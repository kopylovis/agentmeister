import ApplicationServices
import ServiceManagement
import SwiftUI

extension SettingsData.Agent {
    var signedInValue: Bool { signedIn ?? false }
}

/// Мастер первого запуска по макету Onboarding.dc.html: язык и вид, агенты, proxy, вход, режимы, разрешения.
/// Сам почти ничего не делает: показывает состояние из app-state settings и запускает те же команды, что в CLI,
/// в своем терминале под шагом. Вход в агентов идет через agentmeister proxy run, так что токены агенты получают
/// через proxy, а страница входа открывается во встроенном браузере через тот же mihomo.
struct OnboardingView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboardingDone") private var done = false
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    @State private var step = 0
    @State private var data: SettingsData?
    @State private var doctor: DoctorData?
    /// Команда, запущенная кнопкой мастера. Ее терминал виден прямо в мастере.
    @State private var console: TerminalTab?
    @State private var subscription = ""
    @State private var country = ""
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var l: L { L(backend.state.lang) }

    private enum Step: Int, CaseIterable { case look, agents, proxy, signIn, modes, permissions }

    private func name(_ s: Step) -> String {
        switch s {
        case .look: return l.t("Язык и вид", "Language and look")
        case .agents: return l.t("Агенты", "Agents")
        case .proxy: return "Proxy"
        case .signIn: return l.t("Вход", "Sign in")
        case .modes: return l.modes
        case .permissions: return l.t("Разрешения", "Permissions")
        }
    }

    var body: some View {
        let current = Step(rawValue: step) ?? .look
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agentmeister").font(.system(size: 15, weight: .semibold))
                Text(l.t("Первый запуск", "First run")).font(.system(size: 11)).foregroundStyle(Ink.muted).padding(.bottom, 14)
                ForEach(Step.allCases, id: \.self) { item in
                    Button {
                        step = item.rawValue
                    } label: {
                        HStack(spacing: 10) {
                            StepMark(index: item.rawValue, state: item.rawValue < step ? .done : item == current ? .current : .todo)
                            Text(name(item)).foregroundStyle(item == current ? Ink.strong : Ink.text2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 10).fill(item == current ? Ink.thumb : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(item == current ? .isSelected : [])
                }
                Spacer()
            }
            .padding(16)
            .frame(width: 210)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(10)
            .accessibilityLabel(l.t("Шаги настройки", "Setup steps"))

            VStack(alignment: .leading, spacing: 14) {
                Text(l.t("Шаг \(step + 1) из \(Step.allCases.count)", "Step \(step + 1) of \(Step.allCases.count)"))
                    .font(.system(size: 11)).foregroundStyle(Ink.muted)
                // лист не выше главного окна: пока открыт терминал, пояснение шага прячется, а сам шаг
                // при нехватке места прокручивается
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(title(current)).font(.system(size: 22, weight: .semibold))
                        lead(lead(current))
                        switch current {
                        case .look: lookStep
                        case .agents: agentsStep
                        case .proxy: proxyStep
                        case .signIn: signInStep
                        case .modes: modesStep
                        case .permissions: permissionsStep
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity)
                if let console {
                    ConsolePanel(tab: console, l: l) { close() }
                        .frame(height: 220)
                }
                HStack {
                    if current == .proxy && data?.proxy?.configured != true {
                        Button(l.t("Пропустить, работать без proxy", "Skip, work without the proxy")) { skipProxy() }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    Button("") { finish() }.keyboardShortcut(.cancelAction).hidden().frame(width: 0)
                    if step > 0 {
                        Button(l.t("Назад", "Back")) { step -= 1 }
                    }
                    Button(current == .permissions ? l.t("Открыть Agentmeister", "Open Agentmeister") : l.t("Далее", "Continue")) {
                        if current == .permissions { finish() } else { step += 1 }
                    }
                    .buttonStyle(.glassProminent)
                    // пока виден терминал, Return нужен ему, а не кнопке
                    .keyboardShortcut(console == nil ? .defaultAction : nil)
                }
            }
            .padding(22)
        }
        .frame(width: 820, height: 540)
        .environment(\.utilityRunner) { args in run(args) }
        .task { await reload() }
        .onChange(of: step) { Task { await reload() } }
        .onDisappear { console?.terminate() }
    }

    private func title(_ s: Step) -> String {
        switch s {
        case .look: return l.t("Язык и вид", "Language and look")
        case .agents: return l.t("Какие агенты есть на этом Mac", "Agents on this Mac")
        case .proxy: return l.t("Proxy для сессий", "Session proxy")
        case .signIn: return l.t("Вход в агентов", "Sign in to the agents")
        case .modes: return l.t("Режимы и интеграции", "Modes and integrations")
        case .permissions: return l.t("Разрешения macOS", "macOS permissions")
        }
    }

    private func lead(_ s: Step) -> String {
        switch s {
        case .look: return l.t("По умолчанию как в macOS. Поменять можно потом в настройках.", "Follows macOS by default. You can change both later in Settings.")
        case .agents: return l.t("Agentmeister запускает Claude Code и Codex в своих вкладках. Нужен хотя бы один из них.",
                                 "Agentmeister runs Claude Code and Codex in its own tabs. You need at least one of them.")
        case .proxy: return l.t("Сессии через proxy работают в sandbox-exec и ходят в сеть только через mihomo. Вход в агентов на следующем шаге тоже пойдет через него.",
                                "Proxied sessions run in sandbox-exec and reach the network only through mihomo. Signing in to the agents on the next step goes through it too.")
        case .signIn: return l.t("Каждый агент хранит свой вход. Agentmeister только открывает страницу входа и проверяет, что он прошел.",
                                 "Each agent keeps its own sign-in. Agentmeister opens the sign-in page and checks that it worked.")
        case .modes: return l.t("Все это переключается потом на боковой панели и в настройках.", "You can switch all of these later in the sidebar and in Settings.")
        case .permissions: return l.t("macOS спросит их один раз. Без них Agentmeister работает, но без этих функций.",
                                      "macOS asks for these once. Agentmeister works without them, minus these features.")
        }
    }

    /// Запустить команду agentmeister в терминале мастера. Предыдущая, если еще идет, останавливается.
    private func run(_ args: [String]) {
        console?.onExit = nil
        console?.terminate()
        var spec = LaunchSpec(projectName: "agentmeister", projectPath: NSHomeDirectory())
        spec.utility = args
        let tab = TerminalTab(spec: spec)
        tab.exitHint = false
        tab.onExit = { Task { await reload() } }
        console = tab
    }

    private func close() {
        console?.onExit = nil
        console?.terminate()
        console = nil
        Task { await reload() }
    }

    private func reload() async {
        data = await backend.settings()
        if Step(rawValue: step) == .modes { doctor = await backend.doctor() }
        screenAllowed = CGPreflightScreenCaptureAccess()
        loginItem = SMAppService.mainApp.status == .enabled
    }

    private func finish() {
        close()
        done = true
        dismiss()
    }

    private func skipProxy() {
        Task {
            _ = await backend.perform(["proxy", "remember", "direct"])
            step += 1
        }
    }

    /// Пояснение под заголовком шага. Пока открыт терминал, его нет: так шаг и терминал помещаются без обрезки.
    @ViewBuilder
    private func lead(_ text: String) -> some View {
        if console == nil {
            Text(text).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func statusLine(_ ok: Bool, _ text: String, muted: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(ok ? Ink.teal : muted ? Ink.muted : Ink.amber)
    }

    // MARK: Шаги

    private var lookStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(l.t("Язык", "Language")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.muted)
                SegmentedCapsule(selection: Binding(
                    get: { backend.state.langSetting ?? "auto" },
                    set: { value in Task { _ = await backend.perform(["lang", value]) } }
                ), options: [("auto", l.t("Как в системе", "System"), nil), ("ru", "Русский", nil), ("en", "English", nil)])
                .frame(maxWidth: 440)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(l.t("Оформление", "Appearance")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.muted)
                AppearancePicker(selection: $appearance, l: l)
            }
        }
    }

    private var agentsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            agentCard(.claude, data?.claude)
            agentCard(.codex, data?.codex)
            Note(text: l.t("Агенты ставятся в обычные места, как без Agentmeister. Их можно запускать и из терминала.",
                           "Agents install to their usual places, as they would without Agentmeister. You can still run them from a terminal."))
            Button(l.t("Проверить снова", "Check again")) { Task { await reload() } }
        }
    }

    private func agentCard(_ agent: LaunchSpec.Agent, _ info: SettingsData.Agent?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            card {
                HStack(spacing: 12) {
                    AgentBadge(agent: agent, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent == .claude ? "Claude Code" : "Codex").font(.system(size: 14, weight: .semibold))
                        if data == nil {
                            ProgressView().controlSize(.small)
                        } else if let info, info.installed {
                            statusLine(true, l.t("Установлен · ", "Installed · ") + tilde(info.path ?? "") + (info.version.map { " · " + $0 } ?? ""))
                        } else {
                            statusLine(false, l.t("Не найден", "Not found"))
                        }
                    }
                }
            }
            if data != nil, info?.installed != true {
                UtilityButton(title: agent == .codex ? l.t("Установить через Homebrew", "Install with Homebrew") : l.t("Установить", "Install"),
                              args: ["--harness", agent.rawValue, "install"])
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private var proxyStep: some View {
        let p = data?.proxy
        return VStack(alignment: .leading, spacing: 12) {
            if let p {
                if p.configured {
                    HStack(spacing: 10) {
                        GlowDot(color: Ink.tealDot)
                        Text(l.t("Выход \(p.exit ?? "") работает", "Exit \(p.exit ?? "") works")).fontWeight(.medium).foregroundStyle(Ink.teal)
                        Text([p.protocol, p.ip].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.muted)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .glassEffect(.regular.tint(Ink.tealDot.opacity(0.18)), in: .rect(cornerRadius: 14))
                    HStack {
                        UtilityButton(title: l.t("Проверить выход", "Check the exit"), args: ["proxy", "test"])
                        UtilityButton(title: l.t("Сменить подписку", "Change subscription"), args: ["proxy", "setup"])
                    }
                } else {
                    card {
                        Text(l.t("Ссылка на подписку 3x-ui", "3x-ui subscription link")).font(.system(size: 12)).foregroundStyle(Ink.muted)
                        TextField("https://example.com/sub/…", text: $subscription)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        HStack(spacing: 10) {
                            Text(l.t("Страна выхода", "Exit country")).font(.system(size: 12)).foregroundStyle(Ink.muted)
                            Picker("", selection: $country) {
                                Text(l.t("Любая рабочая", "Any working")).tag("")
                                ForEach(["KZ", "SE", "GE", "DE", "NL", "FI", "US"], id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }
                    }
                    Button(l.t("Проверить", "Check")) {
                        run(["proxy", "setup", subscription.trimmingCharacters(in: .whitespaces)] + (country.isEmpty ? [] : ["--country", country]))
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!subscription.hasPrefix("http"))
                }
                Toggle(l.t("Новые сессии по умолчанию через proxy", "New sessions use the proxy by default"), isOn: Binding(
                    get: { p.defaultRoute != "direct" },
                    set: { on in Task { _ = await backend.perform(["proxy", "remember", on ? "vps" : "direct"]); await reload() } }
                ))
                .disabled(!p.configured)
                Note(text: l.t("Ссылка и подписка лежат в ~/.config/mnrh/proxy/, читать их можешь только ты. Сессиям они не видны.",
                               "The link and subscription live in ~/.config/mnrh/proxy/, readable only by you. Sessions can't see them."))
            } else {
                ProgressView()
            }
        }
    }

    private var signInStep: some View {
        let p = data?.proxy
        let ready = p?.configured == true
        return VStack(alignment: .leading, spacing: 12) {
            if ready {
                HStack(spacing: 7) {
                    Image(systemName: "shield").font(.system(size: 11, weight: .semibold))
                    Text(l.t("Вход идет через proxy", "Signing in through proxy") + (p?.exit.map { " " + $0 } ?? ""))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.teal)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(Ink.tealChip))
            } else {
                Text(l.t("Сначала настрой proxy на прошлом шаге: вход идет через него.", "Set up the proxy on the previous step first: sign-in goes through it."))
                    .font(.system(size: 12)).foregroundStyle(Ink.amber)
            }
            signInCard(.claude, data?.claude, ready: ready)
            signInCard(.codex, data?.codex, ready: ready)
            Note(text: l.t("Claude Code хранит вход в связке ключей macOS, Codex в ~/.codex/auth.json. Сессии через proxy продлевают его через тот же proxy.",
                           "Claude Code keeps its sign-in in the macOS keychain, Codex in ~/.codex/auth.json. Proxied sessions refresh it through the same proxy."))
        }
    }

    private func signInCard(_ agent: LaunchSpec.Agent, _ info: SettingsData.Agent?, ready: Bool) -> some View {
        let login = agent == .claude ? ["claude", "auth", "login"] : ["codex", "login"]
        let logout = agent == .claude ? ["claude", "auth", "logout"] : ["codex", "logout"]
        return VStack(alignment: .leading, spacing: 8) {
            card {
                HStack(spacing: 12) {
                    AgentBadge(agent: agent, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent == .claude ? "Claude Code" : "Codex").font(.system(size: 14, weight: .semibold))
                        if data == nil {
                            ProgressView().controlSize(.small)
                        } else if let info, info.installed {
                            if info.signedInValue {
                                let plan = info.plan.map { l.t("подписка ", "") + $0 + l.t("", " plan") }
                                let who = info.email.map { l.t(" как ", " as ") + $0 } ?? ""
                                statusLine(true, l.t("Вошли", "Signed in") + who + (plan.map { " · " + $0 } ?? ""))
                            } else {
                                statusLine(false, l.t("Не выполнен вход", "Not signed in"), muted: true)
                            }
                        } else {
                            statusLine(false, l.t("не установлен", "not installed"), muted: true)
                        }
                    }
                }
            }
            if let info, info.installed {
                HStack {
                    if info.signedInValue {
                        UtilityButton(title: l.t("Выйти", "Sign out"), args: ["proxy", "run", "--claude", "--"] + logout)
                            .disabled(!ready)
                    } else {
                        UtilityButton(title: l.t("Войти", "Sign in"), args: ["proxy", "run", "--claude", "--"] + login)
                            .buttonStyle(.glassProminent)
                            .disabled(!ready)
                    }
                }
            }
        }
    }

    private var modesStep: some View {
        let rows = doctor?.rows ?? []
        let promptsill = rows.contains { $0.text.contains("promptsill") && $0.level == "ok" }
        let commands = rows.contains { $0.check == "commands" && $0.level == "ok" } && rows.contains { $0.check == "mcp" && $0.level == "ok" }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            modeCard("humanize", l.t("Правила письма без примет нейросети для обоих агентов", "Writing rules without AI tells, for both agents"))
            modeCard("guard", l.t("Спрашивать перед секретами и необратимыми командами", "Ask before secrets and irreversible commands"))
            modeCard("notify", l.t("Сказать, когда агент ждет ответа, в том числе в Telegram", "Tell you when an agent is waiting, Telegram included"))
            modeCard("buildlog", l.t("Длинный вывод сборки агент получает выжимкой", "The agent gets a digest of long build output"))
            setupCard(l.t("Строка promptsill", "promptsill status line"), l.t("Контекст, лимиты и proxy под полем ввода", "Context, limits and proxy under the prompt"), ok: promptsill)
            setupCard(l.t("MCP и слэш-команды", "MCP and slash commands"), l.t("/restart, /slim, /todo, /parallel и инструменты agentmeister", "/restart, /slim, /todo, /parallel and agentmeister tools"), ok: commands)
        }
    }

    private func modeCard(_ key: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(key).fontWeight(.semibold)
                Text(text).font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(key, isOn: Binding(get: { backend.state.modes[key] ?? false }, set: { backend.setMode(key, on: $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Ink.card))
    }

    private func setupCard(_ title: String, _ text: String, ok: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(text).font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if doctor == nil {
                ProgressView().controlSize(.small)
            } else if ok {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.tealDot)
            } else {
                UtilityButton(title: l.t("Поставить", "Install"), args: ["setup"]).controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Ink.card))
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            permission(l.t("Уведомления", "Notifications"), l.t("Для \"Claude ждет ответа\" и подтверждений guard", "For \"Claude is waiting\" and guard prompts"),
                       allowed: nil, open: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                CommandButton(title: l.t("Прислать тест", "Send test"), args: ["notify", "test"]) { await reload() }
            }
            permission(l.t("Запись экрана", "Screen Recording"), l.t("Для снимков окон, /shot", "For window screenshots, /shot"),
                       allowed: screenAllowed, open: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                if !screenAllowed {
                    Button(l.t("Попросить доступ", "Ask for access")) {
                        CGRequestScreenCaptureAccess()
                        screenAllowed = CGPreflightScreenCaptureAccess()
                    }
                }
            }
            permission(l.t("Объекты входа", "Login Items"),
                       l.t("Agentmeister открывается при входе и возвращает вкладки, с ними поднимаются host-run и mihomo",
                           "Agentmeister opens at login and brings back its tabs, host-run and mihomo start with them"),
                       allowed: loginItem, open: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                if !loginItem {
                    Button(l.t("Добавить", "Add")) {
                        try? SMAppService.mainApp.register()
                        loginItem = SMAppService.mainApp.status == .enabled
                    }
                }
            }
        }
    }

    /// Карточка разрешения: состояние в карточке, кнопки под ней. allowed nil значит, что macOS не дает его узнать.
    private func permission<Extra: View>(_ title: String, _ text: String, allowed: Bool?, open: String,
                                         @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            card {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        Text(text).font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if allowed == true {
                        Text(l.t("Разрешено", "Allowed")).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.teal)
                    }
                }
            }
            if allowed != true {
                HStack {
                    Button(l.t("Открыть настройки", "Open Settings")) {
                        if let url = URL(string: open) { NSWorkspace.shared.open(url) }
                    }
                    extra()
                }
            }
        }
    }
}

/// Кружок шага в боковой панели мастера: номер, текущий залит акцентом, пройденный с бирюзовой галочкой.
struct StepMark: View {
    enum State { case done, current, todo }
    let index: Int
    let state: State

    var body: some View {
        ZStack {
            Circle().fill(state == .current ? Color.accentColor : state == .done ? Ink.tealChip : Ink.chip)
            if state == .done {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.teal)
            } else {
                Text("\(index + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(state == .current ? .white : Ink.muted)
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// Терминал команды внутри мастера: заголовок с командой и состоянием, кнопка закрыть.
struct ConsolePanel: View {
    @ObservedObject var tab: TerminalTab
    let l: L
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text(tab.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if tab.running {
                    ProgressView().controlSize(.small)
                } else {
                    Text(tab.exitCode == 0 ? l.t("готово", "done") : l.t("код \(tab.exitCode.map(String.init) ?? "?")", "exit \(tab.exitCode.map(String.init) ?? "?")"))
                        .font(.caption)
                        .foregroundStyle(tab.exitCode == 0 ? Ink.teal : Ink.amber)
                }
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(tab.running ? l.t("Остановить и закрыть", "Stop and close") : l.t("Закрыть", "Close"))
                    .accessibilityLabel(tab.running ? l.t("Остановить и закрыть", "Stop and close") : l.t("Закрыть", "Close"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            TerminalHost(tab: tab)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}
