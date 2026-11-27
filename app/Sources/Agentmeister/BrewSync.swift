import Foundation

/// После обновления приложения подтягивает agentmeister и promptsill из Homebrew, если они оттуда стоят.
/// Иначе терминал и строка состояния остаются на старой версии: promptsill из Homebrew стоит в PATH раньше
/// встроенного, и приложение его не трогает.
///
/// Работает только в релизной сборке. Когда версия приложения сменилась, в фоне выполняются brew update и
/// brew upgrade для тех формул kopylovis/tap, что установлены. Формула в tap обновляется через несколько минут
/// после релиза, поэтому, пока brew не отдал agentmeister той же версии, что у приложения, попытка повторяется
/// раз в час, не больше 24 раз на версию. Вывод brew пишется в ~/Library/Logs/Agentmeister/brew-upgrade.log.
enum BrewSync {
    private static let formulas = ["kopylovis/tap/agentmeister", "kopylovis/tap/promptsill"]
    private static let syncedKey = "brewSyncedVersion"
    private static let attemptsKey = "brewSyncAttempts"
    private static let maxAttempts = 24
    /// Переключатель в Настройках > Основные, по умолчанию включено.
    static let enabledKey = "app.brewSync"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private static let queue = DispatchQueue(label: "agentmeister.brew-sync", qos: .utility)

    @MainActor
    static func start() {
        guard Updates.distributed, !Demo.active, enabled,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return }
        queue.async { attempt(version) }
    }

    private static func attempt(_ version: String) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: syncedKey) != version else { return }
        var attempts = defaults.dictionary(forKey: attemptsKey) as? [String: Int] ?? [:]
        let tries = attempts[version, default: 0]
        guard tries < maxAttempts else { return }
        attempts = [version: tries + 1]  // счетчики старых версий не нужны
        defaults.set(attempts, forKey: attemptsKey)

        if sync(version) {
            defaults.set(version, forKey: syncedKey)
        } else {
            queue.asyncAfter(deadline: .now() + 3600) { attempt(version) }
        }
    }

    /// true, когда делать больше нечего: Homebrew нет, наших формул в нем нет или agentmeister уже нужной версии.
    private static func sync(_ version: String) -> Bool {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return true }
        let listed = run(brew, ["list", "--formula", "--full-name"], log: false)
        let installed = formulas.filter { name in listed.text.split(separator: "\n").contains { $0 == name } }
        guard listed.ok, !installed.isEmpty else { return listed.ok }

        log("agentmeister \(version): brew update, brew upgrade \(installed.joined(separator: " "))")
        _ = run(brew, ["update", "--quiet"])
        _ = run(brew, ["upgrade"] + installed)

        guard installed.contains(formulas[0]) else { return true }
        let versions = run(brew, ["list", "--versions", formulas[0]], log: false).text
        let current = versions.split(separator: " ").dropFirst().map(String.init)
        let done = current.contains(version)
        log(done ? "agentmeister \(version) из Homebrew на месте" : "в Homebrew пока \(versions), повтор через час")
        return done
    }

    private static func run(_ brew: String, _ args: [String], log logging: Bool = true) -> (ok: Bool, text: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: brew)
        task.arguments = args
        var env = LoginEnvironment.shared
        // update уже сделан отдельно, подсказки и проверка зависимых формул в логе не нужны
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        task.environment = env
        let out = Pipe()
        task.standardOutput = out
        task.standardError = out
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if logging { log("$ brew \(args.joined(separator: " ")) [\(task.terminationStatus)]\n\(text)") }
            return (task.terminationStatus == 0, text)
        } catch {
            if logging { log("$ brew \(args.joined(separator: " ")): \(error.localizedDescription)") }
            return (false, "")
        }
    }

    private static func log(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Agentmeister")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("brew-upgrade.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("[\(stamp)] \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }
}
