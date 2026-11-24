import AppKit
import Combine
import Network
import SwiftUI
import WebKit

/// Встроенный браузер, который ходит в сеть через тот же mihomo, что и сессии через proxy. В него попадают страницы,
/// которые открывает сам агент (вход, OAuth для MCP): вкладкам через proxy приложение ставит BROWSER на свой
/// помощник, а помощник передает ссылку сюда через agentmeister://browse. Без mihomo браузер ничего не грузит,
/// напрямую страница не пойдет.
@MainActor
final class ProxyBrowser {
    static let shared = ProxyBrowser()

    /// Порт mihomo и язык из app-state. Обновляет Backend при каждом ответе.
    var port = 17890
    var lang = "en"

    private var window: NSWindow?
    private var model: BrowserModel?
    private var titleWatch: AnyCancellable?

    /// Отдельное постоянное хранилище: куки входа живут между запусками и не смешиваются с другими WKWebView.
    private static let storeId = UUID(uuidString: "5E3C1B2A-7D4F-4C61-9B0E-A6E1D2F3C4B5")!

    func open(_ url: URL) {
        if let model, let window {
            model.port = port
            model.load(url)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let store = WKWebsiteDataStore(forIdentifier: Self.storeId)
        let model = BrowserModel(store: store, port: port)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: BrowserView(model: model, l: L(lang)))
        window.setFrameAutosaveName("ProxyBrowser")
        if window.frame.origin == .zero { window.center() }
        self.model = model
        self.window = window
        let fallback = L(lang).t("Браузер через proxy", "Proxy browser")
        window.title = fallback
        // NSHostingView в своем NSWindow не берет navigationTitle, заголовок для меню Window ставим сами
        titleWatch = model.$title.sink { [weak window] title in window?.title = title.isEmpty ? fallback : title }
        model.load(url)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Слушает ли кто-то порт на 127.0.0.1. Для проверки, что mihomo запущен, этого хватает.
    nonisolated static func listening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// Помощник для BROWSER: Claude Code запускает его со ссылкой вместо open. Пишется при каждом запуске,
    /// чтобы путь к нему был всегда свежим.
    static let helper: String? = {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("Agentmeister/bin")
        let file = dir.appendingPathComponent("agentmeister-browse")
        let script = """
        #!/bin/sh
        # Открывает ссылку во встроенном браузере Agentmeister, который ходит в сеть через mihomo.
        # Его ставит BROWSER во вкладках через proxy. Файл пишет приложение при запуске.
        for u in "$@"; do
          enc=$(/usr/bin/python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$u") || exit 1
          /usr/bin/open "agentmeister://browse?url=$enc" || exit 1
        done

        """
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: file, encoding: .utf8)) != script {
                try script.write(to: file, atomically: true, encoding: .utf8)
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file.path
        } catch {
            return nil
        }
    }()
}

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var address = ""
    @Published var title = ""
    @Published var loading = false
    @Published var canBack = false
    @Published var canForward = false
    @Published var error: String?
    @Published var proxyUp = true
    var port: Int {
        didSet { applyProxy() }
    }

    init(store: WKWebsiteDataStore, port: Int) {
        self.port = port
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        applyProxy()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    /// Весь трафик страницы идет через mihomo CONNECT, кроме localhost: туда агент принимает ответ входа.
    /// allowFailover выключен, так что без mihomo страница не откроется напрямую.
    private func applyProxy() {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: p))
        proxy.allowFailover = false
        proxy.excludedDomains = ["localhost", "127.0.0.1", "::1"]
        webView.configuration.websiteDataStore.proxyConfigurations = [proxy]
    }

    func load(_ url: URL) {
        address = url.absoluteString
        error = nil
        proxyUp = ProxyBrowser.listening(port)
        guard proxyUp else { return }
        webView.load(URLRequest(url: url))
    }

    /// Строка адреса: полный адрес, домен или поиск не нужен, достаточно дописать https://.
    func go(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        if let url = URL(string: withScheme) { load(url) }
    }

    func reload() {
        proxyUp = ProxyBrowser.listening(port)
        guard proxyUp else { return }
        if webView.url == nil, let url = URL(string: address) { webView.load(URLRequest(url: url)) } else { webView.reload() }
    }

    private func sync() {
        if let url = webView.url { address = url.absoluteString }
        title = webView.title ?? ""
        loading = webView.isLoading
        canBack = webView.canGoBack
        canForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { error = nil; sync() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { sync() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { sync() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

    private func fail(_ err: Error) {
        sync()
        let ns = err as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        proxyUp = ProxyBrowser.listening(port)
        error = err.localizedDescription
    }

    /// http и https остаются здесь. Остальные схемы (приложения, mailto) отдаются системе, как в обычном браузере.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if ["http", "https", "about", "blob", "data"].contains(scheme) { return .allow }
        NSWorkspace.shared.open(url)
        return .cancel
    }

    /// target=_blank и window.open открываются в этом же окне.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    let l: L
    @State private var editing = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer().frame(width: 64)
                GlassEffectContainer {
                    HStack(spacing: 2) {
                        Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                            .disabled(!model.canBack)
                        Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }
                            .disabled(!model.canForward)
                        Button { model.loading ? model.webView.stopLoading() : model.reload() } label: {
                            Image(systemName: model.loading ? "xmark" : "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                }
                TextField(l.t("Адрес", "Address"), text: $editing)
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .onSubmit { model.go(editing); addressFocused = false }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                Label(model.proxyUp ? l.t("через proxy", "via proxy") : l.t("proxy выключен", "proxy is off"),
                      systemImage: "shield.lefthalf.filled")
                    .font(.callout)
                    .foregroundStyle(model.proxyUp ? Color.teal : Color.orange)
                    .help("127.0.0.1:\(model.port)")
                Button {
                    if let url = model.webView.url ?? URL(string: model.address) { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .help(l.t("Открыть в браузере системы, мимо proxy", "Open in the system browser, bypassing the proxy"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            if model.loading {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            } else {
                Divider()
            }
            ZStack {
                WebViewHost(webView: model.webView)
                if !model.proxyUp {
                    ContentUnavailableView {
                        Label(l.t("mihomo не запущен", "mihomo isn't running"), systemImage: "shield.slash")
                    } description: {
                        Text(l.t("Браузер ходит в сеть только через proxy. mihomo работает, пока открыта хотя бы одна вкладка через proxy. Открой ее и нажми ⌘R.",
                                 "The browser reaches the network only through the proxy. mihomo runs while at least one proxied tab is open. Open one and press ⌘R."))
                    }
                    .background(.background)
                } else if let error = model.error {
                    ContentUnavailableView(l.t("Страница не открылась", "The page didn't load"), systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                        .background(.background)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { editing = model.address }
        .onChange(of: model.address) { if !addressFocused { editing = model.address } }
        .background {
            Button("") { model.reload() }.keyboardShortcut("r", modifiers: .command).hidden()
            Button("") { addressFocused = true }.keyboardShortcut("l", modifiers: .command).hidden()
        }
        .navigationTitle(model.title.isEmpty ? l.t("Браузер через proxy", "Proxy browser") : model.title)
    }
}
