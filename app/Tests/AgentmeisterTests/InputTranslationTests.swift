import Testing
@testable import Agentmeister

@Test func scrambleEndsOnBothTexts() {
    let ru = "Посмотри на [Image #1]\nи исправь", en = "Look at [Image #1]\nand fix it"
    #expect(InputTranslationOverlay.scramble(ru, into: en, progress: 1, tick: 7) == en)
    #expect(InputTranslationOverlay.scramble(ru, into: ru, progress: 0, tick: 7, noise: 0) == ru)
    let noisy = InputTranslationOverlay.scramble(ru, into: en, progress: 0, tick: 7)
    #expect(noisy.count == ru.count)
    #expect(Array(noisy).enumerated().allSatisfy { i, c in Array(ru)[i].isLetter || c == Array(ru)[i] })
}

@Test func scrambleKeepsImageLabels() {
    let ru = "[Image #10] что написано на картинке?"
    for tick in 0..<20 {
        #expect(InputTranslationOverlay.scramble(ru, into: ru, progress: 0, tick: tick).hasPrefix("[Image #10] "))
    }
}

@Test func translateKeyProviderByShape() {
    #expect(TranslateKey.provider("sk-or-v1-0123456789abcdef0123") == "OpenRouter")
    #expect(TranslateKey.provider("  AIza" + String(repeating: "x", count: 35) + "\n") == "Google AI Studio")
    #expect(TranslateKey.provider("AQ." + String(repeating: "A", count: 40)) == "Google AI Studio")
    #expect(TranslateKey.provider("sk-ant-api03-abc") == nil)
    #expect(TranslateKey.provider("") == nil)
}
