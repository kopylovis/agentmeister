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
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            DetailView()
                .inspector(isPresented: $ui.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 240, ideal: 290, max: 380)
                }
        }
        .navigationTitle(workspace.current?.title ?? "Agentmeister")
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

    private var subtitle: String {
        let waiting = workspace.tabs.filter { $0.status == "waiting" }.count
        let count = l.tabs(workspace.tabs.count)
        return waiting > 0 ? count + " · " + l.t("ждут \(waiting)", "\(waiting) waiting") : count
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ProxyBadge()
        }
        ToolbarItem(placement: .primaryAction) {
            LibraryToolbarButton(title: l.t("Сессии", "Sessions"))
        }
        ToolbarItem(placement: .primaryAction) {
            UsageToolbarButton(title: l.t("Статистика", "Usage"))
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                ui.newSessionProject = workspace.current?.spec.projectPath
                ui.showNewSession = true
            } label: {
                Label(l.newSession, systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .help(l.newSession + ", ⌘N")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                ui.showInspector.toggle()
            } label: {
                Label(l.inspector, systemImage: "sidebar.right")
            }
            .help(l.inspector + ", ⌥⌘I")
        }
    }
}

struct LibraryToolbarButton: View {
    @Environment(\.openWindow) private var openWindow
    let title: String

    var body: some View {
        Button {
            openWindow(id: "library")
        } label: {
            Label(title, systemImage: "books.vertical")
        }
        .help(title + ", ⇧⌘O")
    }
}

struct ProxyBadge: View {
    @EnvironmentObject var backend: Backend
    var l: L { L(backend.state.lang) }

    var body: some View {
        let proxy = backend.state.proxy
        let text: String
        let color: Color
        if proxy?.configured != true {
            text = l.proxyOff
            color = .secondary
        } else if proxy?.running == true {
            text = [proxy?.exit, proxy?.protocol].compactMap { $0 }.joined(separator: " · ")
            color = .teal
        } else {
            text = l.proxyIdle
            color = .secondary
        }
        return Label(text.isEmpty ? "proxy" : text, systemImage: "shield.lefthalf.filled")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .help(backend.lastError ?? "mihomo")
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
        List {
            Section(l.projects) {
                ForEach(backend.state.projects) { project in
                    DisclosureGroup(isExpanded: binding(for: project)) {
                        ForEach(backend.state.sessions(in: project).prefix(6)) { session in
                            SessionRow(session: session, project: project)
                        }
                    } label: {
                        ProjectRow(project: project)
                    }
                }
            }
            if !backend.state.modes.isEmpty {
                Section(l.modes) {
                    ForEach(backend.state.modes.keys.sorted().filter { $0 != "alias" }, id: \.self) { key in
                        Toggle(l.modeTitle(key), isOn: Binding(
                            get: { backend.state.modes[key] ?? false },
                            set: { backend.setMode(key, on: $0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                }
            }
            if let error = backend.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear { expandOpenProjects() }
        .onChange(of: workspace.selected) { expandOpenProjects() }
    }

    private func binding(for project: AppState.Project) -> Binding<Bool> {
        Binding(get: { expanded.contains(project.path) },
                set: { if $0 { expanded.insert(project.path) } else { expanded.remove(project.path) } })
    }

    private func expandOpenProjects() {
        if let path = workspace.current?.spec.projectPath { expanded.insert(path) }
    }
}

struct ProjectRow: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    let project: AppState.Project
    @State private var hover = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        let waiting = workspace.tabs.filter { $0.spec.projectPath == project.path && $0.status == "waiting" }.count
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(project.name)
                .lineLimit(1)
            Spacer()
            if waiting > 0 {
                Text(l.t("\(waiting) ждет", "\(waiting) waiting"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if hover {
                Button {
                    workspace.open(LaunchSpec(projectName: project.name, projectPath: project.path))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(l.t("Новая сессия Claude Code через proxy", "New Claude Code session via proxy"))
            }
        }
        .onHover { hover = $0 }
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
        Button {
            workspace.open(LaunchSpec(projectName: project.name, projectPath: project.path, resumeId: session.id))
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(status == nil ? Color.secondary.opacity(0.35) : statusColor(status))
                    .frame(width: 7, height: 7)
                Text(session.title.isEmpty ? l.untitled : session.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if workspace.liveElsewhere.contains(session.id) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(status.map { l.statusTitle($0) } ?? l.ago(session.mtime))
                    .font(.caption)
                    .foregroundStyle(status == "waiting" ? Color.orange : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            VStack(spacing: 8) {
                TabStrip()
                if let tab = workspace.current {
                    InfoBar(tab: tab)
                }
                TerminalHost(tab: workspace.current)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}

struct TabStrip: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var backend: Backend

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(workspace.tabs) { tab in
                        TabChip(tab: tab, selected: tab.id == workspace.selected)
                    }
                }
                .padding(4)
            }
        }
    }
}

struct TabChip: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var backend: Backend
    @ObservedObject var tab: TerminalTab
    let selected: Bool
    @State private var hover = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        Button {
            workspace.selected = tab.id
        } label: {
            HStack(spacing: 7) {
                Text(tab.spec.agent == .codex ? "X" : "C")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill((tab.spec.agent == .codex ? Color.blue : Color.orange).opacity(0.22)))
                Text(tab.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: .leading)
                Text(tab.spec.direct ? l.direct : l.proxy)
                    .font(.caption)
                    .foregroundStyle(tab.spec.direct ? Color.orange : Color.teal)
                if hover {
                    Button {
                        workspace.close(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color.primary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help(l.closeTab + ", ⌘W")
                } else if tab.status == "waiting" {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                } else if !tab.running {
                    Image(systemName: "stop.circle").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .glassEffect(selected ? .regular.tint(.accentColor.opacity(0.25)).interactive() : .regular.interactive(), in: .capsule)
        .contextMenu {
            Button(l.restart) { tab.restart() }
            Button(l.closeTab) { workspace.close(tab.id) }
            if let sid = tab.sessionId {
                Divider()
                Button(l.t("Скопировать id сессии", "Copy session id")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sid, forType: .string)
                }
            }
        }
    }
}

struct InfoBar: View {
    @EnvironmentObject var backend: Backend
    @ObservedObject var tab: TerminalTab

    var l: L { L(backend.state.lang) }

    var body: some View {
        HStack(spacing: 8) {
            Text(tilde(tab.spec.projectPath))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(tab.spec.direct ? l.direct : (l.proxy + " · sandbox-exec"))
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill((tab.spec.direct ? Color.orange : Color.teal).opacity(0.15)))
                .foregroundStyle(tab.spec.direct ? Color.orange : Color.teal)
            if tab.running {
                Text(l.statusTitle(tab.status))
                    .font(.caption)
                    .foregroundStyle(tab.status == "waiting" ? Color.orange : Color.secondary)
            } else {
                Text(l.exited + (tab.exitCode.map { ", \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(l.restart) { tab.restart() }
                .buttonStyle(.glass)
                .controlSize(.small)
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
        let dark = context.environment.colorScheme == .dark
        let background = dark ? NSColor(red: 0.063, green: 0.067, blue: 0.078, alpha: 1) : NSColor.white
        container.layer?.backgroundColor = background.cgColor
        guard let term = tab?.view else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if term.nativeBackgroundColor != background {
            term.nativeBackgroundColor = background
            term.nativeForegroundColor = dark ? NSColor(red: 0.85, green: 0.86, blue: 0.88, alpha: 1)
                                              : NSColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1)
            term.caretColor = dark ? .white : .black
        }
        if term.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            term.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(term)
            NSLayoutConstraint.activate([
                term.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                term.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
                term.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
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

struct TabInspector: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @ObservedObject var tab: TerminalTab

    var l: L { L(backend.state.lang) }

    /// Строка без переноса: панель узкая, и длинный путь лучше сократить посередине, чем ломать на две строки.
    private func row(_ title: String, _ value: String, truncate: Text.TruncationMode = .tail) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(value)
                .lineLimit(1)
                .truncationMode(truncate)
                .foregroundStyle(.secondary)
                .help(value)
        }
    }

    var body: some View {
        let saved = backend.state.sessions.first { $0.id == tab.sessionId }
        Form {
            Section {
                Text(saved?.title.isEmpty == false ? saved!.title : tab.title)
                    .font(.headline)
                row(l.agent, tab.spec.agent == .codex ? "Codex" : "Claude Code")
                row(l.route, tab.spec.direct ? l.directly : l.viaProxy)
                row(l.status, tab.running ? l.statusTitle(tab.status) : l.exited)
                row(l.folder, tilde(tab.spec.projectPath), truncate: .head)
                if let branch = saved?.branch, !branch.isEmpty {
                    row("git", branch)
                }
                if let sid = tab.sessionId {
                    LabeledContent(l.sessionId) {
                        Text(String(sid.prefix(8)))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            Section {
                HStack {
                    Button(l.restart) { tab.restart() }
                    Button(l.closeTab) { workspace.close(tab.id) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Новая сессия

struct NewSessionSheet: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    let initialProject: String?

    @State private var projectPath = ""
    @State private var agent: LaunchSpec.Agent = .claude
    @State private var direct = false
    @State private var resumeLast = false
    @State private var prompt = ""

    var l: L { L(backend.state.lang) }

    var body: some View {
        let project = backend.state.projects.first { $0.path == projectPath }
        let last = project.flatMap { backend.state.sessions(in: $0).first }
        VStack(alignment: .leading, spacing: 16) {
            Text(l.newSession).font(.title3.weight(.semibold))
            Form {
                Picker(l.project, selection: $projectPath) {
                    ForEach(backend.state.projects) { p in Text(p.name).tag(p.path) }
                }
                Picker(l.agent, selection: $agent) {
                    Text("Claude Code").tag(LaunchSpec.Agent.claude)
                    Text("Codex").tag(LaunchSpec.Agent.codex)
                }
                .pickerStyle(.segmented)
                Picker(l.route, selection: $direct) {
                    Text(l.viaProxy).tag(false)
                    Text(l.directly).tag(true)
                }
                .pickerStyle(.segmented)
                if agent == .claude, let last {
                    Picker(l.start, selection: $resumeLast) {
                        Text(l.startNew).tag(false)
                        Text(l.resumeLast + ", \"" + (last.title.isEmpty ? l.untitled : last.title) + "\"").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                }
                if !(resumeLast && agent == .claude) {
                    TextField(l.firstPrompt, text: $prompt, prompt: Text(l.firstPromptHint), axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .formStyle(.grouped)
            if direct {
                Label(l.directWarning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button(l.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(l.open) {
                    guard let project else { return }
                    var spec = LaunchSpec(projectName: project.name, projectPath: project.path, agent: agent, direct: direct)
                    if resumeLast && agent == .claude, let last { spec.resumeId = last.id } else { spec.firstPrompt = prompt }
                    workspace.open(spec)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(project == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            projectPath = initialProject ?? backend.state.projects.first?.path ?? ""
        }
    }
}
