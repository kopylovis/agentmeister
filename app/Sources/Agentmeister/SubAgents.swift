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
            let meta = (fm.contents(atPath: (dir as NSString).appendingPathComponent("agent-\(id).meta.json"))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            // без метки окончания агент считается идущим, только пока пишет: брошенный упавшей сессией не висит
            let finished = meta["finished"] as? Bool == true || now.timeIntervalSince(modified) > 10 * 60
            out.append(SubAgent(id: id, description: (meta["description"] as? String) ?? id,
                                type: (meta["agentType"] as? String) ?? "agent", file: file, modified: modified, finished: finished))
        }
        return Array(out.sorted { $0.modified > $1.modified }.prefix(8))
    }

    /// Строка переписки агента: его текст или вызов инструмента одной строкой.
    struct Entry: Identifiable {
        let id: Int
        let tool: String?
        let text: String
    }

    /// Последние записи переписки: текст агента и вызовы инструментов. Читается хвост файла, у агентов
    /// со скриншотами переписка бывает в мегабайты.
    static func transcript(_ file: String, limit: Int = 300) -> [Entry] {
        guard let handle = FileHandle(forReadingAtPath: file) else { return [] }
        defer { try? handle.close() }
        let tail: UInt64 = 2 << 20
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        var out: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  o["type"] as? String == "assistant",
                  let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    let text = ((block["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { out.append(Entry(id: out.count, tool: nil, text: text)) }
                case "tool_use":
                    let input = (block["input"] as? [String: Any]) ?? [:]
                    let keys = ["description", "command", "file_path", "pattern", "url", "query", "prompt"]
                    let arg = keys.lazy.compactMap { input[$0] as? String }.first ?? ""
                    let short = arg.split(separator: "\n").first.map(String.init) ?? ""
                    out.append(Entry(id: out.count, tool: (block["name"] as? String) ?? "tool", text: String(short.prefix(160))))
                default: break
                }
            }
        }
        return Array(out.suffix(limit))
    }
}

/// Агент сессии в ряду подзадач: состояние и описание, по клику его переписка.
struct SubAgentChip: View {
    let agent: SubAgent
    let l: L
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
    }
}

/// Переписка агента сессии, обновляется раз в 2 секунды, пока лист открыт. Только чтение: писать агенту
/// можно в самой сессии.
struct SubAgentSheet: View {
    let agent: SubAgent
    let l: L
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SubAgents.Entry]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Ink.faint)
                Text(agent.description).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(agent.type).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.faint)
                Spacer()
                Button(l.t("Готово", "Done")) { dismiss() }
                    .buttonStyle(PillStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            if let entries {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(entries) { entry in
                                if let tool = entry.tool {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(tool).fontWeight(.semibold).foregroundStyle(Ink.teal)
                                        Text(entry.text).foregroundStyle(Ink.muted).lineLimit(1).truncationMode(.middle)
                                    }
                                    .font(.system(size: 12, design: .monospaced))
                                } else {
                                    Text(entry.text).font(.system(size: 13)).foregroundStyle(Ink.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(16)
                        .textSelection(.enabled)
                    }
                    .onChange(of: entries.count) { proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 680, idealWidth: 780, minHeight: 460, idealHeight: 620)
        .task {
            let file = agent.file
            while !Task.isCancelled {
                let now = await Task.detached(priority: .userInitiated) { SubAgents.transcript(file) }.value
                if entries?.count != now.count || entries == nil { entries = now }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
