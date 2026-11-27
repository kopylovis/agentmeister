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

/// Режимы по макету MasterDetail.dc.html: слева список режимов с точкой состояния и строкой из настоящих данных,
/// справа выбранный режим с описанием, переключателем и его настройками. Выбор помнится в modes.selected.
struct ModesPane: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    let data: SettingsData?
    let reload: () async -> Void
    @AppStorage("modes.selected") private var selected = "guard"
    @State private var test = "git push --force origin main"
    @State private var result: GuardTest?
    @State private var orKey = ""
    @State private var keyNote: (String, Bool)?

    static let order = ["guard", "humanize", "translate", "buildlog", "lid"]

    var l: L { L(backend.state.lang) }
    private var info: SettingsData.ModesInfo? { data?.modesInfo }

    private func run(_ args: [String]) {
        Task {
            _ = await backend.perform(args)
            await reload()
        }
    }

    private func isOn(_ name: String) -> Bool {
        name == "guard" ? data?.modes?["guard"] ?? data?.guard?.on ?? false : data?.modes?[name] ?? false
    }

    var body: some View {
        PaneTitle(l.modes)
        if data?.modes != nil {
            let current = Self.order.contains(selected) ? selected : "guard"
            HStack(alignment: .top, spacing: 16) {
                // в окне 1040 pt справа остается около 480 pt: этого хватает полю ключа с двумя кнопками
                modeList(current).frame(width: 264)
                detail(current).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ProgressView()
        }
    }

    // MARK: Список

    private func modeList(_ current: String) -> some View {
        VStack(spacing: 2) {
            ForEach(Self.order, id: \.self) { name in
                let on = isOn(name)
                let picked = name == current
                Button {
                    selected = name
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(on ? (picked ? Color.white : Ink.tealDot) : Color.clear)
                            .overlay(Circle().strokeBorder(on ? Color.clear : (picked ? Color.white.opacity(0.85) : Ink.dotOff), lineWidth: 1.5))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(picked ? Color.white : Ink.text)
                            Text(status(name))
                                .font(.system(size: 11.5))
                                .foregroundStyle(picked ? Color.white.opacity(0.85) : Ink.muted)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(picked ? Color.accentColor : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hover(10))
                .help(status(name))
                .accessibilityLabel(name + ", " + (on ? l.t("включен", "on") : l.t("выключен", "off")) + ", " + status(name))
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l.modes)
    }

    /// Строка под именем режима. Только то, что есть в данных настроек: правила, журналы, пороги, готовность.
    private func status(_ name: String) -> String {
        switch name {
        case "guard":
            guard let g = data?.guard else { return "" }
            let on = g.rules.filter(\.on).count
            let rules = l.t("\(on) из \(g.rules.count) правил", "\(on) of \(g.rules.count) rules")
            guard let hit = g.lastHit else { return rules }
            let when = Date().timeIntervalSince1970 - hit < 60 ? l.t("только что", "just now") : l.agoLong(hit)
            return rules + l.t(", сработал ", ", last hit ") + when
        case "humanize":
            return l.t("текст агента, но не код", "replies, commits, PRs and docs")
        case "translate":
            let key = ShortcutStore.shared.label(.translateInput)
            if info?.translateKey == nil { return l.t("\(key), нет ключа", "\(key), no key") }
            return key + " · " + providerName(info?.translateProvider)
                + (info?.translateMedianMs.map { l.t(", медиана ", ", median ") + duration($0) } ?? "")
        case "buildlog":
            return l.t("больше \(info?.buildlogLines ?? 200) строк или \(info?.buildlogKB ?? 20) КБ", "over \(info?.buildlogLines ?? 200) lines or \(info?.buildlogKB ?? 20) KB")
        case "lid":
            if !(info?.lidReady ?? false) { return l.t("нужна настройка", "needs setup") }
            return isOn("lid") ? l.t("готов", "ready") : l.t("выключен, готов к включению", "off, ready to turn on")
        default:
            return ""
        }
    }

    private func providerName(_ id: String?) -> String { id == "google" ? "Google AI Studio" : "OpenRouter" }

    private func duration(_ ms: Int) -> String {
        guard ms >= 1000 else { return l.t("\(ms) мс", "\(ms) ms") }
        let s = String(format: "%.1f", Double(ms) / 1000)
        return l.t(s.replacingOccurrences(of: ".", with: ",") + " с", s + " s")
    }

    // MARK: Панель режима

    private func detail(_ name: String) -> some View {
        GlassSection(spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(.system(size: 20, weight: .semibold))
                    Text(description(name))
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // без правила sudoers lid on спросил бы пароль, а здесь нет терминала: сначала "Настроить"
                let locked = name == "lid" && !(info?.lidReady ?? false)
                // у translate главное ⌘⇧T, он работает без переключателя: переключатель стал флажком автоперевода в панели
                if name != "translate" {
                    HeaderSwitch(label: name, on: isOn(name)) { run([name, $0 ? "on" : "off"]) }
                        .disabled(locked)
                        .help(locked ? l.t("Сначала настрой lid", "Set lid up first") : "")
                }
            }
            switch name {
            case "guard": guardPanel
            case "humanize": humanizePanel
            case "translate": translatePanel
            case "buildlog": buildlogPanel
            default: lidPanel
            }
        }
    }

    private func description(_ name: String) -> String {
        switch name {
        case "guard":
            return l.t("Перед рискованным вызовом Codex просит подтверждение в чате. Claude Code использует свои разрешения, а в режиме auto тоже спрашивает в чате.",
                       "Codex asks for confirmation in chat before a risky call. Claude Code uses its permission prompt and asks in chat in auto mode.")
        case "humanize":
            return l.t("Правила письма без примет нейросети для Claude Code и Codex. Касаются ответов, коммитов, PR и документации, но не самого кода.",
                       "Writing rules without AI tells for Claude Code and Codex. They cover replies, commits, PRs and docs, not the code itself.")
        case "translate":
            let key = ShortcutStore.shared.label(.translateInput)
            return l.t("\(key) во вкладке Claude Code или Codex переводит строку ввода на английский прямо на месте, через OpenRouter или Google AI Studio. Перевод видно до отправки, агент получает только английский и отвечает на твоем языке. Картинки остаются, Esc отменяет. Слэш-команды и все, что похоже на ключи, токены и ссылки proxy, не отправляются.",
                       "\(key) in a Claude Code or Codex tab translates the input line to English in place, through OpenRouter or Google AI Studio. You see the translation before sending, the agent gets English only and replies in your language. Images stay, Esc cancels. Slash commands and anything that looks like keys, tokens or proxy links are not sent.")
        case "buildlog":
            return l.t("Claude Code и Codex получают ошибки и итог сборки вместе с путем к полному логу. В Codex команда сборки возвращает свой код завершения.",
                       "Claude Code and Codex receive build errors and a summary with the path to the full log. In Codex the build keeps its exit code.")
        default:
            let grace = info?.lidGraceMin ?? 2, battery = info?.lidBattery ?? 15
            return l.t("Работает вместе с кнопкой \"Не спать\" на вкладке сессии. Кнопка не дает Mac уснуть, пока крышка открыта, а lid держит его и с закрытой крышкой. Отпускает через \(grace) мин после последней такой сессии или при \(battery)% батареи.",
                       "Works together with the Stay awake button on a session tab. The button keeps the Mac from sleeping while the lid is open, and lid keeps it awake with the lid closed too. Lets go \(grace) min after the last such session or at \(battery)% battery.")
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Ink.muted).gridColumnAlignment(.leading)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Ink.muted)
    }

    /// Подпись журнала и ссылка на файл справа, как "Last messages ... Open log" в макете.
    private func logHeader(_ title: String, path: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            sectionTitle(title)
            Spacer(minLength: 8)
            if let path {
                Button(l.t("Открыть журнал", "Open log")) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .buttonStyle(.textLink)
                    .font(.system(size: 12))
                    .help(tilde(path))
            }
        }
    }

    private func rawLog(_ lines: [String]) -> some View {
        Text(lines.joined(separator: "\n"))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Ink.text2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Ink.card))
    }

    /// Таблица журнала: заголовки колонок, строки через тонкую линию. Последняя колонка забирает остаток ширины.
    private func logTable(_ heads: [String], _ rows: [[(String, Color)]]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(heads.enumerated()), id: \.offset) { _, head in
                    Text(head).foregroundStyle(Ink.faint)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().overlay(Ink.hairline)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { i, cell in
                        // последняя колонка обычным шрифтом и в две строки: итог перевода и вызов guard бывают длинными
                        let last = i == row.count - 1
                        Text(cell.0)
                            .font(last ? .system(size: 12) : nil)
                            .foregroundStyle(cell.1)
                            .lineLimit(last ? 2 : 1)
                            .truncationMode(last ? .tail : .middle)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(cell.0)
                            .frame(maxWidth: last ? .infinity : nil, alignment: .leading)
                    }
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled)
    }

    // MARK: guard

    @ViewBuilder private var guardPanel: some View {
        if let g = data?.guard {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(l.t("Правила", "Rules"))
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
                            .disabled(!isOn("guard"))
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(l.t("Проверить команду", "Test a command"))
                HStack {
                    TextField("", text: $test)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit(check)
                        .accessibilityLabel(l.t("Команда для проверки", "Command to test"))
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
            VStack(alignment: .leading, spacing: 8) {
                logHeader(l.t("Последние срабатывания", "Recent hits"), path: g.logPath)
                let lines = g.log ?? []
                let rows = lines.compactMap(GuardLine.init)
                if lines.isEmpty {
                    Text(l.t("пока не было", "none yet")).font(.system(size: 12)).foregroundStyle(Ink.faint)
                } else if rows.count == lines.count {
                    logTable([l.t("время", "time"), l.t("что", "action"), l.t("правило", "rule"), l.t("вызов", "call")],
                             rows.reversed().map { r in
                                 [(r.time, Ink.text2), (r.action, r.action == "allow" ? Ink.teal : r.action == "error" ? Ink.red : Ink.amber),
                                  (r.rule, Ink.text), (r.what, Ink.muted)]
                             })
                } else {
                    rawLog(lines)
                }
            }
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

    // MARK: humanize

    @ViewBuilder private var humanizePanel: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                fieldLabel(l.t("Агенты", "Agents"))
                Text("Claude Code, Codex")
                    // одна растягиваемая ячейка отдает колонке значений всю ширину, иначе Grid делит ее поровну
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                fieldLabel(l.t("Касается", "Covers"))
                Text(l.t("ответов, коммитов, PR и документации", "replies, commits, PRs and docs"))
            }
            GridRow {
                fieldLabel(l.t("Не касается", "Leaves alone"))
                Text(l.t("самого кода", "the code itself"))
            }
            GridRow {
                fieldLabel(l.t("В сессии", "In a session"))
                Text(l.t("/humanize переключает, есть on, off и status", "/humanize toggles it, also on, off and status"))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 13))
        if let on = info?.humanizeTypography {
            SettingsRow(l.t("Строгая типографика", "Strict typography"),
                        l.t("Только прямые кавычки, без буквы е с точками, без двоеточий посреди фразы. Строже обычной русской типографики, поэтому отдельно.",
                            "Straight quotes only, no letter ё, no colons mid-sentence. Stricter than usual typography, so it's separate.")) {
                HeaderSwitch(label: l.t("Строгая типографика", "Strict typography"), on: on) { run(["humanize", "typography", $0 ? "on" : "off"]) }
            }
        }
    }

    // MARK: translate

    /// Ключ здесь только вводится: панель показывает, сохранен ли он, но не сам ключ и не его часть.
    @ViewBuilder private var translatePanel: some View {
        let provider = info?.translateProvider ?? "openrouter"
        let google = provider == "google"
        let name = providerName(provider)
        let source = info?.translateKey
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                fieldLabel(l.t("Провайдер", "Provider"))
                SegmentedCapsule(selection: Binding(get: { provider }, set: { run(["translate", "provider", $0]) }),
                                 options: [("openrouter", "OpenRouter", nil), ("google", "Google AI Studio", nil)])
                    .frame(maxWidth: 340)
            }
            GridRow {
                fieldLabel(l.t("Ключ", "Key"))
                VStack(alignment: .leading, spacing: 8) {
                    Text(source == "file" ? l.t("сохранен", "saved")
                         : source == "env" ? l.t("из переменной окружения", "from the environment")
                         : l.t("нет, без него перевод не работает", "none, nothing is translated without it"))
                        .foregroundStyle(source == nil ? Ink.amber : Ink.teal)
                    HStack(spacing: 8) {
                        SecureField(google ? "AQ.… / AIza…" : "sk-or-v1-…", text: $orKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit(saveKey)
                            .accessibilityLabel(l.t("Ключ \(name)", "\(name) key"))
                        Button(l.t("Сохранить", "Save"), action: saveKey)
                            .buttonStyle(PillStyle(small: true))
                            .disabled(orKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        if source == "file" {
                            Button(l.t("Удалить", "Remove")) { run(["translate", "key", "rm", provider]) }
                                .buttonStyle(PillStyle(small: true))
                        }
                    }
                    if let keyNote {
                        Text(keyNote.0).font(.system(size: 12)).foregroundStyle(keyNote.1 ? Ink.teal : Ink.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            GridRow {
                fieldLabel(l.t("Клавиша", "Shortcut"))
                Text(l.t("\(ShortcutStore.shared.label(.translateInput)), меняется в разделе \"Горячие клавиши\"",
                         "\(ShortcutStore.shared.label(.translateInput)), change it under Shortcuts"))
                    .foregroundStyle(Ink.text)
            }
            if let model = info?.translateModel {
                GridRow {
                    fieldLabel(l.t("Модель", "Model"))
                    Text(model).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
            GridRow {
                fieldLabel(l.t("Запасной", "Fallback"))
                let other = providerName(google ? "openrouter" : "google")
                Text(info?.translateFallback.map { l.t("\(providerName($0)), когда \(name) ошибается или опаздывает",
                                                       "\(providerName($0)), when \(name) fails or is late") }
                     ?? l.t("нет, появится с ключом \(other)", "none, a saved \(other) key adds one"))
                    .foregroundStyle(info?.translateFallback == nil ? Ink.muted : Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                    // без растяжения Grid меряет текст в две строки и оставляет над ним пустое место
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 13))
        VStack(alignment: .leading, spacing: 4) {
            Toggle(l.t("Добавлять перевод к сообщениям без \(ShortcutStore.shared.label(.translateInput))",
                       "Add a translation to messages sent without \(ShortcutStore.shared.label(.translateInput))"),
                   isOn: Binding(get: { isOn("translate") }, set: { run(["translate", $0 ? "on" : "off"]) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
            Text(l.t("Для iTerm2 и сообщений, отправленных без перевода. Хук не может заменить сообщение, поэтому агент видит и оригинал, и перевод, и токенов уходит немного больше.",
                     "For iTerm2 and messages sent untranslated. A hook can't replace the message, so the agent sees both the original and the translation, which costs a few more tokens."))
                .font(.system(size: 12))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
        if google {
            Text(l.t("Бесплатно в пределах лимитов, но Google может брать запросы для улучшения моделей. Там, где Gemini API недоступен (например, в России), отвечает только через proxy. Временами думает 7-15 секунд, тогда при сохраненном ключе OpenRouter переводит он.",
                     "Free within limits, but Google may use requests to improve its models. Where the Gemini API isn't available (Russia, for example), it answers only through the proxy. It sometimes takes 7-15 seconds, and then OpenRouter translates if its key is saved."))
                .font(.system(size: 12))
                .foregroundStyle(Ink.warn)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Ink.warnChip))
        }
        let lines = info?.translateLog ?? []
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                logHeader(l.t("Последние сообщения, текст не хранится", "Last messages, no text is stored"), path: info?.translateLogPath)
                let rows = lines.compactMap(TranslateLine.init)
                if rows.count == lines.count {
                    logTable([l.t("время", "time"), l.t("знаков", "chars"), l.t("мс", "ms"), l.t("итог", "result")],
                             rows.reversed().map { r in
                                 [(r.shortTime, Ink.text2), (String(r.chars), Ink.text2), (r.ms.map(String.init) ?? "-", Ink.text2),
                                  (r.result(l), r.ok ? Ink.teal : r.failed ? Ink.red : r.skipped ? Ink.amber : Ink.text)]
                             })
                } else {
                    rawLog(lines)
                }
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

    // MARK: buildlog

    @ViewBuilder private var buildlogPanel: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                fieldLabel(l.t("Команды", "Commands"))
                Text("Gradle, xcodebuild, swift build/test, npm, pnpm, yarn, pytest, make")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let info {
                GridRow {
                    fieldLabel(l.t("Выжимка", "Digest"))
                    HStack(spacing: 8) {
                        Text(l.t("вывод длиннее", "output over")).fixedSize()
                        NumberField(value: info.buildlogLines) { run(["buildlog", "lines", String($0)]) }
                        Text(l.t("строк", "lines")).fixedSize()
                    }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    HStack(spacing: 8) {
                        Text(l.t("или больше", "or over")).fixedSize()
                        NumberField(value: info.buildlogKB ?? 20) { run(["buildlog", "kb", String($0)]) }
                        Text(l.t("КБ", "KB")).fixedSize()
                    }
                }
                GridRow {
                    fieldLabel(l.t("Полные логи", "Full logs"))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(l.t("хранятся", "kept for")).fixedSize()
                            NumberField(value: info.buildlogDays) { run(["buildlog", "days", String($0)]) }
                            Text(l.t("дней", "days")).fixedSize()
                        }
                        Button(tilde(info.buildlogDir) + "/") { NSWorkspace.shared.open(URL(fileURLWithPath: info.buildlogDir)) }
                            .buttonStyle(.textLink)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
        }
        .font(.system(size: 13))
        Note(text: l.t("Упавшая сборка тоже приходит выжимкой, и Claude Code пишет, что команда упала. Код возврата при этом теряется.",
                       "A failed build also comes as a digest, and Claude Code is told the command failed. The exit code itself is lost."))
    }

    // MARK: lid

    @ViewBuilder private var lidPanel: some View {
        let ready = info?.lidReady ?? false
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                fieldLabel(l.t("Состояние", "Status"))
                Text(ready ? l.t("готов, pmset работает без пароля", "ready, pmset runs without a password")
                           : l.t("не настроен, pmset нужен пароль администратора", "not set up, pmset needs an administrator password"))
                    .foregroundStyle(ready ? Ink.teal : Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                fieldLabel(l.t("Держит", "Holds"))
                Text(l.t("вкладки с \"Не спать\" и сессии agentmeister -k", "tabs with Stay awake and agentmeister -k sessions"))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                fieldLabel(l.t("Отпускает", "Lets go"))
                HStack(spacing: 8) {
                    NumberField(value: info?.lidGraceMin ?? 2) { run(["lid", "grace", String($0)]) }
                    Text(l.t("мин после последней сессии", "min after the last session")).fixedSize()
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                HStack(spacing: 8) {
                    Text(l.t("или на батарее при", "or on battery at")).fixedSize()
                    NumberField(value: info?.lidBattery ?? 15) { run(["lid", "battery", String($0)]) }
                    Text("%").fixedSize()
                }
            }
        }
        .font(.system(size: 13))
        if !ready {
            HStack(spacing: 12) {
                UtilityButton(title: l.t("Настроить", "Set up"), args: ["lid", "setup"], prominent: true)
                Note(text: l.t("Ставит правило sudoers для pmset, sudo один раз спросит пароль во вкладке.",
                               "Adds a sudoers rule for pmset, sudo asks for the password once in a tab."))
            }
        }
        Note(text: l.t("Mac в закрытой сумке греется.", "A Mac in a closed bag gets hot."))
    }
}

/// Строка журнала guard в виде guard_log: "24.11 19:47  hold  secrets-read   /x/.env".
struct GuardLine {
    let time, action, rule, what: String

    init?(_ line: String) {
        guard let m = logMatch(#"^(\d\d\.\d\d \d\d:\d\d)\s+(\S+)\s+(\S+)(?:\s+(.*))?$"#, line) else { return nil }
        time = m[0] ?? ""
        action = m[1] ?? ""
        rule = m[2] ?? ""
        what = m[3] ?? ""
    }
}

/// Строка журнала translate: "2026-11-27 10:41:07 3f9c2a1e 182 зн 640 мс переведен". Итог пишется по-русски,
/// для английского интерфейса известные итоги переводятся, остальное показывается как есть.
struct TranslateLine {
    let date, time: String
    let chars: Int
    let ms: Int?
    let raw: String

    init?(_ line: String) {
        guard let m = logMatch(#"^(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) \S+ (\d+) зн(?: (\d+) мс)? (.+)$"#, line),
              let chars = Int(m[2] ?? "") else { return nil }
        date = m[0] ?? ""
        time = m[1] ?? ""
        self.chars = chars
        ms = m[3].flatMap { Int($0) }
        raw = m[4] ?? ""
    }

    /// Только время для сегодняшних строк, иначе день и месяц.
    var shortTime: String {
        // журнал пишет местное время
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        guard date != today, date.count == 10 else { return time }
        let p = date.split(separator: "-")
        return "\(p[2]).\(p[1]) \(time.prefix(5))"
    }

    var ok: Bool { raw == "переведен" }
    var skipped: Bool { raw.hasPrefix("пропущен") }
    var failed: Bool { raw.hasPrefix("ошибка") || raw.hasPrefix("сбой") }

    static let secrets = ["приватный ключ": "private key", "ссылка proxy": "proxy link", "пароль в ссылке": "password in a link",
                          "токен в ссылке": "token in a link", "ключ API": "API key", "токен GitHub": "GitHub token",
                          "токен Slack": "Slack token", "ключ AWS": "AWS key", "ключ Google": "Google key",
                          "токен Telegram": "Telegram token", "секрет в присваивании": "secret in an assignment",
                          "заголовок авторизации": "authorization header", "длинный токен": "long token"]

    func result(_ l: L) -> String {
        guard l.en else { return raw }
        func after(_ prefix: String) -> String? { raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : nil }
        if ok { return "translated" }
        if raw == "перевод совпал с оригиналом" { return "same as the original" }
        if let e = after("ошибка, ") { return "error, " + e }
        if let e = after("сбой ") { return "crash " + e }
        if let r = raw.range(of: " не ответил вовремя, перевел ") {
            return "\(raw[..<r.lowerBound]) late, \(raw[r.upperBound...]) translated"
        }
        if let why = after("пропущен, ") {
            let reasons = ["пусто": "empty", "слэш-команда": "slash command", "без нелатинских букв": "no non-Latin letters"]
            if let en = reasons[why] { return "skipped, " + en }
            if let n = logMatch(#"^длиннее (\d+) знаков$"#, why)?[0] { return "skipped, longer than \(n) characters" }
            if let s = logMatch(#"^похоже на секрет \((.+)\)$"#, why)?[0] {
                return "skipped, looks like a secret (\(Self.secrets[s] ?? s))"
            }
            return "skipped, " + why
        }
        return raw
    }
}

/// Группы совпадения с начала строки, nil у группы, которая не участвовала.
private func logMatch(_ pattern: String, _ text: String) -> [String?]? {
    guard let rx = try? NSRegularExpression(pattern: pattern),
          let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } }
}

/// Ответ app-state guard-test.
struct GuardTest: Decodable {
    let rule: String?
    let why: String?
    let off: Bool?
}

// MARK: - Уведомления

/// Уведомления по макету Notify.dc.html: Mac и каналы на телефон (NotifyChannels.swift).
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

    private func row<Control: View>(_ title: String, _ sub: String? = nil, @ViewBuilder control: @escaping () -> Control) -> some View {
        SettingsRow(title, sub, titleFont: .system(size: 13, weight: .medium), control: control)
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
            PhoneChannels(n: n, reload: reload)
            Note(text: l.t("Если сессия подключена к Remote Control и в /config включено Push when actions required, ее запросы и вопросы не дублируются в каналы на телефон. Уведомление на Mac остается.",
                           "If a session is connected to Remote Control with Push when actions required on in /config, its requests and questions are not duplicated to phone channels. The Mac notification stays."))
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
    static let codexHistoryKey = "terminal.codexHistory"
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

    static var codexHistory: Bool { UserDefaults.standard.object(forKey: codexHistoryKey) as? Bool ?? true }

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
    @AppStorage(TerminalPrefs.codexHistoryKey) private var codexHistory = true
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
                row(l.t("История Codex в терминале", "Codex history in the terminal")) {
                    Toggle("", isOn: $codexHistory).toggleStyle(.switch).labelsHidden()
                }
                .help(l.t("В новых и перезапущенных вкладках Codex текущий запрос закреплен над ответом. Выключите для полноэкранного режима Codex.",
                          "Pin the current prompt above its answer in new and restarted Codex tabs. Turn off for the fullscreen Codex interface."))
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
        GlassSection {
            SettingsRow(l.t("Агент для новых сессий", "Agent for new sessions")) {
                SegmentedCapsule(selection: $defaultAgent, options: [("claude", "Claude Code", nil), ("codex", "Codex", nil),
                                                                      ("ask", l.t("Спрашивать", "Ask each time"), nil)],
                                 compact: true)
            }
        }
        if let d = backend.state.sessionDefaults {
            SessionDefaultsSection(d: d, l: l, set: { key, value in Task { _ = await backend.perform(["defaults", key, value]) } })
        }
        if let data {
            // карточки одной высоты: каждая тянется до самой высокой
            HStack(alignment: .top, spacing: 16) {
                AgentCard(agent: .claude, info: data.claude, l: l, reload: reload)
                AgentCard(agent: .codex, info: data.codex, l: l, reload: reload)
            }
            .fixedSize(horizontal: false, vertical: true)
            HeadsUpSection(l: l)
        } else {
            ProgressView()
        }
    }
}

/// Умолчания для сессий, которые agentmeister открывает сам: open_claude, /parallel, меню в терминале.
/// Вкладки приложения берут режим и Remote Control из листа новой сессии, это отдельно.
struct SessionDefaultsSection: View {
    let d: AppState.SessionDefaults
    let l: L
    let set: (String, String) -> Void

    var body: some View {
        GlassSection {
            Text(l.t("Сессии, которые открывает agentmeister", "Sessions agentmeister opens"))
                .font(.system(size: 15, weight: .semibold))
            Text(l.t("open_claude, /parallel и меню agentmeister в терминале. Новые вкладки этого окна берут настройки из листа новой сессии.",
                     "open_claude, /parallel and the agentmeister menu in a terminal. New tabs in this window take their settings from the new session sheet."))
                .font(.system(size: 12)).foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
            SettingsRow(l.t("Режим", "Mode"),
                        l.t("caffeinate не дает Mac уснуть, пока идет сессия.", "caffeinate keeps the Mac awake while the session runs.")) {
                SegmentedCapsule(selection: Binding(get: { d.mode }, set: { set("mode", $0) }),
                                 options: [("caffeinate", "caffeinate", nil), ("normal", l.t("Обычный", "Normal"), nil)], compact: true)
            }
            Divider()
            SettingsRow(l.t("Remote Control", "Remote Control"),
                        l.t("Сессию можно вести с телефона и на claude.ai.", "The session can be driven from a phone and on claude.ai.")) {
                Toggle("", isOn: Binding(get: { d.remoteControl }, set: { set("remote-control", $0 ? "on" : "off") }))
                    .toggleStyle(.switch).labelsHidden()
            }
            Divider()
            SettingsRow(l.t("/restart обновляет Claude Code", "/restart updates Claude Code"),
                        l.t("Перед перезапуском выполняется claude update.", "claude update runs before the restart.")) {
                Toggle("", isOn: Binding(get: { d.restartUpdate }, set: { set("restart-update", $0 ? "on" : "off") }))
                    .toggleStyle(.switch).labelsHidden()
            }
            Divider()
            SettingsRow(l.t("Модель для /ask", "Model for /ask"),
                        l.t("Отдельный Claude, который отвечает про другой проект.", "The separate Claude that answers about another project.")) {
                SegmentedCapsule(selection: Binding(get: { d.askModel }, set: { set("ask-model", $0) }),
                                 options: [("sonnet", "Sonnet", nil), ("opus", "Opus", nil), ("haiku", "Haiku", nil)], compact: true)
            }
        }
    }
}

/// Ответ app-state headsup: заметки Heads up и You should know из Claude Code, новые первыми.
struct HeadsUpData: Decodable {
    struct Entry: Decodable, Hashable {
        let ts: Double?
        let headline: String
        let project: String?
        let cwd: String?
        let session: String?
        let tag: String?
        let times: Int?
    }

    let entries: [Entry]
    let path: String
    let plugin: Bool
    let max: Int
}

extension Backend {
    func headsup() async -> HeadsUpData? { await Self.json(["app-state", "headsup"]) }
}

/// Заметки Heads up, которые показывал Claude Code, и закрытые случайно тоже. Плагин хранит только заголовки,
/// время, проект и сессию дописывает хук agentmeister (headsup.py), текста пояснения нет нигде.
struct HeadsUpSection: View {
    @EnvironmentObject var backend: Backend
    let l: L
    @State private var data: HeadsUpData?
    @State private var all = false
    private static let shown = 6

    var body: some View {
        GlassSection(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Heads up").font(.system(size: 17, weight: .semibold))
                Spacer()
                if let data, !data.entries.isEmpty {
                    Text(l.count(data.entries.count, "заметка", "заметки", "заметок", "note", "notes"))
                        .font(.system(size: 12)).foregroundStyle(Ink.muted)
                }
            }
            Note(text: l.t("Заметки Heads up и You should know, которые показывал Claude Code, в том числе закрытые. Claude Code хранит только заголовки, без пояснения из карточки. Время и проект agentmeister записывает сам.",
                           "Heads up and You should know notes Claude Code has shown, closed ones included. Claude Code keeps only the headlines, not the explanation from the card. agentmeister records the time and project itself."))
            if let data {
                if data.entries.isEmpty {
                    Text(data.plugin ? l.t("Заметок пока нет", "No notes yet")
                                     : l.t("Claude Code еще не показывал заметок", "Claude Code has not shown any notes yet"))
                        .font(.system(size: 12)).foregroundStyle(Ink.muted)
                } else {
                    ForEach(Array(data.entries.prefix(all ? data.entries.count : Self.shown).enumerated()), id: \.offset) { _, e in
                        row(e)
                    }
                    HStack(spacing: 16) {
                        if data.entries.count > Self.shown {
                            Button(all ? l.t("Свернуть", "Show fewer") : l.t("Показать все", "Show all")) { all.toggle() }
                                .buttonStyle(.textLink)
                        }
                        Spacer()
                        Button(tilde(data.path)) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: data.path)])
                        }
                        .buttonStyle(.textLink(Ink.muted))
                        .help(l.t("Показать в Finder", "Show in Finder"))
                    }
                    .font(.system(size: 12))
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { data = await backend.headsup() }
    }

    private func row(_ e: HeadsUpData.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(e.headline)
                .font(.system(size: 13))
                .foregroundStyle(Ink.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(meta(e))
                .font(.system(size: 11))
                .foregroundStyle(Ink.faint)
                .textSelection(.enabled)
                .help(e.cwd.map(tilde) ?? "")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
    }

    private func meta(_ e: HeadsUpData.Entry) -> String {
        var parts = [e.ts.map(when) ?? l.t("раньше, время неизвестно", "earlier, time unknown")]
        if let project = e.project { parts.append(project) }
        if let tag = e.tag, tag != "Heads up" { parts.append(tag) }
        if let n = e.times, n > 1 { parts.append(l.t("показана ", "shown ") + l.count(n, "раз", "раза", "раз", "time", "times")) }
        return parts.joined(separator: " · ")
    }

    private func when(_ ts: Double) -> String {
        let date = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.locale = Locale(identifier: l.en ? "en_US" : "ru_RU")
        let thisYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        f.dateFormat = l.en ? (thisYear ? "MMM d, HH:mm" : "MMM d yyyy, HH:mm") : (thisYear ? "d MMM, HH:mm" : "d MMM yyyy, HH:mm")
        return f.string(from: date)
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
    private func fix(_ row: DoctorData.Row) -> [String]? {
        switch row.check {
        case "codex":
            if row.text.contains("/hooks") && !row.text.contains("--harness codex setup") { return nil }
            return ["--harness", "codex", "setup"]
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
        let off = rest.filter { $0.level == "off" }.count
        let ok = rest.count - off
        let summary = [
            problems(bad: bad, warn: issues.count - bad),
            ok > 0 ? l.t("\(checks(ok)) в порядке", "\(checks(ok)) OK") : "",
            off > 0 ? l.t("выключено \(off)", "\(off) off") : ""
        ].filter { !$0.isEmpty }.joined(separator: ", ")
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
            if let args = fix(row) {
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
