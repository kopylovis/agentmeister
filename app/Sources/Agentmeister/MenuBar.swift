import AppKit
import SwiftUI

/// Значок Agentmeister в строке меню и его панель: открытые сессии, proxy, host-run и быстрые действия.
/// Показ включается в Настройках > Основные, по умолчанию включен.
enum MenuBarPrefs {
    static let showKey = "menuBar.show"
}

/// Сводное состояние сессий для значка: ждущая важнее работающей, работающая важнее простоя.
enum MenuBarStatus {
    case idle, busy, waiting

    @MainActor
    static func of(_ workspace: Workspace, _ state: AppState) -> MenuBarStatus {
        let (tabs, others) = workspace.openSessions(state)
        // реестр Claude Code знает и наши вкладки, поэтому статусы берутся и из него: вкладка узнает свой статус
        // только после sync, а значок перерисовывается по новому состоянию сразу
        let statuses = tabs.map(\.status) + others.map(\.status) + state.live.map(\.status)
        if statuses.contains("waiting") { return .waiting }
        if statuses.contains("busy") { return .busy }
        return .idle
    }

    /// Шаблонный SF Symbol: пузырь в простое, пузырь с многоточием, пока агент пишет, залитый с восклицательным
    /// знаком, когда агент ждет ответа.
    var symbol: String {
        switch self {
        case .idle: return "bubble.left"
        case .busy: return "ellipsis.bubble"
        case .waiting: return "exclamationmark.bubble.fill"
        }
    }
}

/// Значок в строке меню. Свой вид с наблюдаемыми объектами: метка MenuBarExtra иначе не узнает о смене статуса.
struct MenuBarLabel: View {
    @ObservedObject var backend: Backend
    @ObservedObject var workspace: Workspace

    var body: some View {
        let status = MenuBarStatus.of(workspace, backend.state)
        let l = L(backend.state.lang)
        Image(systemName: status.symbol)
            .accessibilityLabel("Agentmeister, " + (status == .waiting ? l.waiting : status == .busy ? l.working : l.idle))
    }
}

/// Панель значка: шириной 300, сессии сверху (ждущие первыми), под ними proxy, host-run и кнопки.
struct MenuBarPanel: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var l: L { L(backend.state.lang) }

    /// Строка списка: вкладка этого окна или сессия из реестра, открытая в другом окне.
    private struct Entry: Identifiable {
        let id: String
        let tab: TerminalTab?
        let live: AppState.Live?
        let status: String?
    }

    private static func rank(_ status: String?) -> Int {
        switch status {
        case "waiting": return 0
        case "busy": return 1
        default: return 2
        }
    }

    private var entries: [Entry] {
        let (tabs, others) = workspace.openSessions(backend.state)
        let list = tabs.map { Entry(id: "tab-" + $0.id.uuidString, tab: $0, live: nil, status: $0.status) }
            + others.enumerated().map { index, live in
                Entry(id: "live-" + (live.sessionId ?? "\(live.pid ?? 0)-\(index)"), tab: nil, live: live, status: live.status)
            }
        // сортировка устойчивая: внутри одного статуса порядок вкладок как в окне
        return list.enumerated().sorted { a, b in
            (Self.rank(a.element.status), a.offset) < (Self.rank(b.element.status), b.offset)
        }.map(\.element)
    }

    var body: some View {
        let items = entries
        let waiting = items.filter { $0.status == "waiting" }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Agentmeister").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text)
                Spacer()
                if !items.isEmpty {
                    Text(l.t("открыто \(items.count)", "\(items.count) open")
                         + (waiting > 0 ? l.t(waiting == 1 ? ", ждет 1" : ", ждут \(waiting)", ", \(waiting) waiting") : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(waiting > 0 ? Ink.amber : Ink.faint)
                }
            }
            .padding(.horizontal, 4)

            sessions(items)

            VStack(spacing: 2) {
                proxyRow
                hostRunRow
            }

            actions
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: Сессии

    @ViewBuilder
    private func sessions(_ items: [Entry]) -> some View {
        if items.isEmpty {
            Text(l.noTabs)
                .font(.system(size: 12))
                .foregroundStyle(Ink.muted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
        } else {
            let list = VStack(spacing: 2) {
                ForEach(items) { entry in
                    if let tab = entry.tab {
                        MenuBarTabRow(tab: tab) { focus(tab) }
                    } else if let live = entry.live {
                        liveRow(live)
                    }
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
            if items.count > 7 {
                ScrollView { list }.frame(height: 7 * 42 + 8)
            } else {
                list
            }
        }
    }

    /// Сессия в iTerm2, Terminal или другом окне: вкладки у нее здесь нет, клик открывает экран ее проекта.
    private func liveRow(_ live: AppState.Live) -> some View {
        let project = live.cwd.flatMap { backend.state.project(containing: $0) }
        let saved = live.sessionId.flatMap { sid in backend.state.sessions.first { $0.id == sid } }
        let title = saved?.title.isEmpty == false ? saved!.title : (live.name?.isEmpty == false ? live.name! : l.untitled)
        return MenuBarRow(status: live.status, agent: .claude, title: title,
                          detail: [project?.name ?? live.cwd.map(tilde), l.statusTitle(live.status)].compactMap { $0 }.joined(separator: " · "),
                          elsewhere: true,
                          help: l.t("Открыта в другом окне", "Open in another window")) {
            showMain()
            if let project { ui.projectScreen = project.path }
        }
    }

    private func focus(_ tab: TerminalTab) {
        workspace.selected = tab.id
        tab.rang = false
        ui.projectScreen = nil
        showMain()
    }

    // MARK: Proxy и host-run

    private var proxyRow: some View {
        let p = backend.state.proxy
        let running = p?.running == true
        let route = [p?.exit, p?.protocol].compactMap { $0 }.joined(separator: " · ")
        let title = p?.configured != true ? l.proxyOff : route.isEmpty ? "proxy" : route
        let state = p?.configured != true ? l.t("настроить", "set up")
            : running ? l.t("работает", "running") : l.t("ждет сессию", "idle")
        return MenuBarLine(dot: running ? Ink.tealDot : p?.configured == true ? Ink.amberDot : Ink.dotOff, glow: p?.configured == true,
                           icon: "shield", title: title, trailing: state, tint: running ? Ink.teal : Ink.muted,
                           help: [p?.node, p?.ip].compactMap { $0 }.joined(separator: " · ")) {
            openSettingsPane("proxy")
        }
    }

    @ViewBuilder
    private var hostRunRow: some View {
        if let h = backend.state.hostRun {
            MenuBarLine(dot: h.running ? Ink.tealDot : Ink.amberDot, icon: "terminal",
                        title: h.running ? l.t("host-run работает", "host-run running") : l.t("host-run не запущен", "host-run isn't running"),
                        trailing: h.running ? l.commands(h.commands) : "", tint: Ink.muted, help: h.log ?? "") {
                openSettingsPane("proxy")
            }
        }
    }

    // MARK: Кнопки

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                PillButton(title: l.newSession, prominent: true, small: true) {
                    showMain()
                    ui.newSessionProject = workspace.current?.spec.projectPath
                    ui.showNewSession = true
                }
                .frame(maxWidth: .infinity)
                PillButton(title: l.t("Показать окно", "Show Agentmeister"), small: true) { showMain() }
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 8) {
                PillButton(title: l.t("Настройки", "Settings"), small: true) { openSettingsPane(nil) }
                    .frame(maxWidth: .infinity)
                PillButton(title: l.t("Выйти", "Quit"), small: true) {
                    dismiss()
                    NSApp.terminate(nil)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Главное окно вперед. openWindow на случай, если окно закрыли, а приложение живет ради Настроек.
    private func showMain() {
        dismiss()
        openWindow(id: "main")
        Workspace.bringMainWindowForward()
    }

    private func openSettingsPane(_ section: String?) {
        dismiss()
        if let section { UserDefaults.standard.set(section, forKey: "settingsSection") }
        openSettings()
        NSApp.activate()
    }
}

/// Строка вкладки: следит за самой вкладкой, чтобы статус и заголовок менялись на ходу.
private struct MenuBarTabRow: View {
    @EnvironmentObject var backend: Backend
    @ObservedObject var tab: TerminalTab
    let action: () -> Void

    var body: some View {
        let l = L(backend.state.lang)
        let saved = backend.state.sessions.first { $0.id == tab.sessionId }
        MenuBarRow(status: tab.status, agent: tab.spec.agent,
                   title: saved?.title.isEmpty == false ? saved!.title : tab.title,
                   detail: tab.spec.projectName + " · " + (tab.spec.agent == .codex && tab.status == nil ? l.t("открыта", "open") : l.statusTitle(tab.status)),
                   elsewhere: false, help: "", action: action)
    }
}

/// Строка сессии: точка статуса, значок агента, заголовок и "проект · статус". Подсветка под курсором.
private struct MenuBarRow: View {
    let status: String?
    let agent: LaunchSpec.Agent
    let title: String
    let detail: String
    let elsewhere: Bool
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SessionDot(status: status, size: 7)
                AgentBadge(agent: agent, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(status == "waiting" ? Ink.amber : Ink.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if elsewhere {
                    Image(systemName: "macwindow.on.rectangle").font(.system(size: 10)).foregroundStyle(Ink.faint)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Ink.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityElement(children: .combine)
    }
}

/// Строка состояния под списком: точка, значок, текст и справа короткое состояние. Клик ведет в настройки.
private struct MenuBarLine: View {
    let dot: Color
    var glow = true
    let icon: String
    let title: String
    let trailing: String
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                GlowDot(color: dot, glow: glow, size: 6)
                Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(tint).lineLimit(1)
                Spacer(minLength: 4)
                Text(trailing).font(.system(size: 11)).foregroundStyle(Ink.faint).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.faint)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Ink.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}
