import SwiftUI

/// Строка палитры: что показать, что сделать по Enter и по ⌘Enter ("в новой вкладке").
struct PaletteItem: Identifiable {
    enum Group: Int { case sessions, thisSession, tools, projects }

    let id: String
    let group: Group
    let title: String
    let detail: String
    var shortcut = ""
    let run: @MainActor () -> Void
    /// ⌘Enter. Если nil, ⌘Enter делает то же, что Enter.
    var runInNewTab: (@MainActor () -> Void)?

    /// Подходит ли строка под запрос: все слова запроса есть в названии или подписи.
    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return true }
        let hay = (title + " " + detail).lowercased()
        return words.allSatisfy { hay.contains($0) }
    }
}

/// Палитра команд по ⌘K, как в макете Palette.dc.html: сессии (открытые вкладки и недавние), действия этой
/// сессии и инструменты agentmeister.
struct PaletteView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    @ObservedObject private var keys = ShortcutStore.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var cursor = 0
    @FocusState private var focused: Bool

    var l: L { L(backend.state.lang) }

    /// Текущая вкладка Claude Code, в которую палитра вписывает команды вроде /ask.
    private var claudeTab: TerminalTab? {
        guard let tab = workspace.current, tab.spec.utility == nil, tab.spec.agent == .claude, tab.running else { return nil }
        return tab
    }

    /// Новая вкладка Claude в проекте текущей вкладки с этим первым запросом.
    private func openWithPrompt(_ prompt: String) {
        guard let spec = workspace.current?.spec, spec.utility == nil else { return }
        var fresh = LaunchSpec(projectName: spec.projectName, projectPath: spec.projectPath, direct: spec.direct)
        fresh.firstPrompt = prompt
        workspace.open(fresh)
    }

    /// Инструмент-команда Claude Code: Enter вписывает ее в текущую вкладку, ⌘Enter открывает с ней новую.
    private func slash(_ id: String, _ title: String, _ detail: String, _ command: String, key: String = "") -> PaletteItem {
        PaletteItem(id: id, group: .tools, title: title, detail: detail, shortcut: key, run: {
            if let tab = claudeTab { tab.type(command) } else { openWithPrompt(command) }
        }, runInNewTab: { openWithPrompt(command) })
    }

    private var items: [PaletteItem] {
        var out: [PaletteItem] = []
        for (i, tab) in workspace.tabs.enumerated() {
            let saved = backend.state.sessions.first { $0.id == tab.sessionId }
            out.append(PaletteItem(id: "tab-\(tab.id)", group: .sessions,
                                   title: saved?.title.isEmpty == false ? saved!.title : tab.title,
                                   detail: tab.spec.projectName + " · " + l.t("открыта", "open"),
                                   shortcut: i < 9 ? "⌘\(i + 1)" : "") {
                // onChange(of: selected) не сработает, если вкладка уже выбрана, а экран проекта должен закрыться
                ui.projectScreen = nil
                workspace.selected = tab.id
            })
        }
        let open = Set(workspace.tabs.compactMap(\.sessionId))
        for session in backend.state.sessions.prefix(40) where !open.contains(session.id) {
            let project = backend.state.projects.first { session.cwd == $0.path || session.cwd.hasPrefix($0.path + "/") }
            guard let project else { continue }
            out.append(PaletteItem(id: "s-\(session.id)", group: .sessions,
                                   title: session.title.isEmpty ? l.untitled : session.title,
                                   detail: (session.kind == .codex ? "Codex · " : "") + project.name + " · "
                                       + (workspace.liveElsewhere.contains(session.id)
                                       ? l.t("открыта в другом окне", "open in another window") : l.agoLong(session.mtime))) {
                workspace.open(LaunchSpec.resume(session, project: project))
            })
        }

        let tab = workspace.current
        let claude = tab != nil && tab?.spec.utility == nil && tab?.spec.agent == .claude
        out.append(PaletteItem(id: "a-new", group: .thisSession, title: l.newSession, detail: "", shortcut: keys.label(.newSession)) {
            ui.newSessionProject = workspace.current?.spec.projectPath
            ui.showNewSession = true
        })
        if let tab {
            out.append(PaletteItem(id: "a-restart", group: .thisSession,
                                   title: claude && TerminalTab.restartUpdates ? l.t("Перезапустить с обновлением", "Restart with update") : l.restart,
                                   detail: claude && TerminalTab.restartUpdates ? "claude update" : "", shortcut: keys.label(.restart)) {
                tab.restartPreferred(note: l.updating)
            })
            if claude && tab.sessionId != nil {
                out.append(PaletteItem(id: "a-slim", group: .thisSession, title: l.slim,
                                       detail: l.t("убрать старые скриншоты и длинные выводы", "drop old screenshots and long outputs")) {
                    tab.slim(note: l.slimming)
                })
            }
            if tab.spec.utility == nil {
                out.append(PaletteItem(id: "a-fresh", group: .thisSession, title: l.t("С чистого листа", "Fresh start"),
                                       detail: l.t("эта сессия останется в списке", "this one stays in the list")) {
                    tab.fresh()
                })
            }
            if claude {
                out.append(PaletteItem(id: "a-forget", group: .thisSession, title: l.forget,
                                       detail: l.t("удалить без следа и открыть чистую", "delete without a trace and open a clean one")) {
                    ui.forgetting = tab
                })
            }
        }
        out.append(PaletteItem(id: "a-parallel", group: .thisSession, title: l.t("Параллельная задача", "Parallel task"),
                               detail: l.t("своя ветка и worktree", "own branch and worktree"), shortcut: keys.label(.parallel)) {
            ui.newSessionProject = workspace.current?.spec.projectPath
            ui.newSessionParallel = true
            ui.showNewSession = true
        })

        out.append(slash("t-ask", l.t("Спросить другой проект", "Ask another project"),
                         l.t("отдельный Claude только на чтение", "a separate read-only Claude"), "/ask ", key: keys.label(.ask)))
        out.append(slash("t-shot", l.t("Снимок окна", "Window screenshot"), "Simulator, Chrome, …", "/shot ", key: keys.label(.shot)))
        out.append(slash("t-release", l.t("Заметки к релизу", "Release notes"),
                         l.t("\"Что нового\" для fastlane", "\"What's new\" for fastlane"), "/release-notes"))
        out.append(PaletteItem(id: "t-deps", group: .tools, title: l.t("Устаревшие зависимости", "Outdated dependencies"), detail: "Gradle") {
            var spec = LaunchSpec(projectName: "agentmeister", projectPath: workspace.current?.spec.projectPath ?? NSHomeDirectory())
            spec.utility = ["deps"] + (workspace.current.map { [$0.spec.projectPath] } ?? [])
            workspace.open(spec)
        })
        out.append(slash("t-mac", l.t("Состояние Mac", "Mac status"), l.t("память, swap, диск", "memory, swap, disk"),
                         l.t("Покажи состояние Mac: память, swap, диск (mac_status)", "Show the Mac status: memory, swap, disk (mac_status)")))
        out.append(slash("t-free", l.t("Освободить память", "Free up memory"),
                         l.t("закрыть лишнее, сжать открытые сессии", "close extras, slim open sessions"),
                         l.t("Освободи память (free_memory)", "Free up memory (free_memory)")))
        out.append(PaletteItem(id: "t-usage", group: .tools, title: l.t("Статистика", "Usage"),
                               detail: l.t("токены и время", "tokens and time"), shortcut: keys.label(.usage)) {
            openWindow(id: "usage")
        })

        for project in backend.state.projects {
            out.append(PaletteItem(id: "p-\(project.path)", group: .projects,
                                   title: l.t("Новая сессия в ", "New session in ") + project.name,
                                   detail: backend.state.proxy?.defaultRoute == "direct" ? l.t("напрямую", "direct") : l.t("через proxy", "via proxy")) {
                workspace.open(LaunchSpec.quick(project, route: backend.state.proxy?.defaultRoute))
            })
        }
        return out
    }

    private var filtered: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let found = items.filter { $0.matches(q) }
        guard q.isEmpty else { return found }
        // без запроса проекты не нужны, а недавних сессий хватит пяти: остальные находятся по словам
        var recent = 0
        return found.filter { item in
            if item.group == .projects { return false }
            if item.id.hasPrefix("s-") { recent += 1; return recent <= 5 }
            return true
        }
    }

    private func groupTitle(_ g: PaletteItem.Group) -> String {
        switch g {
        case .sessions: return l.t("Сессии", "Sessions")
        case .thisSession: return l.t("Эта сессия", "This session")
        case .tools: return l.t("Инструменты", "Tools")
        case .projects: return l.projects
        }
    }

    var body: some View {
        let list = filtered
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(Ink.muted)
                TextField(l.t("Сессия, действие или инструмент", "Session, action or tool"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { run(list, newTab: false) }
                    .onKeyPress(.downArrow) { cursor = min(cursor + 1, max(0, list.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { cursor = max(cursor - 1, 0); return .handled }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        run(list, newTab: true)
                        return .handled
                    }
                    .accessibilityLabel(l.t("Палитра команд", "Command palette"))
                Text("esc").font(.system(size: 11)).foregroundStyle(Ink.faint)
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            Rectangle().fill(Ink.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || list[index - 1].group != item.group {
                                SectionCaption(text: groupTitle(item.group))
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)
                            }
                            PaletteRow(item: item, selected: index == cursor)
                                .id(item.id)
                                .onTapGesture { cursor = index; run(list, newTab: false) }
                        }
                        if list.isEmpty {
                            Text(l.t("Ничего не нашлось", "Nothing found"))
                                .foregroundStyle(Ink.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: cursor) {
                    if cursor < list.count { proxy.scrollTo(list[cursor].id, anchor: .center) }
                }
            }
            Rectangle().fill(Ink.hairline).frame(height: 1)
            HStack(spacing: 16) {
                Text("↑↓ " + l.t("выбрать", "select"))
                Text("↩ " + l.t("выполнить", "run"))
                Text("⌘↩ " + l.t("в новой вкладке", "in a new tab"))
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(Ink.faint)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 600, height: 520)
        .onChange(of: query) { cursor = 0 }
        .onAppear { focused = true }
    }

    private func run(_ list: [PaletteItem], newTab: Bool) {
        guard cursor < list.count else { return }
        let item = list[cursor]
        dismiss()
        DispatchQueue.main.async { (newTab ? item.runInNewTab ?? item.run : item.run)() }
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .fontWeight(.medium)
                    .foregroundStyle(selected ? Ink.strong : Ink.text)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.system(size: 12)).foregroundStyle(Ink.muted).lineLimit(1)
                }
            }
            Spacer()
            Text(item.shortcut)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Ink.faint)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Ink.hover : .clear))
        .contentShape(Rectangle())
    }
}
