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
        // встроенный CLI последним: agentmeister по имени во вкладках находится, даже если его не ставили отдельно
        if let bundled = bundledCLI {
            let dir = (bundled as NSString).deletingLastPathComponent
            if !(env["PATH"] ?? "").split(separator: ":").contains(Substring(dir)) { env["PATH"]! += ":" + dir }
        }
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

    /// Файл рядом с тем agentmeister, который запускают вкладки, или nil, если в этой версии CLI его нет.
    private static func besideCLI(_ relative: String) -> String? {
        let real = (agentmeister as NSString).resolvingSymlinksInPath
        let root = ((real as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let path = (root as NSString).appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// restart_job.py рядом с тем agentmeister, который запускают вкладки. Нет его, и вкладка без перезапуска.
    static let restartJob: String? = besideCLI("libexec/agentmeister/lib/restart_job.py")

    /// EDITOR вкладок Claude Code: по ⌘⇧T переводит строку ввода, иначе открывает обычный редактор.
    static let translateEditor: String? = besideCLI("libexec/agentmeister/editor/agentmeister")

    /// CLI, который едет внутри приложения (Contents/Resources/agentmeister), его кладет туда bundle.sh.
    static let bundledCLI: String? = {
        guard let resources = Bundle.main.resourcePath else { return nil }
        let path = resources + "/agentmeister/bin/agentmeister"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    /// Полный путь к agentmeister. Из PATH пользователя, если он новее встроенного, или той же версии, но это
    /// git-репозиторий (разработка agentmeister: правки в нем должны работать сразу). Иначе встроенный: VERSION
    /// поднимается не с каждым изменением, и CLI той же версии из Homebrew может не знать новых команд.
    static let agentmeister: String = {
        let path = shared["PATH"] ?? "/usr/bin:/bin"
        let first = path.split(separator: ":").map { "\($0)/agentmeister" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let bundled = bundledCLI else { return first ?? "agentmeister" }
        guard let first, realPath(first) != realPath(bundled) else { return bundled }
        let order = compareVersions(cliVersion(first), cliVersion(bundled))
        return order > 0 || (order == 0 && isCheckout(first)) ? first : bundled
    }()

    static var found: Bool { agentmeister.hasPrefix("/") }

    /// Встроенный CLI сейчас главный: в PATH своего нет или он старее.
    static var usesBundledCLI: Bool { bundledCLI != nil && realPath(agentmeister) == realPath(bundledCLI!) }

    private static func realPath(_ path: String) -> String { (path as NSString).resolvingSymlinksInPath }

    /// CLI лежит в git-репозитории (bin/.. содержит .git).
    private static func isCheckout(_ path: String) -> Bool {
        let root = ((realPath(path) as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return FileManager.default.fileExists(atPath: root + "/.git")
    }

    /// Версия CLI из файла VERSION в его корне (bin/..), без него из agentmeister --version.
    private static func cliVersion(_ path: String) -> String {
        let root = ((realPath(path) as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        if let text = try? String(contentsOfFile: root + "/VERSION", encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["--version"]
        task.environment = shared
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "0" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
    }

    private static func compareVersions(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// promptsill, который едет внутри приложения (Contents/Resources/promptsill), его кладет туда bundle.sh.
    static let bundledPromptsill: String? = {
        guard let resources = Bundle.main.resourcePath else { return nil }
        let path = resources + "/promptsill/promptsill"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    /// Команды в терминале сразу после установки приложения: ссылки ~/.local/bin/agentmeister и
    /// ~/.local/bin/promptsill на то, что едет внутри. statusLine Claude Code на promptsill ставит agentmeister setup.
    static func linkCommand() {
        if let cli = bundledCLI { link("agentmeister", to: cli) }
        if let promptsill = bundledPromptsill { link("promptsill", to: promptsill) }
    }

    /// Ссылка ~/.local/bin/<name> на копию внутри приложения. Только из Applications и только если команды еще
    /// нигде нет. Ссылку на копию внутри другого Agentmeister.app (приложение перенесли) переводит на эту.
    private static func link(_ name: String, to bundled: String) {
        let home = NSHomeDirectory()
        let app = Bundle.main.bundlePath
        guard app.hasPrefix("/Applications/") || app.hasPrefix(home + "/Applications/") else { return }
        let fm = FileManager.default
        let link = home + "/.local/bin/" + name
        if let target = try? fm.destinationOfSymbolicLink(atPath: link) {
            guard target != bundled, target.contains("/Agentmeister.app/Contents/Resources/") else { return }
        } else {
            // agentmeister уже есть где-то в PATH входа (Homebrew, ~/bin, bin/ репозитория): своя ссылка его бы
            // перекрыла, а make install потом счел бы ~/.local/bin/agentmeister чужим
            let ownDir = (bundled as NSString).deletingLastPathComponent
            let dirs = (shared["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0 != ownDir }
            if fm.fileExists(atPath: link) || (dirs + ["/opt/homebrew/bin", "/usr/local/bin"]).contains(where: {
                fm.isExecutableFile(atPath: $0 + "/" + name)
            }) {
                return
            }
        }
        try? fm.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        try? fm.removeItem(atPath: link)
        try? fm.createSymbolicLink(atPath: link, withDestinationPath: bundled)
    }
}

/// Ответ agentmeister app-state.
struct AppState: Decodable {
    struct Project: Decodable, Hashable, Identifiable {
        let name: String
        let path: String
        var id: String { path }

        /// Домашняя папка, как "Открыть в домашней папке" в меню CLI. Приложение добавляет ее само.
        var isHome: Bool { path == NSHomeDirectory() }

        /// Лежит ли путь в проекте. Домашней папке принадлежит только она сама: иначе в нее попали бы все проекты
        /// и все сессии.
        func contains(_ other: String) -> Bool {
            other == path || (!isHome && other.hasPrefix(path + "/"))
        }
    }

    struct Session: Decodable, Hashable, Identifiable {
        let id: String
        let cwd: String
        let title: String
        let branch: String
        let mtime: Double
        let size: Int
        let running: Bool
        /// Есть ли еще папка проекта. Nil в старом ответе app-state.
        let cwdExists: Bool?
        /// claude или codex. Nil в старом ответе app-state, это Claude Code.
        var agent: String? = nil
        /// Когда тред Codex начался, секунды Unix.
        var created: Double? = nil

        var kind: LaunchSpec.Agent { agent == "codex" ? .codex : .claude }
    }

    struct Live: Decodable, Hashable {
        let sessionId: String?
        let pid: Int32?
        let cwd: String?
        let status: String?
        let name: String?
        /// Сессия Remote Control, к которой сейчас подключена эта сессия. Claude Code пишет его в реестр при
        /// подключении и стирает при отключении.
        let bridgeSessionId: String?
    }

    struct Proxy: Decodable, Hashable {
        let configured: Bool
        let running: Bool?
        let exit: String?
        let `protocol`: String?
        let sessions: Int?
        let port: Int?
        let ip: String?
        let node: String?
        let defaultRoute: String?
        /// Подписка новых сессий, если по умолчанию выбрана одна (agentmeister -x <имя>). Nil у каскада.
        let defaultSubscription: String?
        /// Подписки proxy: основная и добавленные через proxy add.
        let subscriptions: [Subscription]?
        /// Подписка, на которой каскад (просто -x) сейчас, по ответу mihomo. Nil, если подписка одна, mihomo не
        /// запущен или живых серверов нет.
        let current: String?
        /// Сторож закрыл очередь подписок: ни один живой сервер не выходит в стране основной.
        let blocked: Bool?

        /// Закрыта ли вкладка с этой подпиской (nil у каскада).
        func isBlocked(_ subscription: String?) -> Bool {
            guard let subscription else { return blocked == true }
            return subscriptions?.first { $0.name == subscription }?.blocked == true
        }

        struct Subscription: Decodable, Hashable {
            let name: String
            let port: Int?
            /// Страна выхода из настройки подписки (--country).
            let country: String?
            /// Страна выхода через порт только этой подписки при запуске mihomo.
            let exit: String?
            /// Идет ли подписка в каскад просто -x. Не идет, если ее страна не совпала со страной основной.
            let inCascade: Bool?
            /// Сторож закрыл порт подписки: ни один живой сервер не выходит в ее стране.
            let blocked: Bool?
        }

        /// Порт mihomo для вкладки: каскад или порт ее подписки. Nil, если подписки больше нет: открывать
        /// через другую нельзя.
        func port(for subscription: String?) -> Int? {
            guard let subscription else { return port }
            return subscriptions?.first { $0.name == subscription }?.port
        }

        /// Из чего выбирать подписку: только когда их больше одной.
        var choices: [Subscription] { (subscriptions?.count ?? 0) > 1 ? subscriptions ?? [] : [] }
    }

    /// Подписка новых сессий по умолчанию: nil у каскада по всем подпискам и у прямого маршрута.
    var defaultSubscription: String? {
        guard let proxy, proxy.defaultRoute != "direct", let name = proxy.defaultSubscription else { return nil }
        return proxy.choices.contains { $0.name == name } ? name : nil
    }

    var version = ""
    var lang = "en"
    /// Что выбрано в ~/.config/mnrh/config: ru, en или auto (язык macOS).
    var langSetting: String?
    var projectsDir = ""
    /// Все папки с проектами, первая главная. Nil в старом ответе app-state.
    var projectsDirs: [String]?
    var projects: [Project] = []
    var sessions: [Session] = []
    /// Треды Codex. app-state отдает их отдельно, Backend сливает их в sessions.
    var codexSessions: [Session]?
    var live: [Live] = []
    var proxy: Proxy?
    var modes: [String: Bool] = [:]
    /// Работает ли исполнитель host-run и сколько команд в белом списке.
    var hostRun: HostRun?

    struct HostRun: Decodable, Hashable {
        let running: Bool
        let commands: Int
        let log: String?
    }

    /// Выполнен ли вход в агентов, по их собственным файлам.
    var signedIn: [String: Bool]?
    /// Сколько дней Claude Code хранит переписки.
    var retentionDays: Int?
    /// Модель и усилие из настроек агентов, "opus high" и "gpt-5.5 high". Nil, если не выбраны.
    var models: [String: String?]?
    var errors: [String: String] = [:]

    init() {}

    /// Проект, в папке которого лежит путь. Из вложенных проектов берется самый глубокий.
    func project(containing path: String) -> Project? {
        projects.filter { $0.contains(path) }.max { $0.path.count < $1.path.count }
    }

    func sessions(in project: Project, agent: LaunchSpec.Agent? = nil) -> [Session] {
        sessions.filter { project.contains($0.cwd) && (agent == nil || $0.kind == agent) }
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
        let size: Int?
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
    /// codex для треда Codex. Nil у сессий Claude Code.
    var agent: String? = nil
}

/// Раз в несколько секунд спрашивает agentmeister app-state и раздает результат окнам.
@MainActor
final class Backend: ObservableObject {
    @Published private(set) var state = AppState()
    @Published private(set) var lastError: String?
    /// Выход proxy сменился сам, пока шли сессии. Баннер вкладки показывает это, пока его не скроют.
    @Published var exitChange: (from: String, to: String)?
    /// mihomo не отвечает два опроса подряд, пока идет вкладка через proxy. Одна неудача бывает и у живого mihomo,
    /// когда Mac занят (например, сразу после запуска приложения), и не стоит красного баннера. Без вкладок
    /// через proxy mihomo остановлен нарочно, и промахи не считаются.
    @Published var proxyDown = false
    private var proxyMisses = 0
    /// Backend приложения. Вкладка через proxy при старте просит по нему свежий app-state.
    static weak var main: Backend?
    /// Первый ответ app-state пришел (или не пришел, но попытка была). После него можно восстанавливать вкладки.
    @Published private(set) var ready = false
    private var liveTimer: Timer?
    private var fullTimer: Timer?
    private var projectsRefreshQueued = false
    private var loading = false
    private var pendingRefresh: Task<Void, Never>?
    private var activation: NSObjectProtocol?

    /// Опрос в два темпа. Статусы открытых сессий меняются часто, а читаются дешево: это несколько маленьких
    /// файлов ~/.claude/sessions/<pid>.json, их приложение читает само раз в 2 секунды. Полный app-state
    /// (Python, проекты, сессии, proxy, режимы) идет при запуске, когда окно становится активным, раз в минуту
    /// и после смены статуса какой-то сессии: тогда ее переписка и заголовок могли измениться.
    init() {
        Self.main = self
        refresh()
        if Demo.active { return }  // в демо данные не меняются, опрашивать нечего
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

    /// Вкладка через proxy запустилась: mihomo мог быть остановлен и сейчас поднимается. Свежий app-state сразу
    /// и еще раз, когда кончаются 20 секунд, которые баннер mihomo дает вкладке на старт.
    func proxiedTabStarted() {
        refreshSoon()
        refreshLater(20)
    }

    /// refreshSoon через столько секунд. Не отменяет уже назначенный refreshSoon.
    private func refreshLater(_ seconds: Double) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.refreshSoon()
        }
    }

    private func pollLive() {
        Task.detached(priority: .utility) {
            let live = Self.readLive()
            await MainActor.run {
                // Remote Control тоже: кнопка панели сессии показывает, подключена ли сессия на самом деле
                let before = Dictionary(self.state.live.compactMap { r in r.sessionId.map { ($0, (r.status ?? "") + " " + (r.bridgeSessionId ?? "")) } },
                                        uniquingKeysWith: { a, _ in a })
                let after = Dictionary(live.compactMap { r in r.sessionId.map { ($0, (r.status ?? "") + " " + (r.bridgeSessionId ?? "")) } },
                                       uniquingKeysWith: { a, _ in a })
                guard before != after || self.state.live.map(\.pid) != live.map(\.pid) else { return }
                self.state.live = live
                self.refreshSoon()
            }
        }
    }

    /// Открытые сессии из реестра Claude Code, у которых жив процесс. То же, что claude_live.live() в CLI.
    nonisolated static func readLive() -> [AppState.Live] {
        if Demo.active { return [] }
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

    func refreshProjects() {
        ProjectIcons.shared.invalidate()
        if loading {
            projectsRefreshQueued = true
        } else {
            refresh()
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
                        let previous = self.state.proxy
                        var state = try JSONDecoder().decode(AppState.self, from: data)
                        if let codex = state.codexSessions, !codex.isEmpty {
                            // один список на все окна, новые первыми, как у Claude Code
                            state.sessions = (state.sessions + codex).sorted { $0.mtime > $1.mtime }
                        }
                        // домашняя папка первой, как в меню CLI. В боковой панели она встает после проектов с вкладками
                        let home = NSHomeDirectory()
                        if !state.projects.contains(where: { $0.path == home }) {
                            state.projects.insert(AppState.Project(name: L(state.lang).t("Домашняя папка", "Home"), path: home), at: 0)
                        }
                        self.state = state
                        let watching = Workspace.main?.tabs.contains { $0.running && $0.spec.proxied } ?? false
                        self.proxyMisses = watching && state.proxy?.running == false ? self.proxyMisses + 1 : 0
                        if self.proxyDown != (self.proxyMisses >= 2) { self.proxyDown = self.proxyMisses >= 2 }
                        // первый промах проверяем через 10 секунд, а не через минуту: настоящий сбой виден сразу
                        if self.proxyMisses == 1 { self.refreshLater(10) }
                        if let from = previous?.exit, let to = self.state.proxy?.exit, from != to,
                           previous?.running == true, self.state.proxy?.running == true {
                            self.exitChange = (from, to)
                        }
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
                if self.projectsRefreshQueued {
                    self.projectsRefreshQueued = false
                    self.refresh()
                }
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

    /// Команда agentmeister ради результата для человека: удалось ли и что она напечатала (stdout и stderr вместе,
    /// без цветов). Для действий, у которых вывод в терминале не нужен, а ошибку показать надо.
    nonisolated static func runForText(_ args: [String]) -> (ok: Bool, text: String) {
        if Demo.active { return (true, "") }
        guard LoginEnvironment.found else { return (false, "agentmeister isn't in PATH") }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: LoginEnvironment.agentmeister)
        task.arguments = args
        task.environment = LoginEnvironment.shared
        let out = Pipe()
        task.standardOutput = out
        task.standardError = out
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
            return (task.terminationStatus == 0, text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Команда agentmeister с текстом на stdin, для секретов: в аргументах их видно в ps.
    nonisolated static func runWithInput(_ args: [String], input: String) -> (ok: Bool, text: String) {
        if Demo.active { return (true, "") }
        guard LoginEnvironment.found else { return (false, "agentmeister isn't in PATH") }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: LoginEnvironment.agentmeister)
        task.arguments = args
        task.environment = LoginEnvironment.shared
        let out = Pipe(), inPipe = Pipe()
        task.standardOutput = out
        task.standardError = out
        task.standardInput = inPipe
        do {
            try task.run()
            inPipe.fileHandleForWriting.write(Data((input + "\n").utf8))
            try? inPipe.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
            return (task.terminationStatus == 0, text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    nonisolated static func run(_ args: [String]) -> Result<Data, Error> {
        if Demo.active { return Demo.response(args) }  // демо для скриншотов: готовые ответы, ничего не запускается
        guard LoginEnvironment.found else {
            return .failure(NSError(domain: "agentmeister", code: 127, userInfo: [NSLocalizedDescriptionKey:
                "agentmeister isn't in PATH. Install it (./install.sh) or check PATH in ~/.zshrc."]))
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
                                        userInfo: [NSLocalizedDescriptionKey: "agentmeister \(args.joined(separator: " ")) exited with code \(task.terminationStatus)"]))
            }
            return .success(data)
        } catch {
            return .failure(error)
        }
    }
}
