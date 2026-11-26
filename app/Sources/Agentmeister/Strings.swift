import Foundation

/// Тексты интерфейса на двух языках. Язык тот же, что у меню agentmeister: lang из ~/.config/mnrh/config,
/// иначе первый язык macOS. Его присылает app-state.
struct L {
    let en: Bool

    init(_ lang: String) { en = lang != "ru" }

    func t(_ ru: String, _ en: String) -> String { self.en ? en : ru }

    var projects: String { t("Проекты", "Projects") }
    var modes: String { t("Режимы", "Modes") }
    var newSession: String { t("Новая сессия", "New session") }
    var newTab: String { t("Новая вкладка", "New tab") }
    var newTerminal: String { t("Новая вкладка терминала", "New terminal tab") }
    var openTerminalHere: String { t("Открыть терминал здесь", "Open terminal here") }
    var closeTab: String { t("Закрыть вкладку", "Close tab") }
    var restart: String { t("Перезапустить", "Restart") }
    var resumeLast: String { t("Продолжить последнюю", "Resume last") }
    var resume: String { t("Продолжить", "Resume") }
    var inspector: String { t("Панель сессии", "Session panel") }
    var noTabs: String { t("Нет открытых вкладок", "No open tabs") }
    /// Подсказка пустого окна с текущим сочетанием новой сессии, без него, если сочетание убрали.
    func noTabsHint(_ newSessionKey: String) -> String {
        newSessionKey.isEmpty ? t("Выбери проект или сессию слева.", "Pick a project or a session on the left.")
            : t("Выбери проект или сессию слева, или нажми \(newSessionKey).", "Pick a project or a session on the left, or press \(newSessionKey).")
    }
    var proxy: String { "proxy" }
    var direct: String { t("напрямую", "direct") }
    var viaProxy: String { t("Через proxy", "Via proxy") }
    var directly: String { t("Напрямую", "Direct") }
    var proxyOff: String { t("proxy не настроен", "proxy not set up") }
    var proxyIdle: String { t("proxy ждет сессию", "proxy idle") }
    var agent: String { t("Агент", "Agent") }
    var route: String { t("Маршрут", "Route") }
    var folder: String { t("Папка", "Folder") }
    var status: String { t("Состояние", "Status") }
    var sessionId: String { t("Сессия", "Session") }
    var project: String { t("Проект", "Project") }
    var start: String { t("Начать", "Start") }
    var startNew: String { t("Новая сессия", "New session") }
    var firstPrompt: String { t("Первый запрос", "First request") }
    var firstPromptHint: String { t("Можно оставить пустым", "Optional") }
    var open: String { t("Открыть", "Open") }
    var cancel: String { t("Отмена", "Cancel") }
    var directWarning: String { t("Без proxy агент пойдет в сеть напрямую и без sandbox-exec.", "Without the proxy the agent goes online directly and without sandbox-exec.") }
    var exited: String { t("процесс завершился", "process exited") }
    var waiting: String { t("ждет ответа", "waiting") }
    var working: String { t("работает", "working") }
    var idle: String { t("свободна", "idle") }
    var starting: String { t("запускается", "starting") }
    var untitled: String { t("без названия", "untitled") }
    var backendError: String { t("Не удалось получить состояние agentmeister", "Couldn't read agentmeister state") }

    func modeTitle(_ key: String) -> String {
        switch key {
        case "humanize": return t("Без примет нейросети", "No AI tells")
        case "guard": return t("Спрашивать перед опасным", "Ask before risky commands")
        case "buildlog": return t("Выжимка сборки", "Build digest")
        case "notify": return t("Уведомления", "Notifications")
        case "lid": return t("Не спать с закрытой крышкой", "Stay awake with the lid closed")
        case "alias": return t("Короткое имя am", "Short name am")
        default: return key
        }
    }

    func statusTitle(_ status: String?) -> String {
        switch status {
        case "waiting": return waiting
        case "busy": return working
        case "idle": return idle
        default: return starting
        }
    }

    /// "1 вкладка, 2 вкладки, 5 вкладок" и "1 tab, 2 tabs".
    func count(_ n: Int, _ one: String, _ few: String, _ many: String, _ enOne: String, _ enMany: String) -> String {
        if en { return "\(n) " + (n == 1 ? enOne : enMany) }
        let tens = n % 100, ones = n % 10
        let word = (11...14).contains(tens) ? many : ones == 1 ? one : (2...4).contains(ones) ? few : many
        return "\(n) \(word)"
    }

    func tabs(_ n: Int) -> String { count(n, "вкладка", "вкладки", "вкладок", "tab", "tabs") }
    func commands(_ n: Int) -> String { count(n, "команда", "команды", "команд", "command", "commands") }

    var moveToClaude: String { t("Перенести в Claude Code", "Move to Claude Code") }
    var updating: String { t("Обновляю Claude Code…", "Updating Claude Code…") }
    var slim: String { t("Сжать", "Slim") }
    var rename: String { t("Переименовать", "Rename") }
    var forget: String { t("Забыть", "Forget") }
    var slimming: String { t("Сжимаю сессию и продолжаю ее…", "Slimming the session, then resuming it…") }
    var forgetting: String { t("Удаляю сессию без следа и открываю чистую…", "Deleting the session without a trace, opening a clean one…") }

    /// Короткое состояние для строки сессии в боковой панели: "ждет", "идет".
    func shortStatus(_ status: String?) -> String {
        switch status {
        case "waiting": return t("ждет", "waiting")
        case "busy": return t("идет", "running")
        case "idle": return t("открыта", "open")
        default: return starting
        }
    }

    /// "3 ч назад", "вчера", "5 дн назад": для подписи, где одно число без слова непонятно.
    func agoLong(_ time: Double) -> String {
        let short = ago(time)
        let s = Date().timeIntervalSince1970 - time
        if s < 60 || (s >= 86400 && s < 172800) { return short }
        return t(short + " назад", short + " ago")
    }

    func ago(_ time: Double) -> String {
        let s = max(0, Date().timeIntervalSince1970 - time)
        if s < 60 { return t("сейчас", "now") }
        if s < 3600 { return t("\(Int(s / 60)) мин", "\(Int(s / 60)) min") }
        if s < 86400 { return t("\(Int(s / 3600)) ч", "\(Int(s / 3600)) h") }
        if s < 172800 { return t("вчера", "yesterday") }
        return t("\(Int(s / 86400)) дн", "\(Int(s / 86400)) d")
    }
}
