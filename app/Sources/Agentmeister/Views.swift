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
    @Published var showInspector = true
    @Published var newSessionProject: String?
    /// Лист новой сессии открыть сразу на "параллельно, своя ветка и worktree".
    @Published var newSessionParallel = false
    /// Вкладка, сессию которой переименовывают.
    @Published var renaming: TerminalTab?
}

func tilde(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

func statusColor(_ status: String?) -> Color {
    switch status {
    case "waiting": return .orange
    case "busy": return .teal
    case "idle": return .secondary
    default: return .clear
    }
}

// MARK: - Окно

struct MainView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState

    var l: L { L(backend.state.lang) }

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 360)
        } detail: {
            DetailView()
                .inspector(isPresented: $ui.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 260, ideal: 290, max: 380)
                }
        }
        .navigationTitle("Agentmeister")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .sheet(isPresented: $ui.showNewSession) {
            NewSessionSheet(initialProject: ui.newSessionProject)
        }
        .sheet(isPresented: $ui.showPalette) {
            PaletteView()
        }
        .sheet(isPresented: $ui.showOnboarding) {
            OnboardingView()
        }
        .sheet(item: $ui.renaming) { tab in
            RenameSheet(tab: tab)
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
            // мастер один раз, при первом запуске
            if !UserDefaults.standard.bool(forKey: "onboardingDone") { ui.showOnboarding = true }
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
            // agentmeister://focus?tab=<id> из клика по уведомлению
            guard url.host() == "focus",
                  let tab = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "tab" })?.value
            else { return }
            try? FileManager.default.removeItem(atPath: Workspace.focusFile)
            workspace.focus(tab: tab)
        }
        .onChange(of: workspace.selected) { workspace.writeFront(active: NSApp.isActive) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.writeFront(active: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            workspace.writeFront(active: false)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            workspace.takeFocusRequest()
        }
    }

    /// "4 вкладки, 1 ждет ответа" / "4 tabs, 1 waiting for you", как в макете.
    private var subtitle: String {
        let waiting = workspace.tabs.filter { $0.status == "waiting" }.count
        let count = l.tabs(workspace.tabs.count)
        return waiting > 0 ? count + ", " + l.t("\(waiting) ждет ответа", "\(waiting) waiting for you") : count
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 10) {
                SearchCapsule()
                ProxyBadge()
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                ui.newSessionProject = workspace.current?.spec.projectPath
                ui.showNewSession = true
            } label: {
                Label(l.newSession, systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .help(l.newSession + ", ⌘N")
            Button {
                ui.showInspector.toggle()
            } label: {
                Label(l.inspector, systemImage: "sidebar.right")
            }
            .help(l.t("Показать или скрыть панель сессии", "Show or hide the session panel") + ", ⌥⌘I")
        }
    }
}

/// Поле "Поиск ⌘K" в тулбаре. Открывает палитру команд, где ищутся вкладки, сессии и действия.
struct SearchCapsule: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var ui: UIState
    var l: L { L(backend.state.lang) }

    var body: some View {
        Button {
            ui.showPalette = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13))
                Text(l.t("Поиск   ⌘K", "Search   ⌘K"))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.muted)
            .padding(.horizontal, 14)
            .frame(width: 240, height: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(l.t("Поиск по сессиям", "Search sessions"))
        .help(l.t("Палитра команд, ⌘K", "Command palette, ⌘K"))
    }
}

/// Значок proxy в тулбаре: бирюзовая стеклянная капсула со страной и протоколом выхода, "KZ · vless".
struct ProxyBadge: View {
    @EnvironmentObject var backend: Backend
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
        return HStack(spacing: 7) {
            Image(systemName: "shield").font(.system(size: 12, weight: .medium))
            Text(text.isEmpty ? "proxy" : text).fontWeight(.medium)
        }
        .foregroundStyle(live ? Ink.teal : Ink.muted)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .glassEffect(live ? .regular.tint(Ink.tealDot.opacity(0.22)) : .regular, in: .capsule)
        .help(backend.lastError ?? [proxy?.node, proxy?.ip].compactMap { $0 }.joined(separator: " · "))
    }
}

// MARK: - Боковая панель

struct Sidebar: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    @State private var expanded: Set<String> = []

    var l: L { L(backend.state.lang) }

    var body: some View {
        VStack(spacing: 0) {
            projectList
            SidebarFooter()
        }
        .onAppear { expandOpenProjects() }
        .onChange(of: workspace.selected) { expandOpenProjects() }
    }

    private var projectList: some View {
        List {
            Section {
                ForEach(backend.state.projects) { project in
                    DisclosureGroup(isExpanded: binding(for: project)) {
                        ForEach(backend.state.sessions(in: project).prefix(6)) { session in
                            SessionRow(session: session, project: project)
                        }
                    } label: {
                        ProjectRow(project: project, open: expanded.contains(project.path))
                    }
                }
            } header: {
                SectionCaption(text: l.projects)
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
        if let path = workspace.current?.spec.projectPath { expanded.insert(path) }
    }
}

/// Низ боковой панели: режимы капсулами и состояние host-run.
struct SidebarFooter: View {
    @EnvironmentObject var backend: Backend

    var l: L { L(backend.state.lang) }

    /// Порядок из макета. Режимы, которых нет в ответе app-state, не показываются.
    private static let order = ["humanize", "guard", "notify", "buildlog", "lid"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption(text: l.modes)
            FlowLayout(spacing: 6) {
                ForEach(Self.order.filter { backend.state.modes[$0] != nil }, id: \.self) { key in
                    let on = backend.state.modes[key] ?? false
                    Button {
                        backend.setMode(key, on: !on)
                    } label: {
                        Text(key)
                            .font(.system(size: 12))
                            .foregroundStyle(on ? Ink.modeOn : Ink.muted)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Capsule().fill(on ? Ink.modeOnBg : Ink.modeOffBg))
                            .overlay(Capsule().strokeBorder(on ? Ink.modeOnBorder : Ink.modeOffBorder))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(l.modeTitle(key))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
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
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
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
        let tabs = workspace.tabs.filter { $0.spec.projectPath == project.path && $0.running }
        let liveHere = backend.state.live.filter { live in
            guard let cwd = live.cwd else { return false }
            return cwd == project.path || cwd.hasPrefix(project.path + "/")
        }
        // вкладки этого окна и сессии в других окнах, без двойного счета
        let count = max(tabs.count, liveHere.count)
        let waiting = tabs.contains { $0.status == "waiting" } || liveHere.contains { $0.status == "waiting" }
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(Ink.muted)
            Text(project.name)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer()
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
                .help(l.t("Новая сессия Claude Code через proxy", "New Claude Code session via proxy"))
            } else if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(waiting ? Ink.amber : Ink.faint)
            }
        }
        .frame(minHeight: 28)
        .onHover { hover = $0 }
        .listRowBackground(open ? RoundedRectangle(cornerRadius: 10).fill(Ink.openBg).padding(.horizontal, 10) : nil)
        .contextMenu {
            Button(l.t("Новая сессия через proxy", "New session via proxy")) {
                workspace.open(LaunchSpec(projectName: project.name, projectPath: project.path))
            }
            Button(l.t("Новая сессия…", "New session…")) {
                ui.newSessionProject = project.path
                ui.showNewSession = true
            }
            if let last = backend.state.sessions(in: project).first {
                Button(l.resumeLast) {
                    workspace.open(LaunchSpec(projectName: project.name, projectPath: project.path, resumeId: last.id))
                }
            }
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
    let session: AppState.Session
    let project: AppState.Project

    var l: L { L(backend.state.lang) }

    var body: some View {
        let tab = workspace.tabs.first { $0.sessionId == session.id && $0.running }
        let live = backend.state.live.first { $0.sessionId == session.id }
        let status = tab?.status ?? live?.status
        let current = tab != nil && tab?.id == workspace.selected
        let dot: Color = status == "waiting" ? Ink.amberDot : status != nil ? Ink.tealDot : Ink.savedDot
        Button {
            workspace.open(LaunchSpec(projectName: project.name, projectPath: project.path, resumeId: session.id))
        } label: {
            HStack(spacing: 8) {
                GlowDot(color: dot, glow: status != nil)
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

    var body: some View {
        if workspace.tabs.isEmpty {
            ContentUnavailableView(l.noTabs, systemImage: "terminal", description: Text(l.noTabsHint))
        } else {
            VStack(spacing: 10) {
                TabStrip()
                if let tab = workspace.current {
                    InfoBar(tab: tab)
                }
                TerminalHost(tab: workspace.current)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
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
            .help(l.newTab + ", ⌘T")
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
                    .help(l.closeTab + ", ⌘W")
                } else if tab.status == "waiting" {
                    GlowDot(color: Ink.amberDot, size: 8)
                        .accessibilityLabel(l.t("ждет ответа", "waiting for you"))
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
        Button(l.restart) { tab.restart() }
            .keyboardShortcut("r", modifiers: .command)
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
        if let sid = tab.sessionId {
            Button(l.t("Скопировать id сессии", "Copy session id")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sid, forType: .string)
            }
        }
        if claude {
            Divider()
            Button(role: .destructive) {
                tab.forget(note: l.forgetting)
            } label: {
                Text(l.forget)
                Text(l.t("удалить без следа", "delete without a trace"))
            }
        }
        Divider()
        Button(l.closeTab) { workspace.close(tab.id) }
            .keyboardShortcut("w", modifiers: .command)
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
                Button(l.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(l.rename, action: save)
                    .buttonStyle(.glassProminent)
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
    @ObservedObject var tab: TerminalTab

    var l: L { L(backend.state.lang) }

    var body: some View {
        let branch = backend.state.sessions.first { $0.id == tab.sessionId }?.branch ?? ""
        let port = backend.state.proxy?.port ?? 17890
        HStack(spacing: 8) {
            Chip(mono: true) { Text(tilde(tab.spec.projectPath)).lineLimit(1).truncationMode(.head) }
                .layoutPriority(2)
            if !branch.isEmpty {
                Chip(mono: true) { Text(branch).lineLimit(1) }
                    .layoutPriority(1)
            }
            if tab.spec.utility != nil {
                Chip(foreground: Ink.muted) {
                    Text(tab.spec.proxied ? l.t("proxy run, сеть через 127.0.0.1:\(port)", "proxy run, network via 127.0.0.1:\(port)")
                                          : l.t("команда agentmeister", "agentmeister command"))
                }
            } else if tab.spec.proxied {
                Chip(background: Ink.tealChip, foreground: Ink.teal) {
                    Text(tab.spec.agent == .codex
                         ? l.t("строгий профиль, сеть только через mihomo", "strict profile, network only through mihomo")
                         : l.t("sandbox-exec, сеть через 127.0.0.1:\(port)", "sandbox-exec, network via 127.0.0.1:\(port)"))
                }
            } else {
                Chip(foreground: Ink.direct) { Text(l.t("напрямую, без sandbox-exec", "direct, no sandbox-exec")) }
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
                    HStack(spacing: 6) {
                        Image(systemName: "timer").font(.system(size: 11))
                        Text(l.t("Не спать", "Stay awake"))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(tab.spec.awake ? Ink.modeOn : Ink.muted)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(tab.spec.awake ? Ink.modeOnBg : .clear))
                    .overlay(Capsule().strokeBorder(tab.spec.awake ? Ink.modeOnBorder : Ink.buttonBorder))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(l.t("Mac не уснет, пока идет эта сессия", "The Mac stays awake while this session runs"))
                .accessibilityAddTraits(tab.spec.awake ? .isSelected : [])
            }
            if !tab.running {
                Text(l.exited + (tab.exitCode.map { ", \($0)" } ?? ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.faint)
            }
            Spacer(minLength: 0)
            if tab.spec.utility == nil {
                Button(tab.spec.proxied ? l.t("Перезапустить напрямую", "Restart without proxy")
                                        : l.t("Перезапустить через proxy", "Restart via proxy")) { tab.switchRoute() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            } else {
                Button(l.restart) { tab.restart() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Показывает терминал выбранной вкладки. NSView терминала не пересоздается, только меняется местами.
struct TerminalHost: NSViewRepresentable {
    let tab: TerminalTab?

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
        DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
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
    @ObservedObject var tab: TerminalTab

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
                    row(l.agent, tab.spec.utility != nil ? "agentmeister" : tab.spec.agent == .codex ? "Codex" : "Claude Code")
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
                    if let branch = saved?.branch, !branch.isEmpty {
                        row(l.t("Ветка", "Branch"), branch, mono: true)
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
                    CapsuleButton(title: l.restart) { tab.restart() }
                    if claude && tab.sessionId != nil {
                        CapsuleButton(title: l.slim) { tab.slim(note: l.slimming) }
                    }
                    if tab.spec.utility == nil {
                        CapsuleButton(title: l.t("С чистого листа", "Fresh start")) { tab.fresh() }
                    }
                    if claude {
                        CapsuleButton(title: l.forget, destructive: true) { tab.forget(note: l.forgetting) }
                    }
                }
                .padding(.horizontal, 2)

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

    var body: some View {
        let project = backend.state.projects.first { $0.path == projectPath }
        let last = project.flatMap { backend.state.sessions(in: $0).first }
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
                                .disabled(last == nil || agent != .claude)
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
                Button(l.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    open(project: project, last: last)
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text(l.t("Открыть вкладку  ⌘↩", "Open tab  ⌘↩")) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.glassProminent)
                .disabled(project == nil || busy || (mode == .parallel && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            projectPath = initialProject ?? backend.state.projects.first?.path ?? ""
            if AgentPrefs.defaultAgent == "codex" { agent = .codex }
            direct = backend.state.proxy?.defaultRoute == "direct"
            if ui.newSessionParallel { mode = .parallel }
            ui.newSessionParallel = false
        }
        .onChange(of: agent) { if agent == .codex { mode = .new } }
    }

    private func open(project: AppState.Project?, last: AppState.Session?) {
        guard let project else { return }
        var spec = LaunchSpec(projectName: project.name, projectPath: project.path, agent: agent, direct: direct)
        spec.remoteControl = remoteControl && agent == .claude
        switch mode {
        case .new:
            spec.firstPrompt = prompt
        case .resume:
            spec.resumeId = last?.id
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

