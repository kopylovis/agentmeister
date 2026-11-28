"""Канал "вебхук": POST с JSON на любой адрес (Home Assistant, n8n, свой скрипт). В config notify_webhook (off,
away, always) и notify_webhook_body (full или title). Адрес целиком лежит в Связке ключей (agentmeister.notify,
аккаунт webhook): в нем часто сидит токен. Заголовок Authorization, если нужен, там же (аккаунт webhook-auth).

Тело запроса: agent, title (агент и что случилось), message, project, session, urgent, а еще text и content
с заголовком и текстом одной строкой, их понимают простые приемники чатов."""
import json
import urllib.error
import urllib.parse
import urllib.request

import keychain
import ntfy_alert
from mnrhlib import read_config, tr, write_config

ACCOUNT = "webhook"
AUTH_ACCOUNT = "webhook-auth"


class WebhookError(Exception):
    pass


def url():
    return keychain.find(ACCOUNT)


def configured():
    return bool(url())


def mode():
    # сначала config: хук зовет mode() на каждое событие, а Связку ключей трогаем, только если канал включен
    value = read_config().get("notify_webhook", "off")
    return value if value in ("away", "always") and configured() else "off"


def body_mode():
    value = read_config().get("notify_webhook_body", "full")
    return value if value in ntfy_alert.BODIES else "full"


def host():
    return urllib.parse.urlparse(url()).hostname or ""


def valid(value):
    parsed = urllib.parse.urlparse(value)
    return parsed.scheme in ("http", "https") and bool(parsed.hostname)


def payload(agent, head, project, session, text, urgent, body="full"):
    title = f"{agent}: {head}"
    if body == "title":
        session, text = "", ""
    message = "\n\n".join(p for p in (session, text) if p) or project or head
    line = f"{title}\n{message}"
    return {"agent": agent, "title": title, "message": message, "project": project, "session": session,
            "urgent": bool(urgent), "text": line, "content": line}


def send(data):
    target = url()
    if not target:
        raise WebhookError(tr("Вебхук не подключен: agentmeister notify webhook setup",
                              "The webhook isn't connected: agentmeister notify webhook setup"))
    headers = {"Content-Type": "application/json", "User-Agent": "agentmeister"}
    auth = keychain.find(AUTH_ACCOUNT)
    if auth:
        headers["Authorization"] = auth
    req = urllib.request.Request(target, data=json.dumps(data, ensure_ascii=False).encode(), method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace").strip()[:200]
        raise WebhookError(f"HTTP {e.code} {detail}".strip()) from None
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise WebhookError(tr(f"нет связи с {host()}: {getattr(e, 'reason', e)}",
                              f"can't reach {host()}: {getattr(e, 'reason', e)}")) from None


def describe():
    if not configured():
        return tr("Вебхук: не подключен, agentmeister notify webhook setup", "Webhook: not connected, agentmeister notify webhook setup")
    when = {"off": tr("выключен", "off"), "away": tr("когда ты не за Mac", "when you are away"),
            "always": tr("всегда", "always")}[mode()]
    body = tr("только заголовок", "title only") if body_mode() == "title" else tr("полный текст", "full text")
    auth = tr(", с заголовком Authorization", ", with an Authorization header") if keychain.find(AUTH_ACCOUNT) else ""
    return tr(f"Вебхук: {when}, {host()}, {body}{auth}", f"Webhook: {when}, {host()}, {body}{auth}")


def setup(args):
    if args:
        return usage(2)
    value = keychain.read_secret(tr("Адрес вебхука (при вводе не виден): ", "Webhook URL (hidden): "))
    if not valid(value):
        print(tr("Не похоже на адрес. Пример https://example.com/hooks/agentmeister",
                 "Not a URL. Example https://example.com/hooks/agentmeister"))
        return 2
    if not keychain.save(ACCOUNT, value, "Agentmeister webhook"):
        print(tr("Не сохранил адрес в Связку ключей", "Couldn't save the URL to the keychain"))
        return 1
    if read_config().get("notify_webhook", "off") == "off":
        write_config(notify_webhook="away")
    print(describe())
    return 0


def usage(code=0):
    print(tr("agentmeister notify webhook setup     подключить, адрес спросит или возьмет из stdin",
             "agentmeister notify webhook setup     connect, asks for the URL or reads it from stdin"))
    print(tr("  … webhook away | always | off | test", "  … webhook away | always | off | test"))
    print(tr("  … webhook body full | title         полный текст или только заголовок",
             "  … webhook body full | title         full text or title only"))
    print(tr("  … webhook auth [off]                заголовок Authorization из stdin, например Bearer <токен>",
             "  … webhook auth [off]                Authorization header from stdin, for example Bearer <token>"))
    print(tr("  … webhook forget                    забыть адрес и заголовок", "  … webhook forget                    forget URL and header"))
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
        print(tr("Сначала agentmeister notify webhook setup", "Run agentmeister notify webhook setup first"))
        return 1
    if cmd in ("on", "away", "always", "off") and len(args) == 1:
        write_config(notify_webhook="away" if cmd == "on" else cmd)
        print(describe())
        return 0
    if cmd == "body" and len(args) == 2 and args[1] in ntfy_alert.BODIES:
        write_config(notify_webhook_body=args[1])
        print(describe())
        return 0
    if cmd == "auth" and args[1:] in ([], ["off"]):
        if args[1:] == ["off"]:
            keychain.delete(AUTH_ACCOUNT)
        else:
            value = keychain.read_secret(tr("Значение заголовка Authorization (при вводе не видно): ",
                                            "Authorization header value (hidden): "))
            if not value or not keychain.save(AUTH_ACCOUNT, value, "Agentmeister webhook authorization"):
                print(tr("Заголовок не сохранен", "Header not saved"))
                return 1
        print(describe())
        return 0
    if cmd == "forget" and len(args) == 1:
        keychain.delete(ACCOUNT)
        keychain.delete(AUTH_ACCOUNT)
        write_config(notify_webhook=None, notify_webhook_body=None)
        print(tr("Вебхук отключен, адрес и заголовок удалены", "Webhook disconnected, URL and header removed"))
        return 0
    if cmd == "test" and len(args) == 1:
        try:
            send(payload("Agentmeister", tr("проверка канала", "channel check"), "agentmeister", "",
                         tr("Сюда приходят уведомления от Claude Code и Codex.", "Claude Code and Codex notifications arrive here."),
                         False))
        except WebhookError as e:
            print(tr(f"Не отправил: {e}", f"Not sent: {e}"))
            return 1
        print(tr("Отправил пробный запрос", "Sent a test request"))
        return 0
    return usage(2)
