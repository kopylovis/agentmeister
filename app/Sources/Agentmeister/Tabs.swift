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
    /// id сессии Claude Code или треда Codex, который продолжить. nil значит новая сессия.
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
        } else if let id = resumeId {
            // как agentmeister --harness codex restart: codex resume -C <папка> <id>, флаги перед id
            args += ["--", "resume", "-C", projectPath] + agentArgs + [id]
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
    static func resume(_ id: String, cwd: String?, project: AppState.Project, agent: Agent = .claude) -> LaunchSpec {
        var isDir: ObjCBool = false
        let path = cwd.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue ? $0 : nil } ?? project.path
        return LaunchSpec(projectName: project.name, projectPath: path, agent: agent, resumeId: id)
    }

    /// Продолжить сохраненную сессию любого агента.
    static func resume(_ session: AppState.Session, project: AppState.Project) -> LaunchSpec {
        resume(session.id, cwd: session.cwd, project: project, agent: session.kind)
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
    /// Сессия Claude Code (или тред Codex) в этой вкладке и ее статус из реестра Claude Code (waiting, busy, idle).
    /// У Codex статуса нет, а id треда находит Workspace.trackCodexThreads.
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
    /// Вкладку закрыли. Отложенный перезапуск (после claude update, slim или выхода процесса) ее уже не поднимает:
    /// иначе агент пошел бы в терминале, которого нет ни в одном окне.
    private var closed = false
    /// Перезапуск уже идет: ждем выхода агента, claude update или команду sessions. Повторный запрос до нового
    /// старта ничего не делает, иначе второй claude update убил бы сессию, которую открыл первый.
    private var restarting = false
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
        restarting = false
        guard !closed else { return }
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
        // tabs.json пишется по изменению списка вкладок, а это изменение внутри вкладки
        Workspace.main?.save()
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
                guard !self.closed else { return }
                self.view.feed(text: lines.joined(separator: "\r\n") + (lines.isEmpty ? "" : "\r\n"))
                if code != 0 {
                    // сессия все равно открывается: старая версия Claude Code работает
                    self.updateFailed = UpdateFailure(at: Date(), code: code, version: version,
                                                      log: out.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                self.relaunch()
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
        afterStop {
            self.spec.direct.toggle()
            Workspace.main?.save()
            self.relaunch()
        }
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
                await MainActor.run {
                    // вкладку закрыли, пока шла команда: продолжать некуда
                    if self.closed { self.restarting = false } else { then(ok) }
                }
            }
        }
    }

    /// Что сделать, когда процесс вкладки завершится. SwiftTerm молча не запускает новый процесс, пока старый
    /// не завершился до конца, поэтому перезапуск ждет его выхода, а не стартует сразу после terminate().
    private var pendingAfterExit: (@MainActor () -> Void)?

    private func afterStop(_ action: @escaping @MainActor () -> Void) {
        guard !closed else { return }
        if restarting {
            // агент еще не вышел: повторяем сигнал, а действие остается первым
            if running, pendingAfterExit != nil { view.terminate() }
            return
        }
        restarting = true
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
        whileStopped(note, ["sessions", "slim", sid, "-y"]) { _ in self.relaunch() }
    }

    /// Удалить сессию без следа и открыть чистую в той же папке, как /forget.
    func forget(note: String) {
        guard let sid = sessionId, spec.agent == .claude else { fresh(); return }
        whileStopped(note, ["sessions", "rm", sid, "-y"]) { _ in self.startFresh() }
    }

    /// Переименовать сессию, как /rename. Работает и на ходу: Claude Code дописывает название в конец переписки.
    func rename(_ title: String) {
        guard let sid = sessionId else { return }
        Task.detached(priority: .userInitiated) { _ = Backend.run(["sessions", "rename", sid, title]) }
    }

    /// Новая сессия в той же вкладке. Нынешняя остается в списке сессий.
    func fresh() {
        afterStop { self.startFresh() }
    }

    private func startFresh() {
        spec.resumeId = nil
        spec.firstPrompt = ""
        sessionId = nil
        start()
    }

    /// Перезапуск продолжает ту же сессию, если ее id уже известен. У Codex так же, по id треда.
    func restart() {
        afterStop { self.relaunch() }
    }

    /// Запуск той же сессии, когда агент уже остановлен. Последний шаг любого перезапуска.
    private func relaunch() {
        if let sid = sessionId, spec.utility == nil {
            spec.resumeId = sid
            spec.firstPrompt = ""
        }
        start()
    }

    func terminate() {
        closed = true
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
            if let sid = item.sessionId, resumable.contains(sid) { spec.resumeId = sid }
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

    /// Открытые сессии: идущие вкладки этого окна и записи реестра Claude Code, которых среди них нет
    /// (iTerm2, второй Agentmeister). Реестр знает и наши вкладки, поэтому вкладка с известной сессией
    /// считается один раз, а вкладка Codex, которой нет в реестре, тоже считается.
    func openSessions(_ state: AppState) -> (tabs: [TerminalTab], others: [AppState.Live]) {
        let open = tabs.filter { $0.running && $0.spec.utility == nil }
        let mine = Set(open.compactMap(\.sessionId))
        return (open, state.live.filter { $0.sessionId.map { !mine.contains($0) } ?? true })
    }

    /// Открытые сессии проекта. Вкладка и запись реестра относятся к самому глубокому проекту, в чьей папке
    /// лежат: продолжение открывается в папке сессии, а это бывает подпапка проекта.
    func openSessions(in project: AppState.Project, state: AppState) -> (tabs: [TerminalTab], others: [AppState.Live]) {
        let (open, others) = openSessions(state)
        let here = { (path: String?) in path.flatMap { state.project(containing: $0)?.path } == project.path }
        return (open.filter { here($0.spec.projectPath) }, others.filter { here($0.cwd) })
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
        // реестр знает только Claude Code: Codex во вкладке мог запустить claude, и тот не сессия вкладки
        for tab in tabs where tab.running && tab.spec.agent == .claude {
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

    /// Новая вкладка Claude Code в том же проекте и маршруте с контекстом треда Codex: /import-codex <id>.
    func moveToClaude(_ tab: TerminalTab) {
        guard tab.spec.agent == .codex, tab.spec.utility == nil, let sid = tab.sessionId else { return }
        var spec = LaunchSpec(projectName: tab.spec.projectName, projectPath: tab.spec.projectPath, direct: tab.spec.direct)
        spec.firstPrompt = "/import-codex " + sid
        open(spec)
    }

    private var codexScanAt = Date.distantPast
    private var codexScanning = false

    /// Узнать тред Codex у вкладок, где его id еще нет: самый ранний новый тред в папке вкладки, начатый после
    /// ее запуска, не занятый другой вкладкой и принадлежащий процессу этой вкладки. Свой значит, что rollout
    /// держит открытым потомок shell вкладки, а если файл сейчас закрыт, что id треда есть в argv потомка codex.
    /// Иначе тред мог начать Codex в iTerm2 в той же папке: не берем и смотрим снова через 5 секунд.
    /// Codex заводит rollout с первым запросом, до него продолжать нечего.
    /// Зовется раз в секунду, а файлы смотрит не чаще раза в 5 секунд и только пока такие вкладки есть.
    func trackCodexThreads() {
        let waiting = tabs.filter { $0.running && $0.spec.agent == .codex && $0.spec.utility == nil && $0.sessionId == nil }
        guard !waiting.isEmpty, !codexScanning, Date().timeIntervalSince(codexScanAt) > 5 else { return }
        codexScanAt = Date()
        codexScanning = true
        let since = waiting.map(\.startedAt).min() ?? Date()
        let roots = waiting.map(\.shellPid)
        Task.detached(priority: .utility) {
            let threads = CodexThreads.recent(since: since)
            // процессы вкладок смотрим, только если есть что сопоставлять
            let trees = threads.isEmpty ? [] : roots.map { ProcessTree.Snapshot(root: $0) }
            await MainActor.run {
                self.codexScanning = false
                var claimed = Set(self.tabs.filter { $0.spec.agent == .codex }.compactMap(\.sessionId))
                let order = waiting.indices.sorted { waiting[$0].startedAt < waiting[$1].startedAt }
                for index in order where index < trees.count {
                    let tab = waiting[index], tree = trees[index]
                    // shell вкладки сменился (перезапуск): дерево снято с прошлого процесса
                    guard tab.running, tab.sessionId == nil, tab.shellPid == tree.root else { continue }
                    let path = (tab.spec.projectPath as NSString).resolvingSymlinksInPath
                    guard let thread = threads.first(where: { thread in
                        !claimed.contains(thread.id) && thread.created >= tab.startedAt.addingTimeInterval(-2)
                            && (thread.cwd as NSString).resolvingSymlinksInPath == path
                            && tree.owns(thread)
                    }) else { continue }
                    claimed.insert(thread.id)
                    tab.sessionId = thread.id
                }
                self.save()
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
    /// сохраненную сессию в новой вкладке, если она не открыта в другом окне. Продолжение только с allowResume:
    /// его дает запрос из focus.json, который пишет хук уведомлений. Ссылка agentmeister:// сама по себе может
    /// прийти от любой программы и только выбирает уже открытую вкладку. true, если что-то открыли.
    @discardableResult
    func focus(tab: String, session: String? = nil, state: AppState? = nil, allowResume: Bool = false) -> Bool {
        let tabId = UUID(uuidString: tab)
        let sid = session.flatMap { $0.range(of: Self.sessionPattern, options: .regularExpression) != nil ? $0.lowercased() : nil }
        if let tabId, let target = tabs.first(where: { $0.id == tabId }) {
            selected = target.id
        } else if let sid, let target = tabs.first(where: { $0.sessionId == sid }) {
            selected = target.id
        } else if allowResume, let sid, !liveElsewhere.contains(sid), let state,
                  let saved = state.sessions.first(where: { $0.id == sid }),
                  let project = state.projects.first(where: { saved.cwd == $0.path || saved.cwd.hasPrefix($0.path + "/") }) {
            // агент из сохраненной сессии: id треда Codex иначе ушел бы в claude --resume
            open(LaunchSpec.resume(saved, project: project))
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
        guard restored, pendingRestore == nil, let request = Self.takeFocusFile() else { return }
        focus(tab: request.tab, session: request.session, state: state, allowResume: true)
    }

    /// Прочитать и сразу удалить focus.json, чтобы один запрос не сработал дважды. nil, если файла нет,
    /// он испорчен или старше двух минут.
    static func takeFocusFile() -> (tab: String, session: String?)? {
        guard let data = FileManager.default.contents(atPath: focusFile) else { return nil }
        try? FileManager.default.removeItem(atPath: focusFile)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tab = obj["tab"] as? String else { return nil }
        if let at = obj["at"] as? Double, Date().timeIntervalSince1970 - at > 120 { return nil }
        return (tab, obj["session"] as? String)
    }

    /// Ссылка agentmeister://focus: выбрать открытую вкладку. Продолжить сохраненную сессию можно, только если
    /// хук уведомлений оставил в focus.json запрос с той же вкладкой и сессией. Запрос забираем в любом случае.
    func focusFromURL(tab: String, session: String?, state: AppState) {
        let request = Self.takeFocusFile()
        let same = { (a: String?, b: String?) in a.map { $0.lowercased() } == b.map { $0.lowercased() } }
        let allow = session != nil && request.map { same($0.session, session) && same($0.tab, tab) } == true
        focus(tab: tab, session: session, state: state, allowResume: allow)
    }

    func terminateAll() {
        tabs.forEach { $0.terminate() }
    }
}

/// Треды Codex, начатые недавно, прямо из ~/.codex/sessions. Codex не пишет реестр открытых сессий, как Claude
/// Code, поэтому вкладка узнает свой тред так: новый rollout в ее папке, начатый после запуска вкладки.
enum CodexThreads {
    struct Thread {
        let id: String
        let cwd: String
        let created: Date
        /// Файл rollout: по нему видно, какой процесс пишет тред.
        var path = ""
    }

    static var home: String {
        LoginEnvironment.shared["CODEX_HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    /// Треды с первой строкой session_meta, файлы которых менялись после since. Смотрим только папки дней
    /// от since до сегодня: Codex раскладывает rollout по sessions/ГГГГ/ММ/ДД.
    nonisolated static func recent(since: Date) -> [Thread] {
        let fm = FileManager.default
        let root = (home as NSString).appendingPathComponent("sessions")
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: since.addingTimeInterval(-86400))
        var out: [Thread] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        while day <= Date() {
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = String(format: "%@/%04d/%02d/%02d", root, c.year ?? 0, c.month ?? 0, c.day ?? 0)
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let path = (dir as NSString).appendingPathComponent(name)
                guard let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date,
                      modified >= since.addingTimeInterval(-5),
                      var thread = firstLine(path, iso: iso) else { continue }
                thread.path = path
                out.append(thread)
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? Date.distantFuture
        }
        return out.sorted { $0.created < $1.created }
    }

    private nonisolated static func firstLine(_ path: String, iso: ISO8601DateFormatter) -> Thread? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // в первой строке лежат и инструкции модели, она бывает в десятки килобайт
        guard let data = try? handle.read(upToCount: 1 << 20),
              let end = data.firstIndex(of: UInt8(ascii: "\n")) ?? (data.isEmpty ? nil : data.endIndex),
              let row = try? JSONSerialization.jsonObject(with: data[..<end]) as? [String: Any],
              row["type"] as? String == "session_meta",
              let meta = row["payload"] as? [String: Any],
              let id = meta["id"] as? String, let cwd = meta["cwd"] as? String,
              let stamp = meta["timestamp"] as? String, let created = iso.date(from: stamp) else { return nil }
        // треды субагентов Codex заводит сам, это не разговор вкладки
        if meta["source"] is [String: Any] || meta["thread_source"] as? String == "subagent" { return nil }
        return Thread(id: id.lowercased(), cwd: cwd, created: created)
    }
}

/// Процессы вкладки через libproc: потомки shell, их открытые файлы и argv. Нужно, чтобы вкладка Codex взяла
/// свой тред, а не тред Codex из iTerm2 в той же папке. Приложение идет вне песочницы и видит процессы своего
/// пользователя, как lsof.
enum ProcessTree {
    /// Потомки root, открытые ими файлы и argv тех, кто похож на codex. Снимок делается вне главного потока.
    struct Snapshot {
        let root: pid_t
        /// Открытые потомками rollout-файлы, пути приведены через samePath.
        var openFiles: Set<String> = []
        /// argv потомков, у которых в пути программы или в argv есть codex.
        var codexArgv: [[String]] = []

        nonisolated init(root: pid_t) {
            self.root = root
            for pid in ProcessTree.descendants(of: root) {
                // нужны только rollout, остальные файлы node и codex не приводим
                for file in ProcessTree.openFiles(of: pid) where (file as NSString).lastPathComponent.hasPrefix("rollout-") {
                    openFiles.insert(ProcessTree.samePath(file))
                }
                if let argv = ProcessTree.arguments(of: pid), argv.contains(where: ProcessTree.isCodex) {
                    codexArgv.append(argv)
                }
            }
        }

        /// Тред принадлежит вкладке: его rollout открыт у потомка, а если закрыт между записями, id треда
        /// стоит в argv потомка codex (codex resume <id>).
        nonisolated func owns(_ thread: CodexThreads.Thread) -> Bool {
            if !thread.path.isEmpty, openFiles.contains(ProcessTree.samePath(thread.path)) { return true }
            return codexArgv.contains { argv in argv.contains { $0.lowercased().contains(thread.id) } }
        }
    }

    /// Один путь в одном виде: без симлинков и без /private, который macOS дописывает к /var и /tmp.
    nonisolated static func samePath(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }

    nonisolated static func isCodex(_ arg: String) -> Bool {
        (arg as NSString).lastPathComponent.lowercased().contains("codex")
    }

    /// Все потомки root обходом в ширину по PROC_PPID_ONLY. Предел на случай дерева, которое растет под нами.
    nonisolated static func descendants(of root: pid_t) -> [pid_t] {
        guard root > 1 else { return [] }
        var out: [pid_t] = []
        var queue = [root]
        var seen: Set<pid_t> = [root]
        while !queue.isEmpty, out.count < 1024 {
            let pid = queue.removeFirst()
            for child in children(of: pid) where seen.insert(child).inserted {
                out.append(child)
                queue.append(child)
            }
        }
        return out
    }

    nonisolated static func children(of pid: pid_t) -> [pid_t] {
        let estimate = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), nil, 0)
        guard estimate > 0 else { return [] }
        // запас: между двумя вызовами могли появиться новые дети
        var pids = [pid_t](repeating: 0, count: Int(estimate) / MemoryLayout<pid_t>.stride + 16)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    /// Пути файлов, открытых процессом: PROC_PIDLISTFDS, затем PROC_PIDFDVNODEPATHINFO по каждому vnode.
    nonisolated static func openFiles(of pid: pid_t) -> [String] {
        let estimate = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimate > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimate) / stride + 16)
        let bytes = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }
        var out: [String] = []
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(bytes) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty { out.append(path) }
        }
        return out
    }

    /// argv процесса из KERN_PROCARGS2: argc, путь программы, нули выравнивания, затем argc строк.
    /// Первым элементом идет путь программы, чтобы узнать codex и тогда, когда argv[0] у него node.
    nonisolated static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let data = buffer.prefix(size)
        let argc = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = data.startIndex + 4
        func next() -> String? {
            while index < data.endIndex, data[index] == 0 { index += 1 }
            guard index < data.endIndex else { return nil }
            let end = data[index...].firstIndex(of: 0) ?? data.endIndex
            defer { index = end }
            return String(decoding: data[index..<end], as: UTF8.self)
        }
        guard let exec = next() else { return nil }
        var out = [exec]
        for _ in 0..<max(0, Int(argc)) {
            guard let arg = next() else { break }
            out.append(arg)
        }
        return out
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
