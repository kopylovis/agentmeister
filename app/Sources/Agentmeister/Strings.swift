import Foundation

/// Тексты интерфейса на двух языках. Язык тот же, что у меню agentmeister: lang из ~/.config/mnrh/config,
/// иначе первый язык macOS. Его присылает app-state.
struct L {
    let en: Bool

    init(_ lang: String) { en = lang == "en" }

    func t(_ ru: String, _ en: String) -> String { self.en ? en : ru }

    var projects: String { t("Проекты", "Projects") }
    var modes: String { t("Режимы", "Modes") }
    var newSession: String { t("Новая сессия", "New session") }
    var newTab: String { t("Новая вкладка", "New tab") }
    var closeTab: String { t("Закрыть вкладку", "Close tab") }
    var restart: String { t("Перезапустить", "Restart") }
    var resumeLast: String { t("Продолжить последнюю", "Resume last") }
    var resume: String { t("Продолжить", "Resume") }
    var inspector: String { t("Панель сессии", "Session panel") }
    var noTabs: String { t("Нет открытых вкладок", "No open tabs") }
    var noTabsHint: String { t("Выбери проект или сессию слева, или нажми ⌘N.", "Pick a project or a session on the left, or press ⌘N.") }
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

    func ago(_ time: Double) -> String {
        let s = max(0, Date().timeIntervalSince1970 - time)
        if s < 60 { return t("сейчас", "now") }
        if s < 3600 { return t("\(Int(s / 60)) мин", "\(Int(s / 60)) min") }
        if s < 86400 { return t("\(Int(s / 3600)) ч", "\(Int(s / 3600)) h") }
        return t("\(Int(s / 86400)) дн", "\(Int(s / 86400)) d")
    }
}
