"""Канал Pushover (https://pushover.net/api): платный сервис, свой сервер не нужен. В config notify_pushover (off,
away, always) и notify_pushover_body (full или title, по умолчанию title: сервер чужой). Ключ пользователя и токен
приложения лежат в Связке ключей (agentmeister.notify, аккаунты pushover-user и pushover). Вопросы и запросы
уходят с приоритетом 1, он пробивает тихие часы, остальное с 0."""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

import keychain
import ntfy_alert
from mnrhlib import read_config, tr, write_config

API = "https://api.pushover.net/1/messages.json"
USER_ACCOUNT = "pushover-user"
TOKEN_ACCOUNT = "pushover"


class PushoverError(Exception):
    pass


def configured():
    return bool(keychain.find(TOKEN_ACCOUNT)) and bool(keychain.find(USER_ACCOUNT))


def mode():
    # сначала config: хук зовет mode() на каждое событие, а Связку ключей трогаем, только если канал включен
    value = read_config().get("notify_pushover", "off")
    return value if value in ("away", "always") and configured() else "off"


def body_mode():
    value = read_config().get("notify_pushover_body", "title")
    return value if value in ntfy_alert.BODIES else "title"


def send(title, message, urgent=False):
    token, user = keychain.find(TOKEN_ACCOUNT), keychain.find(USER_ACCOUNT)
    if not token or not user:
        raise PushoverError(tr("Pushover не подключен: agentmeister notify pushover setup",
                               "Pushover isn't connected: agentmeister notify pushover setup"))
    form = {"token": token, "user": user, "title": title[:250], "message": (message or title or "—")[:1024],
            "priority": "1" if urgent else "0"}
    req = urllib.request.Request(API, data=urllib.parse.urlencode(form).encode(), method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status
    except urllib.error.HTTPError as e:
        try:
            errors = json.loads(e.read().decode(errors="replace")).get("errors") or []
        except ValueError:
            errors = []
        raise PushoverError(f"HTTP {e.code} {'; '.join(map(str, errors))}".strip()) from None
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise PushoverError(f"нет связи с api.pushover.net: {getattr(e, 'reason', e)}") from None


def describe():
    if not configured():
        return tr("Pushover: не подключен, agentmeister notify pushover setup",
                  "Pushover: not connected, agentmeister notify pushover setup")
    when = {"off": tr("выключен", "off"), "away": tr("когда ты не за Mac", "when you are away"),
            "always": tr("всегда", "always")}[mode()]
    body = tr("только заголовок", "title only") if body_mode() == "title" else tr("полный текст", "full text")
    return f"Pushover: {when}, {body}"


def read_pair():
    """Ключ пользователя и токен приложения: из терминала двумя вопросами, из stdin двумя строками."""
    if sys.stdin.isatty():
        user = keychain.read_secret(tr("Ключ пользователя (User Key, при вводе не виден): ", "User Key (hidden): "))
        token = keychain.read_secret(tr("Токен приложения (API Token, при вводе не виден): ", "Application API Token (hidden): "))
        return user, token
    parts = sys.stdin.read().split()
    return (parts + ["", ""])[:2]


def setup(args):
    if args:
        return usage(2)
    user, token = read_pair()
    if not user or not token:
        print(tr("Нужны оба значения, ключ пользователя и токен приложения",
                 "Both are needed, the User Key and the application token"))
        return 2
    if not (keychain.save(USER_ACCOUNT, user, "Agentmeister Pushover user") and
            keychain.save(TOKEN_ACCOUNT, token, "Agentmeister Pushover token")):
        print(tr("Не сохранил ключи в Связку ключей", "Couldn't save the keys to the keychain"))
        return 1
    if read_config().get("notify_pushover", "off") == "off":
        write_config(notify_pushover="away")
    print(describe())
    return 0


def usage(code=0):
    print(tr("agentmeister notify pushover setup  подключить, ключ пользователя и токен приложения спросит или возьмет "
             "из stdin двумя строками",
             "agentmeister notify pushover setup  connect, asks for the User Key and the app token or reads two lines "
             "from stdin"))
    print(tr("  … pushover away | always | off | test", "  … pushover away | always | off | test"))
    print(tr("  … pushover body full | title   полный текст или только заголовок",
             "  … pushover body full | title   full text or title only"))
    print(tr("  … pushover forget              забыть ключи", "  … pushover forget              forget the keys"))
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
        print(tr("Сначала agentmeister notify pushover setup", "Run agentmeister notify pushover setup first"))
        return 1
    if cmd in ("on", "away", "always", "off") and len(args) == 1:
        write_config(notify_pushover="away" if cmd == "on" else cmd)
        print(describe())
        return 0
    if cmd == "body" and len(args) == 2 and args[1] in ntfy_alert.BODIES:
        write_config(notify_pushover_body=args[1])
        print(describe())
        return 0
    if cmd == "forget" and len(args) == 1:
        keychain.delete(USER_ACCOUNT)
        keychain.delete(TOKEN_ACCOUNT)
        write_config(notify_pushover=None, notify_pushover_body=None)
        print(tr("Pushover отключен, ключи удалены", "Pushover disconnected, keys removed"))
        return 0
    if cmd == "test" and len(args) == 1:
        try:
            send(tr("Agentmeister: проверка канала", "Agentmeister: channel check"),
                 tr("Сюда приходят уведомления от Claude Code и Codex.", "Claude Code and Codex notifications arrive here."))
        except PushoverError as e:
            print(tr(f"Не отправил: {e}", f"Not sent: {e}"))
            return 1
        print(tr("Отправил пробное уведомление", "Sent a test notification"))
        return 0
    return usage(2)
