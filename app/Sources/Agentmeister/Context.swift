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
        let root = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        for dir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let path = "\(root)/\(dir)/\(sessionId).jsonl"
            if fm.fileExists(atPath: path) {
                paths[sessionId] = path
                return path
            }
        }
        return nil
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
