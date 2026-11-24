import AppKit
import SwiftUI

/// Раскладка главного окна по макету: три стеклянные карточки с зазором 8. Слева проекты (сворачиваются в рельсу),
/// посередине шапка, вкладки и терминал, справа панель сессии (прячется). Ширины тянутся мышью и запоминаются.
/// В узком окне сначала прячется панель сессии, потом проекты сворачиваются в рельсу.
struct CardsLayout<Main: View>: View {
    @EnvironmentObject var ui: UIState
    @AppStorage("layout.sidebarWidth") private var sidebarWidth = 250.0
    @AppStorage("layout.inspectorWidth") private var inspectorWidth = 290.0
    @ViewBuilder var main: () -> Main

    static var gap: CGFloat { 8 }
    static var railWidth: CGFloat { 80 }
    static var mainMin: CGFloat { 560 }

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.width - Self.gap * 2
            // сколько помещается: сначала уходит панель сессии, потом проекты в рельсу
            let wantInspector = ui.showInspector
            let wantSidebar = !ui.sidebarCollapsed
            let fitsAll = full >= sidebarWidth + Self.mainMin + inspectorWidth + Self.gap * 2
            let fitsSidebar = full >= sidebarWidth + Self.mainMin + Self.gap
            let showInspector = wantInspector && (fitsAll || (!wantSidebar && full >= Self.railWidth + Self.mainMin + inspectorWidth + Self.gap * 2))
            let showSidebar = wantSidebar && (showInspector ? fitsAll : fitsSidebar)
            HStack(spacing: 0) {
                Group {
                    if showSidebar {
                        Sidebar()
                            .frame(width: sidebarWidth)
                    } else {
                        SidebarRail()
                            .frame(width: Self.railWidth)
                    }
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                if showSidebar {
                    ResizeHandle(width: $sidebarWidth, range: 200...380, sign: 1)
                } else {
                    Color.clear.frame(width: Self.gap)
                }
                main()
                    .frame(minWidth: Self.mainMin, maxWidth: .infinity, maxHeight: .infinity)
                if showInspector {
                    ResizeHandle(width: $inspectorWidth, range: 240...400, sign: -1)
                    InspectorView()
                        .frame(width: inspectorWidth)
                        .frame(maxHeight: .infinity)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(Self.gap)
            .animation(.snappy(duration: 0.25), value: showSidebar)
            .animation(.snappy(duration: 0.25), value: showInspector)
        }
    }
}

/// Невидимая полоса 8 точек между карточками: тянется мышью и меняет ширину соседней карточки.
struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// 1 для карточки слева от полосы, -1 для карточки справа.
    let sign: Double
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: CardsLayout<EmptyView>.gap)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = start ?? width
                        if start == nil { start = width }
                        width = min(max(base + sign * value.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
    }
}

/// Шапка средней карточки, как в макете: название и подзаголовок, поиск, proxy, новая сессия и панель сессии.
/// За пустое место шапки окно можно таскать.
struct MainHeader: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState

    var l: L { L(backend.state.lang) }

    private var subtitle: String {
        let waiting = workspace.tabs.filter { $0.status == "waiting" }.count
        let count = l.tabs(workspace.tabs.count)
        return waiting > 0 ? count + ", " + l.t("\(waiting) ждет ответа", "\(waiting) waiting for you") : count
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Agentmeister").font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Ink.muted)
            }
            .fixedSize()
            .padding(.horizontal, 6)
            Spacer(minLength: 12)
            SearchCapsule()
            ProxyBadge().fixedSize()
            HStack(spacing: 0) {
                Button {
                    ui.newSessionProject = workspace.current?.spec.projectPath
                    ui.showNewSession = true
                } label: {
                    // в узком окне от кнопки остается только плюс
                    ViewThatFits(in: .horizontal) {
                        Label(l.newSession, systemImage: "plus").labelStyle(.titleAndIcon).fixedSize()
                        Image(systemName: "plus")
                    }
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(Capsule().fill(Color.accentColor))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(l.newSession + ", ⌘N")
                Button {
                    withAnimation(.snappy(duration: 0.25)) { ui.showInspector.toggle() }
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(Ink.text2)
                        .frame(width: 34, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l.t("Показать или скрыть панель сессии", "Show or hide the session panel") + ", ⌥⌘I")
                .accessibilityLabel(l.t("Показать или скрыть панель сессии", "Show or hide the session panel"))
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
        }
        .frame(height: 40)
        .padding(.top, 2)
        .background(WindowDragArea())
    }
}

/// Пустое место, за которое тянется окно без заголовка.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Кнопка свернуть или развернуть проекты, у светофора.
struct SidebarToggle: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var ui: UIState
    var l: L { L(backend.state.lang) }

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { ui.sidebarCollapsed.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .foregroundStyle(Ink.text2)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(l.t("Свернуть или развернуть проекты", "Collapse or expand projects") + ", ⌃⌘S")
        .accessibilityLabel(l.t("Свернуть или развернуть проекты", "Collapse or expand projects"))
    }
}

/// Проекты, свернутые в рельсу: буквы проектов с точкой статуса. Сначала проекты с открытыми сессиями,
/// ждущая сессия видна янтарной точкой. Клик открывает экран проекта, правый клик дает новую сессию.
struct SidebarRail: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState

    var l: L { L(backend.state.lang) }

    /// Две буквы проекта: "Ag" для agentmeister, "TM" для tossling-mobile. Одна буква не различает проекты.
    private func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." || $0 == " " })
        if parts.count >= 2, let a = parts[0].first, let b = parts[1].first { return (String(a) + String(b)).uppercased() }
        return String(name.prefix(2)).capitalized
    }

    private func state(_ p: AppState.Project) -> (count: Int, waiting: Bool) {
        let tabs = workspace.tabs.filter { $0.spec.projectPath == p.path && $0.running }
        let live = backend.state.live.filter { ($0.cwd ?? "") == p.path || ($0.cwd ?? "").hasPrefix(p.path + "/") }
        return (max(tabs.count, live.count), tabs.contains { $0.status == "waiting" } || live.contains { $0.status == "waiting" })
    }

    var body: some View {
        let projects = backend.state.projects
        let active = projects.filter { state($0).count > 0 }
        let rest = projects.filter { state($0).count == 0 }
        VStack(spacing: 8) {
            Color.clear.frame(height: 22)
            SidebarToggle()
            Divider().padding(.horizontal, 14)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(active + rest) { project in
                        let s = state(project)
                        Button {
                            ui.projectScreen = project.path
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Text(initials(project.name))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(ui.projectScreen == project.path || workspace.current?.spec.projectPath == project.path ? Ink.strong : Ink.text2)
                                    .frame(width: 40, height: 36)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(
                                        ui.projectScreen == project.path || workspace.current?.spec.projectPath == project.path ? Ink.thumb : Ink.chip))
                                if s.count > 0 {
                                    GlowDot(color: s.waiting ? Ink.amberDot : Ink.tealDot, size: 8)
                                        .padding(3)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help(project.name + (s.count > 0 ? " · " + l.t("открыто \(s.count)", "\(s.count) open") : ""))
                        .contextMenu {
                            Button(l.t("Новая сессия через proxy", "New session via proxy")) {
                                workspace.open(LaunchSpec(projectName: project.name, projectPath: project.path))
                            }
                            Button(l.t("Обзор проекта", "Project overview")) { ui.projectScreen = project.path }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            if let h = backend.state.hostRun {
                GlowDot(color: h.running ? Ink.tealDot : Ink.amberDot)
                    .help(h.running ? l.t("host-run работает", "host-run running") : l.t("host-run не запущен", "host-run isn't running"))
                    .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity)
    }
}
