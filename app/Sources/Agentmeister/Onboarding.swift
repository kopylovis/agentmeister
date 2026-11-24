import SwiftUI

extension SettingsData.Agent {
    var signedInValue: Bool { signedIn ?? false }
}

/// Мастер первого запуска: агенты, proxy, вход, режимы, разрешения. Сам почти ничего не делает, а показывает
/// состояние из app-state settings и запускает те же команды, что в CLI, в своем терминале под шагами. Вход в агентов
/// идет через agentmeister proxy run, так что токены агенты получают через proxy.
struct OnboardingView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboardingDone") private var done = false
    @State private var step = 0
    @State private var data: SettingsData?
    /// Команда, запущенная кнопкой мастера. Ее терминал виден прямо в мастере.
    @State private var console: TerminalTab?

    var l: L { L(backend.state.lang) }

    private var steps: [(String, String)] {
        [(l.t("Агенты", "Agents"), "cpu"), ("Proxy", "shield.lefthalf.filled"), (l.t("Вход", "Sign in"), "person.badge.key"),
         (l.modes, "switch.2"), (l.t("Готово", "Done"), "checkmark.seal")]
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agentmeister").font(.title3.weight(.semibold)).padding(.bottom, 2)
                Text(l.t("Первый запуск", "First run")).font(.caption).foregroundStyle(.secondary).padding(.bottom, 14)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                    Button {
                        step = index
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: index < step ? "checkmark.circle.fill" : item.1)
                                .foregroundStyle(index < step ? Color.teal : index == step ? Color.accentColor : Color.secondary)
                                .frame(width: 20)
                            Text(item.0)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9).fill(index == step ? Color.primary.opacity(0.1) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(16)
            .frame(width: 210)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(10)

            VStack(alignment: .leading, spacing: 14) {
                Text(l.t("Шаг \(step + 1) из \(steps.count)", "Step \(step + 1) of \(steps.count)"))
                    .font(.caption).foregroundStyle(.secondary)
                // лист не выше главного окна: пока открыт терминал, пояснение шага прячется, а сам шаг
                // при нехватке места прокручивается
                ScrollView {
                    Group {
                        switch step {
                        case 0: agentsStep
                        case 1: proxyStep
                        case 2: signInStep
                        case 3: modesStep
                        default: doneStep
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
                    if step < steps.count - 1 {
                        Button(l.t("Пропустить мастер", "Skip setup")) { finish() }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    if step > 0 {
                        Button(l.t("Назад", "Back")) { step -= 1 }
                    }
                    Button(step == steps.count - 1 ? l.t("Открыть Agentmeister", "Open Agentmeister") : l.t("Далее", "Continue")) {
                        if step == steps.count - 1 { finish() } else { step += 1 }
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

    private func reload() async { data = await backend.settings() }

    private func finish() {
        close()
        done = true
        dismiss()
    }

    /// Пояснение под заголовком шага. Пока открыт терминал, его нет: так шаг и терминал помещаются без обрезки.
    @ViewBuilder
    private func lead(_ text: String) -> some View {
        if console == nil {
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func status(_ ok: Bool, _ okText: String, _ badText: String) -> some View {
        Label(ok ? okText : badText, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(ok ? Color.teal : Color.orange)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var agentsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l.t("Какие агенты есть на этом Mac", "Agents on this Mac")).font(.title2.weight(.semibold))
            lead(l.t("Agentmeister запускает Claude Code и Codex в своих вкладках. Нужен хотя бы один из них.",
                     "Agentmeister runs Claude Code and Codex in its own tabs. You need at least one."))
            agentCard("Claude Code", data?.claude, install: ["--harness", "claude", "install"])
            agentCard("Codex", data?.codex, install: ["--harness", "codex", "install"])
            Button(l.t("Проверить снова", "Check again")) { Task { await reload() } }
                .help(l.t("Перечитать, какие агенты установлены", "Look for installed agents again"))
        }
    }

    private func agentCard(_ name: String, _ info: SettingsData.Agent?, install: [String]) -> some View {
        card {
            HStack {
                Text(name).font(.headline)
                Spacer()
                if let info, info.installed {
                    status(true, (info.version ?? "") + " · " + tilde(info.path ?? ""), "")
                        .font(.callout)
                } else {
                    UtilityButton(title: l.t("Установить", "Install"), args: install)
                }
            }
        }
    }

    private var proxyStep: some View {
        let p = data?.proxy
        return VStack(alignment: .leading, spacing: 12) {
            Text(l.t("Proxy для сессий", "Session proxy")).font(.title2.weight(.semibold))
            lead(l.t("Сессии через proxy идут в sandbox-exec и ходят в сеть через mihomo. Вход в агентов на следующем шаге тоже пойдет через него.",
                     "Proxied sessions run in sandbox-exec and reach the network through mihomo. Signing in on the next step goes through it too."))
            card {
                if let p {
                    status(p.configured, l.t("proxy настроен", "proxy is set up") + (p.exit.map { ", " + l.t("выход ", "exit ") + $0 } ?? ""),
                           l.t("proxy не настроен", "proxy isn't set up"))
                } else {
                    ProgressView()
                }
            }
            // действия под карточкой, а не в ней: карточка показывает только состояние, как на остальных шагах
            if let p {
                HStack {
                    UtilityButton(title: p.configured ? l.t("Сменить подписку", "Change subscription") : l.t("Настроить proxy", "Set up proxy"),
                                  args: ["proxy", "setup"])
                    if p.configured {
                        UtilityButton(title: l.t("Проверить выход", "Check the exit"), args: ["proxy", "test"])
                    }
                }
            }
        }
    }

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l.t("Вход в агентов", "Sign in to the agents")).font(.title2.weight(.semibold))
            lead(l.t("Каждый агент хранит свой вход. Команда входа идет здесь же, через proxy: агент получает токен через mihomo, а страница входа открывается во встроенном браузере через тот же mihomo.",
                     "Each agent keeps its own sign-in. The sign-in command runs right here through the proxy: the agent gets its token through mihomo, and the sign-in page opens in the built-in browser through the same mihomo."))
            signInCard("Claude Code", data?.claude, args: ["proxy", "run", "--claude", "--", "claude", "auth", "login"])
            signInCard("Codex", data?.codex, args: ["proxy", "run", "--claude", "--", "codex", "login"])
        }
    }

    private func signInCard(_ name: String, _ info: SettingsData.Agent?, args: [String]) -> some View {
        card {
            HStack {
                Text(name).font(.headline)
                Spacer()
                if let info, info.installed {
                    if info.signedInValue {
                        status(true, l.t("вход выполнен", "signed in") + (info.plan.map { " · " + $0 } ?? ""), "")
                            .font(.callout)
                    } else {
                        UtilityButton(title: l.t("Войти", "Sign in"), args: args)
                    }
                } else {
                    Text(l.t("не установлен", "not installed")).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var modesStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l.t("Режимы", "Modes")).font(.title2.weight(.semibold))
            lead(l.t("Все это потом переключается на боковой панели и в настройках.", "You can switch these later in the sidebar and in Settings."))
            card {
                ForEach(["humanize", "guard", "buildlog", "notify"], id: \.self) { key in
                    HStack {
                        Text(l.modeTitle(key))
                        Spacer()
                        Toggle(l.modeTitle(key), isOn: Binding(
                            get: { backend.state.modes[key] ?? false },
                            set: { backend.setMode(key, on: $0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l.t("Все готово", "All set")).font(.title2.weight(.semibold))
            lead(l.t("Проект слева открывает новую сессию через proxy, сессия под проектом продолжается во вкладке. ⌘K ищет вкладки, сессии и действия, ⌘, открывает настройки. Мастер можно открыть снова из меню Help.",
                     "A project on the left opens a new session via the proxy, a session under it resumes in a tab. ⌘K finds tabs, sessions and actions, ⌘, opens Settings. You can reopen this from the Help menu."))
            UtilityButton(title: l.t("Проверить установку (setup)", "Check the install (setup)"), args: ["setup"])
            Text(l.t("Команды, хуки, MCP-сервер и promptsill. То же самое показывает Настройки, раздел Диагностика.",
                     "Commands, hooks, the MCP server and promptsill. Settings, Diagnostics shows the same."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                        .foregroundStyle(tab.exitCode == 0 ? Color.teal : Color.orange)
                }
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(tab.running ? l.t("Остановить и закрыть", "Stop and close") : l.t("Закрыть", "Close"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            TerminalHost(tab: tab)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}
