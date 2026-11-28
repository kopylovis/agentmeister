import AppKit
import SwiftTerm

/// Тема терминала: фон, текст, курсор, выделение и 16 цветов ANSI. Цвета строками "#RRGGBB".
/// Встроенные темы "window" и "dark" повторяют прежние настройки: цвета окна (светлые или темные) и всегда темные.
struct TerminalTheme: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var background: String
    var foreground: String
    var cursor: String?
    var selection: String?
    var ansi: [String]?
}

@MainActor
enum TerminalThemes {
    /// Готовые палитры с открытыми лицензиями (Solarized, Gruvbox, Tomorrow, Dracula: MIT).
    static let builtins: [TerminalTheme] = [
        TerminalTheme(id: "solarized-dark", name: "Solarized Dark", background: "#002b36", foreground: "#839496",
                      cursor: "#93a1a1", selection: "#073642", ansi: solarized),
        TerminalTheme(id: "solarized-light", name: "Solarized Light", background: "#fdf6e3", foreground: "#657b83",
                      cursor: "#586e75", selection: "#eee8d5", ansi: solarized),
        TerminalTheme(id: "gruvbox-dark", name: "Gruvbox Dark", background: "#282828", foreground: "#ebdbb2",
                      cursor: "#ebdbb2", selection: "#504945",
                      ansi: ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
                             "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]),
        TerminalTheme(id: "tomorrow-night", name: "Tomorrow Night", background: "#1d1f21", foreground: "#c5c8c6",
                      cursor: "#c5c8c6", selection: "#373b41",
                      ansi: ["#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
                             "#969896", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#ffffff"]),
        TerminalTheme(id: "dracula", name: "Dracula", background: "#282a36", foreground: "#f8f8f2",
                      cursor: "#f8f8f2", selection: "#44475a",
                      ansi: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                             "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]),
    ]

    private static let solarized = ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                                    "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]

    /// Свои темы, импортированные из iTerm2 или Ghostty: по файлу JSON на тему.
    static var userDir: String { (AppDirs.config as NSString).appendingPathComponent("terminal-themes") }

    /// Свои темы читаются с диска один раз: resolve зовется при каждой отрисовке вкладки. Импорт и удаление
    /// сбрасывают кеш, а раздел "Терминал" перечитывает папку, когда открывается.
    private static var cached: [TerminalTheme]?

    static func user() -> [TerminalTheme] {
        if let cached { return cached }
        let themes = readUser()
        cached = themes
        return themes
    }

    static func reloadUser() -> [TerminalTheme] {
        cached = nil
        return user()
    }

    private static func readUser() -> [TerminalTheme] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: userDir)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return names.compactMap { name in
            fm.contents(atPath: (userDir as NSString).appendingPathComponent(name))
                .flatMap { try? JSONDecoder().decode(TerminalTheme.self, from: $0) }
        }
    }

    static func theme(_ id: String) -> TerminalTheme? {
        builtins.first { $0.id == id } ?? user().first { $0.id == id }
    }

    /// Цвета для вкладки. Тема "window" берет светлую или темную пару от окна, "dark" всегда темную.
    struct Resolved: Equatable {
        let key: String
        let background: NSColor
        let foreground: NSColor
        let cursor: NSColor
        let selection: NSColor?
        let ansi: [SwiftTerm.Color]
    }

    static func resolve(_ id: String, windowDark: Bool) -> Resolved {
        // "window" и "dark" не темы из списка: папку тем ради них не читаем
        if id != "window", id != "dark", let t = theme(id), let bg = color(t.background), let fg = color(t.foreground) {
            let ansi = (t.ansi ?? []).compactMap(termColor)
            return Resolved(key: id, background: bg, foreground: fg, cursor: t.cursor.flatMap(color) ?? fg,
                            selection: t.selection.flatMap(color), ansi: ansi.count == 16 ? ansi : SwiftTerm.Color.terminalAppColors)
        }
        let dark = windowDark || id == "dark"
        return Resolved(key: dark ? "dark" : "light", background: dark ? NSColor(hex: 0x08090B) : .white,
                        foreground: dark ? NSColor(hex: 0xD9DBE1) : NSColor(hex: 0x24262B),
                        cursor: dark ? .white : .black, selection: nil, ansi: SwiftTerm.Color.terminalAppColors)
    }

    /// Какая тема уже стоит во вкладке: палитру ставим заново только при смене темы.
    private static var applied: [ObjectIdentifier: String] = [:]

    static func apply(_ r: Resolved, to term: LocalProcessTerminalView) {
        let key = ObjectIdentifier(term)
        guard applied[key] != r.key else { return }
        applied[key] = r.key
        term.nativeBackgroundColor = r.background
        term.nativeForegroundColor = r.foreground
        term.caretColor = r.cursor
        if let selection = r.selection { term.selectedTextBackgroundColor = selection }
        term.installColors(r.ansi)
    }

    // MARK: Импорт

    enum ImportError: Error {
        case unreadable, noColors

        func text(_ l: L) -> String {
            switch self {
            case .unreadable: return l.t("Файл не читается как тема iTerm2 или Ghostty", "The file doesn't read as an iTerm2 or Ghostty theme")
            case .noColors: return l.t("В файле нет фона, текста или 16 цветов ANSI", "The file has no background, foreground or 16 ANSI colors")
            }
        }
    }

    /// Тема из файла .itermcolors (plist) или темы Ghostty (строки "ключ = значение"). Сохраняется в userDir.
    @discardableResult
    static func importFile(_ url: URL) throws -> TerminalTheme {
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        let base = url.deletingPathExtension().lastPathComponent
        let theme: TerminalTheme
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            theme = try fromITerm(plist, name: base)
        } else if let text = String(data: data, encoding: .utf8) {
            theme = try fromGhostty(text, name: base)
        } else {
            throw ImportError.unreadable
        }
        try FileManager.default.createDirectory(atPath: userDir, withIntermediateDirectories: true)
        let out = (userDir as NSString).appendingPathComponent(theme.id.dropFirst("user-".count) + ".json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(theme).write(to: URL(fileURLWithPath: out), options: .atomic)
        cached = nil
        return theme
    }

    static func remove(_ id: String) {
        guard id.hasPrefix("user-") else { return }
        try? FileManager.default.removeItem(atPath: (userDir as NSString).appendingPathComponent(id.dropFirst(5) + ".json"))
        cached = nil
    }

    static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let trimmed = s.split(separator: "-").joined(separator: "-")
        return trimmed.isEmpty ? "theme" : String(trimmed.prefix(40))
    }

    static func fromITerm(_ plist: [String: Any], name: String) throws -> TerminalTheme {
        func hex(_ key: String) -> String? {
            guard let c = plist[key] as? [String: Any],
                  let r = (c["Red Component"] as? NSNumber)?.doubleValue,
                  let g = (c["Green Component"] as? NSNumber)?.doubleValue,
                  let b = (c["Blue Component"] as? NSNumber)?.doubleValue else { return nil }
            return String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }
        let ansi = (0..<16).compactMap { hex("Ansi \($0) Color") }
        guard let bg = hex("Background Color"), let fg = hex("Foreground Color"), ansi.count == 16 else { throw ImportError.noColors }
        return TerminalTheme(id: "user-" + slug(name), name: name, background: bg, foreground: fg,
                             cursor: hex("Cursor Color"), selection: hex("Selection Color"), ansi: ansi)
    }

    static func fromGhostty(_ text: String, name: String) throws -> TerminalTheme {
        var values: [String: String] = [:]
        var ansi = [String?](repeating: nil, count: 16)
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].hasPrefix("#") else { continue }
            if parts[0] == "palette" {
                // palette = 3=#f0c674
                let entry = parts[1].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if entry.count == 2, let i = Int(entry[0]), (0..<16).contains(i), let h = normalized(entry[1]) { ansi[i] = h }
            } else if let h = normalized(parts[1]) {
                values[parts[0]] = h
            }
        }
        let full = ansi.compactMap { $0 }
        guard let bg = values["background"], let fg = values["foreground"], full.count == 16 else { throw ImportError.noColors }
        return TerminalTheme(id: "user-" + slug(name), name: name, background: bg, foreground: fg,
                             cursor: values["cursor-color"], selection: values["selection-background"], ansi: full)
    }

    /// "#abc", "abcdef" или "#ABCDEF" -> "#abcdef"; иное nil.
    static func normalized(_ raw: String) -> String? {
        var s = raw.lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + s
    }

    static func color(_ hex: String) -> NSColor? {
        guard let h = normalized(hex), let v = Int(h.dropFirst(), radix: 16) else { return nil }
        return NSColor(hex: UInt32(v))
    }

    static func termColor(_ hex: String) -> SwiftTerm.Color? {
        guard let h = normalized(hex), let v = Int(h.dropFirst(), radix: 16) else { return nil }
        return SwiftTerm.Color(red8: UInt16((v >> 16) & 0xff), green8: UInt16((v >> 8) & 0xff), blue8: UInt16(v & 0xff))
    }
}
