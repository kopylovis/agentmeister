import AppKit
import SwiftUI

/// Ответ agentmeister app-state project.
struct ProjectData: Decodable {
    struct Git: Decodable {
        struct Commit: Decodable, Hashable { let sha: String; let time: Int?; let subject: String }
        let branch: String?
        let dirty: Int
        let commits: [Commit]
    }

    struct Last: Decodable {
        let id: String
        let title: String
        let last: Double?
        let size: Int?
        let summary: String
    }

    struct Todo: Decodable, Hashable {
        let n: Int?
        let text: String
        let done: Bool
    }

    struct Parallel: Decodable, Hashable {
        let branch: String
        let task: String
        let ahead: String?
        let dirty: Int
        let running: Bool
        let path: String
    }

    struct Tools: Decodable {
        let releaseSince: String?
        let gradle: Bool?
    }

    let path: String
    let name: String
    let git: Git?
    let last: Last?
    let todos: [Todo]?
    let parallel: [Parallel]?
    let tools: Tools?
}

/// Экран проекта. Слева поле новой сессии и список сессий, справа действия и инструменты, бэклог,
/// параллельные задачи и коммиты. Открывается кликом по проекту в боковой панели и закрывается
/// при переходе к вкладке.
struct ProjectView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    let path: String
    @State private var data: ProjectData?
    @State private var newTask = ""
    /// Ширина экрана: от нее зависит, две колонки или одна.
    @State private var width: CGFloat = 1000
    @State private var moreSessions = false

    // поле новой сессии
    @State private var prompt = ""
    @State private var agent: LaunchSpec.Agent = .claude
    @State private var direct = false
    @State private var asParallel = false
    @State private var starting = false
    @State private var startError: String?
    @FocusState private var promptFocused: Bool

    var l: L { L(backend.state.lang) }

    private var project: AppState.Project? { backend.state.projects.first { $0.path == path } }
    private var name: String { project?.name ?? (path as NSString).lastPathComponent }

    var body: some View {
        ScrollView {
            Group {
                if width >= 760 {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        HStack(alignment: .top, spacing: 28) {
                            VStack(alignment: .leading, spacing: 26) { composer; sessions }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            VStack(alignment: .leading, spacing: 26) { actions; details }
                                .frame(width: min(380, max(290, width * 0.32)), alignment: .topLeading)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        header; composer; actions; sessions; details
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .task(id: path) {
            prompt = ""
            startError = nil
            asParallel = false
            agent = AgentPrefs.defaultAgent == "codex" ? .codex : .claude
            direct = backend.state.proxy?.defaultRoute == "direct"
            await reload()
        }
        // Esc закрывает экран проекта и возвращает вкладки. Листы и поповеры живут в своих окнах,
        // так что там Esc закрывает их, а не этот экран.
        .background {
            Button("") { ui.projectScreen = nil }
                .keyboardShortcut(.cancelAction)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private func reload() async {
        data = await Backend.json(["app-state", "project", path])
    }

    // MARK: - Шапка

    private var header: some View {
        let openTabs = workspace.tabs.filter { $0.running && $0.spec.utility == nil
            && backend.state.project(containing: $0.spec.projectPath)?.path == path }
        return HStack(alignment: .center, spacing: 14) {
            ProjectIconView(path: path, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 24, weight: .semibold))
                Text([tilde(path), data?.git?.branch, data?.git.map { $0.dirty == 0 ? l.t("без изменений", "clean") : "±\($0.dirty)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Ink.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let first = openTabs.first {
                Button {
                    workspace.selected = first.id
                    ui.projectScreen = nil
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(Ink.tealDot).frame(width: 7, height: 7)
                        Text(l.count(openTabs.count, "вкладка открыта", "вкладки открыты", "вкладок открыто", "open tab", "open tabs"))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.teal)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(Ink.tealChip))
                    .contentShape(Capsule())
                }
                .buttonStyle(.hoverCapsule(.overlay))
                .help(l.t("Перейти к вкладке", "Go to the tab"))
            }
        }
    }

    // MARK: - Новая сессия

    private var composer: some View {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let exit = backend.state.proxy?.exit
        return VStack(alignment: .leading, spacing: 10) {
            Text(asParallel ? l.t("Параллельная задача в \(name)", "Parallel task in \(name)")
                            : l.t("Новая сессия в \(name)", "New session in \(name)"))
                .font(.system(size: 12))
                .foregroundStyle(Ink.muted)
            TextEditor(text: $prompt)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .focused($promptFocused)
                .frame(height: 64)
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text(asParallel
                             ? l.t("Что сделать в своей ветке. Без задачи параллельную не начать.",
                                   "What to do in its own branch. A parallel task needs one.")
                             : l.t("Что сделать агенту. Текст станет первым запросом, можно оставить пустым.",
                                   "What should the agent do? The text becomes the first prompt, or leave it empty."))
                            .font(.system(size: 14))
                            .foregroundStyle(Ink.faint)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Menu {
                    Button("Claude Code") { agent = .claude }
                    Button("Codex") { agent = .codex; asParallel = false }
                } label: {
                    chip(agent == .codex ? "Codex" : "Claude Code",
                         fg: agent == .codex ? Ink.codexBadge : Ink.claudeBadge,
                         bg: agent == .codex ? Ink.codexBadgeBg : Ink.claudeBadgeBg)
                }
                .menuStyle(.button)
                .buttonStyle(.hoverCapsule(.overlay))
                .menuIndicator(.hidden)
                .fixedSize()
                .help(l.agent)
                Menu {
                    Button(l.t("Через proxy", "Via proxy") + (exit.map { " " + $0 } ?? "")) { direct = false }
                    Button(l.directly) { direct = true }
                } label: {
                    chip(direct ? l.directly : "proxy" + (exit.map { " " + $0 } ?? ""),
                         fg: direct ? Ink.direct : Ink.teal,
                         bg: direct ? Ink.amberDot.opacity(0.16) : Ink.tealChip)
                }
                .menuStyle(.button)
                .buttonStyle(.hoverCapsule(.overlay))
                .menuIndicator(.hidden)
                .fixedSize()
                .help(direct ? l.directWarning : l.route)
                Toggle(l.t("В своем worktree, параллельной задачей", "In its own worktree, as a parallel task"), isOn: $asParallel)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(agent == .claude ? Ink.text2 : Ink.faint)
                    .disabled(agent != .claude)
                    .help(agent == .claude
                          ? l.t("Своя ветка и worktree. Готовую задачу вливают в исходную ветку, через PR или выбрасывают.",
                                "Its own branch and worktree. Finish by merging into the original branch, through a PR, or by dropping it.")
                          : l.t("Параллельные задачи пока только у Claude Code", "Parallel tasks are Claude Code only for now"))
                    .padding(.leading, 4)
                Spacer(minLength: 8)
                PillButton(title: l.t("Начать  ⌘↩", "Start  ⌘↩"), prominent: true, busy: starting) { start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(project == nil || starting || (asParallel && trimmed.isEmpty))
            }
            if let startError {
                Text(startError).font(.system(size: 12)).foregroundStyle(Ink.red)
            } else if direct {
                Text(l.directWarning).font(.system(size: 11)).foregroundStyle(Ink.amber)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Ink.card))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(promptFocused ? Ink.modeOnBorder : Ink.hairline))
    }

    private func chip(_ text: String, fg: Color, bg: Color) -> some View {
        HStack(spacing: 5) {
            Text(text)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 12))
        .foregroundStyle(fg)
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(Capsule().fill(bg))
        .contentShape(Capsule())
    }

    private func start() {
        guard let project else { return }
        var spec = LaunchSpec(projectName: project.name, projectPath: project.path, agent: agent, direct: direct)
        spec.remoteControl = agent == .claude
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        startError = nil
        guard asParallel else {
            spec.firstPrompt = task
            workspace.open(spec)
            prompt = ""
            ui.projectScreen = nil
            return
        }
        starting = true
        Task {
            startError = await workspace.openParallel(spec, project: project, task: task, state: backend.state, l: l)
            starting = false
            if startError == nil {
                prompt = ""
                ui.projectScreen = nil
            }
        }
    }

    // MARK: - Сессии

    private var sessions: some View {
        let all = project.map { backend.state.sessions(in: $0) } ?? []
        let shown = all.prefix(moreSessions ? 40 : 6)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                heading(l.t("Сессии", "Sessions"))
                Spacer()
                if all.count > 6 {
                    Button(moreSessions ? l.t("Свернуть", "Fewer") : l.t("Еще", "More")) { moreSessions.toggle() }
                        .buttonStyle(.textLink)
                        .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            if let project, !all.isEmpty {
                ForEach(shown) { session in
                    // хвост переписки только у закрытой: у идущей во вкладке он меняется на глазах и ничего не говорит
                    let open = workspace.tabs.contains { $0.sessionId == session.id && $0.running }
                    ProjectSessionRow(session: session, project: project,
                                      summary: !open && session.id == data?.last?.id ? data?.last?.summary : nil)
                }
            } else {
                Text(l.t("Сессий в этом проекте пока нет. Напишите задачу выше, чтобы начать первую.",
                         "No sessions in this project yet. Write a task above to start the first one."))
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.muted)
                    .padding(.horizontal, 12)
            }
        }
    }

    // MARK: - Действия и инструменты

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            actionButton(l.t("Новая сессия…", "New session…"), icon: "plus", shortcut: .newSession, prominent: true) {
                ui.newSessionProject = path
                ui.newSessionParallel = false
                ui.showNewSession = true
            }
            actionButton(l.t("Параллельная задача…", "Parallel task…"), icon: "arrow.triangle.branch", shortcut: .parallel) {
                ui.newSessionProject = path
                ui.newSessionParallel = true
                ui.showNewSession = true
            }
            SectionCaption(text: l.t("ИНСТРУМЕНТЫ", "TOOLS"))
                .padding(.top, 14)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
            toolRow(l.t("Спросить другой проект", "Ask another project"), l.t("Отдельный Claude только на чтение", "A separate read-only Claude"),
                    ShortcutStore.shared.label(.ask)) { typeOrOpen("/ask ") }
            toolRow(l.t("Снимок окна", "Window screenshot"), l.t("Simulator, Chrome, любое приложение", "Simulator, Chrome, any app"),
                    ShortcutStore.shared.label(.shot)) { typeOrOpen("/shot ") }
            toolRow(l.t("Заметки к релизу", "Release notes"), l.t("\"Что нового\" на русском и английском для fastlane", "\"What's new\" in Russian and English for fastlane"),
                    data?.tools?.releaseSince.map { l.t("с ", "since ") + $0 } ?? "") { openWithPrompt("/release-notes") }
            toolRow(l.t("Устаревшие зависимости", "Outdated dependencies"), l.t("Gradle и libs.versions.toml", "Gradle and libs.versions.toml"),
                    data?.tools?.gradle == true ? "" : l.t("нет Gradle", "no Gradle"), enabled: data?.tools?.gradle == true) { utility(["deps", path]) }
        }
    }

    private func actionButton(_ title: String, icon: String, shortcut: ShortcutAction, prominent: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).frame(width: 16)
                Text(title).fontWeight(prominent ? .semibold : .regular)
                Spacer()
                Text(ShortcutStore.shared.label(shortcut)).font(.system(size: 12)).opacity(0.75)
            }
            .font(.system(size: 13))
            .foregroundStyle(prominent ? Color.white : Ink.text)
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(prominent ? Color.accentColor : Ink.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover(12, .overlay))
    }

    private func toolRow(_ title: String, _ desc: String, _ meta: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(enabled ? Ink.text2 : Ink.faint)
                Spacer()
                Text(meta).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.faint)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover(10))
        .disabled(!enabled)
        .help(desc)
    }

    // MARK: - Бэклог, параллельные задачи, коммиты

    @ViewBuilder private var details: some View {
        if let data {
            backlog(data)
            parallel(data)
            commits(data)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    private func heading(_ title: String, _ trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(Ink.faint) }
        }
    }

    private func backlog(_ d: ProjectData) -> some View {
        let todos = d.todos ?? []
        let open = todos.filter { !$0.done }.count
        return VStack(alignment: .leading, spacing: 10) {
            heading(l.t("Бэклог", "Backlog"), l.t("открыто \(open)", "\(open) open"))
                .help(l.t("Тот же бэклог видят /todo и агенты через MCP.", "The same backlog is shared with /todo and with agents through MCP."))
            TextField(l.t("Добавить задачу", "Add a task"), text: $newTask)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTask)
            ForEach(todos, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        if let n = item.n { run(["todo", "-p", path, "done", String(n)]) }
                    } label: {
                        Image(systemName: item.done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(item.done ? Ink.faint : Ink.muted)
                    }
                    .buttonStyle(.hover(4))
                    .disabled(item.done)
                    Text(item.text)
                        .font(.system(size: 12))
                        .strikethrough(item.done)
                        .foregroundStyle(item.done ? Ink.faint : Ink.text)
                    Spacer()
                    if let n = item.n {
                        Text("#\(n)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.faint)
                    }
                }
            }
        }
    }

    private func parallel(_ d: ProjectData) -> some View {
        let items = d.parallel ?? []
        return VStack(alignment: .leading, spacing: 10) {
            heading(l.t("Параллельные задачи", "Parallel tasks"), items.isEmpty ? l.t("ни одной", "none") : nil)
                .help(l.t("Каждая задача живет в своей ветке и worktree. Завершить можно слиянием в исходную ветку, через PR с ожиданием CI или выбросить. После этого worktree и ветка убираются.",
                          "Each task lives in its own branch and worktree. Finish by merging into the original branch, through a PR that waits for CI, or by dropping it. The worktree and branch are removed afterwards."))
            ForEach(items, id: \.self) { e in
                let tabOpen = workspace.tabs.contains { $0.spec.projectPath == e.path && $0.running }
                let ahead = Int(e.ahead ?? "") ?? 0
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        GlowDot(color: e.running ? Ink.tealDot : Color(hex: 0x7C8BFF), glow: e.running)
                        Text(e.branch).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Text(e.running ? l.t("идет", "running") : l.t("готово", "done"))
                            .font(.system(size: 11)).foregroundStyle(e.running ? Ink.teal : Ink.muted)
                    }
                    if !e.task.isEmpty { Text(e.task).font(.system(size: 12)).lineLimit(2) }
                    Text([l.count(ahead, "коммит", "коммита", "коммитов", "commit", "commits"),
                          tabOpen ? l.t("вкладка открыта", "tab open") : e.running ? l.t("сессия идет", "session running") : l.t("сессия закрыта", "session closed"),
                          e.dirty > 0 ? l.t("незакоммичено \(e.dirty)", "\(e.dirty) uncommitted") : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Ink.muted)
                    HStack(spacing: 6) {
                        Button(l.t("Открыть вкладку", "Open tab")) {
                            workspace.open(LaunchSpec(projectName: name + " · " + e.branch, projectPath: e.path))
                            ui.projectScreen = nil
                        }
                        .buttonStyle(PillStyle(small: true))
                        .disabled(tabOpen)
                        Menu(l.t("Завершить…", "Finish…")) {
                            Button(l.t("Через PR, дождаться CI и слить", "Through a PR, wait for CI and merge")) { utility(["parallel", "pr", e.branch, "-p", path]) }
                            Button(l.t("Влить локально", "Merge locally")) { utility(["parallel", "merge", e.branch, "-p", path]) }
                            Divider()
                            Button(l.t("Выбросить", "Drop"), role: .destructive) { utility(["parallel", "drop", e.branch, "-p", path]) }
                        }
                        .menuStyle(.button)
                        .buttonStyle(PillStyle(small: true))
                        .fixedSize()
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
            }
        }
    }

    @ViewBuilder private func commits(_ d: ProjectData) -> some View {
        if let commits = d.git?.commits, !commits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                heading(l.t("Последние коммиты", "Recent commits"))
                ForEach(commits, id: \.self) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(c.sha).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.link)
                        Text(c.subject).font(.system(size: 12)).foregroundStyle(Ink.text2).lineLimit(1)
                    }
                    .help(c.subject)
                }
            }
        }
    }

    // MARK: - Запуск

    private func openWithPrompt(_ prompt: String) {
        var spec = LaunchSpec(projectName: name, projectPath: path)
        spec.firstPrompt = prompt
        workspace.open(spec)
        ui.projectScreen = nil
    }

    /// Вписать команду в открытую вкладку Claude этого проекта, иначе открыть новую с ней.
    private func typeOrOpen(_ command: String) {
        if let tab = workspace.tabs.first(where: { $0.spec.projectPath == path && $0.spec.agent == .claude && $0.spec.utility == nil && $0.running }) {
            workspace.selected = tab.id
            tab.type(command)
            ui.projectScreen = nil
        } else {
            openWithPrompt(command)
        }
    }

    private func utility(_ args: [String]) {
        var spec = LaunchSpec(projectName: "agentmeister", projectPath: path)
        spec.utility = args
        workspace.open(spec)
        ui.projectScreen = nil
    }

    private func addTask() {
        let text = newTask.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        newTask = ""
        run(["todo", "-p", path, "add", text])
    }

    private func run(_ args: [String]) {
        Task {
            _ = await backend.perform(args)
            await reload()
        }
    }
}

/// Сессия в списке экрана проекта. Открытая во вкладке переключает на вкладку, закрытая продолжается
/// кнопкой или показывает переписку по клику.
struct ProjectSessionRow: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    let session: AppState.Session
    let project: AppState.Project
    /// Хвост переписки последней сессии, у остальных нет.
    let summary: String?
    @State private var hover = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        let tab = workspace.tabs.first { $0.sessionId == session.id && $0.running }
        let live = backend.state.live.first { $0.sessionId == session.id }
        let status = tab?.status ?? live?.status
        let elsewhere = live != nil && tab == nil
        let meta = tab != nil ? l.t("открыта во вкладке", "open in a tab")
            : elsewhere ? l.t("открыта в другом окне", "open in another window")
            : l.agoLong(session.mtime) + " · " + ByteCountFormatter.string(fromByteCount: Int64(session.size), countStyle: .file)
        HStack(spacing: 12) {
            Button {
                if tab != nil {
                    resume()
                } else {
                    ui.projectScreen = nil
                    ui.sessionPreview = session.id
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    SessionDot(status: status, open: status != nil || tab != nil, size: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if session.kind == .codex { AgentBadge(agent: .codex, size: 14) }
                            Text(session.title.isEmpty ? l.untitled : session.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Ink.text)
                                .lineLimit(1)
                        }
                        Text(meta)
                            .font(.system(size: 12))
                            .foregroundStyle(tab != nil ? Ink.teal : Ink.muted)
                        if let summary, !summary.isEmpty {
                            Text(summary).font(.system(size: 12)).foregroundStyle(Ink.text2).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if tab != nil {
                PillButton(title: l.t("К вкладке", "Go to tab"), small: true) { resume() }
            } else if !elsewhere && hover {
                PillButton(title: l.resume, prominent: true, small: true) { resume() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tab != nil ? Ink.card : hover ? Ink.hover : .clear))
        .onHover { hover = $0 }
        .contextMenu {
            if !elsewhere { Button(l.resume) { resume() } }
            Button(l.t("Показать переписку", "Show the conversation")) {
                ui.projectScreen = nil
                ui.sessionPreview = session.id
            }
        }
        .help(elsewhere ? l.t("Открыта в другом окне", "Open in another window")
              : tab != nil ? l.t("Перейти к вкладке", "Go to the tab")
              : l.t("Показать переписку, продолжить оттуда", "Show the conversation and resume from there"))
    }

    private func resume() {
        ui.projectScreen = nil
        workspace.open(LaunchSpec.resume(session, project: project))
    }
}
