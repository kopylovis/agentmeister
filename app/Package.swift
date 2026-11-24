// swift-tools-version: 6.0
// Спайк десктопного Agentmeister: окно SwiftUI с вкладками на SwiftTerm, в каждой вкладке agentmeister
// запускает Claude Code или Codex как в обычном терминале. Проверяем, тянет ли SwiftTerm TUI агентов.
import PackageDescription

let package = Package(
    name: "AgentmeisterApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "AgentmeisterSpike",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/AgentmeisterSpike"
        ),
    ],
    swiftLanguageModes: [.v5]
)
