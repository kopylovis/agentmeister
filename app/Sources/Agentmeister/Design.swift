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

    /// Фон терминала из макета: почти черный в темной теме, белый в светлой.
    static let terminalBg = Color(light: .white, dark: NSColor(hex: 0x08090B))
}

/// Круглый значок агента: C для Claude Code, X для Codex, терминал для служебной вкладки.
struct AgentBadge: View {
    let agent: LaunchSpec.Agent?
    var size: CGFloat = 18

    var body: some View {
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
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 6, content: content)
            .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(background))
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
struct SessionDot: View {
    let status: String?
    var open = true
    var size: CGFloat = 8
    @State private var dim = false

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
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: open ? color.opacity(0.8) : .clear, radius: 4)
            .opacity(busy && dim ? 0.35 : 1)
            .onAppear { startPulse(busy) }
            .onChange(of: busy) { startPulse(busy) }
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
