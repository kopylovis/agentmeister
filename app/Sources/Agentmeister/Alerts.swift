import AppKit
import SwiftUI

/// Баннер над терминалом вкладки, как в макете Errors.dc.html: цветная плашка, круглый значок, заголовок,
/// пояснение и кнопки. Показывает первое, что сейчас мешает вкладке.
struct TabAlert: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @ObservedObject var tab: TerminalTab
    @State private var dismissed: Set<String> = []
    @State private var busy = false

    var l: L { L(backend.state.lang) }

    enum Tone { case red, amber, teal }

    struct Item {
        let id: String
        let tone: Tone
        let icon: String
        let title: String
        let body: String
        let primary: (String, () -> Void)?
        let secondary: (String, () -> Void)?
    }

    private var agentName: String { tab.spec.agent == .codex ? "Codex" : "Claude Code" }

    private var item: Item? {
        let proxy = backend.state.proxy
        var items: [Item] = []
        if !tab.running, let code = tab.exitCode, code != 0, tab.spec.utility == nil {
            items.append(Item(id: "exit-\(code)-\(tab.startedAt.timeIntervalSince1970)", tone: .red, icon: "exclamationmark.triangle",
                              title: l.t("\(agentName) завершился с кодом \(code)", "\(agentName) exited with code \(code)"),
                              body: tab.spec.agent == .codex
                                  ? l.t("Перезапуск откроет новую сессию Codex с тем же маршрутом.", "Restart opens a new Codex session with the same route.")
                                  : l.t("Переписка сохранена. Перезапуск откроет ту же сессию с тем же маршрутом.",
                                        "The conversation is saved. Restart opens the same session with the same route."),
                              primary: (l.restart, { tab.restart() }),
                              secondary: tab.sessionId != nil && tab.spec.agent == .claude
                                  ? (l.t("Сжать и перезапустить", "Slim and restart"), { tab.slim(note: l.slimming) }) : nil))
        }
        if tab.running, tab.spec.proxied, proxy?.configured == true, proxy?.running == false {
            items.append(Item(id: "mihomo", tone: .red, icon: "exclamationmark.triangle",
                              title: l.t("mihomo не отвечает, сессия без сети", "mihomo is not responding, the session has no network"),
                              body: l.t("Песочница не пустит агента в сеть мимо proxy. Агент ждет, его ход не потерян.",
                                        "The sandbox keeps the agent off the network without the proxy. The agent is waiting, its turn is not lost."),
                              primary: (l.t("Перезапустить mihomo", "Restart mihomo"), { perform(["proxy", "restart"]) }),
                              secondary: tab.spec.utility == nil ? (l.t("Продолжить напрямую", "Continue without proxy"), { tab.switchRoute() }) : nil))
        }
        if let failed = tab.updateFailed {
            items.append(Item(id: "update-\(failed.at.timeIntervalSince1970)", tone: .red, icon: "exclamationmark.triangle",
                              title: l.t("claude update не прошел", "claude update failed"),
                              body: failed.version.map { v in
                                  l.t("Новая версия не скачалась. Сессия открыта на \(v), работать можно.",
                                      "The new version didn't download. The session is open on \(v) and usable.")
                              } ?? l.t("Новая версия не скачалась. Сессия открыта, работать можно.",
                                       "The new version didn't download. The session is open and usable."),
                              primary: (l.t("Повторить", "Retry"), {
                                  tab.updateFailed = nil
                                  tab.restartPreferred(note: l.updating)
                              }),
                              secondary: (l.t("Журнал", "Log"), { showUpdateLog(failed) })))
        }
        if tab.spec.agent == .codex, tab.spec.utility == nil, backend.state.signedIn?["codex"] == false {
            items.append(Item(id: "codex-signin", tone: .amber, icon: "key",
                              title: l.t("Codex просит войти снова", "Codex wants you to sign in again"),
                              body: l.t("Вход в ChatGPT истек. Вход откроется через тот же proxy, сессия продолжится после него.",
                                        "The ChatGPT sign-in expired. Sign-in opens through the same proxy, the session continues afterwards."),
                              primary: (l.t("Войти", "Sign in"), { utility(["proxy", "run", "--claude", "--", "codex", "login"]) }),
                              secondary: nil))
        }
        if tab.spec.proxied, tab.spec.utility == nil, let h = backend.state.hostRun, !h.running {
            items.append(Item(id: "hostrun", tone: .amber, icon: "stop.circle",
                              title: l.t("Исполнитель host-run не запущен", "The host-run runner is not running"),
                              body: l.t("Команды вне песочницы не пройдут, пока он не запущен.", "Commands outside the sandbox will fail until it runs."),
                              primary: (l.t("Запустить", "Start"), { startHostRun() }),
                              secondary: h.log.map { log in (l.t("Журнал", "Log"), { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }) }))
        }
        if tab.spec.proxied, let change = backend.exitChange {
            items.append(Item(id: "exit-\(change.from)-\(change.to)", tone: .teal, icon: "info.circle",
                              title: l.t("Выход сменился с \(change.from) на \(change.to)", "Exit switched from \(change.from) to \(change.to)"),
                              body: l.t("Сервер \(change.from) перестал отвечать, mihomo переключился на следующий из подписки. Сессии работают дальше.",
                                        "The \(change.from) server stopped answering, mihomo moved to the next one in the subscription. Sessions keep working."),
                              primary: (l.t("Подробнее", "Details"), { utility(["proxy"]) }),
                              secondary: (l.t("Скрыть", "Dismiss"), { backend.exitChange = nil })))
        }
        return items.first { !dismissed.contains($0.id) }
    }

    var body: some View {
        if let item {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color(item.tone))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(color(item.tone).opacity(0.2)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).fontWeight(.semibold).foregroundStyle(color(item.tone))
                    Text(item.body).font(.system(size: 12)).foregroundStyle(Ink.text2).lineLimit(3)
                    HStack(spacing: 6) {
                        if let primary = item.primary {
                            Button(primary.0, action: primary.1).buttonStyle(.glassProminent).controlSize(.small).disabled(busy)
                        }
                        if let secondary = item.secondary {
                            Button(secondary.0, action: secondary.1).buttonStyle(.glass).controlSize(.small)
                        }
                    }
                    .padding(.top, 6)
                }
                Spacer(minLength: 0)
                Button {
                    dismissed.insert(item.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.muted)
                }
                .buttonStyle(.plain)
                .help(l.t("Скрыть", "Dismiss"))
                .accessibilityLabel(l.t("Скрыть", "Dismiss"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(color(item.tone).opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(color(item.tone).opacity(0.35)))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isStaticText)
        }
    }

    private func color(_ tone: Tone) -> Color {
        switch tone {
        case .red: return Ink.red
        case .amber: return Ink.amber
        case .teal: return Ink.teal
        }
    }

    private func perform(_ args: [String]) {
        busy = true
        Task {
            _ = await backend.perform(args)
            busy = false
        }
    }

    private func utility(_ args: [String]) {
        var spec = LaunchSpec(projectName: "agentmeister", projectPath: NSHomeDirectory())
        spec.utility = args
        workspace.open(spec)
    }

    /// Вывод claude update в окне с прокруткой: в баннер он не влезает, а причина обычно в нем.
    private func showUpdateLog(_ failed: TerminalTab.UpdateFailure) {
        let alert = NSAlert()
        alert.messageText = l.t("claude update, код \(failed.code)", "claude update, exit code \(failed.code)")
        alert.informativeText = failed.log.isEmpty ? l.t("Команда ничего не вывела.", "The command printed nothing.") : ""
        if !failed.log.isEmpty {
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 480, height: 220)
            scroll.hasVerticalScroller = true
            if let text = scroll.documentView as? NSTextView {
                text.string = failed.log
                text.isEditable = false
                text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            }
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: l.t("Скопировать", "Copy"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(failed.log, forType: .string)
        }
    }

    /// Исполнитель host-run в фоне, как (agentmeister host-run serve &) в обычном терминале.
    private func startHostRun() {
        busy = true
        let task = Process()
        task.executableURL = URL(fileURLWithPath: LoginEnvironment.agentmeister)
        task.arguments = ["host-run", "serve"]
        task.environment = LoginEnvironment.shared
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        Task {
            try? await Task.sleep(for: .seconds(2))
            backend.refresh()
            busy = false
        }
    }
}
