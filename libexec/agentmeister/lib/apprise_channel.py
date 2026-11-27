"""Канал Apprise (https://github.com/caronc/apprise): около сотни сервисов через команду apprise на этом Mac.
Адреса сервисов с их токенами agentmeister не хранит и не передает: apprise без адресов в аргументах берет их из
своего config (~/.config/apprise/apprise.yml и соседние пути), а текст уведомления читает из stdin. В аргументах
остаются только заголовок, тип и тег.

В config notify_apprise (off, away, always), notify_apprise_body (full или title, по умолчанию title: куда уйдет
текст, решает чужой config) и notify_apprise_tag (только сервисы с этим тегом)."""
import os
import re
import shutil
import subprocess

import ntfy_alert
from mnrhlib import HOME, read_config, tr, write_config

DOCS = "https://github.com/caronc/apprise/wiki/config"
# пути, которые apprise читает, когда адреса не переданы (apprise/cli.py, DEFAULT_CONFIG_PATHS)
CONFIGS = tuple(os.path.join(HOME, p) for p in (
    ".apprise", ".apprise.conf", ".apprise.yml", ".apprise.yaml",
    ".config/apprise", ".config/apprise.conf", ".config/apprise.yml", ".config/apprise.yaml",
    ".apprise/apprise", ".apprise/apprise.conf", ".apprise/apprise.yml", ".apprise/apprise.yaml",
    ".config/apprise/apprise", ".config/apprise/apprise.conf", ".config/apprise/apprise.yml",
    ".config/apprise/apprise.yaml"))
SEARCH = ("/opt/homebrew/bin", "/usr/local/bin", os.path.join(HOME, ".local", "bin"))
TAG_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")


class AppriseError(Exception):
    pass


def binary():
    found = shutil.which("apprise")
    if found:
        return found
    return next((p for p in (os.path.join(d, "apprise") for d in SEARCH) if os.access(p, os.X_OK)), None)


def config_file():
    return next((p for p in CONFIGS if os.path.isfile(p)), None)


def configured():
    return bool(binary()) and bool(config_file())


def mode():
    value = read_config().get("notify_apprise", "off")
    return value if value in ("away", "always") and configured() else "off"


def body_mode():
    value = read_config().get("notify_apprise_body", "title")
    return value if value in ntfy_alert.BODIES else "title"


def tag():
    value = read_config().get("notify_apprise_tag", "")
    return value if TAG_RE.match(value) else ""


def send(title, message, urgent=False):
    exe = binary()
    if not exe:
        raise AppriseError(tr("apprise не найден, brew install apprise", "apprise isn't installed, brew install apprise"))
    if not config_file():
        raise AppriseError(tr(f"нет config apprise со списком сервисов, {DOCS}", f"no apprise config with services, {DOCS}"))
    args = [exe, "-t", title, "-n", "warning" if urgent else "info"] + (["-g", tag()] if tag() else [])
    try:
        r = subprocess.run(args, input=message or title or "—", capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise AppriseError(f"apprise: {e}") from None
    if r.returncode != 0:
        tail = (r.stderr or r.stdout).strip().splitlines()[-1:] or [f"код {r.returncode}"]
        raise AppriseError(f"apprise: {tail[0][:200]}")
    return 0


def describe():
    if not binary():
        return tr("Apprise: не установлен, brew install apprise", "Apprise: not installed, brew install apprise")
    if not config_file():
        return tr(f"Apprise: нет config со списком сервисов, {DOCS}", f"Apprise: no config with services, {DOCS}")
    when = {"off": tr("выключен, agentmeister notify apprise away", "off, agentmeister notify apprise away"),
            "away": tr("когда ты не за Mac", "when you are away"), "always": tr("всегда", "always")}[mode()]
    body = tr("только заголовок", "title only") if body_mode() == "title" else tr("полный текст", "full text")
    tagged = tr(f", тег {tag()}", f", tag {tag()}") if tag() else ""
    return f"Apprise: {when}, {config_file().replace(HOME, '~')}, {body}{tagged}"


def usage(code=0):
    print(tr("agentmeister notify apprise away | always | off | test  через apprise и его config",
             "agentmeister notify apprise away | always | off | test  through apprise and its config"))
    print(tr("  … apprise body full | title   полный текст или только заголовок",
             "  … apprise body full | title   full text or title only"))
    print(tr("  … apprise tag <тег> | off      только сервисы с этим тегом в config apprise",
             "  … apprise tag <tag> | off      only services with this tag in the apprise config"))
    return code


def main(args):
    cmd = args[0] if args else ""
    if not cmd:
        print(describe())
        return 0
    if cmd in ("-h", "--help"):
        return usage()
    if cmd in ("on", "away", "always", "off", "setup") and len(args) == 1:
        if cmd != "off" and not configured():
            print(describe())
            return 1
        write_config(notify_apprise="off" if cmd == "off" else "away" if cmd in ("on", "setup") else cmd)
        print(describe())
        return 0
    if cmd == "body" and len(args) == 2 and args[1] in ntfy_alert.BODIES:
        write_config(notify_apprise_body=args[1])
        print(describe())
        return 0
    if cmd == "tag" and len(args) == 2:
        if args[1] != "off" and not TAG_RE.match(args[1]):
            print(tr("Тег: латинские буквы, цифры, - и _", "Tag: Latin letters, digits, - and _"))
            return 2
        write_config(notify_apprise_tag=None if args[1] == "off" else args[1])
        print(describe())
        return 0
    if cmd == "forget" and len(args) == 1:
        write_config(notify_apprise=None, notify_apprise_body=None, notify_apprise_tag=None)
        print(tr("Apprise выключен, config apprise не тронут", "Apprise off, the apprise config is untouched"))
        return 0
    if cmd == "test" and len(args) == 1:
        try:
            send(tr("Agentmeister: проверка канала", "Agentmeister: channel check"),
                 tr("Сюда приходят уведомления от Claude Code и Codex.", "Claude Code and Codex notifications arrive here."))
        except AppriseError as e:
            print(tr(f"Не отправил: {e}", f"Not sent: {e}"))
            return 1
        print(tr("apprise отправил пробное уведомление", "apprise sent a test notification"))
        return 0
    return usage(2)
