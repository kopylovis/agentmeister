import AppKit
import SwiftUI

/// Лист с выводом команды agentmeister вместо вкладки терминала: что идет, сколько, чем кончилось.
/// Пока команда идет, ее можно остановить или скрыть лист, она продолжит работать.
struct CommandSheet: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var run: CommandRun
    @State private var copied = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            status
            log
            footer
            if run.phase == .running {
                Text(l.t("Скрыть оставляет команду идти. Кнопка, которой ее запустили, показывает индикатор и по клику открывает лист снова. Если команда упадет, лист откроется сам.",
                         "Hide keeps the command running. The button that started it shows a spinner and opens this sheet again. If the command fails, the sheet opens by itself."))
                    .font(.system(size: 11)).foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 620)
    }

    private var tint: (fg: Color, bg: Color) {
        switch run.phase {
        case .running: return (Ink.link, Ink.hover)
        case .done: return (Ink.teal, Ink.tealChip)
        case .failed: return (Ink.red, Ink.redChip)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: run.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint.fg)
                .frame(width: 32, height: 32)
                .background(Circle().fill(tint.bg))
            VStack(alignment: .leading, spacing: 3) {
                Text(run.title).font(.system(size: 15, weight: .semibold))
                Text(run.command)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.faint)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            switch run.phase {
            case .running:
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: run.started, by: 1)) { _ in
                    Text(l.t("Идет ", "Running ") + Self.clock(run.duration, l))
                }
            case .done:
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                Text(l.t("Готово за ", "Done in ") + Self.clock(run.duration, l))
            case .failed:
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                Text(failure).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(tint.fg)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.bg))
        .overlay {
            if run.phase == .failed { RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.redBorder) }
        }
    }

    private var failure: String {
        if run.stopped { return l.t("Остановлено", "Stopped") }
        let head = l.t("Не прошло, код \(run.code ?? 1)", "Failed, exit code \(run.code ?? 1)")
        return run.reason.map { head + ". " + $0 } ?? head
    }

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.colored(run.lines.suffix(2000), empty: run.phase == .running ? "" :
                                        l.t("Команда ничего не вывела.", "The command printed nothing.")))
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(height: 260)
            .background(RoundedRectangle(cornerRadius: 10).fill(Ink.terminalBg))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.fieldBorder))
            .onChange(of: run.output) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(copied ? l.t("Скопировано", "Copied") : l.t("Скопировать вывод", "Copy output")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.output, forType: .string)
                copied = true
            }
            .buttonStyle(.link).font(.system(size: 12))
            .disabled(run.output.isEmpty)
            if run.phase == .failed && !run.stopped {
                Button(l.t("Открыть в терминале", "Open in Terminal")) { openInTerminal() }
                    .buttonStyle(.link).font(.system(size: 12))
            }
            Spacer()
            switch run.phase {
            case .running:
                // цвет у самой подписи: PillStyle красит подпись в обычный цвет текста
                Button(role: .destructive) { run.stop() } label: { Text(l.t("Остановить", "Stop")).foregroundStyle(Ink.red) }
                    .buttonStyle(PillStyle())
                Button(l.t("Скрыть", "Hide")) { CommandRuns.shared.hide(run) }
                    .buttonStyle(PillStyle())
                    .keyboardShortcut(.cancelAction)
            case .done, .failed:
                Button(run.phase == .done ? l.t("Запустить снова", "Run again") : l.t("Повторить", "Try again")) { again() }
                    .buttonStyle(PillStyle())
                Button(run.phase == .done ? l.t("Готово", "Done") : l.t("Закрыть", "Close")) { CommandRuns.shared.dismiss(run) }
                    .buttonStyle(PillStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func again() {
        CommandRuns.shared.start(run.args, title: run.title, icon: run.icon, host: run.host, sheet: true,
                                 onFinish: run.onFinish)
    }

    /// Запасной путь: та же команда во вкладке-утилите главного окна, где она может спросить что-то сама.
    private func openInTerminal() {
        CommandRuns.shared.dismiss(run)
        var spec = LaunchSpec(projectName: "agentmeister", projectPath: NSHomeDirectory())
        spec.utility = run.args
        workspace.open(spec)
        openWindow(id: "main")
    }

    static func clock(_ t: TimeInterval, _ l: L) -> String {
        let s = max(Int(t.rounded(.down)), 0)
        return s < 60 ? l.t("\(s) с", "\(s) s") : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Вывод с подсветкой значков в начале строки: ✓ бирюзой, ✗ и Error красным, ! янтарем.
    static func colored(_ lines: ArraySlice<String>, empty: String) -> AttributedString {
        guard lines.contains(where: { !$0.isEmpty }) else {
            var text = AttributedString(empty)
            text.foregroundColor = Ink.faint
            return text
        }
        var out = AttributedString()
        for (i, line) in lines.enumerated() {
            let trimmed = line.drop { $0 == " " }
            var part = AttributedString(line)
            part.foregroundColor = Ink.text2
            if trimmed.hasPrefix("✗") || trimmed.hasPrefix("Error") || trimmed.hasPrefix("error:") {
                part.foregroundColor = Ink.red
            } else if trimmed.hasPrefix("✓"), let r = part.range(of: "✓") {
                part[r].foregroundColor = Ink.teal
            } else if trimmed.hasPrefix("!"), let r = part.range(of: "!") {
                part[r].foregroundColor = Ink.amber
            }
            out += part
            if i < lines.count - 1 { out += AttributedString("\n") }
        }
        return out
    }
}

/// Показывать листы команд, запущенных в этом окне.
struct CommandSheets: ViewModifier {
    let host: CommandHost
    @ObservedObject private var runs = CommandRuns.shared

    func body(content: Content) -> some View {
        content
            .environment(\.commandHost, host)
            .sheet(item: Binding(get: { runs.shown[host] }, set: { new in
                if let new { runs.show(new) } else if let old = runs.shown[host] { runs.hide(old) }
            })) { run in
                CommandSheet(run: run)
            }
    }
}

extension View {
    func commandSheets(_ host: CommandHost) -> some View { modifier(CommandSheets(host: host)) }
}
