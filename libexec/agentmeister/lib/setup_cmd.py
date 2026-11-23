"""Настройка команд, хуков и MCP для Claude Code."""
import json
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import CLAUDE_HOME, CM, HOME, PROMPTSILL_HINT, ROOT, STATUS_CMD, is_hook, promptsill_path, tilde  # noqa: E402
from claude_proc import CLAUDE_BIN  # noqa: E402
import claude_settings  # noqa: E402
from mcp_server import MCP_NAME, READ_ONLY, tools  # noqa: E402
from slash import EXTRA_COMMANDS, EXTRA_SLASH, FORGET_SLASH, FRESH_SLASH, SLASH, SLIM_SLASH  # noqa: E402

COMMANDS = os.path.join(CLAUDE_HOME, "commands")
COMMAND_FILE = os.path.join(COMMANDS, "restart.md")
FORGET_FILE = os.path.join(COMMANDS, "forget.md")
FRESH_FILE = os.path.join(COMMANDS, "fresh.md")
OLD_FORGET_FILE = os.path.join(COMMANDS, "forget-session.md")
SLIM_FILE = os.path.join(COMMANDS, "slim.md")
SETTINGS = claude_settings.PATH
# Так MCP-сервер назывался, пока claudemeister был частью mnrh (mnrh claude mcp). setup его убирает.
OLD_MCP_NAMES = ("mnrh", "claudemeister")
# Строка хука перезапуска в ~/.zshrc: новая, до переименования в agentmeister и та, что ставил mnrh
ZSH_MARKERS = ("share/agentmeister/restart.zsh", "share/claudemeister/restart.zsh", "share/mnrh/restart.zsh")
ZSHRC = os.path.join(os.environ.get("ZDOTDIR") or HOME, ".zshrc")
CODEX_SETUP = "agentmeister --harness codex setup"


def is_zsh_hook(line):
    return any(m in line for m in ZSH_MARKERS)


def hook_file():
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__)))))
    m = re.match(r"(.*)/Cellar/(agentmeister|claudemeister)/[^/]+/(.*)", root)
    if m:
        root = f"{m.group(1)}/opt/{m.group(2)}/{m.group(3)}"
    return os.path.join(root, "share", "agentmeister", "restart.zsh")


def zshrc_lines():
    try:
        with open(ZSHRC) as f:
            return f.read().splitlines(keepends=True)
    except OSError:
        return []


def write_zshrc(lines):
    with open(ZSHRC, "w") as f:
        f.writelines(lines)


def install_restart_hook():
    hook = hook_file()
    line = f'[ -f "{hook}" ] && source "{hook}"\n'
    lines = zshrc_lines()
    if line in lines:
        print(f"✓ хук перезапуска уже в {tilde(ZSHRC)}")
        return
    lines = [l for l in lines if not is_zsh_hook(l)]
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    write_zshrc(lines + [line])
    print(f"✓ хук перезапуска → {tilde(ZSHRC)} (работает в новых вкладках терминала)")


def rename_rule(rule, names):
    for name in names:
        prefix = f"mcp__{name}"
        if rule == prefix or rule.startswith(prefix + "__"):
            return "mcp__" + MCP_NAME + rule[len(prefix):]
    if "claudemeister" in names:
        return re.sub(r"^Bash\(claudemeister(?=[ ):])", "Bash(agentmeister", rule)
    return rule


def notice_hook(install, rename_rules=()):
    try:
        settings = claude_settings.load()
    except ValueError as e:
        print(f"✗ {tilde(SETTINGS)} не читается как JSON ({e}), хуки Claude Code не трогаю")
        return
    claude_settings.ensure_hooks(settings, install)
    retention = claude_settings.ensure_retention(settings, install)
    line = settings.get("statusLine")
    command = claude_settings.statusline_command(settings)
    ours = is_hook(command, STATUS_CMD) or "promptsill" in command
    promptsill = promptsill_path()
    # без promptsill заглушка statusline остается, но уже agentmeister, а не mnrh claude
    claude_settings.ensure_statusline(settings, promptsill, install)
    status_note = ("! строка состояния: у тебя уже своя statusLine, не трогаю" if line and not ours else
                   "✓ строка состояния: promptsill уже стоит в statusLine" if "promptsill" in command else
                   "✓ строка состояния → statusLine (promptsill)" if promptsill else
                   f"! строка состояния теперь отдельная программа promptsill: {PROMPTSILL_HINT}, "
                   "потом снова agentmeister setup")
    allow_rules = [f"mcp__{MCP_NAME}__{name}" for name in READ_ONLY]
    # разрешения старого MCP-сервера mnrh тоже убираем: инструменты теперь у agentmeister
    old_rules = {f"mcp__{server}__{name}" for server in rename_rules for name in READ_ONLY + ["mac_status", "free_memory"]}
    perms = settings.setdefault("permissions", {})
    if rename_rules:
        for key in ("allow", "ask", "deny"):
            if isinstance(perms.get(key), list):
                perms[key] = list(dict.fromkeys(rename_rule(r, rename_rules) for r in perms[key]))
    allow = [r for r in perms.get("allow", []) if r not in allow_rules and r not in old_rules] + \
        (allow_rules if install else [])
    if allow:
        perms["allow"] = allow
    else:
        perms.pop("allow", None)
    if not perms:
        settings.pop("permissions")
    claude_settings.save_atomic(settings)
    if install:
        print(f"✓ сообщения после /restart и /forget, удаление пустых сессий → хуки SessionStart и SessionEnd "
              f"в {tilde(SETTINGS)}")
        print(status_note)
        print("✓ guard: вопрос перед чтением и удалением ключей и перед необратимыми командами (reset --hard, "
              "push --force, rm -r вне проекта…) → хук PreToolUse (agentmeister guard)")
        print("✓ длинный вывод сборок и тестов: Claude видит выжимку, полный лог в ~/.cache/mnrh/logs, в iTerm2 "
              "идущая сборка подписана во вкладке → хуки PreToolUse, PostToolUse и PostToolUseFailure "
              "(agentmeister buildlog)")
        print("✓ уведомления, когда Claude ждёт тебя → хуки UserPromptSubmit, Stop и Notification "
              "(agentmeister notify -h)")
        print("✓ humanize → хуки SessionStart, UserPromptSubmit и Stop. Включить через /humanize "
              "или agentmeister humanize on")
        print(f"✓ без вопроса о разрешении: {', '.join(READ_ONLY)} (они только читают)")
        days = settings.get("cleanupPeriodDays")
        print(f"✓ переписки хранятся {claude_settings.RETENTION_DAYS} дней вместо 30 → cleanupPeriodDays"
              if retention else f"✓ переписки хранятся {days} дней (cleanupPeriodDays, твое значение)")


SETUP_USAGE = f"""agentmeister setup [--country KZ] [--only <имя>]
    поставить команды /restart, /forget и другие, хуки Claude Code, хук zsh, MCP-сервер agentmeister
    и настроить прокси, если он еще не настроен. --country и --only уходят в agentmeister proxy setup
agentmeister setup --remove    убрать настройку Claude Code
{CODEX_SETUP}    настроить хуки и MCP для Codex"""


def setup_args(args):
    """{'remove': bool, 'country': str, 'only': str} или None с ошибкой в stderr."""
    opts, it = {"remove": False, "country": "", "only": ""}, iter(args)
    for a in it:
        if a == "--remove":
            opts["remove"] = True
        elif a in ("--country", "--only"):
            value = next(it, "").strip()
            if not value or value.startswith("-"):
                print(f"agentmeister setup: после {a} нужно значение\n\n{SETUP_USAGE}", file=sys.stderr)
                return None
            opts[a[2:]] = value
        else:
            print(f"agentmeister setup: не знаю {a}\n\n{SETUP_USAGE}", file=sys.stderr)
            return None
    if opts["country"] and not re.match(r"^[A-Za-z]{2}$", opts["country"]):
        print("agentmeister setup: --country ждет код страны из двух букв, например KZ", file=sys.stderr)
        return None
    return opts


def mcp_get(name):
    """(подключен ли MCP-сервер name, [команда, аргументы...]) по выводу claude mcp get."""
    r = subprocess.run([CLAUDE_BIN, "mcp", "get", name], capture_output=True, text=True)
    if r.returncode != 0:
        return False, []
    command = re.search(r"^\s*Command:\s*(.+?)\s*$", r.stdout, re.M)
    args = re.search(r"^\s*Args:\s*(.*?)\s*$", r.stdout, re.M)
    return True, ([command.group(1)] if command else []) + (args.group(1).split() if args else [])


def configure_mcp(remove=False):
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or HOME
    path = os.path.join(config_dir, ".claude.json")
    try:
        with open(path) as stream:
            servers = json.load(stream).get("mcpServers", {})
    except FileNotFoundError:
        servers = {}
    entries = {}
    names = []
    for name in (*OLD_MCP_NAMES, MCP_NAME):
        entry = servers.get(name)
        if entry is None:
            if name in OLD_MCP_NAMES:
                names.append(name)
            continue
        binary = os.path.basename(entry.get("command") or "")
        if name == "mnrh":
            owned = binary == "mnrh" and entry.get("args") == ["claude", "mcp"]
        else:
            owned = binary in ("agentmeister", "claudemeister") and entry.get("args") == ["mcp"]
        if not owned:
            if name == MCP_NAME and not remove:
                raise ValueError(f"MCP {MCP_NAME} already exists with a different command")
            continue
        entries[name] = entry
        if name in OLD_MCP_NAMES:
            names.append(name)
    if not remove:
        configs = [dict(value, type="stdio", command=CM, args=["mcp"]) for value in entries.values()]
        if any(dict(config, env=config.get("env") or {}) != dict(configs[0], env=configs[0].get("env") or {})
               for config in configs[1:]):
            raise ValueError("Existing MCP registrations have different settings")
        if MCP_NAME not in entries:
            config = configs[0] if configs else {"command": CM, "args": ["mcp"], "type": "stdio"}
            subprocess.run([CLAUDE_BIN, "mcp", "add-json", "--scope", "user", MCP_NAME, json.dumps(config)],
                           check=True, stdout=subprocess.DEVNULL)
        elif os.path.basename(entries[MCP_NAME]["command"]) != "agentmeister":
            raise ValueError(f"Update the command for MCP {MCP_NAME} to {CM} mcp")
    for name in entries:
        if remove or name != MCP_NAME:
            subprocess.run([CLAUDE_BIN, "mcp", "remove", "--scope", "user", name], check=True,
                           stdout=subprocess.DEVNULL)
    return names


def setup(args):
    import claude_setup
    if any(a in ("-h", "--help", "help") for a in args):
        print(SETUP_USAGE)
        return 0
    opts = setup_args(args)
    if opts is None:
        return 2
    if not shutil.which(CLAUDE_BIN):
        # без claude не зарегистрировать MCP-сервер, а setup бросил бы работу на полпути с traceback
        print(f"Не нашел {CLAUDE_BIN} в PATH. Для установки Claude Code запусти agentmeister --harness claude install. "
              f"Для Codex запусти {CODEX_SETUP}.", file=sys.stderr)
        return 1
    try:
        legacy_names = configure_mcp(opts["remove"])
    except (OSError, ValueError, subprocess.CalledProcessError):
        print("Не удалось обновить регистрацию MCP agentmeister. Проверь настройки MCP пользователя.", file=sys.stderr)
        return 1
    if opts["remove"]:
        for f in [COMMAND_FILE, FORGET_FILE, FRESH_FILE, SLIM_FILE, OLD_FORGET_FILE] + \
                [os.path.join(COMMANDS, f"{n}.md") for n in EXTRA_COMMANDS]:
            if os.path.exists(f):
                os.remove(f)
        notice_hook(False, legacy_names)
        lines = zshrc_lines()
        kept = [l for l in lines if not is_zsh_hook(l)]
        if kept != lines:
            write_zshrc(kept)
        print("Убрал /restart, /forget, /fresh, /slim, /todo, /where, /release-notes, /parallel, /shot, /ask, "
              f"/humanize, /import-codex, MCP-сервер {MCP_NAME} и хук из {tilde(ZSHRC)}.")
        # agentmeister больше не предлагает setup при запуске; вернуть все: agentmeister setup
        claude_setup.write(set(), set(claude_setup.IDS))
        return 0
    os.makedirs(os.path.dirname(COMMAND_FILE), exist_ok=True)
    if os.path.exists(OLD_FORGET_FILE):
        os.remove(OLD_FORGET_FILE)
    pages = [(COMMAND_FILE, SLASH), (FORGET_FILE, FORGET_SLASH), (FRESH_FILE, FRESH_SLASH), (SLIM_FILE, SLIM_SLASH)] + \
        [(os.path.join(COMMANDS, f"{n}.md"), EXTRA_SLASH[n]) for n in EXTRA_COMMANDS]
    for path, text in pages:
        with open(path, "w") as f:
            f.write(text)
        print(f"✓ /{os.path.basename(path)[:-3]} → {tilde(path)}")

    # до хуков: если promptsill поставится сейчас, notice_hook сразу пропишет его в statusLine
    promptsill = claude_setup.promptsill_step()
    notice_hook(True, legacy_names)
    install_restart_hook()
    print(f"✓ MCP {MCP_NAME}")
    import claude_notify
    if claude_notify.ensure_app():
        print(f"✓ приложение уведомлений → {tilde(claude_notify.AGENT.app)} (agentmeister notify test)")
    else:
        print("✗ не собрал приложение уведомлений: нужен swiftc (xcode-select --install)")
    proxy = claude_setup.proxy_step(opts["country"], opts["only"])
    asked = {"proxy": proxy, "promptsill": promptsill}
    claude_setup.record(set(claude_setup.AUTO) | {s for s, r in asked.items() if r == "done"},
                        {s for s, r in asked.items() if r == "skipped"})
    # setup все перевел на agentmeister, прежний отказ от переноса больше не нужен
    claude_setup.write(*claude_setup.current(), legacy_declined=False)
    if not shutil.which("agentmeister"):
        print(f"! agentmeister нет в PATH, а /restart, /todo и другие команды вызывают его по имени. "
              f"Поставь его: brew install kopylovis/tap/agentmeister или make install в {tilde(ROOT)}")
    print("Настройки Claude Code подхватятся при запуске новой сессии или перезапуске открытой.")
    print(f"Для Codex запусти {CODEX_SETUP}, затем подтверди хуки через /hooks.")
    return 0
