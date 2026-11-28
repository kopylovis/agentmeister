import SwiftUI

/// Откуда берутся серверы основной подписки: ссылка на подписку или свой прокси. Вместо вопросов
/// agentmeister proxy setup в терминале. Ссылка и адрес уходят в команду через stdin ("-" вместо аргумента):
/// в аргументах их видно в ps. Вывод команды показывает лист CommandSheet того же окна.
struct ProxySourceSheet: View {
    @EnvironmentObject var backend: Backend
    @Environment(\.dismiss) private var dismiss
    @Environment(\.commandHost) private var host
    let title: String
    var own = false
    var onFinish: (() async -> Void)? = nil
    @State private var ownProxy = false
    @State private var secret = ""
    @State private var country = ""
    @State private var only = ""

    var l: L { L(backend.state.lang) }

    static let countries = ["DE", "FI", "FR", "GB", "GE", "KZ", "NL", "PL", "SE", "TR", "US"]

    private var proxy: AppState.Proxy? { backend.state.proxy }
    private var busy: Int { proxy?.configured == true ? proxy?.sessions ?? 0 : 0 }
    private var clean: String { secret.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Что не так с введенным, до запуска команды. Подробную проверку делает сам proxy setup.
    private var problem: String? {
        guard !clean.isEmpty else { return nil }
        if ownProxy {
            return clean.range(of: #"^(socks5h?|https?)://\S+:\d+/?$"#, options: .regularExpression) == nil
                ? l.t("Нужен адрес с портом: socks5://127.0.0.1:1080 или http://proxy.corp:3128",
                      "It needs an address with a port: socks5://127.0.0.1:1080 or http://proxy.corp:3128") : nil
        }
        if clean.hasPrefix("happ://") {
            return l.t("Это зашифрованная ссылка Happ, ее читает только сам Happ. Нужна обычная https:// ссылка.",
                       "This is an encrypted Happ link, only Happ can read it. It needs a plain https:// link.")
        }
        return clean.hasPrefix("http://") || clean.hasPrefix("https://") ? nil
            : l.t("Ссылка начинается с https://", "The link starts with https://")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text(l.t("Источник", "Source")).foregroundStyle(Ink.muted)
                    SegmentedCapsule(selection: Binding(get: { ownProxy ? "own" : "sub" }, set: { ownProxy = $0 == "own"; secret = "" }),
                                     options: [("sub", l.t("Подписка", "Subscription"), nil), ("own", l.t("Свой прокси", "Your own proxy"), nil)],
                                     compact: true)
                        .fixedSize()
                }
                GridRow {
                    Text(ownProxy ? l.t("Адрес", "Address") : l.t("Ссылка", "Link")).foregroundStyle(Ink.muted)
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(ownProxy ? "socks5://127.0.0.1:1080" : "https://…", text: $secret)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(start)
                        Text(problem ?? (ownProxy
                            ? l.t("socks5://, http:// или https:// с портом, логин и пароль можно в адресе.",
                                  "socks5://, http:// or https:// with a port, a login and password can go in the address.")
                            : l.t("Для Clash, mihomo или v2ray, та же, что в Happ.", "For Clash, mihomo or v2ray, the same one as in Happ.")))
                            .font(.system(size: 11))
                            .foregroundStyle(problem == nil ? Ink.faint : Ink.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Text(l.t("Страна", "Country")).foregroundStyle(Ink.muted)
                    Picker("", selection: $country) {
                        Text(l.t("Любая рабочая", "Any working")).tag("")
                        ForEach(countryOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                if !ownProxy {
                    GridRow {
                        Text(l.t("Серверы", "Servers")).foregroundStyle(Ink.muted)
                        TextField(l.t("все, или выражение для имени, например DE", "all, or a name pattern such as DE"), text: $only)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .font(.system(size: 13))
            Note(text: l.t("Ссылка уходит в agentmeister через stdin, в аргументах и в ps ее не видно. Хранится в ~/.config/agentmeister/proxy, файл читаешь только ты. Если через новую выйти не получится, прежняя настройка вернется сама.",
                           "The link goes to agentmeister through stdin, it isn't in the arguments or in ps. It's kept in ~/.config/agentmeister/proxy, readable only by you. If the new one can't get out, the previous setup comes back by itself."))
            if busy > 0 {
                Text(l.t("Сейчас через proxy идут сессии (\(busy)). Сменить подписку можно, когда их закроют.",
                         "Proxied sessions are running now (\(busy)). The subscription can be changed once they are closed."))
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.warn)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Ink.warnChip))
            }
            HStack {
                Spacer()
                Button(l.cancel) { dismiss() }
                    .buttonStyle(PillStyle())
                    .keyboardShortcut(.cancelAction)
                Button(l.t("Проверить и сохранить", "Check and save"), action: start)
                    .buttonStyle(PillStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(clean.isEmpty || problem != nil || busy > 0)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            ownProxy = own
            country = proxy?.subscriptions?.first { $0.name == "main" }?.country?.uppercased() ?? ""
        }
    }

    private var countryOptions: [String] {
        Self.countries.contains(country) || country.isEmpty ? Self.countries : (Self.countries + [country]).sorted()
    }

    private func start() {
        guard !clean.isEmpty, problem == nil, busy == 0 else { return }
        var args = ["proxy", "setup"] + (ownProxy ? ["--upstream", "-"] : ["-"])
        if !country.isEmpty { args += ["--country", country] }
        let pattern = only.trimmingCharacters(in: .whitespaces)
        if !ownProxy && !pattern.isEmpty { args += ["--only", pattern] }
        let input = clean
        let title = self.title
        let host = self.host
        let backend = self.backend
        let after = onFinish
        dismiss()
        // лист команды открывается, когда этот уже закрылся: два листа одного окна сразу не показать
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            CommandRuns.shared.start(args, title: title, icon: "arrow.triangle.2.circlepath", host: host, sheet: true,
                                     input: input) {
                backend.refresh()
                await after?()
            }
        }
    }
}
