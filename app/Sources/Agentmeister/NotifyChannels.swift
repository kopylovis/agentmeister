import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Каналы уведомлений на телефон по макету notify-channels: общий порог "не за Mac", подключенные каналы
/// карточками и лист "Добавить канал". Каждое действие это agentmeister notify <канал> ..., секреты уходят
/// через stdin (Backend.runWithInput), в аргументах их видно в ps.
enum PhoneChannel: String, CaseIterable, Identifiable {
    case telegram, tossling, ntfy, bark, gotify, webhook, pushover, apprise
    var id: String { rawValue }

    var name: String {
        switch self {
        case .telegram: "Telegram"
        case .tossling: "Tossling"
        case .ntfy: "ntfy"
        case .bark: "Bark"
        case .gotify: "Gotify"
        case .webhook: "Webhook"
        case .pushover: "Pushover"
        case .apprise: "Apprise"
        }
    }

    /// Исходники сервиса: подпись и адрес.
    var source: (String, String) {
        switch self {
        case .telegram: ("Bot API", "https://core.telegram.org/bots/api")
        case .tossling: ("Tossling/tossling-server", "https://github.com/Tossling/tossling-server")
        case .ntfy: ("binwiederhier/ntfy", "https://github.com/binwiederhier/ntfy")
        case .bark: ("Finb/Bark", "https://github.com/Finb/Bark")
        case .gotify: ("gotify/server", "https://github.com/gotify/server")
        case .webhook: ("POST JSON", "https://github.com/kopylovis/agentmeister#notifications-when-claude-is-waiting-for-you")
        case .pushover: ("pushover.net/api", "https://pushover.net/api")
        case .apprise: ("caronc/apprise", "https://github.com/caronc/apprise")
        }
    }

    func summary(_ l: L) -> String {
        switch self {
        case .telegram: l.t("Свой бот, кнопки \"Разрешить\" и \"Отклонить\" в чате", "Your own bot, Allow and Deny buttons in the chat")
        case .tossling: l.t("Твой сервер Tossling, канал agentmeister", "Your Tossling server, the agentmeister channel")
        case .ntfy: l.t("ntfy.sh или свой сервер ntfy", "ntfy.sh or your own ntfy server")
        case .bark: l.t("Push на iPhone через APNs без своего приложения", "Push to an iPhone through APNs without your own app")
        case .gotify: l.t("Свой сервер Gotify и приложение на Android", "Your own Gotify server and the Android app")
        case .webhook: l.t("POST с JSON на любой адрес", "POST JSON to any URL")
        case .pushover: l.t("Платный сервис, свой сервер не нужен", "A paid service, no server of your own")
        case .apprise: l.t("Около сотни сервисов через apprise на этом Mac", "About a hundred services through apprise on this Mac")
        }
    }

    func tags(_ l: L) -> [String] {
        switch self {
        case .telegram: [l.t("все телефоны", "any phone"), l.t("облако Telegram", "Telegram cloud")]
        case .tossling: ["Android", "iPhone", l.t("свой сервер", "own server")]
        case .ntfy: ["Android", "iPhone", l.t("облако или свой", "cloud or own")]
        case .bark: ["iPhone", l.t("облако или свой", "cloud or own")]
        case .gotify: ["Android", l.t("веб", "web"), l.t("свой сервер", "own server")]
        case .webhook: ["Home Assistant", "n8n", l.t("скрипты", "scripts")]
        case .pushover: ["Android", "iPhone", l.t("платно", "paid")]
        case .apprise: [l.t("любые", "any"), l.t("свой config", "own config")]
        }
    }
}

private func host(_ url: String?) -> String {
    guard let url, let h = URL(string: url)?.host else { return url ?? "" }
    if let port = URL(string: url)?.port { return "\(h):\(port)" }
    return h
}

/// Блокирующую команду agentmeister увести с главного потока.
private func agentmeister(_ args: [String], input: String? = nil) async -> (ok: Bool, text: String) {
    await Task.detached(priority: .userInitiated) {
        if let input { return Backend.runWithInput(args, input: input) }
        return Backend.runForText(args)
    }.value
}

struct PhoneChannels: View {
    @EnvironmentObject var backend: Backend
    let n: SettingsData.Notify
    let reload: () async -> Void
    @State private var open: Set<PhoneChannel> = []
    @State private var adding = false

    var l: L { L(backend.state.lang) }

    private var connected: [PhoneChannel] { PhoneChannel.allCases.filter(isConnected) }

    private func isConnected(_ c: PhoneChannel) -> Bool {
        switch c {
        case .telegram: n.telegram.connected
        case .tossling: n.tossling?.configured ?? n.phone.configured
        case .ntfy: n.ntfy?.configured ?? false
        case .bark: n.bark?.configured ?? false
        case .gotify: n.gotify?.configured ?? false
        case .webhook: n.webhook?.configured ?? false
        case .pushover: n.pushover?.configured ?? false
        case .apprise: n.apprise?.configured ?? false
        }
    }

    private func run(_ args: [String]) {
        Task {
            _ = await backend.perform(args)
            await reload()
        }
    }

    var body: some View {
        GlassSection {
            HStack(spacing: 12) {
                Text(l.t("На телефон", "To your phone")).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { adding = true } label: { Label(l.t("Добавить канал", "Add channel"), systemImage: "plus") }
                    .buttonStyle(PillStyle(prominent: connected.isEmpty))
            }
            Note(text: l.t("Каналы работают независимо, включить можно несколько сразу. Токены и ключи лежат в Связке ключей macOS, в файлы настроек они не попадают.",
                           "Channels work independently, several can be on at once. Tokens and keys live in the macOS keychain, never in settings files."))
            SettingsRow(l.t("Не за Mac после", "Away after"),
                        l.t("Экран заблокирован или мышь и клавиатура не трогались столько минут. Одно значение для всех каналов.",
                            "The screen is locked or the mouse and keyboard sat idle this many minutes. One value for all channels."),
                        titleFont: .system(size: 13, weight: .medium)) {
                HStack(spacing: 6) {
                    NumberField(value: max(1, (n.away ?? n.telegram.away) / 60)) { run(["notify", "away", String(max(1, $0) * 60)]) }
                    Text(l.t("мин", "min")).foregroundStyle(Ink.muted)
                }
            }
            if connected.isEmpty {
                Text(l.t("Каналов пока нет. Добавь первый, и вопросы агента придут на телефон, когда ты отойдешь от Mac.",
                         "No channels yet. Add one and agent questions reach your phone when you step away from the Mac."))
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.muted)
                    .frame(maxWidth: .infinity)
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
            } else {
                VStack(spacing: 8) {
                    ForEach(connected) { c in
                        ChannelCard(channel: c, n: n, l: l, expanded: Binding(
                            get: { open.contains(c) },
                            set: { if $0 { open.insert(c) } else { open.remove(c) } }), reload: reload)
                    }
                }
            }
        }
        .id("phone-channels")
        .onAppear {
            guard Demo.active, open.isEmpty else { return }
            if Demo.scene == "settings-notify-add" || Demo.scene.hasPrefix("telegram-") { adding = true }
            open = Demo.scene == "settings-notify-phone" ? [.webhook] : Demo.scene == "settings-notify" ? [.ntfy] : [.telegram]
        }
        .sheet(isPresented: $adding) {
            AddChannelSheet(l: l, connected: Set(connected)) { Task { await reload() } }
        }
    }
}

/// Строка канала со статусом и раскрывающаяся карточка с его настройками.
struct ChannelCard: View {
    @EnvironmentObject var backend: Backend
    let channel: PhoneChannel
    let n: SettingsData.Notify
    let l: L
    @Binding var expanded: Bool
    let reload: () async -> Void
    @State private var confirmRemove = false
    @State private var secret: SecretRequest?
    @State private var output: String?

    private var cmd: [String] { ["notify", channel.rawValue] }

    private var mode: String {
        switch channel {
        case .telegram: n.telegram.when
        case .tossling: n.tossling?.mode ?? n.phone.mode
        case .ntfy: n.ntfy?.mode ?? "off"
        case .bark: n.bark?.mode ?? "off"
        case .gotify: n.gotify?.mode ?? "off"
        case .webhook: n.webhook?.mode ?? "off"
        case .pushover: n.pushover?.mode ?? "off"
        case .apprise: n.apprise?.mode ?? "off"
        }
    }

    private var body_: String? {
        switch channel {
        case .telegram: nil
        case .tossling: n.tossling?.body
        case .ntfy: n.ntfy?.body
        case .bark: n.bark?.body
        case .gotify: n.gotify?.body
        case .webhook: n.webhook?.body
        case .pushover: n.pushover?.body
        case .apprise: n.apprise?.body
        }
    }

    private var error: SettingsData.Notify.SendError? {
        switch channel {
        case .telegram: n.telegram.error
        case .tossling: n.tossling?.error
        case .ntfy: n.ntfy?.error
        case .bark: n.bark?.error
        case .gotify: n.gotify?.error
        case .webhook: n.webhook?.error
        case .pushover: n.pushover?.error
        case .apprise: n.apprise?.error
        }
    }

    private var detail: String {
        switch channel {
        case .telegram: n.telegram.bot.map { "@" + $0 } ?? ""
        case .tossling: [host(n.tossling?.server), n.tossling?.topic ?? "agentmeister"].filter { !$0.isEmpty }.joined(separator: " · ")
        case .ntfy: [host(n.ntfy?.server), n.ntfy?.topic.map { $0.count > 20 ? String($0.prefix(18)) + "…" : $0 } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        case .bark: host(n.bark?.server) + ((n.bark?.encrypted ?? false) ? " · AES-256" : "")
        case .gotify: host(n.gotify?.server)
        case .webhook: n.webhook?.host ?? ""
        case .pushover: "api.pushover.net"
        case .apprise: [n.apprise?.config ?? "", n.apprise?.tag.map { "#" + $0 } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    /// Ошибка в строке канала видна, пока канал включен: у выключенного она уже ничего не значит.
    private var failing: Bool { error != nil && mode != "off" }

    private func run(_ args: [String]) {
        Task {
            _ = await backend.perform(args)
            await reload()
        }
    }

    private func row<Control: View>(_ title: String, _ sub: String? = nil, @ViewBuilder control: @escaping () -> Control) -> some View {
        SettingsRow(title, sub, titleFont: .system(size: 13, weight: .medium), control: control)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: { header }
                .buttonStyle(.plain)
                .accessibilityLabel(channel.name)
                .accessibilityValue(expanded ? l.t("раскрыт", "expanded") : l.t("свернут", "collapsed"))
            if expanded {
                Rectangle().fill(Ink.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(failing ? Ink.redBorder : .clear))
        .sheet(item: $secret) { req in SecretSheet(request: req, l: l) { Task { await reload() } } }
        .sheet(isPresented: Binding(get: { output != nil }, set: { if !$0 { output = nil } })) {
            OutputSheet(text: output ?? "", l: l)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(channel.name).font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Ink.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            chip
            if body_ == "title" { StateChip(text: l.t("только заголовок", "title only"), fg: Ink.muted, bg: Ink.chip) }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Ink.muted)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var chip: some View {
        if failing {
            StateChip(text: l.t("ошибка", "failing"), fg: Ink.red, bg: Ink.redChip)
        } else {
            switch mode {
            case "always": StateChip(text: l.t("всегда", "always"), fg: Ink.codexBadge, bg: Ink.codexBadgeBg)
            case "away": StateChip(text: l.t("не за Mac", "when away"), fg: Ink.teal, bg: Ink.tealChip)
            default: StateChip(text: l.t("выключен", "off"), fg: Ink.muted, bg: Ink.chip)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if failing, let error {
            let at = Date(timeIntervalSince1970: error.at).formatted(date: .abbreviated, time: .shortened)
            Box(text: l.t("Отправка \(at) не прошла. ", "Sending at \(at) failed. ") + error.text, fg: Ink.red, bg: Ink.redChip)
        }
        row(l.t("Когда присылать", "When to send")) {
            SegmentedCapsule(selection: Binding(get: { mode }, set: { run(cmd + [$0]) }),
                             options: (channel == .telegram ? [] : [("off", l.t("Выкл", "Off"), nil)])
                                + [("away", l.t("Когда я не за Mac", "When I'm away"), nil), ("always", l.t("Всегда", "Always"), nil)],
                             compact: true)
        }
        if let body_ {
            row(l.t("Текст уведомления", "Notification text"),
                l.t("В тексте бывает команда, которую агент просит разрешить", "The text can contain a command the agent asks to allow")) {
                SegmentedCapsule(selection: Binding(get: { body_ }, set: { run(cmd + ["body", $0]) }),
                                 options: [("full", l.t("Полностью", "Full"), nil), ("title", l.t("Только заголовок", "Title only"), nil)],
                                 compact: true)
            }
        }
        switch channel {
        case .telegram: telegram
        case .tossling: tossling
        case .ntfy: ntfy
        case .bark: bark
        case .gotify: gotify
        case .webhook: webhook
        case .pushover: pushover
        case .apprise: apprise
        }
        footer
    }

    @ViewBuilder private var telegram: some View {
        field(l.t("Бот", "Bot"), n.telegram.bot.map { "@" + $0 } ?? "")
        field(l.t("Токен бота", "Bot token"), keychain: true)
        row(l.t("Отвечать на запросы разрешений из Telegram", "Answer permission requests from Telegram"),
            l.t("Кнопки \"Разрешить\" и \"Отклонить\" в чате, пока ты не за Mac. Вопросы и планы остаются на Mac.",
                "\"Allow\" and \"Deny\" buttons in the chat while you are away. Questions and plans stay on the Mac.")) {
            HeaderSwitch(label: "approve", on: n.telegram.approve) { run(["notify", "telegram", "approve", $0 ? "on" : "off"]) }
        }
        if n.telegram.approve {
            Box(text: l.t("Разрешить команду на Mac сможет любой, кто откроет твой Telegram или получит токен бота. Включай, только если у аккаунта Telegram есть пароль и двухэтапная проверка.",
                          "Anyone who can open your Telegram or holds the bot token can allow a command on your Mac. Turn this on only if your Telegram account has a password and two-step verification."),
                fg: Ink.amber, bg: Ink.amberDot.opacity(0.14))
        }
    }

    @ViewBuilder private var tossling: some View {
        let t = n.tossling
        if t?.source == "manual" {
            field(l.t("Сервер", "Server"), t?.server ?? "")
            field(l.t("Токен публикации", "Publisher token"), keychain: true) {
                secret = SecretRequest(title: l.t("Токен публикации Tossling", "Tossling publisher token"),
                                       prompt: l.t("Токен проекта для канала agentmeister", "Project token for the agentmeister channel"),
                                       args: ["notify", "tossling", "token"])
            }
        } else {
            Box(text: l.t("Настройки взяты у tossling на этом Mac. Если поменяешь сервер в Tossling, здесь он поменяется сам.",
                          "Settings come from tossling on this Mac. Change the server in Tossling and it changes here too."),
                fg: Ink.teal, bg: Ink.tealChip)
            field(l.t("Сервер", "Server"), t?.server ?? "")
        }
        field(l.t("Канал", "Channel"), t?.topic ?? "agentmeister")
        Note(text: l.t("На телефоне Tossling, Уведомления, плюс, канал agentmeister.", "On the phone Tossling, Notifications, plus, channel agentmeister."))
    }

    @ViewBuilder private var ntfy: some View {
        let t = n.ntfy
        field(l.t("Сервер", "Server"), t?.server ?? "")
        HStack(spacing: 12) {
            Text(l.t("Канал", "Topic")).foregroundStyle(Ink.muted).frame(width: 170, alignment: .leading)
            Text(t?.topic ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            CommandButton(title: l.t("Новое имя", "New name"), args: ["notify", "ntfy", "topic", "new"], reload: reload, small: true)
        }
        .font(.system(size: 13))
        field(l.t("Токен", "Token"), keychain: t?.token ?? false, empty: l.t("нет", "none")) {
            secret = SecretRequest(title: l.t("Токен ntfy", "ntfy token"),
                                   prompt: l.t("Токен tk_... или логин:пароль", "A tk_... token or user:password"),
                                   args: ["notify", "ntfy", "token"])
        }
        if let url = t?.subscribe {
            HStack(alignment: .center, spacing: 14) {
                QRCode(text: url).frame(width: 92, height: 92)
                Text(l.t("Наведи камеру телефона, ссылка откроет канал в приложении ntfy. Или подпишись вручную, сервер \(host(t?.server)), канал \(t?.topic ?? "").",
                         "Point the phone camera here, the link opens the topic in the ntfy app. Or subscribe by hand, server \(host(t?.server)), topic \(t?.topic ?? "")."))
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if (t?.public ?? false) && !(t?.token ?? false) {
            Box(text: l.t("На ntfy.sh канал без токена читает любой, кто знает его имя. Имя случайное, не показывай его никому. Новое имя отключит старые подписки.",
                          "On ntfy.sh anyone who knows the topic name can read it without a token. The name is random, keep it private. A new name cuts off old subscriptions."),
                fg: Ink.amber, bg: Ink.amberDot.opacity(0.14))
        } else if !(t?.public ?? true) {
            Note(text: l.t("Чтобы push на iPhone приходил сразу, своему серверу нужен upstream-base-url: https://ntfy.sh.",
                           "For instant push on iPhone your own server needs upstream-base-url: https://ntfy.sh."))
        }
    }

    @ViewBuilder private var bark: some View {
        let t = n.bark
        field(l.t("Сервер", "Server"), t?.server ?? "")
        field(l.t("Ключ устройства", "Device key"), keychain: true) {
            secret = SecretRequest(title: l.t("Ключ устройства Bark", "Bark device key"),
                                   prompt: l.t("Ключ или адрес с главного экрана Bark", "The key or the URL from the Bark main screen"),
                                   args: ["notify", "bark", "setup"])
        }
        row(l.t("Шифровать текст", "Encrypt the text"),
            l.t("AES-256. Ключ знают только этот Mac и Bark на телефоне, сервер видит шифр.",
                "AES-256. Only this Mac and Bark on the phone know the key, the server sees ciphertext.")) {
            HeaderSwitch(label: "encrypt", on: t?.encrypted ?? false) { on in
                Task {
                    let r = await agentmeister(["notify", "bark", "encrypt", on ? "on" : "off"])
                    await reload()
                    if on { output = r.text }
                }
            }
        }
        if t?.encrypted ?? false {
            HStack {
                Button(l.t("Показать ключ для приложения", "Show the key for the app")) {
                    Task { output = await agentmeister(["notify", "bark", "encrypt", "on"]).text }
                }
                .buttonStyle(PillStyle(small: true))
                Spacer()
            }
        }
    }

    @ViewBuilder private var gotify: some View {
        let t = n.gotify
        field(l.t("Сервер", "Server"), t?.server ?? "")
        field(l.t("Токен приложения", "App token"), keychain: true) {
            secret = SecretRequest(title: l.t("Токен приложения Gotify", "Gotify app token"),
                                   prompt: l.t("Токен из Apps в веб-панели Gotify", "The token from Apps in the Gotify web UI"),
                                   args: ["notify", "gotify", "setup", t?.server ?? ""])
        }
        let urgent = t?.priority.urgent ?? 8, normal = t?.priority.normal ?? 4
        row(l.t("Приоритет вопросов", "Question priority"), l.t("От 0 до 10. С 8 Android показывает уведомление со звуком и вибрацией", "0 to 10. From 8 Android shows it with sound and vibration")) {
            NumberField(value: urgent) { run(["notify", "gotify", "priority", String(min(10, $0)), String(normal)]) }
        }
        row(l.t("Приоритет \"готово\"", "\"Done\" priority"), l.t("От 4 со звуком, ниже только значок", "From 4 with sound, below that an icon only")) {
            NumberField(value: normal) { run(["notify", "gotify", "priority", String(urgent), String(min(10, $0))]) }
        }
        Note(text: l.t("Приложения для iPhone у Gotify нет.", "Gotify has no iPhone app."))
    }

    @ViewBuilder private var webhook: some View {
        field(l.t("Адрес", "URL"), keychain: true) {
            secret = SecretRequest(title: l.t("Адрес вебхука", "Webhook URL"),
                                   prompt: l.t("Полный адрес, токен в нем останется в Связке ключей", "The full URL, a token in it stays in the keychain"),
                                   args: ["notify", "webhook", "setup"])
        }
        field(l.t("Authorization", "Authorization"), keychain: n.webhook?.auth ?? false, empty: l.t("нет", "none")) {
            secret = SecretRequest(title: l.t("Заголовок Authorization", "Authorization header"),
                                   prompt: l.t("Значение заголовка, например Bearer <токен>", "The header value, for example Bearer <token>"),
                                   args: ["notify", "webhook", "auth"])
        }
        Note(text: l.t("Тело запроса JSON с полями agent, title, message, project, session, urgent и строкой text.",
                       "The request body is JSON with agent, title, message, project, session, urgent and a text line."))
    }

    @ViewBuilder private var pushover: some View {
        field(l.t("Ключ пользователя и токен", "User Key and token"), keychain: true) {
            secret = SecretRequest(title: l.t("Ключи Pushover", "Pushover keys"),
                                   prompt: l.t("User Key и API Token приложения через пробел", "The User Key and the app API Token, separated by a space"),
                                   args: ["notify", "pushover", "setup"])
        }
        Note(text: l.t("Вопросы и запросы уходят с приоритетом 1, он пробивает тихие часы Pushover.",
                       "Questions and requests go with priority 1, which gets through Pushover quiet hours."))
    }

    @ViewBuilder private var apprise: some View {
        let t = n.apprise
        field(l.t("Config apprise", "apprise config"), t?.config ?? "")
        HStack(spacing: 12) {
            Text(l.t("Тег", "Tag")).foregroundStyle(Ink.muted).frame(width: 170, alignment: .leading)
            Text(t?.tag ?? l.t("все сервисы без тега", "all untagged services")).font(.system(size: 12, design: .monospaced))
            Spacer()
        }
        .font(.system(size: 13))
        Note(text: l.t("Адреса сервисов и их токены живут в config apprise, agentmeister их не хранит. Текст уходит в apprise через stdin. Тег задается командой agentmeister notify apprise tag <тег>.",
                       "Service URLs and their tokens live in the apprise config, agentmeister doesn't keep them. The text goes to apprise through stdin. Set a tag with agentmeister notify apprise tag <tag>."))
    }

    private var removeArgs: [[String]]? {
        switch channel {
        case .telegram: [["notify", "telegram", "off"]]
        case .tossling: n.tossling?.source == "manual" ? [["notify", "tossling", "off"], ["notify", "tossling", "token", "off"], ["notify", "tossling", "server", "auto"]] : nil
        case .ntfy, .bark, .gotify, .webhook, .pushover: [["notify", channel.rawValue, "forget"]]
        case .apprise: [["notify", "apprise", "forget"]]
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            CommandButton(title: l.t("Прислать тест", "Send test"), args: cmd + ["test"], reload: reload, small: true)
            Spacer()
            if let removeArgs {
                if confirmRemove {
                    Button(l.t("Оставить", "Keep")) { confirmRemove = false }.buttonStyle(PillStyle(small: true))
                }
                Button(confirmRemove ? l.t("Точно отключить?", "Disconnect for sure?") : l.t("Отключить", "Disconnect")) {
                    if !confirmRemove { confirmRemove = true; return }
                    confirmRemove = false
                    Task {
                        for args in removeArgs { _ = await agentmeister(args) }
                        await reload()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.red)
            }
        }
    }

    /// Ряд "подпись, значение". keychain: значение это секрет из Связки ключей, его не показываем, только заменяем.
    @ViewBuilder private func field(_ title: String, _ value: String = "", keychain: Bool? = nil, empty: String? = nil,
                                    replace: (() -> Void)? = nil) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(Ink.muted).frame(width: 170, alignment: .leading)
            if let keychain {
                if keychain {
                    Text("••••••••••••").font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.muted)
                    StateChip(text: l.t("в Связке ключей", "in the keychain"), fg: Ink.teal, bg: Ink.tealChip)
                } else {
                    Text(empty ?? l.t("не задан", "not set")).foregroundStyle(Ink.muted)
                }
                Spacer(minLength: 8)
                if let replace {
                    Button(keychain ? l.t("Заменить", "Replace") : l.t("Добавить", "Add"), action: replace).buttonStyle(PillStyle(small: true))
                }
            } else {
                Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 13))
    }
}

/// Маленький чип статуса в строке канала.
struct StateChip: View {
    let text: String
    let fg: Color
    let bg: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(fg)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(bg))
    }
}

/// Цветная плашка с пояснением: ошибка, предупреждение или подсказка.
private struct Box: View {
    let text: String
    let fg: Color
    let bg: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(fg)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(bg))
    }
}

/// QR-код ссылки подписки, рисуется CoreImage без сглаживания.
struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white))
                .accessibilityLabel("QR " + text)
        }
    }

    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: output.extent.size)
    }
}

struct SecretRequest: Identifiable {
    let title: String
    let prompt: String
    let args: [String]
    var id: String { args.joined(separator: " ") }
}

/// Ввести или заменить секрет канала. Значение уходит в команду через stdin и нигде не остается.
struct SecretSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: SecretRequest
    let l: L
    let done: () -> Void
    @State private var value = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title).font(.system(size: 17, weight: .semibold))
            Text(request.prompt).font(.system(size: 12)).foregroundStyle(Ink.muted)
            SecureField("", text: $value).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .onSubmit(save)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Ink.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(l.t("Отмена", "Cancel")) { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button(l.t("Сохранить", "Save"), action: save).buttonStyle(PillStyle(prominent: true))
                    .disabled(busy || value.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func save() {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, !busy else { return }
        busy = true
        Task {
            let r = await agentmeister(request.args, input: v)
            busy = false
            if r.ok {
                done()
                dismiss()
            } else {
                error = r.text.isEmpty ? l.t("Не сохранилось", "Not saved") : r.text
            }
        }
    }
}

/// Вывод команды, который надо прочитать или скопировать: ключ шифрования Bark для приложения.
struct OutputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    let l: L

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
            HStack {
                Spacer()
                Button(l.t("Готово", "Done")) { dismiss() }.buttonStyle(PillStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}

/// Лист "Добавить канал": карточки сервисов со ссылками на исходники, потом форма подключения выбранного.
struct AddChannelSheet: View {
    @Environment(\.dismiss) private var dismiss
    let l: L
    let connected: Set<PhoneChannel>
    let done: () -> Void
    @State private var picked: PhoneChannel?
    @State private var server = ""
    @State private var token = ""
    @State private var extra = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if picked == .telegram {
                TelegramConnectForm(l: l, back: { picked = nil }, cancel: { dismiss() }, done: { done(); dismiss() })
            } else if let picked {
                form(picked)
            } else {
                picker
            }
        }
        .padding(22)
        .frame(width: 640)
        // демо telegram-token, -wait, -shared: лист сразу на подключении Telegram
        .onAppear { if Demo.active && Demo.scene.hasPrefix("telegram-") { picked = .telegram } }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l.t("Добавить канал", "Add a channel")).font(.system(size: 17, weight: .semibold))
            Text(l.t("Куда присылать вопросы и запросы агентов, когда ты не за Mac. Ссылка под названием ведет на исходники сервиса.",
                     "Where agent questions and requests go when you are away from the Mac. The link under each name leads to the service's source."))
                .font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(PhoneChannel.allCases) { c in card(c) }
            }
            HStack {
                Spacer()
                Button(l.t("Отмена", "Cancel")) { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
            }
        }
    }

    private func card(_ c: PhoneChannel) -> some View {
        let on = connected.contains(c)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                picked = c
                server = c == .ntfy ? "https://ntfy.sh" : ""
                token = ""
                extra = ""
                error = nil
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(c.name).font(.system(size: 14, weight: .semibold))
                        if on { StateChip(text: l.t("подключен", "connected"), fg: Ink.teal, bg: Ink.tealChip) }
                    }
                    Text(c.summary(l)).font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                    Text(c.tags(l).joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(on)
            Link(c.source.0, destination: URL(string: c.source.1)!)
                .font(.system(size: 11, design: .monospaced))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Ink.card))
        .opacity(on ? 0.6 : 1)
    }

    @ViewBuilder private func form(_ c: PhoneChannel) -> some View {
        Text(l.t("Подключить \(c.name)", "Connect \(c.name)")).font(.system(size: 17, weight: .semibold))
        switch c {
        case .telegram:
            // свой лист: TelegramConnectForm
            EmptyView()
        case .tossling:
            Text(l.t("Если на этом Mac поставить Tossling и подключить его к серверу, настройки подтянутся сами. Без него укажи сервер и токен публикации проекта для канала agentmeister.",
                     "Install Tossling on this Mac and connect it to your server, and the settings come by themselves. Without it give the server and a project publisher token for the agentmeister channel."))
                .font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link(l.t("Как поставить Tossling", "How to install Tossling"), destination: URL(string: "https://tossling.github.io/docs/install/")!)
                Link(l.t("Токен проекта", "Project token"), destination: URL(string: "https://tossling.github.io/docs/server/projects/")!)
            }
            .font(.system(size: 12))
            input(l.t("Сервер", "Server"), "https://tossling.example.com", $server)
            input(l.t("Токен публикации", "Publisher token"), "tk_…", $token, secure: true)
        case .ntfy:
            input(l.t("Сервер", "Server"), "https://ntfy.sh", $server)
            input(l.t("Токен, необязательно", "Token, optional"), l.t("tk_… или логин:пароль", "tk_… or user:password"), $token, secure: true)
            Text(l.t("Имя канала будет случайным. На ntfy.sh без токена оно работает как пароль, поэтому туда по умолчанию уходит только заголовок.",
                     "The topic name is random. On ntfy.sh without a token it works as a password, so only the title goes there by default."))
                .font(.system(size: 12)).foregroundStyle(Ink.amber).fixedSize(horizontal: false, vertical: true)
        case .bark:
            input(l.t("Ключ устройства", "Device key"), l.t("ключ или https://api.day.app/ключ/", "key or https://api.day.app/key/"), $token, secure: true)
            Text(l.t("Ключ показан на главном экране приложения Bark. Шифрование включается после подключения, в карточке канала.",
                     "The key is on the main screen of the Bark app. Encryption is turned on after connecting, in the channel card."))
                .font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
        case .gotify:
            input(l.t("Сервер", "Server"), "https://gotify.example.com", $server)
            input(l.t("Токен приложения", "App token"), l.t("из Apps в веб-панели", "from Apps in the web UI"), $token, secure: true)
        case .webhook:
            input(l.t("Адрес", "URL"), "https://example.com/hooks/agentmeister", $token, secure: true)
            input(l.t("Authorization, необязательно", "Authorization, optional"), "Bearer …", $extra, secure: true)
            Text(l.t("Адрес хранится в Связке ключей целиком, токен в нем никуда не попадет.",
                     "The URL is kept in the keychain whole, a token in it goes nowhere else."))
                .font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
        case .pushover:
            input(l.t("Ключ пользователя", "User Key"), "u…", $server, secure: true)
            input(l.t("Токен приложения", "App API Token"), "a…", $token, secure: true)
            Link(l.t("Где взять", "Where to get them"), destination: URL(string: "https://pushover.net/api")!).font(.system(size: 12))
        case .apprise:
            Text(l.t("Нужны команда apprise (brew install apprise) и ее config со списком сервисов, например ~/.config/apprise/apprise.yml. agentmeister только включает отправку через нее.",
                     "This needs the apprise command (brew install apprise) and its config with your services, for example ~/.config/apprise/apprise.yml. agentmeister only turns sending through it on."))
                .font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            Link(l.t("Как писать config apprise", "How to write the apprise config"), destination: URL(string: "https://github.com/caronc/apprise/wiki/config")!)
                .font(.system(size: 12))
        }
        if let error { Text(error).font(.system(size: 12)).foregroundStyle(Ink.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        HStack {
            Button(l.t("Назад", "Back")) { picked = nil; error = nil }.buttonStyle(PillStyle())
            Spacer()
            Button(l.t("Отмена", "Cancel")) { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
            Button(l.t("Подключить", "Connect")) { connect(c) }
                .buttonStyle(PillStyle(prominent: true))
                .disabled(busy || !ready(c))
                .keyboardShortcut(.defaultAction)
        }
    }

    private func input(_ title: String, _ placeholder: String, _ text: Binding<String>, secure: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(Ink.muted).frame(width: 170, alignment: .leading)
            Group {
                if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
        }
    }

    private func ready(_ c: PhoneChannel) -> Bool {
        let s = server.trimmingCharacters(in: .whitespaces), t = token.trimmingCharacters(in: .whitespaces)
        switch c {
        case .telegram: return true
        case .ntfy: return !s.isEmpty
        case .bark: return !t.isEmpty
        case .tossling, .gotify, .pushover: return !s.isEmpty && !t.isEmpty
        case .webhook: return !t.isEmpty
        case .apprise: return true
        }
    }

    /// Шаги подключения по порядку. Секрет идет вторым элементом, через stdin.
    private func steps(_ c: PhoneChannel) -> [([String], String?)] {
        let s = server.trimmingCharacters(in: .whitespacesAndNewlines), t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        switch c {
        case .telegram: return []
        case .tossling: return [(["notify", "tossling", "server", s], nil), (["notify", "tossling", "token"], t), (["notify", "tossling", "away"], nil)]
        case .ntfy: return [(["notify", "ntfy", "setup", "--server", s], nil)] + (t.isEmpty ? [] : [(["notify", "ntfy", "token"], t)])
        case .bark: return [(["notify", "bark", "setup"], t)]
        case .gotify: return [(["notify", "gotify", "setup", s], t)]
        case .webhook:
            let auth = extra.trimmingCharacters(in: .whitespacesAndNewlines)
            return [(["notify", "webhook", "setup"], t)] + (auth.isEmpty ? [] : [(["notify", "webhook", "auth"], auth)])
        case .pushover: return [(["notify", "pushover", "setup"], s + "\n" + t)]
        case .apprise: return [(["notify", "apprise", "away"], nil)]
        }
    }

    private func connect(_ c: PhoneChannel) {
        busy = true
        error = nil
        Task {
            for (args, input) in steps(c) {
                let r = await agentmeister(args, input: input)
                if !r.ok {
                    busy = false
                    error = r.text.isEmpty ? l.t("Не подключилось", "Couldn't connect") : r.text
                    done()
                    return
                }
            }
            busy = false
            done()
            dismiss()
        }
    }
}
