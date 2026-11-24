import AppKit
import SwiftTerm
import SwiftUI

/// Вкладки окна. Терминалы живут здесь, а не во view, чтобы переключение вкладок не убивало процессы.
final class Workspace: ObservableObject {
    @Published var sessions: [TerminalSession] = []
    @Published var selected: UUID?
    let base: LaunchSpec

    init(base: LaunchSpec) {
        self.base = base
        open(base)
    }

    var current: TerminalSession? { sessions.first { $0.id == selected } }

    func open(_ spec: LaunchSpec) {
        let session = TerminalSession(spec: spec)
        sessions.append(session)
        selected = session.id
    }

    func close(_ id: UUID?) {
        guard let id, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].terminate()
        sessions.remove(at: index)
        if sessions.isEmpty {
            NSApp.terminate(nil)
        } else {
            selected = sessions[min(index, sessions.count - 1)].id
        }
    }

    func select(number: Int) {
        guard number >= 1, number <= sessions.count else { return }
        selected = sessions[number - 1].id
    }

    func restartCurrent() {
        guard let session = current, !session.running else { return }
        session.start()
    }
}

/// Показывает терминал выбранной вкладки. Сам NSView терминала не пересоздается, только меняется местами.
struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let term = session?.view else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if term.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            term.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(term)
            NSLayoutConstraint.activate([
                term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                term.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                term.topAnchor.constraint(equalTo: container.topAnchor),
                term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
    }
}

struct TabButton: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(session.spec.codex ? "X" : "C")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.orange.opacity(0.25)))
                Text(session.title).lineLimit(1).truncationMode(.tail)
                Text(session.spec.direct ? "напрямую" : "proxy")
                    .font(.caption)
                    .foregroundStyle(session.spec.direct ? Color.orange : Color.teal)
                if !session.running {
                    Image(systemName: "stop.circle").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .frame(maxWidth: 240)
            .background(Capsule().fill(selected ? Color.primary.opacity(0.14) : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(workspace.sessions) { session in
                    TabButton(session: session, selected: session.id == workspace.selected) {
                        workspace.selected = session.id
                    }
                }
                Button {
                    workspace.open(workspace.base)
                } label: {
                    Image(systemName: "plus").frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Новая вкладка, ⌘T")
                Spacer()
            }
            .padding(4)
            .background(.bar)
            TerminalHost(session: workspace.current)
        }
        .frame(minWidth: 720, minHeight: 420)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Спайк собирается как обычный исполняемый файл без .app, поэтому macOS по умолчанию не дает ему Dock и меню.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AgentmeisterSpikeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var workspace = Workspace(base: LaunchSpec.parse(CommandLine.arguments))

    var body: some Scene {
        WindowGroup("Agentmeister") {
            WorkspaceView(workspace: workspace)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новая вкладка") { workspace.open(workspace.base) }
                    .keyboardShortcut("t")
                Button("Закрыть вкладку") { workspace.close(workspace.selected) }
                    .keyboardShortcut("w")
                Button("Запустить заново") { workspace.restartCurrent() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Вкладки") {
                ForEach(1..<10) { n in
                    Button("Вкладка \(n)") { workspace.select(number: n) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))))
                }
            }
        }
    }
}
