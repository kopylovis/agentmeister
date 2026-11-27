import Foundation

/// Сколько токенов в контексте сессии Claude Code, по ее переписке в ~/.claude/projects. Та же логика, что у
/// claude_slim.context_tokens: последний ответ модели (вход вместе с кэшем) или граница /compact.
enum SessionContext {
    /// Порог, после которого /slim советует /compact. Совпадает с COMPACT_HINT в claude_restart.py.
    static let compactHint = 200_000

    /// Файл переписки по id сессии. Папка проекта зависит от cwd сессии, поэтому ищем по всем и запоминаем.
    nonisolated(unsafe) private static var paths: [String: String] = [:]
    private static let lock = NSLock()

    static func file(_ sessionId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        if let known = paths[sessionId], fm.fileExists(atPath: known) { return known }
        let root = (LoginEnvironment.claudeHome as NSString).appendingPathComponent("projects")
        for dir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let path = "\(root)/\(dir)/\(sessionId).jsonl"
            if fm.fileExists(atPath: path) {
                paths[sessionId] = path
                return path
            }
        }
        return nil
    }

    /// Токены в контексте и размер окна, если он известен.
    struct Usage: Equatable {
        let used: Int
        let size: Int?

        /// Порог "пора сжать": 200 тыс. или 80% окна, если окно меньше.
        var over: Bool { used >= min(SessionContext.compactHint, size.map { $0 * 4 / 5 } ?? .max) }
    }

    /// Контекст сессии Claude Code: токены из переписки, окно из файла promptsill. Окно в переписку не попадает,
    /// его знает только строка состояния, и promptsill пишет его в ~/.cache/promptsill/context/<сессия>.json.
    static func claude(_ sessionId: String) -> Usage? {
        guard let used = tokens(sessionId) else { return nil }
        let cache = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".cache")
        let file = (cache as NSString).appendingPathComponent("promptsill/context/\(sessionId).json")
        let size = FileManager.default.contents(atPath: file)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["size"] as? Int
        return Usage(used: used, size: size.flatMap { $0 > 0 ? $0 : nil })
    }

    /// Контекст треда Codex из его rollout: последнее событие token_count, в нем и токены, и окно модели.
    static func codex(_ threadId: String) -> Usage? {
        guard let path = codexFile(threadId), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let tail: UInt64 = 4 << 20
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            let raw = Data(line)
            guard raw.range(of: Data("\"token_count\"".utf8)) != nil,
                  let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let payload = o["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let used = (info["last_token_usage"] as? [String: Any])?["total_tokens"] as? Int else { continue }
            let window = info["model_context_window"] as? Int
            return Usage(used: used, size: window.flatMap { $0 > 0 ? $0 : nil })
        }
        return nil
    }

    nonisolated(unsafe) private static var codexPaths: [String: String] = [:]

    /// rollout треда: ~/.codex/sessions/ГГГГ/ММ/ДД/rollout-<время>-<id>.jsonl, свежие дни первыми.
    static func codexFile(_ threadId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        if let known = codexPaths[threadId], fm.fileExists(atPath: known) { return known }
        let root = (LoginEnvironment.codexHome as NSString).appendingPathComponent("sessions")
        let suffix = "-\(threadId.lowercased()).jsonl"
        for year in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted(by: >) {
            for month in ((try? fm.contentsOfDirectory(atPath: "\(root)/\(year)")) ?? []).sorted(by: >) {
                for day in ((try? fm.contentsOfDirectory(atPath: "\(root)/\(year)/\(month)")) ?? []).sorted(by: >) {
                    let dir = "\(root)/\(year)/\(month)/\(day)"
                    if let name = (try? fm.contentsOfDirectory(atPath: dir))?.first(where: { $0.lowercased().hasSuffix(suffix) }) {
                        codexPaths[threadId] = "\(dir)/\(name)"
                        return codexPaths[threadId]
                    }
                }
            }
        }
        return nil
    }

    /// 84k, 279k, 1M, 1.2M, как в строке promptsill.
    static func short(_ n: Int) -> String {
        if n < 1_000_000 { return "\(max(1, Int((Double(n) / 1000).rounded())))k" }
        let m = (Double(n) / 1_000_000 * 10).rounded() / 10
        return (m == m.rounded() ? String(Int(m)) : String(m)) + "M"
    }

    static func tokens(_ sessionId: String) -> Int? {
        guard let path = file(sessionId), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let tail: UInt64 = 8 << 20
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            let raw = Data(line)
            guard raw.range(of: Data("\"usage\"".utf8)) != nil || raw.range(of: Data("\"compact_boundary\"".utf8)) != nil,
                  let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  o["isSidechain"] as? Bool != true else { continue }
            if o["type"] as? String == "system", o["subtype"] as? String == "compact_boundary" {
                return (o["compactMetadata"] as? [String: Any])?["postTokens"] as? Int
            }
            if o["type"] as? String == "assistant",
               let usage = (o["message"] as? [String: Any])?["usage"] as? [String: Any] {
                let total = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                    .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
                if total > 0 { return total }
            }
        }
        return nil
    }
}
