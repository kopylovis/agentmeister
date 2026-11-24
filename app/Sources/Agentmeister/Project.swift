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

/// Экран проекта по макету Project.dc.html: где остановились, бэклог, параллельные задачи, инструменты.
/// Открывается кликом по проекту в боковой панели и закрывается при переходе к вкладке.
struct ProjectView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    let path: String
    @State private var data: ProjectData?
    @State private var newTask = ""
    /// Ширина области карточек: от нее зависит, две колонки или одна.
    @State private var width: CGFloat = 1000

    var l: L { L(backend.state.lang) }

    private var project: AppState.Project? { backend.state.projects.first { $0.path == path } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let data {
                    // две колонки, каждая заполняется сама: короткая карточка не оставляет дыру рядом с длинной
                    Group {
                        if width >= 700 {
                            HStack(alignment: .top, spacing: 16) {
                                VStack(spacing: 16) { leftOff(data); parallel(data) }
                                    .frame(maxWidth: .infinity)
                                VStack(spacing: 16) { backlog(data); tools(data) }
                                    .frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 16) {
                                leftOff(data); backlog(data); parallel(data); tools(data)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(24)
        }
        .task(id: path) { await reload() }
    }

    private func reload() async {
        data = await Backend.json(["app-state", "project", path])
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ProjectIconView(path: path, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(project?.name ?? (path as NSString).lastPathComponent).font(.system(size: 24, weight: .semibold))
                Text([tilde(path), data?.git?.branch, data?.git.map { $0.dirty == 0 ? l.t("без изменений", "clean") : "±\($0.dirty)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Ink.muted)
            }
            Spacer()
            Button {
                ui.projectScreen = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .help(l.t("Закрыть", "Close"))
            .opacity(workspace.tabs.isEmpty ? 0 : 1)
            if let last = data?.last {
                Button(l.resumeLast) { open(resume: last.id) }
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private func section<Content: View, Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory,
                                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                accessory()
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func leftOff(_ d: ProjectData) -> some View {
        section(l.t("Где остановились", "Where we left off"), accessory: { EmptyView() }) {
            if let last = d.last {
                Button {
                    open(resume: last.id)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionCaption(text: l.t("Прошлая сессия", "Last session"))
                        Text(last.title).fontWeight(.medium).foregroundStyle(Ink.text)
                        Text([last.last.map { l.agoLong($0) }, last.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(Ink.muted)
                        if !last.summary.isEmpty {
                            Text(last.summary).font(.system(size: 12)).foregroundStyle(Ink.text2).lineLimit(4)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l.t("Продолжить во вкладке", "Resume in a tab"))
            } else {
                Text(l.t("Сессий в этом проекте пока нет", "No sessions in this project yet")).foregroundStyle(Ink.muted)
            }
            if let commits = d.git?.commits, !commits.isEmpty {
                SectionCaption(text: l.t("Последние коммиты", "Recent commits"))
                ForEach(commits, id: \.self) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(c.sha).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.link)
                        Text(c.subject).font(.system(size: 12)).lineLimit(1)
                    }
                }
            }
        }
    }

    private func backlog(_ d: ProjectData) -> some View {
        let todos = d.todos ?? []
        let open = todos.filter { !$0.done }.count
        return section(l.t("Бэклог", "Backlog"), accessory: {
            Text(l.t("открыто \(open)", "\(open) open")).font(.system(size: 12)).foregroundStyle(Ink.muted)
        }) {
            HStack {
                TextField(l.t("Новая задача", "New task"), text: $newTask)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTask)
                Button(l.t("Добавить", "Add"), action: addTask)
                    .disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(todos, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        if let n = item.n { run(["todo", "-p", path, "done", String(n)]) }
                    } label: {
                        Image(systemName: item.done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(item.done ? Ink.faint : Ink.muted)
                    }
                    .buttonStyle(.plain)
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
            Text(l.t("Тот же бэклог видят /todo и агенты через MCP.", "The same backlog is shared with /todo and with agents through MCP."))
                .font(.system(size: 11)).foregroundStyle(Ink.faint)
        }
    }

    private func parallel(_ d: ProjectData) -> some View {
        let items = d.parallel ?? []
        return section(l.t("Параллельные задачи", "Parallel tasks"), accessory: {
            Button(l.t("Новая", "New")) {
                ui.newSessionProject = path
                ui.newSessionParallel = true
                ui.showNewSession = true
            }
            .controlSize(.small)
        }) {
            if items.isEmpty {
                Text(l.t("Сейчас ни одной", "None right now")).font(.system(size: 12)).foregroundStyle(Ink.muted)
            }
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
                            workspace.open(LaunchSpec(projectName: (project?.name ?? "") + " · " + e.branch, projectPath: e.path))
                            ui.projectScreen = nil
                        }
                        .controlSize(.small)
                        .disabled(tabOpen)
                        Menu(l.t("Завершить…", "Finish…")) {
                            Button(l.t("Через PR, дождаться CI и слить", "Through a PR, wait for CI and merge")) { utility(["parallel", "pr", e.branch, "-p", path]) }
                            Button(l.t("Влить локально", "Merge locally")) { utility(["parallel", "merge", e.branch, "-p", path]) }
                            Divider()
                            Button(l.t("Выбросить", "Drop"), role: .destructive) { utility(["parallel", "drop", e.branch, "-p", path]) }
                        }
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
            }
            Text(l.t("Каждая задача живет в своей ветке и worktree. Завершить можно слиянием в исходную ветку, через PR с ожиданием CI или выбросить. После этого worktree и ветка убираются.",
                     "Each task lives in its own branch and worktree. Finish by merging into the original branch, through a PR that waits for CI, or by dropping it. The worktree and branch are removed afterwards."))
                .font(.system(size: 11)).foregroundStyle(Ink.faint).lineLimit(4)
        }
    }

    private func tools(_ d: ProjectData) -> some View {
        section(l.t("Инструменты проекта", "Project tools"), accessory: { EmptyView() }) {
            toolRow(l.t("Заметки к релизу", "Release notes"), l.t("\"Что нового\" на русском и английском для fastlane", "\"What's new\" in Russian and English for fastlane"),
                    d.tools?.releaseSince.map { l.t("с тега ", "since ") + $0 } ?? "") { openWithPrompt("/release-notes") }
            toolRow(l.t("Устаревшие зависимости", "Outdated dependencies"), l.t("Gradle и libs.versions.toml", "Gradle and libs.versions.toml"),
                    d.tools?.gradle == true ? "" : l.t("нет Gradle", "no Gradle"), enabled: d.tools?.gradle == true) { utility(["deps", path]) }
            toolRow(l.t("Спросить другой проект", "Ask another project"), l.t("Отдельный Claude только на чтение", "A separate read-only Claude"), "⇧⌘A") {
                typeOrOpen("/ask ")
            }
            toolRow(l.t("Снимок окна", "Window screenshot"), l.t("Simulator, Chrome, любое приложение", "Simulator, Chrome, any app"), "⇧⌘S") {
                typeOrOpen("/shot ")
            }
        }
    }

    private func toolRow(_ title: String, _ desc: String, _ meta: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium).foregroundStyle(enabled ? Ink.text : Ink.faint)
                    Text(desc).font(.system(size: 12)).foregroundStyle(Ink.muted)
                }
                Spacer()
                Text(meta).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.faint)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Ink.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func open(resume id: String) {
        workspace.open(LaunchSpec(projectName: project?.name ?? (path as NSString).lastPathComponent, projectPath: path, resumeId: id))
        ui.projectScreen = nil
    }

    private func openWithPrompt(_ prompt: String) {
        var spec = LaunchSpec(projectName: project?.name ?? (path as NSString).lastPathComponent, projectPath: path)
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
