import AppKit
import SwiftUI

/// Цвета из макета (am-design, Main.dc.html и др.). У каждого два значения: для темной и светлой темы.
extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func white(_ a: CGFloat) -> NSColor { NSColor(white: 1, alpha: a) }
    static func black(_ a: CGFloat) -> NSColor { NSColor(white: 0, alpha: a) }
}

enum Ink {
    static let text = Color(light: NSColor(hex: 0x1B1C20), dark: NSColor(hex: 0xECEDF1))
    static let text2 = Color(light: NSColor(hex: 0x3A3D45), dark: NSColor(hex: 0xC9CCD4))
    static let muted = Color(light: NSColor(hex: 0x5B5F69), dark: NSColor(hex: 0xA9ADB8))
    static let faint = Color(light: NSColor(hex: 0x646873), dark: NSColor(hex: 0x9095A1))
    static let link = Color(light: NSColor(hex: 0x1F5FD1), dark: NSColor(hex: 0x8DB8FF))
    static let strong = Color(light: .black, dark: .white)

    static let teal = Color(light: NSColor(hex: 0x0E7A6D), dark: NSColor(hex: 0x8FE3D6))
    static let tealChip = Color(light: NSColor(hex: 0x1F8F82, alpha: 0.12), dark: NSColor(hex: 0x3FB6A8, alpha: 0.14))
    static let tealDot = Color(hex: 0x3FB6A8)
    static let amber = Color(light: NSColor(hex: 0x9A5800), dark: NSColor(hex: 0xF0AE4A))
    static let amberDot = Color(hex: 0xF0AE4A)
    static let direct = Color(light: NSColor(hex: 0x9A5800), dark: NSColor(hex: 0xE3B47E))
    static let red = Color(light: NSColor(hex: 0xA3271F), dark: NSColor(hex: 0xF7A19B))
    static let redChip = Color(light: NSColor(hex: 0xE5534B, alpha: 0.10), dark: NSColor(hex: 0xE5534B, alpha: 0.14))
    static let redBorder = Color(light: NSColor(hex: 0xE5534B, alpha: 0.35), dark: NSColor(hex: 0xE5534B, alpha: 0.40))
    static let savedDot = Color(light: NSColor(hex: 0xB5B8C0), dark: NSColor(hex: 0x5A5E68))

    static let card = Color(light: .black(0.035), dark: .white(0.05))
    static let chip = Color(light: .black(0.05), dark: .white(0.06))
    static let openBg = Color(light: .black(0.04), dark: .white(0.06))
    static let thumb = Color(light: .white(0.96), dark: .white(0.16))
    static let hover = Color(light: NSColor(hex: 0x2F6FE4, alpha: 0.12), dark: NSColor(hex: 0x8DB8FF, alpha: 0.18))
    static let hairline = Color(light: .black(0.08), dark: .white(0.10))
    static let buttonBg = Color(light: .white(0.75), dark: .white(0.08))
    static let buttonBorder = Color(light: .black(0.10), dark: .white(0.12))

    static let claudeBadgeBg = Color(light: NSColor(hex: 0xF0AE4A, alpha: 0.28), dark: NSColor(hex: 0xF0AE4A, alpha: 0.22))
    static let claudeBadge = Color(light: NSColor(hex: 0x7A4300), dark: NSColor(hex: 0xF5C37A))
    static let codexBadgeBg = Color(light: NSColor(hex: 0x2F6FE4, alpha: 0.15), dark: NSColor(hex: 0x8DB8FF, alpha: 0.22))
    static let codexBadge = Color(light: NSColor(hex: 0x1F5FD1), dark: NSColor(hex: 0xAFCBFF))

    static let modeOnBg = Color(light: NSColor(hex: 0x2F6FE4, alpha: 0.14), dark: NSColor(hex: 0x2F6FE4, alpha: 0.30))
    static let modeOnBorder = Color(light: NSColor(hex: 0x2F6FE4, alpha: 0.35), dark: NSColor(hex: 0x8DB8FF, alpha: 0.45))
    static let modeOn = Color(light: NSColor(hex: 0x1F4FB0), dark: NSColor(hex: 0xD6E4FF))
    static let modeOffBg = Color(light: .white(0.6), dark: .white(0.05))
    static let modeOffBorder = Color(light: .black(0.10), dark: .white(0.10))

    /// Подписи полей и групп в диалогах (Auth.dc.html): светлее muted.
    static let label = Color(light: NSColor(hex: 0x4A4E58), dark: NSColor(hex: 0xB4B8C2))
    /// Строки-варианты с кружком выбора: выбранная светлее и с синей рамкой.
    static let optionOnBg = Color(light: .white(0.9), dark: .white(0.12))
    static let optionOnBorder = Color(light: NSColor(hex: 0x2F6FE4, alpha: 0.55), dark: NSColor(hex: 0x8DB8FF, alpha: 0.55))
    static let optionOffBg = Color(light: .black(0.03), dark: .white(0.04))
    static let optionOffBorder = Color(light: .black(0.08), dark: .white(0.10))
    static let dotOff = Color(light: .black(0.25), dark: .white(0.35))
    /// Поле ввода и рамка встроенного окна.
    static let field = Color(light: .white(0.8), dark: .black(0.25))
    static let fieldBorder = Color(light: .black(0.10), dark: .white(0.14))
    static let segTrack = Color(light: .black(0.06), dark: .black(0.28))
    static let ringTrack = Color(light: .black(0.10), dark: .white(0.15))
    /// Выбранный сегмент маршрута: бирюзовый через proxy, янтарный напрямую.
    static let tealSegBg = Color(light: NSColor(hex: 0x1F8F82, alpha: 0.18), dark: NSColor(hex: 0x3FB6A8, alpha: 0.32))
    static let tealSeg = Color(light: NSColor(hex: 0x0B5E54), dark: NSColor(hex: 0xA6EDE2))
    static let directSegBg = Color(light: NSColor(hex: 0xD9822B, alpha: 0.20), dark: NSColor(hex: 0xD9822B, alpha: 0.32))
    static let directSeg = Color(light: NSColor(hex: 0x6E3C00), dark: NSColor(hex: 0xF5CC9A))
    /// Янтарная плашка "напрямую" и предупреждения.
    static let warnChip = Color(light: NSColor(hex: 0xD9822B, alpha: 0.14), dark: NSColor(hex: 0xD9822B, alpha: 0.16))
    static let warn = Color(light: NSColor(hex: 0x7A4300), dark: NSColor(hex: 0xF0C38E))
    /// Бирюзовое стекло "Вход выполнен".
    static let tealGlass = Color(light: NSColor(hex: 0x1F8F82, alpha: 0.12), dark: NSColor(hex: 0x3FB6A8, alpha: 0.16))
    static let tealGlassBorder = Color(light: NSColor(hex: 0x1F8F82, alpha: 0.30), dark: NSColor(hex: 0x6FD3C5, alpha: 0.30))
    static let tealBadge = Color(hex: 0x1F8F82)

    /// Фон терминала из макета: почти черный в темной теме, белый в светлой.
    static let terminalBg = Color(light: .white, dark: NSColor(hex: 0x08090B))
}

/// Круглый значок агента: C для Claude Code, X для Codex, терминал для служебной вкладки.
struct AgentBadge: View {
    let agent: LaunchSpec.Agent?
    var size: CGFloat = 18

    var body: some View {
        if let agent, let icon = AgentIcons.icon(agent) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            letter
        }
    }

    private var letter: some View {
        Group {
            if let agent {
                Text(agent == .codex ? "X" : "C")
                    .font(.system(size: size * 0.55, weight: .bold, design: .monospaced))
                    .foregroundStyle(agent == .codex ? Ink.codexBadge : Ink.claudeBadge)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(Ink.muted)
            }
        }
        .frame(width: size, height: size)
        .background(Circle().fill(agent == nil ? Ink.chip : agent == .codex ? Ink.codexBadgeBg : Ink.claudeBadgeBg))
    }
}

/// Иконки агентов из установленных приложений: Claude.app и Codex (у OpenAI это ChatGPT.app с id com.openai.codex).
/// Нет приложения, остается буква на цветном круге.
@MainActor
enum AgentIcons {
    private static var cache: [LaunchSpec.Agent: NSImage] = [:]
    private static var missing: Set<LaunchSpec.Agent> = []

    static func icon(_ agent: LaunchSpec.Agent) -> NSImage? {
        if let image = cache[agent] { return image }
        if missing.contains(agent) { return nil }
        let id = agent == .claude ? "com.anthropic.claudefordesktop" : "com.openai.codex"
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            missing.insert(agent)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[agent] = image
        return image
    }
}

/// Светящаяся точка состояния, как в макете: янтарная ждет, бирюзовая идет, серая сохранена.
struct GlowDot: View {
    let color: Color
    var glow = true
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: glow ? color.opacity(0.85) : .clear, radius: 4)
    }
}

/// Капсула-чип высотой 26 из строки сессии.
struct Chip<Content: View>: View {
    var background: Color = Ink.chip
    var foreground: Color = Ink.text2
    var mono = false
    /// С действием чип становится кнопкой: под курсором рамка и рука, по клику действие.
    var action: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        if let action {
            Button(action: action) { face }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .onHover { hover = $0 }
        } else {
            face
        }
    }

    private var face: some View {
        HStack(spacing: 6, content: content)
            .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(hover ? Ink.buttonBorder : .clear))
            .brightness(hover ? 0.04 : 0)
            .contentShape(Capsule())
    }
}

/// Кнопка-капсула из панели сессии: обычная или красная для "Забыть".
struct CapsuleButton: View {
    let title: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(destructive ? Ink.red : Ink.text)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(destructive ? Ink.redChip : Ink.buttonBg))
                .overlay(Capsule().strokeBorder(destructive ? Ink.redBorder : Ink.buttonBorder))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Заголовок секции мелким полужирным, как "Проекты" и "Режимы" в макете.
struct SectionCaption: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.faint)
    }
}

/// Точка состояния сессии, одна схема на все окно. Зеленая: сессия открыта и ничего не делает. Желтая и мигает:
/// агент работает. Синяя: агент ждет ответа или разрешения. Серая: сессия сохранена, но не открыта.
extension EnvironmentValues {
    /// Эта сторона боковой карточки (список проектов или рельса) сейчас скрыта. Обе живут все время ради размытия
    /// под барами, и скрытая не должна гонять анимации.
    @Entry var sidebarHidden = false
}

struct SessionDot: View {
    let status: String?
    var open = true
    var size: CGFloat = 8
    @State private var dim = false
    @Environment(\.sidebarHidden) private var hidden

    static let idle = Color(hex: 0x3FB66A)
    static let busy = Color(hex: 0xF2C230)
    static let waiting = Color(hex: 0x3D8BFF)

    private var color: Color {
        guard open else { return Ink.savedDot }
        switch status {
        case "busy": return Self.busy
        case "waiting": return Self.waiting
        default: return Self.idle
        }
    }

    var body: some View {
        let busy = open && status == "busy"
        // в скрытой панели точка не пульсирует: repeatForever иначе перерисовывает ее без конца
        let pulse = busy && !hidden
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: open ? color.opacity(0.8) : .clear, radius: 4)
            .opacity(busy && dim ? 0.35 : 1)
            .onAppear { startPulse(pulse) }
            .onChange(of: pulse) { startPulse(pulse) }
            .accessibilityLabel(!open ? "saved" : status == "waiting" ? "waiting for you" : status == "busy" ? "working" : "open")
    }

    private func startPulse(_ on: Bool) {
        if on {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
        } else {
            withAnimation(.default) { dim = false }
        }
    }
}

extension Shape where Self == ConcentricRectangle {
    /// Карточка у края окна: углы концентричны углам самого окна, как у системных панелей macOS 26.
    static var windowCard: ConcentricRectangle { ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true) }
}

/// Кнопка диалога высотой 34: обычная стеклянная или залитая акцентом.
struct PillButton: View {
    let title: String
    var prominent = false
    var small = false
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(busy ? 0 : 1)
                if busy { ProgressView().controlSize(.small).tint(prominent ? .white : nil) }
            }
        }
        .buttonStyle(PillStyle(prominent: prominent, small: small))
    }
}

/// Капсула приложения для любой кнопки: синяя главная или светлая обычная, 34 pt (small 28 pt), подсветка под
/// курсором. Ей заменены системные .glass и .glassProminent, чтобы кнопки во всех окнах были одного вида.
struct PillStyle: ButtonStyle {
    var prominent = false
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent, small: small)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let small: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: small ? 12 : 13, weight: prominent ? .medium : .regular))
                .foregroundStyle(prominent ? .white : Ink.text)
                .lineLimit(1)
                .padding(.horizontal, small ? 12 : 16)
                .frame(minWidth: small ? nil : 96)
                .frame(height: small ? 28 : 34)
                .background(Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor)
                                                     : AnyShapeStyle(hover && enabled ? Ink.hover : Ink.buttonBg))
                    .shadow(color: .black.opacity(prominent ? 0.25 : 0), radius: 4, y: 2))
                .overlay(Capsule().strokeBorder(prominent ? .clear : Ink.buttonBorder))
                .brightness(prominent && hover && enabled ? 0.06 : 0)
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.8 : enabled ? 1 : 0.5)
                .onHover { hover = $0 }
        }
    }
}

/// Чип информационной строки вкладки: капсула 26 pt с тонкой рамкой, значок и подпись, как "Не спать".
/// on подсвечивает включенное состояние.
struct ChipStyle: ButtonStyle {
    var on = false

    func makeBody(configuration: Configuration) -> some View { ChipBody(configuration: configuration, on: on) }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        let on: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .labelStyle(ChipLabelStyle())
                .font(.system(size: 12))
                .foregroundStyle(on ? Ink.modeOn : hover && enabled ? Ink.text : Ink.muted)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(on ? Ink.modeOnBg : hover && enabled ? Ink.hover : .clear))
                .overlay(Capsule().strokeBorder(on ? Ink.modeOnBorder : Ink.buttonBorder))
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.8 : enabled ? 1 : 0.5)
                .onHover { hover = $0 }
        }
    }

    private struct ChipLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) {
                configuration.icon.font(.system(size: 11))
                configuration.title
            }
        }
    }
}


extension View {
    /// Размытая подложка бара над прокруткой: строки, ушедшие под него, видны только пятнами, без затемнения. Край со стороны
    /// списка плавно гаснет, чтобы бар не выглядел отдельной полосой.
    func blurBar(edge: VerticalEdge) -> some View {
        background {
            BackdropBlur(radius: 32)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.75),
                                             .init(color: .clear, location: 1)],
                                     startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top))
                .ignoresSafeArea()
        }
    }
}

/// Чистое размытие того, что под видом, без тона и затемнения, как у материала. AppKit такого не дает,
/// поэтому слой CABackdropLayer с гауссовым фильтром. Если классов нет, остается самый тонкий материал.
struct BackdropBlur: NSViewRepresentable {
    var radius: CGFloat

    final class BlurView: NSView {
        let radius: CGFloat

        init(radius: CGFloat) {
            self.radius = radius
            super.init(frame: .zero)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// Только картинка: клики проходят к тому, что под ним и над ним.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func makeBackingLayer() -> CALayer {
            guard let backdrop = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init(),
                  let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
                  let filter = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
                    .takeUnretainedValue() as? NSObject
            else {
                let fallback = CALayer()
                fallback.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor
                return fallback
            }
            filter.setValue(radius, forKey: "inputRadius")
            filter.setValue(true, forKey: "inputNormalizeEdges")
            backdrop.filters = [filter]
            return backdrop
        }
    }

    func makeNSView(context: Context) -> BlurView { BlurView(radius: radius) }
    func updateNSView(_ view: BlurView, context: Context) {}
}

/// Текущая ветка git для папки: ищет .git вверх по дереву (в worktree это файл со ссылкой gitdir) и читает HEAD.
/// Без git nil, при отсоединенном HEAD короткий хеш.
enum GitHead {
    static func branch(at path: String) -> String? {
        var dir = URL(fileURLWithPath: path)
        let fm = FileManager.default
        while dir.path != "/" {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    guard let link = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = link.split(separator: "\n").first, line.hasPrefix("gitdir: ") else { return nil }
                    let target = String(line.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespaces)
                    gitDir = target.hasPrefix("/") ? URL(fileURLWithPath: target) : dir.appendingPathComponent(target)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
                return head.isEmpty ? nil : String(head.prefix(7))
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}
