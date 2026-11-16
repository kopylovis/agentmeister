"""Меню действий claudemeister: claudemeister без аргументов в терминале.

Действие запускается как claudemeister <аргументы>, полная команда печатается, чтобы в следующий раз набрать ее
сразу. После действия можно вернуться в меню. Режимы (humanize, guard, buildlog, уведомления, крышка) по Enter
переключаются на месте: меню остается и показывает новое состояние. Язык берется из mnrhlib.lang().
"""
import os
import shlex
import signal
import subprocess
import sys
import textwrap
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from menu import choice, panel, pick  # noqa: E402
from mnrhlib import CM, DEV, RESTART_QUEUE, ROOT, tilde, tr  # noqa: E402

# (команда, значок, по-русски, по-английски, описание по-русски, по-английски). Группа: команда None.
# Режим: "mode <имя>", Enter переключает его. Значки только шириной в две клетки, без VS16: иначе едут рамки.
ITEMS = [
    (None, "", "Сессии", "Sessions", "", ""),
    ("open", "📂", "Открыть проект", "Open a project",
     "Выбрать проект в папке проектов и запустить в нем Claude Code. Если в проекте есть сохраненные сессии, "
     "claudemeister предложит продолжить одну из них.",
     "Pick a project in the projects folder and start Claude Code there. If the project has saved sessions, "
     "claudemeister offers to resume one."),
    ("root", "🏠", "Открыть в домашней папке", "Open in the home folder",
     "Запустить Claude Code в домашней папке, без привязки к проекту.",
     "Start Claude Code in the home folder, outside any project."),
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
        on = [name for name, flag in self.state.items() if flag]
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


def pick_action(at=1, note=""):
    title = f"\x1b[1;35mclaudemeister\x1b[0m  {dim('v' + version())}" + (f"  \x1b[33m{note}\x1b[0m" if note else "")
    state = modes()
    items = rows(state)
    hint = tr("↑↓ выбрать · Enter запустить · буквы ищут · Tab описание · Esc выход",
              "↑↓ move · Enter run · type to search · Tab description · Esc quit")
    return panel(items, title=title, default=at, describe=Describe(state),
                 heads=(tr("Действия", "Actions"), tr("Описание", "Description")), hint=hint,
                 fallback=lambda: pick(items, title=title, esc=tr("выход", "quit"), default=at))


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


def switch(name):
    """Переключить режим на месте. Возвращает строку для заголовка меню."""
    want = "off" if mode_on(name) else "on"
    import claude_lid
    if name == "lid" and want == "on" and not claude_lid.ready():
        # правила sudoers еще нет: lid on поставит его и спросит пароль sudo, это надо видеть
        print(dim("$ claudemeister lid on"), flush=True)
        run(["lid", "on"])
    else:
        done = subprocess.run([CM, name, want], capture_output=True, text=True)
        if done.returncode != 0:
            last = (done.stderr or done.stdout).strip().splitlines()
            return tr(f"{name}: не переключилось", f"{name}: did not switch") + (f" ({last[-1][:60]})" if last else "")
    return f"{name}: " + (tr("включено", "on") if mode_on(name) else tr("выключено", "off"))


def main():
    at, note = 1, ""
    while True:
        at = pick_action(at, note)
        if at is None:
            return 0
        note = ""
        key = ITEMS[at][0]
        if key == "quit":
            return 0
        if key.startswith("mode "):
            note = switch(key.split()[1])
            continue
        print(dim(f"$ claudemeister {key}"), flush=True)
        if not again(run(shlex.split(key))):
            return 0


if __name__ == "__main__":
    sys.exit(main())
