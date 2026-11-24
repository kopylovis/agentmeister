import AppKit
import Darwin
import SwiftTerm

/// Что запустить во вкладке. agentmeister сам поднимает proxy, sandbox-exec и агента, как во вкладке iTerm2.
struct LaunchSpec: Hashable {
    enum Agent: String, CaseIterable { case claude, codex }

    var projectName: String
    var projectPath: String
    var agent: Agent = .claude
    var direct = false
    /// id сессии Claude Code, которую продолжить. nil значит новая сессия.
    var resumeId: String?
    var firstPrompt = ""
    /// Служебная вкладка: agentmeister с этими аргументами вместо агента (proxy setup, lid setup и т. п.).
    /// Такие вкладки не восстанавливаются после перезапуска.
    var utility: [String]?

    /// Идет ли вкладка через proxy: обычная сессия без -d или служебная agentmeister proxy run.
    var proxied: Bool {
        if let utility { return utility.starts(with: ["proxy", "run"]) }
        return !direct
    }

    /// Служебная вкладка входа в агента (claude auth login, codex login).
    var signIn: Bool { utility?.contains("login") ?? false }

    /// Аргументы agentmeister, как их собирает open_flow.command: -n обычный режим без caffeinate, -x или -d маршрут.
    var arguments: [String] {
        if let utility { return utility }
        var args = agent == .codex ? ["--harness", "codex"] : []
        args += [projectPath, "-n", direct ? "-d" : "-x"]
        if let id = resumeId, agent == .claude {
            args += ["--", "--resume", id]
        } else {
            args.append("--new")
            let prompt = firstPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty { args += ["--", prompt] }
        }
        return args
    }
}

/// Одна вкладка: терминал SwiftTerm и процесс в нем.
@MainActor
final class TerminalTab: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    @Published var spec: LaunchSpec
    @Published var title: String
    @Published var running = true
    @Published var exitCode: Int32?
    /// Сессия Claude Code в этой вкладке и ее статус из реестра Claude Code (waiting, busy, idle).
    @Published var sessionId: String?
    @Published var status: String?
    let view: AppTerminalView

    init(spec: LaunchSpec) {
        self.spec = spec
        self.title = spec.utility.map { "agentmeister " + $0.joined(separator: " ") } ?? spec.projectName
        self.sessionId = spec.resumeId
        view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        super.init()
        view.tab = self
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.optionAsMetaKey = true
        start()
    }

    /// Окружение вкладки. TERM_PROGRAM=Agentmeister, FORCE_HYPERLINK оставляет ссылки OSC 8 в строке promptsill
    /// (Claude Code иначе вырезает их для незнакомого терминала). Картинки OSC 1337 в меню agentmeister
    /// SwiftTerm стирает, как только в строку пишется текст, поэтому меню показывает emoji.
    static func environment(tab: UUID, spec: LaunchSpec) -> [String] {
        var env = LoginEnvironment.shared
        let drop = ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE",
                    "LC_TERMINAL", "LC_TERMINAL_VERSION", "COLORFGBG", "TMUX", "STY",
                    "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy", "NO_PROXY", "no_proxy",
                    "MNRH_PROXY"]
        for key in drop { env.removeValue(forKey: key) }
        for key in env.keys where key.hasPrefix("CLAUDECODE") || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CODEX_") {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Agentmeister"
        env["MNRH_ICONS"] = "emoji"
        env["FORCE_HYPERLINK"] = "1"
        // хук уведомлений узнает по нему вкладку: клик открывает ее, а если она впереди, уведомления нет
        env["AGENTMEISTER_TAB"] = tab.uuidString.lowercased()
        if let job = LoginEnvironment.restartJob {
            // тот же признак, что ставит restart.zsh: claude_restart пишет задание для хука, а не ищет вкладку iTerm2
            env["MNRH_RESTART_HOOK"] = "2"
            env["MNRH_RESTART_JOB"] = job
        }
        // страницы, которые агент открывает сам (вход, OAuth для MCP), идут во встроенный браузер через тот же proxy
        env.removeValue(forKey: "BROWSER")
        if spec.proxied && BrowserSettings.forAgent, let helper = ProxyBrowser.helper {
            env["BROWSER"] = helper
        }
        if env["LANG"] == nil { env["LANG"] = "ru_RU.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// После agentmeister вкладка выполняет задания перезапуска, как хук share/agentmeister/restart.zsh в iTerm2.
    /// /restart, /forget, /fresh и /slim кладут задание в ~/.cache/mnrh/restart/<tty>, restart_job.py take
    /// проверяет его поля, run строит argv сам. Без этого цикла вкладке после выхода Claude некуда вернуться.
    static let shellScript = """
    "$0" "$@"
    j=${MNRH_RESTART_JOB:-}
    [[ -n $j && -f $j ]] || exit
    t=${TTY:-$(tty)}
    f=$HOME/.cache/mnrh/restart/${t:t}
    while [[ -e $f || -L $f ]]; do
      out=$(/usr/bin/python3 -I $j take $f) || break
      job=( "${(@0)out}" )
      (( $#job == 3 )) || break
      cd -- $job[1] || break
      /usr/bin/python3 -I $j run $job[3]
    done
    """

    func start() {
        exitCode = nil
        running = true
        status = nil
        let args = ["-l", "-c", Self.shellScript, LoginEnvironment.agentmeister] + spec.arguments
        view.startProcess(executable: "/bin/zsh", args: args, environment: Self.environment(tab: id, spec: spec), execName: "-zsh")
    }

    /// Перезапуск продолжает ту же сессию, если ее id уже известен.
    func restart() {
        if running { view.terminate() }
        if let sid = sessionId, spec.agent == .claude {
            spec.resumeId = sid
            spec.firstPrompt = ""
        }
        start()
    }

    func terminate() {
        if running { view.terminate() }
    }

    var shellPid: pid_t { view.process?.shellPid ?? 0 }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        self.title = trimmed.isEmpty ? spec.projectName : trimmed
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        running = false
        self.exitCode = exitCode
        status = nil
        let code = exitCode.map(String.init) ?? "?"
        view.feed(text: "\r\n\u{1b}[2m[exit \(code). ⌘⇧R]\u{1b}[0m\r\n")
    }
}

/// Родитель процесса по sysctl. Нужен, чтобы понять, какая сессия из реестра Claude Code живет в нашей вкладке.
func parentPid(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

func isDescendant(_ pid: pid_t, of root: pid_t) -> Bool {
    guard root > 1 else { return false }
    var current = pid
    for _ in 0..<32 {
        if current == root { return true }
        guard let parent = parentPid(of: current), parent > 1 else { return false }
        current = parent
    }
    return false
}

/// Вкладки окна. Терминалы живут здесь, а не во view, чтобы переключение вкладок не убивало процессы.
@MainActor
final class Workspace: ObservableObject {
    @Published var tabs: [TerminalTab] = [] { didSet { save() } }
    @Published var selected: UUID? { didSet { save() } }
    private var restored = false

    var current: TerminalTab? { tabs.first { $0.id == selected } }

    // MARK: Вкладки между запусками

    /// Что нужно, чтобы открыть вкладку снова: проект, агент, маршрут и сессия Claude Code.
    struct SavedTab: Codable {
        var projectName: String
        var projectPath: String
        var agent: String
        var direct: Bool
        var sessionId: String?
        var selected: Bool
    }

    static var savedTabsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Agentmeister/tabs.json")
    }

    /// Записывается при каждом изменении вкладок, поэтому падение приложения тоже не теряет их.
    func save() {
        guard restored else { return }
        let saved = tabs.filter { $0.spec.utility == nil }.map {
            SavedTab(projectName: $0.spec.projectName, projectPath: $0.spec.projectPath, agent: $0.spec.agent.rawValue,
                     direct: $0.spec.direct, sessionId: $0.sessionId, selected: $0.id == selected)
        }
        let url = Self.savedTabsURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Открыть вкладки прошлого запуска. Сессию, которая сейчас открыта в другом окне (iTerm2 или второй
    /// Agentmeister), не трогаем: второй Claude на той же переписке испортил бы ее. Сессию, в которой Claude
    /// так и не ответил, Claude Code не сохраняет, и --resume ее не найдет, поэтому такая вкладка начнется заново.
    func restore(live: [AppState.Live], projects: [AppState.Project], sessions: [AppState.Session]) {
        guard !restored else { return }
        defer { restored = true; save() }
        guard let data = try? Data(contentsOf: Self.savedTabsURL),
              let saved = try? JSONDecoder().decode([SavedTab].self, from: data) else { return }
        let busy = Set(live.compactMap(\.sessionId))
        let known = Set(projects.map(\.path))
        let resumable = Set(sessions.map(\.id))
        var select: UUID?
        for item in saved {
            guard known.contains(item.projectPath) || FileManager.default.fileExists(atPath: item.projectPath) else { continue }
            if let sid = item.sessionId, busy.contains(sid) { continue }
            let agent = LaunchSpec.Agent(rawValue: item.agent) ?? .claude
            var spec = LaunchSpec(projectName: item.projectName, projectPath: item.projectPath, agent: agent, direct: item.direct)
            if agent == .claude, let sid = item.sessionId, resumable.contains(sid) { spec.resumeId = sid }
            let tab = TerminalTab(spec: spec)
            tabs.append(tab)
            if item.selected { select = tab.id }
        }
        selected = select ?? tabs.first?.id
    }

    /// Сессии Claude Code, открытые не во вкладках этого окна: в iTerm2, Terminal или втором Agentmeister.
    @Published private(set) var liveElsewhere: Set<String> = []
    /// Почему последнее открытие не удалось. Окно показывает это предупреждением.
    @Published var notice: String?

    func open(_ spec: LaunchSpec) {
        // Сессия уже открыта во вкладке: переходим к ней, а не запускаем второй Claude на той же переписке
        if let sid = spec.resumeId, let tab = tabs.first(where: { $0.sessionId == sid && $0.running }) {
            selected = tab.id
            return
        }
        // Открыта в другом окне: второй Claude на той же переписке перемешал бы ответы обоих
        if let sid = spec.resumeId, liveElsewhere.contains(sid) {
            notice = sid
            return
        }
        let tab = TerminalTab(spec: spec)
        tabs.append(tab)
        selected = tab.id
    }

    func close(_ id: UUID?) {
        guard let id, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].terminate()
        tabs.remove(at: index)
        selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
    }

    func select(number: Int) {
        guard number >= 1, number <= tabs.count else { return }
        selected = tabs[number - 1].id
    }

    /// Сопоставить открытые сессии Claude Code с вкладками по дереву процессов и обновить статусы.
    func sync(with live: [AppState.Live]) {
        defer {
            let mine = Set(tabs.filter(\.running).compactMap(\.sessionId))
            let elsewhere = Set(live.compactMap(\.sessionId)).subtracting(mine)
            if elsewhere != liveElsewhere { liveElsewhere = elsewhere }
        }
        for tab in tabs where tab.running {
            let root = tab.shellPid
            let match = live.first { record in
                guard let pid = record.pid else { return false }
                if let sid = tab.sessionId, record.sessionId == sid { return true }
                return isDescendant(pid, of: root)
            }
            if let match {
                if tab.sessionId != match.sessionId {
                    tab.sessionId = match.sessionId
                    save()
                }
                if tab.status != match.status { tab.status = match.status }
            } else if tab.status != nil {
                tab.status = nil
            }
        }
    }

    // MARK: Уведомления

    static let appDir = (NSHomeDirectory() as NSString).appendingPathComponent(".cache/mnrh/app")
    static let frontFile = (appDir as NSString).appendingPathComponent("front.json")
    static let focusFile = (appDir as NSString).appendingPathComponent("focus.json")

    /// Записать, какая вкладка выбрана и активно ли окно. Хук уведомлений не шлет уведомление о вкладке,
    /// на которую ты и так смотришь.
    func writeFront(active: Bool) {
        let front: [String: Any] = ["tab": current?.id.uuidString.lowercased() ?? "", "active": active,
                                    "at": Date().timeIntervalSince1970]
        try? FileManager.default.createDirectory(atPath: Self.appDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: front) {
            try? data.write(to: URL(fileURLWithPath: Self.frontFile), options: .atomic)
        }
    }

    /// Открыть вкладку по id из клика по уведомлению. true, если такая вкладка есть.
    @discardableResult
    func focus(tab: String) -> Bool {
        guard let target = tabs.first(where: { $0.id.uuidString.lowercased() == tab.lowercased() }) else { return false }
        selected = target.id
        NSApp.activate()
        return true
    }

    /// Забрать запрос фокуса, который оставил клик по уведомлению. Старше минуты запрос уже не нужен.
    func takeFocusRequest() {
        guard let data = FileManager.default.contents(atPath: Self.focusFile) else { return }
        try? FileManager.default.removeItem(atPath: Self.focusFile)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tab = obj["tab"] as? String else { return }
        if let at = obj["at"] as? Double, Date().timeIntervalSince1970 - at > 60 { return }
        focus(tab: tab)
    }

    func terminateAll() {
        tabs.forEach { $0.terminate() }
    }
}

/// Настройки встроенного браузера. Хранятся в UserDefaults, переключаются в Настройки → Proxy.
enum BrowserSettings {
    static let forAgentKey = "browserForAgent"
    static let forLinksKey = "browserForLinks"
    /// Страницы, которые открывает агент во вкладке через proxy. По умолчанию включено.
    static var forAgent: Bool { UserDefaults.standard.object(forKey: forAgentKey) as? Bool ?? true }
    /// Ссылки, по которым кликаешь во вкладке через proxy. По умолчанию браузер системы.
    static var forLinks: Bool { UserDefaults.standard.bool(forKey: forLinksKey) }
}

/// Терминал вкладки. Отличается от SwiftTerm одним: ссылки http и https из вкладки через proxy может открыть
/// во встроенном браузере. Во вкладке входа так всегда, пока включен браузер для агента, иначе по настройке.
final class AppTerminalView: LocalProcessTerminalView {
    weak var tab: TerminalTab?

    override func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        if let spec = tab?.spec, spec.proxied,
           spec.signIn ? BrowserSettings.forAgent : BrowserSettings.forLinks,
           let url = URL(string: request.link), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            ProxyBrowser.shared.open(url)
            return
        }
        super.requestOpenLink(source: source, request: request)
    }
}
