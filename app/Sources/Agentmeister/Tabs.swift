import AppKit
import Darwin
import Quartz
import SwiftTerm
import UniformTypeIdentifiers

/// Что запустить во вкладке. agentmeister сам поднимает proxy, sandbox-exec и агента, как во вкладке iTerm2.
struct LaunchSpec: Hashable {
    enum Agent: String, CaseIterable { case claude, codex }

    var projectName: String
    var projectPath: String
    var agent: Agent = .claude
    var direct = false
    /// Подписка proxy, только через которую идет вкладка (agentmeister -x <имя>). Nil значит каскад по всем.
    var subscription: String? = nil
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
    /// Служебная команда запускается как есть, без agentmeister впереди: вход напрямую из диалога входа.
    var bare = false
    /// Вход из диалога входа: страницу, которую агент открывает сам, BROWSER всегда отдает приложению,
    /// а диалог открывает ее там, где выбрано. Маршрут при этом любой.
    var signInDialog = false
    /// Вкладка агента, чьей подзадачей открыта эта: параллельная задача в своем worktree. Подзадачи показываются
    /// рядом под вкладкой агента, а не в общей полосе.
    var parent: UUID?
    /// Вкладка терминала без агента: shell входа в папке проекта. Через proxy это agentmeister proxy run в строгой
    /// песочнице, как у Codex: сеть только через mihomo и сокет ssh-agent, напрямую не уходит ничего. git по ssh
    /// идет через mihomo (GIT_SSH_COMMAND). Напрямую это сам shell. Собирает ее LaunchSpec.terminal.
    var terminal = false
    /// Только демо для скриншотов: вместо агента вкладка печатает этот файл.
    var demoScreen: String?

    var codexSession: Bool { agent == .codex && utility == nil && !terminal }
    var claudeSession: Bool { agent == .claude && utility == nil && !terminal }

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
        args += [projectPath, "-n", direct ? "-d" : subscription.map { "--proxy=" + $0 } ?? "-x"]
        // флаги после -- agentmeister передает самому агенту
        var agentArgs: [String] = resumeId == nil ? extraFlags : []
        if remoteControl && agent == .claude { agentArgs += ["--remote-control", projectName] }
        // флаги запуска по умолчанию из настроек агента
        agentArgs = AgentPrefs.flags(agent) + agentArgs
        if codexSession && TerminalPrefs.codexHistory && !agentArgs.contains("--no-alt-screen") {
            agentArgs.insert("--no-alt-screen", at: 0)
        }
        if let id = resumeId, agent == .claude {
            // запрос после продолжения: перезапуск после /slim так сразу выполняет /compact
            let prompt = firstPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            args += ["--", "--resume", id] + agentArgs + (prompt.isEmpty ? [] : [prompt])
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
    /// state: подписка по умолчанию из Настроек. Если там выбрана одна подписка, продолжение идет только
    /// через нее, а не по очереди: какой подписка была у сессии раньше, сохраненная переписка не помнит.
    static func resume(_ id: String, cwd: String?, project: AppState.Project, agent: Agent = .claude,
                       state: AppState? = nil) -> LaunchSpec {
        var isDir: ObjCBool = false
        let path = cwd.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue ? $0 : nil } ?? project.path
        return LaunchSpec(projectName: project.name, projectPath: path, agent: agent, subscription: state?.defaultSubscription,
                          resumeId: id)
    }

    /// Продолжить сохраненную сессию любого агента.
    static func resume(_ session: AppState.Session, project: AppState.Project, state: AppState? = nil) -> LaunchSpec {
        resume(session.id, cwd: session.cwd, project: project, agent: session.kind, state: state)
    }

    /// Новая сессия в один клик: агент и маршрут по умолчанию из настроек.
    @MainActor
    /// Вкладка терминала в папке path. Без настроенного proxy только напрямую. command выполняется первым в
    /// интерактивном shell (с алиасами из .zshrc), потом вкладка остается в обычном shell входа.
    static func terminal(name: String, path: String, direct: Bool, command: String = "",
                         subscription: String? = nil) -> LaunchSpec {
        var spec = LaunchSpec(projectName: name, projectPath: path, direct: direct, subscription: direct ? nil : subscription)
        spec.terminal = true
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        var shell = [loginShell, "-l"]
        if !command.isEmpty { shell += ["-i", "-c", command + "\nexec " + loginShell + " -l"] }
        if direct {
            spec.utility = shell
            spec.bare = true
        } else {
            spec.utility = ["proxy", "run"] + (spec.subscription.map { ["--via", $0] } ?? []) + ["--"] + shell
        }
        return spec
    }

    /// Shell входа пользователя из его записи в системе, как у Terminal. Приложение из Finder может не знать SHELL.
    static var loginShell: String {
        if let pw = getpwuid(getuid()), let raw = pw.pointee.pw_shell {
            let shell = String(cString: raw)
            if shell.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        return "/bin/zsh"
    }

    static func quick(_ project: AppState.Project, state: AppState) -> LaunchSpec {
        LaunchSpec(projectName: project.name, projectPath: project.path,
                   agent: AgentPrefs.defaultAgent == "codex" ? .codex : .claude, direct: state.proxy?.defaultRoute == "direct",
                   subscription: state.defaultSubscription)
    }

    /// Маршрут для подписи: через что вкладка выходит сейчас. Только через одну подписку это "proxy home SE",
    /// по очереди "proxy main KZ" (подписка, на которой каскад сейчас, и ее страна), с одной подпиской "proxy GE".
    /// Напрямую это "напрямую".
    func routeLabel(_ l: L, proxy: AppState.Proxy? = nil) -> String {
        guard proxied else { return l.direct }
        let subs = proxy?.subscriptions ?? []
        if proxy?.isBlocked(subscription) == true {
            return ([l.proxy, subscription, l.t("закрыто", "closed")].compactMap { $0 }).joined(separator: " ")
        }
        let name = subscription ?? (subs.count > 1 ? proxy?.current : nil)
        let exit = name.flatMap { n in subs.first { $0.name == n }?.exit } ?? (subscription == nil ? proxy?.exit : nil)
        return ([l.proxy, name, exit].compactMap { $0 }).joined(separator: " ")
    }
}

/// Одна вкладка: терминал SwiftTerm и процесс в нем.
@MainActor
final class TerminalTab: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    /// Id вкладки переживает перезапуск приложения (tabs.json): по нему клик по старому уведомлению находит
    /// вкладку, и AGENTMEISTER_TAB у идущего агента остается верным.
    let id: UUID
    @Published var spec: LaunchSpec
    /// Фоновые агенты внутри сессии вкладки, идущие и недавно законченные. Обновляет ряд подзадач.
    @Published var agents: [SubAgent] = []
    /// Фоновые команды сессии (Bash в фоне), идущие и недавно законченные. Тоже в ряду подзадач.
    @Published var shells: [BackgroundShell] = []
    /// Закрепленный запрос над терминалом (Prompts.swift) и то, из чего он посчитан.
    @Published var sticky: StickyPrompt?
    /// Все запросы вкладки для списка и меток на полосе прокрутки: из переписки и из вывода.
    @Published var promptEntries: [PromptEntry] = []
    let promptIndex = PromptIndex()
    @Published var promptScan: PromptScan?
    @Published var title: String
    @Published var running = true
    @Published var exitCode: Int32?
    /// Сессия Claude Code (или тред Codex) в этой вкладке и ее статус из реестра Claude Code (waiting, busy, idle).
    /// У Codex статуса нет, а id треда находит Workspace.trackCodexThreads.
    @Published var sessionId: String?
    @Published var status: String?
    /// Сессия сейчас подключена к Remote Control: в реестре Claude Code у нее есть bridgeSessionId.
    /// spec.remoteControl это настройка запуска, а это то, что идет на самом деле.
    @Published var remoteConnected = false
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
    @Published var downloadedImage: URL?
    let view: AppTerminalView

    init(spec: LaunchSpec, id: UUID? = nil) {
        self.id = id ?? UUID()
        self.spec = spec
        self.title = spec.terminal ? (LaunchSpec.loginShell as NSString).lastPathComponent
            : spec.utility.map { (spec.bare ? "" : "agentmeister ") + $0.joined(separator: " ") } ?? spec.projectName
        self.sessionId = spec.resumeId
        view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        super.init()
        view.tab = self
        view.processDelegate = self
        view.registerForDraggedTypes([.fileURL])
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
                    "LC_TERMINAL", "LC_TERMINAL_VERSION", "COLORFGBG", "TMUX", "TMUX_PANE", "STY",
                    "ZELLIJ", "ZELLIJ_SESSION_NAME", "ZELLIJ_VERSION",
                    "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy", "NO_PROXY", "no_proxy",
                    "MNRH_PROXY", "MNRH_PROXY_SUB", "PROMPTSILL_PROXY_LABEL", "PROMPTSILL_PROXY_DETAIL", "PROMPTSILL_PROXY_URL", "PROMPTSILL_PROXY_FILE"]
        for key in drop { env.removeValue(forKey: key) }
        for key in env.keys where key.hasPrefix("CLAUDECODE") || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CODEX_") {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // Codex 0.172 selects inline graphics by a substring in TERM_PROGRAM. SwiftTerm renders Kitty placements.
        env["TERM_PROGRAM"] = spec.codexSession ? "Agentmeister (Kitty graphics)" : "Agentmeister"
        env["MNRH_ICONS"] = "emoji"
        env["FORCE_HYPERLINK"] = "1"
        // хук уведомлений узнает по нему вкладку: клик открывает ее, а если она впереди, уведомления нет
        env["AGENTMEISTER_TAB"] = tab.uuidString.lowercased()
        // классический режим Claude Code: переписка в прокрутке терминала, ⌘F по ней ищет (Settings > Terminal)
        if spec.agent == .claude && TerminalPrefs.classicRenderer { env["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] = "1" }
        // ⌘⇧T: Ctrl+G открывает строку ввода в EDITOR (у Claude Code и у Codex), а он переводит ее и сразу
        // выходит. Свой редактор пользователя остается в AGENTMEISTER_EDITOR, обычный Ctrl+G открывает его
        if spec.claudeSession || spec.codexSession, let editor = LoginEnvironment.translateEditor, !editor.contains(" ") {
            env["AGENTMEISTER_EDITOR"] = env["VISUAL"] ?? env["EDITOR"] ?? "vi"
            env["VISUAL"] = editor
            env["EDITOR"] = editor
        }
        if let job = LoginEnvironment.restartJob {
            // тот же признак, что ставит restart.zsh: claude_restart пишет задание для хука, а не ищет вкладку iTerm2
            env["MNRH_RESTART_HOOK"] = "2"
            env["MNRH_RESTART_JOB"] = job
        }
        // терминал через proxy: в строгой песочнице прямой ssh закрыт, git ходит по ssh через CONNECT mihomo.
        // MNRH_PROXY с портом ставит proxy run, git раскрывает переменную, когда запускает команду через sh
        // Свой GIT_SSH_COMMAND пользователя (ssh -i ключ, -F конфиг) остается, к нему добавляется только ProxyCommand.
        // Обертку не на ssh так не дополнить, тогда работает только наш вариант.
        if spec.terminal && spec.proxied {
            let viaProxy = "ssh -o ProxyCommand='/usr/bin/nc -X connect -x 127.0.0.1:$MNRH_PROXY %h %p'"
            let own = env["GIT_SSH_COMMAND"]?.trimmingCharacters(in: .whitespaces) ?? ""
            if own == "ssh" || own.hasPrefix("ssh ") {
                env["GIT_SSH_COMMAND"] = viaProxy + own.dropFirst(3)
            } else {
                env["GIT_SSH_COMMAND"] = viaProxy
            }
        }
        // страницы, которые агент открывает сам (вход, OAuth для MCP), идут во встроенный браузер через тот же proxy
        env.removeValue(forKey: "BROWSER")
        if (spec.proxied && BrowserSettings.forAgent) || spec.signInDialog, let helper = ProxyBrowser.helper {
            env["BROWSER"] = helper
        }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// После agentmeister вкладка выполняет задания перезапуска, как хук share/agentmeister/restart.zsh в iTerm2.
    /// /restart, /forget, /fresh и /slim кладут задание в ~/.cache/mnrh/restart/<tty>, restart_job.py take
    /// проверяет его поля, run строит argv сам. Без этого цикла вкладке после выхода Claude некуда вернуться.
    static let shellScript = """
    export MNRH_TTY=${TTY:-$(tty)}
    "$0" "$@"
    j=${MNRH_RESTART_JOB:-}
    [[ -n $j && -f $j ]] || exit
    t=${TTY:-$(tty)}
    f=$HOME/.cache/mnrh/restart/${t:t}
    while [[ -e $f || -L $f ]]; do
      out=$(/usr/bin/python3 -I -B $j take $f) || break
      job=( "${(@0)out}" )
      (( $#job == 3 )) || break
      cd -- $job[1] || break
      /usr/bin/python3 -I -B $j run $job[3]
    done
    """

    func start() {
        restarting = false
        guard !closed else { return }
        exitCode = nil
        running = true
        status = nil
        startedAt = Date()
        if let screen = spec.demoScreen {
            view.startProcess(executable: "/bin/sh", args: ["-c", "cat \"$0\"; exec sleep 86400", screen],
                              environment: ["TERM=xterm-256color", "LANG=en_US.UTF-8"], execName: "sh",
                              currentDirectory: NSHomeDirectory())
            return
        }
        // "$0" в shellScript: agentmeister или, у вкладки bare, сама команда
        let program = spec.bare ? spec.arguments.first ?? "true" : LoginEnvironment.agentmeister
        let args = ["-l", "-c", Self.shellScript, program] + (spec.bare ? Array(spec.arguments.dropFirst()) : spec.arguments)
        view.startProcess(executable: "/bin/zsh", args: args, environment: Self.environment(tab: id, spec: spec), execName: "-zsh",
                          currentDirectory: FileManager.default.fileExists(atPath: spec.projectPath) ? spec.projectPath : NSHomeDirectory())
        updateAwake()
        if spec.proxied { Backend.main?.proxiedTabStarted() }
    }

    /// Включить или выключить "не спать" прямо в идущей сессии, без перезапуска.
    // MARK: Поиск по выводу

    /// Своя панель поиска над терминалом (у SwiftTerm панель закрытая и без счетчика): открыта ли, что ищем,
    /// параметры и место текущего совпадения среди всех.
    @Published var finding = false
    @Published var findTerm = ""
    @Published var findOptions = SearchOptions()
    @Published var findPosition: (index: Int, total: Int) = (0, 0)
    /// Растет, когда полю поиска нужно снова взять фокус (⌘F при уже открытой панели).
    @Published var findFocus = 0

    /// Действия меню Правка: ⌘F, ⌘G, ⇧⌘G, ⌘E.
    func find(_ action: NSTextFinder.Action) {
        switch action {
        case .showFindInterface:
            // при открытой панели выделено само совпадение: ⌘F только возвращает фокус полю и не трогает поиск
            if finding {
                findFocus += 1
                return
            }
            if let selected = view.getSelection(), !selected.isEmpty, !selected.contains("\n") {
                findTerm = selected
            } else if findTerm.isEmpty, let last = NSPasteboard(name: .find).string(forType: .string) {
                findTerm = last
            }
            finding = true
            findFocus += 1
            restartSearch()
        case .nextMatch:
            step(forward: true)
        case .previousMatch:
            step(forward: false)
        case .setSearchString:
            guard let selected = view.getSelection(), !selected.isEmpty else { return }
            findTerm = selected
            remember(selected)
            restartSearch()
        case .hideFindInterface:
            closeFind()
        default:
            break
        }
    }

    /// Искать заново с начала: поменялся текст или параметры.
    func restartSearch() {
        view.clearSearch()
        guard !findTerm.isEmpty else {
            findPosition = (0, 0)
            return
        }
        // с конца: ближе всего к свежему выводу, а не к началу прокрутки на тысячи строк вверх
        view.findPrevious(findTerm, options: findOptions)
        findPosition = view.searchMatchSummary(findTerm, options: findOptions)
    }

    /// К следующему или предыдущему совпадению. Без текста в панели берет последний искомый, как ⌘G в macOS.
    func step(forward: Bool) {
        if findTerm.isEmpty, let last = NSPasteboard(name: .find).string(forType: .string) { findTerm = last }
        guard !findTerm.isEmpty else { return }
        if forward { view.findNext(findTerm, options: findOptions) } else { view.findPrevious(findTerm, options: findOptions) }
        findPosition = view.searchMatchSummary(findTerm, options: findOptions)
        remember(findTerm)
    }

    func closeFind() {
        if !findTerm.isEmpty { remember(findTerm) }
        finding = false
        view.clearSearch()
        findPosition = (0, 0)
        view.window?.makeFirstResponder(view)
    }

    /// Общий для приложений буфер поиска macOS: ⌘G в другом окне найдет то же.
    private func remember(_ term: String) {
        let board = NSPasteboard(name: .find)
        board.clearContents()
        board.setString(term, forType: .string)
    }

    func setAwake(_ on: Bool) {
        spec.awake = on
        updateAwake()
        // tabs.json пишется по изменению списка вкладок, а это изменение внутри вкладки
        Workspace.main?.save()
    }

    /// Включить или выключить Remote Control. Настройка сохраняется для следующих запусков, а идущую сессию
    /// Claude Code вкладка подключает или отключает командой /remote-control, если ее можно вписать, ничего не
    /// испортив (promptReady). При выключении Claude Code открывает свою панель Remote Control, где фокус стоит
    /// на Continue: отключает в ней сам человек. false значит, что вписать команду нельзя и идущая сессия
    /// осталась как была: тогда спросить, перезапустить ли ее сейчас.
    @discardableResult
    func setRemoteControl(_ on: Bool) -> Bool {
        spec.remoteControl = on
        // tabs.json пишется по изменению списка вкладок, а это изменение внутри вкладки
        Workspace.main?.save()
        guard running, spec.agent == .claude, spec.utility == nil, remoteConnected != on else { return true }
        guard promptReady else { return false }
        // имя то же, что у --remote-control при запуске
        submit(on ? "/remote-control " + spec.projectName : "/remote-control")
        view.window?.makeFirstResponder(view)
        return true
    }

    /// Можно ли вписать /remote-control в идущий Claude Code и нажать Enter. Claude Code не ждет ответа в
    /// диалоге: статус idle или busy (эта команда выполняется и посреди ответа, не прерывая и не дожидаясь его).
    /// И строка ввода пуста, иначе команда дописалась бы к черновику и Enter отправил бы его.
    var promptReady: Bool {
        guard running, status == "idle" || status == "busy",
              let screen = view.terminalContentSnapshot(region: .history(maximumScrollbackRows: -1)) else { return false }
        return Self.promptEmpty(screen)
    }

    /// Пуста ли строка ввода Claude Code на живом экране. Это последняя строка, которая начинается с "❯" без
    /// подложки (запросы в прокрутке на подложке). После "❯" может стоять только серая подсказка (Try "..."),
    /// курсор терминала стоит сразу за "❯ ", а до черты под полем ввода нет строк с текстом. "❯" у пункта
    /// списка в диалоге стоит перед обычным текстом, такой экран пустым не считается.
    nonisolated static func promptEmpty(_ screen: TerminalContentSnapshot) -> Bool {
        func blank(_ cell: TerminalCellSnapshot) -> Bool { cell.isBlank || cell.text.allSatisfy(\.isWhitespace) }
        let rows = screen.rows
        for index in rows.indices.reversed() {
            let row = rows[index]
            guard let first = row.cells.firstIndex(where: { !blank($0) }), row.cells[first].text == "❯" else { continue }
            let bg = row.cells[first].attribute.bg
            guard bg == .defaultColor || bg == .defaultInvertedColor,
                  screen.cursorRow == row.absoluteRow, screen.cursorColumn == first + 2,
                  row.cells[(first + 1)...].allSatisfy({ blank($0) || $0.attribute.style.contains(.dim) }) else { return false }
            for below in rows[(index + 1)...] {
                guard let start = below.cells.firstIndex(where: { !blank($0) }) else { continue }
                return below.cells[start].text == "─"
            }
            return true
        }
        return false
    }

    private func updateAwake() {
        caffeinate?.terminate()
        caffeinate = nil
        guard spec.awake, running, shellPid > 0 else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -is, как у agentmeister -k: Mac не спит и от простоя, и от сети. Сторож lid узнает такой caffeinate
        // по родителю-приложению и держит Mac и с закрытой крышкой, если режим lid включен
        task.arguments = ["-is", "-w", String(shellPid)]
        if (try? task.run()) != nil {
            caffeinate = task
            Task.detached(priority: .utility) { _ = Backend.run(["lid", "keep"]) }
        }
    }

    /// Команда оболочки для обновления агента. agentmeister agent-update берет brew upgrade для установки из Homebrew
    /// и claude update или codex update для остальных, последней строкой печатает итог. Через proxy
    /// (agentmeister proxy run), если не сказано идти напрямую: скачивание не должно уходить мимо mihomo.
    /// tail: false отдает весь вывод, а код выхода остается кодом обновления, а не tail.
    nonisolated static func updateCommand(direct: Bool, agent: LaunchSpec.Agent = .claude, tail: Bool = true,
                                          subscription: String? = nil) -> String {
        let am = "'" + LoginEnvironment.agentmeister.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let update = "\(am) agent-update \(agent == .codex ? "codex" : "claude")"
        // через mihomo, но без песочницы: brew upgrade распаковывает в своей песочнице macOS, а вложенную macOS не дает.
        // Имя подписки проверено при выборе: строчные латинские буквы, цифры и дефис, кавычки не нужны.
        let via = subscription.flatMap { $0.range(of: "^[a-z][a-z0-9-]{0,19}$", options: .regularExpression) != nil ? "--via \($0) " : nil } ?? ""
        let proxy = "\(am) proxy run --no-sandbox \(via)-- "
        return (direct ? update : proxy + update) + " 2>&1" + (tail ? " | tail -3" : "")
    }

    /// Команда оболочки для проверки новой версии агента (agentmeister agent-update --check), JSON в stdout.
    nonisolated static func checkCommand(direct: Bool, agent: LaunchSpec.Agent) -> String {
        let am = "'" + LoginEnvironment.agentmeister.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let check = "\(am) agent-update --check \(agent == .codex ? "codex" : "claude")"
        return (direct ? check : "\(am) proxy run --no-sandbox -- " + check) + " 2>/dev/null"
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
        // пока агент выходит и обновляется, терминалом не пользуются: плашка поверх него, клавиатура не у него
        updatingAgent = true
        view.window?.makeFirstResponder(nil)
        afterStop { self.updateThenRestart(note: note) }
    }

    /// Идет обновление агента перед перезапуском: вкладка показывает плашку и не принимает ввод.
    @Published var updatingAgent = false

    private func updateThenRestart(note: String) {
        view.feed(text: "\r\n\u{1b}[2m" + note + "\u{1b}[0m\r\n")
        updateFailed = nil
        let command = TerminalTab.updateCommand(direct: spec.direct, agent: .claude, tail: false, subscription: spec.subscription)
        Task.detached(priority: .userInitiated) {
            let (code, out) = Self.shell(command)
            // версия, на которой откроется сессия, если обновление не встало
            let version = code == 0 ? nil : Self.shell("claude --version").1.split(whereSeparator: \.isWhitespace)
                .map(String.init).first { $0.first?.isNumber == true }
            let lines = out.split(separator: "\n", omittingEmptySubsequences: true).suffix(3)
            await MainActor.run {
                self.updatingAgent = false
                guard !self.closed else { return }
                self.view.window?.makeFirstResponder(self.view)
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

    // MARK: Перевод строки ввода (⌘⇧T)

    /// Идет перевод строки ввода. Claude Code на это время уходит в редактор и стирает экран, поэтому внутри
    /// терминала лежит его снимок, сделанный до Ctrl+G (AppTerminalView.freeze), а поверх карточка перевода.
    struct InputTranslation {
        enum Issue: Equatable {
            case notOpened, timeout, cancelled
            case failed(String)
        }
        let started = Date()
        var model: String?
        var provider: String?
        /// Текст строки ввода и перевод: карточка показывает, как один складывается в другой.
        var original: String?
        var english: String?
        var issue: Issue?
        var done = false
        var doneAt: Date?
    }
    @Published var inputTranslation: InputTranslation?
    /// ⌘⇧T без ключа переводчика: во вкладке карточка с полем для ключа (TranslateKeyCard).
    @Published var askingKey = false

    var canTranslateInput: Bool {
        (spec.claudeSession || spec.codexSession) && running && LoginEnvironment.translateEditor != nil && editorKey != nil
    }

    /// Чем агент открывает строку ввода во внешнем редакторе. Claude Code всегда Ctrl+G. Codex тоже, если клавишу
    /// не переназначили в ~/.codex/config.toml (open_external_editor), а переназначенную понимаем только ctrl-<буква>.
    var editorKey: String? {
        guard spec.codexSession else { return "\u{07}" }
        let home = LoginEnvironment.shared["CODEX_HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        let config = (try? String(contentsOfFile: (home as NSString).appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        return Self.codexEditorKey(config)
    }

    nonisolated static func codexEditorKey(_ config: String) -> String? {
        guard let match = config.firstMatch(of: #/(?m)^\s*open_external_editor\s*=\s*"([^"]*)"/#) else { return "\u{07}" }
        guard let letter = String(match.output.1).lowercased().wholeMatch(of: #/ctrl-([a-z])/#)?.output.1.unicodeScalars.first
        else { return nil }
        return String(UnicodeScalar(UInt8(letter.value - 96)))
    }

    private func editFile(_ suffix: String) -> String {
        (Workspace.translateDir as NSString).appendingPathComponent("edit-" + id.uuidString.lowercased() + suffix)
    }

    /// Запрос для редактора editor/agentmeister, снимок терминала и Ctrl+G. Редактор переводит файл со строкой ввода
    /// и пишет ход работы в edit-<вкладка>.status.json.
    func translateInput() {
        guard canTranslateInput, inputTranslation == nil else {
            NSSound.beep()
            return
        }
        guard TranslateKey.saved else {
            askingKey = true
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Workspace.translateDir, withIntermediateDirectories: true)
        for suffix in [".status.json", ".cancel"] { try? fm.removeItem(atPath: editFile(suffix)) }
        guard fm.createFile(atPath: editFile(".json"), contents: Data("{}".utf8)) else {
            NSSound.beep()
            return
        }
        view.freeze()
        inputTranslation = InputTranslation()
        view.send(txt: editorKey ?? "\u{07}")
        watchInputTranslation(since: Date(), cancelSent: false)
    }

    /// Esc во время перевода: редактор выйдет, не трогая текст.
    func cancelInputTranslation() {
        guard inputTranslation?.done == false else { return }
        FileManager.default.createFile(atPath: editFile(".cancel"), contents: nil)
    }

    private func watchInputTranslation(since start: Date, cancelSent: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, var current = self.inputTranslation, !current.done else { return }
            let fm = FileManager.default
            let elapsed = Date().timeIntervalSince(start)
            // запрос так и лежит: Ctrl+G не открыл редактор, например на экране диалог или меню
            if elapsed > 1.5, fm.fileExists(atPath: self.editFile(".json")) {
                try? fm.removeItem(atPath: self.editFile(".json"))
                self.finishInputTranslation(.notOpened, redraw: false)
                return
            }
            if let data = fm.contents(atPath: self.editFile(".status.json")),
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if o["state"] as? String == "done" {
                    let issue: InputTranslation.Issue? = o["ok"] as? Bool == true ? nil
                        : o["cancelled"] as? Bool == true ? .cancelled : .failed(o["error"] as? String ?? "")
                    self.inputTranslation?.english = o["english"] as? String
                    self.finishInputTranslation(issue, redraw: true)
                    return
                }
                if current.model == nil, let model = o["model"] as? String {
                    current.model = model
                    current.provider = o["provider"] as? String
                    current.original = o["text"] as? String
                    self.inputTranslation = current
                }
            }
            var cancelSent = cancelSent
            if elapsed > 20, !cancelSent {
                self.cancelInputTranslation()
                cancelSent = true
            }
            if elapsed > 25 {
                self.finishInputTranslation(.timeout, redraw: true)
                return
            }
            self.watchInputTranslation(since: start, cancelSent: cancelSent)
        }
    }

    /// Снимок снимается, когда Claude Code вернулся из редактора и перерисовал экран, а карточка дописала
    /// перевод. Ошибку карточка показывает еще немного.
    private func finishInputTranslation(_ issue: InputTranslation.Issue?, redraw: Bool) {
        guard var current = inputTranslation else { return }
        current.done = true
        current.doneAt = Date()
        current.issue = issue
        inputTranslation = current
        for suffix in [".status.json", ".cancel"] { try? FileManager.default.removeItem(atPath: editFile(suffix)) }
        let wait = issue == nil ? (current.english == nil ? 0.3 : InputTranslationOverlay.reveal + 0.15)
            : issue == .cancelled ? (redraw ? 0.3 : 0) : (redraw ? 0.3 : 0) + 1.6
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            // снимок уходит сразу, без растворения: под ним уже тот же экран, только с переводом
            self?.view.unfreeze()
            self?.inputTranslation = nil
        }
    }

    /// Та же сессия через proxy, но через другую подписку: nil значит по очереди по всем.
    func switchSubscription(_ name: String?) {
        afterStop {
            self.spec.direct = false
            self.spec.subscription = name
            Workspace.main?.save()
            self.relaunch()
        }
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
    /// then: первый запрос сессии после сжатия, например /compact, чтобы сжать и сам разговор.
    func slim(note: String, then prompt: String = "") {
        guard let sid = sessionId, spec.agent == .claude else { return }
        whileStopped(note, ["sessions", "slim", sid, "-y"]) { _ in self.relaunch(prompt: prompt) }
    }

    /// Вписать команду агенту и отправить ее, как будто ее набрали и нажали Enter.
    func submit(_ text: String) {
        view.send(txt: text + "\r")
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
    private func relaunch(prompt: String = "") {
        if let sid = sessionId, spec.utility == nil {
            spec.resumeId = sid
            spec.firstPrompt = prompt
        }
        start()
        // запрос нужен один раз: иначе восстановленная после перезапуска приложения вкладка повторила бы его
        if !prompt.isEmpty { spec.firstPrompt = "" }
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
        let key = ShortcutStore.shared.label(.restart)
        view.feed(text: "\r\n\u{1b}[2m[exit \(code)" + (exitHint && !key.isEmpty ? ". " + key : "") + "]\u{1b}[0m\r\n")
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
        /// Подписка proxy вкладки. Nil у каскада и в tabs.json старых версий.
        var subscription: String?
        var sessionId: String?
        var selected: Bool
        var awake: Bool?
        var remoteControl: Bool?
        /// Id вкладки. Nil в tabs.json старых версий.
        var id: String?
        /// Id вкладки агента, если это его подзадача.
        var parent: String?
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
                     direct: $0.spec.direct, subscription: $0.spec.subscription, sessionId: $0.sessionId,
                     selected: $0.id == selected,
                     awake: $0.spec.awake, remoteControl: $0.spec.remoteControl, id: $0.id.uuidString.lowercased(),
                     parent: $0.spec.parent?.uuidString.lowercased())
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
        if Demo.active {
            guard tabs.isEmpty else { return }
            // вкладки демо из tabs.json папки демо; restored не ставится, поэтому save() ничего не пишет
            for item in Demo.tabs() {
                var spec = LaunchSpec(projectName: item.project, projectPath: item.path,
                                      agent: LaunchSpec.Agent(rawValue: item.agent ?? "") ?? .claude,
                                      direct: item.direct ?? false, subscription: item.subscription)
                spec.terminal = item.terminal ?? false
                spec.remoteControl = item.remoteControl ?? false
                if spec.terminal { spec.utility = ["proxy", "run", "--", "zsh"] }
                spec.demoScreen = Demo.screenPath(item.screen)
                open(spec, select: item.selected ?? false)
            }
            return
        }
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
            var spec = LaunchSpec(projectName: item.projectName, projectPath: item.projectPath, agent: agent, direct: item.direct,
                                  subscription: item.subscription)
            spec.awake = item.awake ?? false
            spec.remoteControl = item.remoteControl ?? false
            spec.parent = item.parent.flatMap(UUID.init(uuidString:))
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

    /// select: false оставляет выбранной нынешнюю вкладку. Так открываются вкладки, которые попросил агент.
    func open(_ spec: LaunchSpec, select: Bool = true) {
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
        var spec = spec
        // у подзадачи подзадач нет: новая встает к тому же агенту
        spec.parent = spec.parent.flatMap { id in tabs.first { $0.id == id } }.map { root(of: $0).id }
        let tab = TerminalTab(spec: spec)
        // подзадача встает за последней подзадачей своего агента, так соседние вкладки по ⌃Tab идут подряд
        if let parent = spec.parent, let last = tabs.lastIndex(where: { $0.id == parent || $0.spec.parent == parent }) {
            tabs.insert(tab, at: last + 1)
        } else {
            tabs.append(tab)
        }
        if select || selected == nil { selected = tab.id }
    }

    /// Вкладка терминала. Маршрут через proxy, только если proxy настроен.
    func openTerminal(name: String, path: String, direct: Bool, state: AppState, command: String = "",
                      subscription: String? = nil) {
        open(.terminal(name: name, path: path, direct: direct || state.proxy?.configured != true, command: command,
                       subscription: subscription))
    }

    /// Терминал в папке текущей вкладки и с ее маршрутом. Без вкладок в домашней папке с маршрутом по умолчанию.
    func openTerminalHere(state: AppState) {
        if let spec = current?.spec {
            openTerminal(name: spec.projectName, path: spec.projectPath, direct: !spec.proxied, state: state,
                         subscription: spec.subscription)
        } else {
            let home = NSHomeDirectory()
            openTerminal(name: (home as NSString).lastPathComponent, path: home,
                         direct: state.proxy?.defaultRoute == "direct", state: state, subscription: state.defaultSubscription)
        }
    }

    // MARK: Подзадачи

    /// Агент вкладки: та, чьей подзадачей она открыта, если она еще открыта, иначе сама вкладка.
    func root(of tab: TerminalTab) -> TerminalTab {
        guard let id = tab.spec.parent, let parent = tabs.first(where: { $0.id == id }) else { return tab }
        return parent
    }

    /// Вкладки общей полосы: агенты без подзадач.
    var roots: [TerminalTab] { tabs.filter { root(of: $0) === $0 } }

    func subtasks(of tab: TerminalTab) -> [TerminalTab] { tabs.filter { $0.spec.parent == tab.id } }

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

    /// Проекты для боковой панели и рельсы: сверху проекты с вкладками в порядке вкладок, за ними проекты,
    /// открытые в других окнах, затем остальные. Смена статуса (работает, ждет ответа) проекты не
    /// переставляет, двигают открытие, закрытие и перетаскивание вкладок.
    func sidebarProjects(_ state: AppState) -> [AppState.Project] {
        let (open, others) = openSessions(state)
        var order: [String] = []
        let add = { (path: String?) in
            if let p = path.flatMap({ state.project(containing: $0)?.path }), !order.contains(p) { order.append(p) }
        }
        // сначала агенты общей полосы, потом подзадачи: проект встает туда, где его вкладка в полосе
        let openRoots = roots.filter { tab in open.contains { $0 === tab } }
        for tab in openRoots { add(tab.spec.projectPath) }
        for tab in open { add(tab.spec.projectPath) }
        let elsewhere = Set(others.compactMap { $0.cwd.flatMap { state.project(containing: $0)?.path } })
        for p in state.projects where elsewhere.contains(p.path) { add(p.path) }
        if order.isEmpty { return state.projects }
        let byPath = Dictionary(state.projects.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return order.compactMap { byPath[$0] } + state.projects.filter { !order.contains($0.path) }
    }

    /// Есть ли у проекта вкладки в этом окне: только такие проекты можно переставлять.
    func hasTabs(in project: AppState.Project, state: AppState) -> Bool {
        roots.contains { state.project(containing: $0.spec.projectPath)?.path == project.path }
    }

    /// Переставить вкладку общей полосы на место другой: правее цели при движении вправо, левее при движении
    /// влево. Подзадачи остаются в своем ряду под агентом.
    func move(_ id: UUID, to target: UUID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        var next = tabs
        let tab = next.remove(at: from)
        next.insert(tab, at: min(to, next.count))
        tabs = next
    }

    /// Переставить проект в рельсе и боковой панели. Их порядок повторяет порядок вкладок, поэтому
    /// двигаются сами вкладки: все вкладки проекта встают вместе на место вкладок проекта-цели.
    /// Проект без вкладок в этом окне не двигается.
    func moveProject(_ path: String, to target: String, state: AppState) {
        guard path != target else { return }
        let key = { (tab: TerminalTab) in state.project(containing: tab.spec.projectPath)?.path ?? tab.spec.projectPath }
        let rootTabs = roots
        var groups: [(path: String, tabs: [TerminalTab])] = []
        for tab in rootTabs {
            let k = key(tab)
            if let i = groups.firstIndex(where: { $0.path == k }) { groups[i].tabs.append(tab) } else { groups.append((k, [tab])) }
        }
        guard let from = groups.firstIndex(where: { $0.path == path }),
              let to = groups.firstIndex(where: { $0.path == target }) else { return }
        let group = groups.remove(at: from)
        groups.insert(group, at: min(to, groups.count))
        let rest = tabs.filter { tab in !rootTabs.contains { $0 === tab } }
        tabs = groups.flatMap(\.tabs) + rest
    }

    /// Новая вкладка в проекте текущей: новая сессия с тем же агентом и маршрутом, у терминала еще один терминал.
    /// Без вкладок ничего не делает.
    @discardableResult
    func newTab() -> Bool {
        guard var spec = current?.spec, spec.utility == nil || spec.terminal else { return false }
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
        // подзадачи закрытого агента остаются и встают в общую полосу
        for child in tabs where child.spec.parent == id { child.spec.parent = nil }
        let parent = tabs[index].spec.parent.flatMap { p in tabs.first { $0.id == p } }
        tabs[index].terminate()
        tabs.remove(at: index)
        // после закрытой подзадачи выбран ее агент
        selected = parent?.id ?? (tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id)
    }

    /// Соседняя вкладка по кругу: 1 следующая, -1 предыдущая.
    func selectNeighbor(_ step: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == selected } ?? 0
        selected = tabs[(index + step + tabs.count) % tabs.count].id
        current?.rang = false
    }

    /// ⌘1…9 считает вкладки общей полосы, подзадачи в счет не идут.
    func select(number: Int) {
        let roots = roots
        guard number >= 1, number <= roots.count else { return }
        selected = roots[number - 1].id
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
                let connected = match.bridgeSessionId != nil
                if tab.remoteConnected != connected { tab.remoteConnected = connected }
            } else {
                if tab.status != nil { tab.status = nil }
                if tab.remoteConnected { tab.remoteConnected = false }
            }
        }
        DockAttention.update(waiting: tabs.filter { $0.running && $0.status == "waiting" }.count)
    }

    /// Новая вкладка Claude Code в том же проекте и маршруте с контекстом треда Codex: /import-codex <id>.
    func moveToClaude(_ tab: TerminalTab) {
        guard tab.spec.agent == .codex, tab.spec.utility == nil, let sid = tab.sessionId else { return }
        var spec = LaunchSpec(projectName: tab.spec.projectName, projectPath: tab.spec.projectPath, direct: tab.spec.direct,
                              subscription: tab.spec.subscription)
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

    /// В демо своя папка: front.json, focus.json и запросы настоящего приложения демо не трогает.
    static let appDir = Demo.active ? (NSTemporaryDirectory() as NSString).appendingPathComponent("agentmeister-demo-app")
        : (NSHomeDirectory() as NSString).appendingPathComponent(".cache/mnrh/app")
    static let frontFile = (appDir as NSString).appendingPathComponent("front.json")
    static let focusFile = (appDir as NSString).appendingPathComponent("focus.json")
    /// Обмен с редактором editor/agentmeister при переводе строки ввода: edit-<вкладка>.json, .status.json и .cancel.
    static let translateDir = (appDir as NSString).appendingPathComponent("translate")

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
                  let project = state.project(containing: saved.cwd) {
            // агент из сохраненной сессии: id треда Codex иначе ушел бы в claude --resume
            open(LaunchSpec.resume(saved, project: project, state: state))
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

    // MARK: Вкладки по просьбе агента

    static let openDir = (appDir as NSString).appendingPathComponent("open")
    /// Флаги claude, которые можно передать в запросе: форк разговора, продолжение и режим разрешений без
    /// обхода проверок. Остальное отклоняем, запрос может прийти от любой программы этого пользователя.
    private static let permissionModes: Set<String> = ["default", "acceptEdits", "auto", "plan"]

    /// Забрать запросы agentmeister open_claude и parallel из вкладок этого окна: open/<id>.json. На каждый
    /// пишем ответ <id>.reply.json, CLI ждет его несколько секунд, а без ответа открывает терминал как раньше.
    func takeOpenRequests(state: AppState) {
        guard restored, pendingRestore == nil else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.openDir) else { return }
        for name in names where name.hasSuffix(".json") && !name.hasSuffix(".reply.json") {
            let id = String(name.dropLast(5))
            let path = (Self.openDir as NSString).appendingPathComponent(name)
            guard id.range(of: Self.sessionPattern, options: .regularExpression) != nil,
                  let data = fm.contents(atPath: path) else { continue }
            try? fm.removeItem(atPath: path)
            var reply: [String: Any] = ["ok": false]
            switch openRequest(data, state: state) {
            case .success(let tab): reply = ["ok": true, "tab": tab.uuidString.lowercased()]
            case .failure(let error): reply["error"] = error.text
            }
            if let out = try? JSONSerialization.data(withJSONObject: reply) {
                try? out.write(to: URL(fileURLWithPath: (Self.openDir as NSString).appendingPathComponent(id + ".reply.json")), options: .atomic)
            }
        }
    }

    struct OpenRefusal: Error { let text: String }

    /// Запрос открыть вкладку. Он должен прийти из открытой вкладки этого окна (id в AGENTMEISTER_TAB), папка
    /// должна лежать в папке проектов, а маршрут всегда через proxy: иначе сессия из песочницы открыла бы себе
    /// сессию без нее.
    private func openRequest(_ data: Data, state: AppState) -> Result<UUID, OpenRefusal> {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = o["path"] as? String, !path.isEmpty else { return .failure(OpenRefusal(text: "bad request")) }
        if let at = o["at"] as? Double, Date().timeIntervalSince1970 - at > 30 { return .failure(OpenRefusal(text: "stale request")) }
        guard let from = (o["from"] as? String).flatMap(UUID.init(uuidString:)),
              let requester = tabs.first(where: { $0.id == from && $0.running }) else {
            return .failure(OpenRefusal(text: "the requesting tab isn't open in Agentmeister"))
        }
        let folder = (path as NSString).standardizingPath
        var isDir: ObjCBool = false
        let roots = (state.projectsDirs ?? [state.projectsDir]).filter { !$0.isEmpty }.map { ($0 as NSString).standardizingPath }
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue,
              roots.contains(where: { folder.hasPrefix($0 + "/") }) else {
            return .failure(OpenRefusal(text: "the folder isn't inside the projects folder"))
        }
        let flags = (o["flags"] as? [String]) ?? []
        var i = 0
        while i < flags.count {
            switch flags[i] {
            case "--fork-session", "--continue": i += 1
            case "--resume" where i + 1 < flags.count && flags[i + 1].range(of: Self.sessionPattern, options: .regularExpression) != nil: i += 2
            case "--permission-mode" where i + 1 < flags.count && Self.permissionModes.contains(flags[i + 1]): i += 2
            default: return .failure(OpenRefusal(text: "flag \(flags[i]) isn't allowed"))
            }
        }
        let name = (o["name"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } ?? (folder as NSString).lastPathComponent
        // через ту же подписку, что у вкладки, которая просит: из сессии только через home и подзадача только через home
        var spec = LaunchSpec(projectName: name, projectPath: folder, agent: .claude, direct: false,
                              subscription: requester.spec.proxied ? requester.spec.subscription : nil)
        spec.firstPrompt = (o["prompt"] as? String) ?? ""
        spec.extraFlags = flags
        spec.awake = (o["awake"] as? Bool) ?? false
        spec.remoteControl = (o["remote_control"] as? Bool) ?? false
        if o["subtask"] as? Bool == true { spec.parent = requester.id }
        open(spec, select: false)
        return tabs.last(where: { $0.spec.projectPath == folder }).map { .success($0.id) } ?? .failure(OpenRefusal(text: "the tab didn't open"))
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
    static let linkPlaceKey = "browserLinkPlace"
    /// Страницы, которые открывает агент во вкладке через proxy. По умолчанию включено.
    static var forAgent: Bool { UserDefaults.standard.object(forKey: forAgentKey) as? Bool ?? true }
    /// Где открыть ссылку, по которой кликнули во вкладке через proxy. По умолчанию спросить. До выбора места
    /// был переключатель browserForLinks, включенный значил встроенный браузер.
    static var linkPlace: LinkPlace {
        if let raw = UserDefaults.standard.string(forKey: linkPlaceKey), let place = LinkPlace(rawValue: raw) { return place }
        return UserDefaults.standard.bool(forKey: "browserForLinks") ? .builtin : .ask
    }
}

/// Ключ переводчика для ⌘⇧T: файл в ~/.config/mnrh, как его сохраняет agentmeister translate key, или переменная
/// окружения. Без ключа перевод не начнется, вместо этого во вкладке карточка с полем для ключа.
@MainActor
enum TranslateKey {
    static var saved: Bool {
        let env = LoginEnvironment.shared
        let config = env["XDG_CONFIG_HOME"].map { ($0 as NSString).appendingPathComponent("mnrh") }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/mnrh")
        let files = ["openrouter-key", "gemini-key"].map { (config as NSString).appendingPathComponent($0) }
        let inFile = files.contains { path in
            (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return inFile || ["OPENROUTER_API_KEY", "GEMINI_API_KEY"].contains { env[$0]?.isEmpty == false }
    }

    /// Чей ключ по виду, как key_provider в translate.py: nil, если не похож ни на один.
    nonisolated static func provider(_ key: String) -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.wholeMatch(of: #/sk-or-[A-Za-z0-9_-]{16,200}/#) != nil { return "OpenRouter" }
        if key.wholeMatch(of: #/(?:AIza[0-9A-Za-z_-]{30,60}|AQ\.[0-9A-Za-z_.-]{30,100})/#) != nil { return "Google AI Studio" }
        return nil
    }
}

/// Терминал вкладки. Отличается от SwiftTerm одним: ссылки http и https из вкладки через proxy может открыть
/// во встроенном браузере. Во вкладке входа так всегда, пока включен браузер для агента. В остальных вкладках
/// место берется из настройки, по умолчанию приложение спрашивает (LinkPlaceSheet).
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

    override func paste(_ sender: Any) {
        if tab?.inputTranslation != nil { return }
        if !pasteImage() { super.paste(sender) }
    }

    private var frozen: NSView?

    /// Положить снимок терминала поверх него самого, в те же границы, чтобы он совпадал с экраном до пикселя.
    /// Пока Claude Code переводит строку ввода в редакторе, видна вкладка, а не пустой экран редактора.
    func freeze() {
        guard frozen == nil, bounds.width > 0, bounds.height > 0,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        let view = NSImageView(frame: bounds)
        view.image = image
        // окно могут растянуть, пока идет перевод: снимок не тянется, а стоит в своем размере у верхнего левого
        // угла, остальное фон терминала. Через секунду-две Claude Code перерисует экран под новый размер
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignTopLeft
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        // фон терминала рисует контейнер, а не сам SwiftTerm, и снимок вне букв прозрачен. Без своего фона
        // сквозь него видно живой экран, когда Claude Code уже вернулся из редактора
        view.layer?.backgroundColor = nativeBackgroundColor.cgColor
        // чуть притушить, чтобы карточка читалась
        let dim = CALayer()
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        dim.frame = view.bounds
        dim.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(dim)
        addSubview(view)
        frozen = view
    }

    func unfreeze() {
        frozen?.removeFromSuperview()
        frozen = nil
    }

    static func handleImagePaste(_ event: NSEvent) -> NSEvent? {
        // во время перевода строки ввода клавиши во вкладку не идут, Esc отменяет перевод; сочетания с ⌘ работают
        if let view = event.window?.firstResponder as? AppTerminalView, let tab = view.tab, tab.inputTranslation != nil,
           !event.modifierFlags.contains(.command) {
            if event.keyCode == 53 { tab.cancelInputTranslation() }  // Esc
            return nil
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .control || modifiers == .command,
              event.characters == "\u{16}" || event.charactersIgnoringModifiers?.lowercased() == "v",
              let view = event.window?.firstResponder as? AppTerminalView,
              view.pasteImage() else { return event }
        return nil
    }

    /// Картинка из буфера или один файл изображения из Finder. Codex получает file URL, Claude Code путь,
    /// и оба превращают его в [Image #N].
    private func pasteImage() -> Bool {
        guard let tab, tab.running, tab.spec.codexSession || tab.spec.claudeSession else { return false }
        do {
            guard let url = try Self.imageURL(from: .general) else { return false }
            if tab.spec.claudeSession {
                pasteClaudeImages([url].filter(Self.isImageFile), text: Self.escaped(url.path))
            } else {
                pasteText(url.absoluteString)
            }
        } catch {
            NSApp.presentError(error)
        }
        return true
    }

    static func imageURL(from board: NSPasteboard) throws -> URL? {
        if board.types?.contains(.fileURL) == true {
            let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            guard let files, files.count == 1, let url = files.first,
                  let properties = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey]),
                  properties.isRegularFile == true, properties.contentType?.conforms(to: .image) == true else { return nil }
            return url
        }

        let png: Data
        if let data = board.data(forType: .png) {
            png = data
        } else {
            guard let type = board.types?.first(where: { UTType($0.rawValue)?.conforms(to: .image) == true }),
                  let data = board.data(forType: type), let bitmap = NSBitmapImageRep(data: data),
                  let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
            png = data
        }
        // The composer reads the file again on submit. Keep it in the user's temporary directory.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentmeister-\(UUID()).png")
        try png.write(to: url, options: .withoutOverwriting)
        return url
    }

    // Картинка в строке ввода Claude Code видна только как [Image #N], а файл Claude Code сохраняет лишь при
    // отправке. Поэтому номер N приложение узнает само: после вставки ищет на экране новый [Image #N] и
    // запоминает, какой файл вставило. Клик по [Image #N] показывает этот файл в Quick Look.
    private var pastedImages: [Int: URL] = [:]
    private var pastedImagesSession: String?
    private var imagePressTaken = false
    private var previewURL: URL?

    /// Форматы, которые Claude Code прикладывает к запросу по пути.
    static func isImageFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp"].contains(url.pathExtension.lowercased())
    }

    private func pasteClaudeImages(_ images: [URL], text: String) {
        let before = images.isEmpty ? [:] : imageTokenCounts()
        pasteText(text)
        if !images.isEmpty { claimImages(images, before: before, attempt: 0) }
    }

    /// Claude Code заменяет путь на [Image #N] не сразу. Новые номера ищем несколько раз, пока они не появятся.
    private func claimImages(_ images: [URL], before: [Int: Int], attempt: Int) {
        let delays = [0.1, 0.2, 0.4, 0.8, 1.6]
        guard attempt < delays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            guard let self else { return }
            let added = self.imageTokenCounts().filter { $0.value > before[$0.key, default: 0] }.keys.sorted()
            if added.count < images.count, attempt + 1 < delays.count {
                self.claimImages(images, before: before, attempt: attempt + 1)
                return
            }
            self.syncImageSession()
            // номера у Claude Code только растут, новые картинки получают старшие
            for (number, url) in zip(added.suffix(images.count), images) { self.pastedImages[number] = url }
        }
    }

    /// /clear и перезапуск начинают нумерацию заново, старые номера к новой сессии не относятся.
    private func syncImageSession() {
        let session = tab?.sessionId
        if pastedImagesSession == nil {
            pastedImagesSession = session
        } else if let session, session != pastedImagesSession {
            pastedImages = [:]
            pastedImagesSession = session
        }
    }

    private func liveRows() -> [TerminalContentRowSnapshot] {
        guard let viewport = terminalContentSnapshot(region: .viewport) else { return [] }
        let top = viewport.liveTopRow
        return terminalContentSnapshot(region: .rows(top..<(top + viewport.dimensions.rows)))?.rows ?? []
    }

    private func imageTokenCounts() -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for row in liveRows() {
            for token in Self.imageTokens(row.cells.map(\.text)) { counts[token.number, default: 0] += 1 }
        }
        return counts
    }

    /// [Image #N] в строке экрана: столбцы и номер. Одна ячейка это один столбец, поэтому ищем по ячейкам.
    static func imageTokens(_ cells: [String]) -> [(columns: ClosedRange<Int>, number: Int)] {
        let prefix = "[Image #".map(String.init)
        var found: [(columns: ClosedRange<Int>, number: Int)] = []
        var i = 0
        while i + prefix.count < cells.count {
            guard Array(cells[i..<(i + prefix.count)]) == prefix else {
                i += 1
                continue
            }
            var j = i + prefix.count
            var digits = ""
            while j < cells.count, let c = cells[j].first, cells[j].count == 1, c.isASCII, c.isNumber {
                digits.append(c)
                j += 1
            }
            if !digits.isEmpty, j < cells.count, cells[j] == "]", let number = Int(digits) {
                found.append((i...j, number))
                i = j + 1
            } else {
                i += 1
            }
        }
        return found
    }

    private func imageUnderPointer(_ event: NSEvent) -> URL? {
        guard tab?.spec.claudeSession == true, !pastedImages.isEmpty,
              let viewport = terminalContentSnapshot(region: .viewport) else { return nil }
        syncImageSession()
        let index = characterIndex(for: event.locationInWindow)
        let cols = viewport.dimensions.cols
        guard cols > 0, index >= 0 else { return nil }
        let line = index / cols, col = index % cols
        guard viewport.rows.indices.contains(line) else { return nil }
        let token = Self.imageTokens(viewport.rows[line].cells.map(\.text)).first { $0.columns.contains(col) }
        guard let number = token?.number, let url = pastedImages[number] else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            pastedImages[number] = nil
            return nil
        }
        return url
    }

    private func showPreview(_ url: URL) {
        previewURL = url
        window?.makeFirstResponder(self)
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, panel.dataSource === self {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        previewURL != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        previewURL = nil
    }

    // Файлы из Finder и скриншоты: путь вставляется в строку ввода, как в Terminal и iTerm2. Claude Code
    // по пути к картинке прикладывает ее к сообщению.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.files(sender).isEmpty || tab?.running != true ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = Self.files(sender)
        guard !files.isEmpty, tab?.running == true else { return false }
        window?.makeFirstResponder(self)
        let text = files.map { Self.escaped($0.path) }.joined(separator: " ") + " "
        if tab?.spec.claudeSession == true {
            pasteClaudeImages(files.filter(Self.isImageFile), text: text)
        } else {
            pasteText(text)
        }
        return true
    }

    private static func files(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Путь для строки ввода: пробелы, кавычки и скобки через обратную косую черту, как при перетаскивании в Terminal.
    static func escaped(_ path: String) -> String {
        let special = Set(" \t\\'\"()[]{}&;|<>$`!*?#~")
        return path.map { special.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }

    private var downloadPress: (point: NSPoint, label: String?)?

    override func mouseDown(with event: NSEvent) {
        downloadPress = nil
        imagePressTaken = false
        if event.clickCount == 1, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let url = imageUnderPointer(event) {
            imagePressTaken = true
            showPreview(url)
            return
        }
        if tab?.spec.codexSession == true, event.clickCount == 1,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           let snapshot = terminalContentSnapshot(region: .viewport) {
            let index = characterIndex(for: event.locationInWindow)
            let cols = snapshot.dimensions.cols
            if cols > 0, index >= 0, snapshot.rows.indices.contains(index / cols) {
                let label = CodexImageDownload.label(in: snapshot.rows[index / cols], at: index % cols)
                downloadPress = (event.locationInWindow, label)
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        downloadPress = nil
        if !imagePressTaken { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if imagePressTaken {
            imagePressTaken = false
            return
        }
        if let press = downloadPress,
           !event.modifierFlags.contains(.command) || hypot(event.locationInWindow.x - press.point.x,
                                                            event.locationInWindow.y - press.point.y) > 4 {
            downloadPress = nil
        }
        super.mouseUp(with: event)
        if let label = downloadPress?.label, let tab, let session = tab.sessionId {
            let project = URL(fileURLWithPath: tab.spec.projectPath, isDirectory: true)
            saveClickedImage {
                CodexImageDownload.source(label: label, session: session, project: project)
            }
        }
        downloadPress = nil
    }

    private func saveClickedImage(_ source: @escaping @Sendable () -> URL?) {
        Task {
            do {
                let saved = try await Task.detached(priority: .userInitiated) { () throws -> URL? in
                    guard let url = source() else { return nil }
                    let folder = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                                             appropriateFor: nil, create: true)
                    return try CodexImageDownload.save(url, in: folder)
                }.value
                if let saved { tab?.downloadedImage = saved }
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    override func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        if downloadPress != nil, let tab {
            downloadPress = nil
            let project = URL(fileURLWithPath: tab.spec.projectPath, isDirectory: true)
            if let link = URL(string: request.link), let url = CodexImageDownload.localImage(link, project: project) {
                saveClickedImage { url }
                return
            }
        }
        // ссылку из терминала диалога входа диалог открывает сам, там же, где страницу от BROWSER
        if tab?.spec.signInDialog == true, let url = URL(string: request.link), ProxyBrowser.shared.offer(url) {
            return
        }
        if let spec = tab?.spec, spec.proxied,
           let url = URL(string: request.link), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            // через подписку этой вкладки; подписки больше нет, и ссылка не откроется через другую
            let proxy = Backend.main?.state.proxy
            guard let port = proxy?.port(for: spec.subscription) ?? (proxy == nil ? ProxyBrowser.shared.port : nil) else { return }
            if spec.signIn {
                if BrowserSettings.forAgent {
                    ProxyBrowser.shared.open(url, port: port, via: spec.subscription)
                    return
                }
            } else {
                LinkOpener.open(url, place: BrowserSettings.linkPlace, window: window, port: port, via: spec.subscription)
                return
            }
        }
        super.requestOpenLink(source: source, request: request)
    }
}

/// Значок в Dock: число вкладок, которые ждут ответа, и один отскок, когда их стало больше, а окно не в фокусе.
@MainActor
enum DockAttention {
    static let key = "dock.attention"
    private static var last = 0

    static func update(waiting: Int) {
        defer { last = waiting }
        guard UserDefaults.standard.object(forKey: key) as? Bool ?? true else { return }
        let label = waiting > 0 ? String(waiting) : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        if waiting > last, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }
}

extension AppTerminalView: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}
