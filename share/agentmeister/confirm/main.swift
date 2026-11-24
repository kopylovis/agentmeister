// Окно подтверждения для agentmeister host-run. Исполнитель вне песочницы показывает его, когда сессия
// просит поменять белый список команд. Ответ печатается в stdout: allow, deny, closed или timeout.
//
// У сессии через proxy есть доверие Универсального доступа терминала, поэтому она может посылать
// синтетические клики и нажимать кнопки через Accessibility. Кнопку "Разрешить" так не нажать: у нее нет
// action, клавиатура до нее не доходит, а клик засчитывается, только если событие пришло от устройства
// (у события, которое отправил процесс, в поле источника стоит его pid).
import AppKit

func option(_ name: String, _ fallback: String) -> String {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

func finish(_ answer: String) -> Never {
    print(answer)
    fflush(stdout)
    exit(answer == "allow" ? 0 : 1)
}

func note(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

final class HumanButton: NSButton {
    var armed = false
    var onPress: () -> Void = {}

    override var acceptsFirstResponder: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    override func keyDown(with event: NSEvent) {}
    override func accessibilityPerformPress() -> Bool { false }

    override func mouseDown(with event: NSEvent) {
        let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        guard source == 0 else {
            note("ignored a click sent by process \(source)")
            return
        }
        guard armed else { return }
        super.mouseDown(with: event)  // подсветка до отпускания кнопки мыши
        guard let window = window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(point) { onPress() }
    }
}

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ note: Notification) {
        let width: CGFloat = 560
        let intro = NSTextField(wrappingLabelWithString: option("--text", ""))
        intro.font = .systemFont(ofSize: 13)
        let detail = NSTextField(wrappingLabelWithString: option("--detail", ""))
        detail.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detail.isSelectable = true
        for field in [intro, detail] {
            field.preferredMaxLayoutWidth = width - 40
        }

        let allow = HumanButton(title: option("--allow", "Разрешить"), target: nil, action: nil)
        allow.bezelStyle = .rounded
        allow.isEnabled = false
        allow.onPress = { finish("allow") }
        let deny = NSButton(title: option("--deny", "Отказать"), target: self, action: #selector(denied))
        deny.bezelStyle = .rounded
        deny.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, deny, allow])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [intro, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(20, after: detail)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = option("--title", "agentmeister")
        window.contentView = stack
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        window.delegate = self
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.layoutIfNeeded()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Пауза, чтобы клик, начатый до появления окна, не попал в кнопку.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            allow.armed = true
            allow.isEnabled = true
        }
        let timeout = Double(option("--timeout", "120")) ?? 120
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish("timeout") }
    }

    @objc func denied() { finish("deny") }

    func windowWillClose(_ notification: Notification) { finish("closed") }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
signal(SIGTERM) { _ in finish("closed") }
app.run()
