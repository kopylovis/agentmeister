import AppKit
import SwiftUI

/// Подключение Telegram в листе "Добавить канал" вместо мастера в терминале. Токен уходит в
/// agentmeister notify telegram setup --stdin через stdin, команда открывает чат с ботом и ждет Start
/// до трех минут. Бот, которого уже взял плагин Telegram, команда без --force не подключает (код 3).
struct TelegramConnectForm: View {
    let l: L
    let back: () -> Void
    let cancel: () -> Void
    let done: () -> Void
    @State private var token = ""
    @State private var run: CommandRun?
    @State private var problem: String?

    static let tokenPattern = #"^\d{5,}:[A-Za-z0-9_-]{30,}$"#

    private var clean: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { clean.range(of: Self.tokenPattern, options: .regularExpression) != nil }

    var body: some View {
        if let run {
            TelegramRunView(run: run, l: l, retry: { start(force: run.args.contains("--force")) },
                            force: { start(force: true) }, otherToken: { token = ""; self.run = nil },
                            failed: { reason in problem = reason; self.run = nil }, cancel: cancel, done: done)
        } else {
            tokenStep
        }
    }

    private var tokenStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l.t("Шаг 1 из 2", "Step 1 of 2")).font(.system(size: 11)).foregroundStyle(Ink.faint)
                Text(l.t("Подключить Telegram", "Connect Telegram")).font(.system(size: 17, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("1").foregroundStyle(Ink.faint)
                    Text(.init(l.t("В Telegram открой [@BotFather](https://t.me/BotFather), отправь /newbot, придумай имя и адрес бота.",
                                   "In Telegram open [@BotFather](https://t.me/BotFather), send /newbot, pick a name and a username for the bot.")))
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("2").foregroundStyle(Ink.faint)
                    Text(l.t("BotFather пришлет токен вида 123456789:AA…, вставь его сюда.",
                             "BotFather sends a token like 123456789:AA…, paste it here."))
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Ink.text2)
            VStack(alignment: .leading, spacing: 6) {
                Text(l.t("Токен бота", "Bot token")).font(.system(size: 12)).foregroundStyle(Ink.label)
                SecureField("123456789:AA…", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if valid { start(force: false) } }
                Text(problem ?? l.t("Хранится в Связке ключей macOS. В файлы, вывод и аргументы команды не попадает.",
                                    "Kept in the macOS keychain. It never goes to files, output or the command's arguments."))
                    .font(.system(size: 11))
                    .foregroundStyle(problem == nil ? Ink.faint : Ink.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(l.t("Назад", "Back"), action: back).buttonStyle(PillStyle())
                Spacer()
                Button(l.t("Отмена", "Cancel"), action: cancel).buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button(l.t("Дальше", "Continue")) { start(force: false) }
                    .buttonStyle(PillStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .onAppear {
            // демо telegram-wait и telegram-shared: сразу дальше с выдуманным токеном
            if Demo.active, Demo.scene == "telegram-wait" || Demo.scene == "telegram-shared" {
                token = "123456789:" + String(repeating: "A", count: 35)
                start(force: false)
            }
        }
    }

    private func start(force: Bool) {
        problem = nil
        let next = CommandRun(args: ["notify", "telegram", "setup", "--stdin"] + (force ? ["--force"] : []),
                              title: "Telegram", icon: "paperplane", host: .settings)
        next.input = clean
        run?.stop()
        run = next
        next.start()
    }
}

/// Вторая половина: проверка токена, бот плагина, ожидание Start, итог. Показывает то, что печатает команда.
private struct TelegramRunView: View {
    @ObservedObject var run: CommandRun
    let l: L
    let retry: () -> Void
    let force: () -> Void
    let otherToken: () -> Void
    let failed: (String?) -> Void
    let cancel: () -> Void
    let done: () -> Void
    /// Когда команда напечатала ссылку на бота: от этого момента она ждет Start три минуты.
    @State private var linkAt: Date?
    @State private var copied = false

    /// Бот и код из строки со ссылкой https://t.me/<бот>?start=<код>.
    private var link: (url: URL, bot: String, code: String)? {
        let text = run.output
        guard let re = try? NSRegularExpression(pattern: #"https://t\.me/([A-Za-z0-9_]+)\?start=([0-9a-f]+)"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let all = Range(m.range, in: text), let bot = Range(m.range(at: 1), in: text),
              let code = Range(m.range(at: 2), in: text), let url = URL(string: String(text[all])) else { return nil }
        return (url, String(text[bot]), String(text[code]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if run.phase == .failed && run.code == 3 {
                shared
            } else if let link {
                wait(link)
            } else if run.phase == .running {
                header(l.t("Шаг 1 из 2", "Step 1 of 2"), l.t("Подключить Telegram", "Connect Telegram"))
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(l.t("Проверяю токен у Telegram", "Checking the token with Telegram")).foregroundStyle(Ink.text2)
                }
                .font(.system(size: 13))
                footer { Button(l.t("Отмена", "Cancel")) { run.stop(); cancel() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction) }
            }
        }
        .onAppear { noteLink() }
        .onChange(of: run.output) { noteLink() }
        .onChange(of: run.phase) {
            // токен не принят: обратно к полю с причиной
            if run.phase == .failed && run.code != 3 && link == nil && !run.stopped { failed(run.reason) }
        }
    }

    private func noteLink() {
        if linkAt == nil, link != nil { linkAt = Date() }
    }

    private func header(_ step: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step).font(.system(size: 11)).foregroundStyle(Ink.faint)
            Text(title).font(.system(size: 17, weight: .semibold))
        }
    }

    private func footer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Spacer()
            content()
        }
    }

    private var shared: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(l.t("Шаг 1 из 2", "Step 1 of 2"), l.t("Подключить Telegram", "Connect Telegram"))
            VStack(alignment: .leading, spacing: 6) {
                Text(l.t("Этот бот уже подключен в плагине Telegram для Claude Code", "This bot is already set up in the Telegram plugin for Claude Code"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.warn)
                Text(l.t("Telegram отдает обновления только одной программе. agentmeister и плагин будут перебивать друг друга, кнопки \"Разрешить\" и \"Отклонить\" с этим ботом работать не будут. Лучше завести для agentmeister отдельного бота в @BotFather.",
                         "Telegram gives updates to only one program. agentmeister and the plugin will get in each other's way, and the Allow and Deny buttons won't work with this bot. Better create a separate bot for agentmeister in @BotFather."))
                    .font(.system(size: 12)).foregroundStyle(Ink.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Ink.warnChip))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.amberDot.opacity(0.35)))
            footer {
                Button(l.t("Другой токен", "Another token"), action: otherToken).buttonStyle(PillStyle())
                Button(l.t("Все равно подключить", "Connect anyway"), action: force).buttonStyle(PillStyle())
            }
        }
    }

    @ViewBuilder private func wait(_ link: (url: URL, bot: String, code: String)) -> some View {
        switch run.phase {
        case .done:
            header(l.t("Готово", "Done"), l.t("Telegram подключен", "Telegram is connected"))
            status(ok: true, run.reason ?? l.t("Подключено", "Connected"))
            Text(l.t("Бот прислал \"agentmeister подключен\". Уведомления пойдут туда, когда ты не за Mac.",
                     "The bot sent \"agentmeister is connected\". Notifications go there when you are away from the Mac."))
                .font(.system(size: 13)).foregroundStyle(Ink.text2).fixedSize(horizontal: false, vertical: true)
            footer { Button(l.t("Готово", "Done"), action: done).buttonStyle(PillStyle(prominent: true)).keyboardShortcut(.defaultAction) }
        case .failed:
            header(l.t("Шаг 2 из 2", "Step 2 of 2"), l.t("Нажми Start у бота", "Press Start at the bot"))
            status(ok: false, run.stopped ? l.t("Остановлено", "Stopped") : run.reason ?? l.t("Не дождался Start", "No Start arrived"))
            footer {
                Button(l.t("Отмена", "Cancel"), action: cancel).buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
                Button(l.t("Повторить", "Try again"), action: retry).buttonStyle(PillStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        case .running:
            header(l.t("Шаг 2 из 2", "Step 2 of 2"), l.t("Нажми Start у бота", "Press Start at the bot"))
            status(ok: true, l.t("Токен принят, бот @\(link.bot)", "Token accepted, bot @\(link.bot)"))
            Text(l.t("Telegram уже открыт на чате с ботом. Нажми там Start, и уведомления пойдут в этот чат. Чужой /start без кода не подключится.",
                     "Telegram is already open on the chat with the bot. Press Start there and notifications go to that chat. Someone else's /start without the code won't connect."))
                .font(.system(size: 13)).foregroundStyle(Ink.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(l.t("Открыть Telegram снова", "Open Telegram again")) { NSWorkspace.shared.open(link.url) }
                    .buttonStyle(PillStyle(prominent: true))
                    .fixedSize()
                Text(l.t("или отправь боту", "or send the bot")).font(.system(size: 12)).foregroundStyle(Ink.faint)
                Text("/start " + link.code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Ink.chip))
                Button(copied ? l.t("Скопировано", "Copied") : l.t("Скопировать", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("/start " + link.code, forType: .string)
                    copied = true
                }
                .buttonStyle(.link).font(.system(size: 12))
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, 180 - Int(context.date.timeIntervalSince(linkAt ?? context.date)))
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(l.t("Жду Start, осталось ", "Waiting for Start, ") + String(format: "%d:%02d", left / 60, left % 60)
                         + l.t("", " left"))
                }
                .font(.system(size: 13))
                .foregroundStyle(Ink.link)
            }
            footer { Button(l.t("Отмена", "Cancel")) { run.stop(); cancel() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction) }
        }
    }

    private func status(ok: Bool, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark" : "xmark").font(.system(size: 12, weight: .bold))
            Text(text).lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(ok ? Ink.teal : Ink.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(ok ? Ink.tealChip : Ink.redChip))
    }
}
