import SwiftUI

/// Текст агента с разметкой Markdown: заголовки, списки, блоки кода, цитаты, таблицы и разделители. Внутри
/// строки жирный, курсив, `код` и ссылки разбирает AttributedString. Text SwiftUI блочную разметку не показывает,
/// а склеивает строки, поэтому блоки разбираются здесь построчно.
struct MarkdownText: View {
    let text: String
    var size: CGFloat = 13

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .textSelection(.enabled)
        // ссылки идут тем же путем, что клик в терминале: окно Agentmeister через proxy, Chrome через proxy
        // или браузер системы, по настройке или с вопросом. Иначе SwiftUI отдал бы их браузеру системы напрямую
        .environment(\.openURL, OpenURLAction { url in
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .systemAction }
            LinkOpener.open(url, place: BrowserSettings.linkPlace, window: NSApp.keyWindow)
            return .handled
        })
    }

    @ViewBuilder
    private func view(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case let .heading(level, line):
            Text(MarkdownBlocks.inline(line))
                .font(.system(size: size + (level == 1 ? 4 : level == 2 ? 2 : 0), weight: .semibold))
                .foregroundStyle(Ink.text)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        case let .paragraph(lines):
            Text(MarkdownBlocks.inline(lines.joined(separator: "\n")))
                .font(.system(size: size))
                .foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
        case let .list(items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.system(size: size, design: item.marker == "•" ? .default : .monospaced))
                            .foregroundStyle(Ink.muted)
                            .frame(minWidth: 12, alignment: .trailing)
                        Text(MarkdownBlocks.inline(item.text))
                            .font(.system(size: size))
                            .foregroundStyle(Ink.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case let .code(lines):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: size - 1, design: .monospaced))
                    .foregroundStyle(Ink.text2)
                    .fixedSize()
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.card))
        case let .quote(lines):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Ink.hairline).frame(width: 3)
                Text(MarkdownBlocks.inline(lines.joined(separator: "\n")))
                    .font(.system(size: size))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .table(rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(MarkdownBlocks.inline(cell))
                                    .font(.system(size: size - 1, weight: index == 0 ? .semibold : .regular))
                                    .foregroundStyle(index == 0 ? Ink.text : Ink.text2)
                            }
                        }
                        if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.card))
        case .rule:
            Divider()
        }
    }
}

enum MarkdownBlocks {
    struct Item {
        let depth: Int
        let marker: String
        let text: String
    }

    enum Block {
        case heading(Int, String)
        case paragraph([String])
        case list([Item])
        case code([String])
        case quote([String])
        case table([[String]])
        case rule
    }

    private static let listRe = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d{1,3}[.)])\s+(.*)$"#)
    private static let headingRe = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*?)\s*#*\s*$"#)

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var items: [Item] = []
        var quote: [String] = []
        var table: [[String]] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph)); paragraph = [] }
            if !items.isEmpty { blocks.append(.list(items)); items = [] }
            if !quote.isEmpty { blocks.append(.quote(quote)); quote = [] }
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(lines))
                    code = nil
                } else {
                    lines.append(line)
                    code = lines
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                code = []
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1,
               let c = trimmed.first, "-*_".contains(c) {
                flush()
                blocks.append(.rule)
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            if let m = headingRe.firstMatch(in: line, range: range),
               let hashes = Range(m.range(at: 1), in: line), let body = Range(m.range(at: 2), in: line) {
                flush()
                blocks.append(.heading(line[hashes].count, String(line[body])))
                continue
            }
            if trimmed.hasPrefix("|") {
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // строка-разделитель |---|:--:| в таблице не видна
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }
                if table.isEmpty { flush() }
                table.append(cells)
                continue
            }
            if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let m = listRe.firstMatch(in: line, range: range),
               let indent = Range(m.range(at: 1), in: line), let marker = Range(m.range(at: 2), in: line),
               let body = Range(m.range(at: 3), in: line) {
                if items.isEmpty { flush() }
                let mark = String(line[marker])
                items.append(Item(depth: min(line[indent].count / 2, 4), marker: "-*+".contains(mark) ? "•" : mark,
                                  text: String(line[body])))
                continue
            }
            // продолжение пункта списка с отступом остается в этом пункте
            if !items.isEmpty, line.hasPrefix("  "), let last = items.popLast() {
                items.append(Item(depth: last.depth, marker: last.marker, text: last.text + " " + trimmed))
                continue
            }
            if paragraph.isEmpty { flush() }
            paragraph.append(line)
        }
        if let code { blocks.append(.code(code)) }
        flush()
        return blocks
    }

    private static let links = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Разметка внутри строки. Сломанная разметка остается как есть, текстом. Голые адреса Markdown ссылками
    /// не делает, их находит NSDataDetector.
    static func inline(_ text: String) -> AttributedString {
        var out = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let plain = String(out.characters)
        for match in links?.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) ?? [] {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out),
                  out[lower..<upper].link == nil else { continue }
            out[lower..<upper].link = url
        }
        return out
    }
}
