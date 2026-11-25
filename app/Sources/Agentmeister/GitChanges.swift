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
    @Environment(\.openWindow) private var openWindow

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
                Button {
                    ChangesFocus.shared.show(file.path, in: snapshot.root)
                    openWindow(id: "changes", value: snapshot.root)
                } label: { row(file) }
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
