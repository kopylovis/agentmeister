// swift-tools-version: 6.2
// Десктопный Agentmeister: окно SwiftUI с боковой панелью проектов и вкладками на SwiftTerm. В каждой вкладке
// agentmeister запускает Claude Code или Codex как в обычном терминале, с proxy и sandbox-exec.
// Состояние (проекты, сессии, proxy, режимы) приложение берет из agentmeister app-state.
import PackageDescription

let package = Package(
    name: "AgentmeisterApp",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Agentmeister",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Agentmeister"
        ),
    ],
    swiftLanguageModes: [.v5]
)
