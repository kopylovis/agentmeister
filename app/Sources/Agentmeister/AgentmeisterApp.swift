import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Пока приложение собирается как исполняемый файл без .app, macOS сама не дает ему Dock и меню
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AgentmeisterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var backend = Backend()
    @StateObject private var workspace = Workspace()
    @StateObject private var ui = UIState()

    var body: some Scene {
        Window("Agentmeister", id: "main") {
            MainView()
                .environmentObject(backend)
                .environmentObject(workspace)
                .environmentObject(ui)
        }
        Window(L(backend.state.lang).t("Сессии", "Sessions"), id: "library") {
            LibraryView()
                .environmentObject(backend)
                .environmentObject(workspace)
                .environmentObject(ui)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            let l = L(backend.state.lang)
            CommandGroup(replacing: .newItem) {
                Button(l.newSession + "…") {
                    ui.newSessionProject = workspace.current?.spec.projectPath
                    ui.showNewSession = true
                }
                .keyboardShortcut("n")
                Button(l.newTab) {
                    if let spec = workspace.current?.spec {
                        var fresh = spec
                        fresh.resumeId = nil
                        fresh.firstPrompt = ""
                        workspace.open(fresh)
                    } else {
                        ui.showNewSession = true
                    }
                }
                .keyboardShortcut("t")
                Button(l.closeTab) { workspace.close(workspace.selected) }
                    .keyboardShortcut("w")
                    .disabled(workspace.current == nil)
                Button(l.restart) { workspace.current?.restart() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(workspace.current == nil)
            }
            CommandGroup(after: .windowList) {
                OpenLibraryButton(title: l.t("Сессии", "Sessions"))
            }
            CommandGroup(after: .sidebar) {
                Button(l.inspector) { ui.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
            CommandMenu(l.t("Вкладки", "Tabs")) {
                ForEach(1..<10) { n in
                    Button(l.t("Вкладка \(n)", "Tab \(n)")) { workspace.select(number: n) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))))
                }
                Divider()
                Button(l.t("К вкладке, которая ждет", "Jump to the waiting tab")) {
                    if let tab = workspace.tabs.first(where: { $0.status == "waiting" }) { workspace.selected = tab.id }
                }
                .keyboardShortcut("j")
            }
        }
    }
}
