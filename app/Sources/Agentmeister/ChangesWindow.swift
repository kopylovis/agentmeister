import SwiftUI
import UniformTypeIdentifiers

/// Какой файл показать в окне изменений: клик по файлу в карточке инспектора пишет сюда, окно прокручивает к нему.
@MainActor
final class ChangesFocus: ObservableObject {
    static let shared = ChangesFocus()
    struct Request: Equatable { let root: String; let path: String; let nonce: UUID }
    @Published var request: Request?

    func show(_ path: String, in root: String) { request = Request(root: root, path: path, nonce: UUID()) }
}

/// Строка разобранного диффа: номера в старом и новом файле, вид и текст без знака.
struct DiffLine: Identifiable {
    enum Kind { case context, add, del, hunk, note }
    let id: Int
    let kind: Kind
    let old: Int?
    let new: Int?
    let text: String
    /// Заголовок ханка: функция или тип после второго @@.
    var section = ""
    /// Сколько символов в начале и в конце строки совпадает с парной строкой: середина подсвечивается ярче.
    var same: (prefix: Int, suffix: Int)?
}

enum DiffParser {
    static func parse(_ text: String) -> [DiffLine] {
        var out: [DiffLine] = []
        var old = 0, new = 0, started = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                started = true
                // @@ -a,b +c,d @@ section
                let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
                if parts.count >= 3 {
                    old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                let header = parts.prefix(4).joined(separator: " ")
                let section = parts.count > 4 ? String(parts[4]) : ""
                out.append(DiffLine(id: out.count, kind: .hunk, old: nil, new: nil, text: header, section: section))
                continue
            }
            guard started else {
                if line.hasPrefix("Binary files") {
                    out.append(DiffLine(id: out.count, kind: .note, old: nil, new: nil, text: line))
                }
                continue
            }
            if line.hasPrefix("+") {
                out.append(DiffLine(id: out.count, kind: .add, old: nil, new: new, text: String(line.dropFirst())))
                new += 1
            } else if line.hasPrefix("-") {
                out.append(DiffLine(id: out.count, kind: .del, old: old, new: nil, text: String(line.dropFirst())))
                old += 1
            } else if line.hasPrefix("\\") {
                out.append(DiffLine(id: out.count, kind: .note, old: nil, new: nil, text: String(line.dropFirst(2))))
            } else if line.hasPrefix(" ") {
                out.append(DiffLine(id: out.count, kind: .context, old: old, new: new, text: String(line.dropFirst())))
                old += 1
                new += 1
            }
        }
        markWords(&out)
        return out
    }

    /// Подряд идущие удаленные и добавленные строки поровну: пары строк, у которых совпадают начало и конец.
    private static func markWords(_ lines: inout [DiffLine]) {
        var i = 0
        while i < lines.count {
            guard lines[i].kind == .del else { i += 1; continue }
            var d = i
            while d < lines.count && lines[d].kind == .del { d += 1 }
            var a = d
            while a < lines.count && lines[a].kind == .add { a += 1 }
            if a - d == d - i {
                for k in 0..<(d - i) {
                    let x = Array(lines[i + k].text), y = Array(lines[d + k].text)
                    var p = 0
                    while p < x.count && p < y.count && x[p] == y[p] { p += 1 }
                    var s = 0
                    while s < x.count - p && s < y.count - p && x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
                    // совсем разные строки целиком не подсвечиваем: это не правка слова, а новая строка
                    if p + s > 0 {
                        lines[i + k].same = (p, s)
                        lines[d + k].same = (p, s)
                    }
                }
            }
            i = max(a, i + 1)
        }
    }
}

/// Все изменения репозитория в одном окне: слева файлы, справа их диффы подряд. Обновляется раз в 5 секунд.
struct ChangesWindow: View {
    let root: String
    @EnvironmentObject var backend: Backend
    @ObservedObject private var focus = ChangesFocus.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var snapshot: GitChanges.Snapshot?
    @State private var diffs: [String: [DiffLine]] = [:]
    @State private var viewed: Set<String> = []
    @State private var selection: String?
    @State private var scrollTarget: String?

    var l: L { L(backend.state.lang) }
    private var files: [GitChange] { snapshot?.files ?? [] }

    var body: some View {
        NavigationSplitView {
            List(files, selection: $selection) { file in
                fileRow(file).tag(file.path)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
            .safeAreaInset(edge: .bottom) {
                if !files.isEmpty {
                    Text(l.t("Просмотрено \(viewed.intersection(files.map(\.path)).count) из \(files.count)",
                             "Viewed \(viewed.intersection(files.map(\.path)).count) of \(files.count)"))
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        } detail: {
            detail
        }
        .navigationTitle(l.t("Изменения", "Changes") + " · " + (root as NSString).lastPathComponent)
        .toolbar {
            ToolbarItemGroup {
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                    .help(l.t("Предыдущий файл", "Previous file"))
                    .keyboardShortcut(.upArrow, modifiers: [.option])
                    .disabled(files.isEmpty)
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                    .help(l.t("Следующий файл", "Next file"))
                    .keyboardShortcut(.downArrow, modifiers: [.option])
                    .disabled(files.isEmpty)
            }
        }
        .background {
            // Esc закрывает окно, как ⌘W
            Button("") { dismissWindow() }.keyboardShortcut(.cancelAction).hidden()
        }
        .onChange(of: selection) { if let selection { scrollTarget = selection } }
        .onChange(of: focus.request) { take() }
        .task(id: root) {
            take()
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if snapshot == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if files.isEmpty {
            ContentUnavailableView(l.t("Рабочая копия чистая", "The working tree is clean"), systemImage: "checkmark.circle",
                                   description: Text(l.t("Незакоммиченных изменений нет", "No uncommitted changes")))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                        ForEach(files) { file in
                            Section {
                                if !viewed.contains(file.path) {
                                    fileBody(file)
                                }
                            } header: {
                                fileHeader(file)
                            }
                            .id(file.path)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: scrollTarget) {
                    guard let target = scrollTarget else { return }
                    withAnimation(.snappy) { proxy.scrollTo(target, anchor: .top) }
                    scrollTarget = nil
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        }
    }

    // MARK: Список файлов

    private func fileRow(_ file: GitChange) -> some View {
        let name = (file.path as NSString).lastPathComponent
        let dir = (file.path as NSString).deletingLastPathComponent
        let seen = viewed.contains(file.path)
        let url = URL(fileURLWithPath: root).appendingPathComponent(file.path)
        return HStack(spacing: 8) {
            Text(file.letter).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(file.color).frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if !dir.isEmpty {
                    Text(dir).font(.system(size: 10.5)).foregroundStyle(Ink.faint).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if seen {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.teal)
            } else {
                counts(file)
            }
        }
        .opacity(seen ? 0.6 : 1)
        .help(file.path)
    }

    @ViewBuilder
    private func counts(_ file: GitChange) -> some View {
        let lines = diffs[file.path] ?? []
        let added = file.added ?? lines.filter { $0.kind == .add }.count
        let removed = file.removed ?? lines.filter { $0.kind == .del }.count
        HStack(spacing: 4) {
            if added > 0 { Text("+\(added)").foregroundStyle(Ink.teal) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(Ink.red) }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    // MARK: Дифф файла

    private func fileHeader(_ file: GitChange) -> some View {
        let seen = viewed.contains(file.path)
        let url = URL(fileURLWithPath: root).appendingPathComponent(file.path)
        return HStack(spacing: 8) {
            Button {
                if seen { viewed.remove(file.path) } else { viewed.insert(file.path) }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(seen ? -90 : 0))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.hoverCircle())
            Text(file.letter).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(file.color)
            Text(file.path).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.head)
                .textSelection(.enabled)
            counts(file)
            Spacer(minLength: 8)
            Toggle(l.t("Просмотрено", "Viewed"), isOn: Binding(get: { seen }, set: { if $0 { viewed.insert(file.path) } else { viewed.remove(file.path) } }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            if file.letter != "D" {
                if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
                    Button(l.t("Сохранить копию…", "Save a Copy…")) { saveCopy(of: url, type: type) }
                        .buttonStyle(PillStyle(small: true))
                }
                Button(l.t("Открыть", "Open")) {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(PillStyle(small: true))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ink.hairline))
    }

    private func saveCopy(of source: URL, type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = source.lastPathComponent
        panel.begin { response in
            guard response == .OK, let destination = panel.url,
                  source.standardizedFileURL != destination.standardizedFileURL else { return }
            do {
                try Data(contentsOf: source, options: .mappedIfSafe).write(to: destination, options: .atomic)
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    @ViewBuilder
    private func fileBody(_ file: GitChange) -> some View {
        if let lines = diffs[file.path] {
            if lines.isEmpty {
                Text(l.t("Изменений в тексте нет", "No text changes")).font(.system(size: 12)).foregroundStyle(Ink.muted).padding(12)
            } else {
                VStack(spacing: 0) {
                    ForEach(lines.prefix(4000)) { line in DiffRow(line: line) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ink.hairline))
                if file.letter == "D" {
                    Text(l.t("Файл удален. Вернуть его можно командой git restore \(file.path)",
                             "The file was deleted. git restore \(file.path) brings it back"))
                        .font(.system(size: 11)).foregroundStyle(Ink.faint).padding(.horizontal, 4)
                }
            }
        } else {
            ProgressView().controlSize(.small).padding(12)
        }
    }

    // MARK: Данные

    /// Запрос от карточки инспектора для этого репозитория: выбрать файл и прокрутить к нему.
    private func take() {
        guard let request = focus.request, request.root == root else { return }
        viewed.remove(request.path)
        selection = request.path
        scrollTarget = request.path
        focus.request = nil
    }

    private func step(_ delta: Int) {
        guard !files.isEmpty else { return }
        let index = selection.flatMap { s in files.firstIndex { $0.path == s } } ?? (delta > 0 ? -1 : files.count)
        let next = min(max(index + delta, 0), files.count - 1)
        selection = files[next].path
    }

    private func reload() async {
        let root = root
        let now = await Task.detached(priority: .utility) { GitChanges.snapshot(at: root) }.value
        guard let now else { snapshot = GitChanges.Snapshot(root: root, files: []); return }
        let files = Array(now.files.prefix(60))
        let parsed = await Task.detached(priority: .utility) {
            var out: [String: [DiffLine]] = [:]
            for file in files { out[file.path] = DiffParser.parse(GitChanges.diff(file, root: root)) }
            return out
        }.value
        snapshot = now
        diffs = parsed
    }
}

/// Строка диффа: две колонки номеров, знак, текст с переносом. Подложка + и − на всю ширину, номера на ней
/// чуть темнее, измененная середина строки ярче.
private struct DiffRow: View {
    let line: DiffLine

    var body: some View {
        switch line.kind {
        case .hunk:
            HStack(spacing: 8) {
                Text(line.section.isEmpty ? line.text : line.section)
                    .foregroundStyle(line.section.isEmpty ? Ink.faint : Ink.text2)
                Spacer(minLength: 8)
                if !line.section.isEmpty { Text(line.text).foregroundStyle(Ink.faint).font(.system(size: 10.5, design: .monospaced)) }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .background(Ink.link.opacity(0.08))
        case .note:
            Text(line.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.faint)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            HStack(alignment: .top, spacing: 0) {
                number(line.old)
                number(line.new)
                Text(sign).foregroundStyle(tint).frame(width: 20)
                Text(content)
                    .foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 12)
            }
            .font(.system(size: 12, design: .monospaced))
            .background(fill)
            .textSelection(.enabled)
        }
    }

    private var sign: String { line.kind == .add ? "+" : line.kind == .del ? "−" : " " }
    private var tint: Color { line.kind == .add ? Ink.teal : line.kind == .del ? Ink.red : Ink.faint }
    private var fill: Color { line.kind == .add ? Ink.teal.opacity(0.10) : line.kind == .del ? Ink.red.opacity(0.10) : .clear }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .foregroundStyle(Ink.faint)
            .frame(width: 46, alignment: .trailing)
            .padding(.trailing, 6)
            .padding(.vertical, 1.5)
            .background(line.kind == .context ? Color.clear : tint.opacity(0.08))
    }

    private var content: AttributedString {
        var text = AttributedString(line.text.isEmpty ? " " : line.text)
        guard let same = line.same, line.kind == .add || line.kind == .del else { return text }
        let count = line.text.count
        let start = same.prefix, end = count - same.suffix
        guard start < end else { return text }
        let lower = text.index(text.startIndex, offsetByCharacters: start)
        let upper = text.index(text.startIndex, offsetByCharacters: end)
        text[lower..<upper].backgroundColor = tint.opacity(0.32)
        return text
    }
}
