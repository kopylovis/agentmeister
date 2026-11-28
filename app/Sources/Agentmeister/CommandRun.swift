import AppKit
import SwiftUI

/// Окно, в котором показывается лист команды. Свой у главного окна, Настроек и мастера первого запуска:
/// лист с одного корня в другом окне не появится.
enum CommandHost: Hashable {
    case main, settings, onboarding, library
}

struct CommandHostKey: EnvironmentKey {
    static let defaultValue: CommandHost = .main
}

extension EnvironmentValues {
    var commandHost: CommandHost {
        get { self[CommandHostKey.self] }
        set { self[CommandHostKey.self] = newValue }
    }
}

/// Команда agentmeister, запущенная из интерфейса без вкладки терминала. Вывод (stdout и stderr вместе, без
/// цветов) копится по мере работы, его показывает CommandSheet.
@MainActor
final class CommandRun: ObservableObject, Identifiable {
    enum Phase { case running, done, failed }

    let id = UUID()
    let args: [String]
    let title: String
    let icon: String
    let host: CommandHost
    let started = Date()
    @Published private(set) var phase: Phase = .running
    @Published private(set) var output = ""
    @Published private(set) var code: Int32?
    @Published private(set) var finished: Date?
    /// Остановлена кнопкой "Остановить", а не упала сама.
    @Published private(set) var stopped = false
    /// Лист закрыли кнопкой "Скрыть", пока команда шла.
    var hidden = false
    /// Запущена с листом, а не кнопкой в строке: такой упавшей команде лист открывается снова.
    var sheet = false
    var onFinish: (() async -> Void)?
    /// Строка для stdin: ссылка, адрес прокси или токен. В аргументах их видно в ps, поэтому они идут так.
    /// Хранится, пока жив объект, чтобы "Повторить" не спрашивал ее снова.
    var input: String?
    private var process: Process?

    /// Больше этого вывод не держим: начало обрезается, конец важнее.
    private static let limit = 400_000

    init(args: [String], title: String, icon: String, host: CommandHost) {
        self.args = args
        self.title = title
        self.icon = icon
        self.host = host
    }

    var command: String { "agentmeister " + args.joined(separator: " ") }

    var duration: TimeInterval { (finished ?? Date()).timeIntervalSince(started) }

    func start() {
        if Demo.active {
            demo()
            return
        }
        guard LoginEnvironment.found else {
            append("agentmeister isn't in PATH\n")
            finish(127)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: LoginEnvironment.agentmeister)
        task.arguments = args
        task.environment = LoginEnvironment.shared
        task.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let stdin = input.map { _ in Pipe() }
        task.standardInput = stdin ?? FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        let decoder = UTF8Chunks()
        // конец потока приходит тем же обработчиком после всех данных, поэтому порядок вывода и итога сохраняется
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                let rest = decoder.flush()
                task.waitUntilExit()
                let status = task.terminationStatus
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if !rest.isEmpty { self?.append(rest) }
                        self?.finish(status)
                    }
                }
                return
            }
            let text = decoder.feed(data)
            guard !text.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.append(text) }
            }
        }
        do {
            try task.run()
            process = task
            if let stdin, let input {
                // команда могла уже выйти: запись в закрытый канал дала бы SIGPIPE и уронила бы приложение.
                // F_SETNOSIGPIPE только у этого дескриптора: запись вернет ошибку. signal(SIGPIPE, SIG_IGN) не годится,
                // его унаследовали бы вкладки терминала, и yes | head в них перестал бы завершаться сам
                _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                try? stdin.fileHandleForWriting.write(contentsOf: Data((input + "\n").utf8))
                try? stdin.fileHandleForWriting.close()
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            append(error.localizedDescription + "\n")
            finish(126)
        }
    }

    func stop() {
        guard phase == .running, let process, process.isRunning else { return }
        stopped = true
        process.terminate()
    }

    private func append(_ text: String) {
        output += text.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        if output.count > Self.limit { output = String(output.suffix(Self.limit)) }
    }

    private func finish(_ status: Int32) {
        code = status
        finished = Date()
        phase = status == 0 && !stopped ? .done : .failed
        process = nil
        CommandRuns.shared.finished(self)
        if let onFinish { Task { await onFinish() } }
    }

    /// Строки для показа: \r внутри строки (прогресс curl, brew) оставляет только то, что после него.
    var lines: [String] {
        output.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line.split(separator: "\r", omittingEmptySubsequences: false).last { !$0.isEmpty } ?? "")
        }
    }

    /// Причина неудачи для строки и листа: последняя непустая строка без значка в начале.
    var reason: String? {
        lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.replacingOccurrences(of: "^\\s*[✗!✓] ", with: "", options: .regularExpression) }
    }

    /// Демо для скриншотов: вывод из Demo.commandOutput, сцена command-running оставляет команду идти.
    private func demo() {
        let (text, status) = Demo.commandOutput(args)
        append(text)
        if Demo.scene == "command-running" { return }
        finish(status)
    }
}

/// Разбор UTF-8 кусками: многобайтная буква может прийти разрезанной между двумя чтениями.
final class UTF8Chunks: @unchecked Sendable {
    private var pending = Data()

    func feed(_ data: Data) -> String {
        pending.append(data)
        // хвост из неполной буквы (до трех байт) ждет следующего куска
        for cut in 0...min(3, pending.count) {
            let head = pending.prefix(pending.count - cut)
            if let text = String(data: head, encoding: .utf8) {
                pending = Data(pending.suffix(cut))
                return text
            }
        }
        let text = String(decoding: pending, as: UTF8.self)
        pending = Data()
        return text
    }

    func flush() -> String {
        defer { pending = Data() }
        return pending.isEmpty ? "" : String(decoding: pending, as: UTF8.self)
    }
}

/// Все команды, запущенные из интерфейса за этот запуск. По ним кнопка узнает, что ее команда еще идет
/// или упала, и какой лист открыть в каком окне.
@MainActor
final class CommandRuns: ObservableObject {
    static let shared = CommandRuns()

    @Published private(set) var runs: [CommandRun] = []
    /// Лист, открытый в окне.
    @Published var shown: [CommandHost: CommandRun] = [:]

    /// Запустить команду. Такая же еще идет: новую не запускаем, а возвращаем ее (и показываем, если надо).
    @discardableResult
    func start(_ args: [String], title: String, icon: String = "terminal", host: CommandHost, sheet: Bool,
               input: String? = nil, onFinish: (() async -> Void)? = nil) -> CommandRun {
        if let running = latest(args), running.phase == .running {
            if sheet { show(running) }
            return running
        }
        let run = CommandRun(args: args, title: title, icon: icon, host: host)
        run.onFinish = onFinish
        run.input = input
        run.sheet = sheet
        run.hidden = !sheet
        runs.removeAll { $0.args == args && $0.phase != .running }
        runs.append(run)
        run.start()
        if sheet { show(run) }
        return run
    }

    func latest(_ args: [String]) -> CommandRun? { runs.last { $0.args == args } }

    /// Идущие команды, у которых аргументы начинаются с этих (все parallel одной ветки, например).
    func latest(where match: ([String]) -> Bool) -> CommandRun? { runs.last { match($0.args) } }

    func show(_ run: CommandRun) {
        run.hidden = false
        shown[run.host] = run
    }

    func hide(_ run: CommandRun) {
        if run.phase == .running { run.hidden = true }
        if shown[run.host] === run { shown[run.host] = nil }
    }

    /// Закрыть лист и забыть законченную команду, чтобы кнопка вернулась в обычный вид.
    func dismiss(_ run: CommandRun) {
        hide(run)
        if run.phase != .running { runs.removeAll { $0 === run } }
    }

    /// Команда закончилась. Если ее лист скрыт и она упала, лист открывается снова: иначе ошибку никто не
    /// увидит. Приложение не впереди: значок в Dock подпрыгивает.
    fileprivate func finished(_ run: CommandRun) {
        objectWillChange.send()
        if run.sheet && run.hidden && run.phase == .failed && !run.stopped && shown[run.host] == nil {
            show(run)
        }
        if let app = NSApp, !app.isActive { app.requestUserAttention(.informationalRequest) }
    }
}
