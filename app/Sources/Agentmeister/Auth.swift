import AppKit
import SwiftUI
import WebKit

extension LaunchSpec.Agent: Identifiable {
    var id: String { rawValue }
}

/// Ход входа в агента для диалога AuthDialog. Сам вход делает CLI агента (claude auth login, codex login) в
/// терминале, которого не видно, пока все идет как надо. По умолчанию через agentmeister proxy run, напрямую
/// только если это выбрано в диалоге. Страницу входа агент открывает через BROWSER, диалог забирает ее у
/// ProxyBrowser и открывает там, где выбрано. Токены и файлы входа диалог не читает: прошел ли вход, он узнает
/// из app-state settings, как настройки и мастер.
@MainActor
final class AuthFlow: ObservableObject {
    enum Phase { case choose, web, wait, done }
    enum Method { case account, key }
    enum Route { case proxy, direct }
    enum Place { case embedded, chrome, system }
    enum Problem: Equatable {
        case exited(Int32)
        case notYet
        case stillRunning
        case key(Int32, String)
    }

    let agent: LaunchSpec.Agent
    /// Метка перехвата страниц этого входа в ProxyBrowser: снимается только свой перехват.
    private let hookId = UUID()
    weak var backend: Backend?

    @Published var phase: Phase = .choose
    @Published var method: Method = .account
    @Published var route: Route = .proxy
    @Published var place: Place = .embedded
    /// Ключ API для Codex. Никуда не пишется и не выводится, кроме stdin codex login --with-api-key.
    @Published var key = ""
    @Published var url: URL?
    @Published var login: TerminalTab?
    @Published var browser: BrowserModel?
    @Published var problem: Problem?
    @Published var busy = false
    /// Терминал входа виден, если агент не открыл страницу или вход не прошел.
    @Published var showOutput = false
    /// Аккаунт до входа и после: "Сменить аккаунт" проходит, только когда вход сменился или команда вышла с 0.
    @Published var info: SettingsData.Agent?
    private var before: SettingsData.Agent?
    private var finished = false
    private var startedAt = Date()
    private var watchdog: Timer?

    init(agent: LaunchSpec.Agent) {
        self.agent = agent
    }

    func load() async {
        let data = await backend?.settings()
        before = agent == .claude ? data?.claude : data?.codex
        info = before
    }

    /// Команда входа. Ключ Anthropic Console Claude Code получает только своим входом в Console, вставленный
    /// ключ он не принимает.
    private var command: [String] {
        if agent == .claude { return ["claude", "auth", "login"] + (method == .key ? ["--console"] : []) }
        return ["codex", "login"]
    }

    func begin() {
        stop()
        problem = nil
        url = nil
        finished = false
        showOutput = false
        startedAt = Date()
        let proxied = route == .proxy
        if place == .embedded {
            browser = BrowserModel(store: .nonPersistent(), port: ProxyBrowser.shared.port, proxied: proxied)
        }
        // перехват ставится до запуска: страница может прийти сразу
        ProxyBrowser.shared.setIntercept(owner: hookId) { [weak self] url in self?.take(url) ?? false }
        var spec = LaunchSpec(projectName: "agentmeister", projectPath: NSHomeDirectory())
        spec.utility = proxied ? ["proxy", "run", "--claude", "--"] + command : command
        spec.bare = !proxied
        spec.signInDialog = true
        let tab = TerminalTab(spec: spec)
        tab.exitHint = false
        tab.onExit = { [weak self, weak tab] in
            guard let self, let tab, tab === self.login else { return }
            self.exited(tab.exitCode)
        }
        login = tab
        phase = place == .embedded ? .web : .wait
        // агент не открыл страницу за 8 секунд: показать его вывод, ссылку из него можно открыть кликом
        watchdog = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.url == nil, self.login?.running == true else { return }
                self.showOutput = true
            }
        }
    }

    private func exited(_ code: Int32?) {
        if code == 0 {
            finished = true
            Task { await check() }
        } else {
            problem = .exited(code ?? -1)
            showOutput = true
        }
    }

    /// Страница входа от BROWSER или клик по ссылке в терминале входа. Берем только страницы входа агентов
    /// и только пока идет вход: остальное, например OAuth для MCP из других вкладок, идет как обычно.
    private func take(_ link: URL) -> Bool {
        guard login?.running == true, phase == .web || phase == .wait, Self.isSignIn(link) else { return false }
        url = link
        open(link)
        return true
    }

    private func open(_ link: URL) {
        switch place {
        case .embedded: browser?.load(link)
        case .chrome: openChrome(link)
        case .system: NSWorkspace.shared.open(link)
        }
    }

    nonisolated static func isSignIn(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https", let host = url.host()?.lowercased() else { return false }
        return ["claude.ai", "claude.com", "anthropic.com", "openai.com", "chatgpt.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Chrome с отдельным чистым профилем. Профили у маршрутов разные: Chrome берет флаги только при первом
    /// запуске профиля.
    private func openChrome(_ link: URL) {
        let proxied = route == .proxy
        ChromeProfile.open(link, profile: "chrome-signin-" + (proxied ? "proxy" : "direct"),
                           proxyPort: proxied ? ProxyBrowser.shared.port : nil)
    }

    /// Из встроенного окна в Chrome через proxy: вход продолжается, страница открывается заново.
    func moveToChrome() {
        place = .chrome
        phase = .wait
        if let url { openChrome(url) }
    }

    /// Прошел ли вход, по app-state settings. При смене аккаунта вход уже был, поэтому нужен новый аккаунт
    /// или успешный выход команды входа.
    func check() async {
        busy = true
        let data = await backend?.settings()
        busy = false
        let now = agent == .claude ? data?.claude : data?.codex
        info = now
        let changed = before?.signedIn != true || now?.email != before?.email || now?.plan != before?.plan
        if now?.signedIn == true && (finished || changed) {
            problem = nil
            showOutput = false
            watchdog?.invalidate()
            ProxyBrowser.shared.clearIntercept(owner: hookId)
            phase = .done
            backend?.refresh()
        } else if case .exited = problem {
            // причина уже на экране
        } else {
            problem = login?.running == true ? .stillRunning : .notYet
        }
    }

    /// Ключ OpenAI через codex login --with-api-key: Codex сам кладет его в ~/.codex/auth.json. Ключ идет только
    /// в stdin, он записан в канал до запуска, в аргументы, журнал и вывод не попадает.
    func saveKey() {
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return }
        busy = true
        problem = nil
        let proxied = route == .proxy
        Task {
            let (code, tail) = await Self.codexKey(secret, proxied: proxied)
            key = ""
            busy = false
            if code == 0 {
                finished = true
                await check()
            } else {
                problem = .key(code, tail)
            }
        }
    }

    nonisolated private static func codexKey(_ secret: String, proxied: Bool) async -> (Int32, String) {
        await Task.detached(priority: .userInitiated) {
            let task = Process()
            if proxied {
                task.executableURL = URL(fileURLWithPath: LoginEnvironment.agentmeister)
                task.arguments = ["proxy", "run", "--claude", "--", "codex", "login", "--with-api-key"]
            } else {
                task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                task.arguments = ["codex", "login", "--with-api-key"]
            }
            var env = LoginEnvironment.shared
            for name in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"] { env.removeValue(forKey: name) }
            task.environment = env
            let input = Pipe()
            let output = Pipe()
            // ключ короче буфера канала: пишем и закрываем до запуска, так запись не ждет процесс
            input.fileHandleForWriting.write(Data(secret.utf8))
            try? input.fileHandleForWriting.close()
            task.standardInput = input
            task.standardOutput = output
            task.standardError = output
            guard (try? task.run()) != nil else { return (127, "") }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: secret, with: "…")
            let last = text.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            return (task.terminationStatus, String(last.prefix(160)))
        }.value
    }

    /// Назад к выбору способа: вход, если идет, останавливается.
    func back() {
        stop()
        problem = nil
        phase = .choose
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        ProxyBrowser.shared.clearIntercept(owner: hookId)
        if let login {
            login.onExit = nil
            // после входа команда сама дописывает и выходит, ее не обрываем
            if phase != .done { login.terminate() }
        }
        login = nil
        browser?.webView.stopLoading()
        browser = nil
    }

    func close() {
        stop()
        key = ""
    }
}

/// Диалог входа в агента по макету Auth.dc.html: способ, маршрут и где открыть вход, затем встроенное окно,
/// ожидание браузера или "Вход выполнен". Открывается из мастера, из настроек агентов и из баннера Codex.
struct AuthDialog: View {
    @EnvironmentObject var backend: Backend
    @Environment(\.dismiss) private var dismiss
    @StateObject private var flow: AuthFlow
    @FocusState private var keyFocused: Bool

    init(agent: LaunchSpec.Agent) {
        _flow = StateObject(wrappedValue: AuthFlow(agent: agent))
    }

    var l: L { L(backend.state.lang) }
    private var claude: Bool { flow.agent == .claude }
    private var name: String { claude ? "Claude Code" : "Codex" }
    private var proxied: Bool { flow.route == .proxy }
    private var proxyReady: Bool { backend.state.proxy?.configured == true }
    /// " KZ": страна выхода после слова proxy, как в макете.
    private var exitSuffix: String { backend.state.proxy?.exit.map { " " + $0 } ?? "" }
    private var pastesKey: Bool { !claude && flow.method == .key }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AgentBadge(agent: flow.agent, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(l.t("Вход в " + name, "Sign in to " + name)).font(.system(size: 17, weight: .semibold))
                    Text(l.t("Вход нужен один раз, его увидят все вкладки " + name, "You sign in once, every " + name + " tab uses it"))
                        .font(.system(size: 12)).foregroundStyle(Ink.label)
                }
            }
            switch flow.phase {
            case .choose: choose
            case .web: web
            case .wait: wait
            case .done: done
            }
        }
        .padding(24)
        .frame(width: 540)
        .foregroundStyle(Ink.text)
        .task {
            flow.backend = backend
            await flow.load()
        }
        .onDisappear { flow.close() }
    }

    // MARK: Выбор

    private var choose: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 8) {
                option(.account, claude ? l.t("Подписка Claude", "Claude subscription") : l.t("Аккаунт ChatGPT", "ChatGPT account"),
                       claude ? l.t("Pro или Max, вход через браузер", "Pro or Max, sign in with the browser")
                              : l.t("Plus, Pro или Business, вход через браузер", "Plus, Pro or Business, sign in with the browser"))
                option(.key, claude ? l.t("Ключ API Anthropic Console", "Anthropic Console API key") : l.t("Ключ API OpenAI", "OpenAI API key"),
                       l.t("Оплата по токенам", "Pay per token"))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(l.t("Способ входа", "Sign-in method"))

            if flow.method == .key { keyField }

            HStack(spacing: 12) {
                Text(l.route).foregroundStyle(Ink.label)
                RouteSwitch(proxy: Binding(get: { proxied }, set: { flow.route = $0 ? .proxy : .direct }),
                            proxyTitle: l.t("Через proxy", "Via proxy") + exitSuffix, directTitle: l.directly)
                    .accessibilityLabel(l.route)
            }
            if proxied && !proxyReady {
                Text(l.t("Proxy не настроен. Настрой его в настройках, раздел Proxy, или выбери вход напрямую.",
                         "The proxy isn't set up. Set it up in Settings > Proxy, or pick Direct."))
                    .font(.system(size: 12)).foregroundStyle(Ink.warn)
            }

            if !pastesKey { whereOptions }

            if let problem = flow.problem { problemText(problem) }

            HStack(spacing: 8) {
                LinkButton(title: claude ? l.t("Bedrock, Vertex AI и другие", "Bedrock, Vertex AI and others") : l.t("Другие способы", "Other options"),
                           compact: true) {
                    let docs = claude ? "https://code.claude.com/docs/en/third-party-integrations" : "https://developers.openai.com/codex/auth"
                    if let url = URL(string: docs) { NSWorkspace.shared.open(url) }
                }
                Spacer()
                PillButton(title: l.t("Отмена", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                PillButton(title: pastesKey ? l.t("Сохранить ключ", "Save key") : l.t("Открыть браузер", "Open browser"),
                           prominent: true, busy: flow.busy) {
                    if pastesKey { flow.saveKey() } else { flow.begin() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
            }
        }
    }

    private var canStart: Bool {
        if flow.busy || (proxied && !proxyReady) { return false }
        if pastesKey { return flow.key.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sk-") }
        return true
    }

    private func option(_ method: AuthFlow.Method, _ title: String, _ desc: String) -> some View {
        OptionRow(on: flow.method == method, title: title, desc: desc) {
            flow.method = method
            flow.problem = nil
        }
    }

    /// Поле ключа. У Claude Code оно выключено: вставленный ключ он не принимает, ключ Console он создает сам
    /// после входа в Console в браузере.
    private var keyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l.t("Ключ API", "API key")).foregroundStyle(Ink.label)
            SecureField(claude ? "sk-ant-…" : "sk-…", text: $flow.key)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($keyFocused)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule().fill(Ink.field))
                .overlay(Capsule().strokeBorder(Ink.fieldBorder))
                .disabled(claude)
                .opacity(claude ? 0.5 : 1)
                .accessibilityLabel(l.t("Ключ API", "API key"))
            Text(claude ? l.t("Claude Code не принимает вставленный ключ. Открой вход в Anthropic Console: Claude Code сам создаст ключ и положит его в связку ключей macOS.",
                              "Claude Code doesn't take a pasted key. Sign in to Anthropic Console instead: Claude Code creates the key and keeps it in the macOS keychain.")
                        : l.t("Ключ ляжет в ~/.codex/auth.json", "The key goes into ~/.codex/auth.json"))
                .font(.system(size: 12)).foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if !claude { keyFocused = true } }
    }

    private var whereOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l.t("Где открыть вход", "Where to sign in")).foregroundStyle(Ink.label)
            VStack(spacing: 6) {
                place(.embedded, l.t("Окно Agentmeister", "Agentmeister window"),
                      proxied ? l.t("страница идет через тот же proxy, что и агенты", "the page goes through the same proxy as the agents")
                              : l.t("страница идет напрямую", "the page goes direct"))
                place(.chrome, l.t("Отдельный профиль Chrome", "Separate Chrome profile"),
                      ChromeProfile.app == nil ? l.t("Chrome не найден", "Chrome isn't installed")
                          : proxied ? l.t("Chrome с proxy и чистым профилем", "Chrome with the proxy and a clean profile")
                          : l.t("Chrome с чистым профилем", "Chrome with a clean profile"))
                    .disabled(ChromeProfile.app == nil)
                place(.system, l.t("Браузер по умолчанию", "Default browser"),
                      l.t("по сети системы, мимо proxy", "over the system network, bypassing the proxy"))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(l.t("Где открыть вход", "Where to sign in"))
        }
    }

    private func place(_ value: AuthFlow.Place, _ title: String, _ desc: String) -> some View {
        OptionRow(on: flow.place == value, title: title, desc: desc, compact: true) { flow.place = value }
    }

    // MARK: Встроенное окно

    private var web: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let browser = flow.browser {
                AuthWebPanel(model: browser, loaded: flow.url != nil, l: l,
                             chip: proxied ? "proxy" + exitSuffix : l.direct, proxied: proxied,
                             placeholderHost: claude ? "claude.ai/oauth/authorize" : "auth.openai.com/oauth/authorize",
                             placeholder: claude ? l.t("Здесь откроется страница входа claude.ai", "The claude.ai sign-in page opens here")
                                                 : l.t("Здесь откроется страница входа OpenAI", "The OpenAI sign-in page opens here"))
            }
            Text(l.t("Куки этого окна не смешиваются с Safari и Chrome. Адреса 127.0.0.1 открываются мимо proxy, на них агент принимает ответ входа.",
                     "This window keeps its cookies apart from Safari and Chrome. 127.0.0.1 addresses bypass the proxy, that is where the agent receives the sign-in reply."))
                .font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            Text(l.t("Google может не пустить вход через Google во встроенном окне. Тогда открой страницу в Chrome через proxy.",
                     "Google may refuse \"Sign in with Google\" in an embedded window. If it does, open the page in Chrome through the proxy."))
                .font(.system(size: 12)).foregroundStyle(Ink.warn).fixedSize(horizontal: false, vertical: true)
            output
            HStack(spacing: 8) {
                LinkButton(title: proxied ? l.t("Открыть в Chrome через proxy", "Open in Chrome through the proxy") : l.t("Открыть в Chrome", "Open in Chrome")) {
                    flow.moveToChrome()
                }
                .disabled(ChromeProfile.app == nil)
                Spacer()
                PillButton(title: l.t("Отмена", "Cancel")) { flow.back() }
                    .keyboardShortcut(.cancelAction)
                checkButton
            }
        }
    }

    // MARK: Ожидание браузера

    private var wait: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Spinner()
                VStack(alignment: .leading, spacing: 3) {
                    Text(l.t("Открыли страницу входа в браузере", "Sign-in page is open in your browser")).fontWeight(.semibold)
                    Text(claude ? l.t("Подтверди вход на странице Claude, вкладка закроется сама", "Confirm on the Claude page, the tab closes by itself")
                                : l.t("Подтверди вход на странице OpenAI, ответ придет на 127.0.0.1:1455", "Confirm on the OpenAI page, the reply comes back to 127.0.0.1:1455"))
                        .font(.system(size: 12)).foregroundStyle(Ink.muted)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Ink.card))

            VStack(alignment: .leading, spacing: 6) {
                Text(l.t("Браузер не открылся? Скопируй ссылку", "Browser didn't open? Copy the link")).font(.system(size: 12)).foregroundStyle(Ink.label)
                HStack(spacing: 8) {
                    Text(flow.url?.absoluteString ?? "…")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.text2)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    PillButton(title: l.t("Скопировать", "Copy"), small: true) {
                        guard let url = flow.url else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    .disabled(flow.url == nil)
                }
                .padding(.leading, 14)
                .padding([.vertical, .trailing], 8)
                .background(Capsule().fill(Ink.field))
                .overlay(Capsule().strokeBorder(Ink.fieldBorder))
            }

            Text(routeChip)
                .font(.system(size: 12))
                .foregroundStyle(proxied ? Ink.teal : Ink.warn)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(proxied ? Ink.tealChip : Ink.warnChip))

            output
            HStack(spacing: 8) {
                LinkButton(title: l.t("Другой способ", "Another method")) { flow.back() }
                Spacer()
                PillButton(title: l.t("Отмена", "Cancel")) { flow.back() }
                    .keyboardShortcut(.cancelAction)
                checkButton
            }
        }
    }

    private var routeChip: String {
        let proxy = "proxy" + exitSuffix
        if flow.place == .system {
            return proxied ? l.t("Браузер идет по сети системы, токен агент получает через \(proxy)", "The browser uses the system network, the agent gets its token through \(proxy)")
                           : l.t("Вход и токен напрямую, без proxy", "Sign-in and token go direct, no proxy")
        }
        return proxied ? l.t("Chrome и агент идут через \(proxy)", "Chrome and the agent both go through \(proxy)")
                       : l.t("Chrome и агент идут напрямую", "Chrome and the agent both go direct")
    }

    private var checkButton: some View {
        PillButton(title: l.t("Я вошел, проверить", "I signed in, check"), busy: flow.busy) {
            Task { await flow.check() }
        }
        .disabled(flow.busy)
    }

    /// Причина, если вход не прошел, и вывод команды входа, если он нужен.
    @ViewBuilder
    private var output: some View {
        if let problem = flow.problem { problemText(problem) }
        if flow.showOutput, let login = flow.login {
            ConsolePanel(tab: login, l: l) { flow.showOutput = false }
                .frame(height: 150)
        }
    }

    private func problemText(_ problem: AuthFlow.Problem) -> some View {
        let text: String
        switch problem {
        case .exited(let code):
            text = l.t("Команда входа завершилась с кодом \(code). Ее вывод ниже.", "The sign-in command exited with code \(code). Its output is below.")
        case .notYet:
            text = l.t("Вход еще не выполнен.", "You're not signed in yet.")
        case .stillRunning:
            text = l.t("Вход еще идет: подтверди его на странице входа.", "Sign-in is still running: confirm it on the sign-in page.")
        case .key(let code, let tail):
            text = l.t("Codex не сохранил ключ, код \(code)", "Codex didn't save the key, exit code \(code)") + (tail.isEmpty ? "" : ": " + tail)
        }
        return Text(text).font(.system(size: 12)).foregroundStyle(Ink.warn).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Готово

    private var done: some View {
        let info = flow.info
        let account: String = {
            var parts: [String] = []
            if let email = info?.email { parts.append(email) }
            if let plan = info?.plan { parts.append(claude ? l.t("подписка " + plan, plan + " plan") : plan) }
            return parts.isEmpty ? name : parts.joined(separator: " · ")
        }()
        let codexHome = tilde(LoginEnvironment.shared["CODEX_HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex"))
        let proxy = backend.state.proxy
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Ink.tealBadge))
                VStack(alignment: .leading, spacing: 3) {
                    Text(l.t("Вход выполнен", "Signed in")).fontWeight(.semibold).foregroundStyle(Ink.teal)
                    Text(account).font(.system(size: 12)).foregroundStyle(Ink.text2).textSelection(.enabled)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Ink.tealGlass))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.tealGlassBorder))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(l.t("Где хранится", "Stored in")).foregroundStyle(Ink.faint).frame(width: 110, alignment: .leading)
                    Text(claude ? l.t("связка ключей macOS", "macOS keychain") : codexHome + "/auth.json")
                        .font(.system(size: 12, design: .monospaced))
                }
                GridRow {
                    Text(l.route).foregroundStyle(Ink.faint).frame(width: 110, alignment: .leading)
                    Text(proxied ? (["proxy" + exitSuffix, proxy?.protocol].compactMap { $0 }.joined(separator: ", ")) : l.direct)
                }
                GridRow {
                    Text(l.t("Лимиты", "Limits")).foregroundStyle(Ink.faint).frame(width: 110, alignment: .leading)
                    Text(l.t("promptsill покажет их в строке статуса", "promptsill shows them in the status line"))
                }
            }
            .font(.system(size: 12))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Ink.card))

            HStack(spacing: 8) {
                LinkButton(title: l.t("Другой аккаунт", "Use another account")) { flow.back() }
                Spacer()
                PillButton(title: l.t("Готово", "Done"), prominent: true) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Встроенное окно входа: назад, обновить, адрес с замком и плашкой маршрута, под ними страница. До прихода
/// страницы на ее месте пунктирная заглушка.
private struct AuthWebPanel: View {
    @ObservedObject var model: BrowserModel
    let loaded: Bool
    let l: L
    let chip: String
    let proxied: Bool
    let placeholderHost: String
    let placeholder: String

    private var host: String {
        let address = model.address.isEmpty ? placeholderHost : model.address
        return address.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                toolButton("chevron.left", l.t("Назад", "Back")) { model.webView.goBack() }
                    .disabled(!model.canBack)
                toolButton("arrow.clockwise", l.t("Обновить", "Reload")) { model.reload() }
                    .disabled(!loaded)
                HStack(spacing: 8) {
                    Image(systemName: "lock").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.muted)
                    Text(host)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.text2)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    HStack(spacing: 5) {
                        Image(systemName: "shield").font(.system(size: 9, weight: .semibold))
                        Text(chip)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(proxied ? Ink.teal : Ink.warn)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(proxied ? Ink.tealChip : Ink.warnChip))
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Ink.thumb).shadow(color: .black.opacity(0.2), radius: 4, y: 2))
            }
            .padding(8)
            ZStack {
                if loaded {
                    WebViewHost(webView: model.webView)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    if !model.proxyUp || model.error != nil {
                        message(!model.proxyUp ? l.t("mihomo не запущен, страница не грузится.", "mihomo isn't running, the page doesn't load.")
                                               : model.error ?? "")
                    }
                } else {
                    message(placeholder)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.ringTrack, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
            .frame(height: 232)
            .padding([.horizontal, .bottom], 8)
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(Ink.field))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Ink.fieldBorder))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(Ink.muted)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(loaded ? AnyShapeStyle(.background) : AnyShapeStyle(.clear)))
    }

    private func toolButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.muted)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.hoverCircle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Вариант с кружком выбора из макета: название и пояснение, выбранный светлее и с синей рамкой. compact для
/// "Где открыть вход" и диалога ссылки: меньше, пояснение в той же строке.
struct OptionRow: View {
    let on: Bool
    let title: String
    let desc: String
    var compact = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 10 : 12) {
                RadioDot(on: on, size: compact ? 16 : 18)
                if compact {
                    Text(title).fontWeight(.medium)
                    Text(desc).font(.system(size: 12)).foregroundStyle(Ink.muted).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).fontWeight(.semibold)
                        Text(desc).font(.system(size: 12)).foregroundStyle(Ink.muted)
                    }
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(Ink.text)
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 8 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: compact ? 14 : 16).fill(on ? Ink.optionOnBg : Ink.optionOffBg)
                .shadow(color: .black.opacity(on ? 0.18 : 0), radius: 4, y: 2))
            .overlay(RoundedRectangle(cornerRadius: compact ? 14 : 16).strokeBorder(on ? Ink.optionOnBorder : Ink.optionOffBorder))
            .contentShape(RoundedRectangle(cornerRadius: compact ? 14 : 16))
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.hover(compact ? 14 : 16, .overlay))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct RadioDot: View {
    let on: Bool
    let size: CGFloat

    var body: some View {
        Group {
            if on {
                Circle().fill(.white).overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 5))
            } else {
                Circle().strokeBorder(Ink.dotOff, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Маршрут входа: сегмент через proxy бирюзовый, напрямую янтарный, как в макете.
private struct RouteSwitch: View {
    @Binding var proxy: Bool
    let proxyTitle: String
    let directTitle: String

    var body: some View {
        HStack(spacing: 2) {
            segment(proxyTitle, on: proxy, bg: Ink.tealSegBg, fg: Ink.tealSeg) { proxy = true }
            segment(directTitle, on: !proxy, bg: Ink.directSegBg, fg: Ink.directSeg) { proxy = false }
        }
        .padding(3)
        .background(Capsule().fill(Ink.segTrack))
        .accessibilityElement(children: .contain)
    }

    private func segment(_ title: String, on: Bool, bg: Color, fg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.medium)
                .foregroundStyle(on ? fg : Ink.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(Capsule().fill(on ? bg : .clear).shadow(color: .black.opacity(on ? 0.2 : 0), radius: 4, y: 2))
                .contentShape(Capsule())
        }
        .buttonStyle(.hoverCapsule())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Текстовая кнопка цвета ссылки слева в подвале диалога.
private struct LinkButton: View {
    let title: String
    var compact = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: compact ? 12 : 13))
                .foregroundStyle(Ink.link)
                .padding(.horizontal, compact ? 0 : 8)
                .frame(height: 34)
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.textLink)
    }
}

/// Кольцо ожидания из макета: дорожка и акцентная четверть, крутится.
private struct Spinner: View {
    @State private var turn = false

    var body: some View {
        ZStack {
            Circle().stroke(Ink.ringTrack, lineWidth: 3)
            Circle().trim(from: 0, to: 0.25).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(turn ? 360 : 0))
        }
        .frame(width: 25, height: 25)
        .padding(1.5)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turn = true }
        }
        .accessibilityHidden(true)
    }
}
