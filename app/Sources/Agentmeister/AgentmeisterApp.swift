import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Пока приложение собирается как исполняемый файл без .app, macOS сама не дает ему Dock и меню
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Appearance.apply(UserDefaults.standard.string(forKey: Appearance.key) ?? "system")
        UserDefaults.standard.removeObject(forKey: "hotkey.taken")
        if UserDefaults.standard.object(forKey: "hotkey.showApp") as? Bool ?? true { registerShowHotKey() }
    }

    /// ⌃⌥Space из любого приложения показывает Agentmeister. ⌥Space не берем: его занимает ChatGPT. Глобальная клавиша через Carbon, без Универсального доступа.
    private func registerShowHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                NSApp.activate()
                NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Agentmeister" }?
                    .makeKeyAndOrderFront(nil)
            }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x414D5354), id: 1)  // "AMST"
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | controlKey), id, GetApplicationEventTarget(), 0, &hotKey)
        // клавишу уже заняло другое приложение: настройки покажут это вместо молчаливого отказа
        if status != noErr { UserDefaults.standard.set(true, forKey: "hotkey.taken") }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Выход останавливает всех агентов. Если кто-то из них может сейчас работать, сначала спрашиваем.
    /// У Claude Code это статус busy из реестра. Codex статуса не пишет, поэтому занятой считается любая
    /// вкладка Codex, пока ее процесс жив.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = Workspace.main?.tabs.filter { tab in
            tab.running && (tab.status == "busy" || (tab.spec.agent == .codex && tab.spec.utility == nil))
        }.count ?? 0
        guard busy > 0 else { return .terminateNow }
        let l = L(UserDefaults.standard.string(forKey: "lastLang") ?? "en")
        let alert = NSAlert()
        alert.messageText = l.t("Закрыть Agentmeister?", "Quit Agentmeister?")
        alert.informativeText = l.t("Агенты во вкладках (\(busy)) могут быть посреди ответа и остановятся. Переписки сохранятся, вкладки вернутся при следующем запуске.",
                                    "Agents in \(busy) tab(s) may be mid-answer and will stop. Transcripts are kept and tabs come back next launch.")
        alert.addButton(withTitle: l.t("Отмена", "Cancel"))
        alert.addButton(withTitle: l.t("Закрыть", "Quit"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // обычный выход: при следующем запуске вкладки откроются без вопроса
        UserDefaults.standard.set(true, forKey: Workspace.cleanExitKey)
        // окно закрылось: уведомления снова нужны для всех вкладок
        let front = (NSHomeDirectory() as NSString).appendingPathComponent(".cache/mnrh/app/front.json")
        try? FileManager.default.removeItem(atPath: front)
    }
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
        .windowStyle(.hiddenTitleBar)
        Window(L(backend.state.lang).t("Сессии", "Sessions"), id: "library") {
            LibraryView()
                .environmentObject(backend)
                .environmentObject(workspace)
                .environmentObject(ui)
        }
        .defaultSize(width: 1180, height: 720)
        Window(L(backend.state.lang).t("Статистика", "Usage"), id: "usage") {
            UsageView()
                .environmentObject(backend)
                .environmentObject(workspace)
                .environmentObject(ui)
        }
        .defaultSize(width: 980, height: 760)
        Settings {
            SettingsView()
                .environmentObject(backend)
                .environmentObject(workspace)
                .environmentObject(ui)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            let l = L(backend.state.lang)
            CommandGroup(replacing: .newItem) {
                Button(l.newSession + "…") {
                    ui.newSessionProject = workspace.current?.spec.projectPath
                    ui.showNewSession = true
                }
                .keyboardShortcut("n")
                Button(l.newTab) {
                    if !workspace.newTab() { ui.showNewSession = true }
                }
                .keyboardShortcut("t")
                // только когда впереди главное окно: в Настройках, Сессиях и других окнах ⌘W закрывает само окно,
                // а не вкладку с агентом
                Button(l.closeTab) { workspace.close(workspace.selected) }
                    .keyboardShortcut("w")
                    .disabled(workspace.current == nil || !ui.mainKey)
                Button(l.restart) { workspace.current?.restartPreferred(note: l.updating) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(workspace.current == nil || !ui.mainKey)
                Divider()
                Button(l.t("Параллельная задача…", "Parallel task…")) {
                    ui.newSessionProject = workspace.current?.spec.projectPath
                    ui.newSessionParallel = true
                    ui.showNewSession = true
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button(l.t("Спросить другой проект", "Ask another project")) { workspace.typeInClaude("/ask ") }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!workspace.hasClaudeTab)
                Button(l.t("Снимок окна", "Window screenshot")) { workspace.typeInClaude("/shot ") }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!workspace.hasClaudeTab)
            }
            CommandGroup(after: .windowList) {
                OpenLibraryButton(title: l.t("Сессии", "Sessions"))
                OpenUsageButton(title: l.t("Статистика", "Usage"))
            }
            CommandGroup(before: .sidebar) {
                Button(l.t("Палитра команд", "Command palette")) { ui.showPalette = true }
                    .keyboardShortcut("k")
                Divider()
            }
            CommandGroup(after: .sidebar) {
                Button(l.t("Свернуть или развернуть проекты", "Collapse or expand projects")) { ui.sidebarCollapsed.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button(l.inspector) { ui.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .help) {
                Button(l.t("Мастер первого запуска", "First-run setup")) { ui.showOnboarding = true }
            }
            CommandMenu(l.t("Вкладки", "Tabs")) {
                ForEach(1..<10) { n in
                    Button(l.t("Вкладка \(n)", "Tab \(n)")) { workspace.select(number: n) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))))
                }
                Divider()
                Button(l.t("Следующая вкладка", "Next tab")) { workspace.selectNeighbor(1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button(l.t("Предыдущая вкладка", "Previous tab")) { workspace.selectNeighbor(-1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Button(l.t("К вкладке, которая ждет", "Jump to the waiting tab")) {
                    if let tab = workspace.tabs.first(where: { $0.status == "waiting" }) { workspace.selected = tab.id }
                }
                .keyboardShortcut("j")
            }
        }
    }
}
