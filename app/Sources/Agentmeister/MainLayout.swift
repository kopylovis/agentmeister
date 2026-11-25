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
    static var railWidth: CGFloat { 76 }
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
                // обе панели живут все время, переключается только видимость: при пересоздании панели размытие
                // под ее барами пропадало. Прозрачность меняется сразу, анимируется только ширина карточки.
                ZStack(alignment: .topLeading) {
                    Sidebar()
                        .environment(\.sidebarHidden, !showSidebar)
                        .frame(width: sidebarWidth)
                        .opacity(showSidebar ? 1 : 0)
                        .animation(nil, value: showSidebar)
                        .allowsHitTesting(showSidebar)
                        .accessibilityHidden(!showSidebar)
                    SidebarRail()
                        .environment(\.sidebarHidden, showSidebar)
                        .frame(width: Self.railWidth)
                        .opacity(showSidebar ? 0 : 1)
                        .animation(nil, value: showSidebar)
                        .allowsHitTesting(!showSidebar)
                        .accessibilityHidden(showSidebar)
                }
                .frame(width: showSidebar ? sidebarWidth : Self.railWidth, alignment: .topLeading)
                // список прокручивается под шапкой и режимами, но за рамку карточки не выходит
                .clipShape(.windowCard)
                .glassEffect(.regular, in: .windowCard)
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
                        .glassEffect(.regular, in: .windowCard)
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
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: CardsLayout<EmptyView>.gap)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            // полоса пропала под курсором (карточка спряталась): без этого курсор остался бы стрелками
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
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
            SidebarToggle()
                .padding(3)
                .glassEffect(.regular, in: .capsule)
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
                    // на экране проекта новая сессия сразу в этом проекте
                    ui.newSessionProject = ui.projectScreen ?? workspace.current?.spec.projectPath
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
                .buttonStyle(.hoverCapsule(.brighten))
                .shortcutHelp(l.newSession, .newSession)
                Button {
                    withAnimation(.snappy(duration: 0.25)) { ui.showInspector.toggle() }
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(Ink.text2)
                        .frame(width: 34, height: 28)
                        .contentShape(Capsule())
                }
                .buttonStyle(.hoverCapsule())
                .shortcutHelp(l.t("Показать или скрыть панель сессии", "Show or hide the session panel"), .inspector)
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
        override func mouseDown(with event: NSEvent) {
            // двойной щелчок как по заголовку обычного окна: развернуть или вернуть (zoom), либо свернуть в Dock,
            // если так выбрано в Системных настройках
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                switch action {
                case "Minimize": window?.miniaturize(nil)
                case "None": break
                default: window?.zoom(nil)
                }
                return
            }
            window?.performDrag(with: event)
        }
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
                .frame(width: 34, height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.hoverCapsule())
        .shortcutHelp(l.t("Свернуть или развернуть проекты", "Collapse or expand projects"), .sidebar)
        .accessibilityLabel(l.t("Свернуть или развернуть проекты", "Collapse or expand projects"))
    }
}

/// Проекты, свернутые в рельсу: только проекты с открытыми сессиями, цветной кружок с буквами и точка статуса,
/// янтарная, если сессия ждет. Остальные проекты в меню под папкой. Клик открывает экран проекта.
struct SidebarRail: View {
    @ObservedObject private var icons = ProjectIcons.shared
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState

    var l: L { L(backend.state.lang) }

    /// Сколько сессий проекта открыто и в каком они состоянии: ждущая важнее работающей, работающая важнее простоя.
    private func state(_ p: AppState.Project) -> (count: Int, status: String?) {
        let (tabs, others) = workspace.openSessions(in: p, state: backend.state)
        let statuses = tabs.map(\.status) + others.map(\.status)
        let status = statuses.contains("waiting") ? "waiting" : statuses.contains("busy") ? "busy" : nil
        return (tabs.count + others.count, status)
    }

    /// Две буквы проекта: "Ag" для agentmeister, "TM" для tossling-mobile.
    private func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." || $0 == " " })
        if parts.count >= 2, let a = parts[0].first, let b = parts[1].first { return (String(a) + String(b)).uppercased() }
        return String(name.prefix(2)).capitalized
    }

    /// Свой постоянный оттенок у каждого проекта, по имени.
    private func hue(_ name: String) -> Double {
        Double(name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 360) / 360
    }

    var body: some View {
        // проекты прокручиваются во всю высоту рельсы, под место светофора и под закрепленный внизу host-run
        ScrollView {
                VStack(spacing: 8) {
                    ForEach(backend.state.projects) { project in
                        let s = state(project)
                        // выделен один проект: открытый экран проекта, а без него проект текущей вкладки
                        let current = ui.projectScreen.map { $0 == project.path } ?? (workspace.current?.spec.projectPath == project.path)
                        Button {
                            if ui.projectScreen == project.path {
                                // повторный клик закрывает экран проекта и возвращает к вкладке
                                ui.projectScreen = nil
                            } else if let tab = workspace.tabs.first(where: { $0.spec.projectPath == project.path }) {
                                workspace.selected = tab.id
                                ui.projectScreen = nil
                            } else {
                                ui.projectScreen = project.path
                            }
                        } label: {
                            Group {
                                if let image = icons.icon(for: project.path) {
                                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                                        .frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                } else {
                                    Text(initials(project.name))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 32, height: 32)
                                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color(hue: hue(project.name), saturation: 0.45, brightness: 0.62)))
                                }
                            }
                            .frame(width: 46, height: 44)
                            // выбранный проект на мягкой подложке, как выбранная строка в развернутом списке,
                            // под курсором легкая подсветка
                            .modifier(HoverFill(selected: current, radius: 12))
                            .overlay(alignment: .bottomTrailing) {
                                if s.count > 0 {
                                    SessionDot(status: s.status, size: 9)
                                        .padding(2)
                                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                                        .offset(x: -1, y: -1)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(project.name + (s.count == 0 ? "" : " · " + (s.status == "waiting" ? l.t("ждет ответа", "waiting for you")
                              : s.status == "busy" ? l.t("работает", "working") : l.t("открыто \(s.count)", "\(s.count) open"))))
                        .contextMenu {
                            Button(l.newSession) {
                                workspace.open(LaunchSpec.quick(project))
                            }
                            Button(l.t("Обзор проекта", "Project overview")) { ui.projectScreen = project.path }
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .safeAreaBar(edge: .top, spacing: 0) {
                // место светофора: ровное размытие и линия на всю ширину рельсы, как у host-run снизу
                Color.clear.frame(height: 40).frame(maxWidth: .infinity).background(WindowDragArea())
                    .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }
                    .blurBar(edge: .top, fade: false)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
            if let h = backend.state.hostRun {
                // исполнитель host-run: значок терминала и точка состояния, клик открывает его настройки
                SettingsLink {
                    Image(systemName: "terminal")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.text2)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.chip))
                        .overlay(alignment: .bottomTrailing) {
                            Circle().fill(h.running ? SessionDot.idle : Ink.amberDot)
                                .frame(width: 8, height: 8)
                                .padding(2)
                                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                                .offset(x: 2, y: 2)
                        }
                }
                .buttonStyle(.hover(8, .overlay))
                .simultaneousGesture(TapGesture().onEnded { UserDefaults.standard.set("proxy", forKey: "settingsSection") })
                .help(h.running ? l.t("host-run работает · ", "host-run running · ") + l.commands(h.commands)
                                : l.t("host-run не запущен", "host-run isn't running"))
                .accessibilityLabel(h.running ? l.t("host-run работает", "host-run running") : l.t("host-run не запущен", "host-run isn't running"))
                // закрепленный значок без своей подложки, от списка его отделяет линия
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .overlay(alignment: .top) {
                    Rectangle().fill(Ink.hairline).frame(height: 1)
                }
                .blurBar(edge: .bottom, fade: false)
            }
            }
        .frame(maxHeight: .infinity)
    }
}

/// Сдвигает светофор окна внутрь карточки проектов, чтобы кнопки не касались ее скругленной рамки.
/// AppKit возвращает кнопки на место при каждой раскладке заголовка, поэтому сдвиг повторяется.
struct TrafficLightsInset: NSViewRepresentable {
    var dx: CGFloat = 14
    var dy: CGFloat = 9

    final class Probe: NSView {
        var dx: CGFloat = 0, dy: CGFloat = 0
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            DispatchQueue.main.async { self.place() }
        }

        func place() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (i, kind) in kinds.enumerated() {
                guard let button = window.standardWindowButton(kind), let bar = button.superview else { continue }
                let x = 7 + CGFloat(i) * 20 + dx
                let y = (bar.bounds.height - button.frame.height) / 2 - dy
                button.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.dx = dx
        v.dy = dy
        return v
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        DispatchQueue.main.async { nsView.place() }
    }
}
