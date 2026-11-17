"""Меню действий claudemeister: claudemeister без аргументов в терминале.

Действие запускается как claudemeister <аргументы>, полная команда печатается, чтобы в следующий раз набрать ее
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
from mnrhlib import CM, DEV, HOME, RESTART_QUEUE, ROOT, tilde, tr  # noqa: E402
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
     "Сессии в текущей папке. Любую можно продолжить, перенести в другой проект или удалить.",
     "Sessions in the current folder. Resume any of them, move it to another project or delete it."),
    ("ps", "👀", "Запущенные сессии", "Running sessions",
     "Какие сессии Claude Code сейчас открыты и какая из них ждет ответа. Из списка можно перейти во вкладку.",
     "Which Claude Code sessions are open right now and which one is waiting for you. Jump to its tab "
     "from the list."),
    ("restore", "🔄", "Вернуть сессии", "Reopen sessions",
     "Открыть заново сессии, которые были запущены до перезагрузки Mac или сбоя терминала.",
     "Reopen the sessions that were running before a reboot or a terminal crash."),
    ("usage", "📊", "Расход", "Usage",
     "Токены и активное время по проектам и моделям за последние 7 дней. Другой срок и проект задают "
     "claudemeister usage --days N --project P.",
     "Tokens and active time per project and model for the last 7 days. Pick another range or project "
     "with claudemeister usage --days N --project P."),
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
     "Уведомление на Mac, когда Claude просит разрешение, задает вопрос или закончил долгий ход, а вы смотрите "
     "в другую вкладку. Telegram подключает claudemeister notify telegram.",
     "A Mac notification when Claude asks for permission, asks a question or finishes a long turn while you "
     "look at another tab. claudemeister notify telegram adds Telegram."),
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
    ("setup", "🧰", "Настроить Claude Code", "Set up Claude Code",
     "Поставить команды /restart, /forget и другие, хуки Claude Code, хук zsh и MCP-сервер claudemeister. "
     "Прокси тоже настроит, если его еще нет.",
     "Install /restart, /forget and the other commands, Claude Code hooks, the zsh hook and the claudemeister "
     "MCP server. Sets up the proxy too if it is missing."),
    ("--harness codex setup", "🧰", "Настроить Codex", "Set up Codex",
     "Подключить хуки humanize и MCP с задачами проекта и проверкой зависимостей Gradle.",
     "Install the humanize hooks and MCP tools for project tasks and Gradle dependencies."),
    ("mode alias", "🔤", "Короткое имя cm", "Short name cm",
     "Команда cm вместо claudemeister: cm open, cm sessions и так далее. Ставится ссылкой рядом с claudemeister. "
     "Если имя cm уже занято другой программой, claudemeister его не тронет.",
     "The cm command instead of claudemeister: cm open, cm sessions and so on. It is a link next to claudemeister. "
     "If another program already owns the name cm, claudemeister leaves it alone."),
    ("doctor", "🔍", "Проверить установку", "Check the install",
     "Проверить, что claudemeister в PATH, Claude Code найден, а хуки и MCP-сервер на месте.",
     "Check that claudemeister is on PATH, Claude Code is found and the hooks and MCP server are in place."),
    ("help", "❓", "Справка", "Help",
     "Все команды claudemeister с флагами.",
     "Every claudemeister command with its flags."),
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
        self.fresh = False
        try:
            from claude_proc import claude_version
            self.claude = claude_version() or "?"
        except Exception:
            self.claude = "?"
        threading.Thread(target=self.ask_proxy, daemon=True).start()

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
        self.proxy, self.fresh = text, True

    def dirty(self):
        fresh, self.fresh = self.fresh, False
        return fresh

    def __call__(self, i, w):
        key, _, ru, en, desc_ru, desc_en = ITEMS[i]
        lines = [f"\x1b[1m{tr(ru, en)}\x1b[0m", ""]
        lines += textwrap.wrap(tr(desc_ru, desc_en), w) or [""]
        if key.startswith("mode "):
            flag = self.state.get(key.split()[1])
            lines += ["", ("\x1b[32m" + tr("Сейчас включено", "On now") + "\x1b[0m" if flag else
                           tr("Сейчас выключено", "Off now")) + dim(tr(", Enter переключит", ", Enter switches it"))]
        if key not in ("quit",):
            lines += ["", dim(f"$ claudemeister {command(key, self.state)}")]
        on = [name for name, flag in self.state.items() if flag and name != "alias"]
        facts = [(tr("Версия", "Version"), version()),
                 ("Claude Code", self.claude),
                 (tr("Папка", "Folder"), tilde(os.getcwd())),
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
    """Вернуть обычный терминал, запустить claudemeister args и спросить, вернуться ли в меню."""
    screen.close()
    print(dim(f"$ agentmeister {shown(args)}"), flush=True)
    return again(run(args))


def framed(screen, args):
    """Команду в рамке на этом же экране, без мигания. Ответ: вернуться ли в меню. При выходе по q вывод
    остается в обычном терминале, его можно прокрутить."""
    title = f"agentmeister {shown(args)}"
    code, out = run_framed(screen, [CM] + args, title)
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
        code, out = run_framed(screen, [CM, "lid", "on"], "claudemeister lid on")
        if code != 0:
            show_output(screen, out, "claudemeister lid on", code)
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
