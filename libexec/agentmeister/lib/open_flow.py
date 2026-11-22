#!/usr/bin/env python3
"""Вопросы перед запуском Claude Code на одном экране: проект, сессия, режим, сеть.

Esc возвращает на шаг назад, на первом шаге отменяет все. Экран не закрывается между шагами, поэтому
меню не мигает. Зовут его главное меню (функция flow) и claude.sh (командная строка, ответ четырьмя строками).
"""
import argparse
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from menu import Quit, Screen  # noqa: E402
from mnrhlib import HOME, projects_dir, tilde  # noqa: E402

SKIP = object()


def dim(text):
    return f"\x1b[2m{text}\x1b[0m"


def bold(text):
    return f"\x1b[1m{text}\x1b[0m"


def project_dirs(dev=None):
    """Папки проектов без скрытых папок и ссылок на соседний проект."""
    dev = dev or projects_dir()
    try:
        with os.scandir(dev) as entries:
            folders = [e for e in entries if not e.name.startswith(".") and e.is_dir()]
    except OSError:
        return []
    real_folders = {os.path.realpath(e.path) for e in folders if not e.is_symlink()}
    return [e.path for e in sorted(folders, key=lambda e: e.name.lower())
            if not e.is_symlink() or os.path.realpath(e.path) not in real_folders]


def git_info(path):
    """(ветка, [(когда, тема)] трех последних коммитов). Не git-папка: ("", [])."""
    def git(*args):
        try:
            return subprocess.run(["git", "-C", path] + list(args), capture_output=True, text=True,
                                  timeout=5).stdout
        except (OSError, subprocess.TimeoutExpired):
            return ""
    branch = git("branch", "--show-current").strip()
    log = [line.split("\x1f", 1) for line in git("log", "-3", "--format=%cr%x1f%s").splitlines() if "\x1f" in line]
    return branch, [(when, subj) for when, subj in log]


class Projects:
    """Список проектов. git спрашивается один раз за весь проход и параллельно: 20 проектов это 40 вызовов."""

    def __init__(self):
        self.dev = projects_dir()
        self.dirs = project_dirs(self.dev)
        with ThreadPoolExecutor(max_workers=8) as pool:
            self.info = list(pool.map(git_info, self.dirs))
        wide = max([10] + [len(os.path.basename(d)) for d in self.dirs])
        self.items = [("~", "🏠 ~ (домашний каталог)")]
        for d, (branch, log) in zip(self.dirs, self.info):
            name = os.path.basename(d)
            last = log[0][0] if log else ""
            self.items.append((name, f"📁 {name:<{wide}}  {(branch or '-')[:18]:<18}  {last}"))

    def describe(self, i, w):
        if i == 0:
            return [bold("Домашняя папка"), "~", "", "Сессия откроется вне проекта."]
        d = self.dirs[i - 1]
        branch, log = self.info[i - 1]
        lines = [bold(os.path.basename(d)), tilde(d)]
        if branch:
            lines.append(f"ветка {branch}")
        if not log:
            return lines + ["", "не git-репозиторий"]
        lines += ["", dim("ПОСЛЕДНИЕ КОММИТЫ")]
        for when, subj in log:
            lines += [when, "  " + subj]
        return lines

    def pick(self, screen, current):
        default = 1 if current is None else (0 if current == HOME else
                                             (self.dirs.index(current) + 1 if current in self.dirs else 1))
        i = screen.pick(self.items, title=f"Проекты в {tilde(self.dev)}", default=default,
                        describe=self.describe, start=0)
        if i is None:
            return None
        return HOME if i == 0 else self.dirs[i - 1]


MODES = [("caffeinate", "☕ caffeinate",
          [bold("caffeinate"), "", "Mac не уснет, пока идет сессия. Удобно для долгих задач и Remote Control с "
           "телефона. Экран при этом гаснуть может.", "", "С закрытой крышкой на батарее Mac все равно уснет, если "
           "не включен agentmeister lid.", "", dim("БЕЗ ВОПРОСА"), "agentmeister ... -k"]),
         ("normal", "🌙 обычная",
          [bold("Обычная сессия"), "", "Mac засыпает по своим настройкам.", "",
           dim("БЕЗ ВОПРОСА"), "agentmeister ... -n"])]

def network_options(harness):
    if harness == "claude":
        detail = ("Запросы Claude к Anthropic идут через mihomo. При обрыве proxy они завершаются ошибкой. "
                  "SSH и локальные сервисы доступны.")
    else:
        detail = ("Сессия и ее дочерние процессы могут подключаться только к порту mihomo. "
                  "Если proxy недоступен, запросы обрываются. Прямой SSH заблокирован.")
    return [
        ("direct", "🔌 напрямую", [bold("Напрямую"), "", "Сессия ходит в сеть как обычно.", "",
                                  dim("БЕЗ ВОПРОСА"), "agentmeister ... -d"]),
        ("vps", "🌐 через proxy", [bold("Через proxy"), "", detail, "", dim("БЕЗ ВОПРОСА"), "agentmeister ... -x"]),
    ]


def choose(screen, options, title, current):
    keys = [k for k, _, _ in options]
    i = screen.pick([(k, label) for k, label, _ in options], title=title,
                    default=keys.index(current) if current in keys else 0,
                    describe=lambda i, w: options[i][2])
    return None if i is None else keys[i]


def proxy_ready():
    try:
        import claude_proxy
        return claude_proxy.configured()
    except Exception:
        return False


def flow(screen, dir=None, ask_session=True, mode=None, net=None, harness="claude"):
    """Пройти недостающие шаги. Ответ: {"dir", "sid", "mode", "net"} или None, если Esc на первом шаге.
    sid: "new" или id сессии. Шаги без вопроса (сессий нет) Esc тоже перескакивает."""
    import claude_proxy
    if harness == "codex":
        from codex_sessions import session_list
    else:
        from claude_sessions import session_list
    steps = []
    if dir is None:
        steps.append("project")
    if ask_session:
        steps.append("session")
    if mode is None:
        steps.append("mode")
    if net is None and proxy_ready():
        steps.append("net")
    state = {"dir": dir, "sid": "new", "mode": mode or "caffeinate",
             "net": net or (claude_proxy.last() if "net" in steps else "direct")}
    if state["net"] not in ("vps", "direct"):
        state["net"] = "direct"
    projects, session_lists, skipped, k = None, {}, {}, 0
    while k < len(steps):
        step = steps[k]
        if step == "project":
            projects = projects or Projects()
            got = projects.pick(screen, state["dir"])
        elif step == "session":
            if state["dir"] not in session_lists:
                session_lists[state["dir"]] = session_list(state["dir"])
            found = session_lists[state["dir"]]
            if not found:
                state["sid"] = "new"
                got = SKIP
            else:
                items, describe, title, ss = found
                ids = ["new"] + [x["id"] for x in ss]
                i = screen.pick(items, title=title, describe=describe, start=0,
                                default=ids.index(state["sid"]) if state["sid"] in ids else 0)
                got = None if i is None else ids[i]
        elif step == "mode":
            got = choose(screen, MODES, f"Режим сессии в {tilde(state['dir'])}", state["mode"])
        else:
            got = choose(screen, network_options(harness), "Сеть", state["net"])
        if got is None:
            k -= 1
            while k >= 0 and skipped.get(k):
                k -= 1
            if k < 0:
                return None
            continue
        skipped[k] = got is SKIP
        if got is not SKIP:
            state[{"project": "dir", "session": "sid"}.get(step, step)] = got
        k += 1
    if "net" in steps:
        claude_proxy.remember(state["net"])
    return state


def command(state, harness="claude"):
    """Аргументы agentmeister, которые запустят выбранное без вопросов."""
    args = ["root" if state["dir"] == HOME else state["dir"],
            "-k" if state["mode"] == "caffeinate" else "-n",
            "-x" if state["net"] == "vps" else "-d"]
    if harness == "codex":
        resume = codex_resume_args(state["sid"], state["dir"])
        return ["--harness", "codex"] + args + (["--", *resume] if resume else ["--new"])
    return args + (["--new"] if state["sid"] == "new" else ["--", "--resume", state["sid"]])


def codex_resume_args(sid, cwd):
    if sid == "new":
        return []
    if sid == "resume":
        return ["resume"]
    return ["resume", "-C", cwd, sid]


def main(argv=None):
    p = argparse.ArgumentParser(description="вопросы перед запуском; ответ: папка, сессия, режим, сеть по строке")
    p.add_argument("--dir")
    p.add_argument("--no-session", action="store_true")
    p.add_argument("--mode", choices=("caffeinate", "normal"))
    p.add_argument("--net", choices=("vps", "direct"))
    a = p.parse_args(argv)
    screen = Screen()
    try:
        state = flow(screen, a.dir, not a.no_session, a.mode, a.net)
    except Quit:
        state = None
    finally:
        screen.close()
    if state is None:
        return 130
    print("\n".join([state["dir"], state["sid"], state["mode"], state["net"]]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
