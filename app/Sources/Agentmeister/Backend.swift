import AppKit
import Foundation

/// Окружение входа пользователя. Приложение запускают из Finder или Dock, а там PATH короткий и без Homebrew.
/// Поэтому один раз спрашиваем zsh и дальше запускаем agentmeister и вкладки с тем же окружением. Нужен именно
/// интерактивный вход (-l -i): PATH часто дописывают в .zshrc, а zsh -l его не читает.
enum LoginEnvironment {
    static let shared: [String: String] = load()

    private static let marker = "__AGENTMEISTER_ENV__"
    /// Переменные самой оболочки, которые не нужно переносить во вкладки.
    private static let shellOnly: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "TERM", "ZSH_EXECUTION_STRING"]

    private static func load() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let captured = capture(["-l", "-i", "-c"]) ?? capture(["-l", "-c"]) ?? [:]
        for (key, value) in captured where !shellOnly.contains(key) { env[key] = value }
        env["PATH"] = withFallbacks(env["PATH"] ?? "/usr/bin:/bin")
        return env
    }

    /// Окружение из zsh с данными флагами. Вывод .zshrc отсекается меткой, зависшая оболочка снимается через 5 секунд.
    private static func capture(_ flags: [String]) -> [String: String]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = flags + ["print -rn -- \(marker); env -0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            task.terminate()
            return nil
        }
        task.waitUntilExit()
        guard let range = data.range(of: Data(marker.utf8)) else { return nil }
        var env: [String: String] = [:]
        for entry in data[range.upperBound...].split(separator: 0) {
            guard let line = String(data: Data(entry), encoding: .utf8), let eq = line.firstIndex(of: "=") else { continue }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return env["PATH"] == nil ? nil : env
    }

    /// Обычные места установки в конец PATH, если их там нет: install.sh кладет agentmeister в ~/.local/bin.
    static func withFallbacks(_ path: String) -> String {
        var dirs = path.split(separator: ":").map(String.init)
        let home = NSHomeDirectory()
        for dir in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] where !dirs.contains(dir) {
            dirs.append(dir)
        }
        return dirs.joined(separator: ":")
    }

    /// restart_job.py рядом с тем agentmeister, который запускают вкладки. Нет его, и вкладка без перезапуска.
    static let restartJob: String? = {
        let real = (agentmeister as NSString).resolvingSymlinksInPath
        let root = ((real as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let job = (root as NSString).appendingPathComponent("libexec/agentmeister/lib/restart_job.py")
        return FileManager.default.fileExists(atPath: job) ? job : nil
    }()

    /// Полный путь к agentmeister из PATH пользователя.
    static var agentmeister: String {
        let path = shared["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/agentmeister"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "agentmeister"
    }

    static var found: Bool { agentmeister.hasPrefix("/") }
}

/// Ответ agentmeister app-state.
struct AppState: Decodable {
    struct Project: Decodable, Hashable, Identifiable {
        let name: String
        let path: String
        var id: String { path }
    }

    struct Session: Decodable, Hashable, Identifiable {
        let id: String
        let cwd: String
        let title: String
        let branch: String
        let mtime: Double
        let size: Int
        let running: Bool
    }

    struct Live: Decodable, Hashable {
        let sessionId: String?
        let pid: Int32?
        let cwd: String?
        let status: String?
        let name: String?
    }

    struct Proxy: Decodable, Hashable {
        let configured: Bool
        let running: Bool?
        let exit: String?
        let `protocol`: String?
        let sessions: Int?
        let port: Int?
    }

    var version = ""
    var lang = "en"
    /// Что выбрано в ~/.config/mnrh/config: ru, en или auto (язык macOS).
    var langSetting: String?
    var projectsDir = ""
    var projects: [Project] = []
    var sessions: [Session] = []
    var live: [Live] = []
    var proxy: Proxy?
    var modes: [String: Bool] = [:]
    var errors: [String: String] = [:]

    init() {}

    func sessions(in project: Project) -> [Session] {
        sessions.filter { $0.cwd == project.path || $0.cwd.hasPrefix(project.path + "/") }
    }
}

struct SearchResults: Decodable {
    struct Hit: Decodable, Hashable {
        let at: Int
        let role: String
        let time: Double?
        let snippet: String
    }

    struct Result: Decodable, Hashable, Identifiable {
        let id: String
        let title: String
        let home: String
        let last: Double?
        let count: Int
        let hits: [Hit]
    }

    let query: String
    let exact: Bool
    let scanned: Int
    let results: [Result]
}

struct SessionPreview: Decodable {
    struct Message: Decodable, Hashable, Identifiable {
        let at: Int
        let role: String
        let time: Double?
        let text: String
        var id: Int { at }
    }

    let id: String?
    let title: String?
    let home: String?
    let total: Int?
    let first: Double?
    let last: Double?
    let messages: [Message]?
    let error: String?
}

/// Раз в несколько секунд спрашивает agentmeister app-state и раздает результат окнам.
@MainActor
final class Backend: ObservableObject {
    @Published private(set) var state = AppState()
    @Published private(set) var lastError: String?
    /// Первый ответ app-state пришел (или не пришел, но попытка была). После него можно восстанавливать вкладки.
    @Published private(set) var ready = false
    private var liveTimer: Timer?
    private var fullTimer: Timer?
    private var loading = false
    private var pendingRefresh: Task<Void, Never>?
    private var activation: NSObjectProtocol?

    /// Опрос в два темпа. Статусы открытых сессий меняются часто, а читаются дешево: это несколько маленьких
    /// файлов ~/.claude/sessions/<pid>.json, их приложение читает само раз в 2 секунды. Полный app-state
    /// (Python, проекты, сессии, proxy, режимы) идет при запуске, когда окно становится активным, раз в минуту
    /// и после смены статуса какой-то сессии: тогда ее переписка и заголовок могли измениться.
    init() {
        refresh()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollLive() }
        }
        fullTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshSoon() }
        }
    }

    /// Полный app-state через секунду. Несколько поводов подряд дают один запуск.
    func refreshSoon() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.refresh()
        }
    }

    private func pollLive() {
        Task.detached(priority: .utility) {
            let live = Self.readLive()
            await MainActor.run {
                let before = Dictionary(self.state.live.compactMap { r in r.sessionId.map { ($0, r.status ?? "") } },
                                        uniquingKeysWith: { a, _ in a })
                let after = Dictionary(live.compactMap { r in r.sessionId.map { ($0, r.status ?? "") } },
                                       uniquingKeysWith: { a, _ in a })
                guard before != after || self.state.live.map(\.pid) != live.map(\.pid) else { return }
                self.state.live = live
                self.refreshSoon()
            }
        }
    }

    /// Открытые сессии из реестра Claude Code, у которых жив процесс. То же, что claude_live.live() в CLI.
    nonisolated static func readLive() -> [AppState.Live] {
        let env = LoginEnvironment.shared
        let home = env["CLAUDE_CONFIG_DIR"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        let dir = (home as NSString).appendingPathComponent("sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [AppState.Live] = []
        for name in names where name.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent(name)),
                  let record = try? JSONDecoder().decode(AppState.Live.self, from: data),
                  let pid = record.pid, pid > 0 else { continue }
            if kill(pid, 0) != 0 && errno != EPERM { continue }
            out.append(record)
        }
        return out.sorted { a, b in
            if (a.status == "waiting") != (b.status == "waiting") { return a.status == "waiting" }
            return (a.sessionId ?? "") < (b.sessionId ?? "")
        }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .utility) {
            let result = Self.run(["app-state"])
            await MainActor.run {
                self.loading = false
                switch result {
                case .success(let data):
                    do {
                        self.state = try JSONDecoder().decode(AppState.self, from: data)
                        self.lastError = nil
                        ProxyBrowser.shared.port = self.state.proxy?.port ?? 17890
                        ProxyBrowser.shared.lang = self.state.lang
                    } catch {
                        self.lastError = "app-state: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    self.lastError = error.localizedDescription
                }
                if !self.ready { self.ready = true }
            }
        }
    }

    /// Переключить режим так же, как это делает меню: agentmeister <режим> on|off.
    func setMode(_ name: String, on: Bool) {
        Task.detached(priority: .userInitiated) {
            _ = Self.run([name, on ? "on" : "off"])
            await MainActor.run { self.refresh() }
        }
    }

    /// Поиск по всем сессиям: agentmeister app-state search.
    func search(_ query: String) async -> SearchResults? {
        await Self.json(["app-state", "search", query])
    }

    /// Последние сообщения сессии для превью: agentmeister app-state read.
    func read(_ id: String) async -> SessionPreview? {
        await Self.json(["app-state", "read", id])
    }

    /// Команда agentmeister без JSON, например sessions rm <id> -y. После нее состояние перечитывается.
    func perform(_ args: [String]) async -> Bool {
        let ok = await Task.detached(priority: .userInitiated) {
            if case .success = Self.run(args) { return true }
            return false
        }.value
        refresh()
        return ok
    }

    nonisolated static func json<T: Decodable>(_ args: [String]) async -> T? {
        await Task.detached(priority: .userInitiated) {
            guard case .success(let data) = run(args) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }.value
    }

    nonisolated static func run(_ args: [String]) -> Result<Data, Error> {
        guard LoginEnvironment.found else {
            return .failure(NSError(domain: "agentmeister", code: 127, userInfo: [NSLocalizedDescriptionKey:
                "agentmeister не найден в PATH. Установи его (./install.sh) или проверь PATH в ~/.zshrc."]))
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: LoginEnvironment.agentmeister)
        task.arguments = args
        task.environment = LoginEnvironment.shared
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                return .failure(NSError(domain: "agentmeister", code: Int(task.terminationStatus),
                                        userInfo: [NSLocalizedDescriptionKey: "agentmeister \(args.joined(separator: " ")) завершился с кодом \(task.terminationStatus)"]))
            }
            return .success(data)
        } catch {
            return .failure(error)
        }
    }
}
