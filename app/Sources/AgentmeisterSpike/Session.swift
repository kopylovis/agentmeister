import AppKit
import SwiftTerm

/// Что запустить во вкладке. По умолчанию agentmeister сам поднимает proxy, sandbox-exec и агента,
/// как во вкладке iTerm2, поэтому спайк проверяет ровно тот путь, который потом будет в приложении.
struct LaunchSpec {
    var project: String
    var direct = false
    var codex = false
    /// Главное меню agentmeister без проекта: там иконки OSC 1337, которых нет в списке сессий.
    var menu = false
    var agentArgs: [String] = []

    /// Аргументы agentmeister. -n выбирает обычный режим без вопроса (без caffeinate), -x или -d маршрут.
    var arguments: [String] {
        var args = codex ? ["--harness", "codex"] : []
        if menu { return args }
        args += [project, "-n", direct ? "-d" : "-x"]
        if !agentArgs.isEmpty {
            args += ["--"] + agentArgs
        }
        return args
    }

    /// Разбор командной строки спайка: [--menu] [--direct] [--codex] [проект] [-- аргументы агента].
    static func parse(_ argv: [String]) -> LaunchSpec {
        var spec = LaunchSpec(project: ProcessInfo.processInfo.environment["AM_SPIKE_PROJECT"] ?? "agentmeister")
        var rest = argv.dropFirst()
        while let arg = rest.first {
            rest = rest.dropFirst()
            switch arg {
            case "--direct": spec.direct = true
            case "--codex": spec.codex = true
            case "--menu": spec.menu = true
            case "--":
                spec.agentArgs = Array(rest)
                rest = []
            default: spec.project = arg
            }
        }
        return spec
    }
}

/// Одна вкладка: терминал SwiftTerm и процесс в нем.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let spec: LaunchSpec
    let view: LocalProcessTerminalView
    @Published var title: String
    @Published var exitCode: Int32?
    @Published var running = true

    init(spec: LaunchSpec) {
        self.spec = spec
        self.title = spec.project
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.optionAsMetaKey = true
        start()
    }

    /// Окружение как у вкладки терминала, только без следов того, откуда запустили спайк.
    /// TERM_PROGRAM=Agentmeister даст promptsill кликабельные ссылки, MNRH_ICONS=images включит картинки
    /// OSC 1337 в меню agentmeister, хотя menu.py пока узнает только iTerm2 и WezTerm.
    static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        let drop = ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE",
                    "LC_TERMINAL", "LC_TERMINAL_VERSION", "COLORFGBG", "TMUX", "STY",
                    "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy", "NO_PROXY", "no_proxy"]
        for key in drop { env.removeValue(forKey: key) }
        for key in env.keys where key.hasPrefix("CLAUDECODE") || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CODEX_") {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Agentmeister"
        env["TERM_PROGRAM_VERSION"] = "spike"
        env["MNRH_ICONS"] = "images"
        if env["LANG"] == nil { env["LANG"] = "ru_RU.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    func start() {
        exitCode = nil
        running = true
        // zsh -l поднимает PATH из профиля пользователя. Аргументы идут позиционно, кавычки не нужны.
        let args = ["-l", "-c", "exec agentmeister \"$@\"", "zsh"] + spec.arguments
        view.startProcess(executable: "/bin/zsh", args: args, environment: Self.environment(), execName: "-zsh")
    }

    func terminate() {
        if running { view.terminate() }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async {
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            self.title = trimmed.isEmpty ? self.spec.project : trimmed
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.running = false
            self.exitCode = exitCode
            let code = exitCode.map(String.init) ?? "?"
            self.view.feed(text: "\r\n\u{1b}[2m[процесс завершился, код \(code). ⌘⇧R запустит заново]\u{1b}[0m\r\n")
        }
    }
}
