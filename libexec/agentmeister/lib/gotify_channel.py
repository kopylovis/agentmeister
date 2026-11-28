"""Канал Gotify: свой сервер (https://github.com/gotify/server) и приложение для Android
(https://github.com/gotify/android). Приложения для iPhone у Gotify нет. В config notify_gotify (off, away,
always), notify_gotify_server, notify_gotify_body (full или title) и приоритеты notify_gotify_priority_urgent
и notify_gotify_priority. Токен приложения (Apps в веб-панели Gotify, не токен клиента) лежит в Связке ключей
(agentmeister.notify, аккаунт gotify).

Android-клиент по приоритету выбирает канал уведомлений: 0 без уведомления, 1-3 только значок, 4-7 со звуком,
8-10 со звуком и вибрацией поверх экрана. Поэтому вопросы и запросы по умолчанию 8, "готово" 4."""
import json
import urllib.error
import urllib.request

import keychain
import ntfy_alert
from mnrhlib import read_config, tr, write_config
from ntfy_channel import valid_server

ACCOUNT = "gotify"
DEFAULT_URGENT = 8
DEFAULT_NORMAL = 4


class GotifyError(Exception):
    pass


def server():
    return read_config().get("notify_gotify_server", "").rstrip("/")


def token():
    return keychain.find(ACCOUNT)


def configured():
    return bool(server()) and bool(token())


def mode():
    # сначала config: хук зовет mode() на каждое событие, а Связку ключей трогаем, только если канал включен
    value = read_config().get("notify_gotify", "off")
    return value if value in ("away", "always") and configured() else "off"


def body_mode():
    value = read_config().get("notify_gotify_body", "full")
    return value if value in ntfy_alert.BODIES else "full"


def priority(urgent):
    key, default = ("notify_gotify_priority_urgent", DEFAULT_URGENT) if urgent else ("notify_gotify_priority", DEFAULT_NORMAL)
    try:
        return min(10, max(0, int(read_config().get(key, default))))
    except ValueError:
        return default


def send(title, message, urgent=False):
    if not configured():
        raise GotifyError(tr("Gotify не подключен: agentmeister notify gotify setup <сервер>",
                             "Gotify isn't connected: agentmeister notify gotify setup <server>"))
    data = {"title": title, "message": message or title or "—", "priority": priority(urgent)}
    req = urllib.request.Request(server() + "/message", data=json.dumps(data).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "X-Gotify-Key": token()})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise GotifyError(tr(f"HTTP {e.code}, сервер не принял токен. Нужен токен приложения из Apps, "
                                 "а не токен клиента",
                                 f"HTTP {e.code}, the server didn't accept the token. You need an app token from Apps, "
                                 "not a client token")) from None
        try:
            detail = json.loads(e.read().decode(errors="replace")).get("errorDescription", "")
        except ValueError:
            detail = ""
        raise GotifyError(f"HTTP {e.code} {detail}".strip()) from None
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise GotifyError(tr(f"нет связи с сервером Gotify: {getattr(e, 'reason', e)}",
                             f"can't reach the Gotify server: {getattr(e, 'reason', e)}")) from None


def describe():
    if not configured():
        return tr("Gotify: не подключен, agentmeister notify gotify setup <сервер>",
                  "Gotify: not connected, agentmeister notify gotify setup <server>")
    when = {"off": tr("выключен", "off"), "away": tr("когда ты не за Mac", "when you are away"),
            "always": tr("всегда", "always")}[mode()]
    body = tr("только заголовок", "title only") if body_mode() == "title" else tr("полный текст", "full text")
    prio = tr(f"приоритет вопросов {priority(True)}, готово {priority(False)}",
              f"priority {priority(True)} for questions, {priority(False)} for done")
    return f"Gotify: {when}, {server()}, {body}, {prio}"


def setup(args):
    if len(args) != 1:
        return usage(2)
    url = args[0].rstrip("/")
    if not valid_server(url):
        print(tr(f"Не похоже на адрес сервера: {url}. Пример https://gotify.example.com",
                 f"Not a server address: {url}. Example https://gotify.example.com"))
        return 2
    value = keychain.read_secret(tr("Токен приложения из Apps в Gotify (при вводе не виден): ",
                                    "App token from Apps in Gotify (hidden): "))
    if not value:
        print(tr("Пусто, без токена Gotify не примет сообщение", "Empty, Gotify won't take messages without a token"))
        return 1
    if not keychain.save(ACCOUNT, value, "Agentmeister Gotify"):
        print(tr("Не сохранил токен в Связку ключей", "Couldn't save the token to the keychain"))
        return 1
    values = {"notify_gotify_server": url}
    if read_config().get("notify_gotify", "off") == "off":
        values["notify_gotify"] = "away"
    write_config(**values)
    print(describe())
    return 0


def usage(code=0):
    print(tr("agentmeister notify gotify setup <сервер>  подключить, токен приложения спросит или возьмет из stdin",
             "agentmeister notify gotify setup <server>  connect, asks for the app token or reads it from stdin"))
    print(tr("  … gotify away | always | off | test", "  … gotify away | always | off | test"))
    print(tr("  … gotify body full | title          полный текст или только заголовок",
             "  … gotify body full | title          full text or title only"))
    print(tr("  … gotify priority <вопросы> <готово>  от 0 до 10, сейчас 8 и 4 по умолчанию",
             "  … gotify priority <questions> <done>  0 to 10, 8 and 4 by default"))
    print(tr("  … gotify forget                     забыть сервер и токен", "  … gotify forget                     forget server and token"))
    return code


def main(args):
    cmd = args[0] if args else ""
    if not cmd:
        print(describe())
        return 0
    if cmd in ("-h", "--help"):
        return usage()
    if cmd == "setup":
        return setup(args[1:])
    if not configured():
        print(tr("Сначала agentmeister notify gotify setup <сервер>", "Run agentmeister notify gotify setup <server> first"))
        return 1
    if cmd in ("on", "away", "always", "off") and len(args) == 1:
        write_config(notify_gotify="away" if cmd == "on" else cmd)
        print(describe())
        return 0
    if cmd == "body" and len(args) == 2 and args[1] in ntfy_alert.BODIES:
        write_config(notify_gotify_body=args[1])
        print(describe())
        return 0
    if cmd == "priority" and len(args) == 3:
        try:
            urgent, normal = int(args[1]), int(args[2])
        except ValueError:
            urgent = normal = -1
        if not (0 <= urgent <= 10 and 0 <= normal <= 10):
            print(tr("Приоритеты от 0 до 10", "Priorities are 0 to 10"))
            return 2
        write_config(notify_gotify_priority_urgent=str(urgent), notify_gotify_priority=str(normal))
        print(describe())
        return 0
    if cmd == "forget" and len(args) == 1:
        keychain.delete(ACCOUNT)
        write_config(notify_gotify=None, notify_gotify_server=None, notify_gotify_body=None,
                     notify_gotify_priority_urgent=None, notify_gotify_priority=None)
        print(tr("Gotify отключен, сервер и токен удалены", "Gotify disconnected, server and token removed"))
        return 0
    if cmd == "test" and len(args) == 1:
        try:
            send(tr("Agentmeister: проверка канала", "Agentmeister: channel check"),
                 tr("Сюда приходят уведомления от Claude Code и Codex.", "Claude Code and Codex notifications arrive here."),
                 urgent=True)
        except GotifyError as e:
            print(tr(f"Не отправил: {e}", f"Not sent: {e}"))
            return 1
        print(tr("Отправил пробное уведомление", "Sent a test notification"))
        return 0
    return usage(2)
