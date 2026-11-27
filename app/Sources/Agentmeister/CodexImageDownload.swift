import Foundation
import ImageIO
import SwiftTerm
import UniformTypeIdentifiers

enum CodexImageDownload {
    // Codex draws local Markdown links as underlined cells, without an OSC 8 destination.
    static func label(in row: TerminalContentRowSnapshot, at column: Int) -> String? {
        let cells = row.cells
        func isLink(_ i: Int) -> Bool {
            cells.indices.contains(i) && cells[i].attribute.style.contains(.underline)
        }
        guard isLink(column) else { return nil }
        var first = column, last = column
        while isLink(first - 1) { first -= 1 }
        while isLink(last + 1) { last += 1 }
        return cells[first...last].filter { $0.width > 0 }.map { $0.isBlank ? " " : $0.text }.joined()
    }

    static func source(label: String, session: String, project: URL) -> URL? {
        guard let path = SessionContext.codexFile(session),
              let log = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }

        var targets = Set<URL>()
        for line in log.split(separator: 10) where line.contains(UInt8(ascii: "[")) {
            guard line.range(of: Data("\"output_text\"".utf8)) != nil,
                  let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  row["type"] as? String == "response_item",
                  let payload = row["payload"] as? [String: Any], payload["role"] as? String == "assistant",
                  let content = payload["content"] as? [[String: Any]] else { continue }
            for part in content where part["type"] as? String == "output_text" {
                guard let text = part["text"] as? String, text.contains("["),
                      let markdown = try? AttributedString(markdown: text) else { continue }
                for (link, range) in markdown.runs[\.link] {
                    guard let link, String(markdown[range].characters) == label else { continue }
                    targets.insert(link)
                }
                if targets.count > 1 { return nil }
            }
        }
        guard let link = targets.first else { return nil }
        return localImage(link, project: project)
    }

    static func localImage(_ link: URL, project: URL) -> URL? {
        guard link.scheme == nil || link.isFileURL, link.host == nil || link.host == "",
              link.fragment == nil, link.query == nil, !link.path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: link.path, relativeTo: project).standardizedFileURL.resolvingSymlinksInPath()
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let image = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(image) > 0 else { return nil }
        return url
    }

    static func save(_ source: URL, in directory: URL) throws -> URL {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let stem = source.deletingPathExtension().lastPathComponent
        var number = 1
        while true {
            let name = number == 1 ? source.lastPathComponent : "\(stem) (\(number)).\(source.pathExtension)"
            let destination = directory.appendingPathComponent(name)
            do {
                try data.write(to: destination, options: .withoutOverwriting)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                number += 1
            }
        }
    }
}
