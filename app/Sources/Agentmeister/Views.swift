import AppKit
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

/// В SwiftTerm тоже есть тип Color, а в интерфейсе нужен цвет SwiftUI
typealias Color = SwiftUI.Color

/// Что открыто в окне помимо вкладок: лист новой сессии и панель сессии. Меню приложения тоже меняет это.
@MainActor
final class UIState: ObservableObject {
    @Published var showNewSession = false
    @Published var showPalette = false
    @Published var showOnboarding = false
    /// С какого шага открыть мастер первого запуска (agentmeister://onboarding?step=N, перезапуск ради разрешений).
    @Published var onboardingStep = 0
    @Published var showInspector = UserDefaults.standard.object(forKey: "layout.showInspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "layout.showInspector") }
    }
    /// Проекты свернуты в рельсу.
    @Published var sidebarCollapsed = UserDefaults.standard.bool(forKey: "layout.sidebarCollapsed") {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: "layout.sidebarCollapsed") }
    }
    @Published var newSessionProject: String?
    /// Лист параллельной задачи: Claude Code в своей ветке и worktree, проект из newSessionProject.
    @Published var showParallel = false
    /// ⌘⇧T, пока открыт экран проекта или лист с полем запроса: поля с кнопкой перевода переводят свой текст.
    @Published var translateComposer = 0
    var composerShown: Bool { projectScreen != nil || showNewSession || showParallel }
    /// Путь проекта, чей экран открыт вместо терминала. Nil, когда видны вкладки.
    /// Экран проекта и превью сессии взаимоисключающие, а projectScreen = nil везде значит "вернуться к вкладкам",
    /// поэтому это убирает и превью.
    @Published var projectScreen: String? {
        didSet {
            guard !switching, sessionPreview != nil else { return }
            switching = true
            sessionPreview = nil
            switching = false
        }
    }
    /// Сессия, чье превью открыто вместо терминала: клик по закрытой сессии в боковом меню.
    @Published var sessionPreview: String? {
        didSet {
            guard !switching, sessionPreview != nil, projectScreen != nil else { return }
            switching = true
            projectScreen = nil
            switching = false
        }
    }
    private var switching = false
    /// Вместо вкладок открыт экран проекта или превью сессии.
    var screenOpen: Bool { projectScreen != nil || sessionPreview != nil }
    /// Главное окно сейчас впереди. Команды вкладок (⌘W, ⌘R) работают только тогда.
    @Published var mainKey = true
    /// Вкладка, сессию которой просят забыть. Пока не nil, окно спрашивает подтверждение.
    @Published var forgetting: TerminalTab?
    /// Вкладка, сессию которой переименовывают.
    @Published var renaming: TerminalTab?
    /// Вкладка, которую просят перезапустить без proxy. Пока не nil, окно перечисляет риски и ждет подтверждения.
    @Published var confirmingDirect: TerminalTab?
    /// Вкладка, где Remote Control переключили, а вписать /remote-control в идущую сессию было нельзя. Пока не nil,
    /// окно спрашивает, перезапустить ли сессию сейчас. Включить или выключить, видно по spec.remoteControl.
    @Published var confirmingRemote: TerminalTab?
    /// Агент, в которого входят через диалог входа из баннера вкладки. Лист висит на окне, а не на баннере:
    /// баннер пропадает, как только вход прошел, а диалог должен показать "Вход выполнен".
    @Published var signingIn: LaunchSpec.Agent?
}

func tilde(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}


// MARK: - Окно

struct MainView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var l: L { L(backend.state.lang) }

    /// Демо для скриншотов: открыть экран из --scene, когда вкладки уже на месте.
    private func showDemoScene() {
        Task { @MainActor in
            // окно демо отличается от настоящего заголовком, и снимки одного размера
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Agentmeister" }) {
                window.title = "Agentmeister Demo"
                // в сцене tabs-list окно узкое, чтобы вкладки не поместились в полосу, в bar-narrow чтобы панель
                // сессии прокручивалась. В inspector-scroll окно низкое, чтобы прокручивалась правая панель
                window.setFrame(NSRect(x: 40, y: 40, width: Demo.scene == "bar-narrow" ? 760 : Demo.scene == "tabs-list" ? 1000 : 1440,
                                       height: Demo.scene == "inspector-scroll" ? 560 : 880),
                                display: true)
                // снимок с активным окном: цветные кнопки, даже если фокус был у другого приложения
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            try? await Task.sleep(for: .seconds(1))
            switch Demo.scene {
            case "new-session":
                ui.newSessionProject = workspace.current?.spec.projectPath
                ui.showNewSession = true
            case "onboarding-proxy":
                // мастер первого запуска на шаге proxy (четвертый, с нуля 3)
                ui.onboardingStep = 3
                ui.showOnboarding = true
            case "about":
                openWindow(id: "about")
            case "sessions-clean":
                // окно библиотеки, лист уборки открывает оно само
                openWindow(id: "library")
            case "rail":
                ui.sidebarCollapsed = true
            case "modes-toggle":
                ui.sidebarCollapsed = false
            case "project":
                ui.projectScreen = workspace.current.flatMap { backend.state.project(containing: $0.spec.projectPath)?.path }
            case "settings", "settings-modes", "settings-notify", "settings-notify-phone", "settings-notify-add", "settings-general", "settings-buildlog", "settings-lid", "settings-humanize", "settings-guard", "settings-setup-steps", "settings-terminal", "settings-doctor", "settings-doctor-toggle", "settings-doctor-fixing", "settings-doctor-failed", "settings-doctor-fixed", "headsup", "command-running", "command-done", "command-failed", "proxy-change", "proxy-add", "telegram-token", "telegram-wait", "telegram-shared":
                // settings-modes: раздел режимов; settings-notify: уведомления; headsup: раздел агентов с историей заметок Heads up под карточками
                let section = ["settings-modes": "modes", "settings-notify": "notify", "settings-notify-phone": "notify", "settings-notify-add": "notify", "settings-general": "general", "settings-buildlog": "modes", "settings-lid": "modes", "settings-humanize": "modes", "settings-guard": "modes", "settings-setup-steps": "agents", "settings-terminal": "terminal", "settings-doctor": "doctor", "settings-doctor-toggle": "doctor", "settings-doctor-fixing": "doctor", "settings-doctor-failed": "doctor", "settings-doctor-fixed": "doctor", "headsup": "agents", "command-failed": "agents", "telegram-token": "notify", "telegram-wait": "notify", "telegram-shared": "notify"][Demo.scene] ?? "proxy"
                UserDefaults.standard.set(section, forKey: "settingsSection")
                // settings-buildlog и settings-lid открывают режимы с выбранной карточкой
                if let mode = ["settings-buildlog": "buildlog", "settings-lid": "lid", "settings-humanize": "humanize", "settings-guard": "guard"][Demo.scene] {
                    UserDefaults.standard.set(mode, forKey: "modes.selected")
                }
                openSettings()
                // окно настроек высокое, чтобы раздел proxy с подписками поместился целиком
                try? await Task.sleep(for: .seconds(1))
                if let screen = NSScreen.main?.visibleFrame,
                   let settings = NSApp.windows.first(where: { $0.isVisible && $0.title != "Agentmeister Demo" && $0.frame.width > 300 }) {
                    // высота по разделу proxy: ниже уже начинается следующий раздел
                    let height = min(screen.height, 800)
                    settings.setFrame(NSRect(x: screen.minX + 60, y: screen.maxY - height, width: 1040, height: height), display: true)
                }
                // command-running, -done, -failed: лист команды в трех состояниях, вывод из Demo.commandOutput
                if Demo.scene.hasPrefix("command-") {
                    let l = L(backend.state.lang)
                    if Demo.scene == "command-failed" {
                        CommandRuns.shared.start(["--harness", "codex", "install"], title: l.t("Установить Codex", "Install Codex"),
                                                 icon: "arrow.down.circle", host: .settings, sheet: true)
                    } else {
                        CommandRuns.shared.start(["proxy", "test"], title: l.t("Проверить выход", "Check exit"),
                                                 icon: "checkmark.shield", host: .settings, sheet: true)
                    }
                }
            default:
                break
            }
            // у окна настроек нет свертывания и масштаба, и их кнопки серые. На скриншоте они цветные, как у
            // обычного окна. Кнопку закрытия под листом macOS гасит в любом случае, ее перекрашивает shoot.py
            if Demo.scene.hasPrefix("settings") || Demo.scene.hasPrefix("command-") || Demo.scene.hasPrefix("proxy-") || Demo.scene.hasPrefix("telegram-") || Demo.scene == "headsup",
               let settings = NSApp.windows.first(where: { $0.isVisible && $0.title != "Agentmeister Demo" && $0.frame.width > 300 }) {
                settings.styleMask.formUnion([.miniaturizable, .resizable])
            }
        }
    }

    var body: some View {
        CardsLayout {
            VStack(spacing: 10) {
                MainHeader()
                DetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 4)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
        .background(TrafficLightsInset())
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            ui.mainKey = (note.object as? NSWindow)?.identifier?.rawValue.hasPrefix("main") == true
        }
        .onChange(of: backend.state.lang) { UserDefaults.standard.set(backend.state.lang, forKey: "lastLang") }
        .commandSheets(.main)
        .sheet(isPresented: $ui.showNewSession) {
            NewSessionSheet(initialProject: ui.newSessionProject)
        }
        .sheet(isPresented: $ui.showParallel) {
            ParallelSheet(initialProject: ui.newSessionProject)
        }
        .sheet(isPresented: $ui.showPalette) {
            PaletteView()
        }
        .sheet(isPresented: $ui.showOnboarding) {
            OnboardingView()
        }
        .alert(l.t("Перезапустить без proxy?", "Restart without the proxy?"),
               isPresented: Binding(get: { ui.confirmingDirect != nil }, set: { if !$0 { ui.confirmingDirect = nil } }),
               presenting: ui.confirmingDirect) { tab in
            Button(l.t("Перезапустить без proxy", "Restart without proxy"), role: .destructive) {
                tab.switchRoute()
                ui.confirmingDirect = nil
            }
            Button(l.cancel, role: .cancel) { ui.confirmingDirect = nil }
        } message: { _ in
            Text(l.t("""
                Сессия продолжится вне песочницы, и ее трафик пойдет напрямую с этого Mac, мимо mihomo.

                Anthropic, OpenAI и другие сервисы увидят настоящий IP и страну. Если аккаунт обычно работает \
                из другой страны, внезапная смена может закончиться проверкой или блокировкой.

                Агент и его команды смогут ходить в сеть напрямую, а правила mihomo на них перестанут действовать.

                Запрет на правку списка host-run и настроек proxy тоже снимается.

                Вернуть proxy можно кнопкой "Перезапустить через proxy".
                """, """
                The session continues outside the sandbox, and its traffic goes straight from this Mac, past mihomo.

                Anthropic, OpenAI and other services see your real IP and country. If the account usually works \
                from another country, the sudden change can lead to a check or a block.

                The agent and its commands can reach the network directly, and the mihomo rules stop applying to them.

                The lock on the host-run list and the proxy settings is lifted too.

                Restart via proxy brings the proxy back.
                """))
        }
        .alert(ui.confirmingRemote?.spec.remoteControl == false ? l.t("Отключить Remote Control сейчас?", "Disconnect Remote Control now?")
                                                                : l.t("Подключить Remote Control сейчас?", "Connect Remote Control now?"),
               isPresented: Binding(get: { ui.confirmingRemote != nil }, set: { if !$0 { ui.confirmingRemote = nil } }),
               presenting: ui.confirmingRemote) { tab in
            Button(tab.spec.remoteControl ? l.t("Перезапустить с Remote Control", "Restart with Remote Control")
                                          : l.t("Перезапустить без Remote Control", "Restart without Remote Control")) {
                tab.restart()
                ui.confirmingRemote = nil
            }
            Button(l.t("При следующем запуске", "On next start"), role: .cancel) { ui.confirmingRemote = nil }
        } message: { tab in
            Text(l.t("Claude Code ждет ответа в диалоге или в строке ввода есть текст, поэтому приложение не стало вписывать /remote-control. ",
                     "Claude Code is waiting for an answer in a dialog or the prompt has text, so the app did not type /remote-control. ")
                 + (tab.spec.remoteControl
                    ? l.t("Можно перезапустить ту же сессию с Remote Control или подождать до следующего запуска.",
                          "You can restart the same session with Remote Control or wait for the next start.")
                    : l.t("Пока сессию не перезапустят, она остается подключенной. Можно перезапустить ее без Remote Control сейчас.",
                          "The session stays connected until it restarts. You can restart it without Remote Control now."))
                 + (tab.status == "busy" ? l.t(" Ответ, который агент пишет сейчас, прервется.", " The answer the agent is writing now will stop.") : ""))
        }
        .sheet(item: $ui.renaming) { tab in
            RenameSheet(tab: tab)
        }
        .sheet(item: $ui.signingIn, onDismiss: { backend.refresh() }) { agent in
            AuthDialog(agent: agent)
        }
        .confirmationDialog(l.t("Забыть сессию?", "Forget this session?"),
                            isPresented: Binding(get: { ui.forgetting != nil }, set: { if !$0 { ui.forgetting = nil } })) {
            Button(l.forget, role: .destructive) {
                ui.forgetting?.forget(note: l.forgetting)
                ui.forgetting = nil
            }
        } message: {
            Text(l.t("Агент остановится, переписка, история правок и строки в history.jsonl удалятся. Вернуть нельзя. Во вкладке откроется чистая сессия.",
                     "The agent stops, and the transcript, its file history and its lines in history.jsonl are deleted. This can't be undone. A clean session opens in the tab."))
        }
        .sheet(isPresented: Binding(get: { workspace.pendingRestore != nil },
                                    set: { if !$0, workspace.pendingRestore != nil { workspace.finishRestore([]) } })) {
            if let pending = workspace.pendingRestore { RestoreSheet(pending: pending) }
        }
        .alert(l.t("Сессия уже открыта в другом окне", "The session is already open in another window"),
               isPresented: Binding(get: { workspace.notice != nil }, set: { if !$0 { workspace.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(l.t("Она идет в iTerm2, Terminal или другом окне Agentmeister. Второй Claude на той же переписке перемешал бы ответы. Закрой ее там и открой здесь.",
                     "It runs in iTerm2, Terminal or another Agentmeister window. A second Claude on the same transcript would mix up the replies. Close it there and open it here."))
        }
        .onReceive(backend.$state) { state in workspace.sync(with: state.live) }
        // демо: состояние из файла приходит раньше, чем окно начинает следить за ready
        .onAppear {
            guard Demo.active, backend.ready else { return }
            workspace.restore(live: [], projects: backend.state.projects, sessions: backend.state.sessions)
            showDemoScene()
        }
        .onChange(of: backend.ready) {
            guard backend.ready else { return }
            workspace.restore(live: backend.state.live, projects: backend.state.projects, sessions: backend.state.sessions)
            if Demo.active {
                showDemoScene()
                return
            }
            // клик по уведомлению мог и запустить приложение: запрос ждет в focus.json
            workspace.takeFocusRequest(state: backend.state)
            // мастер один раз, при первом запуске, и снова, если он сам перезапустил приложение ради разрешений
            if !UserDefaults.standard.bool(forKey: "onboardingDone") || UserDefaults.standard.object(forKey: "onboardingResumeStep") != nil {
                ui.showOnboarding = true
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .modifier(ReopenWindows())
        .onOpenURL { url in
            // agentmeister://browse?url=<ссылка> от помощника BROWSER во вкладке через proxy
            if url.host() == "browse" {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let raw = items.first(where: { $0.name == "url" })?.value,
                   let target = URL(string: raw), ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
                    // через подписку вкладки, из которой ссылка. Подписки этой вкладки больше нет: не открывать
                    let tabId = items.first(where: { $0.name == "tab" })?.value.flatMap { UUID(uuidString: $0) }
                    let spec = workspace.tabs.first { $0.id == tabId }?.spec
                    let via = spec?.proxied == true ? spec?.subscription : nil
                    if let proxy = backend.state.proxy {
                        guard let port = proxy.port(for: via) else { return }
                        ProxyBrowser.shared.open(target, port: port, via: via)
                    } else {
                        ProxyBrowser.shared.open(target)
                    }
                }
                return
            }
            // agentmeister://onboarding?step=N открывает мастер первого запуска на шаге N (с нуля)
            if url.host() == "onboarding" {
                // открытый мастер ссылка только выводит вперед: шаг с идущей в нем командой она не переключает
                if !ui.showOnboarding {
                    let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "step" }?.value
                    ui.onboardingStep = max(0, Int(raw ?? "") ?? 0)
                    ui.showOnboarding = true
                }
                Workspace.bringMainWindowForward()
                return
            }
            // agentmeister://project?path=<папка> открывает экран проекта, в котором лежит эта папка
            if url.host() == "project" {
                if let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
                   let project = backend.state.project(containing: (raw as NSString).expandingTildeInPath) {
                    ui.sessionPreview = nil
                    ui.projectScreen = project.path
                }
                Workspace.bringMainWindowForward()
                return
            }
            // agentmeister://focus?tab=<id>&session=<id> из клика по уведомлению
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            guard url.host() == "focus", let tab = query?.first(where: { $0.name == "tab" })?.value else { return }
            if !workspace.restoredTabs || workspace.pendingRestore != nil {
                // приложение только что запустилось по ссылке: вкладок еще нет, запрос заберем из focus.json
                Workspace.bringMainWindowForward()
                return
            }
            workspace.focusFromURL(tab: tab, session: query?.first(where: { $0.name == "session" })?.value, state: backend.state)
        }
        .onChange(of: workspace.selected) {
            workspace.writeFront(active: NSApp.isActive)
            ui.projectScreen = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.writeFront(active: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            workspace.writeFront(active: false)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            workspace.takeFocusRequest(state: backend.state)
            workspace.takeOpenRequests(state: backend.state)
            workspace.trackCodexThreads()
        }
    }

}

/// Поле "Поиск ⌘K" в тулбаре. Открывает палитру команд, где ищутся вкладки, сессии и действия.
struct SearchCapsule: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var ui: UIState
    @ObservedObject private var shortcuts = ShortcutStore.shared
    var l: L { L(backend.state.lang) }

    var body: some View {
        Button {
            ui.showPalette = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13))
                Text(shortcuts.label(.palette).isEmpty ? l.t("Поиск", "Search") : l.t("Поиск", "Search") + "   " + shortcuts.label(.palette))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.muted)
            .padding(.horizontal, 14)
            .frame(minWidth: 120, idealWidth: 240, maxWidth: 240, minHeight: 34, maxHeight: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverCapsule())
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(l.t("Поиск по сессиям", "Search sessions"))
        .shortcutHelp(l.t("Палитра команд", "Command palette"), .palette)
    }
}

/// Значок proxy в тулбаре: бирюзовая стеклянная капсула со страной и протоколом выхода, "KZ · vless".
struct ProxyBadge: View {
    @EnvironmentObject var backend: Backend
    @State private var showDetails = false
    var l: L { L(backend.state.lang) }

    var body: some View {
        let proxy = backend.state.proxy
        let text: String
        let live: Bool
        if proxy == nil && backend.lastError != nil {
            text = l.t("нет данных", "no data")
            live = false
        } else if proxy?.configured != true {
            text = l.proxyOff
            live = false
        } else if proxy?.running == true {
            text = [proxy?.exit, proxy?.protocol].compactMap { $0 }.joined(separator: " · ")
            live = true
        } else {
            text = l.proxyIdle
            live = false
        }
        return Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "shield").font(.system(size: 12, weight: .medium))
                Text(text.isEmpty ? "proxy" : text).fontWeight(.medium)
            }
            .foregroundStyle(live ? Ink.teal : Ink.muted)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverCapsule())
        .glassEffect(live ? .regular.tint(Ink.tealDot.opacity(0.22)).interactive() : .regular.interactive(), in: .capsule)
        .help(backend.lastError ?? [proxy?.node, proxy?.ip].compactMap { $0 }.joined(separator: " · "))
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            ProxyPopover()
        }
    }
}

/// Всплывающее окно у значка proxy: выход, сервер, сколько сессий идет через proxy, действия и ссылка на настройки.
struct ProxyPopover: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace

    var l: L { L(backend.state.lang) }

    var body: some View {
        let p = backend.state.proxy
        let agents = workspace.tabs.filter { $0.spec.utility == nil }
        let proxied = agents.filter(\.spec.proxied).count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text(p?.exit ?? "—").font(.system(size: 26, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p?.running == true ? l.t("mihomo работает", "mihomo running")
                         : p?.configured == true ? l.t("mihomo ждет сессию", "mihomo waits for a session") : l.proxyOff)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p?.running == true ? Ink.teal : Ink.muted)
                    Text([p?.protocol, p?.ip].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.muted)
                }
                Spacer()
            }
            if let node = p?.node, !node.isEmpty {
                Text(node).font(.system(size: 12)).foregroundStyle(Ink.text2).lineLimit(1).truncationMode(.middle)
            }
            Text(l.t("Через proxy \(proxied) из \(agents.count) вкладок, новые сессии ",
                     "\(proxied) of \(agents.count) tabs via proxy, new sessions ")
                 + ((p?.defaultRoute ?? "proxy") == "direct" ? l.t("напрямую", "go direct") : l.t("через proxy", "via proxy")))
                .font(.system(size: 12)).foregroundStyle(Ink.muted)
            if p?.configured == true {
                ProxyActions(columns: 1) { backend.refresh() }
            }
            HStack {
                Spacer()
                SettingsLink {
                    Text(l.t("Настройки proxy", "Proxy settings"))
                }
                .buttonStyle(.textLink)
                .simultaneousGesture(TapGesture().onEnded { UserDefaults.standard.set("proxy", forKey: "settingsSection") })
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Боковая панель

struct Sidebar: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    @State private var expanded: Set<String> = []
    @AppStorage("layout.projectsOpen") private var projectsOpen = true

    var l: L { L(backend.state.lang) }

    var body: some View {
        // список проектов во всю высоту карточки, шапка и режимы лежат поверх него барами: строки уходят под них
        // и размываются краевым эффектом, а у режимов свой стеклянный фон
        Group {
            if projectsOpen {
                projectList
                    .scrollContentBackground(.hidden)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Color.clear
            }
        }
        // без .clipped(): обрезка по краю шапки убирала строки из-под нее, и размывать там было нечего
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // флаг хранится в UserDefaults, и withAnimation у заголовка до него не доходит: анимация по значению
        .animation(.snappy(duration: 0.28), value: projectsOpen)
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                // место под светофор, кнопка свертывания теперь в шапке средней карточки
                Color.clear
                    .frame(height: 40)
                    .frame(maxWidth: .infinity)
                    .background(WindowDragArea())
                HStack(spacing: 6) {
                    CollapsibleHeader(title: l.projects, open: $projectsOpen, summary: openSummary, alwaysShowSummary: true)
                    Button(action: backend.refreshProjects) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Ink.muted)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.hover(6))
                    .help(l.t("Обновить проекты", "Refresh projects"))
                    .accessibilityLabel(l.t("Обновить проекты", "Refresh projects"))
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 4)
            }
            // строки под светофором и заголовком размыты
            .blurBar(edge: .top)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) { SidebarFooter() }
        .onAppear { expandOpenProjects() }
        .onChange(of: workspace.selected) { expandOpenProjects() }
    }

    /// "3 open, 1 waiting": вкладки этого окна и сессии из реестра Claude Code, открытые где угодно, в iTerm2
    /// тоже. Реестр знает и наши вкладки, поэтому вкладка с известной сессией считается один раз.
    /// В раскрытой группе ноль не показываем.
    private var openSummary: String {
        let (tabs, others) = workspace.openSessions(backend.state)
        let open = tabs.count + others.count
        let waiting = tabs.filter { $0.status == "waiting" }.count + others.filter { $0.status == "waiting" }.count
        if open == 0 && projectsOpen { return "" }
        var text = l.t("открыто \(open)", "\(open) open")
        if waiting > 0 { text += l.t(waiting == 1 ? ", ждет 1" : ", ждут \(waiting)", ", \(waiting) waiting") }
        return text
    }

    private var projectList: some View {
        List {
            let projects = workspace.sidebarProjects(backend.state)
            ForEach(projects) { project in
                let sessions = backend.state.sessions(in: project).prefix(6)
                Group {
                    if sessions.isEmpty {
                        ProjectRow(project: project)
                    } else {
                        DisclosureGroup(isExpanded: binding(for: project)) {
                            ForEach(sessions) { session in
                                SessionRow(session: session, project: project)
                            }
                        } label: {
                            ProjectRow(project: project)
                        }
                    }
                }
                // двигаются только проекты с вкладками: порядок повторяет полосу вкладок
                .moveDisabled(!workspace.hasTabs(in: project, state: backend.state))
            }
            .onMove { from, to in
                guard let i = from.first else { return }
                // при движении вниз проект встает после того, что был над местом вставки, вверх перед тем, что под ним
                let target = to > i ? projects[to - 1] : projects[min(to, projects.count - 1)]
                withAnimation(.snappy) { workspace.moveProject(projects[i].path, to: target.path, state: backend.state) }
            }
            if let error = backend.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Ink.amber)
                        .font(.caption)
                }
            }
        }
        .listStyle(.sidebar)
        .animation(.snappy, value: workspace.sidebarProjects(backend.state).map(\.path))
    }

    private func binding(for project: AppState.Project) -> Binding<Bool> {
        Binding(get: { expanded.contains(project.path) },
                set: { if $0 { expanded.insert(project.path) } else { expanded.remove(project.path) } })
    }

    private func expandOpenProjects() {
        // продолжение открывается в папке сессии, это бывает подпапка проекта
        if let path = workspace.current?.spec.projectPath { expanded.insert(backend.state.project(containing: path)?.path ?? path) }
    }
}

/// Низ боковой панели: режимы капсулами и состояние host-run.
struct SidebarFooter: View {
    @EnvironmentObject var backend: Backend
    @ObservedObject private var updates = Updates.shared
    /// Список режимов проявляется после того, как встал на место.
    @State private var listShown = false
    @AppStorage("layout.modesOpen") private var modesOpen = true

    var l: L { L(backend.state.lang) }

    /// Короткое описание режима под его именем.
    private func modeHint(_ key: String) -> String { Self.hint(key, l) }

    /// Строка под режимами: значок, текст и стрелка, нажимается целиком.
    private func footerRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.faint)
        }
        .font(.system(size: 12))
        .foregroundStyle(Ink.muted)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: 28)
        .contentShape(Rectangle())
    }

    /// То же описание для узкой панели проектов (RailStatusButton).
    static func hint(_ key: String, _ l: L) -> String {
        switch key {
        case "humanize": return l.t("текст без примет нейросети", "writing without AI tells")
        case "translate":
            let key = ShortcutStore.shared.label(.translateInput)
            return TranslateKey.saved ? l.t("\(key) переводит ввод", "\(key) translates the input") : l.t("\(key), нет ключа", "\(key), no key")
        case "guard": return l.t("спросит перед опасной командой", "asks before risky commands")
        case "notify": return l.t("скажет, что агент ждет", "pings when an agent waits")
        case "buildlog": return l.t("выжимка длинных сборок", "digest of long builds")
        case "lid": return l.t("не спать с закрытой крышкой", "awake with the lid closed")
        default: return ""
        }
    }

    /// Порядок из макета. Режимы, которых нет в ответе app-state, не показываются.
    static let order = ["humanize", "translate", "guard", "notify", "buildlog", "lid"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CollapsibleHeader(title: l.modes, open: $modesOpen,
                              summary: Self.order.filter { backend.state.modes[$0] == true }.joined(separator: " · "),
                              animated: false)
            if modesOpen {
            VStack(spacing: 4) {

                ForEach(Self.order.filter { backend.state.modes[$0] != nil }, id: \.self) { key in
                    let on = backend.state.modes[key] ?? false
                    Button {
                        backend.setMode(key, on: !on)
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(key).font(.system(size: 12, weight: .medium)).foregroundStyle(on ? Ink.modeOn : Ink.text2)
                                Text(modeHint(key)).font(.system(size: 11)).foregroundStyle(Ink.faint).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Capsule()
                                .fill(on ? Color.accentColor : Ink.modeOffBorder)
                                .frame(width: 22, height: 13)
                                .overlay(alignment: on ? .trailing : .leading) {
                                    Circle().fill(.white).frame(width: 9, height: 9).padding(2)
                                }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Ink.modeOnBg : Ink.modeOffBg))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Ink.modeOnBorder : Ink.modeOffBorder))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.hover(10, .overlay))
                    .help(l.modeTitle(key))
                    .accessibilityLabel(key + ", " + modeHint(key))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            // проявляется сам, раскладка вокруг меняется сразу (см. transaction ниже)
            .opacity(listShown ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.18)) { listShown = true } }
            .onDisappear { listShown = false }
            }
            VStack(spacing: 0) {
                if let h = backend.state.hostRun {
                    // вся строка ведет в настройки host-run со списком команд
                    SettingsLink {
                        footerRow {
                            GlowDot(color: h.running ? Ink.tealDot : Ink.amberDot)
                            Text(h.running
                                 ? l.t("host-run работает · ", "host-run running · ") + l.commands(h.commands)
                                 : l.t("host-run не запущен", "host-run isn't running"))
                        }
                    }
                    .buttonStyle(.hover(8, .overlay))
                    .simultaneousGesture(TapGesture().onEnded { UserDefaults.standard.set("proxy", forKey: "settingsSection") })
                    .help(l.t("Настройки host-run и список команд", "host-run settings and its command list"))
                }
                // в демо Sparkle не запущен, строка обновлений там все равно видна для снимка
                if updates.available || Demo.active {
                    if let version = updates.ready {
                        Button { updates.installNow() } label: {
                            footerRow {
                                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                                Text(l.t("Перезапустить и обновить до \(version)", "Restart to update to \(version)"))
                            }
                        }
                        .buttonStyle(.hover(8, .overlay))
                    } else {
                        Button { updates.check() } label: {
                            footerRow {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text(l.t("Проверить обновления…", "Check for Updates…"))
                            }
                        }
                        .buttonStyle(.hover(8, .overlay))
                    }
                }
            }
            .padding(.top, 2)
            .padding(.horizontal, -6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // блок живет в нижней полосе боковой панели: ее высота меняется сразу, без анимации. Если анимировать
        // раскладку внутри, строки host-run и обновлений сначала налезали на режимы, а в конце прыгали
        .transaction(value: modesOpen) { $0.animation = nil }
        .task {
            // демо modes-toggle: режимы сами сворачиваются и разворачиваются, чтобы записать анимацию
            guard Demo.active && Demo.scene == "modes-toggle" else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                modesOpen.toggle()
            }
        }
        .padding(12)
        // жидкое стекло: проекты, уехавшие под режимы, просвечивают размытыми
        .glassEffect(.regular, in: .windowCard)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

/// Заголовок группы в боковой панели: имя, стрелка, справа сводка, пока группа свернута. Клик сворачивает.
struct CollapsibleHeader: View {
    let title: String
    @Binding var open: Bool
    var summary = ""
    /// Сводка и в раскрытой группе: у проектов она говорит то, чего не видно в списке, сколько сессий открыто.
    var alwaysShowSummary = false
    /// false для групп в нижней полосе панели: ее высота меняется без анимации, и анимация внутри дергалась.
    var animated = true

    var body: some View {
        Button {
            if animated {
                withAnimation(.snappy(duration: 0.2)) { open.toggle() }
            } else {
                open.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                SectionCaption(text: title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.faint)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Spacer()
                if (!open || alwaysShowSummary) && !summary.isEmpty {
                    Text(summary).font(.system(size: 11)).foregroundStyle(Ink.faint).lineLimit(1)
                }
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(open ? "expanded" : "collapsed")
    }
}

/// Раскладка в строку с переносом, как flex-wrap в макете.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !row.items.isEmpty && row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

struct ProjectRow: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    let project: AppState.Project
    @State private var hover = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        // вкладки этого окна и сессии в других окнах, без двойного счета
        let (tabs, others) = workspace.openSessions(in: project, state: backend.state)
        let count = tabs.count + others.count
        let statuses = tabs.map(\.status) + others.map(\.status)
        let waiting = statuses.contains("waiting")
        // как на свернутой рельсе: ждет ответа важнее, чем работает
        let status = waiting ? "waiting" : statuses.contains("busy") ? "busy" : nil
        HStack(spacing: 8) {
            // клик открывает экран проекта, повторный клик закрывает его. Жест висит на всем, кроме "+":
            // simultaneousGesture на всей строке срабатывал и вместе с кнопкой новой сессии
            HStack(spacing: 8) {
                ProjectIconView(path: project.path, size: 18)
                    .overlay(alignment: .bottomTrailing) {
                        if count > 0 {
                            SessionDot(status: status, size: 7)
                                .padding(1.5)
                                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                                .offset(x: 3, y: 3)
                        }
                    }
                Text(project.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                if !hover && count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(waiting ? Ink.amber : Ink.faint)
                }
            }
            .frame(minHeight: 28)
            .padding(.leading, 4)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { ui.projectScreen = ui.projectScreen == project.path ? nil : project.path })
            if hover {
                Menu {
                    ProjectLaunchActions(project: project)
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.hover(6))
                .help(l.newSession)
                .accessibilityLabel(l.newSession)
            }
        }
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        // выбранный проект на подложке, под курсором легкая подсветка; развернутый проект без своей подложки
        .listRowBackground(ui.projectScreen == project.path
                           ? RoundedRectangle(cornerRadius: 10).fill(Ink.thumb).padding(.horizontal, 10)
                           : hover ? RoundedRectangle(cornerRadius: 10).fill(Ink.hover).padding(.horizontal, 10) : nil)
        .contextMenu {
            Button(l.newSession) {
                workspace.open(LaunchSpec.quick(project, state: backend.state))
            }
            Button(l.t("Новая сессия…", "New session…")) {
                ui.newSessionProject = project.path
                ui.showNewSession = true
            }
            if let last = backend.state.sessions(in: project).first {
                Button(l.resumeLast) {
                    workspace.open(LaunchSpec.resume(last, project: project, state: backend.state))
                }
            }
            Button(l.t("Обзор проекта", "Project overview")) { ui.projectScreen = project.path }
            Button(l.openTerminalHere) {
                workspace.openTerminal(name: project.name, path: project.path,
                                       direct: backend.state.proxy?.defaultRoute == "direct", state: backend.state,
                                       subscription: backend.state.defaultSubscription)
            }
            Divider()
            Button(l.t("Показать в Finder", "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
            }
        }
    }
}

struct SessionRow: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    let session: AppState.Session
    let project: AppState.Project
    @State private var hover = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        let tab = workspace.tabs.first { $0.sessionId == session.id && $0.running }
        let live = backend.state.live.first { $0.sessionId == session.id }
        let status = tab?.status ?? live?.status
        // пока открыт экран проекта, выделен он, а не вкладка
        let current = ui.sessionPreview == session.id
            || (tab != nil && tab?.id == workspace.selected && !ui.screenOpen)
        Button {
            // открытая во вкладке сессия сразу переключает на вкладку, закрытая сначала показывает превью
            if tab != nil {
                ui.projectScreen = nil
                workspace.open(LaunchSpec.resume(session, project: project, state: backend.state))
            } else {
                ui.sessionPreview = ui.sessionPreview == session.id ? nil : session.id
            }
        } label: {
            HStack(spacing: 8) {
                SessionDot(status: status, open: status != nil || tab != nil, size: 7)
                AgentBadge(agent: session.kind == .codex ? .codex : .claude, size: 14)
                Text(session.title.isEmpty ? l.untitled : session.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(current ? Ink.strong : Ink.text2)
                Spacer(minLength: 4)
                if live != nil && tab == nil {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.caption)
                        .foregroundStyle(Ink.faint)
                }
                Text(status.map { l.shortStatus($0) } ?? l.ago(session.mtime))
                    .font(.system(size: 11))
                    .foregroundStyle(status == "waiting" ? Ink.amber : Ink.faint)
            }
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .listRowBackground(current ? RoundedRectangle(cornerRadius: 10).fill(Ink.thumb).padding(.horizontal, 10)
                           : hover ? RoundedRectangle(cornerRadius: 10).fill(Ink.hover).padding(.horizontal, 10) : nil)
        .contextMenu {
            Button(l.resume) {
                ui.projectScreen = nil
                workspace.open(LaunchSpec.resume(session, project: project, state: backend.state))
            }
            Button(l.t("Показать переписку", "Show the conversation")) { ui.sessionPreview = session.id }
        }
        .help(live != nil && tab == nil
              ? l.t("Открыта в другом окне", "Open in another window")
              : tab != nil ? l.t("Перейти к вкладке", "Go to the tab")
              : l.t("Показать переписку, продолжить оттуда", "Show the conversation and resume from there"))
    }
}

// MARK: - Вкладки и терминал

struct DetailView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace

    var l: L { L(backend.state.lang) }

    @EnvironmentObject var ui: UIState

    var body: some View {
        if let path = ui.projectScreen {
            ProjectView(path: path)
        } else if let id = ui.sessionPreview {
            SessionPreviewScreen(id: id)
        } else if workspace.tabs.isEmpty {
            ContentUnavailableView(l.noTabs, systemImage: "terminal", description: Text(l.noTabsHint(ShortcutStore.shared.label(.newSession))))
        } else {
            VStack(spacing: 10) {
                TabStrip()
                if let tab = workspace.current {
                    let root = workspace.root(of: tab)
                    let subtasks = workspace.subtasks(of: root)
                    SubtaskRowHost(root: root, subtasks: subtasks)
                    InfoBar(tab: tab)
                        .background { SubAgentPoller(root: root) }
                    TabAlert(tab: tab)
                        .id(tab.id)
                }
                TerminalHost(tab: workspace.current)
                    .clipShape(.windowCard)
                    .overlay {
                        if let tab = workspace.current, tab.spec.claudeSession || tab.spec.codexSession {
                            StickyPromptBar(tab: tab).clipShape(.windowCard)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let tab = workspace.current { TerminalFindOverlay(tab: tab) }
                    }
                    .overlay {
                        if let tab = workspace.current { AgentUpdateOverlay(tab: tab) }
                    }
                    .overlay {
                        if let tab = workspace.current { InputTranslationOverlay(tab: tab).clipShape(.windowCard) }
                    }
                    .overlay {
                        if let tab = workspace.current { TranslateKeyCard(tab: tab).clipShape(.windowCard) }
                    }
            }
        }
    }
}

/// Превью закрытой сессии вместо терминала. Продолжить открывает ее во вкладке, Esc и ⌘W возвращают к вкладкам.
struct SessionPreviewScreen: View {
    @EnvironmentObject var ui: UIState
    let id: String

    var body: some View {
        SessionDetail(id: id, onOpened: { ui.sessionPreview = nil }, onDeleted: { ui.sessionPreview = nil })
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
            .clipShape(.windowCard)
            .background {
                Button("") { ui.sessionPreview = nil }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
                    .accessibilityHidden(true)
            }
    }
}

private struct ProjectLaunchActions: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var ui: UIState
    let project: AppState.Project?

    var body: some View {
        let l = L(backend.state.lang)
        let proxy = backend.state.proxy
        let routes: [Bool] = proxy?.configured != true ? [true]
            : proxy?.defaultRoute == "direct" ? [true, false] : [false, true]
        ForEach(routes, id: \.self) { direct in
            Section(direct ? l.directly
                    : l.t("Через proxy", "Via proxy") + (backend.state.defaultSubscription.map { " " + $0 } ?? "")) {
                Button("Claude Code") { openNew(.claude, direct: direct) }
                Button("Codex") { openNew(.codex, direct: direct) }
                Button(l.t("Терминал", "Terminal")) { openNew(nil, direct: direct) }
            }
        }
    }

    private func openNew(_ agent: LaunchSpec.Agent?, direct: Bool) {
        guard let project else {
            ui.showNewSession = true
            return
        }
        let state = backend.state
        let subscription = direct ? nil : state.defaultSubscription
        if let agent {
            workspace.open(LaunchSpec(projectName: project.name, projectPath: project.path, agent: agent,
                                      direct: direct, subscription: subscription))
        } else {
            workspace.openTerminal(name: project.name, path: project.path, direct: direct,
                                   state: state, subscription: subscription)
        }
    }
}

/// Полоса вкладок: одна стеклянная капсула, выбранная вкладка светлее, в конце "+". Когда вкладки не помещаются,
/// края ленты затухают, а по бокам стоят счетчики вкладок за краем. Счетчик открывает их список, желтая точка на
/// нем значит, что за краем вкладка ждет ответа.
struct TabStrip: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var backend: Backend
    /// Вкладка, которую сейчас тащат, и ее сдвиг от своего места в ряду. Вкладка едет под курсором сама, без
    /// системной копии: системный drag and drop отставал от курсора, после отпускания доигрывал анимацию и
    /// зависал, если вкладку бросали мимо полосы.
    @State private var dragged: UUID?
    /// Поднятая вкладка: стекло и тень. Снимается сразу при отпускании, а не вместе с возвратом на место,
    /// иначе тень отставала от вкладки.
    @State private var lifted: UUID?
    @State private var dragOffset: CGFloat = 0
    /// Сколько ряд уже сдвинул вкладку под курсором перестановками: вычитается из пути курсора.
    @State private var dragShift: CGFloat = 0
    /// Рамки вкладок в координатах полосы, без сдвига перетаскивания.
    @State private var frames: [UUID: CGRect] = [:]
    /// Левый край перетаскиваемой вкладки до последней перестановки. Пока рамка его не сменила, рамки старые,
    /// и новая перестановка по ним вернула бы вкладку назад.
    @State private var staleX: CGFloat?
    @State private var position = ScrollPosition(idType: UUID.self)
    @State private var scroll = StripScroll()
    /// Край, у которого открыт список скрытых вкладок.
    @State private var hiddenList: HorizontalEdge? = Demo.active && Demo.scene == "tabs-list" ? .trailing : nil

    var l: L { L(backend.state.lang) }

    private static let spacing: CGFloat = 2

    struct StripScroll: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var width: CGFloat = 0
        var overflows: Bool { content > width + 1 }
        var left: Bool { offset > 1 }
        var right: Bool { offset + width < content - 1 }
    }

    /// Вкладки за краем ленты: больше половины вкладки не видно.
    private func hidden(_ edge: HorizontalEdge) -> [TerminalTab] {
        workspace.roots.filter { tab in
            guard let frame = frames[tab.id] else { return false }
            return edge == .leading ? frame.midX < scroll.offset : frame.midX > scroll.offset + scroll.width
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            if scroll.overflows { hiddenCounter(.leading) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.spacing) {
                    // подзадачи живут в своем ряду под агентом, здесь только агенты
                    let current = workspace.current.map { workspace.root(of: $0).id }
                    ForEach(workspace.roots) { tab in
                        let isDragged = tab.id == dragged
                        TabChip(tab: tab, selected: tab.id == current, subtasks: workspace.subtasks(of: tab).count, lifted: tab.id == lifted)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: TabFramesKey.self, value: [tab.id: proxy.frame(in: .named("tabstrip"))])
                            })
                            .offset(x: isDragged ? dragOffset : 0)
                            .zIndex(isDragged ? 1 : 0)
                            // место под курсором вкладка меняет без анимации, иначе она уезжала бы из-под него
                            .transaction { if isDragged { $0.animation = nil } }
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 5, coordinateSpace: .named("tabstrip"))
                                    .onChanged { drag(tab.id, by: $0.translation.width) }
                                    .onEnded { _ in endDrag() }
                            )
                    }
                }
                .scrollTargetLayout()
                .coordinateSpace(name: "tabstrip")
                .onPreferenceChange(TabFramesKey.self) { frames = $0 }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: StripScroll.self) { geo in
                StripScroll(offset: geo.contentOffset.x, content: geo.contentSize.width, width: geo.containerSize.width)
            } action: { _, now in
                scroll = now
            }
            // край затухает, только когда за ним есть вкладки
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: scroll.left ? 40 : 0)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: scroll.right ? 40 : 0)
                }
            }
            .animation(.easeOut(duration: 0.15), value: scroll.left)
            .animation(.easeOut(duration: 0.15), value: scroll.right)
            if scroll.overflows {
                hiddenCounter(.trailing)
                Rectangle().fill(Ink.hairline).frame(width: 1, height: 22).padding(.horizontal, 3)
            }
            // "+" спрашивает, что открыть в проекте текущей вкладки и как: через proxy (подписка по умолчанию) или
            // напрямую. Первым идет маршрут по умолчанию из настроек proxy. Без настроенного proxy только напрямую
            Menu {
                ProjectLaunchActions(project: currentProject)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.text2)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.hoverCircle())
            .fixedSize()
            .help(l.newTab)
            .accessibilityLabel(l.newTab)
        }
        .padding(4)
        // капсула вокруг капсул вкладок: радиус 22 + отступ 4, углы идут параллельно
        .glassEffect(.regular, in: Capsule())
    }

    /// Число вкладок за краем со стрелкой в его сторону. Клик открывает их список. Без скрытых вкладок у этого края
    /// счетчик остается бледной стрелкой, чтобы лента не меняла ширину при прокрутке.
    private func hiddenCounter(_ edge: HorizontalEdge) -> some View {
        let tabs = hidden(edge)
        let shown = Binding(get: { hiddenList == edge }, set: { if !$0 && hiddenList == edge { hiddenList = nil } })
        return Button { hiddenList = hiddenList == edge ? nil : edge } label: {
            // точка ожидания: статус вкладок меняется без перерисовки полосы, поэтому раз в 2 секунды
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let waiting = tabs.contains { $0.status == "waiting" || $0.rang }
                HStack(spacing: 4) {
                    if edge == .leading { Image(systemName: "chevron.left").font(.system(size: 8, weight: .bold)) }
                    if waiting { Circle().fill(Ink.amberDot).frame(width: 6, height: 6) }
                    if !tabs.isEmpty { Text("\(tabs.count)").font(.system(size: 11, weight: .semibold).monospacedDigit()) }
                    if edge == .trailing { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)) }
                }
                .foregroundStyle(Ink.text2)
                .padding(.horizontal, 8)
                .frame(minWidth: 30, minHeight: 26)
                .background(Capsule().fill(Ink.chip))
                .contentShape(Capsule())
            }
        }
        .buttonStyle(.hoverCapsule())
        .disabled(tabs.isEmpty)
        .opacity(tabs.isEmpty ? 0.35 : 1)
        .help(edge == .leading ? l.t("Вкладки слева за краем", "Tabs hidden on the left") : l.t("Вкладки справа за краем", "Tabs hidden on the right"))
        .accessibilityLabel(edge == .leading ? l.t("Вкладки слева за краем", "Tabs hidden on the left") : l.t("Вкладки справа за краем", "Tabs hidden on the right"))
        .popover(isPresented: shown, arrowEdge: .bottom) {
            HiddenTabsList(tabs: tabs) { tab in
                hiddenList = nil
                workspace.selected = tab.id
                tab.rang = false
                withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(id: tab.id, anchor: .center) }
            }
        }
    }

    /// Вкладка идет за курсором. Когда ее середина заходит за середину соседа, они меняются местами, а сдвиг
    /// уменьшается на ширину соседа, чтобы вкладка осталась под курсором.
    private func drag(_ id: UUID, by translation: CGFloat) {
        if dragged != id {
            dragged = id
            lifted = id
            dragShift = 0
            staleX = nil
        }
        dragOffset = translation - dragShift
        let order = workspace.roots.map(\.id)
        guard let i = order.firstIndex(of: id), let frame = frames[id], frame.minX != staleX else { return }
        staleX = nil
        let center = frame.midX + dragOffset
        if dragOffset > 0, i + 1 < order.count, let next = frames[order[i + 1]], center > next.midX {
            staleX = frame.minX
            withAnimation(.snappy(duration: 0.18)) { workspace.move(id, to: order[i + 1]) }
            dragShift += next.width + Self.spacing
        } else if dragOffset < 0, i > 0, let prev = frames[order[i - 1]], center < prev.midX {
            staleX = frame.minX
            withAnimation(.snappy(duration: 0.18)) { workspace.move(id, to: order[i - 1]) }
            dragShift -= prev.width + Self.spacing
        }
        dragOffset = translation - dragShift
    }

    private var currentProject: AppState.Project? {
        guard let tab = workspace.current else { return nil }
        let spec = workspace.root(of: tab).spec
        return backend.state.project(containing: spec.projectPath)
            ?? AppState.Project(name: spec.projectName, path: spec.projectPath)
    }

    /// Отпустили: вкладка сразу встает на свое место в ряду.
    private func endDrag() {
        lifted = nil
        withAnimation(.snappy(duration: 0.15)) {
            dragOffset = 0
            dragged = nil
        }
        dragShift = 0
        staleX = nil
    }
}

private struct TabFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Список вкладок за краем полосы: состояние, имя и проект, клик переключает на вкладку.
private struct HiddenTabsList: View {
    let tabs: [TerminalTab]
    let pick: (TerminalTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tabs) { tab in
                HiddenTabRow(tab: tab) { pick(tab) }
            }
        }
        .padding(8)
        .frame(width: 360)
    }
}

private struct HiddenTabRow: View {
    @ObservedObject var tab: TerminalTab
    let pick: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                SessionDot(status: tab.rang ? "waiting" : tab.status, size: 7).frame(width: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title).font(.system(size: 13)).foregroundStyle(Ink.text).lineLimit(1)
                    Text(tab.spec.projectName).font(.system(size: 11)).foregroundStyle(Ink.faint).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Ink.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct TabChip: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var ui: UIState
    @ObservedObject var tab: TerminalTab
    let selected: Bool
    /// Сколько у агента подзадач. Число стоит после имени, сами подзадачи в ряду под полосой.
    var subtasks = 0
    /// Вкладку тащат: она идет поверх соседей на стекле, как в Finder, и их текст под ней размыт.
    var lifted = false
    @State private var hover = false

    var l: L { L(backend.state.lang) }

    var body: some View {
        Button {
            workspace.selected = tab.id
            tab.rang = false
        } label: {
            HStack(spacing: 9) {
                // крестик при наведении встает на место значка агента того же размера, как в Safari: ширина
                // вкладки не меняется, и соседние вкладки не прыгают. Значок и крестик плавно сменяют друг друга,
                // как в Finder
                ZStack {
                    AgentBadge(agent: tab.spec.utility == nil ? tab.spec.agent : nil, size: 20)
                        .opacity(hover ? 0 : 1)
                        .scaleEffect(hover ? 0.8 : 1)
                    Button {
                        workspace.close(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Ink.chip))
                    }
                    .buttonStyle(.hoverCircle(.overlay))
                    .shortcutHelp(l.closeTab, .closeTab)
                    .accessibilityLabel(l.closeTab)
                    .opacity(hover ? 1 : 0)
                    .scaleEffect(hover ? 1 : 0.8)
                    .allowsHitTesting(hover)
                    .accessibilityHidden(!hover)
                }
                .frame(width: 20, height: 20)
                // название сессии, под ним мелко проект с иконкой и маршрут, как в варианте B макета вкладок
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 5) {
                        ProjectIconView(path: backend.state.project(containing: tab.spec.projectPath)?.path ?? tab.spec.projectPath, size: 12)
                        Text(tab.spec.projectName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                        if tab.spec.proxied || tab.spec.utility == nil || tab.spec.terminal {
                            Text("·").foregroundStyle(Ink.faint)
                            Text(tab.spec.routeLabel(l, proxy: backend.state.proxy))
                                .foregroundStyle(tab.spec.proxied ? Ink.teal : Ink.direct)
                                .fixedSize()
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(selected ? Ink.label : Ink.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if subtasks > 0 {
                    Text("\(subtasks)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Ink.text2)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(Ink.chip))
                        .help(l.t("Подзадач у агента: \(subtasks)", "Agent's subtasks: \(subtasks)"))
                }
                if tab.running && (tab.status == "waiting" || tab.status == "busy") {
                    SessionDot(status: tab.status)
                } else if tab.rang && !selected {
                    Image(systemName: "bell.fill").font(.system(size: 9)).foregroundStyle(Ink.amber)
                } else if !tab.running {
                    Image(systemName: "stop.circle").font(.system(size: 11)).foregroundStyle(Ink.faint)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(selected ? Ink.strong : Ink.muted)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(minWidth: 160, maxWidth: 240, minHeight: 44, maxHeight: 44)
            // невыбранная вкладка под курсором получает светлую подложку, как в Finder
            // выбранная без тени: полоса вкладок обрезала ее снизу, в светлой теме это было видно. Вместо тени
            // тонкая обводка, чтобы белая капсула не сливалась со светлым фоном. Тень только у поднятой вкладки
            .background {
                Capsule().fill(selected || lifted ? Ink.thumb : hover ? Ink.chip : .clear)
                    .overlay { if selected && !lifted { Capsule().strokeBorder(Ink.hairline) } }
                    .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: 8, y: 2)
            }
            // идет перевод строки ввода: по ярлыку вкладки проходит блик, видно и с другой вкладки
            .overlay {
                if tab.inputTranslation?.done == false {
                    TimelineView(.animation) { context in
                        let p = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 * 1.6 - 0.3
                        LinearGradient(stops: [.init(color: .clear, location: min(1, max(0, p - 0.25))),
                                               .init(color: Ink.teal.opacity(0.22), location: min(1, max(0, p))),
                                               .init(color: .clear, location: min(1, max(0, p + 0.25)))],
                                       startPoint: .leading, endPoint: .trailing)
                            .clipShape(Capsule())
                    }
                    .allowsHitTesting(false)
                }
            }
            // поднятая вкладка на стекле, как в Finder: соседняя под ней видна размытой, а не просвечивает
            .glassEffect(lifted ? .regular : .identity, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hover = inside } }
        // полное имя сессии, если в вкладку оно не влезло, и под ним проект
        .help(tab.title + "\n" + tab.spec.projectName)
        .contextMenu { TabMenu(tab: tab) }
    }
}

/// Ряд подзадач, пока у агента есть подзадачи-вкладки или фоновые агенты в сессии.
struct SubtaskRowHost: View {
    @ObservedObject var root: TerminalTab
    let subtasks: [TerminalTab]

    var body: some View {
        if !subtasks.isEmpty || !root.agents.isEmpty || !root.shells.isEmpty { SubtaskRow(root: root, subtasks: subtasks) }
    }
}

/// Опрос фоновых агентов сессии. Висит на фоне InfoBar, который виден всегда: модификатор на пустом ряду
/// подзадач достается только его детям, и без подзадач-вкладок опрос не запускался бы вовсе. Агентов
/// перечитывает раз в 3 секунды из папки переписки сессии.
struct SubAgentPoller: View {
    @ObservedObject var root: TerminalTab

    var body: some View {
        Color.clear.task(id: root.sessionId) {
            if Demo.subtasks {
                root.agents = Demo.subAgents()
                root.shells = Demo.shells()
                return
            }
            guard let sid = root.sessionId, root.spec.agent == .claude, root.spec.utility == nil else {
                root.agents = []
                root.shells = []
                return
            }
            while !Task.isCancelled {
                let (agents, shells) = await Task.detached(priority: .utility) { (SubAgents.list(sid), BackgroundShells.list(sid)) }.value
                if root.agents != agents { root.agents = agents }
                if root.shells != shells { root.shells = shells }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

/// Подзадача в ряду: состояние, имя и ветка worktree.
struct SubtaskChip: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var backend: Backend
    @ObservedObject var tab: TerminalTab
    let selected: Bool
    @State private var hover = false

    var l: L { L(backend.state.lang) }

    /// Ветка из имени вкладки параллельной задачи: "agentmeister · par/drop-files".
    private var branch: String? {
        let parts = tab.spec.projectName.components(separatedBy: " · ")
        return parts.count > 1 ? parts.last : nil
    }

    var body: some View {
        Button {
            workspace.selected = tab.id
            tab.rang = false
        } label: {
            HStack(spacing: 6) {
                Group {
                    if !tab.running {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.teal)
                    } else {
                        SessionDot(status: tab.status, size: 7)
                    }
                }
                .frame(width: 10)
                Text(tab.title).lineLimit(1).foregroundStyle(selected ? Ink.strong : Ink.text2)
                if let branch {
                    Text(branch).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.faint).lineLimit(1)
                }
                if hover {
                    Button { workspace.close(tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
                    }
                    .buttonStyle(.hoverCircle(.overlay))
                    .accessibilityLabel(l.closeTab)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(maxWidth: 280, minHeight: 26, maxHeight: 26)
            .background(Capsule().fill(selected ? Ink.thumb : hover ? Ink.hover : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tab.title + (branch.map { "\n" + $0 } ?? ""))
        .contextMenu { TabMenu(tab: tab) }
    }
}

/// Действия вкладки из макета: в меню по правому клику и в палитре.
struct TabMenu: View {
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var ui: UIState
    @ObservedObject var tab: TerminalTab

    var l: L { L(backend.state.lang) }

    var body: some View {
        let claude = tab.spec.utility == nil && tab.spec.agent == .claude
        Button(l.restart) { tab.restartPreferred(note: l.updating) }
        if claude && tab.sessionId != nil {
            Button(l.slim) { tab.slim(note: l.slimming) }
            Button(l.rename + "…") { ui.renaming = tab }
        }
        if tab.spec.utility == nil {
            Button {
                // напрямую только после того же вопроса, что у кнопки под вкладкой
                if tab.spec.proxied { ui.confirmingDirect = tab } else { tab.switchRoute() }
            } label: {
                Text(tab.spec.proxied ? l.t("Перейти напрямую", "Switch to direct") : l.t("Перейти на proxy", "Switch to proxy"))
                Text(l.t("перезапуск той же сессии", "restarts the same session"))
            }
            SubscriptionSwitchMenu(tab: tab)
        }
        if tab.spec.agent == .codex && tab.spec.utility == nil {
            Button {
                workspace.moveToClaude(tab)
            } label: {
                Text(l.moveToClaude)
                Text(tab.sessionId == nil ? l.t("тред Codex еще не сохранен", "the Codex thread isn't saved yet")
                                          : l.t("контекст этой сессии Codex в новый Claude", "this Codex session's context into a new Claude"))
            }
            .disabled(tab.sessionId == nil)
        }
        if let sid = tab.sessionId {
            Button(l.t("Скопировать id сессии", "Copy session id")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sid, forType: .string)
            }
        }
        if claude {
            Divider()
            Button(role: .destructive) {
                ui.forgetting = tab
            } label: {
                Text(l.forget)
                Text(l.t("удалить без следа", "delete without a trace"))
            }
        }
        Button(l.openTerminalHere) {
            workspace.openTerminal(name: tab.spec.projectName, path: tab.spec.projectPath, direct: !tab.spec.proxied, state: backend.state,
                                   subscription: tab.spec.subscription)
        }
        Divider()
        Button(l.closeTab) { workspace.close(tab.id) }
            .shortcut(.closeTab)
    }
}

/// Переименование сессии вкладки, как /rename.
struct RenameSheet: View {
    @EnvironmentObject var backend: Backend
    @Environment(\.dismiss) private var dismiss
    let tab: TerminalTab
    @State private var title = ""

    var l: L { L(backend.state.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l.t("Переименовать сессию", "Rename the session")).font(.title3.weight(.semibold))
            TextField(l.t("Название", "Title"), text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                PillButton(title: l.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                PillButton(title: l.rename, prominent: true, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear {
            title = backend.state.sessions.first { $0.id == tab.sessionId }?.title ?? tab.title
        }
    }

    private func save() {
        let clean = title.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        tab.rename(clean)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { backend.refresh() }
    }
}

/// Строка над терминалом: папка, ветка, песочница, Remote Control, "не спать" и смена маршрута.
/// Подменю смены подписки у открытой вкладки: перезапуск той же сессии через выбранную подписку.
/// inline рисует пункты без своего подменю, для меню, которое уже открыто кнопкой.
struct SubscriptionSwitchMenu: View {
    @EnvironmentObject var backend: Backend
    @ObservedObject var tab: TerminalTab
    var inline = false

    var body: some View {
        let l = L(backend.state.lang)
        if tab.spec.utility == nil, !Self.options(tab: tab, proxy: backend.state.proxy).isEmpty {
            if inline {
                items(l)
            } else {
                Menu(l.t("Подписка proxy", "Proxy subscription")) { items(l) }
            }
        }
    }

    /// Из чего выбирать: подписки, когда их больше одной, и все оставшиеся, если подписку вкладки удалили.
    /// Иначе вкладка с удаленной подпиской не запустилась бы, а сменить подписку было бы негде.
    static func options(tab: TerminalTab, proxy: AppState.Proxy?) -> [AppState.Proxy.Subscription] {
        let all = proxy?.subscriptions ?? []
        if all.count > 1 { return all }
        if let mine = tab.spec.subscription, !all.contains(where: { $0.name == mine }) { return all }
        return []
    }

    @ViewBuilder private func items(_ l: L) -> some View {
        let subs = Self.options(tab: tab, proxy: backend.state.proxy)
        let cascade = subs.filter { $0.inCascade != false }.map(\.name)
        // напрямую не отмечен ни один пункт
        let current: String?? = tab.spec.proxied ? .some(tab.spec.subscription) : .none
        Toggle(l.t("По очереди: ", "In order: ") + cascade.joined(separator: ", "), isOn: Binding(
            get: { current == .some(nil) }, set: { if $0 && current != .some(nil) { tab.switchSubscription(nil) } }))
        ForEach(subs, id: \.name) { s in
            Toggle(l.t("Только ", "Only ") + s.name + ((s.exit ?? s.country).map { " " + $0 } ?? ""), isOn: Binding(
                get: { current == .some(s.name) }, set: { if $0 && current != .some(s.name) { tab.switchSubscription(s.name) } }))
        }
        Divider()
        Text(l.t("перезапуск той же сессии", "restarts the same session"))
    }
}

struct InfoBar: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    @ObservedObject var tab: TerminalTab
    @Environment(\.openSettings) private var openSettings
    /// Ветку только что скопировали: чип полторы секунды показывает "Скопировано".
    @State private var copied = false
    /// Ветка папки сейчас, из .git/HEAD. Читается вне главного потока раз в 5 секунд, пока строка видна,
    /// а не в body при каждой перерисовке.
    @State private var head: String?
    /// Токены в контексте сессии Claude Code, из ее переписки. Читается раз в 10 секунд, как и ветка.
    @State private var context: SessionContext.Usage?
    @State private var contextOpen = false
    /// Прокрутка левой части: где затухает край и нужен ли разделитель перед кнопками.
    @State private var scroll = TabStrip.StripScroll()

    private func revealFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: tab.spec.projectPath, isDirectory: true))
    }

    /// Подсказка кнопки Remote Control: что включено для запусков и что идет в сессии сейчас.
    private var remoteControlHelp: String {
        switch (tab.spec.remoteControl, tab.running && tab.remoteConnected) {
        case (true, false) where tab.running:
            return l.t("Remote Control включен, но эта сессия пока не подключена. Подключится после /remote-control или перезапуска",
                       "Remote Control is on, but this session is not connected yet. It connects after /remote-control or a restart")
        case (true, _):
            return l.t("Вопросы сессии приходят в приложение Claude на телефоне. Нажмите, чтобы выключить",
                       "Session questions go to the Claude app on your phone. Click to turn it off")
        case (false, true):
            return l.t("Remote Control выключен для следующих запусков. Эта сессия подключена, пока ее не отключат в панели /remote-control или не перезапустят",
                       "Remote Control is off for the next starts. This session stays connected until you disconnect it in the /remote-control panel or restart it")
        case (false, false):
            return l.t("Подключить сессию к Remote Control и отвечать из приложения Claude на телефоне",
                       "Connect the session to Remote Control and answer from the Claude app on your phone")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyBranch(_ branch: String) {
        copy(branch)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    /// Настройки на разделе proxy и host-run.
    private func openProxySettings() {
        UserDefaults.standard.set("proxy", forKey: "settingsSection")
        openSettings()
        NSApp.activate()
    }

    var l: L { L(backend.state.lang) }

    var body: some View {
        // ветка из истории сессии осталась бы той, на которой она началась, поэтому сначала .git/HEAD
        let branch = head ?? backend.state.sessions.first { $0.id == tab.sessionId }?.branch ?? ""
        // порт этой вкладки: у вкладки только через одну подписку он свой
        let port = backend.state.proxy?.port(for: tab.spec.subscription) ?? backend.state.proxy?.port ?? 17890
        // слева сведения о сессии, они прокручиваются вбок под затухающими краями. Справа кнопки одной группой
        // значков: в узком окне они не сокращаются и при любой ширине стоят на тех же местах
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let parent = tab.spec.parent, workspace.tabs.contains(where: { $0.id == parent }) {
                        Chip(action: { workspace.selected = parent }) {
                            Image(systemName: "arrow.up").font(.system(size: 10, weight: .semibold))
                            Text(l.t("к агенту", "to the agent"))
                        }
                        .help(l.t("Вернуться к вкладке агента", "Back to the agent's tab"))
                    }
                    Chip(mono: true, action: { revealFolder() }) {
                        Text(tilde(tab.spec.projectPath)).lineLimit(1)
                    }
                    .help(l.t("Открыть папку в Finder", "Open the folder in Finder"))
                    .contextMenu {
                        Button(l.t("Открыть в Finder", "Open in Finder")) { revealFolder() }
                        Button(l.t("Скопировать путь", "Copy path")) { copy(tab.spec.projectPath) }
                    }
                    if !branch.isEmpty {
                        Chip(mono: true, action: { copyBranch(branch) }) {
                            Text(l.t("ветка", "branch")).font(.system(size: 12)).foregroundStyle(Ink.faint)
                            Text(copied ? l.t("скопировано", "copied") : branch).lineLimit(1)
                        }
                        .help(l.t("Скопировать имя ветки", "Copy the branch name"))
                    }
                    if tab.spec.utility != nil {
                        Chip(foreground: Ink.muted, action: { openProxySettings() }) {
                            Text(tab.spec.proxied ? l.t("proxy run, сеть через 127.0.0.1:\(port)", "proxy run, network via 127.0.0.1:\(port)")
                                                  : l.t("команда agentmeister", "agentmeister command"))
                        }
                    } else if tab.spec.proxied {
                        Chip(background: Ink.tealChip, foreground: Ink.teal, action: { openProxySettings() }) {
                            Text(tab.spec.agent == .codex
                                 ? l.t("строгий профиль, сеть только через mihomo", "strict profile, network only through mihomo")
                                 : l.t("sandbox-exec, сеть через 127.0.0.1:\(port)", "sandbox-exec, network via 127.0.0.1:\(port)"))
                        }
                        .help(l.t("Настройки proxy и host-run", "Proxy and host-run settings"))
                    } else {
                        Chip(foreground: Ink.direct, action: { openProxySettings() }) {
                            Text(l.t("напрямую, без sandbox-exec", "direct, no sandbox-exec"))
                        }
                        .help(l.t("Настройки proxy и host-run", "Proxy and host-run settings"))
                    }
                    if !tab.running {
                        Text(l.exited + (tab.exitCode.map { ", \($0)" } ?? ""))
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.faint)
                    }
                }
            }
            .frame(height: 26)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onScrollGeometryChange(for: TabStrip.StripScroll.self) { geo in
                TabStrip.StripScroll(offset: geo.contentOffset.x, content: geo.contentSize.width, width: geo.containerSize.width)
            } action: { _, now in
                scroll = now
            }
            // край затухает, только когда за ним что-то есть
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: scroll.left ? 28 : 0)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: scroll.right ? 28 : 0)
                }
            }
            .animation(.easeOut(duration: 0.15), value: scroll.left)
            .animation(.easeOut(duration: 0.15), value: scroll.right)
            if scroll.overflows {
                Rectangle().fill(Ink.hairline).frame(width: 1, height: 18)
            }
            controls
                .fixedSize()
        }
        .padding(.horizontal, 4)
        .task(id: tab.sessionId) {
            context = nil
            guard let sid = tab.sessionId, tab.spec.utility == nil else { return }
            let codex = tab.spec.agent == .codex
            while !Task.isCancelled {
                let now = await Task.detached(priority: .utility) { codex ? SessionContext.codex(sid) : SessionContext.claude(sid) }.value
                if context != now { context = now }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .task(id: tab.spec.projectPath) {
            let path = tab.spec.projectPath
            head = nil
            while !Task.isCancelled {
                let now = await Task.detached(priority: .utility) { GitHead.branch(at: path) }.value
                if head != now { head = now }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

extension InfoBar {
    /// Кнопки справа, только значки. Подписи в подсказках и для VoiceOver.
    @ViewBuilder
    var controls: some View {
        HStack(spacing: 8) {
            if tab.spec.agent == .codex && tab.spec.utility == nil {
                Button { workspace.moveToClaude(tab) } label: { Label(l.moveToClaude, systemImage: "arrow.right.circle") }
                    .buttonStyle(ChipStyle(iconOnly: true))
                    .accessibilityLabel(l.moveToClaude)
                    .disabled(tab.sessionId == nil)
                    .help(l.moveToClaude + ". " + (tab.sessionId == nil
                          ? l.t("Тред Codex появится после первого запроса", "The Codex thread appears after the first request")
                          : l.t("Новая вкладка Claude Code с контекстом этой сессии Codex", "A new Claude Code tab with this Codex session's context")))
            }
            if tab.spec.utility == nil && tab.spec.agent == .claude {
                Button {
                    if !tab.setRemoteControl(!tab.spec.remoteControl) { ui.confirmingRemote = tab }
                } label: {
                    Label("Remote Control", systemImage: "iphone")
                }
                .buttonStyle(ChipStyle(on: tab.spec.remoteControl, iconOnly: true))
                .accessibilityLabel("Remote Control")
                .help("Remote Control. " + remoteControlHelp)
                .accessibilityAddTraits(tab.spec.remoteControl ? .isSelected : [])
            }
            if tab.spec.utility == nil {
                Button {
                    tab.setAwake(!tab.spec.awake)
                } label: {
                    Label(l.t("Не спать", "Stay awake"), systemImage: "timer")
                }
                .buttonStyle(ChipStyle(on: tab.spec.awake, iconOnly: true))
                .accessibilityLabel(l.t("Не спать", "Stay awake"))
                .help(l.t("Не спать. Mac не уснет, пока идет эта сессия", "Stay awake. The Mac stays awake while this session runs"))
                .accessibilityAddTraits(tab.spec.awake ? .isSelected : [])
            }
            if tab.spec.utility == nil, let usage = context {
                contextChip(usage)
            }
            if tab.spec.utility == nil {
                let title = tab.spec.proxied ? l.t("Перезапустить напрямую", "Restart without proxy")
                                             : l.t("Перезапустить через proxy", "Restart via proxy")
                Button { if tab.spec.proxied { ui.confirmingDirect = tab } else { tab.switchRoute() } } label: {
                    Label(title, systemImage: tab.spec.proxied ? "arrow.triangle.2.circlepath" : "shield")
                }
                .buttonStyle(ChipStyle(iconOnly: true))
                .accessibilityLabel(title)
                .help(title + ". " + (tab.spec.proxied ? l.t("Та же сессия, но без песочницы и proxy", "The same session without the sandbox and proxy")
                                                       : l.t("Та же сессия в песочнице, сеть через mihomo", "The same session in the sandbox, network through mihomo")))
                if !SubscriptionSwitchMenu.options(tab: tab, proxy: backend.state.proxy).isEmpty {
                    let route = tab.spec.proxied ? tab.spec.routeLabel(l, proxy: backend.state.proxy) : l.t("Подписка", "Subscription")
                    Menu {
                        SubscriptionSwitchMenu(tab: tab, inline: true)
                    } label: {
                        Label(route, systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .menuStyle(.button)
                    .buttonStyle(ChipStyle(iconOnly: true))
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(route)
                    .help(route + ". " + l.t("Перезапустить ту же сессию через другую подписку proxy", "Restart the same session through another proxy subscription"))
                }
            } else {
                Button { tab.restart() } label: { Label(l.restart, systemImage: "arrow.clockwise") }
                    .buttonStyle(ChipStyle(iconOnly: true))
                    .accessibilityLabel(l.restart)
                    .help(l.restart)
            }
        }
    }

    /// Полоска заполнения окна модели, цифры в подсказке. Если окно неизвестно, вместо полоски число токенов.
    /// С 200 тыс. (или 80% окна поменьше) желтая. Клик открывает выбор, чем сжать.
    func contextChip(_ usage: SessionContext.Usage) -> some View {
        let over = usage.over
        let numbers = SessionContext.short(usage.used) + (usage.size.map { " / " + SessionContext.short($0) } ?? "")
        return Chip(foreground: over ? Ink.amber : Ink.text2, action: tab.running && tab.sessionId != nil ? { contextOpen = true } : nil) {
            if let size = usage.size {
                Capsule().fill(Ink.hairline)
                    .frame(width: 36, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(over ? Ink.amberDot : Ink.text2.opacity(0.6))
                            .frame(width: 36 * min(1, Double(usage.used) / Double(size)), height: 4)
                    }
            } else {
                Text(numbers).monospacedDigit()
            }
        }
        .help(l.t("Контекст \(numbers). Токенов в контексте сессии" + (usage.size == nil ? "" : " из окна модели") + ". Клик предлагает сжать разговор.",
                  "Context \(numbers). Tokens in this session's context" + (usage.size == nil ? "" : " out of the model's window") + ". Click to condense the conversation."))
        .accessibilityLabel(l.t("Контекст \(numbers)", "Context \(numbers)"))
        .popover(isPresented: $contextOpen, arrowEdge: .bottom) { CompactPopover(tab: tab, usage: usage, l: l) { contextOpen = false } }
    }
}

/// Выбор под чипом контекста. /compact пересказывает разговор и уменьшает контекст, /slim убирает из переписки
/// скриншоты и длинные выводы и уменьшает файл. "Оба" сначала сжимает файл, затем открывает сессию с /compact.
struct CompactPopover: View {
    @ObservedObject var tab: TerminalTab
    let usage: SessionContext.Usage
    let l: L
    let close: () -> Void

    var body: some View {
        let used = SessionContext.short(usage.used)
        let window = usage.size.map { SessionContext.short($0) }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(window.map { l.t("В контексте \(used) из \($0)", "\(used) of \($0) in context") }
                     ?? l.t("В контексте \(used) токенов", "\(used) tokens in context"))
                    .font(.system(size: 13, weight: .semibold))
                if usage.over {
                    Text(l.t("Разговор пора сжать: длинный контекст дороже и хуже держит детали.",
                             "Time to condense: a long context costs more and keeps details worse."))
                        .foregroundStyle(Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            option(l.t("Сжать разговор", "Condense the conversation"), "/compact",
                   l.t("Claude перескажет разговор, контекст станет меньше. Ранние подробности останутся только в пересказе.",
                       "Claude summarizes the conversation and the context shrinks. Early details survive only in the summary.")) {
                tab.submit("/compact")
            }
            if tab.spec.agent == .claude {
                option(l.t("Сжать переписку", "Slim the transcript"), "/slim",
                       l.t("Убирает старые скриншоты и длинные выводы из файла сессии, разговор не меняется. Сессия перезапустится.",
                           "Removes old screenshots and long outputs from the session file, the conversation stays. The session restarts.")) {
                    tab.slim(note: l.slimming)
                }
                option(l.t("Все вместе", "Both"), "/slim + /compact",
                       l.t("Сначала /slim, потом сессия откроется и сразу выполнит /compact.",
                           "First /slim, then the session reopens and runs /compact right away.")) {
                    tab.slim(note: l.slimming, then: "/compact")
                }
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 340)
    }

    private func option(_ title: String, _ command: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button {
            close()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium).foregroundStyle(Ink.text)
                    Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.faint)
                }
                Text(detail).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover(8))
    }
}

/// Показывает терминал выбранной вкладки. NSView терминала не пересоздается, только меняется местами.
struct TerminalHost: NSViewRepresentable {
    let tab: TerminalTab?

    /// Терминал занимает все, что ему дали, и не диктует высоту сам: иначе баннер над ним выталкивал бы
    /// полосу вкладок за верх окна.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 200))
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        // Без обрезки SwiftTerm дорисовывает символ за левым краем
        container.layer?.masksToBounds = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let colors = TerminalThemes.resolve(TerminalPrefs.colors, windowDark: context.environment.colorScheme == .dark)
        container.layer?.backgroundColor = colors.background.cgColor
        guard let term = tab?.view else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        TerminalThemes.apply(colors, to: term)
        if term.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            term.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(term)
            NSLayoutConstraint.activate([
                term.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
                term.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                term.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
                term.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            ])
        }
        // пока открыта панель поиска, фокус у ее поля, а не у терминала; пока агент обновляется, ни у кого
        if tab?.finding != true && tab?.updatingAgent != true {
            DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
        }
    }
}

/// Плашка поверх терминала, пока агент вкладки обновляется перед перезапуском: терминал затемнен, клики до него
/// не доходят, а сессия откроется сама, когда обновление закончится.
struct AgentUpdateOverlay: View {
    @EnvironmentObject var backend: Backend
    @ObservedObject var tab: TerminalTab

    var body: some View {
        if tab.updatingAgent {
            let l = L(backend.state.lang)
            ZStack {
                Rectangle().fill(.black.opacity(0.45))
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text(l.updating).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.strong)
                    Text(l.t("Сессия откроется сама, когда обновление закончится. До этого терминал не принимает ввод.",
                             "The session reopens by itself when the update finishes. Until then the terminal takes no input."))
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            .contentShape(Rectangle())
            .onTapGesture {}
            .transition(.opacity)
        }
    }
}

/// Перевод строки ввода по ⌘⇧T: карточка над снимком терминала (под снимком Claude Code или Codex в редакторе стер экран). Пока ждем, по тексту строки пробегают случайные буквы, когда перевод пришел, текст слева
/// направо складывается в английский. Ввод в это время не идет, Esc отменяет.
struct InputTranslationOverlay: View {
    @EnvironmentObject var backend: Backend
    @ObservedObject var tab: TerminalTab
    /// Сколько секунд перевод складывается из букв, прежде чем снимок уберут.
    static let reveal = 0.7

    var body: some View {
        if let t = tab.inputTranslation {
            let l = L(backend.state.lang)
            // снимок терминала лежит в нем самом (AppTerminalView.freeze), здесь только карточка и защита от кликов
            ZStack {
                Color.clear.contentShape(Rectangle()).onTapGesture {}
                card(t, l)
            }
        }
    }

    private func card(_ t: TerminalTab.InputTranslation, _ l: L) -> some View {
        TimelineView(.periodic(from: t.started, by: 0.06)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if t.issue == nil || t.issue == .cancelled {
                        Circle().fill(Ink.teal).frame(width: 7, height: 7)
                            .shadow(color: Ink.teal.opacity(0.8), radius: 4)
                            .opacity(t.done ? 1 : 0.45 + 0.55 * abs(sin(context.date.timeIntervalSince(t.started) * 3)))
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.amber)
                    }
                    Text(title(t, l)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.strong)
                    if let model = t.model, t.issue == nil {
                        Text(model).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.muted).lineLimit(1)
                    }
                }
                if let text = shownText(t, at: context.date) {
                    Text(text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Ink.teal)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let detail = detail(t, l) {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                }
                if t.issue == nil, !t.done {
                    let secs = String(format: "%.1f", context.date.timeIntervalSince(t.started))
                    Text((l.en ? secs : secs.replacingOccurrences(of: ".", with: ",")) + l.t(" с · Esc отменит", " s · Esc cancels"))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Ink.faint)
                }
            }
        }
        .frame(width: 360, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    /// Текст в карточке: оригинал с мерцающими буквами, пока ждем, потом раскрытие перевода. Ошибку показывает
    /// подпись, а не текст.
    private func shownText(_ t: TerminalTab.InputTranslation, at date: Date) -> String? {
        guard let original = t.original, !original.isEmpty else { return nil }
        let tick = Int(date.timeIntervalSinceReferenceDate * 16)
        if let english = t.english, let doneAt = t.doneAt {
            let progress = min(1, date.timeIntervalSince(doneAt) / Self.reveal)
            return Self.scramble(original, into: english, progress: progress, tick: tick)
        }
        if t.done { return t.issue == .cancelled ? original : nil }
        return Self.scramble(original, into: original, progress: 0, tick: tick, noise: 0.18)
    }

    private static let glyphs = Array("абвгдежзиклмнопрстуфхцчшэюяabcdefghijklmnopqrstuvwxyz")

    /// Первые progress долей текста уже английские, остальное оригинал, где буквы с вероятностью noise
    /// (или все, когда перевод пришел) заменены случайными. Пробелы и переводы строк остаются на месте.
    static func scramble(_ from: String, into to: String, progress: Double, tick: Int, noise: Double = 1) -> String {
        let a = Array(from), b = Array(to)
        let count = max(a.count, b.count)
        // метки [Image #N] не мерцают: это вложения, их надо узнавать
        var kept = Set<Int>()
        for match in from.matches(of: #/\[Image #\d+\]/#) {
            let start = from.distance(from: from.startIndex, to: match.range.lowerBound)
            kept.formUnion(start..<(start + from[match.range].count))
        }
        let settled = Int(Double(count) * progress)
        var out = ""
        for i in 0..<count {
            if i < settled {
                if i < b.count { out.append(b[i]) }
                continue
            }
            guard i < a.count else { continue }
            let c = a[i]
            var h = UInt64(truncatingIfNeeded: i &* 2654435761 &+ tick &* 40503)
            h ^= h >> 13
            let roll = Double(h % 1000) / 1000
            out.append(c.isLetter && !kept.contains(i) && roll < noise ? glyphs[Int(h % UInt64(glyphs.count))] : c)
        }
        return out
    }

    private func title(_ t: TerminalTab.InputTranslation, _ l: L) -> String {
        switch t.issue {
        case nil: return t.done ? l.t("Перевел", "Translated") : l.t("Перевожу", "Translating")
        case .cancelled: return l.t("Перевод отменен", "Translation cancelled")
        default: return l.t("Не перевел", "Not translated")
        }
    }

    private func detail(_ t: TerminalTab.InputTranslation, _ l: L) -> String? {
        switch t.issue {
        case .notOpened?: return l.t("Агент не открыл строку ввода в редакторе. Закрой меню или диалог и нажми еще раз.",
                                     "The agent didn't open the input line in the editor. Close the menu or dialog and try again.")
        case .timeout?: return l.t("Переводчик не ответил за 20 секунд, текст остался как был.",
                                   "The translator didn't answer in 20 seconds, the text is unchanged.")
        case .failed(let why)?: return why.isEmpty ? nil : why
        default: return nil
        }
    }
}

/// Кнопка "Перевести" у поля первого запроса: переводит текст на месте, как ⌘⇧T во вкладке, через
/// agentmeister translate text. ⌘⇧T, пока поле на экране, нажимает ее же.
struct TranslateFieldButton: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var ui: UIState
    @Binding var text: String
    @State private var busy = false
    @State private var failure: String?

    /// В тексте есть нелатинские буквы, иначе переводить нечего (как skip_reason в translate.py).
    static func needsTranslation(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value > 0x24F && !(0x1E00...0x1EFF).contains($0.value) }
    }

    var body: some View {
        let l = L(backend.state.lang)
        Button { translate(l) } label: {
            HStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: failure == nil ? "character.bubble" : "exclamationmark.triangle.fill")
                }
                Text(failure == nil ? l.t("Перевести", "Translate") : l.t("Не перевел", "Not translated"))
                Text(ShortcutStore.shared.label(.translateInput)).opacity(0.6)
            }
            .font(.system(size: 12))
            .foregroundStyle(failure == nil ? Ink.text2 : Ink.amber)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(Ink.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverCapsule(.overlay))
        // не сжимается: в узком окне ряд с ней перестраивается, а не обрезает подписи
        .fixedSize()
        .disabled(busy || !Self.needsTranslation(text))
        .help(failure ?? l.t("Перевести текст на английский, проверить и отправить", "Translate the text to English, check it and send"))
        .onChange(of: ui.translateComposer) { translate(l) }
    }

    private func translate(_ l: L) {
        let source = text
        guard !busy, Self.needsTranslation(source) else { return }
        busy = true
        failure = nil
        Task {
            let r = await Task.detached(priority: .userInitiated) { Backend.runWithInput(["translate", "text"], input: source) }.value
            busy = false
            // пока шел перевод, текст поправили руками: перевод старого текста не ставим
            guard text == source else { return }
            if r.ok, !r.text.isEmpty {
                text = r.text
            } else {
                failure = r.text.isEmpty ? l.t("Перевод не удался", "Translation failed") : r.text
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { failure = nil }
            }
        }
    }
}

/// ⌘⇧T без ключа переводчика: карточка во вкладке с полем для ключа. Провайдер определяется по виду ключа,
/// ключ сохраняет agentmeister translate key, после этого сразу идет перевод. Esc или клик мимо закрывают.
struct TranslateKeyCard: View {
    @EnvironmentObject var backend: Backend
    @ObservedObject var tab: TerminalTab
    @State private var key = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        if tab.askingKey {
            let l = L(backend.state.lang)
            ZStack {
                Rectangle().fill(.black.opacity(0.38))
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                card(l)
            }
            .onExitCommand { close() }
            .onAppear { focused = true }
        }
    }

    private func card(_ l: L) -> some View {
        let provider = TranslateKey.provider(key)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Circle().fill(Ink.amber).frame(width: 7, height: 7).shadow(color: Ink.amber.opacity(0.8), radius: 4)
                Text(l.t("Ключ для перевода", "Translator key")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.strong)
            }
            Text(l.t("Вставь ключ OpenRouter или Google AI Studio. Он ляжет в ~/.config/agentmeister с правами 600, как через agentmeister translate key. Строка ввода осталась как была.",
                     "Paste an OpenRouter or Google AI Studio key. It goes to ~/.config/agentmeister with mode 600, as with agentmeister translate key. The input line is unchanged."))
                .font(.system(size: 12.5)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                SecureField("sk-or-v1-…  /  AQ.… / AIza…", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
                    .focused($focused)
                    .onSubmit { save(l) }
                    .accessibilityLabel(l.t("Ключ переводчика", "Translator key"))
                Text(error ?? (trimmed.isEmpty ? l.t("Провайдер определится по ключу", "The key tells which provider it is")
                               : provider.map { l.t("Похоже на ключ \($0), перевод пойдет через него", "Looks like a \($0) key, translation goes through it") }
                               ?? l.t("Не похоже на ключ OpenRouter или Google AI Studio", "Doesn't look like an OpenRouter or Google AI Studio key")))
                    .font(.system(size: 12))
                    .foregroundStyle(error != nil || (provider == nil && !trimmed.isEmpty) ? Ink.red : provider != nil ? Ink.teal : Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Link(l.t("Ключ OpenRouter", "OpenRouter key"), destination: URL(string: "https://openrouter.ai/settings/keys")!)
                Link(l.t("Ключ Google AI Studio", "Google AI Studio key"), destination: URL(string: "https://aistudio.google.com/apikey")!)
            }
            .font(.system(size: 12))
            HStack(spacing: 8) {
                PillButton(title: l.t("Сохранить и перевести", "Save and translate"), prominent: true, small: true, busy: saving) { save(l) }
                    .disabled(provider == nil || saving)
                PillButton(title: l.t("Отмена", "Cancel"), small: true) { close() }
                Spacer(minLength: 0)
                Text(l.t("Esc закроет", "Esc closes")).font(.system(size: 11)).foregroundStyle(Ink.faint)
            }
        }
        .frame(width: 380, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func close() {
        key = ""
        error = nil
        tab.askingKey = false
        tab.view.window?.makeFirstResponder(tab.view)
    }

    private func save(_ l: L) {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TranslateKey.provider(value) != nil, !saving else { return }
        saving = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { Backend.runWithInput(["translate", "key"], input: value) }.value
            saving = false
            guard r.ok else {
                error = r.text.isEmpty ? l.t("Ключ не сохранился", "The key wasn't saved") : r.text
                return
            }
            close()
            tab.translateInput()
        }
    }
}

/// Панель поиска над терминалом, когда она открыта у этой вкладки.
struct TerminalFindOverlay: View {
    @ObservedObject var tab: TerminalTab

    var body: some View {
        if tab.finding {
            TerminalFindBar(tab: tab)
                .padding(.top, 12)
                .padding(.trailing, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// Поиск по выводу вкладки: поле, "номер из всего", регистр, слово целиком, регулярное выражение, стрелки и
/// закрытие. Enter ищет дальше, Shift+Enter назад, Esc закрывает.
struct TerminalFindBar: View {
    @EnvironmentObject var backend: Backend
    @ObservedObject var tab: TerminalTab
    @FocusState private var focused: Bool

    var l: L { L(backend.state.lang) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.muted)
            TextField(l.t("Найти в выводе", "Find in output"), text: $tab.findTerm)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 190)
                .focused($focused)
                .onSubmit { tab.step(forward: !NSEvent.modifierFlags.contains(.shift)) }
                .onKeyPress(.escape) {
                    tab.closeFind()
                    return .handled
                }
            Text(counter)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(!tab.findTerm.isEmpty && tab.findPosition.total == 0 ? Ink.amber : Ink.muted)
                .frame(minWidth: 56, alignment: .trailing)
            Rectangle().fill(Ink.hairline).frame(width: 1, height: 16)
            option("Aa", on: tab.findOptions.caseSensitive, help: l.t("С учетом регистра", "Match case")) {
                tab.findOptions.caseSensitive.toggle()
            }
            option("W", on: tab.findOptions.wholeWord, help: l.t("Слово целиком", "Whole word")) {
                tab.findOptions.wholeWord.toggle()
            }
            option(".*", on: tab.findOptions.regex, help: l.t("Регулярное выражение", "Regular expression")) {
                tab.findOptions.regex.toggle()
            }
            Rectangle().fill(Ink.hairline).frame(width: 1, height: 16)
            icon("chevron.up", help: l.t("Предыдущее (⇧⌘G)", "Previous (⇧⌘G)")) { tab.step(forward: false) }
            icon("chevron.down", help: l.t("Следующее (⌘G)", "Next (⌘G)")) { tab.step(forward: true) }
            icon("xmark", help: l.t("Закрыть (Esc)", "Close (Esc)")) { tab.closeFind() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 38)
        .glassEffect(.regular, in: Capsule())
        .onAppear { focused = true }
        .onChange(of: tab.findFocus) { focused = true }
        .onChange(of: tab.findTerm) { tab.restartSearch() }
    }

    /// "3/14", "нет совпадений" или пусто, пока ничего не введено. Больше тысячи совпадений SwiftTerm не считает.
    private var counter: String {
        guard !tab.findTerm.isEmpty else { return "" }
        let (index, total) = tab.findPosition
        if total == 0 { return l.t("нет", "none") }
        return "\(index)/" + (total >= 1000 ? "1000+" : "\(total)")
    }

    private func option(_ title: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            tab.restartSearch()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(on ? Ink.modeOn : Ink.muted)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Ink.modeOnBg : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover(6))
        .help(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func icon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Ink.text2)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover(6))
        .help(help)
    }
}

// MARK: - Панель сессии

struct InspectorView: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace

    var l: L { L(backend.state.lang) }

    var body: some View {
        if let tab = workspace.current {
            TabInspector(tab: tab)
        } else {
            ContentUnavailableView(l.noTabs, systemImage: "sidebar.right")
        }
    }
}

/// Панель сессии: заголовок со статусом, затем сворачиваемые секции. Маршрут цепочкой от агента до выхода,
/// действия плитками с подписями, изменения рабочей копии, бэклог и host-run.
struct TabInspector: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    @ObservedObject var tab: TerminalTab
    @AppStorage("restartWithUpdate") private var withUpdate = true
    /// Свернутые секции через запятую: route, actions, changes, backlog, hostrun.
    @AppStorage("inspector.collapsed") private var collapsed = ""
    /// Git и бэклог проекта вкладки из app-state project. Обновляются при смене вкладки и раз в минуту.
    @State private var project: ProjectData?
    /// Изменения рабочей копии: git status раз в 5 секунд, пока инспектор открыт.
    @State private var changes: GitChanges.Snapshot?

    var l: L { L(backend.state.lang) }

    var body: some View {
        let saved = backend.state.sessions.first { $0.id == tab.sessionId }
        let claude = tab.spec.utility == nil && tab.spec.agent == .claude
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InspectorSection(title: l.route, open: open("route")) {
                    RouteChain(nodes: routeNodes, direct: !tab.spec.proxied)
                }

                InspectorSection(title: l.t("Действия", "Actions"), open: open("actions")) {
                    actionTiles(claude: claude)
                }

                if tab.spec.utility == nil, let changes {
                    let numbers = DiffColumns(changes.files)
                    InspectorSection(title: l.t("Изменения", "Changes"), open: open("changes")) {
                        if !changes.files.isEmpty {
                            Text("\(changes.files.count)").foregroundStyle(Ink.faint)
                            Spacer(minLength: 4)
                            numbers.cells(numbers.totalAdded, numbers.totalRemoved)
                        }
                    } content: {
                        ChangesList(snapshot: changes, numbers: numbers, l: l)
                    }
                }

                let todos = (project?.todos ?? []).filter { !$0.done }
                if tab.spec.utility == nil, !todos.isEmpty {
                    InspectorSection(title: l.t("Бэклог", "Backlog"), open: open("backlog")) {
                        Text("\(todos.count)").foregroundStyle(Ink.faint)
                    } content: {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(todos.prefix(6), id: \.self) { item in
                                Button {
                                    if let n = item.n { markDone(n) }
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "square").foregroundStyle(Ink.muted)
                                        Text(item.text).foregroundStyle(Ink.text).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.hover(6))
                                .help(l.t("Отметить сделанной", "Mark done"))
                            }
                        }
                        .padding(.horizontal, -4)
                    }
                }

                if let h = backend.state.hostRun {
                    InspectorSection(title: "host-run", open: open("hostrun")) {
                        Spacer(minLength: 4)
                        GlowDot(color: h.running ? Ink.tealDot : Ink.amberDot, size: 6)
                    } content: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(h.running ? l.t("Исполнитель работает", "The runner is running") : l.t("Исполнитель не запущен", "The runner isn't running"))
                                .foregroundStyle(h.running ? Ink.teal : Ink.amber)
                            HStack(spacing: 4) {
                                Text(l.commands(h.commands) + l.t(" в белом списке.", " in the allowlist."))
                                    .foregroundStyle(Ink.muted)
                                SettingsLink {
                                    Text(l.t("Открыть", "Open")).foregroundStyle(Ink.link)
                                }
                                .buttonStyle(.textLink)
                                .simultaneousGesture(TapGesture().onEnded { UserDefaults.standard.set("proxy", forKey: "settingsSection") })
                            }
                        }
                    }
                }
                Rectangle().fill(Ink.hairline).frame(height: 1)
            }
            .font(.system(size: 12))
        }
        .scrollIndicators(.never)
        // демо inspector-scroll: панель прокручена до середины, секции видны и под шапкой, и под нижней полосой
        .defaultScrollAnchor(Demo.active && Demo.scene == "inspector-scroll" ? .center : .top)
        // шапка стоит на месте, секции уходят под нее размытыми, как строки под шапкой проектов слева
        .safeAreaBar(edge: .top, spacing: 0) {
            header(title: saved?.title.isEmpty == false ? saved!.title : tab.title,
                   branch: project?.git?.branch ?? saved?.branch)
                .frame(maxWidth: .infinity, alignment: .leading)
                .blurBar(edge: .top)
        }
        // снизу полоса размытия: строки растворяются у скругленного края карточки, а не срезаются им
        .safeAreaBar(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 20).frame(maxWidth: .infinity).blurBar(edge: .bottom)
        }
        .task(id: tab.spec.projectPath) {
            changes = nil
            let path = tab.spec.projectPath
            guard tab.spec.utility == nil else { return }
            while !Task.isCancelled {
                let now = await Task.detached(priority: .utility) { GitChanges.snapshot(at: path) }.value
                if changes != now { changes = now }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: tab.spec.projectPath) {
            while !Task.isCancelled {
                if tab.spec.utility == nil { project = await Backend.json(["app-state", "project", tab.spec.projectPath]) }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Заголовок сессии, под ним статус процесса и ветка.
    private func header(title: String, branch: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                GlowDot(color: tab.running ? Ink.tealDot : Ink.amberDot, size: 6)
                if tab.running {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(l.t("Работает ", "Running ") + l.duration(context.date.timeIntervalSince(tab.startedAt)))
                    }
                    .foregroundStyle(Ink.teal)
                } else {
                    Text(l.exited.prefix(1).uppercased() + l.exited.dropFirst() + (tab.exitCode.map { ", \($0)" } ?? ""))
                        .foregroundStyle(Ink.direct)
                }
                Spacer(minLength: 6)
                if let branch, !branch.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                        Text(branch).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(Ink.faint)
                    .help(branch)
                }
            }
            .font(.system(size: 11.5))
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    /// Узлы маршрута: агент, затем песочница, mihomo и выход для proxy или одно прямое подключение.
    private var routeNodes: [RouteChain.Node] {
        let agent = RouteChain.Node(title: agentName, detail: agentModel ?? "")
        guard tab.spec.proxied else {
            return [agent, .init(title: l.t("Напрямую", "Direct connection"), detail: l.t("без песочницы", "no sandbox"), color: Ink.direct)]
        }
        let proxy = backend.state.proxy
        let exit = [proxy?.exit, proxy?.protocol].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return [agent,
                .init(title: "sandbox-exec", detail: l.t("без прямой сети", "no direct network")),
                .init(title: "mihomo", detail: "127.0.0.1:\(proxy?.port ?? 17890)", mono: true),
                .init(title: exit.isEmpty ? "proxy" : exit, detail: proxy?.ip ?? "", color: Ink.teal, mono: true)]
    }

    private func actionTiles(claude: Bool) -> some View {
        let tiles = tileList(claude: claude)
        let rows = stride(from: 0, to: tiles.count, by: 2).map { Array(tiles[$0..<min($0 + 2, tiles.count)]) }
        return Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    ForEach(rows[i].indices, id: \.self) { j in rows[i][j] }
                    if rows[i].count == 1 { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Плитки по виду вкладки: Slim только у сессии Claude с id, Forget только у Claude.
    private func tileList(claude: Bool) -> [ActionTile] {
        var tiles: [ActionTile] = [
            ActionTile(icon: "arrow.clockwise", title: l.t("Перезапуск", "Restart"),
                       hint: l.t("та же сессия, с того же места", "same session, picks up where it stopped"),
                       highlighted: !tab.running,
                       toggle: claude ? $withUpdate : nil, toggleTitle: l.t("сначала обновить", "update first")) {
                tab.restartPreferred(note: l.updating)
            }
        ]
        if claude && tab.sessionId != nil {
            tiles.append(ActionTile(icon: "arrow.down.right.and.arrow.up.left", title: l.slim,
                                    hint: l.t("убрать старые скриншоты и длинные выводы", "drop old screenshots and long outputs")) {
                tab.slim(note: l.slimming)
            })
        }
        if tab.spec.utility == nil {
            tiles.append(ActionTile(icon: "sparkles", title: l.t("С чистого листа", "Fresh start"),
                                    hint: l.t("пустой контекст, эта сессия останется в /resume", "empty context, this one stays in /resume")) {
                tab.fresh()
            })
        }
        if claude {
            tiles.append(ActionTile(icon: "trash", title: l.forget,
                                    hint: l.t("удалить без следа и открыть чистую", "delete without a trace, open a clean one"),
                                    destructive: true) {
                ui.forgetting = tab
            })
        }
        return tiles
    }

    /// Привязка к свернутости секции, хранится в inspector.collapsed.
    private func open(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.split(separator: ",").contains(Substring(id)) },
            set: { isOpen in
                var set = Set(collapsed.split(separator: ",").map(String.init))
                if isOpen { set.remove(id) } else { set.insert(id) }
                collapsed = set.sorted().joined(separator: ",")
            })
    }

    private var agentName: String {
        guard tab.spec.utility == nil else { return "agentmeister" }
        return tab.spec.agent == .codex ? "Codex" : "Claude Code"
    }

    /// Модель из флагов вкладки, иначе из настроек агента.
    private var agentModel: String? {
        guard tab.spec.utility == nil else { return nil }
        return tab.spec.modelFlag ?? (backend.state.models?[tab.spec.agent.rawValue] ?? nil)
    }

    private func markDone(_ n: Int) {
        let path = tab.spec.projectPath
        Task {
            _ = await backend.perform(["todo", "-p", path, "done", String(n)])
            project = await Backend.json(["app-state", "project", path])
        }
    }
}

/// Секция инспектора: строка с шевроном сворачивает ее, справа счетчик или статус. Сверху тонкая линия.
struct InspectorSection<Trailing: View, Content: View>: View {
    let title: String
    @Binding var open: Bool
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(title: String, open: Binding<Bool>, @ViewBuilder trailing: @escaping () -> Trailing, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._open = open
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Ink.hairline).frame(height: 1)
            Button {
                withAnimation(.snappy(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Ink.faint)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.text)
                    trailing()
                }
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hover(0))
            if open {
                content()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension InspectorSection where Trailing == EmptyView {
    init(title: String, open: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, open: open, trailing: { EmptyView() }, content: content)
    }
}

/// Маршрут цепочкой: точки на линии сверху вниз, последняя залита. Прямое подключение рисуется пунктиром.
struct RouteChain: View {
    struct Node: Hashable {
        var title: String
        var detail: String
        var color: Color = Ink.text
        var mono = false
    }
    let nodes: [Node]
    var direct = false

    var body: some View {
        let accent = direct ? Ink.direct : Ink.tealDot
        VStack(alignment: .leading, spacing: 0) {
            ForEach(nodes.indices, id: \.self) { i in
                let last = i == nodes.count - 1
                HStack(alignment: .top, spacing: 8) {
                    ZStack(alignment: .top) {
                        if !last {
                            VLine()
                                .stroke(accent.opacity(direct ? 1 : 0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: direct ? [3, 3] : []))
                                .frame(width: 2)
                                .padding(.top, 12)
                        }
                        Circle()
                            .strokeBorder(accent, lineWidth: 2)
                            .background(Circle().fill(last ? accent : Ink.card))
                            .frame(width: 10, height: 10)
                            .padding(.top, 2)
                    }
                    .frame(width: 14)
                    .frame(maxHeight: .infinity, alignment: .top)
                    (Text(nodes[i].title).fontWeight(.medium).foregroundColor(nodes[i].color)
                     + Text(nodes[i].detail.isEmpty ? "" : "  " + nodes[i].detail)
                        .font(nodes[i].mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
                        .foregroundColor(Ink.faint))
                        .textSelection(.enabled)
                        .padding(.bottom, last ? 0 : 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ink.card))
    }
}

/// Вертикальная линия по центру рамки.
struct VLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}

/// Плитка действия: значок и название, под ними что действие делает. Клик по плитке запускает действие,
/// переключатель внутри (у Restart) работает отдельно.
struct ActionTile: View {
    let icon: String
    let title: String
    let hint: String
    var destructive = false
    var highlighted = false
    var toggle: Binding<Bool>? = nil
    var toggleTitle = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 3) {
            // плитки в два столбца узкие: русское название переносится на вторую строку, а одно длинное слово
            // чуть сжимается, но не обрезается
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 14)
                Text(title).font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(destructive ? Ink.red : Ink.text)
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let toggle {
                Toggle(isOn: toggle) {
                    Text(toggleTitle).font(.system(size: 11)).foregroundStyle(Ink.muted)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(hover ? (destructive ? Ink.redChip : Ink.hover) : Ink.card))
        .overlay(shape.strokeBorder(highlighted ? Color.accentColor : hover ? (destructive ? Ink.redBorder : Ink.buttonBorder) : .clear))
        .contentShape(shape)
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .pointerStyle(.link)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
    }
}

// MARK: - Новая сессия

struct NewSessionSheet: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @EnvironmentObject var ui: UIState
    @Environment(\.dismiss) private var dismiss
    let initialProject: String?

    enum StartMode: Hashable { case new, resume, parallel }

    @State private var projectPath = ""
    @State private var agent: LaunchSpec.Agent = .claude
    /// Вместо агента вкладка терминала: проект и маршрут те же, остальное не нужно.
    @State private var terminal = false
    @State private var direct = false
    @State private var subscription: String?
    @State private var mode: StartMode = .new
    @State private var fork = false
    @State private var remoteControl = true
    @State private var prompt = ""
    @State private var busy = false
    @State private var error: String?

    var l: L { L(backend.state.lang) }

    /// Сессия текущей вкладки, если это Claude в том же проекте: ее можно скопировать во второй Claude.
    private var forkSource: String? {
        guard let tab = workspace.current, tab.spec.utility == nil, tab.spec.agent == .claude,
              tab.spec.projectPath == projectPath else { return nil }
        return tab.sessionId
    }

    private var project: AppState.Project? { backend.state.projects.first { $0.path == projectPath } }
    /// Последняя сессия выбранного агента в проекте: ее продолжает "Продолжить последнюю".
    private var lastSession: AppState.Session? { project.flatMap { backend.state.sessions(in: $0, agent: agent).first } }

    var body: some View {
        let project = self.project
        let last = lastSession
        let exit = backend.state.proxy?.exit
        VStack(alignment: .leading, spacing: 18) {
            Text(l.newSession).font(.system(size: 17, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    Text(l.project).foregroundStyle(Ink.muted).frame(width: 104, alignment: .leading)
                    Picker(l.project, selection: $projectPath) {
                        ForEach(backend.state.projects) { p in Text(p.name).tag(p.path) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text(l.agent).foregroundStyle(Ink.muted)
                    SegmentedCapsule(selection: Binding(get: { terminal ? "terminal" : agent.rawValue }, set: { value in
                        terminal = value == "terminal"
                        if let picked = LaunchSpec.Agent(rawValue: value) { agent = picked }
                    }), options: [("claude", "Claude Code", nil), ("codex", "Codex", nil), ("terminal", l.t("Терминал", "Terminal"), nil)])
                }
                GridRow {
                    Text(l.route).foregroundStyle(Ink.muted)
                    SegmentedCapsule(selection: $direct, options: [
                        (false, l.t("Через proxy", "Via proxy") + (exit.map { " " + $0 } ?? ""), Ink.teal),
                        (true, l.directly, Ink.direct),
                    ])
                }
                if !direct, let subs = backend.state.proxy?.choices, !subs.isEmpty {
                    GridRow {
                        Text(l.t("Подписка", "Subscription")).foregroundStyle(Ink.muted)
                        SubscriptionPicker(selection: $subscription, subscriptions: subs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !terminal {
                    GridRow(alignment: .top) {
                        Text(l.start).foregroundStyle(Ink.muted).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 8) {
                            Picker(l.start, selection: $mode) {
                                Text(l.startNew).tag(StartMode.new)
                                Text(l.t("Продолжить последнюю", "Continue the last one")
                                     + (last.map { ", \"" + ($0.title.isEmpty ? l.untitled : $0.title) + "\"" } ?? ""))
                                    .tag(StartMode.resume)
                                    .disabled(last == nil)
                                Text(l.t("Параллельно, своя ветка и worktree", "In parallel, own branch and worktree"))
                                    .tag(StartMode.parallel)
                                    .disabled(agent != .claude)
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                            Toggle(l.t("С копией этого разговора, второй Claude знает все, что уже обсудили",
                                       "With a copy of this conversation, so the second Claude knows everything said so far"),
                                   isOn: $fork)
                                .font(.system(size: 12))
                                .foregroundStyle(Ink.muted)
                                .padding(.leading, 26)
                                .disabled(mode != .parallel || forkSource == nil)
                                .help(forkSource == nil ? l.t("Нужна открытая вкладка Claude в этом проекте", "Needs an open Claude tab in this project") : "")
                        }
                    }
                }
            }
            if !terminal {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(mode == .parallel ? l.t("Задача", "Task") : l.firstPrompt).foregroundStyle(Ink.muted)
                        Spacer(minLength: 8)
                        TranslateFieldButton(text: $prompt)
                    }
                    TextEditor(text: $prompt)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(height: 84)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Ink.card))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.buttonBorder))
                        .overlay(alignment: .topLeading) {
                            if prompt.isEmpty {
                                Text(l.t("Что сделать в этой сессии", "What this session should do"))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Ink.faint)
                                    .padding(.horizontal, 15)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .disabled(mode == .resume)
                }
                if agent == .claude {
                    Toggle(l.t("Remote Control, чтобы продолжить с телефона", "Remote Control, to continue from your phone"), isOn: $remoteControl)
                        .foregroundStyle(Ink.text2)
                }
            }
            if direct {
                Text(l.directWarning)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.amber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Ink.amberDot.opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.amberDot.opacity(0.35)))
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Ink.red)
            }
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: l.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                PillButton(title: l.t("Открыть вкладку  ⌘↩", "Open tab  ⌘↩"), prominent: true, busy: busy) {
                    open(project: project, last: last)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(project == nil || busy || (!terminal && ((mode == .resume && last == nil)
                          || (mode == .parallel && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))))
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            // путь вкладки может быть worktree или подпапкой: берем проект, в котором он лежит
            let projects = backend.state.projects
            projectPath = initialProject.flatMap { p in backend.state.project(containing: p)?.path }
                ?? (projects.first { !$0.isHome } ?? projects.first)?.path ?? ""
            if AgentPrefs.defaultAgent == "codex" { agent = .codex }
            direct = backend.state.proxy?.defaultRoute == "direct"
            subscription = backend.state.defaultSubscription
        }
        .onChange(of: agent) {
            if agent == .codex && mode == .parallel { mode = .new }
            resetResumeIfNothingToContinue()
        }
        .onChange(of: projectPath) { resetResumeIfNothingToContinue() }
    }

    /// У этого агента в этом проекте продолжать нечего: выбор возвращается к новой сессии.
    private func resetResumeIfNothingToContinue() {
        if mode == .resume && lastSession == nil { mode = .new }
    }

    private func open(project: AppState.Project?, last: AppState.Session?) {
        guard let project else { return }
        if terminal {
            workspace.openTerminal(name: project.name, path: project.path, direct: direct, state: backend.state,
                                   subscription: subscription)
            dismiss()
            return
        }
        var spec = LaunchSpec(projectName: project.name, projectPath: project.path, agent: agent, direct: direct,
                              subscription: direct ? nil : subscription)
        spec.remoteControl = remoteControl && agent == .claude
        switch mode {
        case .new:
            spec.firstPrompt = prompt
        case .resume:
            if let last {
                // в папке самой сессии: она могла начаться в подпапке проекта
                spec.projectPath = LaunchSpec.resume(last, project: project).projectPath
                spec.resumeId = last.id
            }
        case .parallel:
            // ветку и worktree делает agentmeister parallel --prepare, а вкладку с задачей открываем сами
            busy = true
            error = nil
            let forkSid = fork ? forkSource : nil
            Task {
                error = await workspace.openParallel(spec, project: project, task: prompt, forkSid: forkSid, state: backend.state, l: l)
                busy = false
                if error == nil { dismiss() }
            }
            return
        }
        workspace.open(spec)
        dismiss()
    }
}

/// Лист параллельной задачи: только Claude Code, своя ветка и worktree, вкладка встает подзадачей агента
/// этого проекта. Агента здесь не выбрать: Codex подзадачей не бывает, а терминалу worktree не нужен.
struct ParallelSheet: View {
    @EnvironmentObject var backend: Backend
    @EnvironmentObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    let initialProject: String?

    @State private var projectPath = ""
    @State private var direct = false
    @State private var subscription: String?
    @State private var fork = false
    @State private var task = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var taskFocused: Bool

    var l: L { L(backend.state.lang) }

    private var project: AppState.Project? { backend.state.projects.first { $0.path == projectPath } }

    /// Сессия текущей вкладки, если это Claude в этом проекте: задача может начать с копией ее разговора.
    private var forkSource: String? {
        guard let tab = workspace.current.map({ workspace.root(of: $0) }), tab.spec.utility == nil, tab.spec.agent == .claude,
              backend.state.project(containing: tab.spec.projectPath)?.path == projectPath else { return nil }
        return tab.sessionId
    }

    var body: some View {
        let exit = backend.state.proxy?.exit
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l.t("Параллельная задача", "Parallel task")).font(.system(size: 17, weight: .semibold))
                Text(l.t("Claude Code в своей ветке и worktree. Вкладка встанет подзадачей агента этого проекта.",
                         "Claude Code in its own branch and worktree. The tab joins this project's agent as a subtask."))
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.muted)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    Text(l.project).foregroundStyle(Ink.muted).frame(width: 104, alignment: .leading)
                    Picker(l.project, selection: $projectPath) {
                        ForEach(backend.state.projects.filter { !$0.isHome }) { p in Text(p.name).tag(p.path) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text(l.route).foregroundStyle(Ink.muted)
                    SegmentedCapsule(selection: $direct, options: [
                        (false, l.t("Через proxy", "Via proxy") + (exit.map { " " + $0 } ?? ""), Ink.teal),
                        (true, l.directly, Ink.direct),
                    ])
                }
                if !direct, let subs = backend.state.proxy?.choices, !subs.isEmpty {
                    GridRow {
                        Text(l.t("Подписка", "Subscription")).foregroundStyle(Ink.muted)
                        SubscriptionPicker(selection: $subscription, subscriptions: subs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(l.t("Задача", "Task")).foregroundStyle(Ink.muted)
                    Spacer(minLength: 8)
                    TranslateFieldButton(text: $task)
                }
                TextEditor(text: $task)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .focused($taskFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(height: 96)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Ink.card))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.buttonBorder))
                    .overlay(alignment: .topLeading) {
                        if task.isEmpty {
                            Text(l.t("Что сделать в своей ветке", "What to do in its own branch"))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Ink.faint)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                Toggle(l.t("С копией этого разговора, второй Claude знает все, что уже обсудили",
                           "With a copy of this conversation, so the second Claude knows everything said so far"),
                       isOn: $fork)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.muted)
                    .disabled(forkSource == nil)
                    .help(forkSource == nil ? l.t("Нужна открытая вкладка Claude в этом проекте", "Needs an open Claude tab in this project") : "")
            }
            if direct {
                Text(l.directWarning)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.amber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Ink.amberDot.opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.amberDot.opacity(0.35)))
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Ink.red)
            }
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: l.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                PillButton(title: l.t("Начать  ⌘↩", "Start  ⌘↩"), prominent: true, busy: busy) { start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(project == nil || busy || trimmed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            let projects = backend.state.projects.filter { !$0.isHome }
            projectPath = initialProject.flatMap { p in backend.state.project(containing: p) }.flatMap { $0.isHome ? nil : $0.path }
                ?? projects.first?.path ?? ""
            direct = backend.state.proxy?.defaultRoute == "direct"
            subscription = backend.state.defaultSubscription
            taskFocused = true
        }
        .onChange(of: projectPath) { if forkSource == nil { fork = false } }
    }

    private func start() {
        guard let project else { return }
        var spec = LaunchSpec(projectName: project.name, projectPath: project.path, agent: .claude, direct: direct,
                              subscription: direct ? nil : subscription)
        spec.remoteControl = true
        busy = true
        error = nil
        let forkSid = fork ? forkSource : nil
        Task {
            error = await workspace.openParallel(spec, project: project, task: task, forkSid: forkSid, state: backend.state, l: l)
            busy = false
            if error == nil { dismiss() }
        }
    }
}

/// Ответ agentmeister parallel --prepare.
struct ParallelJob: Decodable {
    let path: String?
    let branch: String?
    let prompt: String?
    let flags: [String]?
    let error: String?
}

extension Workspace {
    /// Параллельная задача: ветку и worktree делает agentmeister parallel --prepare, вкладку с задачей открываем
    /// сами. Задача из вкладки этого же проекта встает подзадачей ее агента. Возвращает текст ошибки.
    func openParallel(_ spec: LaunchSpec, project: AppState.Project, task: String, forkSid: String? = nil,
                      state: AppState, l: L) async -> String? {
        var args = ["parallel", task, "-p", project.path, "--prepare"]
        if let forkSid { args += ["--fork-sid", forkSid] }
        let job: ParallelJob? = await Backend.json(args)
        guard let job, job.error == nil, let path = job.path else {
            return job?.error ?? l.t("Не получилось сделать worktree", "Couldn't create the worktree")
        }
        var parallel = spec
        parallel.projectName = project.name + " · " + (job.branch ?? "")
        parallel.projectPath = path
        parallel.firstPrompt = job.prompt ?? task
        parallel.extraFlags = job.flags ?? []
        if let current, current.spec.utility == nil, state.project(containing: current.spec.projectPath)?.path == project.path {
            parallel.parent = root(of: current).id
        }
        open(parallel)
        return nil
    }
}

/// Сегментный переключатель-капсула из макета: дорожка и светлый ползунок у выбранного.
/// Обычный делит доступную ширину поровну, compact берет ширину по подписям (контрол у правого края ряда).
struct SegmentedCapsule<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String, Color?)]
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .fontWeight(.medium)
                        .foregroundStyle(on ? (option.2 ?? Ink.strong) : Ink.muted)
                        .lineLimit(compact ? 1 : nil)
                        .padding(.horizontal, compact ? 14 : 0)
                        .frame(maxWidth: compact ? nil : .infinity)
                        .frame(height: 30)
                        .background(Capsule().fill(on ? Ink.thumb : .clear).shadow(color: .black.opacity(on ? 0.2 : 0), radius: 3, y: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.hoverCapsule())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Ink.chip))
    }
}


/// Через какую подписку proxy идет новая сессия: по очереди по всем (просто -x) или только одна (-x <имя>).
/// Показывается, только когда подписок больше одной.
struct SubscriptionPicker: View {
    @EnvironmentObject var backend: Backend
    @Binding var selection: String?
    let subscriptions: [AppState.Proxy.Subscription]

    var body: some View {
        let l = L(backend.state.lang)
        let cascade = subscriptions.filter { $0.inCascade != false }.map(\.name)
        Picker(l.t("Подписка", "Subscription"), selection: $selection) {
            Text(l.t("По очереди: ", "In order: ") + cascade.joined(separator: ", ")).tag(String?.none)
            Divider()
            ForEach(subscriptions, id: \.name) { s in
                Text(l.t("Только ", "Only ") + s.name + ((s.exit ?? s.country).map { " " + $0 } ?? "")).tag(Optional(s.name))
            }
        }
        .labelsHidden()
        .fixedSize()
        .help(l.t("По очереди: следующая подписка, когда в прошлой нет живых серверов. Только одна: без перехода на другие.",
                  "In order: the next subscription when the previous has no live servers. Only one: no switching."))
    }
}


/// Перестановка перетаскиванием: тащимый элемент встает на место того, над которым оказался, сразу, без
/// ожидания отпускания. Тащимый id живет в общем состоянии ряда, потому что onDrag его иначе не отдает.
struct ReorderDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != target else { return }
        withAnimation(.snappy(duration: 0.2)) { move(from, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
