import AppKit
import SwiftTerm
import SwiftUI

/// В SwiftTerm тоже есть тип Color, а в интерфейсе нужен цвет SwiftUI
typealias Color = SwiftUI.Color

/// Что открыто в окне помимо вкладок: лист новой сессии и панель сессии. Меню приложения тоже меняет это.
@MainActor
final class UIState: ObservableObject {
    @Published var showNewSession = false
    @Published var showPalette = false
    @Published var showOnboarding = false
    /// С какого шага открыть мастер первого запуска (agentmeister://onboarding?step=N, перезапуск ради разрешений).
    @Published var onboardingStep = 0
    @Published var showInspector = UserDefaults.standard.object(forKey: "layout.showInspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "layout.showInspector") }
    }
    /// Проекты свернуты в рельсу.
    @Published var sidebarCollapsed = UserDefaults.standard.bool(forKey: "layout.sidebarCollapsed") {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: "layout.sidebarCollapsed") }
    }
    @Published var newSessionProject: String?
    /// Лист новой сессии открыть сразу на "параллельно, своя ветка и worktree".
    @Published var newSessionParallel = false
    /// Путь проекта, чей экран открыт вместо терминала. Nil, когда видны вкладки.
    @Published var projectScreen: String?
    /// Главное окно сейчас впереди. Команды вкладок (⌘W, ⌘R) работают только тогда.
    @Published var mainKey = true
    /// Вкладка, сессию которой просят забыть. Пока не nil, окно спрашивает подтверждение.
    @Published var forgetting: TerminalTab?
    /// Вкладка, сессию которой переименовывают.
    @Published var renaming: TerminalTab?
    /// Вкладка, которую просят перезапустить без proxy. Пока не nil, окно перечисляет риски и ждет подтверждения.
    @Published var confirmingDirect: TerminalTab?
    /// Агент, в которого входят через диалог входа из баннера вкладки. Лист висит на окне, а не на баннере:
    /// баннер пропадает, как только вход прошел, а диалог должен показать "Вход выполнен".
    @Published var signingIn: LaunchSpec.Agent?
}

func tilde(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}


// MARK: - Окно

struct MainView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState

    var l: L { L(backend.state.lang) }

    var body: some View {
        CardsLayout {
            VStack(spacing: 10) {
                MainHeader()
                DetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 4)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
        .background(TrafficLightsInset())
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            ui.mainKey = (note.object as? NSWindow)?.identifier?.rawValue.hasPrefix("main") == true
        }
        .onChange(of: backend.state.lang) { UserDefaults.standard.set(backend.state.lang, forKey: "lastLang") }
        .sheet(isPresented: $ui.showNewSession) {
            NewSessionSheet(initialProject: ui.newSessionProject)
        }
        .sheet(isPresented: $ui.showPalette) {
            PaletteView()
        }
        .sheet(isPresented: $ui.showOnboarding) {
            OnboardingView()
        }
        .alert(l.t("Перезапустить без proxy?", "Restart without the proxy?"),
               isPresented: Binding(get: { ui.confirmingDirect != nil }, set: { if !$0 { ui.confirmingDirect = nil } }),
               presenting: ui.confirmingDirect) { tab in
            Button(l.t("Перезапустить без proxy", "Restart without proxy"), role: .destructive) {
                tab.switchRoute()
                ui.confirmingDirect = nil
            }
            Button(l.cancel, role: .cancel) { ui.confirmingDirect = nil }
        } message: { _ in
            Text(l.t("""
                Сессия продолжится вне песочницы, и ее трафик пойдет напрямую с этого Mac, мимо mihomo.

                Anthropic, OpenAI и другие сервисы увидят настоящий IP и страну. Если аккаунт обычно работает \
                из другой страны, внезапная смена может закончиться проверкой или блокировкой.

                Агент и его команды смогут ходить в сеть напрямую, а правила mihomo на них перестанут действовать.

                Запрет на правку списка host-run и настроек proxy тоже снимается.

                Вернуть proxy можно кнопкой "Перезапустить через proxy".
                """, """
                The session continues outside the sandbox, and its traffic goes straight from this Mac, past mihomo.

                Anthropic, OpenAI and other services see your real IP and country. If the account usually works \
                from another country, the sudden change can lead to a check or a block.

                The agent and its commands can reach the network directly, and the mihomo rules stop applying to them.

                The lock on the host-run list and the proxy settings is lifted too.

                Restart via proxy brings the proxy back.
                """))
        }
        .sheet(item: $ui.renaming) { tab in
            RenameSheet(tab: tab)
        }
        .sheet(item: $ui.signingIn, onDismiss: { backend.refresh() }) { agent in
            AuthDialog(agent: agent)
        }
        .confirmationDialog(l.t("Забыть сессию?", "Forget this session?"),
                            isPresented: Binding(get: { ui.forgetting != nil }, set: { if !$0 { ui.forgetting = nil } })) {
            Button(l.forget, role: .destructive) {
                ui.forgetting?.forget(note: l.forgetting)
                ui.forgetting = nil
            }
        } message: {
            Text(l.t("Агент остановится, переписка, история правок и строки в history.jsonl удалятся. Вернуть нельзя. Во вкладке откроется чистая сессия.",
                     "The agent stops, and the transcript, its file history and its lines in history.jsonl are deleted. This can't be undone. A clean session opens in the tab."))
        }
        .sheet(isPresented: Binding(get: { workspace.pendingRestore != nil },
                                    set: { if !$0, workspace.pendingRestore != nil { workspace.finishRestore([]) } })) {
            if let pending = workspace.pendingRestore { RestoreSheet(pending: pending) }
        }
        .alert(l.t("Сессия уже открыта в другом окне", "The session is already open in another window"),
               isPresented: Binding(get: { workspace.notice != nil }, set: { if !$0 { workspace.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(l.t("Она идет в iTerm2, Terminal или другом окне Agentmeister. Второй Claude на той же переписке перемешал бы ответы. Закрой ее там и открой здесь.",
                     "It runs in iTerm2, Terminal or another Agentmeister window. A second Claude on the same transcript would mix up the replies. Close it there and open it here."))
        }
        .onReceive(backend.$state) { state in workspace.sync(with: state.live) }
        .onChange(of: backend.ready) {
            guard backend.ready else { return }
            workspace.restore(live: backend.state.live, projects: backend.state.projects, sessions: backend.state.sessions)
            // клик по уведомлению мог и запустить приложение: запрос ждет в focus.json
            workspace.takeFocusRequest(state: backend.state)
            // мастер один раз, при первом запуске, и снова, если он сам перезапустил приложение ради разрешений
            if !UserDefaults.standard.bool(forKey: "onboardingDone") || UserDefaults.standard.object(forKey: "onboardingResumeStep") != nil {
                ui.showOnboarding = true
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .modifier(ReopenWindows())
        .onOpenURL { url in
            // agentmeister://browse?url=<ссылка> от помощника BROWSER во вкладке через proxy
            if url.host() == "browse" {
                if let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                   let target = URL(string: raw), ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
                    ProxyBrowser.shared.open(target)
                }
                return
            }
            // agentmeister://onboarding?step=N открывает мастер первого запуска на шаге N (с нуля)
            if url.host() == "onboarding" {
                let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "step" }?.value
                ui.onboardingStep = max(0, Int(raw ?? "") ?? 0)
                ui.showOnboarding = true
                Workspace.bringMainWindowForward()
                return
            }
            // agentmeister://focus?tab=<id>&session=<id> из клика по уведомлению
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            guard url.host() == "focus", let tab = query?.first(where: { $0.name == "tab" })?.value else { return }
            if !workspace.restoredTabs || workspace.pendingRestore != nil {
                // приложение только что запустилось по ссылке: вкладок еще нет, запрос заберем из focus.json
                Workspace.bringMainWindowForward()
                return
            }
            workspace.focusFromURL(tab: tab, session: query?.first(where: { $0.name == "session" })?.value, state: backend.state)
        }
        .onChange(of: workspace.selected) {
            workspace.writeFront(active: NSApp.isActive)
            ui.projectScreen = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.writeFront(active: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            workspace.writeFront(active: false)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            workspace.takeFocusRequest(state: backend.state)
            workspace.trackCodexThreads()
        }
    }

}

/// Поле "Поиск ⌘K" в тулбаре. Открывает палитру команд, где ищутся вкладки, сессии и действия.
struct SearchCapsule: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var ui: UIState
    @ObservedObject private var shortcuts = ShortcutStore.shared
    var l: L { L(backend.state.lang) }

    var body: some View {
        Button {
            ui.showPalette = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13))
                Text(shortcuts.label(.palette).isEmpty ? l.t("Поиск", "Search") : l.t("Поиск", "Search") + "   " + shortcuts.label(.palette))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.muted)
            .padding(.horizontal, 14)
            .frame(minWidth: 120, idealWidth: 240, maxWidth: 240, minHeight: 34, maxHeight: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(l.t("Поиск по сессиям", "Search sessions"))
        .shortcutHelp(l.t("Палитра команд", "Command palette"), .palette)
    }
}

/// Значок proxy в тулбаре: бирюзовая стеклянная капсула со страной и протоколом выхода, "KZ · vless".
struct ProxyBadge: View {
    @EnvironmentObject var backend: Backend
    @State private var showDetails = false
    var l: L { L(backend.state.lang) }

    var body: some View {
        let proxy = backend.state.proxy
        let text: String
        let live: Bool
        if proxy == nil && backend.lastError != nil {
            text = l.t("нет данных", "no data")
            live = false
        } else if proxy?.configured != true {
            text = l.proxyOff
            live = false
        } else if proxy?.running == true {
            text = [proxy?.exit, proxy?.protocol].compactMap { $0 }.joined(separator: " · ")
            live = true
        } else {
            text = l.proxyIdle
            live = false
        }
        return Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "shield").font(.system(size: 12, weight: .medium))
                Text(text.isEmpty ? "proxy" : text).fontWeight(.medium)
            }
            .foregroundStyle(live ? Ink.teal : Ink.muted)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(live ? .regular.tint(Ink.tealDot.opacity(0.22)).interactive() : .regular.interactive(), in: .capsule)
        .help(backend.lastError ?? [proxy?.node, proxy?.ip].compactMap { $0 }.joined(separator: " · "))
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            ProxyPopover()
        }
    }
}

/// Всплывающее окно у значка proxy: выход, сервер, сколько сессий идет через proxy, действия и ссылка на настройки.
struct ProxyPopover: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace

    var l: L { L(backend.state.lang) }

    var body: some View {
        let p = backend.state.proxy
        let agents = workspace.tabs.filter { $0.spec.utility == nil }
        let proxied = agents.filter(\.spec.proxied).count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text(p?.exit ?? "—").font(.system(size: 26, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p?.running == true ? l.t("mihomo работает", "mihomo running")
                         : p?.configured == true ? l.t("mihomo ждет сессию", "mihomo waits for a session") : l.proxyOff)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p?.running == true ? Ink.teal : Ink.muted)
                    Text([p?.protocol, p?.ip].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.muted)
                }
                Spacer()
            }
            if let node = p?.node, !node.isEmpty {
                Text(node).font(.system(size: 12)).foregroundStyle(Ink.text2).lineLimit(1).truncationMode(.middle)
            }
            Text(l.t("Через proxy \(proxied) из \(agents.count) вкладок, новые сессии ",
                     "\(proxied) of \(agents.count) tabs via proxy, new sessions ")
                 + ((p?.defaultRoute ?? "proxy") == "direct" ? l.t("напрямую", "go direct") : l.t("через proxy", "via proxy")))
                .font(.system(size: 12)).foregroundStyle(Ink.muted)
            if p?.configured == true {
                ProxyActions(columns: 1) { backend.refresh() }
            }
            HStack {
                Spacer()
                SettingsLink {
                    Text(l.t("Настройки proxy", "Proxy settings"))
                }
                .buttonStyle(.link)
                .simultaneousGesture(TapGesture().onEnded { UserDefaults.standard.set("proxy", forKey: "settingsSection") })
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Боковая панель

struct Sidebar: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    @State private var expanded: Set<String> = []
    @AppStorage("layout.projectsOpen") private var projectsOpen = true

    var l: L { L(backend.state.lang) }

    var body: some View {
        // список проектов во всю высоту карточки, шапка и режимы лежат поверх него барами: строки уходят под них
        // и размываются краевым эффектом, а у режимов свой стеклянный фон
        Group {
            if projectsOpen {
                projectList
                    .scrollContentBackground(.hidden)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Color.clear
            }
        }
        // без .clipped(): обрезка по краю шапки убирала строки из-под нее, и размывать там было нечего
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // флаг хранится в UserDefaults, и withAnimation у заголовка до него не доходит: анимация по значению
        .animation(.snappy(duration: 0.28), value: projectsOpen)
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                // место под светофор, кнопка свертывания теперь в шапке средней карточки
                Color.clear
                    .frame(height: 40)
                    .frame(maxWidth: .infinity)
                    .background(WindowDragArea())
                CollapsibleHeader(title: l.projects, open: $projectsOpen, summary: openSummary, alwaysShowSummary: true)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)
            }
            // строки под светофором и заголовком размыты
            .blurBar(edge: .top)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) { SidebarFooter() }
        .onAppear { expandOpenProjects() }
        .onChange(of: workspace.selected) { expandOpenProjects() }
    }

    /// "3 open, 1 waiting": вкладки этого окна и сессии из реестра Claude Code, открытые где угодно, в iTerm2
    /// тоже. Реестр знает и наши вкладки, поэтому вкладка с известной сессией считается один раз.
    /// В раскрытой группе ноль не показываем.
    private var openSummary: String {
        let (tabs, others) = workspace.openSessions(backend.state)
        let open = tabs.count + others.count
        let waiting = tabs.filter { $0.status == "waiting" }.count + others.filter { $0.status == "waiting" }.count
        if open == 0 && projectsOpen { return "" }
        var text = l.t("открыто \(open)", "\(open) open")
        if waiting > 0 { text += l.t(waiting == 1 ? ", ждет 1" : ", ждут \(waiting)", ", \(waiting) waiting") }
        return text
    }

    private var projectList: some View {
        List {
            ForEach(backend.state.projects) { project in
                DisclosureGroup(isExpanded: binding(for: project)) {
                    ForEach(backend.state.sessions(in: project).prefix(6)) { session in
                        SessionRow(session: session, project: project)
                    }
                } label: {
                    ProjectRow(project: project, open: expanded.contains(project.path))
                }
            }
            if let error = backend.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Ink.amber)
                        .font(.caption)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func binding(for project: AppState.Project) -> Binding<Bool> {
        Binding(get: { expanded.contains(project.path) },
                set: { if $0 { expanded.insert(project.path) } else { expanded.remove(project.path) } })
    }

    private func expandOpenProjects() {
        // продолжение открывается в папке сессии, это бывает подпапка проекта
        if let path = workspace.current?.spec.projectPath { expanded.insert(backend.state.project(containing: path)?.path ?? path) }
    }
}

/// Низ боковой панели: режимы капсулами и состояние host-run.
struct SidebarFooter: View {
    @EnvironmentObject var backend: Backend
    @AppStorage("layout.modesOpen") private var modesOpen = true

    var l: L { L(backend.state.lang) }

    /// Короткое описание режима под его именем.
    private func modeHint(_ key: String) -> String {
        switch key {
        case "humanize": return l.t("текст без примет нейросети", "writing without AI tells")
        case "guard": return l.t("спросит перед опасной командой", "asks before risky commands")
        case "notify": return l.t("скажет, что агент ждет", "pings when an agent waits")
        case "buildlog": return l.t("выжимка длинных сборок", "digest of long builds")
        case "lid": return l.t("не спать с закрытой крышкой", "awake with the lid closed")
        default: return ""
        }
    }

    /// Порядок из макета. Режимы, которых нет в ответе app-state, не показываются.
    private static let order = ["humanize", "guard", "notify", "buildlog", "lid"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CollapsibleHeader(title: l.modes, open: $modesOpen,
                              summary: Self.order.filter { backend.state.modes[$0] == true }.joined(separator: " · "))
            if modesOpen {
            VStack(spacing: 4) {

                ForEach(Self.order.filter { backend.state.modes[$0] != nil }, id: \.self) { key in
                    let on = backend.state.modes[key] ?? false
                    Button {
                        backend.setMode(key, on: !on)
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(key).font(.system(size: 12, weight: .medium)).foregroundStyle(on ? Ink.modeOn : Ink.text2)
                                Text(modeHint(key)).font(.system(size: 11)).foregroundStyle(Ink.faint).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Capsule()
                                .fill(on ? Color.accentColor : Ink.modeOffBorder)
                                .frame(width: 22, height: 13)
                                .overlay(alignment: on ? .trailing : .leading) {
                                    Circle().fill(.white).frame(width: 9, height: 9).padding(2)
                                }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Ink.modeOnBg : Ink.modeOffBg))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Ink.modeOnBorder : Ink.modeOffBorder))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(l.modeTitle(key))
                    .accessibilityLabel(key + ", " + modeHint(key))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            if let h = backend.state.hostRun {
                HStack(spacing: 8) {
                    GlowDot(color: h.running ? Ink.tealDot : Ink.amberDot)
                    Text(h.running
                         ? l.t("host-run работает · ", "host-run running · ") + l.commands(h.commands)
                         : l.t("host-run не запущен", "host-run isn't running"))
                }
                .font(.system(size: 12))
                .foregroundStyle(Ink.muted)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.28), value: modesOpen)
        .padding(12)
        // жидкое стекло: проекты, уехавшие под режимы, просвечивают размытыми
        .glassEffect(.regular, in: .windowCard)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

/// Заголовок группы в боковой панели: имя, стрелка, справа сводка, пока группа свернута. Клик сворачивает.
struct CollapsibleHeader: View {
    let title: String
    @Binding var open: Bool
    var summary = ""
    /// Сводка и в раскрытой группе: у проектов она говорит то, чего не видно в списке, сколько сессий открыто.
    var alwaysShowSummary = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                SectionCaption(text: title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.faint)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Spacer()
                if (!open || alwaysShowSummary) && !summary.isEmpty {
                    Text(summary).font(.system(size: 11)).foregroundStyle(Ink.faint).lineLimit(1)
                }
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(open ? "expanded" : "collapsed")
    }
}

/// Раскладка в строку с переносом, как flex-wrap в макете.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !row.items.isEmpty && row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

struct ProjectRow: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    let project: AppState.Project
    let open: Bool
    @State private var hover = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        // вкладки этого окна и сессии в других окнах, без двойного счета
        let (tabs, others) = workspace.openSessions(in: project, state: backend.state)
        let count = tabs.count + others.count
        let waiting = tabs.contains { $0.status == "waiting" } || others.contains { $0.status == "waiting" }
        HStack(spacing: 8) {
            // клик открывает экран проекта, повторный клик закрывает его. Жест висит на всем, кроме "+":
            // simultaneousGesture на всей строке срабатывал и вместе с кнопкой новой сессии
            HStack(spacing: 8) {
                ProjectIconView(path: project.path, size: 18)
                Text(project.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                if !hover && count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(waiting ? Ink.amber : Ink.faint)
                }
            }
            .frame(minHeight: 28)
            .padding(.leading, 4)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { ui.projectScreen = ui.projectScreen == project.path ? nil : project.path })
            if hover {
                Button {
                    if AgentPrefs.defaultAgent == "ask" {
                        ui.newSessionProject = project.path
                        ui.showNewSession = true
                    } else {
                        workspace.open(LaunchSpec(projectName: project.name, projectPath: project.path,
                                                  agent: AgentPrefs.defaultAgent == "codex" ? .codex : .claude,
                                                  direct: backend.state.proxy?.defaultRoute == "direct"))
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(l.newSession)
                .accessibilityLabel(l.newSession)
            }
        }
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .listRowBackground(ui.projectScreen == project.path
                           ? RoundedRectangle(cornerRadius: 10).fill(Ink.thumb).padding(.horizontal, 10)
                           : open ? RoundedRectangle(cornerRadius: 10).fill(Ink.openBg).padding(.horizontal, 10) : nil)
        .contextMenu {
            Button(l.newSession) {
                workspace.open(LaunchSpec.quick(project))
            }
            Button(l.t("Новая сессия…", "New session…")) {
                ui.newSessionProject = project.path
                ui.showNewSession = true
            }
            if let last = backend.state.sessions(in: project).first {
                Button(l.resumeLast) {
                    workspace.open(LaunchSpec.resume(last, project: project))
                }
            }
            Button(l.t("Обзор проекта", "Project overview")) { ui.projectScreen = project.path }
            Divider()
            Button(l.t("Показать в Finder", "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
            }
        }
    }
}

struct SessionRow: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    let session: AppState.Session
    let project: AppState.Project

    var l: L { L(backend.state.lang) }

    var body: some View {
        let tab = workspace.tabs.first { $0.sessionId == session.id && $0.running }
        let live = backend.state.live.first { $0.sessionId == session.id }
        let status = tab?.status ?? live?.status
        // пока открыт экран проекта, выделен он, а не вкладка
        let current = tab != nil && tab?.id == workspace.selected && ui.projectScreen == nil
        Button {
            ui.projectScreen = nil
            workspace.open(LaunchSpec.resume(session, project: project))
        } label: {
            HStack(spacing: 8) {
                SessionDot(status: status, open: status != nil || tab != nil, size: 7)
                if session.kind == .codex {
                    // у Claude Code значка нет: их в списке большинство, а X сразу выделяет Codex
                    AgentBadge(agent: .codex, size: 14)
                }
                Text(session.title.isEmpty ? l.untitled : session.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(current ? Ink.strong : Ink.text2)
                Spacer(minLength: 4)
                if live != nil && tab == nil {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.caption)
                        .foregroundStyle(Ink.faint)
                }
                Text(status.map { l.shortStatus($0) } ?? l.ago(session.mtime))
                    .font(.system(size: 11))
                    .foregroundStyle(status == "waiting" ? Ink.amber : Ink.faint)
            }
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(current ? RoundedRectangle(cornerRadius: 10).fill(Ink.thumb).padding(.horizontal, 10) : nil)
        .help(live != nil && tab == nil
              ? l.t("Открыта в другом окне", "Open in another window")
              : l.t("Продолжить в новой вкладке", "Resume in a new tab"))
    }
}

// MARK: - Вкладки и терминал

struct DetailView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace

    var l: L { L(backend.state.lang) }

    @EnvironmentObject var ui: UIState

    var body: some View {
        if let path = ui.projectScreen {
            ProjectView(path: path)
        } else if workspace.tabs.isEmpty {
            ContentUnavailableView(l.noTabs, systemImage: "terminal", description: Text(l.noTabsHint(ShortcutStore.shared.label(.newSession))))
        } else {
            VStack(spacing: 10) {
                TabStrip()
                if let tab = workspace.current {
                    InfoBar(tab: tab)
                    TabAlert(tab: tab)
                        .id(tab.id)
                }
                TerminalHost(tab: workspace.current)
                    .clipShape(.windowCard)
                    .overlay(alignment: .topTrailing) {
                        if let tab = workspace.current { TerminalFindOverlay(tab: tab) }
                    }
            }
        }
    }
}

/// Полоса вкладок: одна стеклянная капсула, выбранная вкладка светлее, в конце "+".
struct TabStrip: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var ui: UIState

    var l: L { L(backend.state.lang) }

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.tabs) { tab in
                        TabChip(tab: tab, selected: tab.id == workspace.selected)
                    }
                }
            }
            Button {
                if !workspace.newTab() { ui.showNewSession = true }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.text2)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .shortcutHelp(l.newTab, .newTab)
            .accessibilityLabel(l.newTab)
        }
        .padding(4)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct TabChip: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var ui: UIState
    @ObservedObject var tab: TerminalTab
    let selected: Bool
    @State private var hover = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        Button {
            workspace.selected = tab.id
            tab.rang = false
        } label: {
            HStack(spacing: 8) {
                AgentBadge(agent: tab.spec.utility == nil ? tab.spec.agent : nil)
                Text(tab.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if tab.spec.proxied || tab.spec.utility == nil {
                    Text(tab.spec.proxied ? l.proxy : l.direct)
                        .font(.system(size: 11))
                        .foregroundStyle(tab.spec.proxied ? Ink.teal : Ink.direct)
                }
                if hover {
                    Button {
                        workspace.close(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Ink.chip))
                    }
                    .buttonStyle(.plain)
                    .shortcutHelp(l.closeTab, .closeTab)
                    .accessibilityLabel(l.closeTab)
                } else if tab.running && (tab.status == "waiting" || tab.status == "busy") {
                    SessionDot(status: tab.status)
                } else if tab.rang && !selected {
                    Image(systemName: "bell.fill").font(.system(size: 9)).foregroundStyle(Ink.amber)
                } else if !tab.running {
                    Image(systemName: "stop.circle").font(.system(size: 11)).foregroundStyle(Ink.faint)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(selected ? Ink.strong : Ink.muted)
            .padding(.horizontal, 12)
            .frame(minWidth: 150, maxWidth: 230, minHeight: 32, maxHeight: 32)
            .background(Capsule().fill(selected ? Ink.thumb : .clear).shadow(color: .black.opacity(selected ? 0.25 : 0), radius: 4, y: 2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        // полное имя сессии, если в вкладку оно не влезло, и под ним проект
        .help(tab.title + "\n" + tab.spec.projectName)
        .contextMenu { TabMenu(tab: tab) }
    }
}

/// Действия вкладки из макета: в меню по правому клику и в палитре.
struct TabMenu: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var ui: UIState
    @ObservedObject var tab: TerminalTab

    var l: L { L(backend.state.lang) }

    var body: some View {
        let claude = tab.spec.utility == nil && tab.spec.agent == .claude
        Button(l.restart) { tab.restartPreferred(note: l.updating) }
        if claude && tab.sessionId != nil {
            Button(l.slim) { tab.slim(note: l.slimming) }
            Button(l.rename + "…") { ui.renaming = tab }
        }
        if tab.spec.utility == nil {
            Button {
                tab.switchRoute()
            } label: {
                Text(tab.spec.proxied ? l.t("Перейти напрямую", "Switch to direct") : l.t("Перейти на proxy", "Switch to proxy"))
                Text(l.t("перезапуск той же сессии", "restarts the same session"))
            }
        }
        if tab.spec.agent == .codex && tab.spec.utility == nil {
            Button {
                workspace.moveToClaude(tab)
            } label: {
                Text(l.moveToClaude)
                Text(tab.sessionId == nil ? l.t("тред Codex еще не сохранен", "the Codex thread isn't saved yet")
                                          : l.t("контекст этой сессии Codex в новый Claude", "this Codex session's context into a new Claude"))
            }
            .disabled(tab.sessionId == nil)
        }
        if let sid = tab.sessionId {
            Button(l.t("Скопировать id сессии", "Copy session id")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sid, forType: .string)
            }
        }
        if claude {
            Divider()
            Button(role: .destructive) {
                ui.forgetting = tab
            } label: {
                Text(l.forget)
                Text(l.t("удалить без следа", "delete without a trace"))
            }
        }
        Divider()
        Button(l.closeTab) { workspace.close(tab.id) }
            .shortcut(.closeTab)
    }
}

/// Переименование сессии вкладки, как /rename.
struct RenameSheet: View {
    @EnvironmentObject var backend: Backend
    @Environment(\.dismiss) private var dismiss
    let tab: TerminalTab
    @State private var title = ""

    var l: L { L(backend.state.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l.t("Переименовать сессию", "Rename the session")).font(.title3.weight(.semibold))
            TextField(l.t("Название", "Title"), text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                PillButton(title: l.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                PillButton(title: l.rename, prominent: true, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear {
            title = backend.state.sessions.first { $0.id == tab.sessionId }?.title ?? tab.title
        }
    }

    private func save() {
        let clean = title.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        tab.rename(clean)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { backend.refresh() }
    }
}

/// Строка над терминалом: папка, ветка, песочница, Remote Control, "не спать" и смена маршрута.
struct InfoBar: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    @ObservedObject var tab: TerminalTab
    @Environment(\.openSettings) private var openSettings
    /// Ветку только что скопировали: чип полторы секунды показывает "Скопировано".
    @State private var copied = false
    /// Ветка папки сейчас, из .git/HEAD. Читается вне главного потока раз в 5 секунд, пока строка видна,
    /// а не в body при каждой перерисовке.
    @State private var head: String?

    private func revealFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: tab.spec.projectPath, isDirectory: true))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyBranch(_ branch: String) {
        copy(branch)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    /// Настройки на разделе proxy и host-run.
    private func openProxySettings() {
        UserDefaults.standard.set("proxy", forKey: "settingsSection")
        openSettings()
        NSApp.activate()
    }

    var l: L { L(backend.state.lang) }

    var body: some View {
        // ветка из истории сессии осталась бы той, на которой она началась, поэтому сначала .git/HEAD
        let branch = head ?? backend.state.sessions.first { $0.id == tab.sessionId }?.branch ?? ""
        let port = backend.state.proxy?.port ?? 17890
        HStack(spacing: 8) {
            Chip(mono: true, action: { revealFolder() }) {
                Text(tilde(tab.spec.projectPath)).lineLimit(1).truncationMode(.head)
            }
            .layoutPriority(2)
            .help(l.t("Открыть папку в Finder", "Open the folder in Finder"))
            .contextMenu {
                Button(l.t("Открыть в Finder", "Open in Finder")) { revealFolder() }
                Button(l.t("Скопировать путь", "Copy path")) { copy(tab.spec.projectPath) }
            }
            if !branch.isEmpty {
                Chip(mono: true, action: { copyBranch(branch) }) {
                    Text(l.t("ветка", "branch")).font(.system(size: 12)).foregroundStyle(Ink.faint)
                    Text(copied ? l.t("скопировано", "copied") : branch).lineLimit(1)
                }
                .layoutPriority(1)
                .help(l.t("Скопировать имя ветки", "Copy the branch name"))
            }
            if tab.spec.utility != nil {
                Chip(foreground: Ink.muted, action: { openProxySettings() }) {
                    Text(tab.spec.proxied ? l.t("proxy run, сеть через 127.0.0.1:\(port)", "proxy run, network via 127.0.0.1:\(port)")
                                          : l.t("команда agentmeister", "agentmeister command"))
                }
            } else if tab.spec.proxied {
                Chip(background: Ink.tealChip, foreground: Ink.teal, action: { openProxySettings() }) {
                    Text(tab.spec.agent == .codex
                         ? l.t("строгий профиль, сеть только через mihomo", "strict profile, network only through mihomo")
                         : l.t("sandbox-exec, сеть через 127.0.0.1:\(port)", "sandbox-exec, network via 127.0.0.1:\(port)"))
                }
                .help(l.t("Настройки proxy и host-run", "Proxy and host-run settings"))
            } else {
                Chip(foreground: Ink.direct, action: { openProxySettings() }) {
                    Text(l.t("напрямую, без sandbox-exec", "direct, no sandbox-exec"))
                }
                .help(l.t("Настройки proxy и host-run", "Proxy and host-run settings"))
            }
            if tab.spec.remoteControl && tab.spec.agent == .claude {
                Chip {
                    Image(systemName: "iphone").font(.system(size: 11))
                    Text("Remote Control")
                }
                .help(l.t("Сессия подключена к Remote Control, вопросы приходят в приложение Claude на телефоне",
                          "Connected to Remote Control, questions go to the Claude app on your phone"))
            }
            if tab.spec.utility == nil {
                Button {
                    tab.setAwake(!tab.spec.awake)
                } label: {
                    Label(l.t("Не спать", "Stay awake"), systemImage: "timer")
                }
                .buttonStyle(ChipStyle(on: tab.spec.awake))
                .help(l.t("Mac не уснет, пока идет эта сессия", "The Mac stays awake while this session runs"))
                .accessibilityAddTraits(tab.spec.awake ? .isSelected : [])
            }
            if !tab.running {
                Text(l.exited + (tab.exitCode.map { ", \($0)" } ?? ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.faint)
            }
            Spacer(minLength: 0)
            if tab.spec.agent == .codex && tab.spec.utility == nil {
                Button { workspace.moveToClaude(tab) } label: { Label(l.moveToClaude, systemImage: "arrow.right.circle") }
                    .buttonStyle(ChipStyle())
                    .disabled(tab.sessionId == nil)
                    .help(tab.sessionId == nil
                          ? l.t("Тред Codex появится после первого запроса", "The Codex thread appears after the first request")
                          : l.t("Новая вкладка Claude Code с контекстом этой сессии Codex", "A new Claude Code tab with this Codex session's context"))
            }
            if tab.spec.utility == nil {
                Button { if tab.spec.proxied { ui.confirmingDirect = tab } else { tab.switchRoute() } } label: {
                    Label(tab.spec.proxied ? l.t("Перезапустить напрямую", "Restart without proxy")
                                           : l.t("Перезапустить через proxy", "Restart via proxy"),
                          systemImage: tab.spec.proxied ? "arrow.triangle.2.circlepath" : "shield")
                }
                .buttonStyle(ChipStyle())
                .help(tab.spec.proxied ? l.t("Та же сессия, но без песочницы и proxy", "The same session without the sandbox and proxy")
                                       : l.t("Та же сессия в песочнице, сеть через mihomo", "The same session in the sandbox, network through mihomo"))
            } else {
                Button { tab.restart() } label: { Label(l.restart, systemImage: "arrow.clockwise") }
                    .buttonStyle(ChipStyle())
            }
        }
        .padding(.horizontal, 4)
        .task(id: tab.spec.projectPath) {
            let path = tab.spec.projectPath
            head = nil
            while !Task.isCancelled {
                let now = await Task.detached(priority: .utility) { GitHead.branch(at: path) }.value
                if head != now { head = now }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// Показывает терминал выбранной вкладки. NSView терминала не пересоздается, только меняется местами.
struct TerminalHost: NSViewRepresentable {
    let tab: TerminalTab?

    /// Терминал занимает все, что ему дали, и не диктует высоту сам: иначе баннер над ним выталкивал бы
    /// полосу вкладок за верх окна.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 200))
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        // Без обрезки SwiftTerm дорисовывает символ за левым краем
        container.layer?.masksToBounds = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let dark = context.environment.colorScheme == .dark || TerminalPrefs.alwaysDark
        let background = dark ? NSColor(hex: 0x08090B) : NSColor.white
        container.layer?.backgroundColor = background.cgColor
        guard let term = tab?.view else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if term.nativeBackgroundColor != background {
            term.nativeBackgroundColor = background
            term.nativeForegroundColor = dark ? NSColor(hex: 0xD9DBE1) : NSColor(hex: 0x24262B)
            term.caretColor = dark ? .white : .black
        }
        if term.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            term.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(term)
            NSLayoutConstraint.activate([
                term.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
                term.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                term.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
                term.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            ])
        }
        // пока открыта панель поиска, фокус у ее поля, а не у терминала
        if tab?.finding != true {
            DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
        }
    }
}

/// Панель поиска над терминалом, когда она открыта у этой вкладки.
struct TerminalFindOverlay: View {
    @ObservedObject var tab: TerminalTab

    var body: some View {
        if tab.finding {
            TerminalFindBar(tab: tab)
                .padding(.top, 12)
                .padding(.trailing, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// Поиск по выводу вкладки: поле, "номер из всего", регистр, слово целиком, регулярное выражение, стрелки и
/// закрытие. Enter ищет дальше, Shift+Enter назад, Esc закрывает.
struct TerminalFindBar: View {
    @EnvironmentObject var backend: Backend
    @ObservedObject var tab: TerminalTab
    @FocusState private var focused: Bool

    var l: L { L(backend.state.lang) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.muted)
            TextField(l.t("Найти в выводе", "Find in output"), text: $tab.findTerm)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 190)
                .focused($focused)
                .onSubmit { tab.step(forward: !NSEvent.modifierFlags.contains(.shift)) }
                .onKeyPress(.escape) {
                    tab.closeFind()
                    return .handled
                }
            Text(counter)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(!tab.findTerm.isEmpty && tab.findPosition.total == 0 ? Ink.amber : Ink.muted)
                .frame(minWidth: 56, alignment: .trailing)
            Rectangle().fill(Ink.hairline).frame(width: 1, height: 16)
            option("Aa", on: tab.findOptions.caseSensitive, help: l.t("С учетом регистра", "Match case")) {
                tab.findOptions.caseSensitive.toggle()
            }
            option("W", on: tab.findOptions.wholeWord, help: l.t("Слово целиком", "Whole word")) {
                tab.findOptions.wholeWord.toggle()
            }
            option(".*", on: tab.findOptions.regex, help: l.t("Регулярное выражение", "Regular expression")) {
                tab.findOptions.regex.toggle()
            }
            Rectangle().fill(Ink.hairline).frame(width: 1, height: 16)
            icon("chevron.up", help: l.t("Предыдущее (⇧⌘G)", "Previous (⇧⌘G)")) { tab.step(forward: false) }
            icon("chevron.down", help: l.t("Следующее (⌘G)", "Next (⌘G)")) { tab.step(forward: true) }
            icon("xmark", help: l.t("Закрыть (Esc)", "Close (Esc)")) { tab.closeFind() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 38)
        .glassEffect(.regular, in: Capsule())
        .onAppear { focused = true }
        .onChange(of: tab.findFocus) { focused = true }
        .onChange(of: tab.findTerm) { tab.restartSearch() }
    }

    /// "3/14", "нет совпадений" или пусто, пока ничего не введено. Больше тысячи совпадений SwiftTerm не считает.
    private var counter: String {
        guard !tab.findTerm.isEmpty else { return "" }
        let (index, total) = tab.findPosition
        if total == 0 { return l.t("нет", "none") }
        return "\(index)/" + (total >= 1000 ? "1000+" : "\(total)")
    }

    private func option(_ title: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            tab.restartSearch()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(on ? Ink.modeOn : Ink.muted)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Ink.modeOnBg : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func icon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Ink.text2)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Панель сессии

struct InspectorView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace

    var l: L { L(backend.state.lang) }

    var body: some View {
        if let tab = workspace.current {
            TabInspector(tab: tab)
        } else {
            ContentUnavailableView(l.noTabs, systemImage: "sidebar.right")
        }
    }
}

/// Панель сессии по макету: заголовок, карточка с агентом и маршрутом, кнопки, host-run.
struct TabInspector: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    @ObservedObject var tab: TerminalTab
    @AppStorage("restartWithUpdate") private var withUpdate = true
    /// Git и бэклог проекта вкладки из app-state project. Обновляются при смене вкладки и раз в минуту.
    @State private var project: ProjectData?

    var l: L { L(backend.state.lang) }

    var body: some View {
        let saved = backend.state.sessions.first { $0.id == tab.sessionId }
        let proxy = backend.state.proxy
        let claude = tab.spec.utility == nil && tab.spec.agent == .claude
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionCaption(text: l.t("Сессия", "Session"))
                    Text(saved?.title.isEmpty == false ? saved!.title : tab.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(3)
                }
                .padding(.horizontal, 4)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 9) {
                    row(l.agent, agentTitle)
                    GridRow {
                        Text(l.route).foregroundStyle(Ink.faint).frame(width: 76, alignment: .leading)
                        if tab.spec.proxied {
                            Text(["proxy " + (proxy?.exit ?? ""), [proxy?.protocol, proxy?.ip].compactMap { $0 }.joined(separator: " ")]
                                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: ", "))
                                .foregroundStyle(Ink.teal)
                        } else {
                            Text(l.directly).foregroundStyle(Ink.direct)
                        }
                    }
                    row(l.t("Песочница", "Sandbox"), tab.spec.proxied ? "sandbox-exec" : l.t("нет", "none"))
                    if let branch = project?.git?.branch ?? saved?.branch, !branch.isEmpty {
                        row(l.t("Ветка", "Branch"), branch + ((project?.git?.dirty ?? 0) > 0 ? " ±\(project!.git!.dirty)" : ""), mono: true)
                    }
                    GridRow {
                        Text(l.t("Активна", "Active")).foregroundStyle(Ink.faint).frame(width: 76, alignment: .leading)
                        if tab.running {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(l.duration(context.date.timeIntervalSince(tab.startedAt)))
                            }
                        } else {
                            Text(l.exited + (tab.exitCode.map { ", \($0)" } ?? ""))
                        }
                    }
                }
                .font(.system(size: 12))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))

                FlowLayout(spacing: 6) {
                    CapsuleButton(title: l.restart) {
                        tab.restartPreferred(note: l.updating)
                    }
                    if claude && tab.sessionId != nil {
                        CapsuleButton(title: l.slim) { tab.slim(note: l.slimming) }
                    }
                    if tab.spec.utility == nil {
                        CapsuleButton(title: l.t("С чистого листа", "Fresh start")) { tab.fresh() }
                    }
                    if claude {
                        CapsuleButton(title: l.forget, destructive: true) { ui.forgetting = tab }
                    }
                }
                .padding(.horizontal, 2)
                if claude {
                    Toggle(l.t("Перезапускать с обновлением агента", "Update the agent when restarting"), isOn: $withUpdate)
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.text2)
                        .padding(.horizontal, 4)
                }

                if let h = backend.state.hostRun {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionCaption(text: "host-run")
                        HStack(spacing: 8) {
                            GlowDot(color: h.running ? Ink.tealDot : Ink.amberDot)
                            Text(h.running ? l.t("исполнитель работает", "the runner is running") : l.t("исполнитель не запущен", "the runner isn't running"))
                                .foregroundStyle(h.running ? Ink.teal : Ink.amber)
                        }
                        Text(l.commands(h.commands) + l.t(" в белом списке", " in the allowlist"))
                            .foregroundStyle(Ink.muted)
                        SettingsLink {
                            Text(l.t("Весь белый список", "Full allowlist")).foregroundStyle(Ink.link)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded { UserDefaults.standard.set("proxy", forKey: "settingsSection") })
                    }
                    .font(.system(size: 12))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
                }

                let todos = (project?.todos ?? []).filter { !$0.done }
                if tab.spec.utility == nil, !todos.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        SectionCaption(text: l.t("Бэклог проекта", "Project backlog"))
                        ForEach(todos.prefix(6), id: \.self) { item in
                            Button {
                                if let n = item.n { markDone(n) }
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "square").foregroundStyle(Ink.muted)
                                    Text(item.text).foregroundStyle(Ink.text).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(l.t("Отметить сделанной", "Mark done"))
                        }
                    }
                    .font(.system(size: 12))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
        .task(id: tab.spec.projectPath) {
            while !Task.isCancelled {
                if tab.spec.utility == nil { project = await Backend.json(["app-state", "project", tab.spec.projectPath]) }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// "Claude Code, opus high" как в макете: модель из флагов вкладки, иначе из настроек агента.
    private var agentTitle: String {
        guard tab.spec.utility == nil else { return "agentmeister" }
        let name = tab.spec.agent == .codex ? "Codex" : "Claude Code"
        let model = tab.spec.modelFlag ?? (backend.state.models?[tab.spec.agent.rawValue] ?? nil)
        return model.map { name + ", " + $0 } ?? name
    }

    private func markDone(_ n: Int) {
        let path = tab.spec.projectPath
        Task {
            _ = await backend.perform(["todo", "-p", path, "done", String(n)])
            project = await Backend.json(["app-state", "project", path])
        }
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(title).foregroundStyle(Ink.faint).frame(width: 76, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Новая сессия

struct NewSessionSheet: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    @Environment(\.dismiss) private var dismiss
    let initialProject: String?

    enum StartMode: Hashable { case new, resume, parallel }

    @State private var projectPath = ""
    @State private var agent: LaunchSpec.Agent = .claude
    @State private var direct = false
    @State private var mode: StartMode = .new
    @State private var fork = false
    @State private var remoteControl = true
    @State private var prompt = ""
    @State private var busy = false
    @State private var error: String?

    var l: L { L(backend.state.lang) }

    /// Сессия текущей вкладки, если это Claude в том же проекте: ее можно скопировать во второй Claude.
    private var forkSource: String? {
        guard let tab = workspace.current, tab.spec.utility == nil, tab.spec.agent == .claude,
              tab.spec.projectPath == projectPath else { return nil }
        return tab.sessionId
    }

    private var project: AppState.Project? { backend.state.projects.first { $0.path == projectPath } }
    /// Последняя сессия выбранного агента в проекте: ее продолжает "Продолжить последнюю".
    private var lastSession: AppState.Session? { project.flatMap { backend.state.sessions(in: $0, agent: agent).first } }

    var body: some View {
        let project = self.project
        let last = lastSession
        let exit = backend.state.proxy?.exit
        VStack(alignment: .leading, spacing: 18) {
            Text(l.newSession).font(.system(size: 17, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    Text(l.project).foregroundStyle(Ink.muted).frame(width: 104, alignment: .leading)
                    Picker(l.project, selection: $projectPath) {
                        ForEach(backend.state.projects) { p in Text(p.name).tag(p.path) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text(l.agent).foregroundStyle(Ink.muted)
                    SegmentedCapsule(selection: $agent, options: [(.claude, "Claude Code", nil), (.codex, "Codex", nil)])
                }
                GridRow {
                    Text(l.route).foregroundStyle(Ink.muted)
                    SegmentedCapsule(selection: $direct, options: [
                        (false, l.t("Через proxy", "Via proxy") + (exit.map { " " + $0 } ?? ""), Ink.teal),
                        (true, l.directly, Ink.direct),
                    ])
                }
                GridRow(alignment: .top) {
                    Text(l.start).foregroundStyle(Ink.muted).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(l.start, selection: $mode) {
                            Text(l.startNew).tag(StartMode.new)
                            Text(l.t("Продолжить последнюю", "Continue the last one")
                                 + (last.map { ", \"" + ($0.title.isEmpty ? l.untitled : $0.title) + "\"" } ?? ""))
                                .tag(StartMode.resume)
                                .disabled(last == nil)
                            Text(l.t("Параллельно, своя ветка и worktree", "In parallel, own branch and worktree"))
                                .tag(StartMode.parallel)
                                .disabled(agent != .claude)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        Toggle(l.t("С копией этого разговора, второй Claude знает все, что уже обсудили",
                                   "With a copy of this conversation, so the second Claude knows everything said so far"),
                               isOn: $fork)
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.muted)
                            .padding(.leading, 26)
                            .disabled(mode != .parallel || forkSource == nil)
                            .help(forkSource == nil ? l.t("Нужна открытая вкладка Claude в этом проекте", "Needs an open Claude tab in this project") : "")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(mode == .parallel ? l.t("Задача", "Task") : l.firstPrompt).foregroundStyle(Ink.muted)
                TextEditor(text: $prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(height: 84)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Ink.card))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.buttonBorder))
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text(l.t("Что сделать в этой сессии", "What this session should do"))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Ink.faint)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(mode == .resume)
            }
            if agent == .claude {
                Toggle(l.t("Remote Control, чтобы продолжить с телефона", "Remote Control, to continue from your phone"), isOn: $remoteControl)
                    .foregroundStyle(Ink.text2)
            }
            if direct {
                Text(l.directWarning)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.amber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Ink.amberDot.opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.amberDot.opacity(0.35)))
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Ink.red)
            }
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: l.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                PillButton(title: l.t("Открыть вкладку  ⌘↩", "Open tab  ⌘↩"), prominent: true, busy: busy) {
                    open(project: project, last: last)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(project == nil || busy || (mode == .resume && last == nil)
                          || (mode == .parallel && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            // путь вкладки может быть worktree или подпапкой: берем проект, в котором он лежит
            let projects = backend.state.projects
            projectPath = initialProject.flatMap { p in projects.first { p == $0.path || p.hasPrefix($0.path + "/") }?.path }
                ?? projects.first?.path ?? ""
            if AgentPrefs.defaultAgent == "codex" { agent = .codex }
            direct = backend.state.proxy?.defaultRoute == "direct"
            if ui.newSessionParallel { mode = .parallel }
            ui.newSessionParallel = false
        }
        .onChange(of: agent) {
            if agent == .codex && mode == .parallel { mode = .new }
            resetResumeIfNothingToContinue()
        }
        .onChange(of: projectPath) { resetResumeIfNothingToContinue() }
    }

    /// У этого агента в этом проекте продолжать нечего: выбор возвращается к новой сессии.
    private func resetResumeIfNothingToContinue() {
        if mode == .resume && lastSession == nil { mode = .new }
    }

    private func open(project: AppState.Project?, last: AppState.Session?) {
        guard let project else { return }
        var spec = LaunchSpec(projectName: project.name, projectPath: project.path, agent: agent, direct: direct)
        spec.remoteControl = remoteControl && agent == .claude
        switch mode {
        case .new:
            spec.firstPrompt = prompt
        case .resume:
            if let last {
                // в папке самой сессии: она могла начаться в подпапке проекта
                spec.projectPath = LaunchSpec.resume(last, project: project).projectPath
                spec.resumeId = last.id
            }
        case .parallel:
            // ветку и worktree делает agentmeister parallel --prepare, а вкладку с задачей открываем сами
            busy = true
            error = nil
            var args = ["parallel", prompt, "-p", project.path, "--prepare"]
            if fork, let sid = forkSource { args += ["--fork-sid", sid] }
            Task {
                let job: ParallelJob? = await Backend.json(args)
                busy = false
                guard let job, job.error == nil, let path = job.path else {
                    error = job?.error ?? l.t("Не получилось сделать worktree", "Couldn't create the worktree")
                    return
                }
                var parallel = spec
                parallel.projectName = project.name + " · " + (job.branch ?? "")
                parallel.projectPath = path
                parallel.firstPrompt = job.prompt ?? prompt
                parallel.extraFlags = job.flags ?? []
                workspace.open(parallel)
                dismiss()
            }
            return
        }
        workspace.open(spec)
        dismiss()
    }
}

/// Ответ agentmeister parallel --prepare.
struct ParallelJob: Decodable {
    let path: String?
    let branch: String?
    let prompt: String?
    let flags: [String]?
    let error: String?
}

/// Сегментный переключатель-капсула из макета: дорожка и светлый ползунок у выбранного.
struct SegmentedCapsule<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String, Color?)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .fontWeight(.medium)
                        .foregroundStyle(on ? (option.2 ?? Ink.strong) : Ink.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(Capsule().fill(on ? Ink.thumb : .clear).shadow(color: .black.opacity(on ? 0.2 : 0), radius: 3, y: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Ink.chip))
    }
}

