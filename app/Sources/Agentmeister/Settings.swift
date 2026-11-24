import SwiftUI

struct SettingsData: Decodable {
    struct Notify: Decodable {
        struct Telegram: Decodable {
            let connected: Bool
            let bot: String?
            let when: String
            let away: Int
            let approve: Bool
        }

        struct Phone: Decodable {
            let mode: String
            let configured: Bool
        }

        let on: Bool
        let after: Int
        let sound: Bool
        let telegram: Telegram
        let phone: Phone
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
        let buildlogDir: String
        let lidReady: Bool
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
    @AppStorage("settingsSection") private var section = SettingsSection.proxy.rawValue

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
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(item == current ? .isSelected : [])
                }
                Spacer()
            }
            .padding(10)
            .padding(.top, 30)
            .frame(width: 210)
            .frame(maxHeight: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(8)
            .accessibilityLabel(l.t("Разделы настроек", "Settings sections"))

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
                .padding(.top, 36)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea(edges: .top)
        .toolbar(removing: .title)
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

    var body: some View {
        Button(title) {
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
        .help("agentmeister " + args.joined(separator: " "))
        .buttonStyle(.glass)
    }
}

/// Кнопка, которая выполняет команду agentmeister и перечитывает настройки.
struct CommandButton: View {
    @EnvironmentObject var backend: Backend
    let title: String
    let args: [String]
    let reload: () async -> Void
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
            if busy { ProgressView().controlSize(.small) } else { Text(title) }
        }
        .buttonStyle(.glass)
        .disabled(busy)
    }
}

/// Язык и вид. Язык общий с CLI (agentmeister lang), вид хранит само приложение.
struct GeneralPane: View {
    @EnvironmentObject var backend: Backend
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue

    var l: L { L(backend.state.lang) }

    var body: some View {
        PaneTitle(l.t("Основные", "General"))
        GlassSection {
            Text(l.t("Язык", "Language")).font(.system(size: 13, weight: .semibold))
            SegmentedCapsule(selection: Binding(
                get: { backend.state.langSetting ?? "auto" },
                set: { value in Task { _ = await backend.perform(["lang", value]) } }
            ), options: [("auto", l.t("Как в системе", "System"), nil), ("ru", "Русский", nil), ("en", "English", nil)])
            .frame(maxWidth: 440)
            Note(text: l.t("Язык общий для приложения и agentmeister в терминале, это agentmeister lang. Как в системе значит русский, только если он стоит первым в macOS, иначе английский.",
                           "The app and agentmeister in a terminal share it, same as agentmeister lang. System means Russian only when it comes first in macOS, English otherwise."))
        }
        GlassSection {
            Text(l.t("Оформление", "Appearance")).font(.system(size: 13, weight: .semibold))
            AppearancePicker(selection: $appearance, l: l)
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

/// Три карточки с превью темы, выбранная обведена акцентом. Как в макете первого запуска.
struct AppearancePicker: View {
    @Binding var selection: String
    let l: L

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Appearance.allCases, id: \.self) { item in
                let on = selection == item.rawValue
                Button {
                    selection = item.rawValue
                    Appearance.apply(item.rawValue)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        preview(item)
                            .frame(height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Text(item == .system ? l.t("Как в системе", "System") : item == .light ? l.t("Светлая", "Light") : l.t("Темная", "Dark"))
                            .fontWeight(.medium)
                            .foregroundStyle(Ink.text)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Ink.card))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: 520)
    }

    @ViewBuilder
    private func preview(_ item: Appearance) -> some View {
        let light = LinearGradient(colors: [Color(hex: 0xBCD8EA), Color(hex: 0xE2D0EE)], startPoint: .topLeading, endPoint: .bottomTrailing)
        let dark = LinearGradient(colors: [Color(hex: 0x1D4C68), Color(hex: 0x4E3566)], startPoint: .topLeading, endPoint: .bottomTrailing)
        switch item {
        case .light: light
        case .dark: dark
        case .system: HStack(spacing: 0) { light; dark }
        }
    }
}

/// Proxy и host-run одним разделом, как в макете Settings.dc.html.
struct ProxyHostRunPane: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    let data: SettingsData?
    let reload: () async -> Void
    @AppStorage(BrowserSettings.forAgentKey) private var browserForAgent = true
    @AppStorage(BrowserSettings.forLinksKey) private var browserForLinks = false
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
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if p.configured {
                        UtilityButton(title: l.t("Проверить выход", "Check exit"), args: ["proxy", "test"])
                        UtilityButton(title: l.t("Обновить подписку", "Update subscription"), args: ["proxy", "setup"])
                        CommandButton(title: l.t("Перезапустить mihomo", "Restart mihomo"), args: ["proxy", "restart"], reload: reload)
                        UtilityButton(title: l.t("Сервер и протокол подробно", "Server and protocol details"), args: ["proxy"])
                            .buttonStyle(.link)
                            .lineLimit(1)
                            .fixedSize()
                        Spacer()
                        Button(l.t("Удалить proxy", "Remove proxy"), role: .destructive) { confirmRemove = true }
                            .foregroundStyle(Ink.red)
                    } else {
                        UtilityButton(title: l.t("Настроить proxy", "Set up proxy"), args: ["proxy", "setup"])
                            .buttonStyle(.glassProminent)
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
                Toggle(l.t("Страницы от агента во встроенном браузере", "Pages the agent opens go to the built-in browser"), isOn: $browserForAgent)
                Toggle(l.t("Ссылки по клику из вкладки тоже", "Links you click in a tab too"), isOn: $browserForLinks)
                Note(text: l.t("Вход в агента, OAuth для MCP и другие страницы, которые агент во вкладке через proxy открывает сам, грузятся во встроенном браузере через тот же mihomo. Если mihomo не запущен, браузер ничего не грузит.",
                               "Agent sign-in, MCP OAuth and other pages a proxied tab opens by itself load in the built-in browser through the same mihomo. With mihomo stopped the browser loads nothing."))
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
                        .buttonStyle(.glassProminent)
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
                Button(l.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    add()
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text(l.t("Добавить", "Add")) }
                }
                .buttonStyle(.glassProminent)
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

