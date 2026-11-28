"""agentmeister doctor: одной командой проверить, что все части agentmeister на месте и работают."""
import json
import os
import shlex
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import BAD, CM, OK, ROOT, WARN, is_hook, promptsill_path, read_config, tilde, tr  # noqa: E402
from claude_proc import CLAUDE_BIN  # noqa: E402
import claude_settings  # noqa: E402
import codex_harness  # noqa: E402

USAGE = """agentmeister doctor    проверить установку Claude Code и Codex, хуки, статус в iTerm2, MCP-сервер, хук zsh,
                       уведомления, promptsill, прокси, крышку, хранение переписок. Код выхода 1, если что-то сломано"""


def run(cmd, timeout=15, stdin=None):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=stdin)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


def version():
    try:
        with open(os.path.join(ROOT, "VERSION")) as f:
            return f.read().strip()
    except OSError:
        return "?"


def check_install():
    where = "Homebrew" if any(f"/Cellar/{name}/" in ROOT + "/" for name in ("agentmeister", "claudemeister")) \
        else tr(f"из папки {tilde(ROOT)}", f"from {tilde(ROOT)}")
    rows = [("ok", f"agentmeister {version()}, {where}")]
    if not shutil.which("agentmeister"):
        rows.append(("bad", tr("agentmeister нет в PATH, а команды и хуки вызывают его по имени",
                               "agentmeister isn't in PATH, but commands and hooks call it by name")))
    import mnrhlib
    if mnrhlib.LEGACY_DIRS:
        rows.append(("warn", tr("настройки лежат в ~/.config/mnrh, старой папке: agentmeister migrate в обычном терминале перенесет их",
                                "settings are in ~/.config/mnrh, the old folder: agentmeister migrate in a regular terminal moves them")))
    claude = shutil.which(CLAUDE_BIN)
    if not claude:
        return rows + [("bad", tr(f"нет {CLAUDE_BIN} в PATH: поставь Claude Code",
                                  f"{CLAUDE_BIN} isn't in PATH: install Claude Code"))]
    code, out = run([claude, "--version"])
    rows.append(("ok", f"Claude Code {out.split()[0] if code == 0 and out.split() else '?'}"))
    return rows


def check_commands():
    import setup_cmd
    from slash import EXTRA_SLASH, FORGET_SLASH, FRESH_SLASH, SLASH, SLIM_SLASH
    pages = [(setup_cmd.COMMAND_FILE, SLASH), (setup_cmd.FORGET_FILE, FORGET_SLASH),
             (setup_cmd.FRESH_FILE, FRESH_SLASH), (setup_cmd.SLIM_FILE, SLIM_SLASH)] + \
        [(os.path.join(setup_cmd.COMMANDS, f"{n}.md"), EXTRA_SLASH[n]) for n in setup_cmd.EXTRA_COMMANDS]
    missing, stale = [], []
    for path, text in pages:
        name = "/" + os.path.basename(path)[:-3]
        if not setup_cmd.command_is_ours(path):
            continue  # своя команда пользователя с тем же именем, setup ее не трогает
        try:
            with open(path) as f:
                if f.read() != text:
                    stale.append(name)
        except OSError:
            missing.append(name)
    if missing:
        return [("bad", tr(f"нет команд {', '.join(missing)}: agentmeister setup",
                           f"missing commands {', '.join(missing)}: agentmeister setup"))]
    if stale:
        return [("warn", tr(f"команды {', '.join(stale)} от другой версии: agentmeister setup обновит их",
                            f"commands {', '.join(stale)} are from another version: agentmeister setup updates them"))]
    return [("ok", tr(f"команды /restart, /forget и еще {len(pages) - 2} на месте",
                      f"commands /restart, /forget and {len(pages) - 2} more in place"))]


def check_settings():
    try:
        settings = claude_settings.load()
    except ValueError as e:
        return [("bad", tr(f"{tilde(claude_settings.PATH)} не читается как JSON: {e}",
                           f"{tilde(claude_settings.PATH)} doesn't parse as JSON: {e}"))]
    rows = []
    lost = claude_settings.missing(settings, exact=True)
    if lost:
        names = sorted({f"{event} {cmd}" for event, cmd, _, _ in lost})
        rows.append(("bad", tr(f"нет хуков или они старые: {', '.join(names)}. agentmeister setup поставит",
                               f"hooks missing or outdated: {', '.join(names)}. agentmeister setup installs them")))
    else:
        rows.append(("ok", tr("хуки Claude Code на месте", "Claude Code hooks in place")))
    days = settings.get("cleanupPeriodDays")
    rows.append(("ok", tr(f"переписки хранятся {days} дней", f"transcripts kept for {days} days"))
                if isinstance(days, int) and days >= 90 else
                ("warn", tr(f"переписки удаляются через {days or 30} дней, поиск по сессиям их потеряет. "
                            "agentmeister setup поставит 365",
                            f"transcripts are deleted after {days or 30} days and session search loses them. "
                            "agentmeister setup sets 365")))
    line = claude_settings.statusline_command(settings)
    if "promptsill" in line:
        rows.append(("ok", tr("строка состояния promptsill", "promptsill status line")))
    elif line:
        rows.append(("ok", tr(f"строка состояния своя: {line[:60]}", f"custom status line: {line[:60]}")))
    elif promptsill_path():
        rows.append(("warn", tr("promptsill стоит, но statusLine пустая: promptsill install",
                                "promptsill is installed, but statusLine is empty: promptsill install")))
    else:
        rows.append(("warn", tr("строки состояния нет: brew install kopylovis/tap/promptsill && promptsill install",
                                "no status line: brew install kopylovis/tap/promptsill && promptsill install")))
    return rows


def iterm_rows(settings):
    """Хуки статуса iTerm2 в settings. До 3.7.7 iTerm2 ставил бинарник cc-status, теперь it2 handle-agent-hook.
    Пустой список, если интеграции iTerm2 с Claude Code нет."""
    old, new = set(), 0
    for _, _, cmd in claude_settings.hook_commands(settings):
        if "handle-agent-hook" in cmd:
            new += 1
            continue
        try:
            words = shlex.split(cmd)
        except ValueError:
            continue
        if words and os.path.basename(words[0]) == "cc-status":
            old.add(os.path.expanduser(words[0]))
    if not old:
        return [("ok", tr("статус в iTerm2: it2 handle-agent-hook", "iTerm2 status: it2 handle-agent-hook"))] if new else []
    fix = tr("iTerm2 > Install Claude Code Integration поставит it2 handle-agent-hook, потом снова agentmeister doctor",
             "iTerm2 > Install Claude Code Integration installs it2 handle-agent-hook, then run agentmeister doctor again")
    gone = sorted(p for p in old if not os.path.exists(p))
    if gone:
        return [("bad", tr(f"хуки iTerm2 вызывают {', '.join(map(tilde, gone))}, а файла нет. {fix}",
                           f"iTerm2 hooks call {', '.join(map(tilde, gone))}, but the file is gone. {fix}"))]
    return [("warn", tr(f"хуки iTerm2 старые, вызывают {', '.join(map(tilde, sorted(old)))}. Пока работают. {fix}",
                        f"iTerm2 hooks are old and call {', '.join(map(tilde, sorted(old)))}. They still work. {fix}"))]


def check_iterm():
    try:
        return iterm_rows(claude_settings.load())
    except ValueError:
        return []  # битый settings.json уже показал check_settings


def check_mcp():
    import setup_cmd
    from mcp_server import MCP_NAME
    listed, registered = setup_cmd.mcp_get(MCP_NAME)
    if not listed:
        return [("bad", tr(f"MCP-сервер {MCP_NAME} не подключен: agentmeister setup",
                           f"MCP server {MCP_NAME} isn't connected: agentmeister setup"))]
    rows = []
    if registered[1:] != ["mcp"] or os.path.realpath(registered[0]) != os.path.realpath(CM):
        rows.append(("warn", tr(f"MCP-сервер подключен к {' '.join(registered)}, а не к {tilde(CM)} mcp",
                                f"MCP server points to {' '.join(registered)}, not {tilde(CM)} mcp")))
    req = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}) + "\n"
    code, out = run(registered or [CM, "mcp"], timeout=20, stdin=req)
    try:
        count = len(json.loads(out.splitlines()[0])["result"]["tools"])
        rows.append(("ok", tr(f"MCP-сервер {MCP_NAME} отвечает, инструментов {count}",
                              f"MCP server {MCP_NAME} responding, {count} tools")))
    except (ValueError, KeyError, IndexError):
        rows.append(("bad", tr(f"MCP-сервер не ответил на tools/list: {out.strip()[:120] or code}",
                               f"MCP server didn't answer tools/list: {out.strip()[:120] or code}")))
    return rows


def check_zsh():
    import setup_cmd
    if any(setup_cmd.is_zsh_hook(line) for line in setup_cmd.zshrc_lines()):
        return [("ok", tr(f"хук перезапуска в {tilde(setup_cmd.ZSHRC)}", f"restart hook in {tilde(setup_cmd.ZSHRC)}"))]
    return [("warn", tr(f"нет хука перезапуска в {tilde(setup_cmd.ZSHRC)}: /restart вернется во вкладку только в "
                        "Terminal и iTerm2. agentmeister setup добавит",
                        f"no restart hook in {tilde(setup_cmd.ZSHRC)}: /restart returns to the tab only in "
                        "Terminal and iTerm2. agentmeister setup adds it"))]


CODEX_SETUP = "agentmeister --harness codex setup"


def check_codex_mcp(config):
    entry = (config.get("mcp_servers") or {}).get(codex_harness.MCP)
    if not entry or not entry.get("enabled", True):
        return "bad", tr(f"Codex MCP выключен или не подключен. Проверь {CODEX_SETUP}",
                         f"Codex MCP is off or not connected. Check {CODEX_SETUP}")
    command = shutil.which(entry.get("command") or "")
    if not command or os.path.realpath(command) != os.path.realpath(CM) or entry.get("args") != codex_harness.MCP_ARGS:
        return "warn", tr("Codex MCP указывает на другую команду.", "Codex MCP points to another command.")
    req = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}) + "\n"
    code, out = run([command, *codex_harness.MCP_ARGS], timeout=5, stdin=req)
    try:
        tools = json.loads(out.splitlines()[0])["result"]["tools"]
        if code == 0 and isinstance(tools, list) and tools:
            return "ok", tr(f"Codex MCP отвечает, инструментов {len(tools)}", f"Codex MCP responding, {len(tools)} tools")
    except (IndexError, ValueError, KeyError, TypeError):
        pass
    return "bad", tr("Codex MCP не ответил на tools/list.", "Codex MCP didn't answer tools/list.")


def check_codex_hooks(hooks, name="humanize-hook"):
    label = "Codex " + name.removesuffix("-hook")
    events = codex_harness.HOOK_COMMANDS[name]
    if hooks is None:
        count = codex_harness.configured_hooks(name)
        if count is not None and count < len(events):
            return "bad", tr(f"{label}, настроено {count} из {len(events)} хуков. Запусти {CODEX_SETUP}.",
                             f"{label}, {count} of {len(events)} hooks installed. Run {CODEX_SETUP}.")
        shown = count if count is not None else '?'
        return "warn", tr(f"{label}, настроено {shown} из {len(events)} хуков. Статус доверия виден в /hooks.",
                          f"{label}, {shown} of {len(events)} hooks set up. Trust status is in /hooks.")
    count = 0
    missing = []
    for event in events:
        event_name = event[0].lower() + event[1:]
        handlers = [hook for hook in hooks if hook.get("eventName") == event_name
                    and codex_harness.covers_tools(name, hook.get("matcher")) and is_hook(hook.get("command"), name)
                    and not (codex_harness.requires_sync(name, event) and hook.get("async"))]
        if not handlers:
            missing.append(event)
        elif any(h.get("enabled") and h.get("trustStatus") == "trusted" for h in handlers):
            count += 1
    if count != len(events):
        fix = (tr(f"Запусти {CODEX_SETUP} для {', '.join(missing)}, затем открой /hooks.",
                  f"Run {CODEX_SETUP} for {', '.join(missing)}, then open /hooks.") if missing else
               tr("Проверь этот хук в /hooks.", "Review this hook in /hooks."))
        return "bad", tr(f"{label}, подтверждено {count} из {len(events)} хуков. {fix}",
                         f"{label}, {count} of {len(events)} hooks trusted. {fix}")
    return "ok", tr(f"{label}, подтверждено {count} из {len(events)} хуков",
                    f"{label}, {count} of {len(events)} hooks trusted")


def check_codex_modes(hooks):
    import main_menu
    rows = []
    for name in codex_harness.HOOK_COMMANDS:
        mode = name.removesuffix("-hook")
        if main_menu.mode_on(mode):
            rows.append(check_codex_hooks(hooks, name))
        else:
            rows.append(("off", tr(f"Codex {mode} выключен", f"Codex {mode} is off")))
    return rows


def check_codex():
    codex = codex_harness.executable()
    if not codex:
        return [("ok", tr("Codex отсутствует в PATH, проверка пропущена", "Codex isn't in PATH, check skipped"))]
    code, out = run([codex, "--version"], timeout=5)
    if code != 0 or not out.strip():
        return [("bad", tr("Codex не ответил на --version", "Codex didn't answer --version"))]
    rows = [("ok", "Codex " + out.splitlines()[0].strip().removeprefix("codex-cli "))]
    cwd = os.getcwd()
    try:
        with codex_harness.app_server(codex, cwd, experimental=True) as request:
            config = request("config/read", {"cwd": cwd})["config"]
            rows.append(check_codex_mcp(config))
            try:
                hooks = request("hooks/list", {"cwds": [cwd]})["data"][0]["hooks"]
            except (OSError, ValueError, KeyError, IndexError):
                hooks = None
            rows.extend(check_codex_modes(hooks))
            skills = request("skills/list", {"cwds": [cwd]})["data"]
    except (OSError, ValueError, KeyError, TypeError):
        return rows + [("bad", tr("Codex App Server не вернул данные установки.",
                                  "Codex App Server didn't return the install data."))]
    rows.append(("ok", tr("Codex видит навык $agentmeister", "Codex sees the $agentmeister skill")) if any(
        skill.get("name") == "agentmeister" and skill.get("enabled")
        for group in skills for skill in group["skills"]
    ) else ("warn", tr(f"Codex не видит навык $agentmeister. Запусти {CODEX_SETUP}",
                       f"Codex doesn't see the $agentmeister skill. Run {CODEX_SETUP}")))
    footer = (config.get("tui") or {}).get("status_line")
    rows.append(("ok", tr(f"Строка состояния Codex, полей {len(footer)}", f"Codex status line, {len(footer)} fields"))
                if footer else
                ("warn", tr("Строка состояния Codex выключена. Поля можно выбрать через /statusline.",
                            "Codex status line is off. Pick its fields with /statusline.")))
    return rows


def check_notify():
    import notify
    if not notify.enabled():
        return [("ok", tr("уведомления выключены (agentmeister notify on)", "notifications off (agentmeister notify on)"))]
    if os.path.isdir(notify.AGENT.app):
        return [("ok", tr(f"уведомления: {tilde(notify.AGENT.app)}", f"notifications: {tilde(notify.AGENT.app)}"))]
    return [("bad", tr("уведомления включены, но приложения нет: agentmeister setup соберет его (нужен swiftc)",
                       "notifications are on, but the app is missing: agentmeister setup builds it (needs swiftc)"))]


def check_proxy():
    import proxy
    if proxy.configured():
        return [("ok", tr("прокси настроен (проверить выход: agentmeister proxy test)",
                          "proxy configured (test the exit: agentmeister proxy test)"))]
    return [("ok", tr("прокси не настроен, agentmeister -x недоступен", "proxy not configured, agentmeister -x is unavailable"))]


def check_lid():
    import claude_lid
    if not claude_lid.switched_on():
        return [("ok", tr("крышка: выключено, закрытая крышка усыпит Mac (agentmeister lid on)",
                          "lid: off, closing the lid puts the Mac to sleep (agentmeister lid on)"))]
    if claude_lid.disabled() and not claude_lid.watcher_pid():
        return [("warn", tr("сон отключен (pmset disablesleep 1), а сторожа нет: agentmeister lid release",
                            "sleep is disabled (pmset disablesleep 1) with no watcher: agentmeister lid release"))]
    if claude_lid.ready():
        return [("ok", tr(f"крышка: caffeinate-сессии не уснут и с закрытой крышкой (на батарее до "
                          f"{claude_lid.low_battery()}% заряда)",
                          f"lid: caffeinate sessions stay awake with the lid closed (on battery down to "
                          f"{claude_lid.low_battery()}%)"))]
    return [("warn" if read_config().get("lid") == "on" else "ok", tr("крышка: закрытая крышка усыпит Mac и в caffeinate-сессии (agentmeister lid setup)",
                      "lid: closing the lid puts the Mac to sleep even in caffeinate sessions (agentmeister lid setup)"))]


def check_modes():
    import main_menu
    import translate
    states = {name: main_menu.mode_on(name) for name in ("humanize", "translate", "guard", "notify", "buildlog", "lid")}
    summary = ", ".join(f"{name} {tr('вкл', 'on') if on else tr('выкл', 'off')}" for name, on in states.items())
    rows = [("ok", tr("режимы: ", "modes: ") + summary)]
    if states.get("translate") and not (translate.key_source() or translate.fallback()):
        rows.append(("bad", tr("Для translate нужен ключ провайдера. Добавь его в настройках перевода.",
                               "Translate needs a provider key. Add one in translation settings.")))
    return rows



CHECKS = [check_install, check_commands, check_settings, check_iterm, check_mcp, check_codex, check_zsh, check_notify, check_proxy,
          check_lid, check_modes]


def main(args):
    if any(a in ("-h", "--help", "help") for a in args):
        print(USAGE)
        return 0
    marks = {"ok": OK, "off": "-", "warn": WARN, "bad": BAD}
    worst = "ok"
    for check in CHECKS:
        try:
            rows = check()
        except Exception as e:
            name = check.__name__[6:]
            rows = [("bad", tr(f"{name}: проверка упала ({e!r})", f"{name}: the check crashed ({e!r})"))]
        for level, text in rows:
            print(f"{marks[level]} {text}")
            if level == "bad" or (level == "warn" and worst == "ok"):
                worst = level
    print()
    print({"ok": tr("Все в порядке.", "All good."), "warn": tr("Работает, но есть что поправить.", "Works, but some things need fixing."),
           "bad": tr("Есть ошибки установки. Подробности выше.", "The install has errors. Details above.")}[worst])
    return 1 if worst == "bad" else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
