import AppKit
import Foundation

/// Демо для скриншотов README: Agentmeister --demo <папка> [--scene main|new-session|project|settings].
/// Только в отладочной сборке. Вместо agentmeister ответы берутся из JSON в папке: app-state.json (проекты,
/// сессии, proxy с выдуманными данными), app-state-settings.json и т. п. по первым двум аргументам команды.
/// Вкладки описаны в tabs.json, вместо агента в каждой печатается текст из своего файла. Настоящие ~/.claude и
/// ~/.config/mnrh не читаются, tabs.json, front.json и focus.json настоящего приложения не пишутся, обновления,
/// горячая клавиша и мастер первого запуска выключены. Снимки делает docs/screenshots/shoot.sh.
enum Demo {
    #if DEBUG
    static let dir: String? = argument("--demo").map { ($0 as NSString).expandingTildeInPath }
    #else
    static let dir: String? = nil
    #endif
    static var active: Bool { dir != nil }
    static let scene = argument("--scene") ?? "main"

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Ответ вместо agentmeister <args>: файл по первым двум аргументам, app-state-settings.json для
    /// "app-state settings". Остальные команды в демо ничего не делают.
    static func response(_ args: [String]) -> Result<Data, Error> {
        guard let dir else { return .failure(CocoaError(.featureUnsupported)) }
        let name = args.prefix(2).filter { !$0.hasPrefix("-") }.joined(separator: "-") + ".json"
        guard let data = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent(name)) else {
            return .failure(CocoaError(.fileNoSuchFile))
        }
        return .success(data)
    }

    struct Tab: Decodable {
        let project: String
        let path: String
        let agent: String?
        let direct: Bool?
        let subscription: String?
        let terminal: Bool?
        let remoteControl: Bool?
        /// Файл с текстом, который печатается во вкладке, относительно папки демо.
        let screen: String
        let selected: Bool?
    }

    static func tabs() -> [Tab] {
        guard let dir, let data = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent("tabs.json")) else {
            return []
        }
        return (try? JSONDecoder().decode([Tab].self, from: data)) ?? []
    }

    /// Изменения рабочей копии для инспектора: папки демо не в git, поэтому файлы выдуманы. Есть файл
    /// с большими числами, новый файл и двоичный без чисел (+0 −0), чтобы проверить столбцы цифр.
    static func changes(at path: String) -> GitChanges.Snapshot {
        func file(_ path: String, _ code: String, _ added: Int?, _ removed: Int?) -> GitChange {
            var change = GitChange(path: path, code: code)
            change.added = added
            change.removed = removed
            return change
        }
        return GitChanges.Snapshot(root: path, files: [
            file("docs/retries.md", "??", 24, 0),
            file("docs/retry-flow.png", " M", nil, nil),
            file("src/webhooks/deliver.ts", " M", 100, 2),
            file("src/webhooks/retry.ts", " M", 7, 31),
        ])
    }

    /// Сцена subtasks (и subtasks-list с открытым списком закончившихся): у выбранной вкладки фоновые агенты
    /// и команды, идущие и закончившиеся, чтобы проверить ряд подзадач без настоящей сессии.
    static var subtasks: Bool { active && scene.hasPrefix("subtasks") }

    static func subAgents() -> [SubAgent] {
        let now = Date()
        return [
            SubAgent(id: "demo-a1", description: "Audit the webhook retry policy", type: "Explore", file: "", modified: now, finished: false),
            SubAgent(id: "demo-a2", description: "Find callers of the old ledger API", type: "Explore", file: "",
                     modified: now.addingTimeInterval(-240), finished: true),
        ]
    }

    static func shells() -> [BackgroundShell] {
        let now = Date()
        func shell(_ id: String, _ text: String, _ status: String?, _ code: Int?, _ ago: Double) -> BackgroundShell {
            BackgroundShell(id: id, description: text, command: text, output: nil, started: now.addingTimeInterval(-ago - 600),
                            status: status, exitCode: code, finishedAt: status == nil ? nil : now.addingTimeInterval(-ago))
        }
        return [
            shell("demo-s1", "Merge PR 460 when its new CI is green", nil, nil, 0),
            shell("demo-s2", "Merge PRs 464 and 465 when green", nil, nil, 0),
            shell("demo-s3", "Merge PR 459 when its CI is green", nil, nil, 0),
            shell("demo-s4", "Resume merging remaining mobile and monitoring PRs", nil, nil, 0),
            shell("demo-s5", "Merge PR 425 when its CI is green", nil, nil, 0),
            shell("demo-s6", "Merge security, scripts, generator and pipeline PRs", nil, nil, 0),
            shell("demo-s7", "Run check.sh and full pytest on current master", "completed", 0, 660),
            shell("demo-s8", "Merge PR 462 when its CI is green", "completed", 0, 120),
            shell("demo-s9", "Merge orphaned PRs as their CI turns green", "killed", nil, 300),
            shell("demo-s10", "Merge mobile and monitoring PRs as CI turns green", "failed", 1, 420),
        ]
    }

    static func screenPath(_ name: String) -> String? {
        dir.map { ($0 as NSString).appendingPathComponent(name) }
    }
}
