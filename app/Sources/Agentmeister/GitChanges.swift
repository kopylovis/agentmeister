import SwiftUI

/// Файл рабочей копии, который отличается от HEAD: изменен, добавлен, удален, переименован или еще не в git.
struct GitChange: Hashable, Identifiable {
    let path: String
    /// Две буквы git status --porcelain: "M ", " M", "A ", "??" и так далее.
    let code: String
    var added: Int?
    var removed: Int?
    var id: String { path }

    var untracked: Bool { code == "??" }
    /// Одна буква для списка. Новый файл и файл вне git оба "A".
    var letter: String {
        if untracked { return "A" }
        let c = code.replacingOccurrences(of: " ", with: "")
        return String(c.first ?? "M")
    }
    var color: Color {
        switch letter {
        case "A": return Ink.teal
        case "D": return Ink.red
        default: return Ink.amber
        }
    }
}

/// Изменения рабочей копии через git. Все вызовы синхронные, их зовут вне главного потока.
enum GitChanges {
    struct Snapshot: Equatable {
        let root: String
        let files: [GitChange]
    }

    private static func git(_ args: [String], in dir: String) -> (Int32, String)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", dir] + args
        // список обновляется каждые 5 секунд, и git не должен при этом брать index.lock у агента
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Изменения во всем репозитории, где лежит папка. nil, если папка не в git.
    static func snapshot(at dir: String) -> Snapshot? {
        guard let (code, top) = git(["rev-parse", "--show-toplevel"], in: dir), code == 0 else { return nil }
        let root = top.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (_, status) = git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root) else { return nil }
        var files: [GitChange] = []
        var entries = status.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst(), entry.count > 3 {
            let code = String(entry.prefix(2))
            files.append(GitChange(path: String(entry.dropFirst(3)), code: code))
            // у переименования следом идет старый путь
            if code.contains("R") || code.contains("C") { _ = entries.popFirst() }
        }
        // строки по файлам из git diff --numstat HEAD; в репозитории без коммитов HEAD нет, тогда без чисел
        if let (ok, numstat) = git(["diff", "--numstat", "-z", "HEAD"], in: root), ok == 0 {
            var counts: [String: (Int?, Int?)] = [:]
            var parts = numstat.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
            while let part = parts.popFirst(), !part.isEmpty {
                let cols = part.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard cols.count == 3 else { continue }
                var path = cols[2]
                if path.isEmpty { _ = parts.popFirst(); path = parts.popFirst() ?? "" }
                counts[path] = (Int(cols[0]), Int(cols[1]))
            }
            for i in files.indices { if let c = counts[files[i].path] { files[i].added = c.0; files[i].removed = c.1 } }
        }
        return Snapshot(root: root, files: files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }

    /// Дифф одного файла против HEAD. Новый файл показывается целиком как добавленный.
    static func diff(_ change: GitChange, root: String) -> String {
        let args = change.untracked
            ? ["diff", "--no-color", "--no-index", "--", "/dev/null", change.path]
            : ["diff", "--no-color", "HEAD", "--", change.path]
        let out = git(args, in: root)?.1 ?? ""
        if !out.isEmpty || change.untracked { return out }
        // без коммитов HEAD нет, тогда дифф против индекса
        return git(["diff", "--no-color", "--cached", "--", change.path], in: root)?.1 ?? ""
    }
}

/// Карточка "Изменения" в инспекторе вкладки: файлы рабочей копии, клик открывает дифф.
struct ChangesCard: View {
    let snapshot: GitChanges.Snapshot
    let l: L
    @State private var open: GitChange?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionCaption(text: l.t("Изменения", "Changes"))
                Spacer()
                if !snapshot.files.isEmpty {
                    Text("\(snapshot.files.count)").font(.system(size: 11)).foregroundStyle(Ink.faint)
                }
            }
            .padding(.bottom, 3)
            if snapshot.files.isEmpty {
                Text(l.t("Рабочая копия чистая", "The working tree is clean")).foregroundStyle(Ink.muted)
            }
            ForEach(snapshot.files.prefix(12)) { file in
                Button { open = file } label: { row(file) }
                    .buttonStyle(.hover(6))
                    .help(file.path)
            }
            if snapshot.files.count > 12 {
                Text(l.t("и еще \(snapshot.files.count - 12)", "and \(snapshot.files.count - 12) more")).foregroundStyle(Ink.faint)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
        .sheet(item: $open) { file in DiffSheet(file: file, root: snapshot.root, l: l) }
    }

    private func row(_ file: GitChange) -> some View {
        let name = (file.path as NSString).lastPathComponent
        let dir = (file.path as NSString).deletingLastPathComponent
        return HStack(spacing: 6) {
            Text(file.letter)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(file.color)
                .frame(width: 12)
            Text(name).foregroundStyle(Ink.text).lineLimit(1).layoutPriority(1)
            if !dir.isEmpty {
                Text(dir).foregroundStyle(Ink.faint).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            if let a = file.added, a > 0 { Text("+\(a)").foregroundStyle(Ink.teal) }
            if let r = file.removed, r > 0 { Text("−\(r)").foregroundStyle(Ink.red) }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Дифф файла в листе: строки с + и - на цветной подложке, заголовки ханков приглушены.
struct DiffSheet: View {
    let file: GitChange
    let root: String
    let l: L
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [Substring]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(file.letter).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(file.color)
                Text(file.path).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    .textSelection(.enabled)
                Spacer()
                if file.letter != "D" {
                    Button(l.t("Открыть файл", "Open file")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: (root as NSString).appendingPathComponent(file.path)))
                    }
                    .buttonStyle(PillStyle())
                }
                Button(l.t("Готово", "Done")) { dismiss() }
                    .buttonStyle(PillStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            if let lines {
                if lines.isEmpty {
                    ContentUnavailableView(l.t("Без отличий в тексте", "No text changes"), systemImage: "doc")
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.prefix(5000).enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : String(line))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(color(line))
                                    .fixedSize()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .background(background(line))
                            }
                        }
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 480, idealHeight: 620)
        .task {
            let file = file, root = root
            let text = await Task.detached(priority: .userInitiated) { GitChanges.diff(file, root: root) }.value
            // шапку диффа (diff --git, index, ---/+++) не показываем, имя файла уже в заголовке
            let all = text.split(separator: "\n", omittingEmptySubsequences: false)
            let start = all.firstIndex { $0.hasPrefix("@@") } ?? all.endIndex
            lines = Array(all[start...]).filter { !($0.isEmpty && $0 == all.last) }
        }
    }

    private func color(_ line: Substring) -> Color {
        if line.hasPrefix("@@") { return Ink.faint }
        if line.hasPrefix("+") { return Ink.teal }
        if line.hasPrefix("-") { return Ink.red }
        return Ink.text2
    }

    private func background(_ line: Substring) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Ink.teal.opacity(0.1) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Ink.red.opacity(0.1) }
        return .clear
    }
}
