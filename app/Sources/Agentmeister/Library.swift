import AppKit
import SwiftUI

/// Строка библиотеки: сохраненная сессия или найденная поиском.
struct LibraryRow: Identifiable, Hashable {
    let id: String
    let title: String
    let home: String
    let time: Double?
    let size: Int?
    let hits: [SearchResults.Hit]
    let count: Int

    var project: String { (home as NSString).lastPathComponent }
}

/// Окно "Сессии" по макету Sessions.dc.html: проекты и фильтры слева, поиск и список посередине,
/// превью с действиями справа. Замена agentmeister sessions.
struct LibraryView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @Environment(\.openWindow) private var openWindow

    // запрос и выбранная сессия переживают закрытие окна и перезапуск
    @AppStorage("libraryQuery") private var query = ""
    /// Путь проекта, "!open" для открытых сейчас, "!gone" для сессий без папки проекта, nil для всех.
    @State private var filter: String?
    @State private var found: SearchResults?
    @State private var searching = false
    @AppStorage("librarySelection") private var storedSelection = ""
    @State private var selection: String?
    @State private var preview: SessionPreview?
    @State private var confirmDelete = false
    @State private var renaming = false

    var l: L { L(backend.state.lang) }

    private var liveIds: Set<String> { Set(backend.state.live.compactMap(\.sessionId)) }
    private var goneIds: Set<String> { Set(backend.state.sessions.filter { $0.cwdExists == false }.map(\.id)) }

    private var rows: [LibraryRow] {
        let all: [LibraryRow]
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            all = backend.state.sessions.map {
                LibraryRow(id: $0.id, title: $0.title, home: $0.cwd, time: $0.mtime, size: $0.size, hits: [], count: 0)
            }
        } else {
            all = (found?.results ?? []).map {
                LibraryRow(id: $0.id, title: $0.title, home: $0.home, time: $0.last, size: $0.size, hits: $0.hits, count: $0.count)
            }
        }
        switch filter {
        case nil: return all
        case "!open": return all.filter { liveIds.contains($0.id) }
        case "!gone": return all.filter { goneIds.contains($0.id) }
        case let path?: return all.filter { $0.home == path || $0.home.hasPrefix(path + "/") }
        }
    }

    private var projectsWithSessions: [(AppState.Project, Int)] {
        backend.state.projects.compactMap { p in
            let n = backend.state.sessions(in: p).count
            return n > 0 ? (p, n) : nil
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $filter) {
                    Section {
                        Label(l.t("Все проекты", "All projects"), systemImage: "tray.full")
                            .badge(backend.state.sessions.count)
                            .tag(nil as String?)
                        ForEach(projectsWithSessions, id: \.0.path) { project, count in
                            Label(project.name, systemImage: "folder")
                                .badge(count)
                                .tag(project.path as String?)
                        }
                    } header: { SectionCaption(text: l.projects) }
                    Section {
                        Label(l.t("Открытые сейчас", "Open now"), systemImage: "dot.radiowaves.left.and.right")
                            .badge(backend.state.sessions.filter { liveIds.contains($0.id) }.count)
                            .tag("!open" as String?)
                        Label(l.t("Проекта больше нет", "Project folder gone"), systemImage: "folder.badge.questionmark")
                            .badge(goneIds.count)
                            .tag("!gone" as String?)
                    } header: { SectionCaption(text: l.t("Показать", "Show")) }
                }
                .listStyle(.sidebar)
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.faint)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } content: {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Ink.muted)
                    TextField(l.t("Слова из переписки, любой проект", "Words from any conversation, any project"), text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityLabel(l.t("Поиск по всем сессиям", "Search all sessions"))
                    if let found, !query.isEmpty {
                        Text(l.t("найдено \(found.results.count)", "\(found.results.count) found"))
                            .font(.system(size: 11)).foregroundStyle(Ink.faint)
                    } else if searching {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .glassEffect(.regular, in: .capsule)
                HStack {
                    Text(filterTitle).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    UtilityButton(title: l.t("Очистить лишние", "Clean up"), args: ["sessions", "clean"])
                        .controlSize(.small)
                        .help(l.t("Битые ссылки, сессии без ответа, папки удаленных проектов. Сначала покажет список.",
                                  "Broken links, sessions without a reply, folders of deleted projects. Shows the list first."))
                }
                List(rows, selection: $selection) { row in
                    LibraryRowView(row: row, query: query, open: liveIds.contains(row.id))
                        .tag(row.id)
                }
                .overlay {
                    if rows.isEmpty {
                        if searching {
                            ProgressView()
                        } else if !query.isEmpty {
                            ContentUnavailableView.search(text: query)
                        } else {
                            ContentUnavailableView(l.t("Сессий нет", "No sessions"), systemImage: "tray")
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .navigationSplitViewColumnWidth(min: 380, ideal: 480, max: 680)
        } detail: {
            if let preview, let id = preview.id {
                PreviewView(preview: preview, sessionId: id, size: backend.state.sessions.first { $0.id == id }?.size,
                            onResume: { resume(awake: $0) }, onDelete: { confirmDelete = true },
                            onRename: { renaming = true }, onMove: move, onSlim: slim,
                            onReadAll: { readAll(id) })
            } else {
                ContentUnavailableView(l.t("Выбери сессию", "Pick a session"), systemImage: "text.bubble")
            }
        }
        .navigationTitle(l.t("Сессии", "Sessions"))
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { found = nil; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let result = await backend.search(q)
            guard !Task.isCancelled else { return }
            found = result
            searching = false
        }
        .task(id: selection) { await loadPreview() }
        .onAppear { if selection == nil, !storedSelection.isEmpty { selection = storedSelection } }
        .confirmationDialog(l.t("Удалить сессию?", "Delete the session?"), isPresented: $confirmDelete) {
            Button(l.t("Удалить", "Delete"), role: .destructive) { delete() }
        } message: {
            Text(l.t("Удалятся переписка, история правок и строки в history.jsonl. Вернуть нельзя.",
                     "The transcript, its file history and its lines in history.jsonl are removed. This can't be undone."))
        }
        .sheet(isPresented: $renaming) {
            if let id = preview?.id {
                RenameSessionSheet(id: id, current: preview?.title ?? "") { Task { await loadPreview(); backend.refresh() } }
            }
        }
        .frame(minWidth: 1000, minHeight: 580)
        .onAppear { WindowMemory.set("library", open: true) }
        .onDisappear { WindowMemory.set("library", open: false) }
    }

    private var filterTitle: String {
        switch filter {
        case nil: return l.t("Все проекты", "All projects")
        case "!open": return l.t("Открытые сейчас", "Open now")
        case "!gone": return l.t("Проекта больше нет", "Project folder gone")
        case let path?: return (path as NSString).lastPathComponent
        }
    }

    /// "14 сессий, 245 MB в ~/.claude/projects. Переписки хранятся 365 дней."
    private var footer: String {
        let n = backend.state.sessions.count
        let bytes = backend.state.sessions.reduce(0) { $0 + $1.size }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let days = backend.state.retentionDays ?? 30
        return l.t("\(l.count(n, "сессия", "сессии", "сессий", "session", "sessions")), \(size) в ~/.claude/projects. Переписки хранятся \(days) дней.",
                   "\(l.count(n, "сессия", "сессии", "сессий", "session", "sessions")), \(size) in ~/.claude/projects. Transcripts are kept for \(days) days.")
    }

    private func loadPreview() async {
        preview = nil
        storedSelection = selection ?? ""
        guard let id = selection else { return }
        preview = await backend.read(id)
    }

    private func resume(awake: Bool) {
        guard let id = preview?.id else { return }
        let home = preview?.home ?? ""
        let project = backend.state.projects.first { home == $0.path || home.hasPrefix($0.path + "/") }
        let path = project?.path ?? home
        let name = project?.name ?? (home as NSString).lastPathComponent
        var spec = LaunchSpec(projectName: name, projectPath: path, resumeId: id)
        spec.awake = awake
        workspace.open(spec)
        openWindow(id: "main")
    }

    private func delete() {
        guard let id = preview?.id else { return }
        Task {
            if await backend.perform(["sessions", "rm", id, "-y"]) {
                selection = nil
                preview = nil
                if !query.isEmpty { found = await backend.search(query) }
            }
        }
    }

    /// Перенести в другую папку: agentmeister sessions mv переписывает cwd внутри сессии.
    private func move() {
        guard let id = preview?.id else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = l.t("Перенести", "Move")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            _ = await backend.perform(["sessions", "mv", id, url.path])
            await loadPreview()
        }
    }

    private func slim() {
        guard let id = preview?.id else { return }
        Task {
            _ = await backend.perform(["sessions", "slim", id, "-y"])
            await loadPreview()
        }
    }

    /// Вся переписка служебной вкладкой: agentmeister sessions show.
    private func readAll(_ id: String) {
        var spec = LaunchSpec(projectName: "agentmeister", projectPath: NSHomeDirectory())
        spec.utility = ["sessions", "show", id]
        workspace.open(spec)
        openWindow(id: "main")
    }
}

/// Строка списка: значок агента, название, чип "открыта", справа проект, время и размер; ниже совпадение.
struct LibraryRowView: View {
    @EnvironmentObject var backend: Backend
    let row: LibraryRow
    let query: String
    let open: Bool

    var l: L { L(backend.state.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AgentBadge(agent: .claude, size: 18)
                Text(row.title.isEmpty ? l.untitled : row.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if open {
                    Text(l.t("открыта", "open"))
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.teal)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Capsule().fill(Ink.tealChip))
                }
                Spacer(minLength: 8)
                Text([row.project, row.time.map { l.agoLong($0) },
                      row.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.faint)
                    .lineLimit(1)
            }
            if let hit = row.hits.first {
                Text(highlight(hit.snippet, query: query))
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.muted)
                    .lineLimit(2)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Подсветить слова запроса. Поиск идет по основам слов, поэтому подсвечивается начало слова без окончания.
func highlight(_ text: String, query: String) -> AttributedString {
    var out = AttributedString(text)
    let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" })
    let lower = text.lowercased()
    for word in words where word.count >= 3 {
        let stem = String(word.prefix(max(3, word.count - 2)))
        var from = lower.startIndex
        while let range = lower.range(of: stem, range: from..<lower.endIndex) {
            if let start = AttributedString.Index(range.lowerBound, within: out),
               let end = AttributedString.Index(range.upperBound, within: out) {
                out[start..<end].foregroundColor = .primary
                out[start..<end].backgroundColor = Color.orange.opacity(0.28)
            }
            from = range.upperBound
        }
    }
    return out
}

struct PreviewView: View {
    @EnvironmentObject var backend: Backend
    let preview: SessionPreview
    let sessionId: String
    let size: Int?
    let onResume: (Bool) -> Void
    let onDelete: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onSlim: () -> Void
    let onReadAll: () -> Void

    var l: L { L(backend.state.lang) }

    var body: some View {
        let live = backend.state.live.contains { $0.sessionId == sessionId }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SectionCaption(text: l.t("Сессия", "Session"))
                Text(preview.title ?? l.untitled)
                    .font(.system(size: 17, weight: .semibold))
                    .textSelection(.enabled)
                Text([String(sessionId.prefix(8)), tilde(preview.home ?? ""),
                      size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Ink.muted)
                    .textSelection(.enabled)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(preview.messages ?? []) { message in
                            MessageView(message: message)
                                .id(message.at)
                        }
                    }
                    .padding(12)
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.card))
                .onAppear { if let last = preview.messages?.last { proxy.scrollTo(last.at, anchor: .bottom) } }
            }
            HStack(spacing: 8) {
                Button(l.resume) { onResume(false) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                Button(l.t("Продолжить, не давая Mac уснуть", "Resume and keep the Mac awake")) { onResume(true) }
                    .buttonStyle(.glass)
            }
            FlowLayout(spacing: 6) {
                CapsuleButton(title: l.rename, action: onRename)
                CapsuleButton(title: l.t("Перенести в папку", "Move to folder"), action: onMove)
                    .disabled(live)
                CapsuleButton(title: l.slim, action: onSlim)
                    .disabled(live)
                CapsuleButton(title: l.t("Удалить", "Delete"), destructive: true, action: onDelete)
                    .disabled(live)
                CapsuleButton(title: l.t("Скопировать id", "Copy id")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sessionId, forType: .string)
                }
            }
            if live {
                Text(l.t("Сессия сейчас открыта: перенести, сжать и удалить можно после того, как ее закроют.",
                         "The session is open now: move, slim and delete work once it is closed."))
                    .font(.system(size: 12)).foregroundStyle(Ink.amber).lineLimit(2)
            }
            Text(l.t("Перенос меняет папку сессии и ее cwd, переписка остается как была. Удаление убирает и историю правок, и строки в history.jsonl.",
                     "Moving changes the session folder and its cwd, the conversation stays as it was. Deleting also removes its file history and its lines in history.jsonl."))
                .font(.system(size: 12))
                .foregroundStyle(Ink.muted)
                .lineLimit(3)
            Button(l.t("Читать переписку целиком", "Read the whole conversation"), action: onReadAll)
                .buttonStyle(.link)
        }
        .padding(16)
    }
}

/// Переименовать сессию по id, как /rename. Для окна "Сессии", где вкладки может и не быть.
struct RenameSessionSheet: View {
    @EnvironmentObject var backend: Backend
    @Environment(\.dismiss) private var dismiss
    let id: String
    let current: String
    let done: () -> Void
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
                Button(l.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(l.rename, action: save)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { title = current }
    }

    private func save() {
        let clean = title.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        Task {
            _ = await backend.perform(["sessions", "rename", id, clean])
            done()
        }
        dismiss()
    }
}

struct MessageView: View {
    @EnvironmentObject var backend: Backend
    let message: SessionPreview.Message

    var l: L { L(backend.state.lang) }

    var body: some View {
        let (who, color): (String, Color) = {
            switch message.role {
            case "user": return (l.t("ты", "you"), .accentColor)
            case "claude": return ("Claude", .orange)
            case "tool": return (l.t("команда", "command"), .secondary)
            case "error": return (l.t("ошибка", "error"), .red)
            default: return (message.role, .secondary)
            }
        }()
        VStack(alignment: .leading, spacing: 3) {
            Text(who)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(message.text)
                .font(message.role == "tool" ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(message.role == "tool" ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }
}

/// Кнопка меню, которая открывает окно библиотеки. Commands не видят окружение, поэтому отдельный View.
struct OpenLibraryButton: View {
    @Environment(\.openWindow) private var openWindow
    let title: String

    var body: some View {
        Button(title) { openWindow(id: "library") }
            .keyboardShortcut("o", modifiers: [.command, .shift])
    }
}

/// Какие окна кроме главного были открыты. При следующем запуске они открываются снова, как и вкладки.
enum WindowMemory {
    static let key = "openWindows"

    static var open: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func set(_ id: String, open isOpen: Bool) {
        var ids = Set(open)
        if isOpen { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
    }
}

/// Открывает окна прошлого запуска. Висит в главном окне, потому что openWindow есть только у View.
struct ReopenWindows: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @State private var done = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !done else { return }
            done = true
            let ids = WindowMemory.open
            DispatchQueue.main.async {
                for id in ids { openWindow(id: id) }
            }
        }
    }
}
