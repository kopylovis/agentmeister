import Foundation
import SwiftTerm
import Testing
@testable import Agentmeister

@Test func codexDraftRepeatingASentPrompt() {
    let terminal = HeadlessTerminal { _ in }
    let screen = "\u{1b}[1;2m› \u{1b}[0mBuild README\r\n\u{1b}[1m›\u{1b}[0m Build README"
    terminal.dataReceived(slice: Array(screen.utf8)[...])
    let rows = terminal.terminalContentSnapshot(region: .all).rows
    let marks = rows.compactMap { PromptIndex.mark($0, agent: .codex) }
    let prompt = SessionPrompt(text: "Build `README`\nThen run the tests", date: .distantPast, agent: .codex)
    let entries = SessionPrompts.merge(marks, [prompt], agent: .codex)
    #expect(marks.map(\.row) == [0])
    #expect(entries.compactMap(\.mark) == marks)
    #expect(entries.first?.text == prompt.text)
}

@Test func codexRolloutFormats() {
    func text(_ event: [String: Any]) -> String? {
        SessionPrompts.codexText(["type": "event_msg", "payload": event])
    }
    let blocks = [["type": "text", "text": "Build"], ["type": "text", "text": "the app"]]
    #expect(text(["type": "item_completed", "item": ["type": "UserMessage", "content": blocks]]) == "Build\nthe app")
    #expect(text(["type": "user_message", "message": "Build the app"]) == "Build the app")
    #expect(text(["type": "item_completed", "item": ["type": "AgentMessage", "content": blocks]]) == nil)
}
