"""Меню действий agentmeister: agentmeister без аргументов в терминале.

Действие запускается как agentmeister <аргументы>, полная команда печатается, чтобы в следующий раз набрать ее
сразу. После действия можно вернуться в меню. Режимы (humanize, guard, buildlog, уведомления, крышка) по Enter
переключаются на месте: меню остается и показывает новое состояние. Язык берется из mnrhlib.lang().
"""
import os
import shlex
import shutil
import signal
import subprocess
import sys
import textwrap
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from menu import Cancel, Panel, Quit, Screen, choice, run_framed, show_output  # noqa: E402
from mnrhlib import CM, DEV, HOME, RESTART_QUEUE, ROOT, promptsill_path, run as capture, tilde, tr  # noqa: E402
import claude_sessions  # noqa: E402
import codex_harness  # noqa: E402
import open_flow  # noqa: E402

# (команда, значок, по-русски, по-английски, описание по-русски, по-английски). Группа: команда None.
# Режим: "mode <имя>", Enter переключает его. Значки только шириной в две клетки, без VS16: иначе едут рамки.
ITEMS = [
    (None, "", "Сессии", "Sessions", "", ""),
    ("open", "📂", "Открыть проект", "Open a project",
     "Выбрать проект и открыть в нем Claude Code или Codex.",
     "Choose a project and open it in Claude Code or Codex."),
    ("root", "🏠", "Открыть в домашней папке", "Open in the home folder",
     "Запустить Claude Code или Codex в домашней папке.",
     "Start Claude Code or Codex in the home folder."),
    ("sessions", "💾", "Сохраненные сессии", "Saved sessions",
     "Продолжить сессию в текущей папке. Для Claude Code здесь также есть перенос и удаление сессий.",
     "Resume a session in the current folder. For Claude Code, you can also move or delete sessions here."),
    ("ps", "👀", "Запущенные сессии", "Running sessions",
     "Какие сессии Claude Code сейчас открыты и какая из них ждет ответа. Из списка можно перейти во вкладку.",
     "Which Claude Code sessions are open right now and which one is waiting for you. Jump to its tab "
     "from the list."),
    ("restore", "🔄", "Вернуть сессии", "Reopen sessions",
     "Открыть заново сессии, которые были запущены до перезагрузки Mac или сбоя терминала.",
     "Reopen the sessions that were running before a reboot or a terminal crash."),
    ("usage", "📊", "Расход", "Usage",
     "Токены и активное время по проектам и моделям за последние 7 дней. Другой срок и проект задают "
     "agentmeister usage --days N --project P.",
     "Tokens and active time per project and model for the last 7 days. Pick another range or project "
     "with agentmeister usage --days N --project P."),
    (None, "", "Агенты", "Harness", "", ""),
    ("--harness claude status", "📊", "Статус Claude Code", "Claude Code status",
     "Версия Claude Code и состояние открытых сессий.", "Claude Code version and the state of open sessions."),
    ("--harness codex statusline", "📊", "Статус Codex", "Codex status",
     "Последние сохраненные лимиты и контекст Codex, данные проекта и Mac. Выводит promptsill.",
     "Show the latest saved Codex limits and context with project and Mac details from promptsill."),
    ("--harness claude install", "📦", "Установить Claude Code", "Install Claude Code",
     "Скачать и запустить установщик Anthropic.", "Download and run the Anthropic installer."),
    ("setup", "🧰", "Настроить Claude Code", "Set up Claude Code",
     "Поставить команды /restart, /forget и другие, хуки Claude Code, хук zsh и MCP-сервер. "
     "Прокси тоже настроит, если его еще нет.",
     "Install /restart, /forget and the other commands, Claude Code hooks, the zsh hook and the "
     "MCP server. Sets up the proxy too if it is missing."),
    ("--harness codex setup", "🧰", "Настроить Codex", "Set up Codex",
     "Подключить хуки, MCP и навык $agentmeister. С promptsill можно включить строку с лимитами.",
     "Install hooks, MCP tools and the $agentmeister skill. With promptsill, set up the footer with rate limits."),
    (None, "", "Режимы, Enter переключает", "Modes, Enter switches", "", ""),
    ("mode humanize", "📝", "Без признаков нейросети", "No AI tells",
     "В начале каждой сессии Claude получает правила письма. Ответы, коммиты и документация выходят без "
     "примет сгенерированного текста.",
     "Every session starts with writing rules, so replies, commits and docs come out without the marks "
     "of generated text."),
    ("mode guard", "🔒", "Вопрос перед опасным", "Ask before risky commands",
     "Перед чтением файлов с ключами и перед опасными командами Claude Code спросит разрешение.",
     "Claude Code asks before it reads key files or runs a risky command."),
    ("mode buildlog", "🔨", "Выжимка сборок", "Build digest",
     "Длинный вывод Gradle и xcodebuild сжимается до ошибок и упавших тестов, чтобы не тратить контекст.",
     "Long Gradle and xcodebuild output is cut down to errors and failed tests, so it does not eat "
     "the context."),
    ("mode notify", "🔔", "Уведомления", "Notifications",
     "Уведомления о запросах разрешения и долгих ответах Claude Code и Codex. "
     "В Claude Code также приходят уведомления о вопросах. Telegram подключает agentmeister notify telegram.",
     "Notifications for permission requests and long turns in Claude Code and Codex. "
     "Claude Code also sends question notifications. agentmeister notify telegram adds Telegram."),
    ("mode lid", "💻", "Не спать с закрытой крышкой", "Stay awake with the lid closed",
     "Mac не засыпает с закрытой крышкой, пока идет сессия. При первом включении спросит пароль sudo.",
     "The Mac stays awake with the lid closed while a session runs. The first time it asks for the sudo "
     "password."),
    (None, "", "Прокси через свой VPS", "Proxy through your VPS", "", ""),
    ("proxy", "🌐", "Состояние прокси", "Proxy status",
     "Настроен ли прокси, запущен ли mihomo и сколько сессий идет через VPS.",
     "Whether the proxy is set up, whether mihomo is running and how many sessions go through the VPS."),
    ("proxy test", "🧪", "Проверить выход", "Check the exit",
     "Сравнить выход напрямую и через VPS, с IP и страной.",
     "Compare the direct exit with the VPS exit, IP and country."),
    ("proxy setup", "🔗", "Настроить по подписке", "Set up from a subscription",
     "Настроить mihomo по ссылке на подписку, как в Happ. Через VPS пойдут сессии, запущенные с -x.",
     "Set up mihomo from a subscription link, the same one Happ takes. Sessions started with -x go "
     "through the VPS."),
    ("proxy restart", "🔁", "Перезапустить mihomo", "Restart mihomo",
     "Перезапустить mihomo, не закрывая сессии, которые идут через VPS.",
     "Restart mihomo without closing the sessions that go through the VPS."),
    ("proxy update", "📦", "Обновить mihomo", "Update mihomo",
     "Обновить mihomo через Homebrew и перезапустить его, если он запущен.",
     "Update mihomo with Homebrew and restart it if it is running."),
    (None, "", "Установка", "Install", "", ""),
    ("mode alias", "🔤", "Короткое имя am", "Short name am",
     "Команда am открывает то же меню, что и agentmeister. "
     "Если имя am уже занято, ссылка не изменится.",
     "The am command opens the same menu as agentmeister. "
     "An existing command named am keeps its place."),
    ("doctor", "🔍", "Проверить установку", "Check the install",
     "Проверить установку agentmeister и настройки интеграции с Claude Code и Codex.",
     "Check the Agentmeister install and its integrations with Claude Code and Codex."),
    ("help", "❓", "Справка", "Help",
     "Все команды agentmeister с флагами.",
     "Every agentmeister command with its flags."),
    ("quit", "🚪", "Выход", "Quit",
     "Закрыть меню. Esc и Ctrl+C делают то же.",
     "Close the menu. Esc and Ctrl+C do the same."),
]


def mode_on(name):
    """Включен ли режим сейчас. Модули грузятся по требованию: меню не должно падать из-за одного из них."""
    try:
        if name == "humanize":
            import claude_humanize
            return claude_humanize.enabled()
        if name == "guard":
            import claude_guard
            return claude_guard.enabled()
        if name == "buildlog":
            import claude_buildlog
            return claude_buildlog.enabled()
        if name == "notify":
            import claude_notify
            return claude_notify.enabled()
        if name == "lid":
            import claude_lid
            return claude_lid.active()
        if name == "alias":
            import claude_alias
            return claude_alias.enabled()
    except Exception:
        pass
    return False


def dim(text):
    return f"\x1b[2m{text}\x1b[0m"


def modes():
    return {key.split()[1]: mode_on(key.split()[1]) for key, *_ in ITEMS if key and key.startswith("mode ")}


def command(key, state):
    """Что запустит Enter: для режима это его переключение."""
    if key.startswith("mode "):
        name = key.split()[1]
        return f"{name} {'off' if state.get(name) else 'on'}"
    return key


def rows(state=None):
    """Строки для меню: (ключ для поиска, значок и название). У режима справа [вкл] или [выкл]."""
    state = modes() if state is None else state
    on, off = tr("вкл", "on"), tr("выкл", "off")
    width = max(len(tr(ru, en)) for key, _, ru, en, _, _ in ITEMS if key) + 2
    out = []
    for key, icon, ru, en, _, _ in ITEMS:
        label = tr(ru, en)
        if key is None:
            out.append((None, label))
            continue
        text = f"{icon} {label}"
        if key.startswith("mode "):
            flag = state.get(key.split()[1])
            text = f"{icon} {label.ljust(width)}" + ("\x1b[32m[" + on + "]\x1b[0m" if flag else dim(f"[{off}]"))
        out.append((f"{key} {label}", text))
    return out


def version():
    try:
        with open(os.path.join(ROOT, "VERSION")) as f:
            return f.read().strip()
    except OSError:
        return "?"


class Describe:
    """Правая панель: описание пункта и что сейчас настроено. Прокси спрашивается в фоне, mihomo может молчать."""

    def __init__(self, state):
        self.state = state
        self.proxy = tr("проверяю", "checking")
        self.codex = self.promptsill = self.hooks = self.proxy
        self.fresh = threading.Event()
        try:
            from claude_proc import claude_version
            self.claude = claude_version() or "?"
        except Exception:
            self.claude = "?"
        threading.Thread(target=self.ask_proxy, daemon=True).start()
        threading.Thread(target=self.ask_codex, daemon=True).start()

    def ask_codex(self):
        def installed_version(path, prefix=""):
            if not path:
                return tr("не найден", "not found")
            return capture([path, "--version"], timeout=2).strip().removeprefix(prefix) or "?"

        self.codex = installed_version(codex_harness.executable(), "codex-cli ")
        self.promptsill = installed_version(promptsill_path())
        count = codex_harness.configured_humanize_hooks()
        self.hooks = "?" if count is None else tr(f"{count}/{len(codex_harness.HOOK_EVENTS)} настроено",
                                                  f"{count}/{len(codex_harness.HOOK_EVENTS)} configured")
        self.fresh.set()

    def ask_proxy(self):
        try:
            import claude_proxy
            if not claude_proxy.configured():
                text = tr("не настроен", "not set up")
            else:
                _, kind = claude_proxy.active_node()
                text = tr(f"работает, {kind}", f"running, {kind}") if kind else \
                    tr("настроен, mihomo не запущен", "set up, mihomo not running")
        except Exception:
            text = "?"
        self.proxy = text
        self.fresh.set()

    def dirty(self):
        if not self.fresh.is_set():
            return False
        self.fresh.clear()
        return True

    def __call__(self, i, w):
        key, _, ru, en, desc_ru, desc_en = ITEMS[i]
        lines = [f"\x1b[1m{tr(ru, en)}\x1b[0m", ""]
        lines += textwrap.wrap(tr(desc_ru, desc_en), w) or [""]
        if key.startswith("mode "):
            flag = self.state.get(key.split()[1])
            lines += ["", ("\x1b[32m" + tr("Сейчас включено", "On now") + "\x1b[0m" if flag else
                           tr("Сейчас выключено", "Off now")) + dim(tr(", Enter переключит", ", Enter switches it"))]
        if key not in ("quit",):
            lines += ["", dim(f"$ agentmeister {command(key, self.state)}")]
        on = [name for name, flag in self.state.items() if flag and name != "alias"]
        facts = [(tr("Версия", "Version"), version()),
                 ("Claude Code", self.claude),
                 ("Codex", self.codex)]
        if key.startswith("--harness codex "):
            facts += [("promptsill", self.promptsill), (tr("Хуки humanize", "Humanize hooks"), self.hooks)]
        facts += [(tr("Папка", "Folder"), tilde(os.getcwd())),
                  (tr("Проекты", "Projects"), tilde(DEV)),
                  (tr("Режимы", "Modes"), ", ".join(on) if on else tr("все выключены", "all off")),
                  (tr("Прокси", "Proxy"), self.proxy)]
        pad = max(len(k) for k, _ in facts) + 3
        lines += ["", "", dim(tr("СЕЙЧАС", "CURRENT SETUP"))]
        lines += [dim(k.ljust(pad)) + v for k, v in facts]
        return lines


def pick_action(screen, at=1, note=""):
    title = f"\x1b[1;35magentmeister\x1b[0m  {dim('v' + version())}" + (f"  \x1b[33m{note}\x1b[0m" if note else "")
    state = modes()
    items = rows(state)
    if not screen.open().roomy():
        return screen.pick(items, title="agentmeister", default=at, back=tr("выход", "quit"))
    hint = tr("↑↓ выбрать · Enter запустить · буквы ищут · Tab описание · Esc выход",
              "↑↓ move · Enter run · type to search · Tab description · Esc quit")
    try:
        return Panel(screen.fd, items, title, at, Describe(state),
                     (tr("Действия", "Actions"), tr("Описание", "Description")), hint).run()
    except Cancel:
        return None


def restart_pending():
    """/restart уже положил задание для этой вкладки: меню больше не показываем, вкладку займет Claude."""
    try:
        job = os.path.join(RESTART_QUEUE, os.path.basename(os.ttyname(0)))
        return time.time() - os.path.getmtime(job) < 120
    except OSError:
        return False


def again(rc):
    if restart_pending():
        return False
    if rc == 130:
        return True
    head = (f"\x1b[32m✓ {tr('Готово', 'Done')}\x1b[0m" if rc == 0 else
            f"\x1b[33m! {tr(f'Завершилось с кодом {rc}', f'Exited with code {rc}')}\x1b[0m")
    try:
        print()
        return choice(head, [("menu", tr("↩ В меню", "↩ Menu"), ""), ("quit", tr("Выйти", "Quit"), "qй")],
                      default=0, back="quit", esc=tr("выход", "quit")) == "menu"
    except OSError:
        return False


def run(args):
    # Ctrl-C прерывает действие, а не меню; обработчик на Python в запущенной программе сбрасывается
    old = signal.signal(signal.SIGINT, lambda *_: None)
    try:
        rc = subprocess.run([CM] + args).returncode
    finally:
        signal.signal(signal.SIGINT, old)
    return 128 - rc if rc < 0 else rc


def shown(args):
    """Команда для показа: пути через ~."""
    return " ".join(shlex.quote(tilde(x)) if x.startswith("/") else shlex.quote(x) for x in args)


def launch(screen, args):
    """Вернуть обычный терминал, запустить agentmeister args и спросить, вернуться ли в меню."""
    screen.close()
    print(dim(f"$ agentmeister {shown(args)}"), flush=True)
    return again(run(args))


def framed(screen, args):
    """Команду в рамке на этом же экране, без мигания. Ответ: вернуться ли в меню. При выходе по q вывод
    остается в обычном терминале, его можно прокрутить."""
    title = f"agentmeister {shown(args)}"
    installing = args[:1] == ["--harness"] and args[2:] == ["install"]
    code, out = run_framed(screen, [CM] + args, title, show_elapsed=installing)
    if restart_pending():
        screen.close()
        return False
    if show_output(screen, out, title, code):
        return True
    screen.close()
    print(dim(f"$ {title}"))
    text = out.plain()
    if text:
        print(text)
    return False


def live_details(s):
    import claude_live
    label, _ = claude_live.STATUS.get(s.get("status"), (s.get("status") or "?", ""))
    facts = [("папка", tilde(str(s.get("cwd") or "?"))), ("состояние", label.strip()),
             ("с тех пор", claude_live.ago(s.get("statusUpdatedAt"))), ("pid", str(s.get("pid") or "?"))]
    return ([f"\x1b[1m{claude_live.title(s)}\x1b[0m", ""] + [dim(f"{k:<11}") + v for k, v in facts if v]
            + ["", tr("Enter переключит на вкладку этой сессии.", "Enter switches to this session's tab.")])


def live_sessions(screen):
    """Запущенные сессии на этом же экране. Enter переключает на вкладку. Ответ: строка для заголовка."""
    import claude_live
    ss = claude_live.live()
    if not ss:
        return tr("открытых сессий нет", "no open sessions")
    at = screen.pick([(f"{claude_live.title(s)} {s.get('cwd')}", claude_live.row(s)) for s in ss],
                     title=tr(f"Открытые сессии ({len(ss)})", f"Open sessions ({len(ss)})"),
                     describe=lambda i, w: live_details(ss[i]))
    if at is None:
        return ""
    if claude_live.jump(ss[at]):
        return tr("переключил на вкладку", "switched to the tab")
    return tr(f"не нашел вкладку, сессия в {tilde(str(ss[at].get('cwd') or '?'))}",
              f"tab not found, the session is in {tilde(str(ss[at].get('cwd') or '?'))}")


def switch(screen, name):
    """Переключить режим на месте. Возвращает строку для заголовка меню."""
    want = "off" if mode_on(name) else "on"
    import claude_lid
    if name == "lid" and want == "on" and not claude_lid.ready():
        # правила sudoers еще нет: lid on поставит его и спросит пароль sudo, это надо видеть
        code, out = run_framed(screen, [CM, "lid", "on"], "agentmeister lid on")
        if code != 0:
            show_output(screen, out, "agentmeister lid on", code)
    else:
        done = subprocess.run([CM, name, want], capture_output=True, text=True)
        if done.returncode != 0:
            last = (done.stderr or done.stdout).strip().splitlines()
            return tr(f"{name}: не переключилось", f"{name}: did not switch") + (f" ({last[-1][:60]})" if last else "")
    return f"{name}: " + (tr("включено", "on") if mode_on(name) else tr("выключено", "off"))


def main():
    screen = Screen()
    try:
        return loop(screen)
    except Quit:
        return 0
    finally:
        screen.close()


def choose_harness(screen):
    if not codex_harness.executable():
        return "claude"
    if not shutil.which(os.environ.get("MNRH_CLAUDE_BIN", "claude")):
        return "codex"
    options = [("claude", "Claude Code"), ("codex", "Codex")]
    i = screen.pick(options, title=tr("Агент", "Agent"), default=0, start=0)
    return options[i][0] if i is not None else None


def saved_codex(screen):
    from codex_sessions import session_list

    cwd = os.getcwd()
    found = session_list(cwd)
    if not found:
        return tr("В этой папке нет сессий Codex", "No Codex sessions in this folder")
    items, describe, title, sessions = found
    picked = screen.pick(items[1:], title=title, start=0, describe=lambda i, width: describe(i + 1, width))
    if picked is not None:
        state = open_flow.flow(screen, cwd, ask_session=False, harness="codex")
        if state is not None:
            state["sid"] = sessions[picked]["id"]
            return launch(screen, open_flow.command(state, "codex"))
    return True


def loop(screen):
    """Подменю (проект, сессии, запущенные) идут на том же экране, он закрывается только перед запуском команды."""
    at, note = 1, ""
    while True:
        at = pick_action(screen, at, note)
        if at is None:
            return 0
        note = ""
        key = ITEMS[at][0]
        if key == "quit":
            return 0
        if key.startswith("mode "):
            note = switch(screen, key.split()[1])
            continue
        if key in ("open", "root"):
            harness = choose_harness(screen)
            if harness is None:
                continue
            state = open_flow.flow(screen, HOME if key == "root" else None, harness=harness)
            if state is not None and not launch(screen, open_flow.command(state, harness)):
                return 0
            continue
        if key == "sessions":
            harness = choose_harness(screen)
            if harness is None:
                continue
            if harness == "codex":
                got = saved_codex(screen)
                if got is False:
                    return 0
                if isinstance(got, str):
                    note = got
                continue
            got = claude_sessions.browse(screen)
            if isinstance(got, str):
                note = got
            elif got:
                _, s, mode = got
                if not launch(screen, ["sessions", "resume", s["id"]] + (["-n"] if mode == "normal" else [])):
                    return 0
            continue
        if key == "ps":
            note = live_sessions(screen)
            continue
        if not framed(screen, shlex.split(key)):
            return 0


if __name__ == "__main__":
    sys.exit(main())
