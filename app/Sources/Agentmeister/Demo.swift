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

    static func screenPath(_ name: String) -> String? {
        dir.map { ($0 as NSString).appendingPathComponent(name) }
    }
}
