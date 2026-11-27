import calendar
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import HOME, project_root, read_config, run, tilde, tr
import claude_search
import mnrh_todo

LAST_CHARS = 1500
ASK_CHARS = 400


def enabled():
    return read_config().get("brief", "on") != "off"


def clip(text, n):
    text = re.sub(r"\n{3,}", "\n\n", (text or "").strip())
    return text if len(text) <= n else text[: n - 1].rstrip() + "…"


def ago(ts):
    if not ts:
        return "?"
    try:
        t = calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return ts[:16]
    s = time.time() - t
    if s < 3600:
        n = max(1, int(s // 60))
        return tr(f"{n} мин назад", f"{n} min ago")
    if s < 86400:
        return tr(f"{int(s // 3600)} ч назад", f"{int(s // 3600)} h ago")
    if s < 2 * 86400:
        return tr("вчера", "yesterday")
    return tr(f"{int(s // 86400)} дн назад", f"{int(s // 86400)} days ago")


def git_part(root):
    if not os.path.isdir(os.path.join(root, ".git")) and not run(["git", "-C", root, "rev-parse", "--git-dir"]).strip():
        return [], {}
    branch = run(["git", "-C", root, "branch", "--show-current"]).strip() or "(detached)"
    status = run(["git", "-C", root, "status", "--porcelain"]).splitlines()
    ahead = run(["git", "-C", root, "rev-list", "--count", "@{u}..HEAD"]).strip()
    log = run(["git", "-C", root, "log", "-5", "--format=%h %ar: %s"]).strip().splitlines()
    tag = run(["git", "-C", root, "describe", "--tags", "--abbrev=0"]).strip()
    since = run(["git", "-C", root, "rev-list", "--count", f"{tag}..HEAD"]).strip() if tag else ""
    head = tr(f"Ветка {branch}", f"Branch {branch}")
    if status:
        head += tr(f", незакоммичено файлов: {len(status)}", f", uncommitted files: {len(status)}")
    if ahead and ahead != "0":
        head += tr(f", не запушено коммитов: {ahead}", f", unpushed commits: {ahead}")
    lines = [head]
    if tag:
        lines.append(tr(f"Последний тег {tag}, коммитов после него: {since or '?'}",
                        f"Last tag {tag}, commits since: {since or '?'}"))
    if log:
        lines.append(tr("Последние коммиты:", "Recent commits:"))
        lines += [f"  {l}" for l in log]
    return lines, {"branch": branch, "dirty": len(status), "ahead": ahead}


def last_session(root, cwd, exclude=None):
    from session_store import encode, is_junk
    best = []
    for cwd in {root, os.path.abspath(cwd)}:
        pdir = os.path.join(claude_search.PROJECTS, encode(cwd))
        try:
            names = os.listdir(pdir)
        except OSError:
            continue
        for f in names:
            sid = f[:-6]
            path = os.path.join(pdir, f)
            if not f.endswith(".jsonl") or sid == exclude or not claude_search.UUID.match(sid) or os.path.islink(path):
                continue
            try:
                best.append((os.path.getmtime(path), sid, path))
            except OSError:  # пустую сессию как раз удалила уборка при старте
                continue
    for _, sid, path in sorted(best, reverse=True):
        if is_junk(path):
            continue
        data = claude_search.update(sid, path)
        if data and any(m[0] == "claude" for m in data["msgs"]):
            return sid, data
    return None, None


def session_part(sid, data):
    msgs = data["msgs"]
    asks = [m for m in msgs if m[0] == "user"]
    replies = [m for m in msgs if m[0] == "claude"]
    title = claude_search.title(sid, data)
    lines = [tr(f"Прошлая сессия в этом проекте: «{title}» ({sid[:8]}), последняя активность {ago(data.get('last'))}",
                f"Previous session in this project: \"{title}\" ({sid[:8]}), last active {ago(data.get('last'))}")]
    if asks:
        lines.append(tr("Последний запрос пользователя:", "The user's last request:"))
        lines.append(clip(asks[-1][2], ASK_CHARS))
    if replies:
        lines.append(tr("Последний ответ Claude:", "Claude's last reply:"))
        lines.append(clip(replies[-1][2], LAST_CHARS))
    return lines, title


def build(cwd, exclude=None):
    root = project_root(cwd)
    name = "~" if root == HOME else os.path.basename(root)
    lines = [tr(f"Проект {name} ({tilde(root)}).", f"Project {name} ({tilde(root)}).")]
    git_lines, g = git_part(root)
    lines += git_lines
    sid, data = last_session(root, cwd, exclude)
    title = None
    if data:
        sess, title = session_part(sid, data)
        lines += [""] + sess
        lines.append(tr(f"Подробнее: session_read id={sid[:8]} at=-10.", f"More: session_read id={sid[:8]} at=-10."))
    todos = mnrh_todo.open_items(root)
    if todos:
        lines += ["", mnrh_todo.fmt(root, todos)]
    short = []
    if title:
        short.append(tr(f"прошлая сессия «{clip(title, 50)}» ({ago(data.get('last'))})",
                        f"previous session \"{clip(title, 50)}\" ({ago(data.get('last'))})"))
    if g.get("dirty"):
        short.append(tr(f"незакоммичено {g['dirty']}", f"uncommitted {g['dirty']}"))
    if todos:
        short.append(tr(f"в бэклоге {len(todos)}", f"backlog {len(todos)}"))
    return "\n".join(lines), short


def context_for_model(cwd, exclude=None):
    text, short = build(cwd, exclude)
    head = tr("agentmeister: справка о проекте на старте сессии. Это фон: не пересказывай её без запроса, но используй, "
              "когда пользователь спрашивает, где остановились, что дальше или ссылается на прошлую работу.\n\n",
              "agentmeister: project notes at session start. This is background: don't retell it unprompted, but use "
              "it when the user asks where things stand, what's next, or refers to earlier work.\n\n")
    user = ("agentmeister: " + " · ".join(short) + tr(" · /where — подробнее", " · /where for more")) if short else ""
    return head + text, user


def cli(args):
    if args[:1] in (["-h"], ["--help"]):
        print(tr("agentmeister brief         где мы остановились: git, прошлая сессия в этом проекте, бэклог",
                 "agentmeister brief         where things stand: git, the previous session in this project, backlog"))
        print(tr("agentmeister brief on|off  показывать ли эту справку Claude при старте новой сессии",
                 "agentmeister brief on|off  whether Claude gets these notes when a new session starts"))
        print()
        print(tr("В Claude Code: /where. При старте новой сессии хук SessionStart передаёт справку Claude\n"
                 "как фон, а тебе показывает одну строку.",
                 "In Claude Code: /where. When a new session starts, the SessionStart hook passes the notes to\n"
                 "Claude as background and shows you one line."))
        return 0
    if args[:1] in (["on"], ["off"]):
        from mnrhlib import write_config
        write_config(brief=args[0])
        print(tr(f"Справка при старте сессии {'включена' if args[0] == 'on' else 'выключена'}",
                 f"Session-start notes {'on' if args[0] == 'on' else 'off'}"))
        return 0
    exclude = os.environ.get("CLAUDE_CODE_SESSION_ID")
    text, _ = build(os.getcwd(), exclude)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(cli(sys.argv[2:] if sys.argv[1:2] == ["brief"] else sys.argv[1:]))
