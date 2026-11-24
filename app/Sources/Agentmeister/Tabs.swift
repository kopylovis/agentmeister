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

    /// Аргументы agentmeister, как их собирает open_flow.command: -n обычный режим без caffeinate, -x или -d маршрут.
    var arguments: [String] {
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
    let view: LocalProcessTerminalView

    init(spec: LaunchSpec) {
        self.spec = spec
        self.title = spec.projectName
        self.sessionId = spec.resumeId
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.optionAsMetaKey = true
        start()
    }

    /// Окружение вкладки. TERM_PROGRAM=Agentmeister, FORCE_HYPERLINK оставляет ссылки OSC 8 в строке promptsill
    /// (Claude Code иначе вырезает их для незнакомого терминала). Картинки OSC 1337 в меню agentmeister
    /// SwiftTerm стирает, как только в строку пишется текст, поэтому меню показывает emoji.
    static func environment() -> [String] {
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
        if env["LANG"] == nil { env["LANG"] = "ru_RU.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    func start() {
        exitCode = nil
        running = true
        status = nil
        let args = ["-l", "-c", "exec \"$0\" \"$@\"", LoginEnvironment.agentmeister] + spec.arguments
        view.startProcess(executable: "/bin/zsh", args: args, environment: Self.environment(), execName: "-zsh")
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
        let saved = tabs.map {
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

    func terminateAll() {
        tabs.forEach { $0.terminate() }
    }
}
