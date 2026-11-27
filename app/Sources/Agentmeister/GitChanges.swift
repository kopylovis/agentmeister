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
        if Demo.active { return Demo.changes(at: dir) }
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
        // файлов вне git нет в numstat, у них все строки добавленные
        for i in files.indices where files[i].untracked && files[i].added == nil {
            files[i].added = lineCount((root as NSString).appendingPathComponent(files[i].path))
            files[i].removed = 0
        }
        return Snapshot(root: root, files: files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }

    /// Строки текстового файла до 2 МБ. Двоичный или большой файл дает nil, как "-" в numstat.
    private static func lineCount(_ path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size <= 2_000_000,
              let data = FileManager.default.contents(atPath: path), !data.contains(0) else { return nil }
        guard !data.isEmpty else { return 0 }
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return data.last == 0x0A ? newlines : newlines + 1
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

/// Столбцы "+N" и "−N" у списка изменений: ширина по самому длинному числу, включая итог в заголовке секции,
/// поэтому цифры стоят ровно друг под другом. Нет данных, значит 0.
struct DiffColumns {
    let totalAdded: Int
    let totalRemoved: Int
    private let addedWidth: Int
    private let removedWidth: Int

    init(_ files: [GitChange]) {
        totalAdded = files.reduce(0) { $0 + ($1.added ?? 0) }
        totalRemoved = files.reduce(0) { $0 + ($1.removed ?? 0) }
        addedWidth = String(totalAdded).count
        removedWidth = String(totalRemoved).count
    }

    /// Пара ячеек. Невидимый шаблон из нулей держит ширину, цифры прижаты вправо (у цифр моноширинный кегль).
    func cells(_ added: Int, _ removed: Int) -> some View {
        HStack(spacing: 6) {
            cell("+", added, addedWidth, Ink.teal)
            cell("−", removed, removedWidth, Ink.red)
        }
        .font(.system(size: 11))
        .monospacedDigit()
    }

    private func cell(_ sign: String, _ n: Int, _ width: Int, _ color: Color) -> some View {
        Text(sign + String(repeating: "0", count: width))
            .hidden()
            .overlay(alignment: .trailing) { Text(sign + String(n)).foregroundStyle(color) }
    }
}

/// Список изменений в инспекторе вкладки: файлы рабочей копии, клик открывает дифф.
struct ChangesList: View {
    let snapshot: GitChanges.Snapshot
    let numbers: DiffColumns
    let l: L
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if snapshot.files.isEmpty {
                Text(l.t("Рабочая копия чистая", "The working tree is clean")).foregroundStyle(Ink.muted).padding(.horizontal, 4)
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
                Text(l.t("и еще \(snapshot.files.count - 12)", "and \(snapshot.files.count - 12) more")).foregroundStyle(Ink.faint).padding(.horizontal, 4)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, -4)
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
            numbers.cells(file.added ?? 0, file.removed ?? 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
