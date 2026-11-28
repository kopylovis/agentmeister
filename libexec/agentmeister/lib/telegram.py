import hmac
import html
import json
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from menu import secret
from mnrhlib import HOME, read_config, tilde, tr, write_config
import keychain
import presence
from presence import away_after

# Секреты каналов уведомлений лежат в Связке ключей под одним сервисом, аккаунт по имени канала
SERVICE = "agentmeister.notify"
ACCOUNT = "telegram"
# Здесь токен лежал до 1.28.1. Запись не удаляется, пока канал не отключат: ее читают старые версии Agentmeister
OLD_KEYCHAIN = ("mnrh-telegram", "bot")
API = "https://api.telegram.org/bot{}/{}"
TOKEN_RE = re.compile(r"^\d{5,}:[A-Za-z0-9_-]{30,}$")


class TelegramError(Exception):
    pass


class TelegramConflict(TelegramError):
    """409: этого бота уже опрашивает другая программа, а Telegram отдает обновления только одной."""


CONFLICT = ("этого бота уже опрашивает другая программа (например, плагин Telegram для Claude Code), "
            "а Telegram отдает обновления только одной. Заведи для agentmeister отдельного бота: "
            "agentmeister notify telegram setup")
CONFLICT_EN = ("another program already polls this bot (for example, the Telegram plugin for Claude Code), "
               "and Telegram gives updates to only one. Create a separate bot for agentmeister: "
               "agentmeister notify telegram setup")


def conflict():
    return tr(CONFLICT, CONFLICT_EN)


def plugin_env():
    """Файл с токеном плагина Telegram для Claude Code (его channels/telegram/.env)."""
    base = os.environ.get("TELEGRAM_STATE_DIR") or os.path.join(
        os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude"), "channels", "telegram")
    return os.path.join(base, ".env")


def plugin_token():
    """Токен бота плагина Telegram, если плагин настроен. Файл только читаем."""
    try:
        with open(plugin_env()) as f:
            for line in f:
                m = re.match(r"^TELEGRAM_BOT_TOKEN=(.*)$", line.strip())
                if m:
                    return m.group(1).strip().strip("\"'")
    except OSError:
        pass
    return ""


def shares_plugin_bot(tok=None):
    """Тот же бот настроен в плагине Telegram для Claude Code: опрашивать его нам нельзя, плагин перестанет
    получать сообщения (Telegram вернет 409 одному из нас)."""
    plug = plugin_token()
    return bool(plug) and plug == (tok or token())


def keychain_find(service, account):
    try:
        r = subprocess.run(["security", "find-generic-password", "-s", service, "-a", account, "-w"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def token():
    tok = keychain_find(SERVICE, ACCOUNT)
    if tok:
        return tok
    tok = keychain_find(*OLD_KEYCHAIN)
    if tok:
        try:  # копия под новым именем, старую запись не трогаем
            save_token(tok)
        except TelegramError:
            pass
    return tok


def save_token(value):
    # через keychain.save: токен уходит в security через stdin, не аргументом
    if not keychain.save(ACCOUNT, value, "Agentmeister Telegram bot", service=SERVICE):
        raise TelegramError(tr("не сохранил токен в Связку ключей", "couldn't save the token to the keychain"))


def forget_token():
    for service, account in ((SERVICE, ACCOUNT), OLD_KEYCHAIN):
        subprocess.run(["security", "delete-generic-password", "-s", service, "-a", account],
                       capture_output=True, timeout=10)


def call(method, tok=None, wait=15, **params):
    tok = tok or token()
    if not tok:
        raise TelegramError(tr("бот не подключён: agentmeister notify telegram",
                               "the bot isn't connected: agentmeister notify telegram"))
    data = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(API.format(tok, method), data=data),
                                    timeout=wait) as r:
            reply = json.load(r)
    except urllib.error.HTTPError as e:
        try:
            reply = json.load(e)
        except ValueError:
            if e.code == 409:
                raise TelegramConflict(conflict()) from None
            raise TelegramError(tr(f"Telegram ответил HTTP {e.code}", f"Telegram answered HTTP {e.code}")) from None
    except (urllib.error.URLError, OSError) as e:
        raise TelegramError(tr(f"нет связи с api.telegram.org ({getattr(e, 'reason', e)})",
                               f"can't reach api.telegram.org ({getattr(e, 'reason', e)})")) from None
    if not reply.get("ok"):
        if reply.get("error_code") == 409:
            raise TelegramConflict(conflict())
        raise TelegramError(reply.get("description") or tr("Telegram вернул ошибку", "Telegram returned an error"))
    return reply["result"]


def chat():
    return read_config().get("telegram_chat", "")


def configured():
    return bool(chat()) and bool(token())


def mode():
    return "always" if read_config().get("telegram_when") == "always" else "away"


def away():
    return presence.away()


def wanted():
    return configured() and (mode() == "always" or away())


def send(title, subtitle, body):
    parts = [f"<b>{html.escape(title)}</b>"]
    if subtitle:
        parts.append(f"<i>{html.escape(subtitle)}</i>")
    if body:
        parts.append(html.escape(body))
    return call("sendMessage", chat_id=chat(), text="\n".join(parts), parse_mode="HTML",
                disable_web_page_preview="true")


def read_token(stdin=False):
    """stdin: токен строкой из stdin (так передает приложение, в аргументах его видно в ps)."""
    if stdin:
        return sys.stdin.readline().strip()
    if sys.stdin.isatty():
        return secret(tr("Токен бота (при вводе не виден): ", "Bot token (hidden): ")).strip()
    clip = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout.strip()
    if TOKEN_RE.match(clip):
        subprocess.run(["pbcopy"], input="", text=True)
        print(tr("Взял токен из буфера обмена и очистил буфер.", "Took the token from the clipboard and cleared the clipboard."))
        return clip
    return ""


def reset_updates(tok=None):
    """Вернуть боту набор обновлений Telegram по умолчанию.

    allowed_updates в getUpdates Telegram запоминает для бота насовсем, и прежние версии оставляли бота
    только с ["message"] или ["callback_query"]: тогда другая программа на том же боте (плагин Telegram
    для Claude Code) не получает сообщений. Пустой список и есть умолчание; сам опрос его больше не передает,
    нужное отбирает сам. timeout=0 без offset ничего не подтверждает."""
    call("getUpdates", tok, timeout=0, limit=1, allowed_updates="[]")


def who(ch):
    name = " ".join(x for x in (ch.get("first_name"), ch.get("last_name")) if x)
    user = f"@{ch['username']}" if ch.get("username") else ""
    return " ".join(x for x in (name, user) if x) or str(ch.get("id", "?"))


def wait_for_start(tok, code, seconds=180):
    """Личный чат, из которого пришел /start <code>. /start без кода или с чужим кодом мог прислать
    кто угодно, кто знает адрес бота: такие пропускаем, иначе уведомления ушли бы ему."""
    offset = None
    deadline = time.time() + seconds
    reset_updates(tok)
    skipped = set()
    while time.time() < deadline:
        updates = call("getUpdates", tok, wait=40, offset=offset, timeout=25)
        for u in updates:
            offset = u["update_id"] + 1
            msg = u.get("message") or {}
            ch = msg.get("chat") or {}
            text = (msg.get("text") or "").strip()
            if ch.get("type") != "private" or not text.startswith("/start"):
                continue
            got = text.split()[1] if len(text.split()) > 1 else ""
            if hmac.compare_digest(got, code) and (msg.get("from") or {}).get("id") == ch.get("id"):
                call("getUpdates", tok, offset=offset, timeout=0)
                return ch
            if ch.get("id") not in skipped:
                skipped.add(ch.get("id"))
                print(tr(f"  Пропускаю /start без верного кода от {who(ch)}: нужна ссылка выше или /start {code}",
                         f"  Skipping /start without the right code from {who(ch)}: use the link above or /start {code}"))
    return None


SHARED_BOT = 3  # код выхода: бот занят плагином Telegram, подключить можно только с --force


def setup(stdin=False, force=False):
    """stdin и force для приложения: токен из stdin; force подключает бота, которого уже взял плагин Telegram."""
    print(tr("Подключаю уведомления в Telegram.", "Connecting Telegram notifications."))
    print(tr("  1. В Telegram открой @BotFather, отправь /newbot, придумай имя и адрес бота.",
             "  1. In Telegram open @BotFather, send /newbot, pick a name and a username for the bot."))
    print(tr("  2. BotFather пришлёт токен вида 123456789:AA… — скопируй его.",
             "  2. BotFather sends a token like 123456789:AA…, copy it."))
    print(tr("Токен хранится в Связке ключей macOS, в файлы и в вывод не попадает.",
             "The token is kept in the macOS keychain and never goes to files or output."))
    tok = read_token(stdin)
    if not TOKEN_RE.match(tok or ""):
        print(tr("Нет токена. Скопируй его из сообщения BotFather и запусти команду ещё раз.",
                 "No token. Copy it from the BotFather message and run the command again."))
        return 1
    try:
        bot = call("getMe", tok)
    except TelegramError as e:
        print(tr(f"✗ Telegram не принял токен: {e}", f"✗ Telegram didn't accept the token: {e}"))
        return 1
    if shares_plugin_bot(tok):
        print(tr(f"! Этот же бот настроен в плагине Telegram для Claude Code ({tilde(plugin_env())}).",
                 f"! The same bot is set up in the Telegram plugin for Claude Code ({tilde(plugin_env())})."))
        print(tr("  Telegram отдает обновления только одной программе: agentmeister и плагин будут перебивать",
                 "  Telegram gives updates to only one program: agentmeister and the plugin will get in each"))
        print(tr("  друг друга, кнопки «Разрешить» и «Отклонить» с этим ботом работать не будут.",
                 "  other's way, and the Allow and Deny buttons won't work with this bot."))
        print(tr("  Лучше заведи для agentmeister отдельного бота в @BotFather.",
                 "  Better create a separate bot for agentmeister in @BotFather."))
        if force:
            pass
        elif stdin or not sys.stdin.isatty():
            print(tr("Не подключил. Подключить все равно: --force", "Not connected. To connect anyway: --force"))
            return SHARED_BOT
        elif input(tr("Все равно подключить этого бота? [y/N] ",
                      "Connect this bot anyway? [y/N] ")).strip().lower() not in ("y", "yes", "д", "да"):
            print(tr("Не подключил.", "Not connected."))
            return 1
    save_token(tok)
    name = bot.get("username", "")
    print(tr(f"✓ бот @{name}", f"✓ bot @{name}"))
    code = secrets.token_hex(4)
    link = f"https://t.me/{name}?start={code}"
    print(tr(f"  3. Открываю {link} — нажми там «Start» (до 3 минут).",
             f"  3. Opening {link}, press Start there (within 3 minutes)."))
    print(tr(f"     Если ссылка не открылась, отправь боту: /start {code}",
             f"     If the link didn't open, send the bot: /start {code}"))
    subprocess.run(["open", link], capture_output=True)
    try:
        ch = wait_for_start(tok, code)
    except TelegramError as e:
        print(f"✗ {e}")
        return 1
    if not ch:
        print(tr("Не дождался /start. Запусти agentmeister notify telegram ещё раз.",
                 "No /start arrived. Run agentmeister notify telegram again."))
        return 1
    write_config(telegram_chat=str(ch["id"]), telegram_bot=name)
    try:
        call("sendMessage", chat_id=ch["id"], text=tr("agentmeister подключен ✓ Сюда будут приходить уведомления Claude, "
                                                      "когда ты не за Mac.",
                                                      "agentmeister is connected ✓ Claude notifications will arrive here "
                                                      "when you are away from the Mac."))
    except TelegramError:
        pass
    print(tr(f"✓ подключено к чату с {who(ch)}. Если это не ты — agentmeister notify telegram off",
             f"✓ connected to the chat with {who(ch)}. If this isn't you: agentmeister notify telegram off"))
    print(tr(f"Уведомления идут в Telegram, когда ты не за Mac: экран заблокирован или {away_after() // 60} мин "
             f"без мыши и клавиатуры.",
             f"Notifications go to Telegram when you are away from the Mac: the screen is locked or "
             f"{away_after() // 60} min without mouse and keyboard."))
    return 0


def describe():
    if not configured():
        return tr("Telegram: не подключён — agentmeister notify telegram",
                  "Telegram: not connected, agentmeister notify telegram")
    bot = read_config().get("telegram_bot", "")
    when = tr("всегда", "always") if mode() == "always" else tr(
        f"когда ты не за Mac (блокировка или {away_after()} с без ввода)",
        f"when you are away (screen locked or {away_after()}s without input)")
    shared = tr(". ! Тот же бот, что у плагина Telegram для Claude Code: кнопки разрешений с ним не работают, "
                "заведи отдельного: agentmeister notify telegram setup",
                ". ! Same bot as the Telegram plugin for Claude Code: permission buttons don't work with it, "
                "create a separate one: agentmeister notify telegram setup") if shares_plugin_bot() else ""
    return f"Telegram: @{bot}, {when}{shared}"


def main(args):
    cmd = args[0] if args else ""
    if not cmd:
        if configured():
            print(describe())
            print(tr("  test | off | always | away [сек] | approve on|off",
                     "  test | off | always | away [sec] | approve on|off"))
            return 0
        return setup()
    if cmd == "setup":
        return setup(stdin="--stdin" in args[1:], force="--force" in args[1:])
    if cmd == "off":
        forget_token()
        write_config(telegram_chat="", telegram_bot="")
        print(tr("Telegram отключён, токен удалён из Связки ключей",
                 "Telegram disconnected, the token is removed from the keychain"))
        return 0
    if cmd == "always":
        write_config(telegram_when="always")
        print(tr("Telegram: присылаю всегда, даже если ты за Mac", "Telegram: sending always, even when you are at the Mac"))
        return 0
    if cmd == "away":
        if len(args) > 1:
            if not args[1].isdigit():
                print(tr("agentmeister notify telegram away <секунд без ввода>",
                         "agentmeister notify telegram away <seconds without input>"))
                return 2
            presence.set_away_after(args[1])
        write_config(telegram_when="away")
        print(describe())
        return 0
    if cmd == "approve":
        import telegram_approve
        return telegram_approve.main(args[1:])
    if cmd == "test":
        try:
            send(tr("agentmeister: пробное уведомление", "agentmeister: test notification"), "Claude Code",
                 tr("Так будут выглядеть уведомления, когда ты не за Mac.",
                    "This is how notifications look when you are away from the Mac."))
        except TelegramError as e:
            print(f"✗ {e}")
            return 1
        print(tr("✓ отправлено в Telegram", "✓ sent to Telegram"))
        return 0
    print(tr("agentmeister notify telegram [test | off | always | away [сек] | approve on|off]",
             "agentmeister notify telegram [test | off | always | away [sec] | approve on|off]"))
    return 2
