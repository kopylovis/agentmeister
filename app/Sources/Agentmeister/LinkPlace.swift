import AppKit
import SwiftUI

/// Где открыть ссылку, по которой кликнули во вкладке через proxy. ask показывает диалог LinkPlaceSheet.
enum LinkPlace: String, CaseIterable {
    case ask, builtin, chrome, system
}

/// Chrome с отдельным профилем в ~/.cache/mnrh/app. С proxyPort он идет через mihomo (--proxy-server), без него
/// напрямую. Флаги Chrome берет только при первом запуске профиля, поэтому у маршрутов профили разные.
/// 127.0.0.1 Chrome и с proxy открывает напрямую, туда агент принимает ответ входа.
@MainActor
enum ChromeProfile {
    static var app: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") }

    /// Без Chrome ссылка уходит браузеру системы.
    static func open(_ link: URL, profile: String, proxyPort: Int?) {
        guard let app else {
            NSWorkspace.shared.open(link)
            return
        }
        var args = ["--user-data-dir=" + NSHomeDirectory() + "/.cache/mnrh/app/" + profile,
                    "--no-first-run", "--no-default-browser-check"]
        if let proxyPort { args.append("--proxy-server=http://127.0.0.1:\(proxyPort)") }
        args.append(link.absoluteString)
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = args
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, _ in }
    }
}

@MainActor
enum LinkOpener {
    /// Открыть ссылку из вкладки через proxy там, где выбрано. ask спрашивает в листе поверх окна вкладки.
    static func open(_ url: URL, place: LinkPlace, window: NSWindow?) {
        switch place {
        // лист открывается после клика, а не внутри mouseUp терминала: модальный лист посреди обработки события
        // ронял AppKit на пересчете constraints
        case .ask: DispatchQueue.main.async { ask(url, window: window) }
        case .builtin: ProxyBrowser.shared.open(url)
        // свой профиль, не профиль входа: куки сайтов из ссылок живут отдельно от чистого входа в агента
        case .chrome: ChromeProfile.open(url, profile: "chrome-links-proxy", proxyPort: ProxyBrowser.shared.port)
        case .system: NSWorkspace.shared.open(url)
        }
    }

    /// Открытые вопросы. Лист держит окно-родитель, отдельное окно держим сами, пока его не закрыли.
    private static var asking: [NSPanel] = []

    private static func ask(_ url: URL, window: NSWindow?) {
        // без fullSizeContentView: у листа safe area менялась на ходу, и AppKit падал на бесконечном пересчете
        // constraints
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        let close = { [weak panel] in
            guard let panel else { return }
            if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() }
            asking.removeAll { $0 === panel }
        }
        let host = NSHostingView(rootView: LinkPlaceSheet(url: url, l: L(ProxyBrowser.shared.lang)) { place, remember in
            close()
            guard let place else { return }
            if remember { UserDefaults.standard.set(place.rawValue, forKey: BrowserSettings.linkPlaceKey) }
            open(url, place: place, window: nil)
        })
        // размер считается один раз: лист, который сам меняет размер окна во время layout, роняет приложение
        let size = host.fittingSize
        host.sizingOptions = []
        panel.setContentSize(NSSize(width: 480, height: max(size.height, 240)))
        panel.contentView = host
        asking.append(panel)
        // на окне уже висит лист (переименование, вход): тогда отдельным окном по центру
        if let window, window.attachedSheet == nil {
            window.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }
}

/// Лист "Где открыть ссылку": те же места, что в диалоге входа, и "Запомнить выбор". Запомненное место меняется
/// в Настройки, раздел Proxy, там же можно вернуть вопрос.
struct LinkPlaceSheet: View {
    let url: URL
    let l: L
    /// nil значит отмену. Второй аргумент говорит, запомнить ли место.
    let done: (LinkPlace?, Bool) -> Void
    @State private var place: LinkPlace = .builtin
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(l.t("Где открыть ссылку", "Where to open the link")).font(.system(size: 17, weight: .semibold))
                Text(url.absoluteString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Ink.label)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            VStack(spacing: 6) {
                row(.builtin, l.t("Окно Agentmeister", "Agentmeister window"),
                    l.t("через тот же proxy, что и агенты", "through the same proxy as the agents"))
                row(.chrome, l.t("Отдельный профиль Chrome", "Separate Chrome profile"),
                    ChromeProfile.app == nil ? l.t("Chrome не найден", "Chrome isn't installed")
                        : l.t("Chrome с proxy и своим профилем", "Chrome with the proxy and its own profile"))
                    .disabled(ChromeProfile.app == nil)
                row(.system, l.t("Браузер по умолчанию", "Default browser"),
                    l.t("по сети системы, мимо proxy", "over the system network, bypassing the proxy"))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(l.t("Где открыть ссылку", "Where to open the link"))
            VStack(alignment: .leading, spacing: 4) {
                Toggle(l.t("Запомнить выбор", "Remember my choice"), isOn: $remember)
                    .toggleStyle(.checkbox)
                Text(l.t("Поменять можно в настройках, раздел Proxy", "You can change it in Settings > Proxy"))
                    .font(.system(size: 12)).foregroundStyle(Ink.muted)
            }
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: l.t("Отмена", "Cancel")) { done(nil, false) }
                    .keyboardShortcut(.cancelAction)
                PillButton(title: l.t("Открыть", "Open"), prominent: true) { done(place, remember) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .foregroundStyle(Ink.text)
    }

    private func row(_ value: LinkPlace, _ title: String, _ desc: String) -> some View {
        OptionRow(on: place == value, title: title, desc: desc, compact: true) { place = value }
    }
}
