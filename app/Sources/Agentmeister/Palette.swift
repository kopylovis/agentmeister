import SwiftUI

/// Строка палитры: что показать и что сделать по Enter.
struct PaletteItem: Identifiable {
    enum Group: Int { case tabs, sessions, actions, projects }

    let id: String
    let group: Group
    let title: String
    let detail: String
    let shortcut: String
    let icon: String
    let run: @MainActor () -> Void

    /// Подходит ли строка под запрос: все слова запроса есть в названии или подписи.
    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return true }
        let hay = (title + " " + detail).lowercased()
        return words.allSatisfy { hay.contains($0) }
    }
}

/// Палитра команд по ⌘K: вкладки, недавние сессии, действия окна и новые сессии в проектах.
struct PaletteView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var cursor = 0
    @FocusState private var focused: Bool

    var l: L { L(backend.state.lang) }

    private var items: [PaletteItem] {
        var out: [PaletteItem] = []
        for (i, tab) in workspace.tabs.enumerated() {
            out.append(PaletteItem(id: "tab-\(tab.id)", group: .tabs, title: tab.title,
                                   detail: tab.spec.projectName + " · " + l.statusTitle(tab.status),
                                   shortcut: i < 9 ? "⌘\(i + 1)" : "", icon: "terminal") {
                workspace.selected = tab.id
            })
        }
        for session in backend.state.sessions.prefix(40) {
            let project = backend.state.projects.first { session.cwd == $0.path || session.cwd.hasPrefix($0.path + "/") }
            guard let project else { continue }
            out.append(PaletteItem(id: "s-\(session.id)", group: .sessions,
                                   title: session.title.isEmpty ? l.untitled : session.title,
                                   detail: project.name + " · " + (workspace.liveElsewhere.contains(session.id)
                                       ? l.t("открыта в другом окне", "open in another window") : l.ago(session.mtime)),
                                   shortcut: "", icon: "text.bubble") {
                workspace.open(LaunchSpec(projectName: project.name, projectPath: project.path, resumeId: session.id))
            })
        }
        let actions: [(String, String, String, @MainActor () -> Void)] = [
            (l.newSession + "…", "⌘N", "plus", { ui.newSessionProject = workspace.current?.spec.projectPath; ui.showNewSession = true }),
            (l.t("Сессии", "Sessions"), "⇧⌘O", "books.vertical", { openWindow(id: "library") }),
            (l.t("Статистика", "Usage"), "⇧⌘U", "chart.bar.xaxis", { openWindow(id: "usage") }),
            (l.inspector, "⌥⌘I", "sidebar.right", { ui.showInspector.toggle() }),
            (l.t("Браузер через proxy", "Proxy browser"), "", "safari", {
                ProxyBrowser.shared.port = backend.state.proxy?.port ?? 17890
                ProxyBrowser.shared.open(URL(string: "https://1.1.1.1/cdn-cgi/trace")!)
            }),
            (l.t("К вкладке, которая ждет", "Jump to the waiting tab"), "⌘J", "bell", {
                if let tab = workspace.tabs.first(where: { $0.status == "waiting" }) { workspace.selected = tab.id }
            }),
            (l.restart, "⇧⌘R", "arrow.clockwise", { workspace.current?.restart() }),
            (l.closeTab, "⌘W", "xmark", { workspace.close(workspace.selected) }),
        ]
        for (i, a) in actions.enumerated() {
            out.append(PaletteItem(id: "a-\(i)", group: .actions, title: a.0, detail: "", shortcut: a.1, icon: a.2, run: a.3))
        }
        for project in backend.state.projects {
            out.append(PaletteItem(id: "p-\(project.path)", group: .projects,
                                   title: l.t("Новая сессия в ", "New session in ") + project.name,
                                   detail: l.t("через proxy", "via proxy"), shortcut: "", icon: "folder") {
                workspace.open(LaunchSpec(projectName: project.name, projectPath: project.path))
            })
        }
        return out
    }

    private var filtered: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let found = items.filter { $0.matches(q) }
        // без запроса проекты не нужны: их много, а новую сессию проще найти по имени
        return q.isEmpty ? found.filter { $0.group != .projects } : found
    }

    private func groupTitle(_ g: PaletteItem.Group) -> String {
        switch g {
        case .tabs: return l.t("Вкладки", "Tabs")
        case .sessions: return l.t("Сессии", "Sessions")
        case .actions: return l.t("Действия", "Actions")
        case .projects: return l.projects
        }
    }

    var body: some View {
        let list = filtered
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(l.t("Вкладка, сессия, действие или проект", "Tab, session, action or project"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(list) }
                    .onKeyPress(.downArrow) { cursor = min(cursor + 1, max(0, list.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { cursor = max(cursor - 1, 0); return .handled }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || list[index - 1].group != item.group {
                                Text(groupTitle(item.group))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, index == 0 ? 4 : 10)
                            }
                            PaletteRow(item: item, selected: index == cursor)
                                .id(item.id)
                                .onTapGesture { cursor = index; run(list) }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: cursor) {
                    if cursor < list.count { proxy.scrollTo(list[cursor].id, anchor: .center) }
                }
            }
            .overlay {
                if list.isEmpty { ContentUnavailableView.search(text: query) }
            }
        }
        .frame(width: 600, height: 440)
        .onChange(of: query) { cursor = 0 }
        .onAppear { focused = true }
    }

    private func run(_ list: [PaletteItem]) {
        guard cursor < list.count else { return }
        let item = list[cursor]
        dismiss()
        DispatchQueue.main.async { item.run() }
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .frame(width: 18)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(item.shortcut)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }
}
