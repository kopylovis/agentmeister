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
            let on: Bool
        }

        let on: Bool
        let rules: [Rule]
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
    }

    struct Agent: Decodable {
        let installed: Bool
        let path: String?
        let version: String?
        let signedIn: Bool?
        let plan: String?
    }

    let notify: Notify?
    let `guard`: Guard?
    let hostRun: HostRun?
    let proxy: Proxy?
    let modes: [String: Bool]?
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

/// Окно настроек (⌘,). Значения берутся из agentmeister app-state settings, изменения идут теми же командами,
/// что в CLI: notify, guard, proxy. Шаги, которым нужен терминал (подписка proxy, sudo для lid, токен бота),
/// открываются служебной вкладкой в главном окне.
struct SettingsView: View {
    @EnvironmentObject var backend: Backend
    @State private var data: SettingsData?

    var l: L { L(backend.state.lang) }

    var body: some View {
        TabView {
            Tab(l.t("Основные", "General"), systemImage: "gearshape") {
                GeneralPane()
            }
            Tab(l.t("Proxy", "Proxy"), systemImage: "shield.lefthalf.filled") {
                ProxyPane(data: data, reload: reload)
            }
            Tab("host-run", systemImage: "terminal") {
                HostRunPane(data: data, reload: reload)
            }
            Tab(l.t("Уведомления", "Notifications"), systemImage: "bell") {
                NotifyPane(data: data, reload: reload)
            }
            Tab(l.modes, systemImage: "switch.2") {
                ModesPane(data: data, reload: reload)
            }
            Tab(l.t("Агенты", "Agents"), systemImage: "cpu") {
                AgentsPane(data: data)
            }
            Tab(l.t("Диагностика", "Diagnostics"), systemImage: "stethoscope") {
                DoctorPane()
            }
        }
        .frame(width: 640, height: 520)
        .task { await reload() }
    }

    func reload() async {
        data = await backend.settings()
    }
}

/// Открыть служебную вкладку с командой agentmeister в главном окне.
struct UtilityButton: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var backend: Backend
    @Environment(\.openWindow) private var openWindow
    let title: String
    let args: [String]

    var body: some View {
        Button(title) {
            let home = NSHomeDirectory()
            var spec = LaunchSpec(projectName: "agentmeister", projectPath: home)
            spec.utility = args
            workspace.open(spec)
            openWindow(id: "main")
        }
        .help("agentmeister " + args.joined(separator: " "))
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
        .disabled(busy)
    }
}

/// Язык интерфейса. Тот же, что у CLI: agentmeister lang пишет его в ~/.config/mnrh/config.
struct GeneralPane: View {
    @EnvironmentObject var backend: Backend

    var l: L { L(backend.state.lang) }

    var body: some View {
        Form {
            Section {
                Picker(l.t("Язык", "Language"), selection: Binding(
                    get: { backend.state.langSetting ?? "auto" },
                    set: { value in
                        Task { _ = await backend.perform(["lang", value]) }
                    }
                )) {
                    Text(l.t("Как в macOS", "Same as macOS")).tag("auto")
                    Text("English").tag("en")
                    Text("Русский").tag("ru")
                }
            } footer: {
                Text(l.t("Язык общий для приложения и agentmeister в терминале, это agentmeister lang. Как в macOS значит русский, только если он стоит первым в системе, иначе английский.",
                         "The app and agentmeister in a terminal share it, same as agentmeister lang. Same as macOS means Russian only when it comes first in System Settings, English otherwise."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ProxyPane: View {
    @EnvironmentObject var backend: Backend
    let data: SettingsData?
    let reload: () async -> Void
    @AppStorage(BrowserSettings.forAgentKey) private var browserForAgent = true
    @AppStorage(BrowserSettings.forLinksKey) private var browserForLinks = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        Form {
            if let p = data?.proxy {
                Section {
                    LabeledContent(l.status) {
                        Text(!p.configured ? l.proxyOff : p.running == true ? l.t("mihomo работает", "mihomo running") : l.proxyIdle)
                            .foregroundStyle(p.running == true ? Color.teal : Color.secondary)
                    }
                    if let exit = p.exit {
                        LabeledContent(l.t("Выход", "Exit"), value: [exit, p.protocol].compactMap { $0 }.joined(separator: " · "))
                    }
                    if let country = p.country {
                        LabeledContent(l.t("Страна по настройке", "Preferred country"), value: country)
                    }
                    if let n = p.sessions {
                        LabeledContent(l.t("Сессий через proxy", "Proxied sessions"), value: "\(n)")
                    }
                } footer: {
                    Text(l.t("Сессия через proxy идет в sandbox-exec. Claude Code ходит в сеть на порты 80 и 443 только через mihomo, SSH и локальные серверы работают. У Codex строгий профиль, вся сеть только через mihomo.",
                             "A proxied session runs in sandbox-exec. Claude Code reaches ports 80 and 443 only through mihomo, SSH and local servers work. Codex gets the strict profile, all network goes through mihomo."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle(l.t("Страницы от агента во встроенном браузере", "Pages the agent opens go to the built-in browser"),
                           isOn: $browserForAgent)
                    Toggle(l.t("Ссылки по клику из вкладки тоже", "Links you click in a tab too"), isOn: $browserForLinks)
                } header: {
                    Text(l.t("Браузер через proxy", "Proxy browser"))
                } footer: {
                    Text(l.t("Вход в агента, OAuth для MCP и другие страницы, которые агент во вкладке через proxy открывает сам, грузятся во встроенном браузере через тот же mihomo. Ссылки из вкладки входа тоже. Если mihomo не запущен, браузер ничего не грузит. Изменение действует для новых вкладок.",
                             "Agent sign-in, MCP OAuth and other pages a proxied tab opens by itself load in the built-in browser through the same mihomo. So do links in a sign-in tab. With mihomo stopped the browser loads nothing. Applies to new tabs."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        CommandButton(title: l.t("Перезапустить mihomo", "Restart mihomo"), args: ["proxy", "restart"], reload: reload)
                        CommandButton(title: l.t("Обновить mihomo", "Update mihomo"), args: ["proxy", "update"], reload: reload)
                    }
                    HStack {
                        UtilityButton(title: l.t("Проверить выход", "Check the exit"), args: ["proxy", "test"])
                        UtilityButton(title: p.configured ? l.t("Сменить подписку", "Change subscription") : l.t("Настроить proxy", "Set up proxy"),
                                      args: ["proxy", "setup"])
                    }
                }
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
    }
}

struct HostRunPane: View {
    @EnvironmentObject var backend: Backend
    let data: SettingsData?
    let reload: () async -> Void

    var l: L { L(backend.state.lang) }

    var body: some View {
        Form {
            if let h = data?.hostRun {
                Section {
                    LabeledContent(l.t("Исполнитель", "Runner")) {
                        Text(h.running ? l.t("работает", "running") + (h.version.map { ", " + $0 } ?? "") : l.t("не запущен", "not running"))
                            .foregroundStyle(h.running ? Color.teal : Color.orange)
                    }
                } footer: {
                    Text(l.t("Команды из этого списка сессии через proxy запускают вне песочницы с прямой сетью. Список меняешь ты: сессия может только попросить, и на маке появится окно подтверждения. Исполнитель поднимается вместе с proxy-сессией.",
                             "Proxied sessions run these commands outside the sandbox with direct network. Only you change the list: a session can ask, and a confirmation window appears on the Mac. The runner starts with a proxied session."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(l.t("Белый список", "Allowlist")) {
                    if h.commands.isEmpty {
                        Text(l.t("Пусто", "Empty")).foregroundStyle(.secondary)
                    }
                    ForEach(h.commands) { c in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(c.name).font(.system(.body, design: .monospaced)).fontWeight(.medium)
                                if c.args {
                                    Text(l.t("+ аргументы", "+ arguments")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text((c.run ?? []).joined(separator: " "))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if let cwd = c.cwd {
                                Text(tilde(cwd)).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
    }
}

struct NotifyPane: View {
    @EnvironmentObject var backend: Backend
    let data: SettingsData?
    let reload: () async -> Void

    var l: L { L(backend.state.lang) }

    private func run(_ args: [String]) {
        Task {
            _ = await backend.perform(args)
            await reload()
        }
    }

    var body: some View {
        Form {
            if let n = data?.notify {
                Section(l.t("На этом Mac", "On this Mac")) {
                    Toggle(l.t("Уведомления", "Notifications"), isOn: Binding(get: { n.on }, set: { run(["notify", $0 ? "on" : "off"]) }))
                    Stepper(value: Binding(get: { n.after }, set: { run(["notify", "after", String(max(0, $0))]) }), in: 0...600, step: 10) {
                        LabeledContent(l.t("Сообщать о конце хода дольше", "Tell me when a turn took longer than"), value: l.t("\(n.after) с", "\(n.after) s"))
                    }
                    Toggle(l.t("Звук Prompt", "Prompt sound"), isOn: Binding(get: { n.sound }, set: { run(["notify", "sound", $0 ? "on" : "off"]) }))
                    CommandButton(title: l.t("Отправить тест", "Send a test"), args: ["notify", "test"], reload: reload)
                }
                Section("Telegram") {
                    if n.telegram.connected {
                        LabeledContent(l.t("Бот", "Bot"), value: n.telegram.bot.map { "@" + $0 } ?? l.t("подключен", "connected"))
                        Picker(l.t("Присылать", "Send"), selection: Binding(get: { n.telegram.when }, set: { run(["notify", "telegram", $0]) })) {
                            Text(l.t("Когда я не за Mac", "When I'm away")).tag("away")
                            Text(l.t("Всегда", "Always")).tag("always")
                        }
                        Toggle(l.t("Отвечать на запросы разрешений из Telegram", "Answer permission requests from Telegram"),
                               isOn: Binding(get: { n.telegram.approve }, set: { run(["notify", "telegram", "approve", $0 ? "on" : "off"]) }))
                        Text(l.t("Разрешить команду на Mac сможет любой, кто откроет твой Telegram или получит токен бота. Включай, только если у аккаунта есть пароль и двухэтапная проверка.",
                                 "Anyone who can open your Telegram or holds the bot token can allow a command on your Mac. Turn this on only if the account has a password and two-step verification."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                        HStack {
                            CommandButton(title: l.t("Тест", "Test"), args: ["notify", "telegram", "test"], reload: reload)
                            CommandButton(title: l.t("Отключить", "Disconnect"), args: ["notify", "telegram", "off"], reload: reload)
                        }
                    } else {
                        UtilityButton(title: l.t("Подключить бота", "Connect a bot"), args: ["notify", "telegram"])
                    }
                }
                Section(l.t("Телефон через ntfy", "Phone through ntfy")) {
                    Picker(l.t("Присылать", "Send"), selection: Binding(get: { n.phone.mode }, set: { run(["notify", "phone", $0]) })) {
                        Text(l.t("Выкл", "Off")).tag("off")
                        Text(l.t("Когда я не за Mac", "When I'm away")).tag("away")
                        Text(l.t("Всегда", "Always")).tag("always")
                    }
                    .disabled(!n.phone.configured)
                    if !n.phone.configured {
                        Text(l.t("ntfy не настроен", "ntfy isn't configured")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
    }
}

struct ModesPane: View {
    @EnvironmentObject var backend: Backend
    let data: SettingsData?
    let reload: () async -> Void

    var l: L { L(backend.state.lang) }

    private func run(_ args: [String]) {
        Task {
            _ = await backend.perform(args)
            await reload()
        }
    }

    var body: some View {
        Form {
            if let modes = data?.modes {
                Section {
                    ForEach(["humanize", "guard", "buildlog", "notify", "lid"], id: \.self) { key in
                        Toggle(l.modeTitle(key), isOn: Binding(get: { modes[key] ?? false }, set: { run([key, $0 ? "on" : "off"]) }))
                    }
                } footer: {
                    Text(l.t("Те же переключатели, что в меню agentmeister и на боковой панели.", "The same switches as in the agentmeister menu and the sidebar."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let g = data?.guard {
                    Section(l.t("Правила guard", "guard rules")) {
                        ForEach(g.rules) { rule in
                            Toggle(isOn: Binding(get: { rule.on }, set: { run(["guard", $0 ? "unskip" : "skip", rule.id]) })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.id).font(.system(.body, design: .monospaced))
                                    Text(rule.text).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!g.on)
                        }
                        UtilityButton(title: l.t("Последние срабатывания", "Recent hits"), args: ["guard", "log"])
                    }
                }
                Section(l.t("Не спать с закрытой крышкой", "Stay awake with the lid closed")) {
                    Text(l.t("Для pmset нужен пароль администратора, поэтому настройка идет в терминале.", "pmset needs an administrator password, so setup runs in a terminal."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    UtilityButton(title: l.t("Настроить lid", "Set up lid"), args: ["lid", "setup"])
                }
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
    }
}

struct AgentsPane: View {
    @EnvironmentObject var backend: Backend
    let data: SettingsData?

    var l: L { L(backend.state.lang) }

    var body: some View {
        Form {
            if let data {
                agent("Claude Code", data.claude, install: ["--harness", "claude", "install"], setup: ["setup"])
                agent("Codex", data.codex, install: ["--harness", "codex", "install"], setup: ["--harness", "codex", "setup"])
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func agent(_ name: String, _ info: SettingsData.Agent?, install: [String], setup: [String]) -> some View {
        Section(name) {
            if let info, info.installed {
                LabeledContent(l.t("Версия", "Version"), value: info.version ?? "?")
                LabeledContent(l.t("Путь", "Path"), value: tilde(info.path ?? ""))
                UtilityButton(title: l.t("Хуки, MCP и команды", "Hooks, MCP and commands"), args: setup)
            } else {
                Text(l.t("Не установлен", "Not installed")).foregroundStyle(.orange)
                UtilityButton(title: l.t("Установить", "Install"), args: install)
            }
        }
    }
}

struct DoctorPane: View {
    @EnvironmentObject var backend: Backend
    @State private var data: DoctorData?
    @State private var loading = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        Form {
            Section {
                if let data {
                    ForEach(data.rows, id: \.self) { row in
                        Label {
                            Text(row.text)
                        } icon: {
                            Image(systemName: row.level == "ok" ? "checkmark.circle.fill" : row.level == "warn" ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(row.level == "ok" ? Color.teal : row.level == "warn" ? Color.orange : Color.red)
                        }
                    }
                } else if loading {
                    ProgressView()
                }
            } header: {
                HStack {
                    Text(summary)
                    Spacer()
                    Button(l.t("Проверить снова", "Check again")) { Task { await load() } }
                        .disabled(loading)
                }
            }
            Section {
                UtilityButton(title: l.t("agentmeister setup", "agentmeister setup"), args: ["setup"])
            } footer: {
                Text(l.t("setup ставит команды, хуки, MCP-сервер, хук zsh и promptsill заново.", "setup reinstalls commands, hooks, the MCP server, the zsh hook and promptsill."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private var summary: String {
        guard let rows = data?.rows else { return l.t("Проверка…", "Checking…") }
        let bad = rows.filter { $0.level == "bad" }.count
        let warn = rows.filter { $0.level == "warn" }.count
        if bad > 0 { return l.t("ошибок \(bad)", "\(bad) errors") }
        if warn > 0 { return l.t("замечаний \(warn)", "\(warn) warnings") }
        return l.t("все в порядке", "all good")
    }

    private func load() async {
        loading = true
        data = await backend.doctor()
        loading = false
    }
}
