import SwiftUI

extension SettingsData.Agent {
    var signedInValue: Bool { signedIn ?? false }
}

/// Мастер первого запуска: агенты, proxy, вход, режимы, разрешения. Сам почти ничего не делает, а показывает
/// состояние из app-state settings и открывает служебные вкладки с теми же командами, что в CLI. Вход в агентов
/// идет через agentmeister proxy run, так что токены агенты получают через proxy.
struct OnboardingView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboardingDone") private var done = false
    @State private var step = 0
    @State private var data: SettingsData?

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
                Group {
                    switch step {
                    case 0: agentsStep
                    case 1: proxyStep
                    case 2: signInStep
                    case 3: modesStep
                    default: doneStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack {
                    if step < steps.count - 1 {
                        Button(l.t("Пропустить мастер", "Skip setup")) { finish() }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    Button(l.t("Проверить снова", "Check again")) { Task { await reload() } }
                    if step > 0 {
                        Button(l.t("Назад", "Back")) { step -= 1 }
                    }
                    Button(step == steps.count - 1 ? l.t("Открыть Agentmeister", "Open Agentmeister") : l.t("Далее", "Continue")) {
                        if step == steps.count - 1 { finish() } else { step += 1 }
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
        }
        .frame(width: 820, height: 540)
        .task { await reload() }
    }

    private func reload() async { data = await backend.settings() }

    private func finish() {
        done = true
        dismiss()
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
            Text(l.t("Agentmeister запускает Claude Code и Codex в своих вкладках. Нужен хотя бы один из них.",
                     "Agentmeister runs Claude Code and Codex in its own tabs. You need at least one."))
                .foregroundStyle(.secondary)
            agentCard("Claude Code", data?.claude, install: ["--harness", "claude", "install"])
            agentCard("Codex", data?.codex, install: ["--harness", "codex", "install"])
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
            Text(l.t("Сессии через proxy идут в sandbox-exec и ходят в сеть через mihomo. Вход в агентов на следующем шаге тоже пойдет через него.",
                     "Proxied sessions run in sandbox-exec and reach the network through mihomo. Signing in on the next step goes through it too."))
                .foregroundStyle(.secondary)
            card {
                if let p {
                    status(p.configured, l.t("proxy настроен", "proxy is set up") + (p.exit.map { ", " + l.t("выход ", "exit ") + $0 } ?? ""),
                           l.t("proxy не настроен", "proxy isn't set up"))
                    HStack {
                        UtilityButton(title: p.configured ? l.t("Сменить подписку", "Change subscription") : l.t("Настроить proxy", "Set up proxy"),
                                      args: ["proxy", "setup"])
                        if p.configured {
                            UtilityButton(title: l.t("Проверить выход", "Check the exit"), args: ["proxy", "test"])
                        }
                    }
                } else {
                    ProgressView()
                }
            }
        }
    }

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l.t("Вход в агентов", "Sign in to the agents")).font(.title2.weight(.semibold))
            Text(l.t("Каждый агент хранит свой вход. Вход открывается служебной вкладкой через proxy: агент получает токен через mihomo, страница входа открывается в браузере.",
                     "Each agent keeps its own sign-in. It runs in a utility tab through the proxy: the agent gets its token through mihomo, the sign-in page opens in the browser."))
                .foregroundStyle(.secondary)
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
            Text(l.t("Все это потом переключается на боковой панели и в настройках.", "You can switch these later in the sidebar and in Settings."))
                .foregroundStyle(.secondary)
            card {
                ForEach(["humanize", "guard", "buildlog", "notify"], id: \.self) { key in
                    Toggle(l.modeTitle(key), isOn: Binding(
                        get: { backend.state.modes[key] ?? false },
                        set: { backend.setMode(key, on: $0) }
                    ))
                    .toggleStyle(.switch)
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l.t("Все готово", "All set")).font(.title2.weight(.semibold))
            Text(l.t("Проект слева открывает новую сессию через proxy, сессия под проектом продолжается во вкладке. ⌘K ищет вкладки, сессии и действия, ⌘, открывает настройки. Мастер можно открыть снова из меню Help.",
                     "A project on the left opens a new session via the proxy, a session under it resumes in a tab. ⌘K finds tabs, sessions and actions, ⌘, opens Settings. You can reopen this from the Help menu."))
                .foregroundStyle(.secondary)
            card {
                UtilityButton(title: l.t("Проверить установку (setup)", "Check the install (setup)"), args: ["setup"])
                Text(l.t("Команды, хуки, MCP-сервер и promptsill. Если что-то не так, это есть и в Настройки → Диагностика.",
                         "Commands, hooks, the MCP server and promptsill. Settings → Diagnostics shows the same."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
