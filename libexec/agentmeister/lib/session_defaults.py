"""Умолчания для сессий, которые agentmeister открывает сам (open_claude, /parallel, меню) и перезапускает.

Строки в ~/.config/agentmeister/config:
  open_mode=caffeinate|normal       режим новой сессии, по умолчанию normal
  open_remote_control=on|off        Remote Control в новых сессиях, по умолчанию off
  restart_update=on|off             /restart сначала обновляет Claude Code, по умолчанию on
  ask_model=sonnet|opus|haiku       модель для /ask, по умолчанию sonnet
  compact_hint_k=50..1000           с какого контекста (тыс. токенов) /slim и приложение советуют /compact, 200

agentmeister defaults показывает их, agentmeister defaults <ключ> <значение> меняет."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import config_int, read_config, tr, write_config  # noqa: E402

# ключ команды: (строка в config, допустимые значения, умолчание)
KEYS = {
    "mode": ("open_mode", ("caffeinate", "normal"), "normal"),
    "remote-control": ("open_remote_control", ("on", "off"), "off"),
    "restart-update": ("restart_update", ("on", "off"), "on"),
    "ask-model": ("ask_model", ("sonnet", "opus", "haiku"), "sonnet"),
}


# числовые: (строка в config, от, до, умолчание)
NUMBERS = {"compact-hint": ("compact_hint_k", 50, 1000, 200)}


def compact_hint():
    """Порог подсказки о /compact в токенах."""
    name, low, high, default = NUMBERS["compact-hint"]
    return config_int(name, default, low, high) * 1000


def value(key):
    name, allowed, default = KEYS[key]
    v = read_config().get(name, "").strip().lower()
    return v if v in allowed else default


def open_mode():
    return value("mode")


def remote_control():
    return value("remote-control") == "on"


def restart_update():
    return value("restart-update") == "on"


def ask_model():
    return value("ask-model")


def state():
    return {"mode": open_mode(), "remoteControl": remote_control(), "restartUpdate": restart_update(),
            "askModel": ask_model(), "compactHintK": compact_hint() // 1000}


USAGE_RU = """agentmeister defaults                         текущие умолчания
agentmeister defaults mode caffeinate|normal   режим сессий, которые открывают open_claude, /parallel и меню
agentmeister defaults remote-control on|off    Remote Control в таких сессиях
agentmeister defaults restart-update on|off    /restart сначала обновляет Claude Code
agentmeister defaults ask-model sonnet|opus|haiku  модель для /ask
agentmeister defaults compact-hint 50..1000    с какого контекста (тыс. токенов) советовать /compact"""
USAGE_EN = """agentmeister defaults                         current defaults
agentmeister defaults mode caffeinate|normal   mode of sessions opened by open_claude, /parallel and the menu
agentmeister defaults remote-control on|off    Remote Control in those sessions
agentmeister defaults restart-update on|off    /restart updates Claude Code first
agentmeister defaults ask-model sonnet|opus|haiku  model for /ask
agentmeister defaults compact-hint 50..1000    from what context size (thousand tokens) to suggest /compact"""


def main(args):
    if args[:1] in (["-h"], ["--help"]):
        print(tr(USAGE_RU, USAGE_EN))
        return 0
    if not args:
        for key in KEYS:
            print(f"{key:<15} {value(key)}")
        print(f"{'compact-hint':<15} {compact_hint() // 1000}")
        return 0
    if len(args) == 2 and args[0] in NUMBERS:
        name, low, high, default = NUMBERS[args[0]]
        if not args[1].isdigit() or not low <= int(args[1]) <= high:
            print(tr(f"{args[0]}: число от {low} до {high}", f"{args[0]}: a number from {low} to {high}"), file=sys.stderr)
            return 2
        write_config(**{name: None if int(args[1]) == default else args[1]})
        print(f"{args[0]} {compact_hint() // 1000}")
        return 0
    if len(args) != 2 or args[0] not in KEYS:
        print(tr(USAGE_RU, USAGE_EN), file=sys.stderr)
        return 2
    key, v = args[0], args[1].lower()
    name, allowed, default = KEYS[key]
    if v not in allowed:
        print(tr(f"{key}: можно {', '.join(allowed)}", f"{key}: one of {', '.join(allowed)}"), file=sys.stderr)
        return 2
    # значение по умолчанию убирает строку из config, как lang auto
    write_config(**{name: None if v == default else v})
    print(f"{key} {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[2:] if sys.argv[1:2] == ["defaults"] else sys.argv[1:]))
