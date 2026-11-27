"""Канал Bark: push на iPhone через APNs без своего приложения (https://github.com/Finb/Bark). Ключ Apple
держит сервер Bark, публичный api.day.app или свой bark-server. В config notify_bark (off, away, always),
notify_bark_server и notify_bark_body (full или title). Ключ устройства лежит в Связке ключей
(agentmeister.notify, аккаунт bark).

Шифрование (bark encrypt on): заголовок и текст уходят AES-256-CBC с PKCS7 в поле ciphertext, со случайным IV
в каждом push. Сервер Bark и APNs видят только ключ устройства и уровень уведомления. Ключ шифрования
(32 символа) лежит в Связке ключей (аккаунт bark-key), его же вводят в приложении Bark."""
import base64
import json
import secrets
import string
import subprocess
import urllib.error
import urllib.parse
import urllib.request

import keychain
import ntfy_alert
from mnrhlib import read_config, tr, write_config

DEFAULT_SERVER = "https://api.day.app"
PUBLIC_HOSTS = ("api.day.app",)
ACCOUNT = "bark"
CRYPTO_ACCOUNT = "bark-key"
GROUP = "Agentmeister"
ALPHABET = string.ascii_letters + string.digits
KEY_LEN = 32  # AES-256
IV_LEN = 16   # CBC


class BarkError(Exception):
    pass


def server():
    return (read_config().get("notify_bark_server") or DEFAULT_SERVER).rstrip("/")


def device_key():
    return keychain.find(ACCOUNT)


def crypto_key():
    value = keychain.find(CRYPTO_ACCOUNT)
    return value if len(value) == KEY_LEN else ""


def public():
    return urllib.parse.urlparse(server()).hostname in PUBLIC_HOSTS


def configured():
    return bool(device_key())


def mode():
    # сначала config: хук зовет mode() на каждое событие, а Связку ключей трогаем, только если канал включен
    value = read_config().get("notify_bark", "off")
    return value if value in ("away", "always") and configured() else "off"


def body_mode():
    value = read_config().get("notify_bark_body", "")
    if value in ntfy_alert.BODIES:
        return value
    # зашифрованный текст сервер не прочитает, на свой сервер можно и так
    return "title" if public() and not crypto_key() else "full"


def random_text(n):
    return "".join(secrets.choice(ALPHABET) for _ in range(n))


def encrypt(data, key, iv):
    """AES-256-CBC с PKCS7 через системный openssl, как в примере из документации Bark. Ключ и IV там
    строки ASCII, openssl ждет их в hex."""
    try:
        r = subprocess.run(["/usr/bin/openssl", "enc", "-aes-256-cbc", "-K", key.encode().hex(), "-iv", iv.encode().hex()],
                           input=data.encode(), capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise BarkError(f"openssl не запустился: {e}") from None
    if r.returncode != 0:
        raise BarkError(f"openssl: {r.stderr.decode(errors='replace').strip()}")
    return base64.b64encode(r.stdout).decode()


def request(title, body, urgent=False):
    """Тело POST /push. Без шифрования заголовок и текст идут открыто, с ним внутри ciphertext."""
    content = {"title": title, "body": body or title or "—", "group": GROUP, "icon": ntfy_alert.AGENTMEISTER_ICON}
    out = {"device_key": device_key(), "level": "timeSensitive" if urgent else "active"}
    key = crypto_key()
    if key:
        iv = random_text(IV_LEN)
        out.update(ciphertext=encrypt(json.dumps(content, ensure_ascii=False), key, iv), iv=iv)
    else:
        out.update(content)
    return out


def send(title, body, urgent=False):
    if not configured():
        raise BarkError(tr("Bark не подключен: agentmeister notify bark setup", "Bark isn't connected: agentmeister notify bark setup"))
    req = urllib.request.Request(server() + "/push", data=json.dumps(request(title, body, urgent)).encode(), method="POST",
                                 headers={"Content-Type": "application/json; charset=utf-8"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status
    except urllib.error.HTTPError as e:
        try:
            detail = json.loads(e.read().decode(errors="replace")).get("message", "")
        except ValueError:
            detail = ""
        if "device token" in detail or "device key" in detail:
            raise BarkError(f"HTTP {e.code}, сервер не знает этот ключ устройства. Скопируй ключ заново в приложении Bark") from None
        raise BarkError(f"HTTP {e.code} {detail}".strip()) from None
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise BarkError(f"нет связи с сервером Bark: {getattr(e, 'reason', e)}") from None


def parse_key(text):
    """Ключ устройства или адрес из приложения Bark вида https://api.day.app/<ключ>/текст. Возвращает
    (сервер или None, ключ)."""
    text = text.strip()
    if "://" not in text:
        return None, text.strip("/")
    parsed = urllib.parse.urlparse(text)
    parts = [p for p in parsed.path.split("/") if p]
    if not parsed.hostname or not parts:
        return None, ""
    return f"{parsed.scheme}://{parsed.netloc}", parts[0]


def describe():
    if not configured():
        return tr("Bark: не подключен, agentmeister notify bark setup", "Bark: not connected, agentmeister notify bark setup")
    when = {"off": tr("выключен", "off"), "away": tr("когда ты не за Mac", "when you are away"),
            "always": tr("всегда", "always")}[mode()]
    body = tr("только заголовок", "title only") if body_mode() == "title" else tr("полный текст", "full text")
    crypto = tr("шифрование AES-256", "AES-256 encryption") if crypto_key() else tr("без шифрования", "not encrypted")
    return f"Bark: {when}, {server()}, {body}, {crypto}"


def explain_crypto():
    print(tr("В приложении Bark открой Push Encryption, выбери AES256, CBC и pkcs7 и введи", "In the Bark app open Push "
             "Encryption, pick AES256, CBC and pkcs7 and enter"))
    print(f"  Key {crypto_key()}")
    print(f"  IV  {read_config().get('notify_bark_iv', '')}")
    print(tr("IV из настроек приложения нужен только для сохранения, в каждом push приходит свой.",
             "The IV in the app settings is only needed to save them, every push carries its own."))


def setup(args):
    if len(args) > 1:
        return usage(2)
    text = args[0] if args else keychain.read_secret(tr("Ключ устройства или адрес из приложения Bark (при вводе не виден): ",
                                                        "Device key or the URL from the Bark app (hidden): "))
    srv, key = parse_key(text)
    if not key or any(c not in ALPHABET + "-_" for c in key):
        print(tr("Не похоже на ключ Bark. Он есть на главном экране приложения, в адресе вида https://api.day.app/<ключ>/",
                 "Not a Bark key. It is on the main screen of the app, in a URL like https://api.day.app/<key>/"))
        return 2
    if not keychain.save(ACCOUNT, key, "Agentmeister Bark device"):
        print(tr("Не сохранил ключ в Связку ключей", "Couldn't save the key to the keychain"))
        return 1
    values = {}
    if srv:
        values["notify_bark_server"] = None if srv == DEFAULT_SERVER else srv
    if read_config().get("notify_bark", "off") == "off":
        values["notify_bark"] = "away"
    write_config(**values)
    print(describe())
    if public() and not crypto_key():
        print(tr("Через api.day.app по умолчанию уходит только заголовок. Чтобы слать полный текст так, что сервер его не "
                 "прочитает: agentmeister notify bark encrypt on",
                 "Only the title goes through api.day.app by default. To send the full text so the server can't read it: "
                 "agentmeister notify bark encrypt on"))
    return 0


def usage(code=0):
    print(tr("agentmeister notify bark setup [<ключ или адрес>]  подключить iPhone с приложением Bark, без аргумента из stdin",
             "agentmeister notify bark setup [<key or URL>]  connect an iPhone with the Bark app, without an argument from stdin"))
    print(tr("  … bark away | always | off | test", "  … bark away | always | off | test"))
    print(tr("  … bark body full | title    полный текст или только заголовок", "  … bark body full | title    full text or title only"))
    print(tr("  … bark encrypt on | off     шифровать AES-256, ключ показывается для приложения Bark",
             "  … bark encrypt on | off     encrypt with AES-256, prints the key for the Bark app"))
    print(tr("  … bark server <url> | auto  свой bark-server или снова api.day.app",
             "  … bark server <url> | auto  your own bark-server or api.day.app again"))
    print(tr("  … bark forget               забыть ключи и настройки", "  … bark forget               forget keys and settings"))
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
        print(tr("Сначала agentmeister notify bark setup", "Run agentmeister notify bark setup first"))
        return 1
    if cmd in ("on", "away", "always", "off") and len(args) == 1:
        write_config(notify_bark="away" if cmd == "on" else cmd)
        print(describe())
        return 0
    if cmd == "body" and len(args) == 2 and args[1] in ntfy_alert.BODIES:
        write_config(notify_bark_body=args[1])
        print(describe())
        return 0
    if cmd == "encrypt" and len(args) == 2 and args[1] in ("on", "off"):
        if args[1] == "off":
            keychain.delete(CRYPTO_ACCOUNT)
            write_config(notify_bark_iv=None)
            print(describe())
            print(tr("В приложении Bark шифрование тоже выключи, иначе push придет как Decryption Failed",
                     "Turn encryption off in the Bark app too, or pushes arrive as Decryption Failed"))
            return 0
        if not crypto_key():
            if not keychain.save(CRYPTO_ACCOUNT, random_text(KEY_LEN), "Agentmeister Bark encryption"):
                print(tr("Не сохранил ключ в Связку ключей", "Couldn't save the key to the keychain"))
                return 1
            write_config(notify_bark_iv=random_text(IV_LEN))
        print(describe())
        explain_crypto()
        return 0
    if cmd == "server" and len(args) == 2:
        url = args[1].rstrip("/")
        if url == "auto":
            write_config(notify_bark_server=None)
        elif urllib.parse.urlparse(url).scheme in ("http", "https") and urllib.parse.urlparse(url).hostname:
            write_config(notify_bark_server=url)
        else:
            print(tr(f"Не похоже на адрес сервера: {url}", f"Not a server address: {url}"))
            return 2
        print(describe())
        return 0
    if cmd == "forget" and len(args) == 1:
        keychain.delete(ACCOUNT)
        keychain.delete(CRYPTO_ACCOUNT)
        write_config(notify_bark=None, notify_bark_server=None, notify_bark_body=None, notify_bark_iv=None)
        print(tr("Bark отключен, ключи и настройки удалены", "Bark disconnected, keys and settings removed"))
        return 0
    if cmd == "test" and len(args) == 1:
        try:
            send(tr("Agentmeister: проверка канала", "Agentmeister: channel check"),
                 tr("Сюда приходят уведомления от Claude Code и Codex.", "Claude Code and Codex notifications arrive here."))
        except BarkError as e:
            print(tr(f"Не отправил: {e}", f"Not sent: {e}"))
            return 1
        print(tr("Отправил пробное уведомление", "Sent a test notification"))
        return 0
    return usage(2)
