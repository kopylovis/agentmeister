import SwiftUI

/// Фоновый агент внутри сессии Claude Code (инструмент Agent): своего терминала у него нет, переписка лежит
/// в <сессия>/subagents/agent-<id>.jsonl, а описание и метка окончания в agent-<id>.meta.json.
struct SubAgent: Identifiable, Equatable {
    let id: String
    let description: String
    let type: String
    let file: String
    let modified: Date
    let finished: Bool
}

enum SubAgents {
    private static let lock = NSLock()
    /// Агенты, которых убрали из ряда подзадач.
    nonisolated(unsafe) private static var hidden: Set<String> = []

    /// Убирает агента из ряда подзадач до перезапуска приложения.
    static func hide(_ id: String) {
        lock.lock()
        hidden.insert(id)
        lock.unlock()
    }

    private static func isHidden(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hidden.contains(id)
    }

    /// Агенты сессии, которые идут сейчас или закончили за последние 15 минут, новые первыми.
    static func list(_ sessionId: String) -> [SubAgent] {
        guard let path = SessionContext.file(sessionId) else { return [] }
        let dir = (String(path.dropLast(6)) as NSString).appendingPathComponent("subagents")
        let fm = FileManager.default
        let now = Date()
        var out: [SubAgent] = []
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".jsonl") && name.hasPrefix("agent-") {
            let file = (dir as NSString).appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: file))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) < 15 * 60 else { continue }
            let id = String(name.dropFirst(6).dropLast(6))
            guard !isHidden(id) else { continue }
            let meta = (fm.contents(atPath: (dir as NSString).appendingPathComponent("agent-\(id).meta.json"))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            // без метки окончания агент считается идущим, только пока пишет: брошенный упавшей сессией не висит
            let finished = meta["finished"] as? Bool == true || now.timeIntervalSince(modified) > 10 * 60
            out.append(SubAgent(id: id, description: (meta["description"] as? String) ?? id,
                                type: (meta["agentType"] as? String) ?? "agent", file: file, modified: modified, finished: finished))
        }
        return Array(out.sorted { $0.modified > $1.modified }.prefix(8))
    }

    /// Запись переписки агента: его текст, вызов инструмента с результатом или итоговый отчет.
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable { case text, tool, report }
        let id: Int
        let kind: Kind
        var tool = ""
        let text: String
        /// Вывод инструмента, пока он не вернулся, nil.
        var output: String?
        var lines = 0
        var error = false
    }

    /// Переписка агента и сводка по ней, как в собственном виде агента у Claude Code.
    struct Transcript: Equatable {
        var prompt = ""
        var entries: [Entry] = []
        var start: Date?
        var end: Date?
        /// Размер контекста на последнем ответе модели.
        var tokens = 0
        var calls = 0
        var model: String?
    }

    /// Переписка агента. Большие файлы (агенты со скриншотами весят мегабайты) читаются с хвоста, задача
    /// и время начала тогда берутся из головы файла.
    static func transcript(_ file: String, limit: Int = 400) -> Transcript {
        var out = Transcript()
        guard let handle = FileHandle(forReadingAtPath: file) else { return out }
        defer { try? handle.close() }
        let tail: UInt64 = 2 << 20
        let size = (try? handle.seekToEnd()) ?? 0
        let cut = size > tail
        if cut {
            try? handle.seek(toOffset: 0)
            for line in ((try? handle.read(upToCount: 512 << 10)) ?? Data()).split(separator: UInt8(ascii: "\n")) {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if out.start == nil { out.start = (o["timestamp"] as? String).flatMap(date) }
                if let prompt = prompt(o) { out.prompt = prompt; break }
            }
        }
        try? handle.seek(toOffset: cut ? size - tail : 0)
        guard let data = try? handle.readToEnd() else { return out }
        var byUse: [String: Int] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let d = (o["timestamp"] as? String).flatMap(date) {
                if out.start == nil { out.start = d }
                out.end = d
            }
            guard let message = o["message"] as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "user":
                if !cut, out.prompt.isEmpty, let prompt = prompt(o) { out.prompt = prompt; continue }
                for block in (message["content"] as? [[String: Any]]) ?? [] where block["type"] as? String == "tool_result" {
                    guard let use = block["tool_use_id"] as? String, let i = byUse[use] else { continue }
                    let text = plain(block["content"]).trimmingCharacters(in: .newlines)
                    out.entries[i].output = text.count > 16000 ? text.prefix(16000) + "\n…" : text
                    out.entries[i].lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
                    out.entries[i].error = block["is_error"] as? Bool == true
                }
            case "assistant":
                if let model = message["model"] as? String, !model.hasPrefix("<") { out.model = model }
                if let u = message["usage"] as? [String: Any] {
                    let keys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"]
                    let sum = keys.reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
                    if sum > 0 { out.tokens = sum }
                }
                for block in (message["content"] as? [[String: Any]]) ?? [] {
                    switch block["type"] as? String {
                    case "text":
                        let text = ((block["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { out.entries.append(Entry(id: out.entries.count, kind: .text, text: text)) }
                    case "tool_use":
                        let name = (block["name"] as? String) ?? "tool"
                        let input = (block["input"] as? [String: Any]) ?? [:]
                        if name == "SubagentHandback", let report = input["message"] as? String {
                            out.entries.append(Entry(id: out.entries.count, kind: .report, text: report))
                            continue
                        }
                        let keys = ["description", "command", "file_path", "pattern", "url", "query", "prompt", "skill"]
                        let arg = keys.lazy.compactMap { input[$0] as? String }.first ?? ""
                        let short = arg.split(separator: "\n").first.map(String.init) ?? ""
                        if let id = block["id"] as? String { byUse[id] = out.entries.count }
                        out.entries.append(Entry(id: out.entries.count, kind: .tool, tool: name, text: String(short.prefix(200))))
                        out.calls += 1
                    default: break
                    }
                }
            default: break
            }
        }
        if out.entries.count > limit { out.entries = Array(out.entries.suffix(limit)) }
        return out
    }

    /// Задача агента: первое сообщение пользователя, не служебное и не результат инструмента.
    private static func prompt(_ o: [String: Any]) -> String? {
        guard o["type"] as? String == "user", o["isMeta"] as? Bool != true, o["toolUseResult"] == nil,
              let content = (o["message"] as? [String: Any])?["content"] else { return nil }
        if let blocks = content as? [[String: Any]], blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
        let text = plain(content).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Текст содержимого сообщения: строка или текстовые блоки, картинки одной пометкой.
    private static func plain(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { b -> String? in
            switch b["type"] as? String {
            case "text": return b["text"] as? String
            case "image": return "[image]"
            case "tool_reference": return b["tool_name"] as? String
            default: return nil
            }
        }.joined(separator: "\n")
    }

    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

/// Агент сессии в ряду подзадач: состояние и описание, по клику его переписка.
struct SubAgentChip: View {
    let agent: SubAgent
    let l: L
    /// Убирает закончившегося агента из ряда.
    var remove: () -> Void = {}
    @State private var hover = false
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                Group {
                    if agent.finished {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.teal)
                    } else {
                        SessionDot(status: "busy", size: 7)
                    }
                }
                .frame(width: 10)
                Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Ink.faint)
                Text(agent.description).lineLimit(1).foregroundStyle(Ink.text2)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(maxWidth: 280, minHeight: 26, maxHeight: 26)
            .background(Capsule().fill(hover ? Ink.hover : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(l.t("Агент внутри этой сессии (\(agent.type)). Клик показывает его переписку.",
                  "An agent inside this session (\(agent.type)). Click to see its transcript."))
        .sheet(isPresented: $open) { SubAgentSheet(agent: agent, l: l) }
        // остановить агента снаружи нельзя: Claude Code не дает для этого способа, только сама сессия
        .contextMenu {
            Button(l.t("Открыть переписку", "Open transcript")) { open = true }
            if agent.finished {
                Button(l.t("Убрать из ряда", "Remove from the row"), action: remove)
            }
        }
    }
}

/// Переписка агента сессии, обновляется раз в 2 секунды, пока лист открыт. Как вид агента в самом Claude Code:
/// задача, вызовы с результатами, отчет, время и токены. Только чтение, писать агенту можно в самой сессии.
struct SubAgentSheet: View {
    let agent: SubAgent
    let l: L
    @Environment(\.dismiss) private var dismiss
    @State private var log: SubAgents.Transcript?
    @State private var finished = false
    @State private var now = Date()
    @State private var open: Set<Int> = []
    @State private var fullPrompt = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .buttonStyle(.hoverCircle())
                    .keyboardShortcut(.cancelAction)
                    .help(l.t("Закрыть (Esc)", "Close (Esc)"))
                    .accessibilityLabel(l.t("Закрыть", "Close"))
                Image(systemName: "sparkles").foregroundStyle(Ink.faint).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(agent.description).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(agent.type).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.faint)
                    }
                    if let log { stats(log) }
                }
                Spacer()
            }
            .padding(14)
            Divider()
            if let log {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if !log.prompt.isEmpty { prompt(log.prompt) }
                            ForEach(log.entries) { entry in
                                switch entry.kind {
                                case .tool: tool(entry)
                                case .text: MarkdownText(text: entry.text)
                                case .report: report(entry.text)
                                }
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(16)
                        .textSelection(.enabled)
                    }
                    .onChange(of: log.entries.count) { proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 680, idealWidth: 820, minHeight: 460, idealHeight: 660)
        .task {
            let file = agent.file
            let dir = (file as NSString).deletingLastPathComponent
            let meta = (dir as NSString).appendingPathComponent("agent-\(agent.id).meta.json")
            while !Task.isCancelled {
                let (fresh, done) = await Task.detached(priority: .userInitiated) {
                    let done = (FileManager.default.contents(atPath: meta)
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["finished"] as? Bool == true
                    return (SubAgents.transcript(file), done)
                }.value
                if log != fresh { log = fresh }
                finished = done || agent.finished || log?.entries.last?.kind == .report
                now = Date()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Состояние, время работы, контекст и число вызовов, как в строке агента у Claude Code.
    private func stats(_ log: SubAgents.Transcript) -> some View {
        var parts: [String] = []
        if let start = log.start {
            let end = finished ? (log.end ?? now) : now
            parts.append(elapsed(max(0, end.timeIntervalSince(start))))
        }
        if log.tokens > 0 { parts.append(l.t("\(l.tokens(log.tokens)) токенов", "\(l.tokens(log.tokens)) tokens")) }
        parts.append(l.t("\(log.calls) \(ru(log.calls, "вызов", "вызова", "вызовов"))", "\(log.calls) tool \(log.calls == 1 ? "call" : "calls")"))
        if let model = log.model { parts.append(model) }
        return HStack(spacing: 6) {
            if finished {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.teal)
                Text(l.t("Готово", "Done")).foregroundStyle(Ink.teal)
            } else {
                SessionDot(status: "busy", size: 7)
                Text(l.t("Идет", "Running")).foregroundStyle(Ink.text2)
            }
            Text("· " + parts.joined(separator: " · ")).foregroundStyle(Ink.faint)
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    /// Задача, с которой агента запустили. Длинная свернута до шести строк.
    private func prompt(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l.t("Задача", "Task")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.faint)
            Text(text).font(.system(size: 12)).foregroundStyle(Ink.text2)
                .lineLimit(fullPrompt ? nil : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            if text.count > 400 || text.split(separator: "\n").count > 6 {
                Button(fullPrompt ? l.t("Свернуть", "Collapse") : l.t("Показать полностью", "Show all")) { fullPrompt.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.link)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ink.card))
    }

    /// Вызов инструмента и коротко его результат. Клик раскрывает весь вывод.
    private func tool(_ entry: SubAgents.Entry) -> some View {
        let expanded = open.contains(entry.id)
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                if expanded { open.remove(entry.id) } else { open.insert(entry.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.tool).fontWeight(.semibold).foregroundStyle(entry.error ? Ink.red : Ink.teal)
                    Text(entry.text).foregroundStyle(Ink.muted).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(entry.output?.isEmpty ?? true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("⎿").foregroundStyle(Ink.faint)
                if expanded, let output = entry.output {
                    Text(output).foregroundStyle(entry.error ? Ink.red : Ink.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    summary(entry)
                }
            }
            .padding(.leading, 10)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    @ViewBuilder private func summary(_ entry: SubAgents.Entry) -> some View {
        if let output = entry.output {
            if output.isEmpty {
                Text(l.t("Нет вывода", "No output")).foregroundStyle(Ink.faint)
            } else if entry.tool == "Read" && !entry.error {
                Text(l.t("Прочитано \(entry.lines) \(ru(entry.lines, "строка", "строки", "строк"))",
                         "Read \(entry.lines) \(entry.lines == 1 ? "line" : "lines")")).foregroundStyle(Ink.faint)
            } else {
                let head = output.split(separator: "\n").prefix(3).joined(separator: "\n")
                let rest = entry.lines - min(3, output.split(separator: "\n").count)
                VStack(alignment: .leading, spacing: 1) {
                    Text(head).foregroundStyle(entry.error ? Ink.red : Ink.muted).lineLimit(3).truncationMode(.tail)
                    if rest > 0 {
                        Text(l.t("… еще \(rest) \(ru(rest, "строка", "строки", "строк")), клик раскроет",
                                 "… \(rest) more \(rest == 1 ? "line" : "lines"), click to expand")).foregroundStyle(Ink.faint)
                    }
                }
            }
        } else {
            Text(finished ? l.t("Нет результата", "No result") : l.t("Выполняется…", "Running…")).foregroundStyle(Ink.faint)
        }
    }

    /// Итоговый отчет, который агент вернул сессии.
    private func report(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                Text(l.t("Отчет агента", "Agent report")).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Ink.teal)
            MarkdownText(text: text)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ink.tealChip))
    }

    /// 45 с, 5 мин 35 с, 1 ч 2 мин.
    private func elapsed(_ s: Double) -> String {
        let n = Int(s)
        if n < 60 { return l.t("\(n) с", "\(n)s") }
        if n < 3600 { return l.t("\(n / 60) мин \(n % 60) с", "\(n / 60)m \(n % 60)s") }
        return l.t("\(n / 3600) ч \(n % 3600 / 60) мин", "\(n / 3600)h \(n % 3600 / 60)m")
    }

    private func ru(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let a = n % 100, b = n % 10
        if (11...14).contains(a) { return many }
        if b == 1 { return one }
        if (2...4).contains(b) { return few }
        return many
    }
}
