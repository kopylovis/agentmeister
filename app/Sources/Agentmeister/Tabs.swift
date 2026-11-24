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
    /// Claude Code с --remote-control: вопросы сессии приходят в приложение Claude на телефоне.
    var remoteControl = false
    /// Не давать Mac уснуть, пока идет сессия. Держит caffeinate, который запускает само приложение.
    var awake = false
    /// Дополнительные флаги агента после --, например --resume <id> --fork-session для форка разговора.
    var extraFlags: [String] = []

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
        // флаги после -- agentmeister передает самому агенту
        var agentArgs: [String] = resumeId == nil ? extraFlags : []
        if remoteControl && agent == .claude { agentArgs += ["--remote-control", projectName] }
        // флаги запуска по умолчанию из настроек агента
        agentArgs = AgentPrefs.flags(agent) + agentArgs
        if let id = resumeId, agent == .claude {
            args += ["--", "--resume", id] + agentArgs
        } else {
            args.append("--new")
            let prompt = firstPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty { agentArgs.append(prompt) }
            if !agentArgs.isEmpty { args += ["--"] + agentArgs }
        }
        return args
    }
}

extension LaunchSpec {
    /// Модель из флагов запуска (--model opus, у Codex еще -m). Флаг сильнее настроек агента.
    var modelFlag: String? {
        let flags = AgentPrefs.flags(agent) + extraFlags
        for (i, flag) in flags.enumerated() {
            if flag.hasPrefix("--model=") { return String(flag.dropFirst(8)) }
            if (flag == "--model" || (agent == .codex && flag == "-m")), i + 1 < flags.count { return flags[i + 1] }
        }
        return nil
    }

    /// Продолжить сессию в ее собственной папке: claude --resume ищет сессию по cwd, а сессия могла начаться
    /// в подпапке проекта.
    static func resume(_ id: String, cwd: String?, project: AppState.Project) -> LaunchSpec {
        var isDir: ObjCBool = false
        let path = cwd.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue ? $0 : nil } ?? project.path
        return LaunchSpec(projectName: project.name, projectPath: path, resumeId: id)
    }

    /// Новая сессия в один клик: агент и маршрут по умолчанию из настроек.
    @MainActor
    static func quick(_ project: AppState.Project, route: String? = nil) -> LaunchSpec {
        LaunchSpec(projectName: project.name, projectPath: project.path,
                   agent: AgentPrefs.defaultAgent == "codex" ? .codex : .claude, direct: route == "direct")
    }
}

/// Одна вкладка: терминал SwiftTerm и процесс в нем.
@MainActor
final class TerminalTab: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    /// Id вкладки переживает перезапуск приложения (tabs.json): по нему клик по старому уведомлению находит
    /// вкладку, и AGENTMEISTER_TAB у идущего агента остается верным.
    let id: UUID
    @Published var spec: LaunchSpec
    @Published var title: String
    @Published var running = true
    @Published var exitCode: Int32?
    /// Сессия Claude Code в этой вкладке и ее статус из реестра Claude Code (waiting, busy, idle).
    @Published var sessionId: String?
    @Published var status: String?
    /// В терминале прозвенел звонок, пока вкладка не была выбрана. Сбрасывается при выборе.
    @Published var rang = false
    /// Вызывается, когда процесс вкладки завершился. Мастер по нему перечитывает состояние.
    var onExit: (() -> Void)?
    /// Подсказка ⌘R после выхода. В мастере ее нет: там перезапуск этой клавишей не работает.
    var exitHint = true
    /// Когда запущен процесс вкладки. Панель сессии показывает, сколько она активна.
    @Published var startedAt = Date()
    /// caffeinate -w для режима "не спать". Живет, пока жив процесс вкладки.
    private var caffeinate: Process?
    let view: AppTerminalView

    init(spec: LaunchSpec, id: UUID? = nil) {
        self.id = id ?? UUID()
        self.spec = spec
        self.title = spec.utility.map { "agentmeister " + $0.joined(separator: " ") } ?? spec.projectName
        self.sessionId = spec.resumeId
        view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        super.init()
        view.tab = self
        view.processDelegate = self
        TerminalPrefs.apply(to: view)
        view.changeScrollback(TerminalPrefs.scrollback)
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
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
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
        startedAt = Date()
        let args = ["-l", "-c", Self.shellScript, LoginEnvironment.agentmeister] + spec.arguments
        view.startProcess(executable: "/bin/zsh", args: args, environment: Self.environment(tab: id, spec: spec), execName: "-zsh",
                          currentDirectory: FileManager.default.fileExists(atPath: spec.projectPath) ? spec.projectPath : NSHomeDirectory())
        updateAwake()
    }

    /// Включить или выключить "не спать" прямо в идущей сессии, без перезапуска.
    func setAwake(_ on: Bool) {
        spec.awake = on
        updateAwake()
    }

    private func updateAwake() {
        caffeinate?.terminate()
        caffeinate = nil
        guard spec.awake, running, shellPid > 0 else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        task.arguments = ["-i", "-w", String(shellPid)]
        if (try? task.run()) != nil { caffeinate = task }
    }

    /// Команда оболочки для claude update. Через proxy (agentmeister proxy run), если не сказано идти напрямую:
    /// скачивание обновления не должно уходить в обычную сеть Mac мимо mihomo.
    /// tail: false отдает весь вывод, а код выхода остается кодом claude update, а не tail.
    nonisolated static func updateCommand(direct: Bool, tail: Bool = true) -> String {
        let am = LoginEnvironment.agentmeister.replacingOccurrences(of: "'", with: "'\\''")
        return (direct ? "claude update" : "'\(am)' proxy run --claude -- claude update") + " 2>&1" + (tail ? " | tail -3" : "")
    }

    /// Чем кончился последний claude update перед перезапуском, если он не прошел. Баннер вкладки
    /// показывает его, сессия при этом открыта на прежней версии.
    struct UpdateFailure {
        let at: Date
        let code: Int32
        let version: String?
        let log: String
    }

    @Published var updateFailed: UpdateFailure?

    /// Перезапуск так, как выбрано галочкой "Перезапускать с обновлением агента": одна настройка для меню,
    /// ⌘R, палитры и панели сессии.
    static var restartUpdates: Bool { UserDefaults.standard.object(forKey: "restartWithUpdate") as? Bool ?? true }

    func restartPreferred(note: String) {
        if Self.restartUpdates && spec.agent == .claude && spec.utility == nil { restartWithUpdate(note: note) } else { restart() }
    }

    /// Перезапуск с claude update перед ним, как /restart. У вкладки через proxy обновление тоже идет через proxy.
    func restartWithUpdate(note: String) {
        guard spec.agent == .claude, spec.utility == nil else { restart(); return }
        afterStop { self.updateThenRestart(note: note) }
    }

    private func updateThenRestart(note: String) {
        view.feed(text: "\r\n\u{1b}[2m" + note + "\u{1b}[0m\r\n")
        updateFailed = nil
        let command = TerminalTab.updateCommand(direct: spec.direct, tail: false)
        Task.detached(priority: .userInitiated) {
            let (code, out) = Self.shell(command)
            // версия, на которой откроется сессия, если обновление не встало
            let version = code == 0 ? nil : Self.shell("claude --version").1.split(whereSeparator: \.isWhitespace)
                .map(String.init).first { $0.first?.isNumber == true }
            let lines = out.split(separator: "\n", omittingEmptySubsequences: true).suffix(3)
            await MainActor.run {
                self.view.feed(text: lines.joined(separator: "\r\n") + (lines.isEmpty ? "" : "\r\n"))
                if code != 0 {
                    // сессия все равно открывается: старая версия Claude Code работает
                    self.updateFailed = UpdateFailure(at: Date(), code: code, version: version,
                                                      log: out.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                self.restart()
            }
        }
    }

    /// Команда zsh с окружением входа: код выхода и весь вывод вместе с ошибками.
    nonisolated static func shell(_ command: String) -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        task.environment = LoginEnvironment.shared
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.standardInput = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return (127, "") }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()
        return (task.terminationStatus, out)
    }

    /// Вписать текст в строку ввода агента, не отправляя. Палитра так подставляет /ask, /shot и другие команды.
    func type(_ text: String) {
        view.send(txt: text)
    }

    /// Та же сессия, другой маршрут: через proxy или напрямую.
    func switchRoute() {
        spec.direct.toggle()
        restart()
    }

    /// Команда agentmeister над сессией этой вкладки, когда агент уже остановлен, потом продолжение.
    /// Пока команда идет, во вкладке видно, что происходит.
    private func whileStopped(_ note: String, _ args: [String], then: @escaping @MainActor (Bool) -> Void) {
        // команда идет только после выхода агента: иначе Claude Code еще дописывает переписку
        afterStop {
            self.view.feed(text: "\r\n\u{1b}[2m" + note + "\u{1b}[0m\r\n")
            Task.detached(priority: .userInitiated) {
                let ok: Bool
                if case .success = Backend.run(args) { ok = true } else { ok = false }
                await MainActor.run { then(ok) }
            }
        }
    }

    /// Что сделать, когда процесс вкладки завершится. SwiftTerm молча не запускает новый процесс, пока старый
    /// не завершился до конца, поэтому перезапуск ждет его выхода, а не стартует сразу после terminate().
    private var pendingAfterExit: (@MainActor () -> Void)?

    private func afterStop(_ action: @escaping @MainActor () -> Void) {
        if running {
            pendingAfterExit = action
            view.terminate()
        } else {
            action()
        }
    }

    /// Сжать сессию (старые скриншоты и длинные выводы) и продолжить ее, как /slim.
    func slim(note: String) {
        guard let sid = sessionId, spec.agent == .claude else { return }
        whileStopped(note, ["sessions", "slim", sid, "-y"]) { _ in self.restart() }
    }

    /// Удалить сессию без следа и открыть чистую в той же папке, как /forget.
    func forget(note: String) {
        guard let sid = sessionId, spec.agent == .claude else { fresh(); return }
        whileStopped(note, ["sessions", "rm", sid, "-y"]) { _ in self.fresh() }
    }

    /// Переименовать сессию, как /rename. Работает и на ходу: Claude Code дописывает название в конец переписки.
    func rename(_ title: String) {
        guard let sid = sessionId else { return }
        Task.detached(priority: .userInitiated) { _ = Backend.run(["sessions", "rename", sid, title]) }
    }

    /// Новая сессия в той же вкладке. Нынешняя остается в списке сессий.
    func fresh() {
        afterStop {
            self.spec.resumeId = nil
            self.spec.firstPrompt = ""
            self.sessionId = nil
            self.start()
        }
    }

    /// Перезапуск продолжает ту же сессию, если ее id уже известен.
    func restart() {
        afterStop {
            if let sid = self.sessionId, self.spec.agent == .claude {
                self.spec.resumeId = sid
                self.spec.firstPrompt = ""
            }
            self.start()
        }
    }

    func terminate() {
        pendingAfterExit = nil
        caffeinate?.terminate()
        caffeinate = nil
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
        caffeinate?.terminate()
        caffeinate = nil
        self.exitCode = exitCode
        status = nil
        if let action = pendingAfterExit {
            // перезапуск, о котором попросили: даем SwiftTerm вернуть сессию в покой и продолжаем
            pendingAfterExit = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { action() }
            return
        }
        let code = exitCode.map(String.init) ?? "?"
        view.feed(text: "\r\n\u{1b}[2m[exit \(code)" + (exitHint ? ". ⌘R" : "") + "]\u{1b}[0m\r\n")
        onExit?()
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
    /// Единственное окно с вкладками: делегат приложения спрашивает у него, есть ли работающие агенты.
    static weak var main: Workspace?

    init() { Workspace.main = self }

    @Published var tabs: [TerminalTab] = [] { didSet { save() } }
    @Published var selected: UUID? { didSet { save() } }
    private var restored = false
    /// Вкладки прошлого запуска уже открыты (или их не было). До этого запрос фокуса ждет.
    var restoredTabs: Bool { restored }

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
        var awake: Bool?
        var remoteControl: Bool?
        /// Id вкладки. Nil в tabs.json старых версий.
        var id: String?
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
                     direct: $0.spec.direct, sessionId: $0.sessionId, selected: $0.id == selected,
                     awake: $0.spec.awake, remoteControl: $0.spec.remoteControl, id: $0.id.uuidString.lowercased())
        }
        let url = Self.savedTabsURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Почему вкладки не закрылись как обычно: приложение упало или Mac перезагрузился. Тогда перед
    /// открытием спрашиваем, как в макете Restore.dc.html.
    enum RestoreReason { case crash, reboot }

    struct PendingRestore {
        let reason: RestoreReason
        let specs: [(spec: LaunchSpec, selected: Bool, id: UUID?)]
    }

    @Published var pendingRestore: PendingRestore?

    static let cleanExitKey = "cleanExit"
    static let reopenSilentlyKey = "restore.reopenSilently"

    /// Время загрузки macOS. Если tabs.json старше, вкладки остались от прошлой загрузки.
    static var bootTime: Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    /// Открыть вкладки прошлого запуска. Сессию, которая сейчас открыта в другом окне (iTerm2 или второй
    /// Agentmeister), не трогаем: второй Claude на той же переписке испортил бы ее. Сессию, в которой Claude
    /// так и не ответил, Claude Code не сохраняет, и --resume ее не найдет, поэтому такая вкладка начнется заново.
    /// После обычного выхода вкладки открываются сразу, после сбоя или перезагрузки сначала лист с вопросом.
    func restore(live: [AppState.Live], projects: [AppState.Project], sessions: [AppState.Session]) {
        guard !restored else { return }
        let defaults = UserDefaults.standard
        let clean = defaults.object(forKey: Self.cleanExitKey) as? Bool ?? true
        defaults.set(false, forKey: Self.cleanExitKey)
        guard let data = try? Data(contentsOf: Self.savedTabsURL),
              let saved = try? JSONDecoder().decode([SavedTab].self, from: data) else {
            restored = true
            return
        }
        let busy = Set(live.compactMap(\.sessionId))
        let known = Set(projects.map(\.path))
        let resumable = Set(sessions.map(\.id))
        var specs: [(spec: LaunchSpec, selected: Bool, id: UUID?)] = []
        for item in saved {
            guard known.contains(item.projectPath) || FileManager.default.fileExists(atPath: item.projectPath) else { continue }
            if let sid = item.sessionId, busy.contains(sid) { continue }
            let agent = LaunchSpec.Agent(rawValue: item.agent) ?? .claude
            var spec = LaunchSpec(projectName: item.projectName, projectPath: item.projectPath, agent: agent, direct: item.direct)
            spec.awake = item.awake ?? false
            spec.remoteControl = item.remoteControl ?? false
            if agent == .claude, let sid = item.sessionId, resumable.contains(sid) { spec.resumeId = sid }
            specs.append((spec, item.selected, item.id.flatMap(UUID.init(uuidString:))))
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: Self.savedTabsURL.path)[.modificationDate]) as? Date
        let reason: RestoreReason? = {
            if clean { return nil }
            if let boot = Self.bootTime, let modified, modified < boot { return .reboot }
            return .crash
        }()
        if let reason, !specs.isEmpty, !defaults.bool(forKey: Self.reopenSilentlyKey) {
            // вкладки пока не трогаем: tabs.json остается, пока не ответили на вопрос
            pendingRestore = PendingRestore(reason: reason, specs: specs)
            return
        }
        finishRestore(specs)
    }

    /// Открыть выбранные вкладки после листа восстановления или сразу.
    func finishRestore(_ specs: [(spec: LaunchSpec, selected: Bool, id: UUID?)]) {
        pendingRestore = nil
        defer { restored = true; save() }
        var select: UUID?
        for item in specs {
            // id второй раз не берем: две вкладки с одним id перепутали бы уведомления
            let tab = TerminalTab(spec: item.spec, id: item.id.flatMap { id in tabs.contains { $0.id == id } ? nil : id })
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

    /// Новая вкладка в проекте текущей: новая сессия с тем же агентом и маршрутом. Без вкладок ничего не делает.
    @discardableResult
    func newTab() -> Bool {
        guard var spec = current?.spec, spec.utility == nil else { return false }
        spec.resumeId = nil
        spec.firstPrompt = ""
        open(spec)
        return true
    }

    /// Текущая вкладка с идущим Claude Code: в нее меню и палитра вписывают /ask, /shot и другие команды.
    var hasClaudeTab: Bool {
        guard let tab = current else { return false }
        return tab.spec.utility == nil && tab.spec.agent == .claude && tab.running
    }

    func typeInClaude(_ text: String) {
        if hasClaudeTab { current?.type(text) }
    }

    func close(_ id: UUID?) {
        guard let id, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].terminate()
        tabs.remove(at: index)
        selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
    }

    /// Соседняя вкладка по кругу: 1 следующая, -1 предыдущая.
    func selectNeighbor(_ step: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == selected } ?? 0
        selected = tabs[(index + step + tabs.count) % tabs.count].id
        current?.rang = false
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

    /// Открыть вкладку из клика по уведомлению: по id вкладки, иначе вкладку с той же сессией, иначе продолжить
    /// сохраненную сессию в новой вкладке, если она не открыта в другом окне. true, если что-то открыли.
    @discardableResult
    func focus(tab: String, session: String? = nil, state: AppState? = nil) -> Bool {
        let tabId = UUID(uuidString: tab)
        let sid = session.flatMap { $0.range(of: Self.sessionPattern, options: .regularExpression) != nil ? $0.lowercased() : nil }
        if let tabId, let target = tabs.first(where: { $0.id == tabId }) {
            selected = target.id
        } else if let sid, let target = tabs.first(where: { $0.sessionId == sid }) {
            selected = target.id
        } else if let sid, !liveElsewhere.contains(sid), let state,
                  let saved = state.sessions.first(where: { $0.id == sid }),
                  let project = state.projects.first(where: { saved.cwd == $0.path || saved.cwd.hasPrefix($0.path + "/") }) {
            open(LaunchSpec.resume(sid, cwd: saved.cwd, project: project))
        } else {
            return false
        }
        current?.rang = false
        Self.bringMainWindowForward()
        return true
    }

    /// id сессии Claude Code: UUID в нижнем регистре. Что-то другое в ссылку не пускаем.
    static let sessionPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

    /// Главное окно вперед, и свернутое тоже.
    static func bringMainWindowForward() {
        NSApp.activate()
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Agentmeister" })
        else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Забрать запрос фокуса, который оставил клик по уведомлению. До восстановления вкладок запрос не трогаем:
    /// после запуска приложения нужная вкладка появится только тогда. Старше двух минут запрос уже не нужен.
    func takeFocusRequest(state: AppState) {
        guard restored, pendingRestore == nil,
              let data = FileManager.default.contents(atPath: Self.focusFile) else { return }
        try? FileManager.default.removeItem(atPath: Self.focusFile)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tab = obj["tab"] as? String else { return }
        if let at = obj["at"] as? Double, Date().timeIntervalSince1970 - at > 120 { return }
        focus(tab: tab, session: obj["session"] as? String, state: state)
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

    /// Звонок: по настройке подсветить вкладку, проиграть звук или ничего.
    nonisolated override func bell(source: Terminal) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                switch TerminalPrefs.bell {
                case "sound": NSSound.beep()
                case "tab": self?.tab?.rang = true
                default: break
                }
            }
        }
    }

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
