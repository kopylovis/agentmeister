import SwiftUI

/// Фоновая команда сессии Claude Code (Bash с run_in_background). Своей вкладки у нее нет: команда и описание
/// лежат в переписке сессии, вывод пишется в файл, а об окончании в переписку приходит task-notification.
struct BackgroundShell: Identifiable, Equatable {
    let id: String
    let description: String
    let command: String
    let output: String?
    let started: Date
    /// nil, пока команда идет. Иначе completed, failed, killed или то, что пришло в уведомлении.
    let status: String?
    let exitCode: Int?
    let finishedAt: Date?

    var failed: Bool { status.map { $0 != "completed" } ?? false || (exitCode.map { $0 != 0 } ?? false) }

    func finished(_ status: String, code: Int?, at: Date) -> BackgroundShell {
        BackgroundShell(id: id, description: description, command: command, output: output, started: started,
                        status: status, exitCode: code, finishedAt: at)
    }
}

enum BackgroundShells {
    /// Что уже прочитано из переписки сессии. Переписка растет до мегабайт, поэтому каждый опрос читает только
    /// дописанное с прошлого раза, и команда, запущенная давно, не теряется.
    private final class Cursor {
        var offset: UInt64 = 0
        /// Вызовы Bash в фоне, на которые еще не пришел ответ с id задачи: id вызова -> описание, команда, время.
        var pending: [String: (String, String, Date)] = [:]
        var shells: [String: BackgroundShell] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cursors: [String: Cursor] = [:]
    /// Команды, которые убрали из ряда подзадач.
    nonisolated(unsafe) private static var hidden: Set<String> = []
    /// Команды, остановленные из приложения: Claude Code сообщит о них как об упавших.
    nonisolated(unsafe) private static var stoppedHere: Set<String> = []

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let startedRe = try! NSRegularExpression(pattern: #"running in background with ID: ([A-Za-z0-9_-]+)"#)
    private static let outputRe = try! NSRegularExpression(pattern: #"Output is being written to: (\S+?\.output)"#)
    private static let noticeRe = try! NSRegularExpression(pattern: #"<task-id>([A-Za-z0-9_-]+)</task-id>.*?<status>([a-z_]+)</status>(?:(?:(?!<task-id>).)*?exit code (-?\d+))?"#)
    /// Ответ TaskStop (раньше KillShell): уведомления об остановленной так команде не бывает.
    private static let stopRe = try! NSRegularExpression(pattern: #"Successfully (?:stopped task|killed shell): ([A-Za-z0-9_-]+)"#)
    /// Последняя строка файла вывода, которую Claude Code дописывает, когда команда кончилась.
    private static let tailRe = try! NSRegularExpression(pattern: #"(?:^|\n)\[(killed|exited with code (-?\d+))\]\s*$"#)

    /// Команды, которые идут сейчас или закончились за последние 15 минут, новые первыми. Идущая дольше суток
    /// считается брошенной: сессию закрыли, а уведомление не пришло.
    static func list(_ sessionId: String) -> [BackgroundShell] {
        guard let path = SessionContext.file(sessionId) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let cursor = cursors[path] ?? Cursor()
        cursors[path] = cursor
        read(path, into: cursor)
        // сессию закрыли или команду остановили, и уведомление не придет, а конец виден в файле вывода
        for shell in cursor.shells.values where shell.status == nil {
            if let end = shell.output.flatMap(ending) { cursor.shells[shell.id] = shell.finished(end.0, code: end.1, at: end.2) }
        }
        let now = Date()
        let shown = cursor.shells.values.filter { shell in
            guard !hidden.contains(shell.id) else { return false }
            if let done = shell.finishedAt { return now.timeIntervalSince(done) < 15 * 60 }
            return now.timeIntervalSince(shell.started) < 24 * 3600
        }
        return Array(shown.sorted { $0.started > $1.started }.prefix(8))
    }

    private static func read(_ path: String, into cursor: Cursor) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // переписку переписали заново (/slim): читаем с начала
        if size < cursor.offset {
            cursor.offset = 0
            cursor.pending = [:]
            cursor.shells = [:]
        }
        guard size > cursor.offset else { return }
        try? handle.seek(toOffset: cursor.offset)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        // недописанная последняя строка дочитается в следующий раз
        let complete = data[data.startIndex...lastNewline]
        cursor.offset += UInt64(complete.count)
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            parse(Data(line), into: cursor)
        }
    }

    private static func parse(_ line: Data, into cursor: Cursor) {
        guard let raw = String(data: line, encoding: .utf8) else { return }
        let hasCall = raw.contains("run_in_background")
        let hasStart = raw.contains("running in background with ID")
        let hasNotice = raw.contains("<task-notification>")
        let hasStop = raw.contains("Successfully stopped task") || raw.contains("Successfully killed shell")
        guard hasCall || hasStart || hasNotice || hasStop,
              let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let time = (o["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
        let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        if hasCall {
            for block in content where block["type"] as? String == "tool_use" && block["name"] as? String == "Bash" {
                guard let id = block["id"] as? String, let input = block["input"] as? [String: Any],
                      input["run_in_background"] as? Bool == true else { continue }
                let command = (input["command"] as? String) ?? ""
                let description = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? String(command.split(separator: "\n").first ?? "")
                cursor.pending[id] = (description, command, time)
            }
        }
        if hasStart {
            for block in content where block["type"] as? String == "tool_result" {
                guard let callId = block["tool_use_id"] as? String, let call = cursor.pending.removeValue(forKey: callId) else { continue }
                let text = resultText(block["content"])
                guard let taskId = first(startedRe, in: text) else { continue }
                cursor.shells[taskId] = BackgroundShell(id: taskId, description: call.0, command: call.1,
                                                        output: first(outputRe, in: text), started: call.2,
                                                        status: nil, exitCode: nil, finishedAt: nil)
            }
        }
        if hasNotice {
            let range = NSRange(raw.startIndex..., in: raw)
            for match in noticeRe.matches(in: raw, range: range) {
                guard let idRange = Range(match.range(at: 1), in: raw), let statusRange = Range(match.range(at: 2), in: raw) else { continue }
                let id = String(raw[idRange])
                // уведомление приходит в переписку не один раз: время окончания берется первое
                guard let shell = cursor.shells[id], shell.status == nil else { continue }
                let code = Range(match.range(at: 3), in: raw).flatMap { Int(raw[$0]) }
                cursor.shells[id] = shell.finished(String(raw[statusRange]), code: code, at: time)
            }
        }
        if hasStop {
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = first(stopRe, in: resultText(block["content"])),
                      let shell = cursor.shells[id], shell.status == nil else { continue }
                cursor.shells[id] = shell.finished("killed", code: nil, at: time)
            }
        }
    }

    /// Конец команды по последней строке ее файла вывода: состояние, код и время, когда файл дописан.
    private static func ending(_ file: String) -> (String, Int?, Date)? {
        guard let handle = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 64 ? size - 64 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        guard let match = tailRe.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let code = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) }
        let at = (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date) ?? Date()
        return code.map { ($0 == 0 ? "completed" : "failed", $0, at) } ?? ("killed", nil, at)
    }

    /// Убирает команду из ряда подзадач до перезапуска приложения.
    static func hide(_ id: String) {
        lock.lock()
        hidden.insert(id)
        lock.unlock()
    }

    static func stoppedFromApp(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedHere.contains(id)
    }

    /// Останавливает команду сигналом TERM. Claude Code запускает каждую фоновую команду оболочкой в своей группе
    /// процессов и пишет вывод из нее же, а сам файл не держит, поэтому сигнал получают группы тех, кто держит
    /// файл вывода, и ничего больше. Об упавшей команде Claude Code сам напишет в сессию. false, если процессов
    /// команды уже нет.
    static func stop(_ shell: BackgroundShell) -> Bool {
        guard let file = shell.output else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-F", "pg", "--", file]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        var pids: [pid_t] = [], groups: [pid_t] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let value = pid_t(line.dropFirst()) else { continue }
            if line.hasPrefix("p") { pids.append(value) } else if line.hasPrefix("g") { groups.append(value) }
        }
        let own = getpgrp()
        let leaders = Set(groups).filter { $0 != own && pids.contains($0) }
        if leaders.isEmpty {
            pids.forEach { kill($0, SIGTERM) }
        } else {
            leaders.forEach { killpg($0, SIGTERM) }
        }
        guard !pids.isEmpty else { return false }
        lock.lock()
        stoppedHere.insert(shell.id)
        lock.unlock()
        return true
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] { return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return ""
    }

    private static func first(_ re: NSRegularExpression, in text: String) -> String? {
        guard let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Хвост вывода команды, последние 256 КБ.
    static func tail(_ file: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: file) else { return "" }
        defer { try? handle.close() }
        let limit: UInt64 = 256 << 10
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > limit ? size - limit : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Фоновая команда в ряду подзадач: состояние и описание, по клику ее вывод. Закончившуюся команду крестик
/// под курсором убирает из ряда.
struct ShellChip: View {
    let shell: BackgroundShell
    let l: L
    let remove: () -> Void
    @State private var hover = false
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                Group {
                    if shell.status == nil {
                        SessionDot(status: "busy", size: 7)
                    } else if shell.failed {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.red)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.teal)
                    }
                }
                .frame(width: 10)
                Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(Ink.faint)
                Text(shell.description).lineLimit(1).foregroundStyle(Ink.text2)
                if hover && shell.status != nil {
                    Button(action: remove) {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
                    }
                    .buttonStyle(.hoverCircle(.overlay))
                    .help(l.t("Убрать из ряда", "Remove from the row"))
                    .accessibilityLabel(l.t("Убрать из ряда", "Remove from the row"))
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(maxWidth: 280, minHeight: 26, maxHeight: 26)
            .background(Capsule().fill(hover ? Ink.hover : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(l.t("Фоновая команда этой сессии. Клик показывает ее вывод.", "A background command of this session. Click to see its output.")
              + "\n" + shell.command)
        .sheet(isPresented: $open) { ShellSheet(shell: shell, l: l, remove: remove) }
    }
}

/// Вывод фоновой команды, обновляется раз в секунду, пока лист открыт. Идущую команду можно остановить,
/// закончившуюся убрать из ряда подзадач.
struct ShellSheet: View {
    let shell: BackgroundShell
    let l: L
    let remove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var stopping = false
    @State private var stopFailed = false

    /// Чем кончилась команда, для заголовка листа.
    private var outcome: (String, Color)? {
        guard let status = shell.status else { return nil }
        if status == "killed" || BackgroundShells.stoppedFromApp(shell.id) { return (l.t("остановлена", "stopped"), Ink.amber) }
        if !shell.failed { return (l.t("готово", "done"), Ink.teal) }
        let code = shell.exitCode.map(String.init) ?? "?"
        return (l.t("код \(code)", "exit \(code)"), Ink.red)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .buttonStyle(.hoverCircle())
                    .keyboardShortcut(.cancelAction)
                    .help(l.t("Закрыть (Esc)", "Close (Esc)"))
                    .accessibilityLabel(l.t("Закрыть", "Close"))
                Image(systemName: "terminal").foregroundStyle(Ink.faint)
                Text(shell.description).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(shell.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.faint)
                Spacer()
                if let outcome {
                    Text(outcome.0).font(.system(size: 12)).foregroundStyle(outcome.1)
                    Button(l.t("Убрать", "Remove")) {
                        remove()
                        dismiss()
                    }
                    .buttonStyle(PillStyle())
                    .help(l.t("Убрать команду из ряда подзадач", "Remove the command from the subtask row"))
                } else {
                    if stopFailed {
                        Text(l.t("процессов команды уже нет", "the command has no processes left"))
                            .font(.system(size: 12)).foregroundStyle(Ink.amber)
                    }
                    Button(stopping ? l.t("Останавливаю…", "Stopping…") : l.t("Остановить", "Stop")) {
                        stopping = true
                        stopFailed = false
                        Task {
                            let target = shell
                            let ok = await Task.detached(priority: .userInitiated) { BackgroundShells.stop(target) }.value
                            stopping = ok
                            stopFailed = !ok
                        }
                    }
                    .buttonStyle(PillStyle())
                    .disabled(stopping)
                    .help(l.t("Остановить команду. Агент получит уведомление, что она прервана.",
                              "Stop the command. The agent gets a notice that it was interrupted."))
                }
            }
            .padding(14)
            Text(shell.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Ink.muted)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Divider()
            if let text {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(text.isEmpty ? l.t("Вывода пока нет", "No output yet") : text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(text.isEmpty ? Ink.faint : Ink.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(16)
                    }
                    .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 680, idealWidth: 780, minHeight: 460, idealHeight: 620)
        .task {
            guard let file = shell.output else {
                text = ""
                return
            }
            while !Task.isCancelled {
                let now = await Task.detached(priority: .userInitiated) { BackgroundShells.tail(file) }.value
                if text != now { text = now }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
