"""Обновить Claude Code или Codex тем способом, каким агент установлен.

Из Homebrew агент обновляет brew upgrade (claude update и codex update там ничего не ставят, а только
советуют brew). Из официального установщика, npm и других способов агент обновляет себя сам.
Способ определяется по настоящему пути бинарника, как в app-state.

agentmeister agent-update claude|codex   обновить и сказать, с какой версии на какую
agentmeister agent-update --print claude  только показать команду
agentmeister agent-update --check claude  JSON с текущей и последней версией, ничего не ставит
"""
import json
import os
import shutil
import subprocess
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import tr  # noqa: E402

AGENTS = ("claude", "codex")
# откуда брать последнюю версию у установки не из Homebrew
NPM = {"claude": "@anthropic-ai/claude-code", "codex": "@openai/codex"}
BREW_PATHS = ("/opt/homebrew/bin/brew", "/usr/local/bin/brew")


# Обертки, которые сами ищут агента дальше по PATH: по метке в тексте скрипта. Обертки pnpm, nix и старый
# ~/.claude/local/claude это и есть установленный агент, их не пропускаем.
SHIM_MARKS = (b"promptsill",)


def is_shim(path):
    """Известная обертка-скрипт перед настоящим агентом, например codex от promptsill в ~/.local/bin."""
    real = os.path.realpath(path)
    try:
        with open(real, "rb") as f:
            head = f.read(65536)
    except OSError:
        return False
    return head[:2] == b"#!" and any(mark in head for mark in SHIM_MARKS)


def binary_path(agent):
    """Бинарник агента из PATH, обертки пропускаются, если дальше по PATH есть сам агент. Claude Code можно
    подменить через MNRH_CLAUDE_BIN, как во всем agentmeister."""
    name = os.environ.get("MNRH_CLAUDE_BIN", "claude") if agent == "claude" else agent
    if os.sep in name:
        return name if os.access(name, os.X_OK) else None
    found, seen = [], set()
    for directory in os.get_exec_path():
        candidate = os.path.join(directory or ".", name)
        real = os.path.realpath(candidate)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK) and real not in seen:
            seen.add(real)
            found.append(candidate)
    return next((c for c in found if not is_shim(c)), found[0] if found else None)


# пакеты Homebrew самих агентов; mise или volta из Homebrew, через которые агент поставлен, агентом не считаются
BREW_TOKENS = {"claude": ("claude-code",), "codex": ("codex",)}


def brew_package(real, agent=None):
    """(имя, cask ли) пакета Homebrew по настоящему пути бинарника, иначе None. С agent только пакет этого агента."""
    parts = real.split(os.sep)
    for marker, cask in (("Caskroom", True), ("Cellar", False)):
        if marker in parts:
            index = parts.index(marker)
            if index + 1 < len(parts) and parts[index + 1]:
                name = parts[index + 1]
                if agent and not any(name == t or name.startswith(t + "@") for t in BREW_TOKENS.get(agent, ())):
                    return None
                return name, cask
    return None


def installed_via(agent, path):
    """homebrew, installer (официальный установщик Claude Code в ~/.local), npm или other."""
    real = os.path.realpath(path)
    if brew_package(real, agent):
        return "homebrew"
    if "node_modules" in real.split(os.sep):
        return "npm"
    if agent == "claude" and "/.local/" in real:
        return "installer"
    return "other"


def nested_sandbox_ok():
    """Можно ли поставить песочницу macOS: внутри sandbox-exec нельзя, и brew upgrade там падает."""
    try:
        return subprocess.run(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true"],
                              capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return True


def brew():
    return shutil.which("brew") or next((p for p in BREW_PATHS if os.access(p, os.X_OK)), "brew")


def update_argv(agent, path=None):
    """Команда обновления. Без бинарника None."""
    path = path or binary_path(agent)
    if not path:
        return None
    package = brew_package(os.path.realpath(path), agent)
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
    if os.path.basename(argv[0]) == "brew" and not nested_sandbox_ok():
        # внутри песочницы proxy-сессии brew не распакует архив: его песочница не встанет внутрь нашей
        command = "brew " + " ".join(argv[1:])
        print(tr(f"{agent}: brew upgrade не работает внутри песочницы proxy-сессии. Обнови снаружи: ⌘R во вкладке "
                 f"Agentmeister или {command} в обычном терминале",
                 f"{agent}: brew upgrade can't run inside a proxied session's sandbox. Update from outside: ⌘R in an "
                 f"Agentmeister tab or {command} in a regular terminal"), file=sys.stderr)
        return 1
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


def parse_version(text):
    """(числа версии, 1 у выпуска или 0 у предварительной), None без версии. "1.2.3-rc1" дает ((1, 2, 3), 0):
    предварительная версия младше выпуска с теми же числами. "2.1.325 (Claude Code)" дает ((2, 1, 325), 1)."""
    word = str(text or "").strip().split(",")[0].split()[0] if str(text or "").strip() else ""
    numbers, release = [], 1
    for piece in word.split("."):
        digits = ""
        for c in piece:
            if not c.isdigit():
                break
            digits += c
        if not digits:
            break
        numbers.append(int(digits))
        if digits != piece:  # -rc1, b4, -alpha: дальше уже не номер выпуска
            release = 0
            break
    return (tuple(numbers), release) if numbers else None


def fetch_json(url):
    # urllib берет HTTPS_PROXY из окружения, под agentmeister proxy run запрос идет через mihomo
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "agentmeister"})
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.loads(response.read(2_000_000))


def latest_version(agent, path):
    """Последняя версия там, откуда агент ставится: API Homebrew для cask и формул, иначе npm."""
    package = brew_package(os.path.realpath(path), agent)
    if package:
        name, cask = package
        if cask:
            return str(fetch_json(f"https://formulae.brew.sh/api/cask/{name}.json")["version"]).split(",")[0]
        return str(fetch_json(f"https://formulae.brew.sh/api/formula/{name}.json")["versions"]["stable"])
    return str(fetch_json(f"https://registry.npmjs.org/{NPM[agent]}/{npm_channel(agent)}")["version"])


def npm_channel(agent):
    """Метка npm, которую ставит само обновление: у Claude Code autoUpdatesChannel stable или latest."""
    if agent != "claude":
        return "latest"
    try:
        with open(os.path.join(os.path.expanduser("~"), ".claude", "settings.json")) as f:
            channel = json.load(f).get("autoUpdatesChannel")
    except (OSError, ValueError, AttributeError):
        return "latest"
    return "stable" if channel == "stable" else "latest"


def check(agent):
    """Есть ли новая версия. JSON в stdout, ошибка сети или источника в поле error."""
    path = binary_path(agent)
    out = {"agent": agent, "installed": bool(path), "current": None, "latest": None, "update": False, "error": None}
    if path:
        out["current"] = version(path)
        out["via"] = installed_via(agent, path)
        try:
            out["latest"] = latest_version(agent, path)
            latest, current = parse_version(out["latest"]), parse_version(out["current"])
            # без своей версии сравнивать не с чем: обновление не предлагаем
            out["update"] = bool(latest and current and latest > current)
        except Exception as e:  # noqa: BLE001 — сеть, HTTP и разбор ответа: приложение ждет JSON в любом случае
            out["error"] = str(e) or e.__class__.__name__
    print(json.dumps(out))
    return 0


def main(argv):
    show = "--print" in argv
    if "--check" in argv:
        rest = [a for a in argv if a != "--check"]
        if len(rest) != 1 or rest[0] not in AGENTS:
            print("agentmeister agent-update --check claude|codex", file=sys.stderr)
            return 2
        return check(rest[0])
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
