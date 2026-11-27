"""Отправка в ntfy и пресет Tossling. Tossling Server внутри тот же ntfy, поэтому оба канала шлют через post().
Сервер и токен Tossling берутся у команды tossling на этом Mac. Без нее их можно задать вручную:
notify_tossling_server в config и токен публикации в Связке ключей (agentmeister.notify, аккаунт tossling)."""
import base64
import json
import os
import subprocess
import urllib.error
import urllib.request

import keychain
from mnrhlib import HOME, read_config, tossling_path, write_config

# Настройки старых версий Tossling (раньше Tossy), если команды tossling нет
LEGACY_CONFIGS = (os.path.join(HOME, ".config", "tossling", "config.json"), os.path.join(HOME, ".config", "tossy", "config.json"))
INSTALL_DOCS = "https://tossling.github.io/docs/install/"
PROJECTS_DOCS = "https://tossling.github.io/docs/server/projects/"
AGENTMEISTER_TOPIC = "agentmeister"
AGENTMEISTER_ICON = "https://raw.githubusercontent.com/kopylovis/agentmeister/main/docs/icon.png"
# До 1.29 токен публикации лежал здесь, аккаунтом был адрес сервера
PUBLISHER_SERVICE = "agentmeister.tossling"
KEYCHAIN_ACCOUNT = "tossling"
MODES = ("off", "away", "always")
BODIES = ("full", "title")


class AlertError(Exception):
    pass


def auth_header(token):
    """Токен ntfy (tk_...) идет как Bearer, пара логин:пароль как Basic."""
    if not token:
        return None
    if ":" in token and not token.startswith("tk_"):
        return "Basic " + base64.b64encode(token.encode()).decode()
    return f"Bearer {token}"


def post(server, token, payload):
    """JSON-публикация ntfy: POST на корень сервера, канал в поле topic."""
    headers = {"Content-Type": "application/json"}
    auth = auth_header(token)
    if auth:
        headers["Authorization"] = auth
    req = urllib.request.Request(server, data=json.dumps(payload).encode(), method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace").strip()
        if e.code in (401, 403):
            raise AlertError(f"сервер не пускает в канал {payload.get('topic')}: нужен доступ на запись (HTTP {e.code})")
        if e.code == 429:
            raise AlertError("сервер ограничил частоту отправки (HTTP 429)")
        raise AlertError(f"HTTP {e.code} {detail}".strip())
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise AlertError(f"нет связи с сервером: {getattr(e, 'reason', e)}")


def payload(topic, message, title="", priority=3, tags=None, click=None, markdown=False, icon=None):
    out = {"topic": topic, "message": message or title or "—", "priority": int(priority)}
    if icon:
        out["icon"] = icon
    if title:
        out["title"] = title
    if tags:
        out["tags"] = list(tags)
    if click:
        out["click"] = click
    if markdown:
        out["markdown"] = True
    return out


def tossling_config():
    path = tossling_path()
    if path:
        try:
            r = subprocess.run([path, "config", "--json"], capture_output=True, text=True, timeout=15)
            return json.loads(r.stdout or "{}")
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return {}
    for legacy in LEGACY_CONFIGS:
        try:
            with open(legacy) as f:
                return json.load(f)
        except (OSError, ValueError):
            continue
    return {}


def manual_server():
    return read_config().get("notify_tossling_server", "").rstrip("/")


def endpoint():
    """Сервер и токен. Адрес, заданный вручную, важнее адреса из tossling. Токен комнаты из tossling годится,
    только если сервер тот же."""
    conf = tossling_config()
    cli_server = conf.get("server", "").rstrip("/")
    server = manual_server() or cli_server
    token = conf.get("token", "") if server == cli_server else ""
    token = token or publisher_token(server)
    return (server, token) if server and token else None


def source():
    """Откуда настройки: manual, если адрес задан вручную, cli, если взят у tossling, иначе пусто."""
    if not configured():
        return ""
    return "manual" if manual_server() else "cli"


def configured():
    return endpoint() is not None


def publisher_token(server):
    return keychain.find(KEYCHAIN_ACCOUNT) or (keychain.find(server, PUBLISHER_SERVICE) if server else "")


def phone_mode():
    conf = read_config()
    value = conf.get("notify_tossling") or conf.get("notify_phone", "off")
    return value if value in ("away", "always") else "off"


def set_mode(value):
    write_config(notify_tossling=value, notify_phone=None)


def body_mode():
    value = read_config().get("notify_tossling_body", "full")
    return value if value in BODIES else "full"


def publish(topic, message, title="", priority=3, tags=None, click=None, markdown=False):
    target = endpoint()
    if not target:
        raise AlertError(f"Tossling на этом Mac не найден или не подключен к серверу. Как поставить: {INSTALL_DOCS}")
    server, token = target
    icon = None
    if topic == AGENTMEISTER_TOPIC:
        token = publisher_token(server) or token
        icon = AGENTMEISTER_ICON
    return post(server, token, payload(topic, message, title, priority, tags, click, markdown, icon))
