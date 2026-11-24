// Окно подтверждения для agentmeister host-run. Исполнитель вне песочницы показывает его, когда сессия
// просит поменять белый список команд. Ответ печатается в stdout: allow, deny, closed или timeout.
//
// У сессии через proxy есть доверие Универсального доступа терминала, поэтому она может посылать
// синтетические клики и нажимать кнопки через Accessibility. Кнопку "Разрешить" так не нажать: у нее нет
// action, клавиатура до нее не доходит, а клик засчитывается, только если событие пришло от устройства
// (у события, которое отправил процесс, в поле источника стоит его pid).
//
// Аргументы: --title (заголовок окна), --heading, --context, --text, --code, --note, --allow, --deny,
// --expiry (строка про тайм-аут, {left} заменяется на оставшееся время) и --timeout в секундах. Без новых
// аргументов окно работает как раньше: заголовок берется из --title, код из --detail.
// Аргументы идут строго парами "--ключ значение": значение, похожее на ключ (код с "--allow" внутри
// строки или целиком), остается значением и не подменяет другой аргумент.
import AppKit

let options: [String: String] = {
    var out: [String: String] = [:]
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let key = args[i]
        guard key.hasPrefix("--"), i + 1 < args.count else {
            note("ignored arguments from \(i + 1): expected --key value pairs")
            break
        }
        if out[key] == nil { out[key] = args[i + 1] }
        i += 2
    }
    return out
}()

func option(_ name: String, _ fallback: String) -> String { options[name] ?? fallback }

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

// Цвета из дизайна (Approve.dc.html), темный и светлый вариант по оформлению системы.
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func themed(dark: NSColor, light: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
}

enum Palette {
    static let text = themed(dark: rgb(0xECEDF1), light: rgb(0x1B1C20))
    static let text2 = themed(dark: rgb(0xD2D5DC), light: rgb(0x3A3D45))
    static let muted = themed(dark: rgb(0xA9ADB8), light: rgb(0x5B5F69))
    static let label = themed(dark: rgb(0xB4B8C2), light: rgb(0x4A4E58))
    static let sheet = themed(dark: rgb(0x282A32, 0.62), light: rgb(0xFFFFFF, 0.70))
    static let sheetBorder = themed(dark: rgb(0xFFFFFF, 0.16), light: rgb(0xFFFFFF, 0.9))
    static let code = themed(dark: rgb(0x000000, 0.35), light: rgb(0x000000, 0.045))
    static let codeBorder = themed(dark: rgb(0xFFFFFF, 0.08), light: rgb(0x000000, 0.06))
    static let codeText = themed(dark: rgb(0xD9DBE1), light: rgb(0x24262B))
    static let iconBg = themed(dark: rgb(0xF0AE4A, 0.24), light: rgb(0xF0AE4A, 0.25))
    static let iconFg = themed(dark: rgb(0xF5C37A), light: rgb(0x7A4300))
    static let confirm = rgb(0x2F6FE4)
}

// Слой с заливкой и рамкой, цвета пересчитываются при смене оформления.
final class Box: NSView {
    var fill: NSColor?
    var border: NSColor?
    var radius: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer = layer else { return }
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.backgroundColor = fill?.cgColor
        layer.borderColor = border?.cgColor
        layer.borderWidth = border == nil ? 0 : 1
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// Документ прокрутки кода: начало текста сверху.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// Окно без рамки: лист со стеклом рисует себя сам. Cmd+W закрывает окно, это отказ.
final class Panel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

func styled(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
            lineSpacing: CGFloat = 0, mono: Bool = false, align: NSTextAlignment = .natural) -> NSAttributedString {
    let font: NSFont = mono ? .monospacedSystemFont(ofSize: size, weight: weight)
                            : .systemFont(ofSize: size, weight: weight)
    let style = NSMutableParagraphStyle()
    style.lineSpacing = lineSpacing
    style.alignment = align
    return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, width: CGFloat,
           lineSpacing: CGFloat = 0, mono: Bool = false, align: NSTextAlignment = .natural) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: "")
    field.attributedStringValue = styled(text, size: size, weight: weight, color: color, lineSpacing: lineSpacing,
                                         mono: mono, align: align)
    field.preferredMaxLayoutWidth = width
    field.isSelectable = mono
    return field
}

func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImageView? {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .medium)) else { return nil }
    let view = NSImageView(image: image)
    view.contentTintColor = color
    return view
}

func pin(_ view: NSView, in box: NSView, inset: NSEdgeInsets) {
    view.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(view)
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: box.topAnchor, constant: inset.top),
        view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset.bottom),
        view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset.left),
        view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset.right),
    ])
}

func countdown(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var ticker: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        let width: CGFloat = 540, padding: CGFloat = 24
        let inner = width - padding * 2
        let timeout = Double(option("--timeout", "120")) ?? 120
        let deadline = Date().addingTimeInterval(timeout)
        var rows: [NSView] = []

        // Значок и заголовок.
        let badge = Box()
        badge.fill = Palette.iconBg
        badge.radius = 18
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([badge.widthAnchor.constraint(equalToConstant: 36),
                                     badge.heightAnchor.constraint(equalToConstant: 36)])
        if let icon = symbol("exclamationmark.shield", size: 17, color: Palette.iconFg) {
            icon.translatesAutoresizingMaskIntoConstraints = false
            badge.addSubview(icon)
            NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                                         icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor)])
        }
        let heading = label(option("--heading", option("--title", "agentmeister")), size: 16, weight: .semibold,
                            color: Palette.text, width: inner - 48)
        var titles: [NSView] = [heading]
        let context = option("--context", "")
        if !context.isEmpty {
            titles.append(label(context, size: 12, color: Palette.label, width: inner - 48))
        }
        let titleStack = NSStackView(views: titles)
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        let header = NSStackView(views: [badge, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: inner).isActive = true
        rows.append(header)

        let text = option("--text", "")
        if !text.isEmpty {
            rows.append(label(text, size: 13, color: Palette.text2, width: inner, lineSpacing: 3))
        }

        let code = option("--code", option("--detail", ""))
        if !code.isEmpty {
            let block = Box()
            block.fill = Palette.code
            block.border = Palette.codeBorder
            block.radius = 16
            let field = label(code, size: 12, color: Palette.codeText, width: inner - 32, lineSpacing: 5, mono: true)
            // длинная команда прокручивается внутри блока: иначе окно выше экрана и кнопок не достать
            let document = FlippedView()
            pin(field, in: document, inset: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = document
            document.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            ])
            pin(scroll, in: block, inset: NSEdgeInsets())
            scroll.heightAnchor.constraint(equalToConstant: min(ceil(field.fittingSize.height) + 28, 260)).isActive = true
            block.layer?.masksToBounds = true
            block.translatesAutoresizingMaskIntoConstraints = false
            block.widthAnchor.constraint(equalToConstant: inner).isActive = true
            rows.append(block)
        }

        let human = option("--note", "")
        if !human.isEmpty {
            var parts: [NSView] = []
            if let lock = symbol("lock", size: 11, color: Palette.muted) { parts.append(lock) }
            parts.append(label(human, size: 12, color: Palette.muted, width: inner - 22))
            let line = NSStackView(views: parts)
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = 8
            line.translatesAutoresizingMaskIntoConstraints = false
            line.widthAnchor.constraint(equalToConstant: inner).isActive = true
            rows.append(line)
        }

        let allow = HumanButton(title: option("--allow", "Разрешить"), target: nil, action: nil)
        allow.bezelStyle = .rounded
        allow.controlSize = .large
        allow.bezelColor = Palette.confirm
        allow.isEnabled = false
        allow.onPress = { finish("allow") }
        let deny = NSButton(title: option("--deny", "Отказать"), target: self, action: #selector(denied))
        deny.bezelStyle = .rounded
        deny.controlSize = .large
        deny.keyEquivalent = "\u{1b}"
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            allow.tintProminence = .primary
            for button in [allow, deny] { button.borderShape = .capsule }
        }
        #endif
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, deny, allow])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: inner).isActive = true
        rows.append(buttons)

        let expiry = option("--expiry", "")
        var expiryField: NSTextField?
        if !expiry.isEmpty {
            let field = label(expiry.replacingOccurrences(of: "{left}", with: countdown(Int(timeout.rounded()))),
                              size: 11, color: Palette.muted, width: inner, align: .right)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: inner).isActive = true
            expiryField = field
            rows.append(field)
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        if expiryField != nil { stack.setCustomSpacing(8, after: buttons) }

        // Лист: стекло macOS 26, на старых системах размытие с рамкой из дизайна.
        let sheet: NSView
        let content = NSView()
        pin(stack, in: content, inset: NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding))
        var glassSheet = false
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 28
            glass.tintColor = Palette.sheet
            content.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = content
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: glass.topAnchor),
                content.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            ])
            sheet = glass
            glassSheet = true
        } else {
            sheet = NSVisualEffectView()
        }
        #else
        sheet = NSVisualEffectView()
        #endif
        if !glassSheet, let blur = sheet as? NSVisualEffectView {
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.maskImage = NSImage(size: NSSize(width: 57, height: 57), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28).fill()
                return true
            }
            blur.maskImage?.capInsets = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
            blur.maskImage?.resizingMode = .stretch
            let tint = Box()
            tint.fill = Palette.sheet
            tint.border = Palette.sheetBorder
            tint.radius = 28
            pin(tint, in: blur, inset: NSEdgeInsets())
            pin(content, in: blur, inset: NSEdgeInsets())
        }
        sheet.translatesAutoresizingMaskIntoConstraints = false
        sheet.widthAnchor.constraint(equalToConstant: width).isActive = true

        window = Panel(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                       styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = option("--title", "agentmeister")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.contentView = sheet
        window.delegate = self
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.setContentSize(sheet.fittingSize)
        window.layoutIfNeeded()
        window.invalidateShadow()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Пауза, чтобы клик, начатый до появления окна, не попал в кнопку.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            allow.armed = true
            allow.isEnabled = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish("timeout") }

        if let field = expiryField, expiry.contains("{left}") {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                let left = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
                field.attributedStringValue = styled(expiry.replacingOccurrences(of: "{left}", with: countdown(left)),
                                                     size: 11, color: Palette.muted, align: .right)
            }
        }
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
