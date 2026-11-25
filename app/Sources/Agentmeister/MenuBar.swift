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

    /// Значок для строки меню, готовый для каждого статуса.
    var image: NSImage {
        switch self {
        case .idle: return MenuBarGlyph.idle
        case .busy: return MenuBarGlyph.busy
        case .waiting: return MenuBarGlyph.waiting
        }
    }
}

/// Глиф иконки приложения (буква "a" со стрелкой терминала) шаблоном для строки меню. Контур снят с
/// share/agentmeister/icon.png (1024 px, глиф в рамке 225...795 по x и 243...758 по y). В свободном срезанном
/// углу справа сверху точка статуса, кольцо, пока агент пишет, и залитая, когда агент ждет ответа.
enum MenuBarGlyph {
    static let idle = make(.idle)
    static let busy = make(.busy)
    static let waiting = make(.waiting)
    /// Кадры спиннера, пока агент пишет: дуга в 270 градусов поворачивается на 30 градусов за кадр.
    static let spinner = (0..<12).map { make(.busy, spin: CGFloat($0) * 30) }

    private static let outline: [CGPoint] = [
        (360, 243), (638, 243), (752, 378), (752, 683), (795, 683), (795, 757), (585, 757), (585, 712), (532, 758),
        (225, 758), (225, 547), (330, 445), (575, 445), (575, 390), (236, 390),
    ].map { CGPoint(x: $0.0, y: $0.1) }
    private static let chevron: [CGPoint] = [
        (371, 500), (434, 500), (518, 585), (434, 673), (371, 673), (450, 585),
    ].map { CGPoint(x: $0.0, y: $0.1) }

    private static func make(_ status: MenuBarStatus, spin: CGFloat? = nil) -> NSImage {
        // поля по бокам шире, чем у стандартных значков: глиф 15 pt в ширину внутри 24 pt
        let size = NSSize(width: 24, height: 18)
        let scale: CGFloat = 14 / 515
        let origin = CGPoint(x: (size.width - 570 * scale) / 2, y: (size.height - 515 * scale) / 2)
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + (p.x - 225) * scale, y: origin.y + (p.y - 243) * scale)
        }
        let image = NSImage(size: size, flipped: true) { _ in
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            for shape in [outline, chevron] {
                path.move(to: point(shape[0]))
                shape.dropFirst().forEach { path.line(to: point($0)) }
                path.close()
            }
            // контур внутрь фигуры: обводка двойной толщины, обрезанная по самому глифу. Снаружи глиф того же
            // размера, узкая прорезь под крышей не зарастает, а у стрелки внутри тоже остается только контур.
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            path.lineWidth = 1.7
            path.lineJoinStyle = .miter
            NSColor.black.setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
            if status != .idle, let context = NSGraphicsContext.current {
                // правый верхний угол рамки, над срезом глифа: зазор вокруг точки глиф почти не задевает
                let center = CGPoint(x: size.width - 2.8, y: 2.9)
                let radius: CGFloat = 2.5, gap: CGFloat = 1
                context.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: center.x - radius - gap, y: center.y - radius - gap,
                                            width: (radius + gap) * 2, height: (radius + gap) * 2)).fill()
                context.compositingOperation = .sourceOver
                let dot = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                if status == .waiting {
                    NSBezierPath(ovalIn: dot).fill()
                } else if let spin {
                    // flipped: углы идут по часовой стрелке, поворот кадра тоже по часовой
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: center, radius: radius - 0.6, startAngle: spin, endAngle: spin + 270)
                    arc.lineWidth = 1.3
                    arc.lineCapStyle = .round
                    NSColor.black.setStroke()
                    arc.stroke()
                } else {
                    let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6))
                    ring.lineWidth = 1.2
                    NSColor.black.setStroke()
                    ring.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Значок в строке меню. Свой вид с наблюдаемыми объектами: метка MenuBarExtra иначе не узнает о смене статуса.
struct MenuBarLabel: View {
    @ObservedObject var backend: Backend
    @ObservedObject var workspace: Workspace
    /// Кадр спиннера. Таймер меняет его, только пока агент пишет, в простое значок не перерисовывается.
    @State private var frame = 0
    @State private var ticker = Timer.publish(every: 0.125, on: .main, in: .common).autoconnect()

    var body: some View {
        let status = MenuBarStatus.of(workspace, backend.state)
        let l = L(backend.state.lang)
        Image(nsImage: status == .busy ? MenuBarGlyph.spinner[frame % MenuBarGlyph.spinner.count] : status.image)
            .accessibilityLabel("Agentmeister, " + (status == .waiting ? l.waiting : status == .busy ? l.working : l.idle))
            .onReceive(ticker) { _ in
                if status == .busy { frame = (frame + 1) % MenuBarGlyph.spinner.count }
            }
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
                // одна сессия бывает открыта в двух окнах сразу: id из сессии и pid, без pid из номера
                Entry(id: "live-\(live.sessionId ?? "")-" + (live.pid.map { String($0) } ?? "n\(index)"),
                      tab: nil, live: live, status: live.status)
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
                        trailing: h.running ? l.commands(h.commands) : "", tint: h.running ? Ink.teal : Ink.muted,
                        help: h.log ?? "") {
                openSettingsPane("proxy")
            }
        }
    }

    // MARK: Кнопки

    /// Главное действие кнопкой на всю ширину, под линией тихая строка: окно и настройки слева, выход справа.
    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                showMain()
                ui.newSessionProject = workspace.current?.spec.projectPath
                ui.showNewSession = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text(l.newSession).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(Capsule().fill(Color.accentColor).shadow(color: .black.opacity(0.25), radius: 4, y: 2))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            Rectangle().fill(Ink.hairline).frame(height: 1).padding(.horizontal, 4)

            HStack(spacing: 2) {
                MenuBarFooterButton(icon: "macwindow", title: l.t("Окно", "Open window")) { showMain() }
                MenuBarFooterButton(icon: "gearshape", title: l.t("Настройки", "Settings")) { openSettingsPane(nil) }
                Spacer(minLength: 4)
                MenuBarFooterButton(icon: "power", title: l.t("Выйти", "Quit")) {
                    dismiss()
                    // вопрос "закрыть идущие сессии?" должен встать впереди, а не за другим приложением
                    NSApp.activate()
                    NSApp.terminate(nil)
                }
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

/// Тихая кнопка нижней строки панели: значок и подпись, подсветка под курсором.
private struct MenuBarFooterButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(hover ? Ink.text : Ink.muted)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Ink.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
