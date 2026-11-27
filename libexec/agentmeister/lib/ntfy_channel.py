"""Канал ntfy: ntfy.sh или свой сервер. В config notify_ntfy (off, away, always), notify_ntfy_server,
notify_ntfy_topic и notify_ntfy_body (full или title). Токен или логин:пароль, если сервер закрыт, лежит
в Связке ключей (agentmeister.notify, аккаунт ntfy).

На ntfy.sh канал без токена читает любой, кто знает его имя, поэтому имя генерируется случайно, а в
уведомление по умолчанию идет только заголовок, без текста вопроса и команды."""
import re
import secrets
import string
import urllib.parse

import keychain
import ntfy_alert
from mnrhlib import read_config, tr, write_config

DEFAULT_SERVER = "https://ntfy.sh"
PUBLIC_HOSTS = ("ntfy.sh",)
TOPIC_RE = re.compile(r"^[-_A-Za-z0-9]{1,64}$")
TOPIC_PREFIX = "agentmeister-"
ACCOUNT = "ntfy"
APPS = "https://ntfy.sh/#subscribe-phone"


def new_topic():
    alphabet = string.ascii_letters + string.digits
    return TOPIC_PREFIX + "".join(secrets.choice(alphabet) for _ in range(20))


def server():
    return (read_config().get("notify_ntfy_server") or DEFAULT_SERVER).rstrip("/")


def topic():
    value = read_config().get("notify_ntfy_topic", "")
    return value if TOPIC_RE.match(value) else ""


def token():
    return keychain.find(ACCOUNT)


def public(url=None):
    return urllib.parse.urlparse(url or server()).hostname in PUBLIC_HOSTS


def configured():
    return bool(topic())


def mode():
    value = read_config().get("notify_ntfy", "off")
    return value if value in ntfy_alert.MODES and configured() else "off"


def body_mode():
    value = read_config().get("notify_ntfy_body", "")
    if value in ntfy_alert.BODIES:
        return value
    return "title" if public() else "full"


def subscribe_url():
    return f"{server()}/{topic()}" if configured() else ""


def send(title, message, priority=3):
    if not configured():
        raise ntfy_alert.AlertError(tr("ntfy не подключен: agentmeister notify ntfy setup",
                                       "ntfy isn't connected: agentmeister notify ntfy setup"))
    return ntfy_alert.post(server(), token(), ntfy_alert.payload(topic(), message, title, priority,
                                                                 icon=ntfy_alert.AGENTMEISTER_ICON))


def valid_server(url):
    parsed = urllib.parse.urlparse(url)
    return parsed.scheme in ("http", "https") and bool(parsed.hostname)


def describe():
    if not configured():
        return tr("ntfy: не подключен, agentmeister notify ntfy setup", "ntfy: not connected, agentmeister notify ntfy setup")
    when = {"off": tr("выключен", "off"), "away": tr("когда ты не за Mac", "when you are away"),
            "always": tr("всегда", "always")}[mode()]
    body = tr("только заголовок", "title only") if body_mode() == "title" else tr("полный текст", "full text")
    auth = tr("с токеном", "with a token") if token() else tr("без токена", "no token")
    return f"ntfy: {when}, {server()}, {tr('канал', 'topic')} {topic()}, {body}, {auth}"


def explain_subscribe():
    print(tr(f"На телефоне в приложении ntfy подпишись на канал {topic()}"
             + ("" if public() else f" на сервере {server()}") + f". Ссылка {subscribe_url()}",
             f"In the ntfy app on your phone, subscribe to {topic()}"
             + ("" if public() else f" on {server()}") + f". Link {subscribe_url()}"))
    if public() and not token():
        print(tr("На ntfy.sh канал без токена читает любой, кто знает его имя. Не показывай его никому. "
                 "Новое имя: agentmeister notify ntfy topic new",
                 "On ntfy.sh anyone who knows the topic name can read it without a token. Keep it private. "
                 "New name: agentmeister notify ntfy topic new"))
    if not public():
        print(tr("Чтобы push на iPhone приходил сразу, на своем сервере нужен upstream-base-url: https://ntfy.sh",
                 "For instant push on iPhone your own server needs upstream-base-url: https://ntfy.sh"))


def setup(args):
    srv, top = None, None
    it = iter(args)
    for arg in it:
        if arg == "--server":
            srv = next(it, "")
        elif arg == "--topic":
            top = next(it, "")
        else:
            return usage(2)
    if srv is not None:
        srv = srv.rstrip("/")
        if not valid_server(srv):
            print(tr(f"Не похоже на адрес сервера: {srv}. Пример https://ntfy.example.com",
                     f"Not a server address: {srv}. Example https://ntfy.example.com"))
            return 2
    if top is not None and not TOPIC_RE.match(top):
        print(tr("Имя канала: от 1 до 64 латинских букв, цифр, - и _", "Topic name: 1 to 64 Latin letters, digits, - and _"))
        return 2
    values = {"notify_ntfy_topic": top or topic() or new_topic()}
    if srv is not None:
        values["notify_ntfy_server"] = None if srv == DEFAULT_SERVER else srv
    if read_config().get("notify_ntfy", "off") == "off":
        values["notify_ntfy"] = "away"
    write_config(**values)
    print(describe())
    explain_subscribe()
    return 0


def usage(code=0):
    print(tr("agentmeister notify ntfy setup [--server <url>] [--topic <имя>]  подключить, имя канала случайное",
             "agentmeister notify ntfy setup [--server <url>] [--topic <name>]  connect, the topic name is random"))
    print(tr("  … ntfy away | always | off | test", "  … ntfy away | always | off | test"))
    print(tr("  … ntfy body full | title    полный текст или только заголовок",
             "  … ntfy body full | title    full text or title only"))
    print(tr("  … ntfy topic new            новое случайное имя канала, старые подписки перестанут получать",
             "  … ntfy topic new            a new random topic, old subscriptions stop receiving"))
    print(tr("  … ntfy token [off]          токен или логин:пароль для закрытого сервера, из stdin",
             "  … ntfy token [off]          token or user:password for a protected server, from stdin"))
    print(tr("  … ntfy forget               забыть настройки и токен", "  … ntfy forget               forget settings and token"))
    return code


def main(args):
    cmd = args[0] if args else ""
    if not cmd:
        if not configured():
            return setup([])
        print(describe())
        return 0
    if cmd in ("-h", "--help"):
        return usage()
    if cmd == "setup":
        return setup(args[1:])
    if not configured():
        print(tr("Сначала agentmeister notify ntfy setup", "Run agentmeister notify ntfy setup first"))
        return 1
    if cmd in ("on", "away", "always", "off") and len(args) == 1:
        write_config(notify_ntfy="away" if cmd == "on" else cmd)
        print(describe())
        return 0
    if cmd == "body" and len(args) == 2 and args[1] in ntfy_alert.BODIES:
        write_config(notify_ntfy_body=args[1])
        print(describe())
        return 0
    if cmd == "topic" and len(args) == 2:
        value = new_topic() if args[1] == "new" else args[1]
        if not TOPIC_RE.match(value):
            print(tr("Имя канала: от 1 до 64 латинских букв, цифр, - и _", "Topic name: 1 to 64 Latin letters, digits, - and _"))
            return 2
        write_config(notify_ntfy_topic=value)
        print(describe())
        explain_subscribe()
        return 0
    if cmd == "token" and len(args) <= 2:
        if args[1:] == ["off"]:
            keychain.delete(ACCOUNT)
            print(describe())
            return 0
        if len(args) == 2:
            return usage(2)
        value = keychain.read_secret(tr("Токен или логин:пароль (при вводе не виден): ",
                                        "Token or user:password (hidden): "))
        if not value:
            print(tr("Пусто, токен не менял", "Empty, token unchanged"))
            return 1
        if not keychain.save(ACCOUNT, value, "Agentmeister ntfy"):
            print(tr("Не сохранил токен в Связку ключей", "Couldn't save the token to the keychain"))
            return 1
        print(describe())
        return 0
    if cmd == "forget" and len(args) == 1:
        keychain.delete(ACCOUNT)
        write_config(notify_ntfy=None, notify_ntfy_server=None, notify_ntfy_topic=None, notify_ntfy_body=None)
        print(tr("ntfy отключен, настройки и токен удалены", "ntfy disconnected, settings and token removed"))
        return 0
    if cmd == "test" and len(args) == 1:
        try:
            send(tr("Agentmeister: проверка канала", "Agentmeister: channel check"),
                 tr("Сюда приходят уведомления от Claude Code и Codex.", "Claude Code and Codex notifications arrive here."))
        except ntfy_alert.AlertError as e:
            print(tr(f"Не отправил: {e}", f"Not sent: {e}"))
            return 1
        print(tr(f"Отправил пробное уведомление в {topic()}", f"Sent a test notification to {topic()}"))
        return 0
    return usage(2)
