import Foundation
import Testing
@testable import Agentmeister

@Test func utf8ChunksKeepLettersSplitAcrossReads() {
    let text = "✓ Готово, порт 17890\n✗ не прошло"
    let chunks = UTF8Chunks()
    var out = ""
    for byte in Array(text.utf8) { out += chunks.feed(Data([byte])) }
    out += chunks.flush()
    #expect(out == text)
}

@MainActor
private func wait(_ run: CommandRun) async {
    for _ in 0..<200 where run.phase == .running { try? await Task.sleep(for: .milliseconds(50)) }
}

@MainActor
@Test func commandRunCollectsOutputAndExitCode() async throws {
    try #require(LoginEnvironment.found)
    let ok = CommandRun(args: ["--version"], title: "version", icon: "terminal", host: .main)
    ok.start()
    await wait(ok)
    #expect(ok.phase == .done)
    #expect(ok.code == 0)
    #expect(ok.output.trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil)

    let bad = CommandRun(args: ["--harness", "nope"], title: "bad", icon: "terminal", host: .main)
    bad.start()
    await wait(bad)
    #expect(bad.phase == .failed)
    #expect(bad.code == 2)
    #expect(bad.reason?.contains("--harness") == true)
}

@MainActor
@Test func inputToACommandThatDoesNotReadItDoesNotCrash() async throws {
    try #require(LoginEnvironment.found)
    // --version выходит, не читая stdin: запись в закрытый канал должна дать ошибку, а не SIGPIPE
    let run = CommandRun(args: ["--version"], title: "version", icon: "terminal", host: .main)
    run.input = String(repeating: "x", count: 200_000)
    run.start()
    await wait(run)
    #expect(run.phase == .done)
}
