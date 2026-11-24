import AppKit
import SwiftTerm
import SwiftUI

/// Переключатель в заголовке карточки, как role="switch" в макете.
struct HeaderSwitch: View {
    let label: String
    let on: Bool
    let set: (Bool) -> Void

    var body: some View {
        Toggle(label, isOn: Binding(get: { on }, set: set))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(label)
    }
}

// MARK: - Режимы

/// Режимы по макету SettingsPanes pane=modes: слева guard с правилами, проверкой команды и журналом,
/// справа humanize, buildlog и lid.
struct ModesPane: View {
    @EnvironmentObject var backend: Backend
    let data: SettingsData?
    let reload: () async -> Void
    @State private var test = "git push --force origin main"
    @State private var result: GuardTest?

    var l: L { L(backend.state.lang) }

    private func run(_ args: [String]) {
        Task {
            _ = await backend.perform(args)
            await reload()
        }
    }

    var body: some View {
        PaneTitle(l.modes)
        if let modes = data?.modes {
            HStack(alignment: .top, spacing: 16) {
                if let g = data?.guard {
                    GlassSection(spacing: 12) {
                        HStack {
                            Text("guard").font(.system(size: 17, weight: .semibold))
                            Spacer()
                            HeaderSwitch(label: "guard", on: modes["guard"] ?? g.on) { run(["guard", $0 ? "on" : "off"]) }
                        }
                        Note(text: l.t("Спрашивает перед рискованным вызовом, а не запрещает его. В режиме auto держит вызов, и агент спрашивает тебя в чате. Остальное решают обычные разрешения агента.",
                                       "Asks before a risky call instead of refusing. In auto mode it holds the call and the agent asks you in the chat. Everything else is left to the agent's normal permissions."))
                        ForEach(g.rules) { rule in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rule.id).font(.system(size: 12, weight: .bold, design: .monospaced))
                                    Text(l.en ? (rule.textEn ?? rule.text) : rule.text)
                                        .font(.system(size: 12)).foregroundStyle(Ink.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                HeaderSwitch(label: rule.id, on: rule.on) { run(["guard", $0 ? "unskip" : "skip", rule.id]) }
                                    .disabled(!(modes["guard"] ?? g.on))
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(l.t("Проверить команду", "Test a command")).font(.system(size: 12)).foregroundStyle(Ink.muted)
                            HStack {
                                TextField("", text: $test)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .onSubmit(check)
                                Button(l.t("Проверить", "Test"), action: check)
                            }
                            if let result {
                                Text(describe(result))
                                    .font(.system(size: 12))
                                    .foregroundStyle(result.rule == nil ? Ink.teal : Ink.amber)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(l.t("Последние срабатывания", "Recent hits")).font(.system(size: 12)).foregroundStyle(Ink.muted)
                            Text((g.log ?? []).isEmpty ? l.t("пока не было", "none yet") : (g.log ?? []).joined(separator: "\n"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Ink.text2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Ink.card))
                            if let path = g.logPath {
                                Button(tilde(path)) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                                    .buttonStyle(.link)
                                    .font(.system(size: 12))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                VStack(spacing: 16) {
                    modeCard("humanize", on: modes["humanize"],
                             l.t("Правила письма без примет нейросети для Claude Code и Codex. Касаются ответов, коммитов, PR и документации, но не самого кода.",
                                 "Writing rules without AI tells for Claude Code and Codex. They cover replies, commits, PRs and docs, not the code itself."),
                             meta: nil)
                    let info = data?.modesInfo
                    modeCard("buildlog", on: modes["buildlog"],
                             l.t("Когда сборка Gradle, xcodebuild, swift, npm, pytest или make выводит больше \(info?.buildlogLines ?? 200) строк или 20 КБ, агент получает выжимку с ошибками и итогами.",
                                 "When a Gradle, xcodebuild, swift, npm, pytest or make build prints more than \(info?.buildlogLines ?? 200) lines or 20 KB, the agent gets a digest with errors and totals."),
                             meta: info.map { (l.t("Полные логи хранятся \($0.buildlogDays) дней в ", "Full logs kept for \($0.buildlogDays) days in ") + tilde($0.buildlogDir) + "/", Ink.muted) })
                    GlassSection(spacing: 10) {
                        Text("lid").font(.system(size: 17, weight: .semibold))
                        Note(text: l.t("Mac не засыпает с закрытой крышкой, пока идет сессия \"не спать\". Отпускает через 2 минуты после последней или при 15% батареи. Mac в закрытой сумке греется.",
                                       "The Mac stays awake with the lid closed while a stay-awake session runs. Lets go 2 minutes after the last one or at 15% battery. A Mac in a closed bag gets hot."))
                        let ready = info?.lidReady ?? false
                        Text(ready ? l.t("Готов, pmset работает без пароля", "Ready, pmset runs without a password")
                                   : l.t("Не настроен, pmset нужен пароль администратора", "Not set up, pmset needs an administrator password"))
                            .font(.system(size: 12))
                            .foregroundStyle(ready ? Ink.teal : Ink.amber)
                    }
                    if !(data?.modesInfo?.lidReady ?? false) {
                        HStack {
                            UtilityButton(title: l.t("Настроить", "Set up"), args: ["lid", "setup"])
                                .buttonStyle(.glassProminent)
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            ProgressView()
        }
    }

    private func modeCard(_ name: String, on: Bool?, _ text: String, meta: (String, Color)?) -> some View {
        GlassSection(spacing: 10) {
            HStack {
                Text(name).font(.system(size: 17, weight: .semibold))
                Spacer()
                HeaderSwitch(label: name, on: on ?? false) { run([name, $0 ? "on" : "off"]) }
            }
            Note(text: text)
            if let meta {
                Text(meta.0).font(.system(size: 12)).foregroundStyle(meta.1)
            }
        }
    }

    private func check() {
        let command = test
        Task { result = await Backend.json(["app-state", "guard-test", command]) }
    }

    private func describe(_ r: GuardTest) -> String {
        guard let rule = r.rule else { return l.t("Пропустит", "Will let it through") }
        let head = r.off == true ? l.t("Правило \(rule) выключено, пропустит", "Rule \(rule) is off, will let it through")
                                 : l.t("Спросит, правило \(rule)", "Will ask, rule \(rule)")
        return head + (r.why.map { ", " + $0 } ?? "")
    }
}

/// Ответ app-state guard-test.
struct GuardTest: Decodable {
    let rule: String?
    let why: String?
    let off: Bool?
}

// MARK: - Уведомления

/// Уведомления по макету Notify.dc.html: Mac, Telegram, телефон.
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

    private func row<Control: View>(_ title: String, _ sub: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(sub).font(.system(size: 12)).foregroundStyle(Ink.muted)
            }
            Spacer()
            control()
        }
    }

    var body: some View {
        PaneTitle(l.t("Уведомления", "Notifications"))
        if let n = data?.notify {
            GlassSection {
                row(l.t("Уведомления на этом Mac", "Notifications on this Mac"),
                    l.t("Когда агент просит разрешение, задает вопрос или минуту ждет тебя", "When an agent asks for permission, asks a question or waits a minute for you")) {
                    HeaderSwitch(label: "notify", on: n.on) { run(["notify", $0 ? "on" : "off"]) }
                }
                row(l.t("Сообщать, если ход длился дольше", "Tell me when a turn took longer than"),
                    l.t("Короткие ответы проходят тихо", "Short replies stay quiet")) {
                    HStack(spacing: 6) {
                        NumberField(value: n.after) { run(["notify", "after", String($0)]) }
                        Text(l.t("с", "s")).foregroundStyle(Ink.muted)
                    }
                }
                row(l.t("Звук Prompt", "Prompt sound"), l.t("Без него уведомления приходят беззвучно", "Without it notifications arrive silently")) {
                    HeaderSwitch(label: "sound", on: n.sound) { run(["notify", "sound", $0 ? "on" : "off"]) }
                }
                HStack {
                    CommandButton(title: l.t("Прислать тест", "Send test"), args: ["notify", "test"], reload: reload)
                    Spacer()
                }
            }
            GlassSection {
                HStack(spacing: 10) {
                    Text("Telegram").font(.system(size: 17, weight: .semibold))
                    if n.telegram.connected {
                        StatusChip(text: l.t("бот подключен", "bot connected") + (n.telegram.bot.map { ", @" + $0 } ?? ""), ok: true)
                    }
                    Spacer()
                    if n.telegram.connected {
                        CommandButton(title: l.t("Прислать тест", "Send test"), args: ["notify", "telegram", "test"], reload: reload)
                        CommandButton(title: l.t("Отключить", "Disconnect"), args: ["notify", "telegram", "off"], reload: reload)
                    } else {
                        UtilityButton(title: l.t("Подключить бота", "Connect a bot"), args: ["notify", "telegram"])
                            .buttonStyle(.glassProminent)
                    }
                }
                if n.telegram.connected {
                    HStack(spacing: 12) {
                        Text(l.t("Присылать", "Send")).foregroundStyle(Ink.muted)
                        SegmentedCapsule(selection: Binding(get: { n.telegram.when }, set: { run(["notify", "telegram", $0]) }),
                                         options: [("away", l.t("Когда я не за Mac", "When I'm away"), nil), ("always", l.t("Всегда", "Always"), nil)])
                            .frame(maxWidth: 360)
                        Text(l.t("Не за Mac после", "Away after")).foregroundStyle(Ink.muted)
                        NumberField(value: max(1, n.telegram.away / 60)) { run(["notify", "telegram", "away", String($0 * 60)]) }
                        Text(l.t("мин", "min")).foregroundStyle(Ink.muted)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        row(l.t("Отвечать на запросы разрешений из Telegram", "Answer permission requests from Telegram"),
                            l.t("Кнопки \"Разрешить\" и \"Отклонить\" в чате, пока ты не за Mac. Вопросы и планы остаются на Mac.",
                                "\"Allow\" and \"Deny\" buttons in the chat while you are away. Questions and plans stay on the Mac.")) {
                            HeaderSwitch(label: "approve", on: n.telegram.approve) { run(["notify", "telegram", "approve", $0 ? "on" : "off"]) }
                        }
                        Text(l.t("Разрешить команду на Mac сможет любой, кто откроет твой Telegram или получит токен бота. Включай, только если у аккаунта Telegram есть пароль и двухэтапная проверка.",
                                 "Anyone who can open your Telegram or holds the bot token can allow a command on your Mac. Turn this on only if your Telegram account has a password and two-step verification."))
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.amber)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Ink.amberDot.opacity(0.14)))
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Ink.card))
                }
            }
            GlassSection {
                Text(l.t("Телефон через ntfy", "Phone through ntfy")).font(.system(size: 17, weight: .semibold))
                Note(text: l.t("Канал claude в Tossling, вопросы и запросы с высоким приоритетом", "The claude channel in Tossling, questions and requests at high priority"))
                SegmentedCapsule(selection: Binding(get: { n.phone.mode }, set: { run(["notify", "phone", $0]) }),
                                 options: [("off", l.t("Выкл", "Off"), nil), ("away", l.t("Когда я не за Mac", "When I'm away"), nil), ("always", l.t("Всегда", "Always"), nil)])
                    .frame(maxWidth: 480)
                    .disabled(!n.phone.configured)
                if !n.phone.configured {
                    Text(l.t("ntfy не настроен", "ntfy isn't configured")).font(.system(size: 12)).foregroundStyle(Ink.amber)
                }
            }
            Note(text: l.t("Если сессия подключена к Remote Control и в /config включено Push when actions required, ее запросы и вопросы не дублируются в Telegram и на телефон. Уведомление на Mac остается.",
                           "If a session is connected to Remote Control with Push when actions required on in /config, its requests and questions are not duplicated to Telegram or the phone. The Mac notification stays."))
        } else {
            ProgressView()
        }
    }
}

/// Узкое числовое поле, 64 точки. Значение уходит по Enter или при потере фокуса.
struct NumberField: View {
    let value: Int
    let commit: (Int) -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .onAppear { text = String(value) }
            .onChange(of: value) { text = String(value) }
            .onSubmit { if let n = Int(text), n >= 0, n != value { commit(n) } }
    }
}

// MARK: - Терминал

/// Настройки терминала вкладок. Хранятся в UserDefaults, применяются ко всем вкладкам сразу.
enum TerminalPrefs {
    static let fontKey = "terminal.font"
    static let sizeKey = "terminal.size"
    static let cursorKey = "terminal.cursor"
    static let scrollbackKey = "terminal.scrollback"
    static let metaKey = "terminal.optionMeta"
    static let linksKey = "terminal.links"
    static let bellKey = "terminal.bell"
    static let colorsKey = "terminal.colors"

    static let fonts = ["SF Mono", "Menlo", "Monaco", "JetBrains Mono"]

    static var fontName: String { UserDefaults.standard.string(forKey: fontKey) ?? "SF Mono" }
    static var size: Double { UserDefaults.standard.object(forKey: sizeKey) as? Double ?? 13 }
    static var cursor: String { UserDefaults.standard.string(forKey: cursorKey) ?? "blinkBar" }
    static var scrollback: Int { UserDefaults.standard.object(forKey: scrollbackKey) as? Int ?? 10_000 }
    static var optionMeta: Bool { UserDefaults.standard.object(forKey: metaKey) as? Bool ?? true }
    static var linksAlways: Bool { UserDefaults.standard.string(forKey: linksKey) == "always" }
    static var bell: String { UserDefaults.standard.string(forKey: bellKey) ?? "tab" }
    static var alwaysDark: Bool { UserDefaults.standard.string(forKey: colorsKey) == "dark" }

    static func font(name: String = fontName, size: Double = size) -> NSFont {
        if name != "SF Mono", let font = NSFont(name: name, size: size) { return font }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func cursorStyle(_ raw: String) -> CursorStyle {
        switch raw {
        case "steadyBar": return .steadyBar
        case "blinkBlock": return .blinkBlock
        case "steadyBlock": return .steadyBlock
        case "blinkUnderline": return .blinkUnderline
        case "steadyUnderline": return .steadyUnderline
        default: return .blinkBar
        }
    }

    @MainActor
    static func apply(to view: LocalProcessTerminalView) {
        view.font = font()
        view.optionAsMetaKey = optionMeta
        view.linkHighlightMode = linksAlways ? .always : .hoverWithModifier
        view.setCursorStyle(cursorStyle(cursor))
    }
}

struct TerminalPane: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @AppStorage(TerminalPrefs.fontKey) private var font = "SF Mono"
    @AppStorage(TerminalPrefs.sizeKey) private var size = 13.0
    @AppStorage(TerminalPrefs.cursorKey) private var cursor = "blinkBar"
    @AppStorage(TerminalPrefs.scrollbackKey) private var scrollback = 10_000
    @AppStorage(TerminalPrefs.metaKey) private var optionMeta = true
    @AppStorage(TerminalPrefs.linksKey) private var links = "modifier"
    @AppStorage(TerminalPrefs.bellKey) private var bell = "tab"
    @AppStorage(TerminalPrefs.colorsKey) private var colors = "window"

    var l: L { L(backend.state.lang) }

    private func row<Control: View>(_ title: String, @ViewBuilder _ control: () -> Control) -> some View {
        HStack {
            Text(title)
            Spacer()
            control().frame(maxWidth: 220, alignment: .trailing)
        }
        .frame(minHeight: 46)
    }

    var body: some View {
        PaneTitle(l.t("Терминал", "Terminal"))
        HStack(alignment: .top, spacing: 16) {
            GlassSection(spacing: 0) {
                row(l.t("Шрифт", "Font")) {
                    Picker("", selection: $font) {
                        ForEach(TerminalPrefs.fonts.filter { $0 == "SF Mono" || NSFont(name: $0, size: 12) != nil }, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                Divider()
                row(l.t("Размер", "Size")) {
                    Stepper(value: $size, in: 9...24, step: 1) { Text("\(Int(size)) pt").monospacedDigit() }
                }
                Divider()
                row(l.t("Цвета терминала", "Terminal colors")) {
                    Picker("", selection: $colors) {
                        Text(l.t("Как у окна", "Match window")).tag("window")
                        Text(l.t("Всегда темные", "Always dark")).tag("dark")
                    }.labelsHidden()
                }
                Divider()
                row(l.t("Курсор", "Cursor")) {
                    Picker("", selection: $cursor) {
                        Text(l.t("Черта, мигает", "Bar, blinking")).tag("blinkBar")
                        Text(l.t("Черта", "Bar")).tag("steadyBar")
                        Text(l.t("Блок, мигает", "Block, blinking")).tag("blinkBlock")
                        Text(l.t("Блок", "Block")).tag("steadyBlock")
                        Text(l.t("Подчеркивание", "Underline")).tag("steadyUnderline")
                    }.labelsHidden()
                }
                Divider()
                row(l.t("Прокрутка назад", "Scrollback")) {
                    Picker("", selection: $scrollback) {
                        ForEach([2_000, 10_000, 50_000, 100_000], id: \.self) { n in
                            Text(l.t("\(n.formatted()) строк", "\(n.formatted()) lines")).tag(n)
                        }
                    }.labelsHidden()
                }
                Divider()
                row("Option " + l.t("как Meta", "as Meta")) {
                    Toggle("", isOn: $optionMeta).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                row(l.t("Ссылки", "Links")) {
                    Picker("", selection: $links) {
                        Text(l.t("по ⌘-клику", "with ⌘-click")).tag("modifier")
                        Text(l.t("всегда подчеркнуты", "always underlined")).tag("always")
                    }.labelsHidden()
                }
                Divider()
                row(l.t("Звонок", "Bell")) {
                    Picker("", selection: $bell) {
                        Text(l.t("подсветить вкладку", "highlight the tab")).tag("tab")
                        Text(l.t("звук", "sound")).tag("sound")
                        Text(l.t("ничего", "nothing")).tag("off")
                    }.labelsHidden()
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 10) {
                GlassSection(spacing: 10) {
                    Text(l.t("Пример", "Preview")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.faint)
                    preview
                    Note(text: l.t("Терминал рисует SwiftTerm. Прокрутка назад действует для новых вкладок, остальное сразу.",
                                   "SwiftTerm draws the terminal. Scrollback applies to new tabs, everything else right away."))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onChange(of: [font, cursor, links, colors]) { applyAll() }
        .onChange(of: size) { applyAll() }
        .onChange(of: optionMeta) { applyAll() }
    }

    private var preview: some View {
        let nsFont = TerminalPrefs.font(name: font, size: size)
        let mono = Font(nsFont)
        return VStack(alignment: .leading, spacing: 2) {
            Text("> " + l.t("собери debug", "build debug"))
            (Text("● ").foregroundStyle(Ink.teal) + Text("Bash(./gradlew :app:assembleDebug)")).lineLimit(1)
            Text("  ⎿  BUILD SUCCESSFUL in 41s").foregroundStyle(Color(hex: 0x8C909B))
            (Text("██▏").foregroundStyle(Ink.link) + Text(" 42% · ") + Text("███▏").foregroundStyle(Ink.amberDot) + Text(" 63%"))
        }
        .font(mono)
        .foregroundStyle(Color(hex: 0xD9DBE1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x08090B)))
    }

    private func applyAll() {
        for tab in workspace.tabs { TerminalPrefs.apply(to: tab.view) }
        workspace.objectWillChange.send()
    }
}

// MARK: - Агенты

/// Агенты по макету: агент для новых сессий и карточка на каждого.
struct AgentsPane: View {
    @EnvironmentObject var backend: Backend
    let data: SettingsData?
    let reload: () async -> Void
    @AppStorage(AgentPrefs.defaultKey) private var defaultAgent = "claude"

    var l: L { L(backend.state.lang) }

    var body: some View {
        PaneTitle(l.t("Агенты", "Agents"))
        HStack(spacing: 14) {
            Text(l.t("Агент для новых сессий", "Agent for new sessions")).foregroundStyle(Ink.muted)
            SegmentedCapsule(selection: $defaultAgent, options: [("claude", "Claude Code", nil), ("codex", "Codex", nil),
                                                                  ("ask", l.t("Спрашивать", "Ask each time"), nil)])
                .frame(maxWidth: 460)
        }
        if let data {
            HStack(alignment: .top, spacing: 16) {
                AgentCard(agent: .claude, info: data.claude, l: l, reload: reload)
                AgentCard(agent: .codex, info: data.codex, l: l, reload: reload)
            }
        } else {
            ProgressView()
        }
    }
}

/// Агент по умолчанию и флаги запуска для новых сессий.
enum AgentPrefs {
    static let defaultKey = "agent.default"
    static func flagsKey(_ agent: LaunchSpec.Agent) -> String { "agent.flags." + agent.rawValue }

    static var defaultAgent: String { UserDefaults.standard.string(forKey: defaultKey) ?? "claude" }

    static func flags(_ agent: LaunchSpec.Agent) -> [String] {
        shellWords(UserDefaults.standard.string(forKey: flagsKey(agent)) ?? "")
    }
}

struct AgentCard: View {
    let agent: LaunchSpec.Agent
    let info: SettingsData.Agent?
    let l: L
    let reload: () async -> Void
    @State private var flags = ""
    @State private var update: String?
    @State private var checking = false

    private var name: String { agent == .claude ? "Claude Code" : "Codex" }

    var body: some View {
        GlassSection {
            HStack(spacing: 12) {
                AgentBadge(agent: agent, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name + (info?.version.map { " " + $0 } ?? "")).font(.system(size: 15, weight: .semibold))
                    if info?.installed == true {
                        Text(update ?? (agent == .claude ? l.t("Обновляется при перезапуске", "Updates on restart")
                                                         : l.t("Обновляется через Homebrew", "Updates through Homebrew")))
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.teal)
                    } else {
                        Text(l.t("Не найден", "Not found")).font(.system(size: 12)).foregroundStyle(Ink.amber)
                    }
                }
                Spacer()
                if info?.installed == true {
                    Button {
                        checkUpdate()
                    } label: {
                        if checking { ProgressView().controlSize(.small) } else { Text(l.t("Проверить обновление", "Check for update")) }
                    }
                    .disabled(checking)
                    .fixedSize()
                }
            }
            if let info, info.installed {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    gridRow(l.t("Путь", "Path"), tilde(info.path ?? ""), mono: true)
                    gridRow(l.t("Установлен", "Installed with"), info.installedVia == "homebrew" ? "Homebrew"
                            : info.installedVia == "installer" ? l.t("установщик Anthropic", "Anthropic installer") : l.t("свой путь", "custom path"))
                    gridRow(l.t("Аккаунт", "Account"), info.signedIn == true
                            ? [info.email, info.plan.map { $0 + l.t("", " plan") }].compactMap { $0 }.joined(separator: " · ")
                            : l.t("вход не выполнен", "not signed in"))
                    gridRow(l.t("Модель", "Model"), info.model ?? l.t("по умолчанию", "default"))
                }
                .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(l.t("Флаги запуска по умолчанию", "Default launch flags")).font(.system(size: 12)).foregroundStyle(Ink.muted)
                    TextField(agent == .claude ? "--model opus" : "--model gpt-5", text: $flags)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { UserDefaults.standard.set(flags, forKey: AgentPrefs.flagsKey(agent)) }
                        .onChange(of: flags) { UserDefaults.standard.set(flags, forKey: AgentPrefs.flagsKey(agent)) }
                }
                FlowLayout(spacing: 8) {
                    UtilityButton(title: l.t("Сменить аккаунт", "Switch account"),
                                  args: ["proxy", "run", "--claude", "--"] + (agent == .claude ? ["claude", "auth", "login"] : ["codex", "login"]))
                    UtilityButton(title: agent == .claude ? l.t("Хуки, MCP и slash-команды", "Hooks, MCP and slash commands")
                                                          : l.t("Хуки, навык и MCP", "Hooks, skill and MCP"),
                                  args: agent == .claude ? ["setup"] : ["--harness", "codex", "setup"])
                }
            } else {
                HStack {
                    UtilityButton(title: l.t("Установить", "Install"), args: ["--harness", agent.rawValue, "install"])
                        .buttonStyle(.glassProminent)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { flags = UserDefaults.standard.string(forKey: AgentPrefs.flagsKey(agent)) ?? "" }
    }

    private func gridRow(_ title: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(title).foregroundStyle(Ink.faint).frame(width: 110, alignment: .leading)
            Text(value).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12)).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    /// Claude Code обновляется сам (claude update), у Codex смотрим brew outdated, ничего не ставя.
    private func checkUpdate() {
        checking = true
        let command = agent == .claude ? "claude update 2>&1 | tail -1" : "brew outdated --cask --greedy codex 2>&1 | tail -1"
        Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-c", command]
            task.environment = LoginEnvironment.shared
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardInput = FileHandle.nullDevice
            try? task.run()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            task.waitUntilExit()
            await MainActor.run {
                checking = false
                if agent == .codex {
                    update = out.isEmpty ? l.t("Последняя версия в Homebrew", "Up to date in Homebrew")
                                         : l.t("Есть обновление: brew upgrade codex", "Update available: brew upgrade codex")
                } else {
                    update = out.isEmpty ? l.t("Последняя версия", "Up to date") : out
                }
                Task { await reload() }
            }
        }
    }
}

// MARK: - Горячие клавиши

struct ShortcutsPane: View {
    @EnvironmentObject var backend: Backend
    @AppStorage("hotkey.showApp") private var showHotKey = true

    var l: L { L(backend.state.lang) }

    var body: some View {
        PaneTitle(l.t("Горячие клавиши", "Shortcuts"))
        HStack(alignment: .top, spacing: 16) {
            group(l.t("Сессии и вкладки", "Sessions and tabs"), [
                (l.newSession, "⌘N"), (l.t("Новая вкладка в этом проекте", "New tab in this project"), "⌘T"),
                (l.closeTab, "⌘W"), (l.t("Следующая вкладка", "Next tab"), "⌃⇥"), (l.t("Вкладка 1–9", "Tab 1–9"), "⌘1…9"),
                (l.t("К вкладке, которая ждет", "Jump to the waiting tab"), "⌘J"), (l.restart, "⌘R"),
                (l.t("Параллельная задача", "Parallel task"), "⇧⌘P"),
            ])
            group(l.t("Окна и инструменты", "Windows and tools"), [
                (l.t("Палитра команд", "Command palette"), "⌘K"), (l.t("Сессии", "Session library"), "⇧⌘O"),
                (l.t("Статистика", "Usage"), "⇧⌘U"), (l.t("Спросить другой проект", "Ask another project"), "⇧⌘A"),
                (l.t("Снимок окна", "Window screenshot"), "⇧⌘S"), (l.inspector, "⌥⌘I"),
                (l.t("Показать Agentmeister из любого приложения", "Show Agentmeister from any app"), "⌃⌥Space"),
            ])
        }
        Toggle(l.t("⌃⌥Space показывает Agentmeister из любого приложения", "⌃⌥Space shows Agentmeister from any app"), isOn: $showHotKey)
        if UserDefaults.standard.bool(forKey: "hotkey.taken") {
            Text(l.t("⌃⌥Space уже занято другим приложением, Agentmeister его не получил.", "Another app already holds ⌃⌥Space, Agentmeister didn't get it."))
                .font(.system(size: 12)).foregroundStyle(Ink.amber)
        }
        Note(text: l.t("⌥Space не используется: его занимает ChatGPT. Изменение действует после перезапуска приложения.",
                       "⌥Space isn't used because ChatGPT takes it. Changes apply after restarting the app."))
    }

    private func group(_ title: String, _ items: [(String, String)]) -> some View {
        GlassSection(spacing: 0) {
            Text(title).font(.system(size: 15, weight: .semibold)).padding(.bottom, 8)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider() }
                HStack {
                    Text(item.0)
                    Spacer()
                    Text(item.1)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 10)
                        .frame(minWidth: 44, minHeight: 26)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Ink.chip))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.buttonBorder))
                        .accessibilityLabel(item.0 + ", " + item.1)
                }
                .frame(minHeight: 40)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Диагностика

/// Диагностика по макету Doctor.dc.html: заголовок с числом ошибок, проверки группами в две колонки, "Исправить".
struct DoctorPane: View {
    @EnvironmentObject var backend: Backend
    @State private var data: DoctorData?
    @State private var loading = false
    @State private var checkedAt: Date?

    var l: L { L(backend.state.lang) }

    private enum Group: Int, CaseIterable { case claude, codex, network, mac }

    private func group(of check: String) -> Group {
        switch check {
        case "codex": return .codex
        case "proxy", "hostrun": return .network
        case "notify", "lid", "modes": return .mac
        default: return .claude
        }
    }

    private func title(_ g: Group) -> String {
        switch g {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .network: return l.t("Сеть и песочница", "Network and sandbox")
        case .mac: return "Mac"
        }
    }

    /// Чем исправить проверку: та же команда, что советует agentmeister doctor.
    private func fix(_ check: String) -> [String]? {
        switch check {
        case "codex": return ["--harness", "codex", "setup"]
        case "proxy": return ["proxy", "setup"]
        case "lid": return ["lid", "setup"]
        case "modes", "install": return nil
        default: return ["setup"]
        }
    }

    /// Строки agentmeister doctor и строка исполнителя host-run из состояния приложения.
    private var allRows: [DoctorData.Row] {
        guard var rows = data?.rows else { return [] }
        if let h = backend.state.hostRun {
            rows.append(DoctorData.Row(check: "hostrun", level: h.running ? "ok" : "warn",
                                       text: h.running ? l.t("исполнитель host-run работает, команд в списке \(h.commands)", "host-run runner running, \(h.commands) commands allowed")
                                                       : l.t("исполнитель host-run не запущен", "host-run runner isn't running")))
        }
        return rows
    }

    var body: some View {
        let rows = allRows
        let bad = rows.filter { $0.level == "bad" }.count
        let warn = rows.filter { $0.level == "warn" }.count
        HStack(spacing: 12) {
            Text(l.t("Диагностика", "Diagnostics")).font(.system(size: 20, weight: .semibold))
            if data != nil {
                if bad > 0 {
                    chip(l.count(bad, "ошибка", "ошибки", "ошибок", "error", "errors"), Ink.red, Ink.redChip, "exclamationmark.triangle")
                } else if warn > 0 {
                    chip(l.count(warn, "замечание", "замечания", "замечаний", "warning", "warnings"), Ink.amber, Ink.amberDot.opacity(0.14), "exclamationmark.circle")
                } else {
                    chip(l.t("все в порядке", "all good"), Ink.teal, Ink.tealChip, "checkmark")
                }
            }
            Spacer()
            if let checkedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(context.date.timeIntervalSince(checkedAt) < 60 ? l.t("проверено только что", "checked just now")
                                                                        : l.t("проверено ", "checked ") + l.agoLong(checkedAt.timeIntervalSince1970))
                        .font(.system(size: 12)).foregroundStyle(Ink.muted)
                }
            }
            Button(l.t("Проверить снова", "Check again")) { Task { await load() } }
                .disabled(loading)
        }
        if data == nil {
            ProgressView()
        }
        let groups = Group.allCases.filter { g in rows.contains { group(of: $0.check) == g } }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)], spacing: 16) {
            ForEach(groups, id: \.self) { g in
                GlassSection(spacing: 0) {
                    Text(title(g)).font(.system(size: 15, weight: .semibold)).padding(.bottom, 8)
                    let items = rows.filter { group(of: $0.check) == g }
                    ForEach(Array(items.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider() }
                        HStack(alignment: .top, spacing: 10) {
                            mark(row.level)
                            Text(row.text)
                                .font(.system(size: 12))
                                .foregroundStyle(row.level == "bad" ? Ink.red : Ink.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if row.level != "ok", let args = fix(row.check) {
                                UtilityButton(title: l.t("Исправить", "Fix"), args: args)
                                    .buttonStyle(.glassProminent)
                                    .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func chip(_ text: String, _ fg: Color, _ bg: Color, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(fg)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(bg))
    }

    @ViewBuilder
    private func mark(_ level: String) -> some View {
        switch level {
        case "ok": Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.tealDot)
        case "warn": Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Ink.amberDot)
        case "off": Image(systemName: "minus.circle.fill").foregroundStyle(Ink.faint)
        default: Image(systemName: "xmark.circle.fill").foregroundStyle(Color(hex: 0xE5534B))
        }
    }

    private func load() async {
        loading = true
        data = await backend.doctor()
        checkedAt = Date()
        loading = false
    }
}
