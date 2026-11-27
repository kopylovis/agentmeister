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
    @EnvironmentObject var workspace: Workspace
    let data: SettingsData?
    let reload: () async -> Void
    @State private var test = "git push --force origin main"
    @State private var result: GuardTest?
    @State private var orKey = ""
    @State private var keyNote: (String, Bool)?

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
                                    .buttonStyle(PillStyle(small: true))
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
                                    .buttonStyle(.textLink)
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
                    translateCard(on: modes["translate"], info: info)
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
                            UtilityButton(title: l.t("Настроить", "Set up"), args: ["lid", "setup"], prominent: true)
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

    /// translate: переключатель, ключ OpenRouter и последние записи журнала (в журнале нет текста промптов).
    private func translateCard(on: Bool?, info: SettingsData.ModesInfo?) -> some View {
        GlassSection(spacing: 10) {
            HStack {
                Text("translate").font(.system(size: 17, weight: .semibold))
                Spacer()
                HeaderSwitch(label: "translate", on: on ?? false) { run(["translate", $0 ? "on" : "off"]) }
            }
            Note(text: l.t("Сообщения на русском и других нелатинских языках переводятся через OpenRouter, агент получает английский текст рядом с оригиналом и отвечает на твоем языке. Слэш-команды, длинные вставки и все, что похоже на ключи, токены и ссылки proxy, не отправляются.",
                           "Messages in Russian and other non-Latin languages are translated through OpenRouter, and the agent gets the English text next to the original and replies in your language. Slash commands, long pastes and anything that looks like keys, tokens or proxy links are not sent."))
            let source = info?.translateKey
            Text(source == "file" ? l.t("Ключ OpenRouter сохранен", "OpenRouter key saved")
                 : source == "env" ? l.t("Ключ из OPENROUTER_API_KEY", "Key from OPENROUTER_API_KEY")
                 : l.t("Ключа OpenRouter нет, без него перевод не работает", "No OpenRouter key, nothing is translated without it"))
                .font(.system(size: 12))
                .foregroundStyle(source == nil ? Ink.amber : Ink.teal)
            HStack(spacing: 8) {
                SecureField("sk-or-v1-…", text: $orKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(saveKey)
                    .accessibilityLabel(l.t("Ключ OpenRouter", "OpenRouter key"))
                Button(l.t("Сохранить", "Save"), action: saveKey)
                    .buttonStyle(PillStyle(small: true))
                    .disabled(orKey.trimmingCharacters(in: .whitespaces).isEmpty)
                if source == "file" {
                    Button(l.t("Удалить", "Remove")) { run(["translate", "key", "rm"]) }
                        .buttonStyle(PillStyle(small: true))
                }
            }
            if let keyNote {
                Text(keyNote.0).font(.system(size: 12)).foregroundStyle(keyNote.1 ? Ink.teal : Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let model = info?.translateModel {
                Text(l.t("Модель ", "Model ") + model).font(.system(size: 12)).foregroundStyle(Ink.muted)
            }
            let lines = info?.translateLog ?? []
            if !lines.isEmpty {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Ink.text2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Ink.card))
            }
            if let path = info?.translateLogPath, !lines.isEmpty {
                Button(tilde(path)) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .buttonStyle(.textLink)
                    .font(.system(size: 12))
            }
        }
    }

    private func saveKey() {
        let key = orKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task {
            let r = await Task.detached(priority: .userInitiated) { Backend.runWithInput(["translate", "key"], input: key) }.value
            if r.ok { orKey = "" }
            keyNote = (r.ok ? l.t("Ключ сохранен", "Key saved") : r.text, r.ok)
            await reload()
        }
    }

    private func check() {
        let command = test
        // проверяем как будто из проекта, иначе относительный rm -r выглядит как удаление в корне диска
        let cwd = workspace.current?.spec.projectPath ?? backend.state.projectsDir
        Task { result = await Backend.json(["app-state", "guard-test", "--cwd", cwd.isEmpty ? NSHomeDirectory() : cwd, command]) }
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
    @AppStorage(DockAttention.key) private var dock = true

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
                row(l.t("Значок в Dock", "Dock icon"),
                    l.t("Подпрыгивает, когда вкладка ждет ответа, а окно не в фокусе. Число на значке показывает, сколько вкладок ждут.",
                        "Bounces when a tab is waiting for you and the window isn't focused. The badge shows how many tabs are waiting.")) {
                    Toggle("", isOn: $dock).toggleStyle(.switch).labelsHidden()
                        .onChange(of: dock) { if !dock { NSApp.dockTile.badgeLabel = nil } }
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
                        UtilityButton(title: l.t("Подключить бота", "Connect a bot"), args: ["notify", "telegram"], prominent: true)
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
    static let classicKey = "terminal.classicRenderer"

    static let fonts = ["SF Mono", "Menlo", "Monaco", "JetBrains Mono"]

    static var fontName: String { UserDefaults.standard.string(forKey: fontKey) ?? "SF Mono" }
    static var size: Double { UserDefaults.standard.object(forKey: sizeKey) as? Double ?? 13 }
    static var cursor: String { UserDefaults.standard.string(forKey: cursorKey) ?? "blinkBar" }
    static var scrollback: Int { UserDefaults.standard.object(forKey: scrollbackKey) as? Int ?? 10_000 }
    static var optionMeta: Bool { UserDefaults.standard.object(forKey: metaKey) as? Bool ?? true }
    static var linksAlways: Bool { UserDefaults.standard.string(forKey: linksKey) == "always" }
    static var bell: String { UserDefaults.standard.string(forKey: bellKey) ?? "tab" }
    static var alwaysDark: Bool { UserDefaults.standard.string(forKey: colorsKey) == "dark" }
    /// Claude Code в классическом режиме (CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1): переписка уходит в прокрутку
    /// терминала, и ⌘F ее находит. В полноэкранном режиме в терминале только видимый экран.
    static var classicRenderer: Bool { UserDefaults.standard.object(forKey: classicKey) as? Bool ?? true }

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
    @AppStorage(TerminalPrefs.classicKey) private var classic = true

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
                row(l.t("История Claude Code в терминале", "Claude Code history in the terminal")) {
                    Toggle("", isOn: $classic).toggleStyle(.switch).labelsHidden()
                }
                .help(l.t("Классический режим Claude Code: вся переписка в прокрутке терминала, ⌘F находит ее целиком. Выключено, и Claude Code рисует полноэкранный интерфейс, где ⌘F видит только экран. Действует для новых и перезапущенных вкладок.",
                          "Claude Code's classic renderer: the whole conversation is in the terminal scrollback and ⌘F finds all of it. Off, Claude Code draws its fullscreen interface and ⌘F sees only the screen. Applies to new and restarted tabs."))
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
            // карточки одной высоты: каждая тянется до самой высокой
            HStack(alignment: .top, spacing: 16) {
                AgentCard(agent: .claude, info: data.claude, l: l, reload: reload)
                AgentCard(agent: .codex, info: data.codex, l: l, reload: reload)
            }
            .fixedSize(horizontal: false, vertical: true)
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
    @EnvironmentObject var backend: Backend
    let agent: LaunchSpec.Agent
    let info: SettingsData.Agent?
    let l: L
    let reload: () async -> Void
    @State private var flags = ""
    /// Итог последнего обновления из этой карточки, последняя строка agent-update.
    @State private var update: String?
    /// Последнее обновление из карточки упало: строка янтарная, кнопка остается.
    @State private var updateFailed = false
    @State private var updating = false
    @State private var check: UpdateCheck?
    @State private var checking = false
    @State private var signingIn: LaunchSpec.Agent?

    private var name: String { agent == .claude ? "Claude Code" : "Codex" }
    private var proxyReady: Bool { backend.state.proxy?.configured == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let info, info.installed {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    gridRow(l.t("Путь", "Path"), tilde(info.path ?? ""), mono: true)
                    gridRow(l.t("Установлен", "Installed with"), info.installedVia == "homebrew" ? "Homebrew"
                            : info.installedVia == "installer" ? l.t("установщик Anthropic", "Anthropic installer")
                            : info.installedVia == "npm" ? "npm" : l.t("свой путь", "custom path"))
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
                Spacer(minLength: 0)
                // две тихие кнопки одной ширины; не влезают в ряд, встают столбиком (у обеих карточек одинаково)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons(info) }
                    VStack(spacing: 8) { buttons(info) }
                }
            } else {
                Spacer(minLength: 0)
                UtilityButton(title: l.t("Установить", "Install"), args: ["--harness", agent.rawValue, "install"], expand: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .onAppear {
            flags = UserDefaults.standard.string(forKey: AgentPrefs.flagsKey(agent)) ?? ""
            if info?.installed == true { runCheck() }
        }
        .onChange(of: info?.installed) { if info?.installed == true && check == nil { runCheck() } }
        .sheet(item: $signingIn, onDismiss: { Task { await reload() } }) { agent in
            AuthDialog(agent: agent)
        }
    }

    /// Шапка одной высоты у обеих карточек: иконка агента, имя и версия в строку, под ними состояние версии.
    /// Кнопка обновления справа появляется, только когда вышла новая версия.
    private var header: some View {
        HStack(spacing: 12) {
            AgentBadge(agent: agent, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name).font(.system(size: 15, weight: .semibold))
                    if let version = info?.version {
                        Text(version).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.muted)
                    }
                }
                .lineLimit(1)
                versionStatus
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if info?.installed == true, check?.update == true, update == nil || updateFailed {
                PillButton(title: l.t("Обновить", "Update"), prominent: true, small: true, busy: updating) { performUpdate() }
                    .disabled(updating)
                    .help(info?.installedVia == "homebrew"
                          ? l.t("brew upgrade через proxy, агент стоит из Homebrew", "brew upgrade through the proxy, the agent is from Homebrew")
                          : l.t("\(agent == .codex ? "codex" : "claude") update через proxy", "\(agent == .codex ? "codex" : "claude") update through the proxy"))
            }
        }
        .frame(height: 40)
    }

    @ViewBuilder
    private var versionStatus: some View {
        if info?.installed != true {
            Text(l.t("Не найден", "Not found")).foregroundStyle(Ink.amber)
        } else if updating {
            Text(l.t("Обновляется…", "Updating…")).foregroundStyle(Ink.muted)
        } else if let update {
            Text(update).foregroundStyle(updateFailed ? Ink.amber : Ink.teal).help(update)
        } else if checking && check == nil {
            Text(l.t("Проверяю обновления…", "Checking for updates…")).foregroundStyle(Ink.muted)
        } else if let check, check.update, let latest = check.latest {
            Text(l.t("Вышла \(latest)", "\(latest) available")).foregroundStyle(Ink.amber)
        } else if let check, check.error == nil {
            Text(l.t("Последняя версия", "Up to date")).foregroundStyle(Ink.teal)
        } else if let check, let error = check.error {
            Button { runCheck(force: true) } label: {
                Text(l.t("Не удалось проверить, повторить", "Couldn't check, try again")).foregroundStyle(Ink.muted)
            }
            .buttonStyle(.textLink(Ink.muted))
            .help(error)
        }
    }

    @ViewBuilder
    private func buttons(_ info: SettingsData.Agent) -> some View {
        Button {
            signingIn = agent
        } label: {
            Label(info.signedIn == true ? l.t("Сменить аккаунт", "Switch account") : l.t("Войти", "Sign in"),
                  systemImage: "person.crop.circle")
                .lineLimit(1)
        }
        .buttonStyle(CardActionStyle())
        UtilityButton(title: l.t("Хуки и MCP", "Hooks and MCP"),
                      args: agent == .claude ? ["setup"] : ["--harness", "codex", "setup"], expand: true,
                      icon: "puzzlepiece.extension")
    }

    private func gridRow(_ title: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(title).foregroundStyle(Ink.faint).frame(width: 110, alignment: .leading)
            Text(value).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12)).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    /// Есть ли новая версия: agentmeister agent-update --check спрашивает API Homebrew или npm, через proxy, если он
    /// настроен. Ответ живет 10 минут на все открытия настроек.
    private func runCheck(force: Bool = false) {
        if !force, let cached = UpdateCheck.cache[agent.rawValue], Date().timeIntervalSince(cached.at) < 600 {
            check = cached.result
            return
        }
        guard !checking else { return }
        checking = true
        let command = TerminalTab.checkCommand(direct: !proxyReady, agent: agent)
        let key = agent.rawValue
        Task.detached {
            let out = TerminalTab.shell(command).1
            let line = out.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? ""
            let result = (try? JSONDecoder().decode(UpdateCheck.self, from: Data(line.utf8)))
                ?? UpdateCheck(current: nil, latest: nil, update: false, error: out.isEmpty ? "no answer" : String(out.suffix(300)))
            await MainActor.run {
                checking = false
                check = result
                if result.error == nil { UpdateCheck.cache[key] = (Date(), result) }
            }
        }
    }

    /// Обновление тем способом, каким агент установлен (agentmeister agent-update), через proxy, если он настроен.
    /// Последняя строка вывода говорит, с какой версии на какую; потом версия проверяется заново.
    private func performUpdate() {
        updating = true
        // весь вывод, чтобы код выхода был кодом обновления, а не tail
        let command = TerminalTab.updateCommand(direct: !proxyReady, agent: agent, tail: false)
        Task.detached {
            let (code, raw) = TerminalTab.shell(command)
            let out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                updating = false
                updateFailed = code != 0
                update = out.split(separator: "\n").last.map(String.init) ?? l.t("Команда ничего не вывела", "The command printed nothing")
                UpdateCheck.cache[agent.rawValue] = nil
                runCheck(force: true)
                Task { await reload() }
            }
        }
    }
}

/// Ответ agentmeister agent-update --check.
struct UpdateCheck: Decodable {
    let current: String?
    let latest: String?
    let update: Bool
    let error: String?

    @MainActor static var cache: [String: (at: Date, result: UpdateCheck)] = [:]
}

/// Тихая кнопка карточки: значок и подпись на легкой подложке с тонкой рамкой, подсветка под курсором.
struct CardActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { CardActionBody(configuration: configuration) }

    private struct CardActionBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.text)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? Ink.hover : Ink.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.hairline))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(configuration.isPressed ? 0.7 : enabled ? 1 : 0.5)
                .onHover { hover = $0 }
        }
    }
}

// MARK: - Горячие клавиши

/// Горячие клавиши по макету SettingsShortcuts.dc.html: две стеклянные группы строк с клавишами-кнопками.
/// Нажатие на клавишу записывает новое сочетание, Esc отменяет, Delete убирает. Системные сочетания и ⌘1…9
/// показаны тусклыми, их не меняют.
struct ShortcutsPane: View {
    @EnvironmentObject var backend: Backend
    @AppStorage(HotKey.enabledKey) private var showHotKey = true
    @AppStorage(HotKey.takenKey) private var hotKeyTaken = false
    @ObservedObject private var store = ShortcutStore.shared
    @StateObject private var recorder = ShortcutRecorder()

    var l: L { L(backend.state.lang) }

    private enum Row {
        case action(ShortcutAction)
        case fixed(String, String)
    }

    var body: some View {
        PaneTitle(l.t("Горячие клавиши", "Shortcuts"))
        HStack(alignment: .top, spacing: 16) {
            group(l.t("Сессии и вкладки", "Sessions and tabs"), [
                .action(.newSession), .action(.newTab), .action(.closeTab), .action(.nextTab), .action(.previousTab),
                .fixed(l.t("Вкладка 1–9", "Tab 1–9"), "⌘1…9"), .action(.waitingTab), .action(.restart), .action(.parallel),
            ])
            group(l.t("Окна и инструменты", "Windows and tools"), [
                .action(.palette), .action(.library), .action(.usage), .action(.ask), .action(.shot), .action(.inspector),
                .action(.sidebar), .action(.showApp),
                .fixed(l.t("Настройки", "Settings"), "⌘,"), .fixed(l.t("Закрыть Agentmeister", "Quit Agentmeister"), "⌘Q"),
            ])
        }
        Toggle(l.t("Показывать Agentmeister из любого приложения по ", "Show Agentmeister from any app with ") + showAppLabel, isOn: $showHotKey)
            .onChange(of: showHotKey) { HotKey.shared.apply() }
        HStack(alignment: .center, spacing: 10) {
            Note(text: l.t("Нажми на сочетание, чтобы поменять его: Esc отменяет, Delete убирает. Системные и ⌘1…9 не меняются. ⌥Space по умолчанию не берем: его занимает ChatGPT.",
                           "Click a shortcut to change it: Esc cancels, Delete clears it. System shortcuts and ⌘1…9 are fixed. ⌥Space isn't the default because ChatGPT takes it."))
            Spacer(minLength: 0)
            CapsuleButton(title: l.t("Сбросить", "Reset to defaults")) {
                recorder.stop()
                store.reset()
            }
            .disabled(store.allDefault)
            .opacity(store.allDefault ? 0.5 : 1)
        }
        .onDisappear { recorder.stop() }
    }

    private var showAppLabel: String {
        let key = store.label(.showApp)
        return key.isEmpty ? l.t("сочетанию (не задано)", "a shortcut (none set)") : key
    }

    private func group(_ title: String, _ rows: [Row]) -> some View {
        GlassSection(spacing: 0) {
            Text(title).font(.system(size: 15, weight: .semibold)).padding(.bottom, 8)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                switch row {
                case .action(let action): actionRow(action)
                case .fixed(let name, let key): fixedRow(name, key)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func actionRow(_ action: ShortcutAction) -> some View {
        let recording = recorder.recording == action
        let key = store.label(action)
        let text = recording ? l.t("Нажми сочетание", "Type shortcut") : key.isEmpty ? l.t("нет", "none") : key
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(action.title(l))
                Spacer()
                Button { recorder.toggle(action, l: l) } label: {
                    Keycap(text: text, recording: recording, muted: key.isEmpty && !recording)
                }
                .buttonStyle(.hover(6, .overlay))
                .help(recording ? l.t("Esc отменяет, Delete убирает сочетание", "Esc cancels, Delete clears the shortcut")
                                : l.t("Нажми, чтобы поменять", "Click to change"))
                .accessibilityLabel(action.title(l) + ", " + (key.isEmpty ? l.t("нет сочетания", "no shortcut") : key))
                .accessibilityHint(l.t("Записать новое сочетание", "Record a new shortcut"))
            }
            if let message = recorder.message, message.action == action {
                Text(message.text).font(.system(size: 12)).foregroundStyle(Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if action == .showApp, hotKeyTaken, !recording, showHotKey, !key.isEmpty {
                Text(l.t("\(key) уже занято другим приложением, Agentmeister его не получил.",
                         "Another app already holds \(key), Agentmeister didn't get it."))
                    .font(.system(size: 12)).foregroundStyle(Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 40)
    }

    private func fixedRow(_ name: String, _ key: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Keycap(text: key, recording: false, muted: true)
                .help(l.t("Системное сочетание, не меняется", "System shortcut, can't be changed"))
                .accessibilityLabel(name + ", " + key + ", " + l.t("не меняется", "fixed"))
        }
        .frame(minHeight: 40)
    }
}

/// Клавиша из макета: моноширинный текст на светлой плашке с тонкой рамкой и тенью снизу.
private struct Keycap: View {
    let text: String
    let recording: Bool
    let muted: Bool

    private static let fill = Color(light: .white(0.9), dark: .white(0.10))
    private static let border = Color(light: .black(0.12), dark: .white(0.16))

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(muted ? Ink.muted : Ink.text)
            .padding(.horizontal, 10)
            .frame(minWidth: 56, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Self.fill).shadow(color: .black.opacity(0.12), radius: 0, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(recording ? Color.accentColor : Self.border, lineWidth: recording ? 2 : 1))
            .opacity(muted && !recording ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Диагностика

/// Диагностика: сводка сверху (чип состояния, счет проверок, время, "Проверить снова"), под ней группы во всю ширину.
/// В группе сначала проблемы, каждая подсвечена и с "Исправить", потом плотные строки в порядке в две колонки.
/// Группа, где все в порядке, свернута в одну строку "Claude Code · 9 проверок в порядке" и раскрывается по клику.
struct DoctorPane: View {
    @EnvironmentObject var backend: Backend
    @State private var data: DoctorData?
    @State private var loading = false
    @State private var checkedAt: Date?
    @State private var expanded: Set<CheckGroup> = []

    var l: L { L(backend.state.lang) }

    fileprivate enum CheckGroup: Int, CaseIterable { case claude, codex, network, mac }

    private func group(of check: String) -> CheckGroup {
        switch check {
        case "codex": return .codex
        case "proxy", "hostrun": return .network
        case "notify", "lid", "modes": return .mac
        default: return .claude
        }
    }

    private func title(_ g: CheckGroup) -> String {
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

    /// Порядок важности: ошибки, замечания, выключенное, в порядке.
    private static func rank(_ level: String) -> Int {
        switch level {
        case "bad": return 0
        case "warn": return 1
        case "off": return 2
        default: return 3
        }
    }

    private static func isProblem(_ level: String) -> Bool { level == "bad" || level == "warn" }

    /// Текст doctor одной фразой делится на короткий заголовок и пояснение: по первому ": ", ". " или скобке.
    /// "крышка: выключено, ..." дает "Крышка" и "выключено, ...", "прокси настроен (проверить ...)" дает
    /// "Прокси настроен" и "проверить ...". Без разделителя пояснения нет.
    static func split(_ text: String) -> (title: String, detail: String?) {
        let marks = [": ", ". ", " ("].compactMap { mark in text.range(of: mark).map { (mark, $0) } }
        guard let (mark, range) = marks.min(by: { $0.1.lowerBound < $1.1.lowerBound }), range.lowerBound > text.startIndex else {
            return (capitalized(text), nil)
        }
        var detail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if mark == " (" {
            guard detail.hasSuffix(")") else { return (capitalized(text), nil) }
            detail.removeLast()
        }
        let head = String(text[..<range.lowerBound])
        return (capitalized(head), detail.isEmpty ? nil : detail)
    }

    /// Заголовок с заглавной буквы и без точки в конце.
    private static func capitalized(_ text: String) -> String {
        let s = text.hasSuffix(".") ? String(text.dropLast()) : text
        guard let first = s.first, first.isLowercase else { return s }
        return first.uppercased() + s.dropFirst()
    }

    private func checks(_ n: Int) -> String { l.count(n, "проверка", "проверки", "проверок", "check", "checks") }

    /// "1 ошибка, 2 замечания" или пусто, если проблем нет.
    private func problems(bad: Int, warn: Int) -> String {
        var parts: [String] = []
        if bad > 0 { parts.append(l.count(bad, "ошибка", "ошибки", "ошибок", "error", "errors")) }
        if warn > 0 { parts.append(l.count(warn, "замечание", "замечания", "замечаний", "warning", "warnings")) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let rows = allRows
        let bad = rows.filter { $0.level == "bad" }.count
        let warn = rows.filter { $0.level == "warn" }.count
        header(total: rows.count, bad: bad, warn: warn)
        if data == nil {
            ProgressView().controlSize(.small)
        }
        let groups = CheckGroup.allCases
            .map { g in (g, rows.filter { group(of: $0.check) == g }.sorted { Self.rank($0.level) < Self.rank($1.level) }) }
            .filter { !$0.1.isEmpty }
            .sorted { (Self.rank($0.1.first?.level ?? "ok"), $0.0.rawValue) < (Self.rank($1.1.first?.level ?? "ok"), $1.0.rawValue) }
        VStack(spacing: 10) {
            ForEach(groups, id: \.0) { g, items in
                groupCard(g, items)
            }
        }
        .task { await load() }
    }

    private func header(total: Int, bad: Int, warn: Int) -> some View {
        HStack(spacing: 12) {
            Text(l.t("Диагностика", "Diagnostics")).font(.system(size: 20, weight: .semibold))
            if data != nil {
                if bad > 0 {
                    chip(problems(bad: bad, warn: warn), Ink.red, Ink.redChip, "exclamationmark.triangle.fill")
                } else if warn > 0 {
                    chip(problems(bad: bad, warn: warn), Ink.amber, Ink.warnChip, "exclamationmark.circle.fill")
                } else {
                    chip(l.t("все в порядке", "all good"), Ink.teal, Ink.tealChip, "checkmark")
                }
                Text(checks(total)).font(.system(size: 12)).foregroundStyle(Ink.muted)
            }
            Spacer()
            if let checkedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(context.date.timeIntervalSince(checkedAt) < 60 ? l.t("проверено только что", "checked just now")
                                                                        : l.t("проверено ", "checked ") + l.agoLong(checkedAt.timeIntervalSince1970))
                        .font(.system(size: 12)).foregroundStyle(Ink.muted)
                }
            }
            Button {
                Task { await load() }
            } label: {
                HStack(spacing: 6) {
                    if loading && data != nil { ProgressView().controlSize(.mini) }
                    Text(l.t("Проверить снова", "Check again"))
                }
            }
            .buttonStyle(PillStyle(small: true))
            .disabled(loading)
        }
    }

    private func groupCard(_ g: CheckGroup, _ items: [DoctorData.Row]) -> some View {
        let issues = items.filter { Self.isProblem($0.level) }
        let rest = items.filter { !Self.isProblem($0.level) }
        let collapsible = issues.isEmpty
        let open = !collapsible || expanded.contains(g)
        let bad = issues.filter { $0.level == "bad" }.count
        let summary = collapsible ? l.t("\(checks(items.count)) в порядке", "\(checks(items.count)) OK")
                                  : problems(bad: bad, warn: issues.count - bad) + (rest.isEmpty ? "" : l.t(", в порядке \(rest.count)", ", \(rest.count) OK"))
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard collapsible else { return }
                if expanded.contains(g) { expanded.remove(g) } else { expanded.insert(g) }
            } label: {
                HStack(spacing: 8) {
                    if collapsible {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.tealDot)
                    }
                    Text(title(g)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text)
                    Text("·").foregroundStyle(Ink.faint)
                    Text(summary).font(.system(size: 12))
                        .foregroundStyle(bad > 0 ? Ink.red : issues.isEmpty ? Ink.muted : Ink.amber)
                    Spacer(minLength: 0)
                    if collapsible {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Ink.faint)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                // поля карточки внутри кнопки: подсветка под курсором закрывает всю карточку, а у раскрытой ее шапку
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverStyle(shape: AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: 18, bottomLeadingRadius: open ? 0 : 18, bottomTrailingRadius: open ? 0 : 18,
                topTrailingRadius: 18, style: .continuous))))
            .allowsHitTesting(collapsible)
            .accessibilityAddTraits(collapsible ? .isButton : [])
            .accessibilityValue(collapsible ? (open ? l.t("развернуто", "expanded") : l.t("свернуто", "collapsed")) : "")

            if open {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, row in
                        issueRow(row)
                    }
                    if !rest.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 18, alignment: .topLeading)],
                                  alignment: .leading, spacing: 7) {
                            ForEach(Array(rest.enumerated()), id: \.offset) { _, row in
                                okRow(row)
                            }
                        }
                        .padding(.horizontal, issues.isEmpty ? 0 : 2)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .animation(.snappy(duration: 0.28), value: open)
    }

    /// Плотная строка проверки в порядке: значок, заголовок и приглушенное пояснение той же строкой.
    private func okRow(_ row: DoctorData.Row) -> some View {
        let (title, detail) = Self.split(row.text)
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            mark(row.level).font(.system(size: 11))
            Group {
                if let detail {
                    Text("\(Text(title).foregroundStyle(Ink.text))  \(Text(detail).foregroundStyle(Ink.muted))")
                } else {
                    Text(title).foregroundStyle(Ink.text)
                }
            }
            .font(.system(size: 12))
            .lineLimit(2)
            .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .help(row.text)
        .accessibilityElement(children: .combine)
    }

    /// Ошибка или замечание: подсвеченная плашка, заголовок, пояснение целиком и "Исправить", если есть команда.
    private func issueRow(_ row: DoctorData.Row) -> some View {
        let (title, detail) = Self.split(row.text)
        let isBad = row.level == "bad"
        return HStack(alignment: .top, spacing: 10) {
            mark(row.level).font(.system(size: 13)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(isBad ? Ink.red : Ink.warn)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Ink.text2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            Spacer(minLength: 0)
            if let args = fix(row.check) {
                UtilityButton(title: l.t("Исправить", "Fix"), args: args, prominent: true, small: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(isBad ? Ink.redChip : Ink.warnChip))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isBad ? Ink.redBorder : Ink.amberDot.opacity(0.35)))
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
        let fresh = await backend.doctor()
        withAnimation(.snappy(duration: 0.28)) {
            data = fresh
            checkedAt = Date()
        }
        loading = false
    }
}
