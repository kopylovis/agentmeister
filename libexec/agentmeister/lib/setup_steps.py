"""Шаги agentmeister setup и проверка перед запуском agentmeister.

setup записывает в ~/.config/mnrh/claude-setup.json, какие шаги сделаны и от каких отказались.
agentmeister перед запуском сверяет запись со STEPS. Если setup на этом Mac не запускали или после
обновления в STEPS появился шаг, которого нет в записи, предлагает настроить.
Новый шаг в setup: добавь его id и описание в STEPS, и при первом запуске после обновления его предложат.
Шаг с вопросом еще и в ASKS, а setup записывает его результат сам, как proxy_step.
"""
import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import (CLAUDE_HOME, HOME, LEGACY_CALL, OK, PROMPTSILL_HINT, WARN, promptsill_path, tilde, tr,  # noqa: E402
                     write_json)
import claude_settings  # noqa: E402

STATE = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "mnrh", "claude-setup.json")
CLAUDE = CLAUDE_HOME
STEPS = [
    ("commands", "команды /restart, /forget, /fresh, /slim, /todo и другие"),
    ("hooks", "хуки Claude Code: сообщения после /restart, guard, уведомления, humanization, выжимка сборок, "
              "строка состояния; "
              "хранить переписки год, а не 30 дней"),
    ("zsh", "хук перезапуска в ~/.zshrc"),
    ("mcp", "MCP-сервер agentmeister"),
    ("notify-app", "приложение уведомлений"),
    ("proxy", "прокси для agentmeister -x"),
    ("promptsill", "строка состояния promptsill: лимиты, контекст, порты, память"),
]
IDS = [s for s, _ in STEPS]
# Шаги с вопросами, у каждого своя функция. Остальные setup делает сам и отмечает сделанными все разом.
ASKS = {"proxy", "promptsill"}
AUTO = set(IDS) - ASKS
# Эти шаги setup делал и до того, как начал вести запись. Если записи нет, а /restart стоит, они сделаны.
BEFORE_STATE = {"commands", "hooks", "zsh", "mcp", "notify-app"}
YES = ("", "y", "yes", "д", "да")
# Шаги, которые ставил mnrh claude setup. Пока команды, хуки или MCP вызывают mnrh claude, их надо переписать.
LEGACY = ["commands", "hooks", "mcp"]


def raw():
    try:
        with open(STATE) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def read():
    data = raw()
    if data is None:
        return None
    return set(data.get("done", [])), set(data.get("skipped", []))


def write(done, skipped, legacy_declined=None):
    """legacy_declined: отказались переводить mnrh claude на agentmeister; None — оставить как было."""
    if legacy_declined is None:
        legacy_declined = bool((raw() or {}).get("legacy_declined"))
    data = {"done": sorted(done), "skipped": sorted(skipped - done)}
    if legacy_declined:
        data["legacy_declined"] = True
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    write_json(STATE, data, newline=True, ensure_ascii=False, indent=2)


def current():
    """(сделано, отказались). Без записи, но с /restart считаем сделанным то, что setup ставил до записи."""
    state = read()
    if state is not None:
        return state
    if os.path.exists(os.path.join(CLAUDE, "commands", "restart.md")):
        return set(BEFORE_STATE), set()
    return set(), set()


def record(done=(), skipped=()):
    old = current()
    write(old[0] | set(done), (old[1] - set(done)) | set(skipped))


def proxy_configured():
    import proxy
    return proxy.configured()


def hooks_outdated():
    """True, если какого-то нашего хука нет в settings.json или у него старый matcher (например, guard без Grep)."""
    if not os.path.exists(claude_settings.PATH):
        return False
    try:
        settings = claude_settings.load()
        return bool(claude_settings.missing(settings, exact=True)) or "cleanupPeriodDays" not in settings
    except (OSError, ValueError):
        return False


def legacy():
    """True, если /restart, хуки или MCP-сервер еще из mnrh: вызывают mnrh claude, а не agentmeister."""
    def text(path):
        try:
            with open(path) as f:
                return f.read()
        except OSError:
            return ""
    if LEGACY_CALL.search(text(os.path.join(CLAUDE, "commands", "restart.md"))):
        return True
    try:
        settings = claude_settings.load()
        commands = [c for _, _, c in claude_settings.hook_commands(settings)] + \
            [claude_settings.statusline_command(settings)]
    except (OSError, ValueError):
        commands = []
    if any(LEGACY_CALL.search(c) for c in commands):
        return True
    try:
        servers = json.loads(text(os.path.join(HOME, ".claude.json")) or "{}").get("mcpServers") or {}
    except (ValueError, AttributeError):
        return False
    previous = servers.get("claudemeister") if isinstance(servers, dict) else None
    if isinstance(previous, dict) and os.path.basename(previous.get("command") or "") in ("agentmeister", "claudemeister") and previous.get("args") == ["mcp"]:
        return True
    old = servers.get("mnrh") if isinstance(servers, dict) else None
    return isinstance(old, dict) and old.get("args") == ["claude", "mcp"]


def pending():
    """(шаги, которых нет ни в сделанных, ни в отказах; True, если setup на этом Mac не запускали)."""
    if read() is None and not os.path.exists(os.path.join(CLAUDE, "commands", "restart.md")):
        return list(IDS), True
    done, skipped = current()
    if "proxy" not in done and proxy_configured():
        done = done | {"proxy"}
    if "promptsill" not in done and promptsill_path():
        done = done | {"promptsill"}
    if not (raw() or {}).get("legacy_declined") and legacy():
        done = done - set(LEGACY)
    if "hooks" in done and hooks_outdated():
        done = done - {"hooks"}
    return [s for s in IDS if s not in done and s not in skipped], False


def ask(question, options, default=0, back=None):
    """options: [(значение, подпись, клавиши)]; back: что вернуть на Esc. Без меню спрашивает строкой."""
    back = back or options[-1][0]
    try:
        from menu import choice
        return choice(question, options, default=default, back=back,
                      esc=next(label for value, label, _ in options if value == back).lower())
    except OSError:
        hint = "/".join(o[1] for o in options)
        answer = input(f"{question} [{hint}] ").strip().lower()
        for value, label, keys in options:
            if answer == label.lower() or (answer and answer in keys):
                return value
        return options[default][0]


def proxy_step(country="", only=""):
    """Шаг setup про прокси. Возвращает "done", "skipped" или None (не настроен и не спрашивали)."""
    import proxy
    if proxy.configured():
        want = proxy.setting("country")
        print(f"{OK} " + tr("прокси уже настроен", "the proxy is already set up")
              + (tr(f", выход должен быть в {want}", f", the exit must be in {want}") if want else "")
              + tr(" (проверить: agentmeister proxy test)", " (check: agentmeister proxy test)"))
        if country and country.upper() != want.upper():
            print(f"{WARN} " + tr(f"--country {country.upper()} не применил, прокси уже настроен. "
                                  f"Поменять: agentmeister proxy setup --country {country.upper()}",
                                  f"--country {country.upper()} not applied, the proxy is already set up. "
                                  f"Change it: agentmeister proxy setup --country {country.upper()}"))
        return "done"
    if not sys.stdin.isatty():
        print(f"{WARN} " + tr("прокси не настроен, не терминал. Настроить: agentmeister proxy setup --country KZ",
                              "the proxy isn't set up and this isn't a terminal. Set it up: agentmeister proxy setup --country KZ"))
        return None
    print(tr("Сессии с флагом -x подключаются через сервер из твоей подписки 3x-ui.",
             "Sessions with -x connect through a server from your 3x-ui subscription."))
    if ask(tr("Настроить прокси сейчас?", "Set up the proxy now?"),
           [("yes", tr("Да", "Yes"), "yд"), ("no", tr("Пропустить", "Skip"), "nн")]) != "yes":
        print(f"{WARN} " + tr("прокси пропущен. Настроить потом: agentmeister proxy setup",
                              "proxy skipped. Set it up later: agentmeister proxy setup"))
        return "skipped"
    if not country:
        country = input(tr("Страна выхода, которую проверять при запуске, например KZ (Enter, не проверять): ",
                           "Exit country to check at start, e.g. KZ (Enter to skip the check): ")).strip()
    code = proxy.setup((["--country", country] if country else []) + (["--only", only] if only else []))
    return "done" if code == 0 else "failed"


def promptsill_step():
    """Шаг setup про promptsill. Возвращает "done", "skipped" или None (не поставлен и не спрашивали)."""
    if promptsill_path():
        print(f"{OK} " + tr("строка состояния promptsill уже стоит", "the promptsill status line is already installed"))
        return "done"
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        print(f"{WARN} " + tr(f"строки состояния promptsill нет, не терминал. Поставить: {PROMPTSILL_HINT}",
                              f"no promptsill status line and this isn't a terminal. Install: {PROMPTSILL_HINT}"))
        return None
    print(tr("promptsill: строка состояния Claude Code с темпом лимитов, контекстом, dev-серверами, портами и памятью.",
             "promptsill: a Claude Code status line with limit pace, context, dev servers, ports and memory."))
    if ask(tr("Поставить promptsill?", "Install promptsill?"),
           [("yes", tr("Да", "Yes"), "yд"), ("no", tr("Пропустить", "Skip"), "nн")]) != "yes":
        print(f"{WARN} " + tr(f"promptsill пропущен. Поставить потом: {PROMPTSILL_HINT}, затем agentmeister setup",
                              f"promptsill skipped. Install later: {PROMPTSILL_HINT}, then agentmeister setup"))
        return "skipped"
    brew = shutil.which("brew") or next((p for p in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew")
                                         if os.access(p, os.X_OK)), None)
    if not brew:
        print(f"{WARN} " + tr(f"нет Homebrew. Поставь его с https://brew.sh, потом {PROMPTSILL_HINT}",
                              f"Homebrew is missing. Install it from https://brew.sh, then {PROMPTSILL_HINT}"))
        return "failed"
    r = subprocess.run([brew, "install", "kopylovis/tap/promptsill"])
    if r.returncode != 0 or not promptsill_path():
        print(f"{WARN} " + tr(f"promptsill не поставился. Попробуй сам: {PROMPTSILL_HINT}",
                              f"promptsill didn't install. Try it yourself: {PROMPTSILL_HINT}"))
        return "failed"
    print(f"{OK} " + tr("promptsill поставлен", "promptsill installed"))
    return "done"


def promptsill_statusline():
    """promptsill поставлен вне полного setup: прописать его в statusLine, если там пусто или наша заглушка."""
    try:
        settings = claude_settings.load()
    except ValueError:
        print(f"{WARN} " + tr(f"{tilde(claude_settings.PATH)} не читается как JSON, statusLine не трогаю. "
                              "Поставь сам: promptsill install",
                              f"{tilde(claude_settings.PATH)} isn't valid JSON, leaving statusLine alone. "
                              "Install it yourself: promptsill install"))
        return
    promptsill = promptsill_path()
    if promptsill and claude_settings.ensure_statusline(settings, promptsill):
        claude_settings.save_atomic(settings)
        print(f"{OK} " + tr("строка состояния → statusLine (promptsill)", "status line → statusLine (promptsill)"))


def check():
    """Перед запуском agentmeister: предложить setup, если его не делали или появились новые шаги."""
    if os.environ.get("MNRH_NO_SETUP_CHECK") or not (sys.stdin.isatty() and sys.stdout.isatty()):
        return 0
    steps, fresh = pending()
    if not steps:
        return 0
    about = dict(STEPS)
    if fresh:
        print("agentmeister setup на этом Mac еще не запускали. Он ставит:")
    elif legacy():
        print("Найдены старые настройки mnrh claude или claudemeister. Теперь используется "
              "agentmeister. Обновить настройки?")
    else:
        print("После обновления в agentmeister setup есть шаги, которые здесь не настроены:")
    for s in steps:
        print(f"  {about[s]}")
    answer = ask("Настроить сейчас?", [("yes", "Да", "yд"), ("later", "Позже", "lп"), ("never", "Не предлагать", "nн")],
                 back="later")
    print()
    if answer == "never":
        migrate = legacy() and set(LEGACY) & set(steps)
        record(skipped=set(steps) - (set(LEGACY) if migrate else set()))
        if migrate:
            # шаги переноса в записи сделаны (их ставил mnrh claude setup), поэтому отказ помним отдельно
            done, skipped = current()
            write(done, skipped, legacy_declined=True)
        print("Больше не спрошу. Настроить можно в любой момент: agentmeister setup\n")
    elif answer == "yes" and set(steps) <= ASKS:
        for step in steps:
            result = proxy_step() if step == "proxy" else promptsill_step()
            if step == "promptsill" and result == "done" and promptsill_path():
                promptsill_statusline()
            if result in ("done", "skipped"):
                record(**{"done" if result == "done" else "skipped": [step]})
        print()
    elif answer == "yes":
        subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "claude_restart.py"),
                        "setup"])
        print()
    else:
        print("Спрошу при следующем запуске.\n")
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "check":
        sys.exit(check())
    if cmd == "pending":
        steps, fresh = pending()
        print(("fresh " if fresh else "") + " ".join(steps))
        sys.exit(0)
    print("setup_steps.py check | pending", file=sys.stderr)
    sys.exit(2)
