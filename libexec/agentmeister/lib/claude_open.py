"""Launch Claude Code in an iTerm2 tab or a terminal window."""
import json
import os
import re
import shlex
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import HOME, LOCAL_CLI, project_entries, project_folders, project_label, projects_dirs, run, settings_path, tilde, tr  # noqa: E402

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
    """(папки проектов для текста, проекты из всех них)."""
    return ", ".join(tilde(d) for d in projects_dirs()), project_folders()


def git_line(d):
    branch = run(["git", "-C", d, "branch", "--show-current"], timeout=5).strip()
    last = run(["git", "-C", d, "log", "-1", "--format=%cr"], timeout=5).strip()
    return f"{branch or '-'}, {last}" if last else (branch or "не git")


def choices(root, dirs, note=""):
    lines = [note] if note else []
    lines.append(f"Проекты в {root} (ветка, последний коммит):")
    lines.append("  ~  домашний каталог")
    lines += [f"  {project_label(d, dirs)}  ({git_line(d)})" for d in dirs]
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


def file_state(path):
    st = os.stat(path)
    return st.st_ino, st.st_size, st.st_mtime_ns


def trust(path, attempts=5):
    """То же, что ответ «Yes, I trust this folder» в окне Claude Code.
    ~/.claude.json всё время переписывают живые Claude Code: читаем прямо перед записью, пишем во временный файл
    рядом и подменяем его, только если файл за это время не менялся, иначе читаем заново."""
    target = os.path.realpath(CLAUDE_JSON)  # файл может быть ссылкой из dotfiles
    key = os.path.abspath(path)
    for _ in range(attempts):
        before = file_state(target)
        with open(target) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("в файле не объект JSON")
        projects = data.setdefault("projects", {})
        if not isinstance(projects, dict):
            raise ValueError("projects в файле не объект JSON")
        entry = projects.get(key) if isinstance(projects.get(key), dict) else {}
        entry["hasTrustDialogAccepted"] = True
        projects[key] = entry
        tmp = f"{target}.{os.getpid()}.mnrh-tmp"
        try:
            with open(tmp, "w") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
                f.write("\n")
            os.chmod(tmp, os.stat(target).st_mode & 0o7777)
            if file_state(target) == before:
                os.replace(tmp, target)
                return
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
        time.sleep(0.05)
    raise OSError(f"{tilde(CLAUDE_JSON)} всё время меняется, попробуй ещё раз")


def shell_word(arg):
    """Слово для строки, которую терминал наберет в zsh. Без управляющих символов это обычные кавычки,
    с ними $'...', чтобы перевод строки не стал нажатием Enter и вся команда осталась одной строкой."""
    if not any(ord(c) < 0x20 or 0x7f <= ord(c) <= 0x9f for c in arg):
        return shlex.quote(arg)
    out = []
    for c in arg:
        code = ord(c)
        if c in "\\'":
            out.append("\\" + c)
        elif c in "\n\t\r":
            out.append({"\n": "\\n", "\t": "\\t", "\r": "\\r"}[c])
        elif code < 0x20 or code == 0x7f:
            out.append(f"\\x{code:02x}")
        elif 0x80 <= code <= 0x9f:  # байты UTF-8: \u не знает bash 3.2 из macOS
            out.append("".join(f"\\x{b:02x}" for b in c.encode()))
        else:
            out.append(c)
    return "$'" + "".join(out) + "'"


def shell_line(argv):
    return " ".join(shell_word(a) for a in argv)


# Флаги agentmeister open, которые сессия может передать через host-run open. -d нет: сессия из песочницы
# не должна открывать сессию без нее. -x и --new добавляются всегда, без --new agentmeister спросил бы в меню.
HOST_FLAGS = {"-k": "-k", "--caffeinate": "-k", "-n": "-n", "--normal": "-n", "-i": "-i", "--incognito": "-i",
              "-x": None, "--proxy": None, "--new": None}


def host_open_command(argv):
    """Команда agentmeister open для host-run open <проект> [флаги] -- [аргументы claude]. Ошибка: ValueError."""
    if "--" in argv:
        cut = argv.index("--")
        head, tail = argv[:cut], argv[cut + 1:]
    else:
        head, tail = argv, []
    project, mode, incognito = None, None, False
    for arg in head:
        if arg in ("-d", "--direct"):
            raise ValueError(tr("host-run open открывает сессию только через proxy, -d нельзя",
                                "host-run open only opens proxied sessions, -d is not allowed"))
        if arg.startswith("-"):
            if arg not in HOST_FLAGS:
                raise ValueError(tr(f"флаг {arg} не подходит, можно -k, -n, -i, -x, --new",
                                    f"flag {arg} is not allowed, use -k, -n, -i, -x, --new"))
            if HOST_FLAGS[arg] == "-i":
                incognito = True
            elif HOST_FLAGS[arg]:
                mode = HOST_FLAGS[arg]
        elif project is None:
            project = arg
        else:
            raise ValueError(tr(f"лишний аргумент {arg}, аргументы claude пиши после --",
                                f"extra argument {arg}, put claude arguments after --"))
    if not project:
        raise ValueError(tr("нужен проект: host-run open <проект> [флаги agentmeister open] -- [аргументы claude]",
                            "a project is required: host-run open <project> [agentmeister open flags] -- [claude arguments]"))
    cmd = [LOCAL_CLI, "open", project, mode or "-k", "-x", "--new"] + (["-i"] if incognito else [])
    return cmd + (["--", *tail] if tail else [])


def open_tab(cmd):
    """Открыть вкладку в текущем окне iTerm2 и запустить там cmd. Это зовет исполнитель host-run вне песочницы.
    -> (текст, ошибка ли)"""
    tty, err = launch("iTerm.app", shell_line(cmd), "tab")
    if not tty:
        return tr(f"iTerm2 не открыл вкладку ({err}).", f"iTerm2 didn't open a tab ({err})."), True
    rc = "--remote-control" in cmd[cmd.index("--") + 1:] if "--" in cmd else False
    where = tr(f"{tilde(cmd[2])}, через proxy", f"{tilde(cmd[2])}, through the proxy")
    return report("iTerm.app", tty, cmd, tr("новую вкладку", "a new tab"), where, rc, prompt=False)


def launch(term, line, placement):
    """Набрать line в новой вкладке или окне. -> (tty, текст ошибки)"""
    script_args = [line, placement] if term == "iTerm.app" else [line]
    try:
        r = subprocess.run(["osascript", "-e", OPEN[term], *script_args], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, f"AppleScript: {exc.__class__.__name__}"
    tty = r.stdout.strip()
    if r.returncode or not tty.startswith("/dev/"):
        return None, (r.stderr or r.stdout).strip() or "osascript без ответа"
    return tty, ""


def via_host_run(cmd):
    """Попросить исполнитель host-run открыть вкладку вне песочницы. None, если исполнителя нет или он старый."""
    import io
    import host_run
    out, err = io.BytesIO(), io.StringIO()
    code = host_run.send_op({"op": "open", "argv": cmd[2:]}, out=out, err=err)
    if code == 125:
        return None
    text = (out.getvalue().decode(errors="replace") + err.getvalue()).strip()
    return text.replace("agentmeister host-run: ", ""), code != 0


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


APP_OPEN_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache"), "mnrh", "app", "open")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
APP_WAIT = 6.0  # приложение забирает запросы раз в секунду


def app_tab():
    """id вкладки десктопного Agentmeister, из которой идет эта сессия, или пусто."""
    tab = os.environ.get("AGENTMEISTER_TAB", "").lower()
    return tab if os.environ.get("TERM_PROGRAM") == "Agentmeister" and UUID_RE.match(tab) else ""


def via_app(request):
    """Попросить десктопный Agentmeister открыть вкладку: запрос файлом в APP_OPEN_DIR, приложение забирает его
    раз в секунду и пишет ответ <id>.reply.json. -> ответ dict или None, если сессия не во вкладке приложения
    или оно не ответило (старая версия, приложение закрыто): тогда открываем как раньше, в терминале."""
    tab = app_tab()
    if not tab:
        return None
    import uuid
    rid = str(uuid.uuid4())
    req = os.path.join(APP_OPEN_DIR, rid + ".json")
    reply = os.path.join(APP_OPEN_DIR, rid + ".reply.json")
    try:
        os.makedirs(APP_OPEN_DIR, exist_ok=True)
        tmp = req + ".tmp"
        with open(tmp, "w") as f:
            json.dump(dict(request, at=time.time(), **{"from": tab}), f)
        os.replace(tmp, req)
    except OSError:
        return None
    deadline = time.time() + APP_WAIT
    while time.time() < deadline:
        try:
            with open(reply) as f:
                answer = json.load(f)
            os.remove(reply)
            return answer if isinstance(answer, dict) else None
        except (OSError, ValueError):
            time.sleep(0.1)
    try:
        os.remove(req)  # приложение запрос так и не взяло
        return None
    except FileNotFoundError:
        return {"ok": True}  # взяло, но ответ не успел


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
        # по имени ищем и среди ссылок-псевдонимов, ссылка и ее папка считаются одним проектом
        found = list({os.path.realpath(d): d for d in match(project, project_entries())}.values())
    if len(found) != 1:
        note = (f"«{project}» подходит к нескольким: {', '.join(tilde(d) for d in found)}, укажи path." if found
                else f"Проекта «{project}» нет в {root}.")
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
    destination = tr("новую вкладку", "a new tab") if placement == "tab" else tr("новое окно", "a new window")

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
    line = shell_line(cmd)

    # параллельная задача из вкладки Agentmeister открывается там же подзадачей этой вкладки
    flags = (["--continue"] if args.get("continue") else []) + list(args.get("flags") or [])
    answer = None if not args.get("subtask") else via_app({"path": target, "name": args.get("name") or name, "prompt": args.get("prompt") or "",
                      "flags": flags, "awake": mode == "caffeinate", "remote_control": rc,
                      "subtask": bool(args.get("subtask"))})
    if answer is not None:
        if not answer.get("ok"):
            return tr(f"Agentmeister не открыл вкладку: {answer.get('error') or 'без причины'}.",
                      f"Agentmeister didn't open a tab: {answer.get('error') or 'no reason given'}."), True
        what = tr("подзадачу этой вкладки", "a subtask of this tab") if args.get("subtask") else tr("новую вкладку", "a new tab")
        text = tr(f"Открыл в Agentmeister {what}: Claude Code в {tilde(target)}, через proxy.",
                  f"Opened {what} in Agentmeister: Claude Code in {tilde(target)}, through the proxy.")
        if args.get("prompt"):
            text += tr(" Первый запрос передан.", " The first prompt was sent.")
        return text, False

    if term == "iTerm.app" and "placement" not in args:
        placement = "auto"
        destination = tr("новую сессию", "a new session")
    tty, err = launch(term, line, placement)
    app = "iTerm2" if term == "iTerm.app" else "Terminal"
    if not tty:
        tab = term == "iTerm.app" and placement in ("tab", "auto")
        if tab and net == "-x":
            # MCP-сервер сессии через proxy в песочнице, и iTerm2 его Apple Events не принимает (-10004).
            # Исполнитель host-run работает вне песочницы и откроет вкладку сам.
            answer = via_host_run(cmd)
            if answer:
                text, failed = answer
                if failed:
                    text += f" В iTerm2 нажми ⌘T и выполни в новой вкладке:\n{line}"
                return text, failed
        hint = (f" Нужно разрешение: {settings_path('settings', 'privacy', 'automation')} → разрешить управлять "
                f"{app}.") if "-1743" in err or "not allowed" in err.lower() else ""
        if tab:
            hint += f" В iTerm2 нажми ⌘T и выполни в новой вкладке:\n{line}"
        return f"Не удалось подтвердить запуск в {app} ({err}).{hint}", True

    where = tr(f"{tilde(target)}, режим {mode}", f"{tilde(target)}, mode {mode}") + \
        (tr(", через proxy", ", through the proxy") if net == "-x" else "")
    return report(term, tty, cmd, destination, where, rc, bool(args.get("prompt")))


def report(term, tty, cmd, destination, where, rc, prompt):
    """Дождаться Claude в терминале tty и ссылки Remote Control. -> (текст, ошибка ли)"""
    app = "iTerm2" if term == "iTerm.app" else "Terminal"
    pid = None
    for _ in range(40):  # до 20 секунд: caffeinate, node, первый запуск
        pid = claude_on(tty)
        if pid:
            break
        time.sleep(0.5)
    url = remote_url(term, tty) if pid and rc else ""
    if pid:
        text = tr(f"Открыл {destination} {app} ({tty}): Claude Code запущен в {where}, pid {pid}.",
                  f"Opened {destination} in {app} ({tty}): Claude Code is running in {where}, pid {pid}.")
        if url:
            text += tr(f" Remote Control включён: {url}", f" Remote Control is on: {url}")
        elif rc:
            text += tr(" Remote Control запрошен, но ссылка за 20 секунд не появилась — проверь терминал.",
                       " Remote Control was requested, but no link appeared in 20 seconds, check the terminal.")
    else:
        line = " ".join(cmd[1:])
        text = tr(f"Открыл {destination} {app} ({tty}) и запустил там `{line}`, но за 20 секунд "
                  f"Claude Code не появился — проверь терминал ({where}).",
                  f"Opened {destination} in {app} ({tty}) and ran `{line}` there, but Claude Code didn't show up "
                  f"in 20 seconds, check the terminal ({where}).")
    if prompt:
        text += tr(" Первый запрос передан.", " The first prompt was sent.")
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
