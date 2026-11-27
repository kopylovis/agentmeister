import Foundation
import Testing
@testable import Agentmeister

@Test func translateInputBetweenLastRules() {
    let rule = String(repeating: "─", count: 40)
    let rows = ["● UserPromptSubmit operation blocked by hook:", "  Original prompt: как зовут", "", rule,
                "❯ Я пишу многострочный текст, потому что", "  нужно [Image #2]", "  Тут шифт энтер [Image #3]", rule,
                "  Opus 5.5 high · proxy GE"]
    let text = AppTerminalView.inputText(rows)
    #expect(AppTerminalView.sameInput(text, "Я пишу многострочный текст, потому что нужно [Image #2]\nТут шифт энтер [Image #3]"))
    #expect(!AppTerminalView.sameInput(text, "Я пишу другой текст"))
    #expect(!AppTerminalView.sameInput("", ""))
    #expect(AppTerminalView.inputText(["❯ text"]) == "")
}

@Test func translateInputCleared() {
    let prompt = "Я пишу многострочный текст\nТут шифт энтер"
    #expect(AppTerminalView.inputCleared("Try \"refactor <filepath>\"", of: prompt))
    #expect(AppTerminalView.inputCleared("", of: prompt))
    #expect(!AppTerminalView.inputCleared("Я пишу многострочный текст", of: prompt))
    #expect(!AppTerminalView.inputCleared(prompt, of: prompt))
}

@Test func translatePiecesSwapImagesForFiles() {
    let a = URL(fileURLWithPath: "/tmp/a.png"), b = URL(fileURLWithPath: "/tmp/b.png")
    let pieces = AppTerminalView.translationPieces("Look at [Image #2]\nand [Image #3] here", files: [2: a, 3: b])
    #expect(pieces == [.text("Look at "), .image(a), .text("\nand "), .image(b), .text(" here")])
    #expect(AppTerminalView.translationPieces("[Image #9]", files: [:]) == [.text("[Image #9]")])
    #expect(AppTerminalView.imageNumbers("[Image #3] и [Image #2]") == [2, 3])
}
