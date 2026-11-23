"""Launch Claude Code in an iTerm2 tab or a terminal window."""
import json
import os
import re
import shlex
import subprocess
import time

from mnrhlib import HOME, LOCAL_CLI, projects_dir, run, settings_path, tilde

OPEN = {
    "Apple_Terminal": '''
on run argv
  tell application "Terminal"
    activate
    set t to do script (item 1 of argv)
    return tty of t
  end tell
end run''',
    "iTerm.app": '''
on run argv
  set launchLine to item 1 of argv
  set placement to item 2 of argv
  set openTab to (placement is "tab")
  tell application id "com.googlecode.iterm2"
    if placement is "auto" then set openTab to ((count of windows) > 0)
    if openTab then
      if not running then error "No open iTerm2 window"
      if (count of windows) is 0 then error "No open iTerm2 window"
      tell current window to set newTab to (create tab with default profile)
      set targetSession to current session of newTab
    else
      set newWindow to (create window with default profile)
      set targetSession to current session of newWindow
    end if
    activate
    tell targetSession
      write text launchLine
      return tty
    end tell
  end tell
end run''',
}
# текст вкладки по tty: отсюда берём ссылку Remote Control
READ = {
    "Apple_Terminal": '''
on run argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is (item 1 of argv) then return (get history of t) as text
      end repeat
    end repeat
  end tell
  return ""
end run''',
    "iTerm.app": '''
on run argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if tty of s is (item 1 of argv) then return contents of s
        end repeat
      end repeat
    end repeat
  end tell
  return ""
end run''',
}
MODES = {"caffeinate": "-k", "normal": "-n"}
CLAUDE_JSON = os.path.join(HOME, ".claude.json")
RC_URL = re.compile(r"https://claude\.ai/code/session_\w+")

TOOL = {
    "name": "open_claude",
    "description": (
        "Открыть новый Claude Code во вкладке iTerm2 или в окне Terminal "
        "через agentmeister. Вызови сначала без project: получишь список проектов и режимов — покажи его "
        "пользователю и спроси, что выбрать (если он уже назвал проект, можно сразу). Потом вызови с project "
        "(имя папки или начало имени, «~» — домашний каталог) и mode. Remote Control включается сразу, "
        "ссылка на сессию (claude.ai/code) приходит в ответе — дай её пользователю. "
        "Результат — где открылось и запустился ли Claude."),
    "inputSchema": {
        "type": "object",
        "properties": {
            "project": {"type": "string", "description": "проект: имя папки или его начало; «~» — домашний каталог"},
            "placement": {"type": "string", "enum": ["tab", "window"],
                          "description": "tab открывает вкладку в текущем окне iTerm2. По умолчанию в iTerm2 "
                                         "открывается вкладка, в Terminal окно. window явно запрашивает окно."},
            "mode": {"type": "string", "enum": ["caffeinate", "normal"],
                     "description": "caffeinate — Mac не уснёт, пока идёт сессия (по умолчанию); normal — обычная"},
            "prompt": {"type": "string", "description": "первый запрос для нового Claude (необязательно)"},
            "continue": {"type": "boolean", "description": "продолжить последнюю сессию в этом проекте (claude --continue)"},
            "trust": {"type": "boolean",
                      "description": "отметить папку доверенной, если Claude Code ещё не доверяет ей. Ставь только "
                                     "после явного согласия пользователя на вопрос о доверии этой папке"},
            "remote_control": {"type": "boolean", "default": True,
                               "description": "включить Remote Control (/rc): сессию можно вести с телефона и в браузере; "
                                              "по умолчанию да"},
        },
    },
}


def project_dirs():
    root = projects_dir()
    if not os.path.isdir(root):
        return root, []
    return root, sorted(os.path.join(root, d) for d in os.listdir(root)
                        if os.path.isdir(os.path.join(root, d)) and not d.startswith("."))


def git_line(d):
    branch = run(["git", "-C", d, "branch", "--show-current"], timeout=5).strip()
    last = run(["git", "-C", d, "log", "-1", "--format=%cr"], timeout=5).strip()
    return f"{branch or '-'}, {last}" if last else (branch or "не git")


def choices(root, dirs, note=""):
    lines = [note] if note else []
    lines.append(f"Проекты в {tilde(root)} (ветка, последний коммит):")
    lines.append("  ~  домашний каталог")
    lines += [f"  {os.path.basename(d)}  ({git_line(d)})" for d in dirs]
    lines.append("")
    lines.append("Режим: caffeinate — Mac не уснёт, пока идёт сессия (по умолчанию); normal — обычная.")
    lines.append("Можно добавить первый запрос (prompt) или продолжить прошлую сессию (continue).")
    lines.append("Покажи список пользователю и спроси, какой проект и режим открыть, "
                 "затем вызови open_claude с project и mode.")
    return "\n".join(lines)


def match(query, dirs):
    if query in ("~", "root", "home", HOME):
        return [HOME]
    q = query.lower()
    exact = [d for d in dirs if os.path.basename(d).lower() == q]
    return exact or [d for d in dirs if os.path.basename(d).lower().startswith(q)]


def trusted(path):
    """Доверяет ли Claude Code папке: сам Claude смотрит её и все папки выше."""
    try:
        with open(CLAUDE_JSON) as f:
            projects = json.load(f).get("projects") or {}
    except (OSError, ValueError):
        return False
    d = os.path.abspath(path)
    while True:
        if (projects.get(d) or {}).get("hasTrustDialogAccepted"):
            return True
        parent = os.path.dirname(d)
        if parent == d:
            return False
        d = parent


def trust(path):
    """То же, что ответ «Yes, I trust this folder» в окне Claude Code."""
    with open(CLAUDE_JSON) as f:
        data = json.load(f)
    data.setdefault("projects", {}).setdefault(os.path.abspath(path), {})["hasTrustDialogAccepted"] = True
    import claude_settings
    claude_settings.save_atomic(data, CLAUDE_JSON)


def terminal():
    term = os.environ.get("TERM_PROGRAM", "")
    return term if term in OPEN else "Apple_Terminal"


def claude_on(tty):
    """pid Claude Code на этом терминале, если он уже поднялся."""
    out = run(["ps", "-t", tty.replace("/dev/", ""), "-o", "pid=,command="], timeout=5)
    for line in out.splitlines():
        pid, _, cmd = line.strip().partition(" ")
        words = cmd.split()
        if words and (os.path.basename(words[0]) == "claude" or
                      os.path.basename(words[0]) == "node" and any(w.endswith("/claude") for w in words[1:2])):
            return int(pid)
    return None


def open_claude(args, cm):
    """-> (текст, ошибка ли)"""
    root, dirs = project_dirs()
    project = (args.get("project") or "").strip()
    direct = args.get("path")
    if direct:
        found = [os.path.abspath(direct)]
    elif not project:
        return choices(root, dirs), False
    else:
        found = match(project, dirs)
    if len(found) != 1:
        note = (f"«{project}» подходит к нескольким: {', '.join(os.path.basename(d) for d in found)}." if found
                else f"Проекта «{project}» нет в {tilde(root)}.")
        return choices(root, dirs, note), True
    target = found[0]
    mode = args.get("mode") or "caffeinate"
    if mode not in MODES:
        return f"Режим бывает caffeinate или normal, а не «{mode}».", True

    term = terminal()
    placement = args.get("placement", "tab" if term == "iTerm.app" else "window")
    if placement not in ("tab", "window"):
        return "placement должен быть tab или window", True
    if placement == "tab":
        term = "iTerm.app"
    destination = "новую вкладку" if placement == "tab" else "новое окно"

    if not trusted(target):
        if args.get("trust") is not True:
            return (f"Claude Code ещё не доверяет папке {tilde(target)}. При запуске он спросит «Do you trust "
                    "the files in this folder?», ответить через Remote Control нельзя, и сессия так и будет ждать. "
                    "Спроси пользователя, доверяет ли он этой папке, и если да, вызови open_claude ещё раз "
                    "с теми же параметрами и trust: true."), True
        try:
            trust(target)
        except (OSError, ValueError) as e:
            return f"Не отметил {tilde(target)} доверенной в {tilde(CLAUDE_JSON)}: {e}", True

    name = "~" if target == HOME else os.path.basename(target)
    # из сессии через proxy новое окно тоже идёт через proxy, иначе напрямую, без вопроса в меню
    net = "-x" if os.environ.get("MNRH_PROXY") else "-d"
    cmd = [LOCAL_CLI if net == "-x" else cm, "open", target if direct else name, MODES[mode], net, "--new"]
    rc = args.get("remote_control", True) is not False
    # имя у --remote-control необязательное: без него первый запрос принялся бы за имя
    extra = (["--remote-control", "home" if name == "~" else name] if rc else []) + \
        (["--continue"] if args.get("continue") else []) + list(args.get("flags") or []) + \
        ([args["prompt"]] if args.get("prompt") else [])
    if extra:
        cmd += ["--"] + extra
    line = " ".join(shlex.quote(c) for c in cmd)

    if term == "iTerm.app" and "placement" not in args:
        placement = "auto"
        destination = "новую сессию"
    script_args = [line, placement] if term == "iTerm.app" else [line]
    try:
        r = subprocess.run(["osascript", "-e", OPEN[term], *script_args], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"Не удалось подтвердить запуск через AppleScript ({exc.__class__.__name__}). Проверь терминал.", True
    tty = r.stdout.strip()
    app = "iTerm2" if term == "iTerm.app" else "Terminal"
    if r.returncode or not tty.startswith("/dev/"):
        err = (r.stderr or r.stdout).strip()
        hint = (f" Нужно разрешение: {settings_path('settings', 'privacy', 'automation')} → разрешить управлять "
                f"{app}.") if "-1743" in err or "not allowed" in err.lower() else ""
        if placement in ("tab", "auto"):
            hint += f" В iTerm2 нажми ⌘T и выполни в новой вкладке:\n{line}"
        return f"Не удалось подтвердить запуск в {app} ({err or 'osascript без ответа'}).{hint}", True

    pid = None
    for _ in range(40):  # до 20 секунд: caffeinate, node, первый запуск
        pid = claude_on(tty)
        if pid:
            break
        time.sleep(0.5)
    where = f"{tilde(target)}, режим {mode}" + (", через proxy" if net == "-x" else "")
    url = remote_url(term, tty) if pid and rc else ""
    if pid:
        text = f"Открыл {destination} {app} ({tty}): Claude Code запущен в {where}, pid {pid}."
        if url:
            text += f" Remote Control включён: {url}"
        elif rc:
            text += " Remote Control запрошен, но ссылка за 20 секунд не появилась — проверь терминал."
    else:
        text = (f"Открыл {destination} {app} ({tty}) и запустил там `{' '.join(cmd[1:])}`, но за 20 секунд "
                f"Claude Code не появился — проверь терминал ({where}).")
    if args.get("prompt"):
        text += " Первый запрос передан."
    return text, not pid


def remote_url(term, tty):
    """Ссылка на сессию Remote Control из текста вкладки; ждём до 20 секунд."""
    for _ in range(40):
        r = subprocess.run(["osascript", "-e", READ[term], tty], capture_output=True, text=True, timeout=15)
        found = RC_URL.findall(r.stdout)
        if found:
            return found[-1]
        time.sleep(0.5)
    return ""
