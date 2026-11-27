"""Ты за Mac или нет. Каналы на телефон в режиме away шлют, только когда экран заблокирован или мышь и клавиатура
не трогались notify_away секунд. Порог общий для всех каналов. Раньше он жил в настройке Telegram (telegram_away),
ее значение читается, пока notify_away не задан."""
import re
import subprocess

from mnrhlib import read_config, write_config

DEFAULT_AWAY = 120


def away_after():
    conf = read_config()
    raw = conf.get("notify_away") or conf.get("telegram_away") or DEFAULT_AWAY
    try:
        return max(0, int(raw))
    except ValueError:
        return DEFAULT_AWAY


def set_away_after(seconds):
    write_config(notify_away=str(max(0, int(seconds))), telegram_away=None)


def idle_seconds():
    try:
        out = subprocess.run(["ioreg", "-c", "IOHIDSystem", "-d", "4"], capture_output=True, text=True,
                             timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return 0
    m = re.search(r'"HIDIdleTime" = (\d+)', out)
    return int(m.group(1)) / 1e9 if m else 0


def screen_locked():
    try:
        r = subprocess.run("ioreg -n Root -d1 -a | plutil -extract IOConsoleLocked raw -o - -", shell=True,
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return r.stdout.strip() == "true"


def away():
    return screen_locked() or idle_seconds() >= away_after()
