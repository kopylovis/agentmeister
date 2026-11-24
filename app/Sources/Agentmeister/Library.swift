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

/// Окно "Сессии": все сессии всех проектов, поиск по переписке, превью и действия. Замена agentmeister sessions.
struct LibraryView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @Environment(\.openWindow) private var openWindow

    // запрос и выбранная сессия переживают закрытие окна и перезапуск
    @AppStorage("libraryQuery") private var query = ""
    @State private var projectFilter: String?
    @State private var found: SearchResults?
    @State private var searching = false
    @AppStorage("librarySelection") private var storedSelection = ""
    @State private var selection: String?
    @State private var preview: SessionPreview?
    @State private var confirmDelete = false

    var l: L { L(backend.state.lang) }

    private var rows: [LibraryRow] {
        let all: [LibraryRow]
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            all = backend.state.sessions.map {
                LibraryRow(id: $0.id, title: $0.title, home: $0.cwd, time: $0.mtime, size: $0.size, hits: [], count: 0)
            }
        } else {
            all = (found?.results ?? []).map {
                LibraryRow(id: $0.id, title: $0.title, home: $0.home, time: $0.last, size: nil, hits: $0.hits, count: $0.count)
            }
        }
        guard let filter = projectFilter else { return all }
        return all.filter { $0.home == filter || $0.home.hasPrefix(filter + "/") }
    }

    private var projectsWithSessions: [(AppState.Project, Int)] {
        backend.state.projects.compactMap { p in
            let n = backend.state.sessions(in: p).count
            return n > 0 ? (p, n) : nil
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $projectFilter) {
                Section(l.projects) {
                    Label(l.t("Все проекты", "All projects"), systemImage: "tray.full")
                        .badge(backend.state.sessions.count)
                        .tag(nil as String?)
                    ForEach(projectsWithSessions, id: \.0.path) { project, count in
                        Label(project.name, systemImage: "folder")
                            .badge(count)
                            .tag(project.path as String?)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            List(rows, selection: $selection) { row in
                LibraryRowView(row: row, query: query)
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
            .navigationSplitViewColumnWidth(min: 360, ideal: 460, max: 640)
            .searchable(text: $query, placement: .toolbar, prompt: l.t("Слова из переписки, любой проект", "Words from any conversation"))
        } detail: {
            if let preview, let id = preview.id {
                PreviewView(preview: preview, sessionId: id, onResume: resume, onDelete: { confirmDelete = true })
            } else {
                ContentUnavailableView(l.t("Выбери сессию", "Pick a session"), systemImage: "text.bubble")
            }
        }
        .navigationTitle(l.t("Сессии", "Sessions"))
        .navigationSubtitle(subtitle)
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
        .task(id: selection) {
            preview = nil
            storedSelection = selection ?? ""
            guard let id = selection else { return }
            preview = await backend.read(id)
        }
        .onAppear { if selection == nil, !storedSelection.isEmpty { selection = storedSelection } }
        .confirmationDialog(l.t("Удалить сессию?", "Delete the session?"), isPresented: $confirmDelete) {
            Button(l.t("Удалить", "Delete"), role: .destructive) { delete() }
        } message: {
            Text(l.t("Удалятся переписка, история правок и строки в history.jsonl. Вернуть нельзя.",
                     "The transcript, its file history and its lines in history.jsonl are removed. This can't be undone."))
        }
        .frame(minWidth: 960, minHeight: 560)
        .onAppear { WindowMemory.set("library", open: true) }
        .onDisappear { WindowMemory.set("library", open: false) }
    }

    private var subtitle: String {
        if let found, !query.isEmpty {
            return l.t("найдено \(found.results.count) из \(found.scanned)", "\(found.results.count) of \(found.scanned) found")
        }
        return l.t("сессий \(backend.state.sessions.count)", "\(backend.state.sessions.count) sessions")
    }

    private func resume() {
        guard let id = preview?.id else { return }
        let home = preview?.home ?? ""
        let project = backend.state.projects.first { home == $0.path || home.hasPrefix($0.path + "/") }
        let path = project?.path ?? home
        let name = project?.name ?? (home as NSString).lastPathComponent
        workspace.open(LaunchSpec(projectName: name, projectPath: path, resumeId: id))
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
}

struct LibraryRowView: View {
    @EnvironmentObject var backend: Backend
    let row: LibraryRow
    let query: String

    var l: L { L(backend.state.lang) }

    var body: some View {
        let live = backend.state.live.first { $0.sessionId == row.id }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                // место под точку есть всегда, чтобы названия начинались ровно
                Circle()
                    .fill(live.map { statusColor($0.status) } ?? .clear)
                    .frame(width: 7, height: 7)
                Text(row.title.isEmpty ? l.untitled : row.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
            }
            Text([row.project, row.time.map { l.ago($0) }, row.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
                  live.map { l.statusTitle($0.status) }]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 14)
            ForEach(row.hits.prefix(2), id: \.self) { hit in
                Text(highlight(hit.snippet, query: query))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 14)
            }
            if row.count > 2 {
                Text(l.t("совпадений \(row.count)", "\(row.count) matches"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 14)
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
    let onResume: () -> Void
    let onDelete: () -> Void

    var l: L { L(backend.state.lang) }

    var body: some View {
        let live = backend.state.live.contains { $0.sessionId == sessionId }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.title ?? l.untitled)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Text("\(String(sessionId.prefix(8))) · \(tilde(preview.home ?? "")) · " + l.t("сообщений \(preview.total ?? 0)", "\(preview.total ?? 0) messages"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
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
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
                .onAppear { if let last = preview.messages?.last { proxy.scrollTo(last.at, anchor: .bottom) } }
            }
            HStack {
                Button(l.resume, action: onResume)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                Button(l.t("Скопировать id", "Copy id")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sessionId, forType: .string)
                }
                .buttonStyle(.glass)
                Spacer()
                Button(l.t("Удалить", "Delete"), role: .destructive, action: onDelete)
                    .buttonStyle(.glass)
                    .disabled(live)
                    .help(live ? l.t("Сессия открыта, сначала закрой ее", "The session is open, close it first") : "")
            }
        }
        .padding(16)
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
