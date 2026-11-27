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
