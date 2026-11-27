import SwiftUI

struct SettingsData: Decodable {
    struct Notify: Decodable {
        /// Последняя ошибка отправки в канал, удачная отправка ее стирает.
        struct SendError: Decodable {
            let at: Double
            let text: String
        }

        struct Telegram: Decodable {
            let connected: Bool
            let bot: String?
            let when: String
            let away: Int
            let approve: Bool
            var error: SendError? = nil
        }

        struct Phone: Decodable {
            let mode: String
            let configured: Bool
        }

        /// Пресет ntfy: канал agentmeister на сервере Tossling. source cli, если настройки взяты у tossling на Mac.
        struct Tossling: Decodable {
            let mode: String
            let configured: Bool
            let server: String?
            let source: String?
            let topic: String
            let body: String
            let docs: String?
            var error: SendError? = nil
        }

        struct Ntfy: Decodable {
            let mode: String
            let configured: Bool
            let server: String
            let topic: String?
            let body: String
            let token: Bool
            let `public`: Bool
            let subscribe: String?
            var error: SendError? = nil
        }

        struct Bark: Decodable {
            let mode: String
            let configured: Bool
            let server: String
            let body: String
            let encrypted: Bool
            let `public`: Bool
            var error: SendError? = nil
        }

        struct Gotify: Decodable {
            struct Priority: Decodable {
                let urgent: Int
                let normal: Int
            }
            let mode: String
            let configured: Bool
            let server: String?
            let body: String
            let priority: Priority
            var error: SendError? = nil
        }

        struct Webhook: Decodable {
            let mode: String
            let configured: Bool
            let host: String?
            let body: String
            let auth: Bool
            var error: SendError? = nil
        }

        struct Pushover: Decodable {
            let mode: String
            let configured: Bool
            let body: String
            var error: SendError? = nil
        }

        /// Apprise шлет по своему config, configured значит: команда apprise есть и config найден.
        struct Apprise: Decodable {
            let mode: String
            let configured: Bool
            let installed: Bool
            let config: String?
            let body: String
            let tag: String?
            var error: SendError? = nil
        }

        let on: Bool
        let after: Int
        let sound: Bool
        var away: Int? = nil
        let telegram: Telegram
        let phone: Phone
        var tossling: Tossling? = nil
        var ntfy: Ntfy? = nil
        var bark: Bark? = nil
        var gotify: Gotify? = nil
        var webhook: Webhook? = nil
        var pushover: Pushover? = nil
        var apprise: Apprise? = nil
    }

    struct Guard: Decodable {
        struct Rule: Decodable, Identifiable {
            let id: String
            let text: String
            let textEn: String?
            let on: Bool
        }

        let on: Bool
        let rules: [Rule]
        let log: [String]?
        let logPath: String?
        /// Время последнего срабатывания (ask, hold, allow) в секундах эпохи.
        let lastHit: Double?
        /// Свои маски секретов (guard_secrets). Nil в старом ответе app-state.
        let secrets: [String]?
    }

    struct HostRun: Decodable {
        struct Command: Decodable, Identifiable {
            let name: String
            let cwd: String?
            let run: [String]?
            let args: Bool
            var id: String { name }
        }

        let running: Bool
        let pid: Int?
        let version: String?
        let commands: [Command]
    }

    struct Proxy: Decodable {
        let configured: Bool
        let running: Bool?
        let exit: String?
        let `protocol`: String?
        let sessions: Int?
        let country: String?
        let ip: String?
        let defaultRoute: String?
        let defaultSubscription: String?
        let subscriptions: [AppState.Proxy.Subscription]?
    }

    struct Agent: Decodable {
        let installed: Bool
        let path: String?
        let version: String?
        let signedIn: Bool?
        let plan: String?
        let email: String?
        let model: String?
        let installedVia: String?
    }

    struct ModesInfo: Decodable {
        let buildlogDays: Int
        let buildlogLines: Int
        /// Порог выжимки в КБ, nil в старом ответе app-state (было 20).
        let buildlogKB: Int?
        let buildlogDir: String
        let lidReady: Bool
        /// Через сколько минут после последней сессии и при каком заряде lid отпускает крышку. Nil в старом ответе.
        let lidGraceMin: Int?
        let lidBattery: Int?
        /// Строгая типографика humanize (прямые кавычки, без е с точками, без двоеточий). Nil в старом ответе.
        let humanizeTypography: Bool?
        /// Откуда ключ OpenRouter для translate: file, env или nil, если его нет.
        let translateKey: String?
        let translateModel: String?
        /// openrouter или google; translateFallback это второй провайдер с ключом, nil если ключа нет.
        let translateProvider: String?
        let translateFallback: String?
        let translateLog: [String]?
        let translateLogPath: String?
        /// Медиана времени перевода по последним строкам журнала, мс. nil, если переводов в журнале нет.
        let translateMedianMs: Int?
    }

    let notify: Notify?
    let `guard`: Guard?
    let hostRun: HostRun?
    let proxy: Proxy?
    let modes: [String: Bool]?
    let modesInfo: ModesInfo?
    let claude: Agent?
    let codex: Agent?
    let errors: [String: String]?
}

struct DoctorData: Decodable {
    struct Row: Decodable, Hashable {
        let check: String
        let level: String
        let text: String
    }

    let rows: [Row]
}

extension Backend {
    func settings() async -> SettingsData? { await Self.json(["app-state", "settings"]) }
    func doctor() async -> DoctorData? { await Self.json(["app-state", "doctor"]) }
}

/// Разделы окна настроек в порядке макета. General добавлен сверху: язык и вид.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, proxy, modes, notify, terminal, agents, shortcuts, doctor
    var id: String { rawValue }

    func title(_ l: L) -> String {
        switch self {
        case .general: return l.t("Основные", "General")
        case .proxy: return l.t("Proxy и host-run", "Proxy and host-run")
        case .modes: return l.t("Режимы", "Modes")
        case .notify: return l.t("Уведомления", "Notifications")
        case .terminal: return l.t("Терминал", "Terminal")
        case .agents: return l.t("Агенты", "Agents")
        case .shortcuts: return l.t("Горячие клавиши", "Shortcuts")
        case .doctor: return l.t("Диагностика", "Diagnostics")
        }
    }
}

/// Окно настроек (⌘,) по макету Settings.dc.html: стеклянная боковая панель разделов и раздел справа.
/// Значения берутся из agentmeister app-state settings, изменения идут теми же командами, что в CLI. Шаги, которым
/// нужен терминал (подписка proxy, sudo для lid, токен бота), открываются служебной вкладкой в главном окне.
struct SettingsView: View {
    @EnvironmentObject var backend: Backend
    @State private var data: SettingsData?
    @AppStorage("settingsSection") private var section = SettingsSection.general.rawValue

    var l: L { L(backend.state.lang) }

    var body: some View {
        let current = SettingsSection(rawValue: section) ?? .proxy
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { item in
                    Button {
                        section = item.rawValue
                    } label: {
                        Text(item.title(l))
                            .fontWeight(item == current ? .medium : .regular)
                            .foregroundStyle(item == current ? Ink.strong : Ink.text2)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(item == current ? Ink.thumb : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hover(10))
                    .accessibilityAddTraits(item == current ? .isSelected : [])
                }
                Spacer()
            }
            .padding(10)
            // светофор сдвинут вниз и вправо, как в главном окне: первый раздел начинается под ним
            .padding(.top, 44)
            // полоса со светофором тянет окно и разворачивает его двойным кликом, как заголовок
            .overlay(alignment: .top) { WindowDragArea().frame(height: 44) }
            .frame(width: 210)
            .frame(maxHeight: .infinity)
            .glassEffect(.regular, in: .windowCard)
            .padding(8)
            .accessibilityLabel(l.t("Разделы настроек", "Settings sections"))

            ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch current {
                    case .general: GeneralPane()
                    case .proxy: ProxyHostRunPane(data: data, reload: reload)
                    case .modes: ModesPane(data: data, reload: reload)
                    case .notify: NotifyPane(data: data, reload: reload)
                    case .terminal: TerminalPane()
                    case .agents: AgentsPane(data: data, reload: reload)
                    case .shortcuts: ShortcutsPane()
                    case .doctor: DoctorPane()
                    }
                }
                .padding(.horizontal, 28)
                // 28 из прежних 36 теперь дает полоса размытия сверху
                .padding(.top, 8)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // демо settings-notify-phone снимает каналы на телефон: прокрутить к ним, когда данные загрузились
            .onAppear {
                guard Demo.scene == "settings-notify-phone" else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { scroller.scrollTo("phone-channels", anchor: .top) }
            }
            }
            // macOS 26 рисует над скрытым заголовком свою полосу, когда курсор над ней, и прокрученная карточка
            // мелькала под ней пятном. Вместо нее ровное размытие, как в главном окне
            .scrollEdgeEffectHidden(true, for: .top)
            .safeAreaBar(edge: .top, spacing: 0) {
                Color.clear.frame(height: 28).frame(maxWidth: .infinity)
                    .background(WindowDragArea())
                    .blurBar(edge: .top)
            }
        }
        .ignoresSafeArea(edges: .top)
        .toolbar(removing: .title)
        // без сдвига светофор лежит на скругленном углу стеклянной карточки разделов
        .background(TrafficLightsInset())
        // окно Settings из SwiftUI нельзя ни растянуть, ни развернуть; двойной клик по верху его разворачивает
        .background(ZoomableWindow())
        .frame(minWidth: 960, idealWidth: 1080, minHeight: 640, idealHeight: 740)
        .task { await reload() }
    }

    func reload() async {
        data = await backend.settings()
    }
}

/// Заголовок раздела: 20 pt, полужирный, как h1 в макете. Справа можно поставить чип состояния.
struct PaneTitle<Accessory: View>: View {
    let text: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            Text(text).font(.system(size: 20, weight: .semibold))
            accessory()
        }
    }
}

extension PaneTitle where Accessory == EmptyView {
    init(_ text: String) { self.init(text: text) { EmptyView() } }
}

/// Стеклянная секция раздела, радиус 20.
struct GlassSection<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// Ряд настройки по макету GeneralRows.dc.html: название и короткое пояснение слева (пояснение переносится),
/// компактный контрол прижат к правому краю по центру и занимает ровно свою ширину.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    var titleFont: Font = .system(size: 13, weight: .semibold)
    @ViewBuilder var control: () -> Control

    init(_ title: String, _ detail: String? = nil, titleFont: Font = .system(size: 13, weight: .semibold),
         @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.titleFont = titleFont
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(titleFont)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize()
        }
    }
}

/// Плитка внутри секции: фон карточки, радиус 14.
struct Tile<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Ink.card))
    }
}

/// Бирюзовый или янтарный чип со светящейся точкой: "mihomo работает".
struct StatusChip: View {
    let text: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 7) {
            GlowDot(color: ok ? Ink.tealDot : Ink.amberDot)
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ok ? Ink.teal : Ink.amber)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(ok ? Ink.tealChip : Ink.amberDot.opacity(0.14)))
    }
}

/// Мелкий абзац пояснения под секцией.
struct Note: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
    }
}

/// Куда UtilityButton отправляет команду. По умолчанию во вкладку главного окна, мастер показывает ее у себя:
/// он открыт листом поверх главного окна и закрыл бы вкладку.
struct UtilityRunnerKey: EnvironmentKey {
    static let defaultValue: (@MainActor ([String]) -> Void)? = nil
}

extension EnvironmentValues {
    var utilityRunner: (@MainActor ([String]) -> Void)? {
        get { self[UtilityRunnerKey.self] }
        set { self[UtilityRunnerKey.self] = newValue }
    }
}

/// Открыть служебную вкладку с командой agentmeister в главном окне.
struct UtilityButton: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var backend: Backend
    @Environment(\.openWindow) private var openWindow
    @Environment(\.utilityRunner) private var runner
    let title: String
    let args: [String]
    /// Растянуть кнопку на всю доступную ширину (ряд одинаковых кнопок внизу карточки).
    var expand = false
    /// Со значком кнопка рисуется тихой кнопкой карточки (CardActionStyle), без него капсулой (PillStyle).
    var icon: String? = nil
    var prominent = false
    var small = false
    /// Значок перед подписью в капсуле (у icon он рисуется тихой кнопкой карточки).
    var symbol: String? = nil

    var body: some View {
        if let icon {
            Button { run() } label: { Label(title, systemImage: icon).lineLimit(1) }
                .help("agentmeister " + args.joined(separator: " "))
                .buttonStyle(CardActionStyle())
        } else {
            Button {
                run()
            } label: {
                Group {
                    if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
                }
                .lineLimit(1)
                .frame(maxWidth: expand ? .infinity : nil)
            }
            .help("agentmeister " + args.joined(separator: " "))
            .buttonStyle(PillStyle(prominent: prominent, small: small))
        }
    }

    private func run() {
        if let runner {
            runner(args)
            return
        }
        let home = NSHomeDirectory()
        var spec = LaunchSpec(projectName: "agentmeister", projectPath: home)
        spec.utility = args
        workspace.open(spec)
        openWindow(id: "main")
    }
}

/// Кнопка, которая выполняет команду agentmeister и перечитывает настройки.
struct CommandButton: View {
    @EnvironmentObject var backend: Backend
    let title: String
    let args: [String]
    let reload: () async -> Void
    var small = false
    var symbol: String? = nil
    @State private var busy = false

    var body: some View {
        Button {
            busy = true
            Task {
                _ = await backend.perform(args)
                await reload()
                busy = false
            }
        } label: {
            if busy {
                ProgressView().controlSize(.small)
            } else if let symbol {
                Label(title, systemImage: symbol)
            } else {
                Text(title)
            }
        }
        .buttonStyle(PillStyle(small: small))
        .disabled(busy)
    }
}

/// Папки с проектами. Это категории вроде ~/Developer или ~/Work, а не сами проекты: проектами считаются их
/// подпапки. У каждой видно, сколько в ней проектов, можно добавить еще и убрать лишнюю. Общий для мастера первого
/// запуска и Настроек, пишет то же, что agentmeister projects-dir.
struct ProjectsFolderPicker: View {
    @EnvironmentObject var backend: Backend
    let l: L
    @State private var busy = false
    @State private var error: String?

    private var folders: [String] {
        let list = backend.state.projectsDirs ?? []
        return list.isEmpty ? [backend.state.projectsDir].filter { !$0.isEmpty } : list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(folders, id: \.self) { folder in
                let count = backend.state.projects.filter { ($0.path as NSString).deletingLastPathComponent == folder }.count
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 18)).foregroundStyle(Ink.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tilde(folder))
                            .font(.system(size: 13, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(count == 0 ? l.t("Проектов здесь нет", "No projects here")
                                        : l.t("Проектов внутри: \(count)", count == 1 ? "1 project inside" : "\(count) projects inside"))
                            .font(.system(size: 12))
                            .foregroundStyle(count == 0 ? Ink.amber : Ink.muted)
                    }
                    Spacer(minLength: 8)
                    if folders.count > 1 {
                        Button {
                            run(["projects-dir", "remove", folder])
                        } label: {
                            Image(systemName: "minus.circle").font(.system(size: 14)).foregroundStyle(Ink.muted)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.hoverCircle())
                        .help(l.t("Убрать папку из списка, сами проекты останутся на месте", "Remove the folder from the list, the projects stay where they are"))
                        .disabled(busy)
                    }
                }
            }
            HStack(spacing: 8) {
                Button { choose() } label: { Label(l.t("Добавить папку с проектами…", "Add a folder of projects…"), systemImage: "plus") }
                    .buttonStyle(PillStyle(small: true))
                    .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Ink.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Команда agentmeister с выводом ошибки: отказ (папка вложена в другую, это сам проект) виден под списком.
    private func run(_ args: [String]) {
        busy = true
        error = nil
        let quote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = ([LoginEnvironment.agentmeister] + args).map(quote).joined(separator: " ")
        Task.detached {
            let (code, out) = TerminalTab.shell(command)
            let message = out.split(separator: "\n").last.map(String.init) ?? ""
            await MainActor.run {
                busy = false
                if code != 0 { error = message.isEmpty ? l.t("Команда не сработала", "The command failed") : message }
                backend.refresh()
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = l.t("Добавить", "Add")
        panel.message = l.t("Выбери папку, в которой лежат проекты, например ~/Developer. Не сам проект, а папку уровнем выше.",
                            "Pick the folder that holds your projects, like ~/Developer. Not a project itself, the folder one level up.")
        panel.directoryURL = URL(fileURLWithPath: folders.first ?? NSHomeDirectory())
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // выбрали сам проект (в нем есть git): предложить папку уровнем выше
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
            let parent = url.deletingLastPathComponent()
            let alert = NSAlert()
            alert.messageText = l.t("Это проект, а не папка с проектами", "This is a project, not a folder of projects")
            alert.informativeText = l.t("В \(url.lastPathComponent) есть git, это сам проект. Agentmeister ждет папку, в которой лежат проекты. Добавить \(tilde(parent.path))?",
                                        "\(url.lastPathComponent) has git, so it is a project itself. Agentmeister wants the folder that holds projects. Add \(tilde(parent.path)) instead?")
            alert.addButton(withTitle: l.t("Добавить \(parent.lastPathComponent)", "Add \(parent.lastPathComponent)"))
            alert.addButton(withTitle: l.cancel)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            url = parent
        }
        if folders.contains(url.path) {
            error = l.t("\(tilde(url.path)) уже в списке", "\(tilde(url.path)) is already listed")
            return
        }
        // первая настройка: ~/Developer по умолчанию заменяется выбранной папкой, если в нем нет проектов
        let replaceDefault = folders == [NSHomeDirectory() + "/Developer"] && backend.state.projects.allSatisfy(\.isHome)
        run(["projects-dir"] + (replaceDefault ? [] : ["add"]) + [url.path])
    }
}

/// Язык и вид. Язык общий с CLI (agentmeister lang), вид хранит само приложение.
struct GeneralPane: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var ui: UIState
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    @AppStorage(MenuBarPrefs.showKey) private var showMenuBar = true
    @AppStorage(MenuBarPrefs.keepRunningKey) private var keepRunning = false
    @AppStorage(BrewSync.enabledKey) private var brewSync = true
    @ObservedObject private var updates = Updates.shared

    var l: L { L(backend.state.lang) }

    var body: some View {
        PaneTitle(l.t("Основные", "General"))
        GlassSection(spacing: 16) {
            SettingsRow(l.t("Язык", "Language"),
                        l.t("Язык общий для приложения и agentmeister в терминале, это agentmeister lang. Как в системе значит русский, только если он стоит первым в macOS, иначе английский.",
                            "The app and agentmeister in a terminal share it, same as agentmeister lang. System means Russian only when it comes first in macOS, English otherwise.")) {
                SegmentedCapsule(selection: Binding(
                    get: { backend.state.langSetting ?? "auto" },
                    set: { value in Task { _ = await backend.perform(["lang", value]) } }
                ), options: [("auto", l.t("Как в системе", "System"), nil), ("ru", "Русский", nil), ("en", "English", nil)], compact: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l.t("Оформление", "Appearance")).font(.system(size: 13, weight: .semibold))
                    Text(l.t("Превью показывают окно приложения в каждой теме.", "Previews show the app window in each theme."))
                        .font(.system(size: 12)).foregroundStyle(Ink.muted)
                }
                AppearancePicker(selection: $appearance, l: l)
            }
        }
        GlassSection {
            SettingsRow(l.t("Мастер первого запуска", "First-run setup"),
                        l.t("Те же семь шагов, что при первом запуске: папки проектов, агенты, proxy, вход, режимы и разрешения.",
                            "The same seven steps as on first launch: project folders, agents, proxy, sign-in, modes and permissions.")) {
                Button {
                    ui.onboardingStep = 0
                    ui.showOnboarding = true
                    openWindow(id: "main")
                    Workspace.bringMainWindowForward()
                } label: { Label(l.t("Открыть мастер", "Open setup"), systemImage: "wand.and.stars") }
                    .buttonStyle(PillStyle(small: true))
            }
        }
        GlassSection {
            Text(l.t("Папки с проектами", "Project folders")).font(.system(size: 13, weight: .semibold))
            ProjectsFolderPicker(l: l)
            Note(text: l.t("Это папки, в которых лежат проекты, например ~/Developer и ~/Work, а не сами проекты. Проектом считается каждая их подпапка. Список общий с agentmeister в терминале, это agentmeister projects-dir.",
                           "These are folders that hold projects, like ~/Developer and ~/Work, not projects themselves. Each of their subfolders is a project. The app and agentmeister in a terminal share the list, same as agentmeister projects-dir."))
        }
        GlassSection {
            SettingsRow(l.t("Показывать в строке меню", "Show in menu bar"),
                        l.t("Значок показывает, работает ли агент или ждет ответа. В панели открытые сессии, proxy, host-run и новая сессия.",
                            "The icon shows whether an agent is working or waiting for you. Its panel lists open sessions, proxy, host-run and starts a new session.")) {
                HeaderSwitch(label: l.t("Показывать в строке меню", "Show in menu bar"), on: showMenuBar) { showMenuBar = $0 }
            }
            Divider()
            SettingsRow(l.t("Оставаться в строке меню после закрытия окна", "Keep running in the menu bar when the window closes"),
                        l.t("Иначе закрытое окно завершает приложение и всех агентов во вкладках. Окно вернет значок в строке меню или Dock.",
                            "Otherwise closing the window quits the app and every agent in its tabs. The menu bar icon or the Dock brings the window back.")) {
                HeaderSwitch(label: l.t("Оставаться в строке меню", "Keep running in the menu bar"), on: keepRunning && showMenuBar) { keepRunning = $0 }
                    .disabled(!showMenuBar)
            }
        }
        if updates.available {
            GlassSection {
                Text(l.t("Обновления", "Updates")).font(.system(size: 13, weight: .semibold))
                SettingsRow(l.t("Проверять обновления", "Check for updates"),
                            l.t("Раз в день, без этого только из меню приложения.", "Once a day; without it, only from the app menu.")) {
                    HeaderSwitch(label: l.t("Проверять обновления", "Check for updates"), on: updates.autoCheck) { updates.autoCheck = $0 }
                }
                Divider()
                SettingsRow(l.t("Скачивать и ставить при выходе", "Download and install on quit"),
                            l.t("Иначе Agentmeister спросит, ставить ли новую версию.", "Otherwise Agentmeister asks before installing a new version.")) {
                    HeaderSwitch(label: l.t("Ставить обновления", "Install updates"), on: updates.autoInstall) { updates.autoInstall = $0 }
                        .disabled(!updates.autoCheck)
                }
                Divider()
                SettingsRow(l.t("Обновлять agentmeister и promptsill в Homebrew", "Upgrade agentmeister and promptsill in Homebrew"),
                            l.t("После обновления приложения, если они стоят из kopylovis/tap. Лог в ~/Library/Logs/Agentmeister/brew-upgrade.log.",
                                "After the app updates, if they're installed from kopylovis/tap. Log in ~/Library/Logs/Agentmeister/brew-upgrade.log.")) {
                    HeaderSwitch(label: l.t("Обновлять Homebrew", "Upgrade Homebrew"), on: brewSync) { brewSync = $0 }
                }
            }
        }
    }
}

/// Системный, светлый или темный вид. Применяется ко всем окнам через NSApp.appearance.
enum Appearance: String, CaseIterable {
    case system, light, dark
    static let key = "appearance"

    @MainActor
    static func apply(_ raw: String) {
        switch Appearance(rawValue: raw) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Три превью темы равными колонками на всю ширину, подпись под превью, выбранное обведено акцентом. Общий для
/// мастера первого запуска и Настроек.
struct AppearancePicker: View {
    @Binding var selection: String
    let l: L

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Appearance.allCases, id: \.self) { item in
                AppearanceOption(item: item, title: title(item), on: selection == item.rawValue) {
                    selection = item.rawValue
                    Appearance.apply(item.rawValue)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func title(_ item: Appearance) -> String {
        switch item {
        case .system: l.t("Как в системе", "System")
        case .light: l.t("Светлая", "Light")
        case .dark: l.t("Темная", "Dark")
        }
    }
}

/// Одно превью темы с подписью. Подсветка под курсором только на самом превью, не на подписи.
private struct AppearanceOption: View {
    let item: Appearance
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ThemeMiniature(item: item)
                    .aspectRatio(2, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Ink.buttonBorder))
                    .overlay(shape.fill(hover && !on ? Ink.hover : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2)
                        .padding(-4))
                Text(title)
                    .fontWeight(on ? .semibold : .regular)
                    .foregroundStyle(Ink.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Главное окно Agentmeister в миниатюре для превью темы: полоса проектов с тремя плитками, две вкладки и
/// терминал с несколькими строками, одна зеленая. У светлой и темной свои цвета, текущая тема приложения на них
/// не влияет. Системная поделена пополам: слева светлая, справа темная. Цвета из макета GeneralRows.dc.html.
struct ThemeMiniature: View {
    let item: Appearance

    struct Tones {
        let window: Color
        let rail: Color
        let tiles: [Color]
        let strip: Color
        let tabOn: Color
        let tabOff: Color
        let panel: Color
        let heading: Color
        let line: Color
        let green: Color
    }

    static let light = Tones(window: Color(hex: 0xEEF0F4), rail: .white,
                             tiles: [Color(hex: 0x6C8F4E), Color(hex: 0x4D7CF0), Color(hex: 0xC58B5C)],
                             strip: .white, tabOn: Color(hex: 0xDFE7FB), tabOff: Color(hex: 0xEEF0F4),
                             panel: .white, heading: Color(hex: 0xD7DAE1), line: Color(hex: 0xE6E8ED), green: Color(hex: 0xB5E0C5))
    static let dark = Tones(window: Color(hex: 0x161618), rail: Color(hex: 0x2A2A2D),
                            tiles: [Color(hex: 0x6C8F4E), Color(hex: 0x4D7CF0), Color(hex: 0x8A5A3C)],
                            strip: Color(hex: 0x2A2A2D), tabOn: Color(hex: 0x2D3B5C), tabOff: Color(hex: 0x38383B),
                            panel: Color(hex: 0x0C0C0D), heading: Color(hex: 0x3A3A3D), line: Color(hex: 0x2A2A2D), green: Color(hex: 0x2F6B47))

    var body: some View {
        switch item {
        case .light: window(Self.light)
        case .dark: window(Self.dark)
        case .system:
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    rail(Self.light, width: 26, tile: 12)
                    terminal(Self.light, short: true)
                }
                .padding(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Self.light.window)
                terminal(Self.dark, short: true)
                    .padding(7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Self.dark.window)
            }
        }
    }

    private func window(_ t: Tones) -> some View {
        HStack(spacing: 5) {
            rail(t, width: 30, tile: 14)
            VStack(spacing: 4) {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(t.tabOn).frame(width: 28)
                    RoundedRectangle(cornerRadius: 2).fill(t.tabOff).frame(width: 28)
                }
                .padding(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 12)
                .background(RoundedRectangle(cornerRadius: 4).fill(t.strip))
                terminal(t, short: false)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.window)
    }

    private func rail(_ t: Tones, width: CGFloat, tile: CGFloat) -> some View {
        VStack(spacing: 4) {
            ForEach(Array(t.tiles.enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 3).fill(color).frame(height: tile)
            }
        }
        .padding(4)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 5).fill(t.rail))
    }

    /// Строки терминала долями ширины: заголовок, текст и одна зеленая.
    private func terminal(_ t: Tones, short: Bool) -> some View {
        let lines: [(CGFloat, CGFloat, Color)] = short
            ? [(0.6, 6, t.heading), (0.8, 4, t.line), (0.7, 4, t.line), (0.5, 4, t.green)]
            : [(0.55, 5, t.heading), (0.85, 4, t.line), (0.75, 4, t.line), (0.45, 4, t.green), (0.65, 4, t.line)]
        return GeometryReader { g in
            VStack(alignment: .leading, spacing: short ? 4 : 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    RoundedRectangle(cornerRadius: 2).fill(line.2).frame(width: g.size.width * line.0, height: line.1)
                }
            }
        }
        .clipped()
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 5).fill(t.panel))
    }
}

/// Proxy и host-run одним разделом, как в макете Settings.dc.html.
struct ProxyHostRunPane: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    let data: SettingsData?
    let reload: () async -> Void
    @AppStorage(BrowserSettings.forAgentKey) private var browserForAgent = true
    @AppStorage(BrowserSettings.linkPlaceKey) private var linkPlace = BrowserSettings.linkPlace.rawValue
    @State private var confirmRemove = false
    @State private var adding = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        let p = data?.proxy
        PaneTitle(text: l.t("Proxy и host-run", "Proxy and host-run")) {
            if let p {
                StatusChip(text: !p.configured ? l.proxyOff : p.running == true ? l.t("mihomo работает", "mihomo running") : l.t("mihomo ждет сессию", "mihomo waits for a session"),
                           ok: p.running == true)
            }
        }
        if let p {
            GlassSection {
                Text(l.t("Proxy для сессий", "Session proxy")).font(.system(size: 17, weight: .semibold))
                Text(l.t("Каждая сессия через proxy идет в sandbox-exec, ограничение действует с запуска. Маршрут выбирается для вкладки и меняется перезапуском той же сессии.",
                         "Every proxied session runs in sandbox-exec, the restriction applies from launch. The route is set per tab and changes when you restart the same session."))
                    .foregroundStyle(Ink.muted)
                    .frame(maxWidth: 640, alignment: .leading)
                HStack(alignment: .top, spacing: 12) {
                    Tile {
                        Text(l.t("Профиль Claude Code", "Claude Code profile")).fontWeight(.semibold)
                        Note(text: l.t("Внешние порты 80 и 443 только через mihomo, по TCP и QUIC. SSH, локальные серверы и unix-сокеты работают как обычно.",
                                       "External ports 80 and 443 go only through mihomo, over TCP and QUIC. SSH, local servers and Unix sockets work as usual."))
                    }
                    Tile {
                        Text(l.t("Строгий профиль Codex", "Strict Codex profile")).fontWeight(.semibold)
                        Note(text: l.t("Сеть только через порт mihomo. git подписывает через SSH_AUTH_SOCK текущего пользователя.",
                                       "Network only through the mihomo port. git can sign through the current user's SSH_AUTH_SOCK."))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 12) {
                    Tile {
                        Text(l.t("Выход", "Exit")).font(.system(size: 11)).foregroundStyle(Ink.faint)
                        Text(p.exit ?? "—").font(.system(size: 22, weight: .semibold))
                        Text([p.protocol, p.ip].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.muted)
                    }
                    let agents = workspace.tabs.filter { $0.spec.utility == nil }
                    let directOnes = agents.filter { !$0.spec.proxied }
                    Tile {
                        Text(l.t("Сессий через proxy", "Sessions via proxy")).font(.system(size: 11)).foregroundStyle(Ink.faint)
                        Text(l.t("\(agents.count - directOnes.count) из \(agents.count)", "\(agents.count - directOnes.count) of \(agents.count)"))
                            .font(.system(size: 22, weight: .semibold))
                        if !directOnes.isEmpty {
                            Text(Set(directOnes.map(\.spec.projectName)).sorted().joined(separator: ", ") + l.t(" идет напрямую", " goes direct"))
                                .font(.system(size: 12)).foregroundStyle(Ink.direct).lineLimit(2)
                        }
                    }
                    Tile {
                        Text(l.t("Новые сессии", "New sessions")).font(.system(size: 11)).foregroundStyle(Ink.faint)
                        SegmentedCapsule(selection: Binding(
                            get: { p.defaultRoute ?? "proxy" },
                            set: { value in Task { _ = await backend.perform(["proxy", "remember", value == "direct" ? "direct" : "vps"]); await reload() } }
                        ), options: [("proxy", l.viaProxy, Ink.teal), ("direct", l.directly, Ink.direct)])
                        .font(.system(size: 12))
                        .accessibilityLabel(l.t("Маршрут по умолчанию", "Default route"))
                        if p.defaultRoute != "direct", let subs = p.subscriptions, subs.count > 1 {
                            SubscriptionPicker(selection: Binding(
                                get: { p.defaultSubscription },
                                set: { name in Task { _ = await backend.perform(["proxy", "remember", name.map { "vps:" + $0 } ?? "vps"]); await reload() } }
                            ), subscriptions: subs)
                            .font(.system(size: 12))
                            .accessibilityLabel(l.t("Подписка по умолчанию", "Default subscription"))
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if p.configured {
                    // действия плитками с пояснением: по одному названию кнопки было непонятно, что она сделает
                    ProxyActions(reload: reload)
                    ProxySubscriptions(subscriptions: p.subscriptions ?? [], mainCountry: p.country, reload: reload)
                }
                HStack(spacing: 8) {
                    if p.configured {
                        Spacer()
                        Button(l.t("Удалить proxy", "Remove proxy"), role: .destructive) { confirmRemove = true }
                            .buttonStyle(.textLink(Ink.red))
                            .foregroundStyle(Ink.red)
                            .font(.system(size: 12))
                    } else {
                        UtilityButton(title: l.t("Настроить proxy", "Set up proxy"), args: ["proxy", "setup"], prominent: true)
                    }
                }
                .confirmationDialog(l.t("Удалить настройку proxy?", "Remove the proxy setup?"), isPresented: $confirmRemove) {
                    Button(l.t("Удалить", "Remove"), role: .destructive) {
                        Task { _ = await backend.perform(["proxy", "remove"]); await reload() }
                    }
                } message: {
                    Text(l.t("Подписка и конфиг mihomo удалятся. Сессии через proxy перестанут запускаться, пока proxy не настроен снова.",
                             "The subscription and the mihomo config go away. Proxied sessions won't start until the proxy is set up again."))
                }
            }
            GlassSection(spacing: 10) {
                Text(l.t("Браузер через proxy", "Proxy browser")).font(.system(size: 13, weight: .semibold))
                SettingsRow(l.t("Страницы от агента во встроенном браузере", "Pages the agent opens go to the built-in browser"),
                            titleFont: .system(size: 13)) {
                    Toggle(l.t("Страницы от агента во встроенном браузере", "Pages the agent opens go to the built-in browser"), isOn: $browserForAgent)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsRow(l.t("Ссылки по клику из вкладки", "Links you click in a tab"), titleFont: .system(size: 13)) {
                    Picker(l.t("Ссылки по клику из вкладки", "Links you click in a tab"), selection: $linkPlace) {
                        Text(l.t("Спрашивать", "Ask")).tag(LinkPlace.ask.rawValue)
                        Text(l.t("Окно Agentmeister", "Agentmeister window")).tag(LinkPlace.builtin.rawValue)
                        if ChromeProfile.app != nil {
                            Text(l.t("Отдельный профиль Chrome", "Separate Chrome profile")).tag(LinkPlace.chrome.rawValue)
                        }
                        Text(l.t("Браузер по умолчанию", "Default browser")).tag(LinkPlace.system.rawValue)
                    }
                    .labelsHidden()
                    // запомненный Chrome без Chrome: в списке его нет, ссылка все равно спросит
                    .onAppear { if linkPlace == LinkPlace.chrome.rawValue && ChromeProfile.app == nil { linkPlace = LinkPlace.ask.rawValue } }
                }
                Note(text: l.t("Вход в агента, OAuth для MCP и другие страницы, которые агент во вкладке через proxy открывает сам, грузятся во встроенном браузере через тот же mihomo. Если mihomo не запущен, браузер ничего не грузит. Ссылку, по которой кликнули во вкладке через proxy, приложение открывает там, где выбрано, или спрашивает. В вопросе можно запомнить выбор.",
                               "Agent sign-in, MCP OAuth and other pages a proxied tab opens by itself load in the built-in browser through the same mihomo. With mihomo stopped the browser loads nothing. A link you click in a proxied tab opens where you picked, or the app asks. The question can remember your choice."))
            }
        } else {
            ProgressView()
        }
        if let h = data?.hostRun {
            GlassSection {
                HStack(spacing: 12) {
                    Text("host-run").font(.system(size: 17, weight: .semibold))
                    Text(l.t("Команды, которые приложение запускает вне песочницы с прямой сетью", "Commands the app runs outside the sandbox with direct network access"))
                        .foregroundStyle(Ink.muted)
                        .lineLimit(2)
                    Spacer()
                    Button(l.t("Добавить команду", "Add command")) { adding = true }
                        .buttonStyle(PillStyle(prominent: true))
                }
                HStack(spacing: 8) {
                    GlowDot(color: h.running ? Ink.tealDot : Ink.amberDot)
                    Text(h.running ? l.t("Исполнитель работает", "The runner is running") + (h.version.map { ", " + $0 } ?? "")
                                   : l.t("Исполнитель не запущен, он поднимется с новой сессией через proxy", "The runner isn't running, it starts with a new proxied session"))
                }
                .font(.system(size: 12))
                .foregroundStyle(h.running ? Ink.teal : Ink.amber)
                HostRunTable(commands: h.commands, l: l) { name in
                    Task { _ = await backend.perform(["host-run", "remove", name]); await reload() }
                }
                Note(text: l.t("Список меняешь только ты, из сессии агента он открыт на чтение. Сейчас его держит файл ~/.config/mnrh/host-run/commands.json, приложение читает тот же файл. Добавление и удаление подтверждаются окном на Mac, кнопку нажимает только мышь.",
                               "Only you can change this list. Agent sessions can read it but not write it. It lives in ~/.config/mnrh/host-run/commands.json today, and the app reads the same file. Adding and removing are confirmed in a window on the Mac, and only a mouse click counts there."))
            }
            .sheet(isPresented: $adding) {
                AddHostRunSheet(l: l) { Task { await reload() } }
            }
        }
    }
}

/// Таблица белого списка: имя, папка, команда, разрешены ли аргументы. Удаление через меню строки.
struct HostRunTable: View {
    let commands: [SettingsData.HostRun.Command]
    let l: L
    let remove: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            row(l.t("Имя", "Name"), l.t("Папка", "Folder"), l.t("Команда", "Command"), l.t("Аргументы", "Arguments"), header: true)
            ForEach(commands) { c in
                Rectangle().fill(Ink.hairline).frame(height: 1)
                row(c.name, tilde(c.cwd ?? ""), (c.run ?? []).joined(separator: " "), c.args ? l.t("да", "yes") : l.t("нет", "no"),
                    header: false, argsOn: c.args)
                    .contextMenu {
                        Button(l.t("Удалить из списка…", "Remove from the list…"), role: .destructive) { remove(c.name) }
                    }
            }
            if commands.isEmpty {
                Text(l.t("Пока пусто", "Empty for now")).foregroundStyle(Ink.muted).padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ a: String, _ b: String, _ c: String, _ d: String, header: Bool, argsOn: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(a).frame(width: 170, alignment: .leading)
            Text(b).frame(width: 200, alignment: .leading)
            Text(c).frame(maxWidth: .infinity, alignment: .leading)
            Text(d).frame(width: 80, alignment: .leading).foregroundStyle(header ? Ink.faint : argsOn ? Ink.text : Ink.faint)
        }
        .font(header ? .system(size: 11, weight: .semibold) : .system(size: 12, design: .monospaced))
        .foregroundStyle(header ? Ink.faint : Ink.text)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 12)
        .padding(.vertical, header ? 8 : 9)
    }
}

/// Добавить команду в белый список host-run. Запрос идет через исполнитель, на Mac появится окно подтверждения.
struct AddHostRunSheet: View {
    @EnvironmentObject var backend: Backend
    @Environment(\.dismiss) private var dismiss
    let l: L
    let done: () -> Void
    @State private var name = ""
    @State private var folder = ""
    @State private var command = ""
    @State private var args = false
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l.t("Новая команда host-run", "New host-run command")).font(.system(size: 17, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(l.t("Имя", "Name")).foregroundStyle(Ink.muted)
                    TextField("myapp-build", text: $name).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text(l.t("Папка", "Folder")).foregroundStyle(Ink.muted)
                    HStack {
                        TextField("~/Developer/myapp", text: $folder).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        Button(l.t("Выбрать…", "Choose…")) { choose() }
                            .buttonStyle(PillStyle(small: true))
                    }
                }
                GridRow {
                    Text(l.t("Команда", "Command")).foregroundStyle(Ink.muted)
                    TextField("swift build", text: $command).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Toggle(l.t("Сессия может дописывать аргументы", "The session may append arguments"), isOn: $args)
                }
            }
            Note(text: l.t("После \"Добавить\" на Mac появится окно исполнителя. Запись появится, только если нажать в нем \"Разрешить\" мышью или трекпадом.",
                           "After Add the runner shows a window on the Mac. The entry appears only if you click Allow there with a mouse or trackpad."))
            if failed {
                Text(l.t("Команда не добавлена: отказ, нет ответа или ошибка в запросе.", "Not added: denied, no answer or a bad request."))
                    .font(.system(size: 12)).foregroundStyle(Ink.red)
            }
            HStack {
                Spacer()
                PillButton(title: l.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                PillButton(title: l.t("Добавить", "Add"), prominent: true, busy: busy) { add() }
                    .keyboardShortcut(.defaultAction)
                .disabled(busy || name.isEmpty || folder.isEmpty || shellWords(command).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { folder = tilde(url.path) }
    }

    private func add() {
        busy = true
        failed = false
        let cwd = (folder as NSString).expandingTildeInPath
        var argv = ["host-run", "add", name, "--cwd", cwd, "--run"] + shellWords(command)
        if args { argv.append("--args") }
        Task {
            let ok = await backend.perform(argv)
            busy = false
            if ok { done(); dismiss() } else { failed = true }
        }
    }
}

/// Разбить строку команды на слова, как оболочка: пробелы, одинарные и двойные кавычки.
func shellWords(_ text: String) -> [String] {
    var words: [String] = []
    var current = ""
    var quote: Character?
    var any = false
    for ch in text {
        if let q = quote {
            if ch == q { quote = nil } else { current.append(ch) }
        } else if ch == "\"" || ch == "'" {
            quote = ch
            any = true
        } else if ch.isWhitespace {
            if any || !current.isEmpty { words.append(current) }
            current = ""
            any = false
        } else {
            current.append(ch)
        }
    }
    if any || !current.isEmpty { words.append(current) }
    return words
}


/// Действия с proxy плитками: значок, название и что произойдет. Общие для настроек и всплывающего окна
/// у значка proxy в шапке.
struct ProxyActions: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.utilityRunner) private var runner
    var columns = 2
    let reload: () async -> Void
    @State private var restarting = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            tile("checkmark.shield", l.t("Проверить выход", "Check exit"),
                 l.t("Страна и IP, с которых сессии выходят в сеть", "Country and IP your sessions go out from")) { utility(["proxy", "test"]) }
            tile("arrow.triangle.2.circlepath", l.t("Обновить подписку", "Update subscription"),
                 l.t("Заново скачать список серверов по ссылке", "Download the server list again from the link")) { utility(["proxy", "setup"]) }
            tile("power", l.t("Перезапустить mihomo", "Restart mihomo"),
                 l.t("Локальный proxy перезапустится, сессии дождутся сети", "The local proxy restarts, sessions wait for the network"),
                 busy: restarting) {
                restarting = true
                Task {
                    _ = await backend.perform(["proxy", "restart"])
                    await reload()
                    restarting = false
                }
            }
            tile("list.bullet.rectangle", l.t("Сервер и протокол", "Server and protocol"),
                 l.t("Подробный отчет во вкладке терминала", "A detailed report in a terminal tab")) { utility(["proxy"]) }
        }
    }

    private func tile(_ icon: String, _ title: String, _ desc: String, busy: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Image(systemName: icon).opacity(busy ? 0 : 1)
                    if busy { ProgressView().controlSize(.small) }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Ink.teal)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Ink.tealDot.opacity(0.16)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.text)
                    Text(desc).font(.system(size: 11)).foregroundStyle(Ink.muted).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.hover(12, .overlay))
        .disabled(busy)
    }

    /// Команда agentmeister во вкладке-утилите главного окна, как у UtilityButton.
    private func utility(_ args: [String]) {
        if let runner {
            runner(args)
            return
        }
        var spec = LaunchSpec(projectName: "agentmeister", projectPath: NSHomeDirectory())
        spec.utility = args
        workspace.open(spec)
        openWindow(id: "main")
    }
}


/// Подписки proxy: основная из proxy setup и добавленные через proxy add. Добавление и удаление идут во
/// вкладке-утилите, как proxy test: mihomo перезапускается и проверяет выход, это видно в выводе.
struct ProxySubscriptions: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.utilityRunner) private var runner
    let subscriptions: [AppState.Proxy.Subscription]
    let mainCountry: String?
    let reload: () async -> Void
    @State private var adding = false
    @State private var removing: String?
    /// Подписка, которую удаляет proxy remove прямо сейчас: mihomo перезапускается, это несколько секунд.
    @State private var deleting: String?
    @State private var problem: String?

    var l: L { L(backend.state.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(l.t("Подписки", "Subscriptions")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { adding = true } label: { Label(l.t("Добавить подписку", "Add subscription"), systemImage: "plus") }
                    .buttonStyle(PillStyle(small: true))
            }
            Note(text: subscriptions.count > 1
                 ? l.t("Через proxy по очереди сессия идет по подпискам сверху вниз. Следующая берется, когда у прошлой не отвечает ни один сервер. Подписка с другой страной в очередь не попадает, через нее можно идти только выбрав ее отдельно.",
                       "Via proxy in order, a session goes through the subscriptions from top to bottom. The next one is used when no server of the previous one answers. A subscription with another country isn't in that order and is used only when chosen on its own.")
                 : l.t("Сейчас одна подписка. Вторая пригодится как запасная, когда у основной не отвечает ни один сервер, или для сессий, которые должны идти только через нее.",
                       "There's one subscription now. A second one works as a fallback when no server of the main one answers, or for sessions that must go only through it."))
            ForEach(subscriptions, id: \.name) { s in
                row(s)
            }
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Ink.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $adding) {
            AddSubscriptionSheet(mainCountry: mainCountry, taken: subscriptions.map(\.name)) { args in
                utility(args)
                watchForChange()
            }
        }
        .confirmationDialog(l.t("Удалить подписку \(removing ?? "")?", "Remove the \(removing ?? "") subscription?"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { name in
            Button(l.t("Удалить", "Remove"), role: .destructive) {
                removing = nil
                remove(name)
            }
        } message: { _ in
            Text(l.t("Ссылка и скачанная подписка удалятся, mihomo перезапустится. Пока через нее идут сессии, удалить ее нельзя.",
                     "The link and the downloaded subscription go away and mihomo restarts. It can't be removed while sessions go through it."))
        }
    }

    private func row(_ s: AppState.Proxy.Subscription) -> some View {
        let ordered = s.inCascade != false
        let place = [s.exit ?? s.country, s.port.map { "127.0.0.1:\($0)" }].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            Text(s.name).font(.system(size: 13, weight: .medium, design: .monospaced))
            Text(place).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.muted)
            Text(ordered ? l.t("в очереди", "in order") : l.t("только отдельно", "on its own only"))
                .font(.system(size: 11))
                .foregroundStyle(ordered ? Ink.teal : Ink.direct)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(ordered ? Ink.tealChip : Ink.amberDot.opacity(0.14)))
            Spacer()
            action(s.name)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ink.card))
    }

    @ViewBuilder private func action(_ name: String) -> some View {
        if name == "main" {
            Text(l.t("основная", "main")).font(.system(size: 11)).foregroundStyle(Ink.faint)
        } else if deleting == name {
            ProgressView().controlSize(.small)
        } else {
            Button(l.t("Удалить", "Remove"), role: .destructive) { removing = name }
                .buttonStyle(.textLink(Ink.red))
                .foregroundStyle(Ink.red)
                .font(.system(size: 12))
                .disabled(deleting != nil)
        }
    }

    /// proxy remove без терминала: ссылку вводить не нужно, а ошибку (через подписку идут сессии) показываем здесь.
    private func remove(_ name: String) {
        deleting = name
        problem = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Backend.runForText(["proxy", "remove", name]) }.value
            await reload()
            deleting = nil
            if !result.ok {
                // последняя строка вывода и есть причина, значок в начале не нужен
                let line = result.text.split(separator: "\n").last.map(String.init) ?? ""
                problem = line.replacingOccurrences(of: "^[✗!✓] ", with: "", options: .regularExpression)
            }
        }
    }

    /// Подписку добавляет вкладка-утилита, и когда она закончит, неизвестно. Список перечитывается, пока в нем
    /// не появится новое имя, но не дольше трех минут.
    private func watchForChange() {
        let before = Set(subscriptions.map(\.name))
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(3))
                await reload()
                if Set(subscriptions.map(\.name)) != before { return }
            }
        }
    }

    private func utility(_ args: [String]) {
        if let runner {
            runner(args)
            return
        }
        var spec = LaunchSpec(projectName: "agentmeister", projectPath: NSHomeDirectory())
        spec.utility = args
        workspace.open(spec)
        openWindow(id: "main")
    }
}

/// Новая подписка: имя, страна выхода и отбор серверов. Запускает agentmeister proxy add во вкладке-утилите, а
/// ссылку спрашивает уже она, скрытым вводом: в аргументах ее видно в ps и в заголовке вкладки.
struct AddSubscriptionSheet: View {
    @EnvironmentObject var backend: Backend
    @Environment(\.dismiss) private var dismiss
    let mainCountry: String?
    let taken: [String]
    let run: ([String]) -> Void
    @State private var name = ""
    @State private var country = ""
    @State private var only = ""

    var l: L { L(backend.state.lang) }

    private var nameError: String? {
        if name.isEmpty { return nil }
        if name.range(of: "^[a-z][a-z0-9-]{0,19}$", options: .regularExpression) == nil {
            return l.t("Латинские строчные буквы, цифры и дефис, до 20 знаков, с буквы", "Lowercase Latin letters, digits and dashes, up to 20, starting with a letter")
        }
        if ["main", "vps", "direct", "reject", "all"].contains(name) { return l.t("Это имя занято", "This name is reserved") }
        if taken.contains(name) { return l.t("Такая подписка уже есть, ее ссылка заменится", "This subscription exists, its link will be replaced") }
        return nil
    }

    private var ready: Bool {
        let nameOK = name.range(of: "^[a-z][a-z0-9-]{0,19}$", options: .regularExpression) != nil
            && !["main", "vps", "direct", "reject", "all"].contains(name)
        let countryOK = country.isEmpty || country.range(of: "^[A-Za-z]{2}$", options: .regularExpression) != nil
        let onlyOK = only.isEmpty || (try? NSRegularExpression(pattern: only)) != nil
        return nameOK && countryOK && onlyOK
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l.t("Новая подписка", "New subscription")).font(.system(size: 20, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text(l.t("Имя", "Name")).foregroundStyle(Ink.muted)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("home", text: $name).textFieldStyle(.roundedBorder)
                        if let nameError { Text(nameError).font(.system(size: 11)).foregroundStyle(Ink.direct) }
                    }
                }
                GridRow {
                    Text(l.t("Страна", "Country")).foregroundStyle(Ink.muted)
                    TextField(mainCountry ?? "DE", text: $country).textFieldStyle(.roundedBorder).frame(width: 80)
                }
                GridRow {
                    Text(l.t("Серверы", "Servers")).foregroundStyle(Ink.muted)
                    TextField(l.t("все, или выражение для имени, например DE", "all, or a name pattern such as DE"), text: $only)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Note(text: mainCountry.map { c in
                l.t("В очередь просто -x подписка попадет, только если ее страна \(c), как у основной. С другой страной через нее можно идти только выбрав ее отдельно.",
                    "Plain -x uses this subscription in order only if its country is \(c), like the main one. With another country it's used only when chosen on its own.")
            } ?? l.t("Если страна задана, а выход через подписку окажется в другой стране, подписка не добавится.",
                     "If a country is set and the subscription exits elsewhere, it won't be added."))
            Note(text: l.t("Ссылку на подписку спросит вкладка, которая откроется, на экране ее видно не будет. Хранится она в ~/.config/mnrh/proxy/subs/, читать ее можешь только ты.",
                           "The tab that opens asks for the subscription link and doesn't show it. It's kept in ~/.config/mnrh/proxy/subs/, readable only by you."))
            HStack {
                Spacer()
                Button(l.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(l.t("Дальше", "Continue")) {
                    let code = country.trimmingCharacters(in: .whitespaces).uppercased()
                    run(["proxy", "add", name] + (code.isEmpty ? [] : ["--country", code]) + (only.isEmpty ? [] : ["--only", only]))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
