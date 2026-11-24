import Foundation

/// Окружение входа пользователя. Приложение запускают из Finder или Dock, а там PATH короткий и без Homebrew.
/// Поэтому один раз спрашиваем zsh -l и дальше запускаем agentmeister и вкладки с тем же окружением.
enum LoginEnvironment {
    static let shared: [String: String] = load()

    private static func load() -> [String: String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", "env -0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            for entry in data.split(separator: 0) {
                guard let line = String(data: Data(entry), encoding: .utf8), let eq = line.firstIndex(of: "=") else { continue }
                env[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        } catch {}
        return env
    }

    /// Полный путь к agentmeister из PATH пользователя.
    static var agentmeister: String {
        let path = shared["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/agentmeister"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "agentmeister"
    }
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
    }

    var version = ""
    var lang = "ru"
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

/// Раз в несколько секунд спрашивает agentmeister app-state и раздает результат окнам.
@MainActor
final class Backend: ObservableObject {
    @Published private(set) var state = AppState()
    @Published private(set) var lastError: String?
    private var timer: Timer?
    private var loading = false

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
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
                    } catch {
                        self.lastError = "app-state: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    self.lastError = error.localizedDescription
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

    nonisolated static func run(_ args: [String]) -> Result<Data, Error> {
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
