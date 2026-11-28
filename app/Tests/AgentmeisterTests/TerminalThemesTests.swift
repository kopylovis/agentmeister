import XCTest
@testable import Agentmeister

@MainActor
final class TerminalThemesTests: XCTestCase {
    func testGhosttyTheme() throws {
        var lines = ["# comment = ignored", "background = 1d1f21", "foreground = #C5C8C6", "cursor-color = #fff",
                     "selection-background = 373b41"]
        for i in 0..<16 { lines.append("palette = \(i)=#\(String(format: "%02x", i))0000") }
        let theme = try TerminalThemes.fromGhostty(lines.joined(separator: "\n"), name: "Tomorrow Night Copy")
        XCTAssertEqual(theme.id, "user-tomorrow-night-copy")
        XCTAssertEqual(theme.background, "#1d1f21")
        XCTAssertEqual(theme.foreground, "#c5c8c6")
        XCTAssertEqual(theme.cursor, "#ffffff")
        XCTAssertEqual(theme.selection, "#373b41")
        XCTAssertEqual(theme.ansi?.count, 16)
        XCTAssertEqual(theme.ansi?[15], "#0f0000")
    }

    func testGhosttyWithoutFullPaletteIsRefused() {
        XCTAssertThrowsError(try TerminalThemes.fromGhostty("background = 000000\nforeground = ffffff\npalette = 0=#000000", name: "x"))
    }

    func testITermColors() throws {
        func color(_ r: Double, _ g: Double, _ b: Double) -> [String: Any] {
            ["Red Component": r, "Green Component": g, "Blue Component": b, "Color Space": "sRGB"]
        }
        var plist: [String: Any] = ["Background Color": color(0, 0.168, 0.211), "Foreground Color": color(0.513, 0.58, 0.588),
                                    "Cursor Color": color(1, 1, 1)]
        for i in 0..<16 { plist["Ansi \(i) Color"] = color(Double(i) / 15, 0, 0) }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let parsed = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let theme = try TerminalThemes.fromITerm(parsed, name: "Solarized Dark (iTerm)")
        XCTAssertEqual(theme.background, "#002b36")
        XCTAssertEqual(theme.foreground, "#839496")
        XCTAssertEqual(theme.cursor, "#ffffff")
        XCTAssertNil(theme.selection)
        XCTAssertEqual(theme.ansi?.last, "#ff0000")
        XCTAssertEqual(theme.id, "user-solarized-dark-iterm")
    }

    func testResolveFallsBackToWindowColors() {
        let unknown = TerminalThemes.resolve("no-such-theme", windowDark: false)
        XCTAssertEqual(unknown.key, "light")
        XCTAssertEqual(TerminalThemes.resolve("dark", windowDark: false).key, "dark")
        let dracula = TerminalThemes.resolve("dracula", windowDark: false)
        XCTAssertEqual(dracula.key, "dracula")
        XCTAssertEqual(dracula.ansi.count, 16)
    }

    func testNormalized() {
        XCTAssertEqual(TerminalThemes.normalized("#ABC"), "#aabbcc")
        XCTAssertNil(TerminalThemes.normalized("#12345"))
        XCTAssertNil(TerminalThemes.normalized("zzzzzz"))
    }
}
