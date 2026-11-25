"""Обновить Claude Code или Codex тем способом, каким агент установлен.

Из Homebrew агент обновляет brew upgrade (claude update и codex update там ничего не ставят, а только
советуют brew). Из официального установщика, npm и других способов агент обновляет себя сам.
Способ определяется по настоящему пути бинарника, как в app-state.

agentmeister agent-update claude|codex   обновить и сказать, с какой версии на какую
agentmeister agent-update --print claude  только показать команду
"""
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import tr  # noqa: E402

AGENTS = ("claude", "codex")
BREW_PATHS = ("/opt/homebrew/bin/brew", "/usr/local/bin/brew")


def binary_path(agent):
    """Бинарник агента из PATH. Claude Code можно подменить через MNRH_CLAUDE_BIN, как во всем agentmeister."""
    name = os.environ.get("MNRH_CLAUDE_BIN", "claude") if agent == "claude" else agent
    return shutil.which(name)


def brew_package(real):
    """(имя, cask ли) пакета Homebrew по настоящему пути бинарника, иначе None."""
    parts = real.split(os.sep)
    for marker, cask in (("Caskroom", True), ("Cellar", False)):
        if marker in parts:
            index = parts.index(marker)
            if index + 1 < len(parts) and parts[index + 1]:
                return parts[index + 1], cask
    return None


def installed_via(agent, path):
    """homebrew, installer (официальный установщик Claude Code в ~/.local) или other."""
    real = os.path.realpath(path)
    if brew_package(real) or real.startswith("/opt/homebrew/"):
        return "homebrew"
    if agent == "claude" and "/.local/" in real:
        return "installer"
    return "other"


def brew():
    return shutil.which("brew") or next((p for p in BREW_PATHS if os.access(p, os.X_OK)), "brew")


def update_argv(agent, path=None):
    """Команда обновления. Без бинарника None."""
    path = path or binary_path(agent)
    if not path:
        return None
    package = brew_package(os.path.realpath(path))
    if package:
        name, cask = package
        return [brew(), "upgrade"] + (["--cask"] if cask else []) + [name]
    return [path, "update"]


def version(path):
    try:
        out = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=20).stdout.split()
    except (OSError, subprocess.SubprocessError):
        return None
    return next((w for w in out if w[:1].isdigit()), None)


def update(agent):
    """Обновить агента, вывод команды идет как есть, в конце строка с итогом. Код выхода команды."""
    path = binary_path(agent)
    argv = update_argv(agent, path)
    if not argv:
        print(tr(f"{agent} не найден в PATH", f"{agent} isn't in PATH"), file=sys.stderr)
        return 127
    before = version(path)
    print("$ " + " ".join(argv), flush=True)
    try:
        code = subprocess.run(argv).returncode
    except OSError as e:
        print(tr(f"не запустил {argv[0]}: {e}", f"couldn't start {argv[0]}: {e}"), file=sys.stderr)
        return 127
    after = version(binary_path(agent) or path)
    if code != 0:
        print(tr(f"{agent}: обновление не прошло (код {code}), осталась {before or '?'}",
                 f"{agent}: update failed (exit {code}), still {before or '?'}"))
    elif before and after and before != after:
        print(tr(f"{agent}: обновлен с {before} до {after}", f"{agent}: updated from {before} to {after}"))
    else:
        print(tr(f"{agent}: последняя версия {after or before or '?'}", f"{agent}: up to date, {after or before or '?'}"))
    return code


def main(argv):
    show = "--print" in argv
    args = [a for a in argv if a != "--print"]
    if len(args) != 1 or args[0] not in AGENTS:
        print("agentmeister agent-update [--print] claude|codex", file=sys.stderr)
        return 2
    if show:
        command = update_argv(args[0])
        if not command:
            return 127
        print(" ".join(command))
        return 0
    return update(args[0])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
