import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pasteMonitor: Any?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Пока приложение собирается как исполняемый файл без .app, macOS сама не дает ему Dock и меню
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Appearance.apply(UserDefaults.standard.string(forKey: Appearance.key) ?? "system")
        // демо для скриншотов не трогает систему: ни горячей клавиши, ни команды в PATH, ни обновлений
        if Demo.active { return }
        // ⌃⌥Space (или свое сочетание из настроек) из любого приложения показывает Agentmeister
        HotKey.shared.apply()
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: AppTerminalView.handleImagePaste)
        // команда agentmeister в терминале из встроенного CLI, если ее еще нигде нет
        DispatchQueue.global(qos: .utility).async { LoginEnvironment.linkCommand() }
        Updates.shared.start()
        // после обновления приложения подтянуть agentmeister и promptsill из Homebrew, если они оттуда
        BrewSync.start()
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

    /// Закрыть и открыть приложение заново (разрешение Записи экрана действует только после перезапуска).
    /// Помощник ждет выхода. Если выход отменили в вопросе о сессиях, terminate возвращается: помощник
    /// снимается, а resumeKey (шаг мастера после перезапуска) убирается, иначе он сработал бы через дни.
    @MainActor static func relaunch(resumeKey: String? = nil) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // собранный бинарник без .app (разработка) запускается сам, .app открывается через open
        let start = Bundle.main.bundleURL.pathExtension == "app" ? "/usr/bin/open \"$0\"" : "\"$0\" >/dev/null 2>&1 &"
        let target = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundlePath
                                                                  : (Bundle.main.executablePath ?? Bundle.main.bundlePath)
        task.arguments = ["-c", "for i in $(seq 300); do kill -0 \(getpid()) 2>/dev/null || { \(start); exit 0; }; sleep 0.2; done",
                          target]
        try? task.run()
        NSApp.terminate(nil)
        task.terminate()
        if let resumeKey { UserDefaults.standard.removeObject(forKey: resumeKey) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Demo.active { return }
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
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
    /// Меню перестраивается, когда в настройках поменяли сочетание
    @ObservedObject private var shortcuts = ShortcutStore.shared
    /// Значок в строке меню, выключается в Настройках > Основные.
    @AppStorage(MenuBarPrefs.showKey) private var showMenuBar = true

    /// Есть ли куда переходить ⌘↑ и ⌘↓: впереди главное окно с вкладкой агента, а не экран проекта.
    private var promptsReady: Bool {
        guard let tab = workspace.current, ui.mainKey, !ui.screenOpen else { return false }
        return tab.spec.claudeSession || (tab.spec.codexSession && tab.view.terminalInputStateSnapshot()?.isAlternateBuffer == false)
    }

    var body: some Scene {
        Window("Agentmeister", id: "main") {
            MainView()
                .environmentObject(backend)
                .environmentObject(workspace)
                .environmentObject(ui)
        }
        .windowStyle(.hiddenTitleBar)
        Window(L(backend.state.lang).t("О программе", "About Agentmeister"), id: "about") {
            AboutView()
                .environmentObject(backend)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
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
        // изменения рабочей копии: одно окно на репозиторий, клик по другому файлу того же репозитория
        // прокручивает уже открытое окно
        WindowGroup(L(backend.state.lang).t("Изменения", "Changes"), id: "changes", for: String.self) { $root in
            ChangesWindow(root: root ?? "")
                .environmentObject(backend)
        }
        .defaultSize(width: 1060, height: 680)
        // привязка только для чтения: MenuBarExtra сам пишет в isInserted при каждом обновлении сцены, запись
        // в @AppStorage снова перестраивает сцену, и главный поток крутился в этом цикле без конца. Значок
        // включает и выключает только переключатель в Настройках.
        MenuBarExtra(isInserted: Binding(get: { showMenuBar && !Demo.active }, set: { _ in })) {
            MenuBarPanel()
                .environmentObject(backend)
                .environmentObject(workspace)
                .environmentObject(ui)
        } label: {
            MenuBarLabel(backend: backend, workspace: workspace)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView()
                .environmentObject(backend)
                .environmentObject(workspace)
                .environmentObject(ui)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            let l = L(backend.state.lang)
            CommandGroup(replacing: .appInfo) {
                AboutCommand(l: l)
            }
            CommandGroup(after: .appInfo) {
                UpdateCommands(l: l)
            }
            CommandGroup(replacing: .newItem) {
                Button(l.newSession + "…") {
                    ui.newSessionProject = workspace.current?.spec.projectPath
                    ui.showNewSession = true
                }
                .shortcut(.newSession)
                Button(l.newTab) {
                    if !workspace.newTab() { ui.showNewSession = true }
                }
                .shortcut(.newTab)
                Button(l.newTerminal) { workspace.openTerminalHere(state: backend.state) }
                    .shortcut(.newTerminal)
                // только когда впереди главное окно: в Настройках, Сессиях и других окнах ⌘W закрывает само окно,
                // а не вкладку с агентом. Пока открыт экран проекта, выбранная вкладка скрыта под ним,
                // поэтому ⌘W закрывает сам экран и возвращает к вкладке, а ⌘R выключен, чтобы не перезапустить
                // агента, которого не видно.
                Button(ui.projectScreen != nil ? l.t("Закрыть экран проекта", "Close project screen")
                       : ui.sessionPreview != nil ? l.t("Закрыть превью сессии", "Close session preview") : l.closeTab) {
                    if ui.screenOpen { ui.projectScreen = nil } else { workspace.close(workspace.selected) }
                }
                    .shortcut(.closeTab)
                    .disabled(!ui.mainKey || (!ui.screenOpen && workspace.current == nil))
                Button(l.restart) { workspace.current?.restartPreferred(note: l.updating) }
                    .shortcut(.restart)
                    .disabled(workspace.current == nil || !ui.mainKey || ui.screenOpen)
                // переход между запросами в выводе Claude Code, как метки в Terminal и iTerm2
                Button(l.t("Предыдущий запрос", "Previous prompt")) { workspace.current?.jumpPrompt(forward: false) }
                    .shortcut(.previousPrompt)
                    .disabled(!promptsReady)
                Button(l.t("Следующий запрос", "Next prompt")) { workspace.current?.jumpPrompt(forward: true) }
                    .shortcut(.nextPrompt)
                    .disabled(!promptsReady)
                Divider()
                Button(l.t("Параллельная задача…", "Parallel task…")) {
                    ui.newSessionProject = workspace.current?.spec.projectPath
                    ui.showParallel = true
                }
                .shortcut(.parallel)
                Button(l.t("Спросить другой проект", "Ask another project")) { workspace.typeInClaude("/ask ") }
                    .shortcut(.ask)
                    .disabled(!workspace.hasClaudeTab)
                Button(l.t("Снимок окна", "Window screenshot")) { workspace.typeInClaude("/shot ") }
                    .shortcut(.shot)
                    .disabled(!workspace.hasClaudeTab)
                Button(l.t("Перевести ввод на английский", "Translate the input to English")) { workspace.current?.translateInput() }
                    .shortcut(.translateInput)
                    .disabled(!(workspace.current?.canTranslateInput ?? false))
            }
            // поиск по терминалу текущей вкладки: панель поиска SwiftTerm, ⌘G и ⇧⌘G по совпадениям
            CommandGroup(after: .textEditing) {
                let canFind = ui.mainKey && !ui.screenOpen && workspace.current != nil
                Divider()
                Button(l.t("Найти…", "Find…")) { workspace.current?.find(.showFindInterface) }
                    .keyboardShortcut("f")
                    .disabled(!canFind)
                Button(l.t("Найти следующее", "Find Next")) { workspace.current?.find(.nextMatch) }
                    .keyboardShortcut("g")
                    .disabled(!canFind)
                Button(l.t("Найти предыдущее", "Find Previous")) { workspace.current?.find(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!canFind)
                Button(l.t("Искать выделенное", "Use Selection for Find")) { workspace.current?.find(.setSearchString) }
                    .keyboardShortcut("e")
                    .disabled(!canFind)
            }
            CommandGroup(after: .windowList) {
                OpenLibraryButton(title: l.t("Сессии", "Sessions"))
                OpenUsageButton(title: l.t("Статистика", "Usage"))
            }
            CommandGroup(before: .sidebar) {
                Button(l.t("Палитра команд", "Command palette")) { ui.showPalette = true }
                    .shortcut(.palette)
                Divider()
            }
            CommandGroup(after: .sidebar) {
                Button(l.t("Свернуть или развернуть проекты", "Collapse or expand projects")) { ui.sidebarCollapsed.toggle() }
                    .shortcut(.sidebar)
                Button(l.inspector) { ui.showInspector.toggle() }
                    .shortcut(.inspector)
            }
            CommandGroup(replacing: .help) {
                Button(l.t("Мастер первого запуска", "First-run setup")) {
                    ui.onboardingStep = 0
                    ui.showOnboarding = true
                }
            }
            CommandMenu(l.t("Вкладки", "Tabs")) {
                ForEach(1..<10) { n in
                    Button(l.t("Вкладка \(n)", "Tab \(n)")) {
                        ui.projectScreen = nil
                        workspace.select(number: n)
                    }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))))
                }
                Divider()
                Button(l.t("Следующая вкладка", "Next tab")) { ui.projectScreen = nil; workspace.selectNeighbor(1) }
                    .shortcut(.nextTab)
                Button(l.t("Предыдущая вкладка", "Previous tab")) { ui.projectScreen = nil; workspace.selectNeighbor(-1) }
                    .shortcut(.previousTab)
                Button(l.t("К вкладке, которая ждет", "Jump to the waiting tab")) {
                    if let tab = workspace.tabs.first(where: { $0.status == "waiting" }) {
                        ui.projectScreen = nil
                        workspace.selected = tab.id
                    }
                }
                .shortcut(.waitingTab)
            }
        }
    }
}
