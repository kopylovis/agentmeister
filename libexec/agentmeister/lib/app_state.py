"""agentmeister app-state: состояние для десктопного Agentmeister одним JSON.

Приложение не разбирает вывод для людей и не дублирует логику CLI. Оно раз в несколько секунд спрашивает
эту команду: проекты из папки проектов, сохраненные сессии Claude Code, открытые сейчас сессии с их статусом
(ждет, работает, свободна), состояние proxy и режимов. Каждая часть собирается отдельно: если одна упала,
остальные приходят как обычно, а в errors остается причина.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mnrhlib  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
SESSION_LIMIT = 300


def version():
    try:
        with open(os.path.join(ROOT, "VERSION")) as f:
            return f.read().strip()
    except OSError:
        return ""


def projects():
    import open_flow
    return [{"name": os.path.basename(p), "path": p} for p in open_flow.project_dirs()]


def sessions():
    """Сохраненные сессии Claude Code, новые первыми. Пустые, без ответа Claude, приложению не нужны."""
    import session_store
    out = []
    for s in session_store.load():
        if s.get("link") or not s.get("answered"):
            continue
        out.append({
            "id": s["id"], "cwd": s["cwd"], "title": s.get("title") or "", "branch": s.get("branch") or "",
            "mtime": s["mtime"], "size": s["size"], "running": bool(s.get("running")),
        })
        if len(out) >= SESSION_LIMIT:
            break
    return out


def live():
    """Открытые сейчас сессии из реестра Claude Code: статус waiting, busy или idle."""
    import claude_live
    return [{"sessionId": s.get("sessionId"), "pid": s.get("pid"), "cwd": s.get("cwd"), "status": s.get("status"),
             "name": s.get("name"), "statusUpdatedAt": s.get("statusUpdatedAt")} for s in claude_live.live()]


def proxy():
    import claude_proxy
    configured = claude_proxy.configured()
    p = claude_proxy.port() if configured else None
    pid = claude_proxy.read_pid() if configured else None
    running = bool(pid and claude_proxy.listening(p))
    try:
        with open(claude_proxy.EXIT) as f:
            info = json.load(f)
    except (OSError, ValueError):
        info = {}
    loc = info.get("loc")
    try:
        held = len(claude_proxy.holders()) if configured else 0
    except OSError:  # holders спрашивает ps, а из песочницы proxy-сессии ps не запустить
        held = None
    return {"configured": configured, "running": running, "port": p,
            "exit": loc.upper() if isinstance(loc, str) and len(loc) == 2 else None,
            "protocol": info.get("proto") if isinstance(info.get("proto"), str) else None,
            "sessions": held}


def modes():
    import claude_menu
    return claude_menu.modes()


def collect():
    state = {"version": version(), "lang": mnrhlib.lang(), "projectsDir": mnrhlib.projects_dir(),
             "generatedAt": time.time(), "errors": {}}
    for name, part, empty in (("projects", projects, []), ("sessions", sessions, []), ("live", live, []),
                              ("proxy", proxy, None), ("modes", modes, {})):
        try:
            state[name] = part()
        except Exception as e:  # одна сломанная часть не должна оставить окно пустым
            state[name] = empty
            state["errors"][name] = f"{type(e).__name__}: {e}"
    return state


def main(argv):
    if argv and argv[0] in ("-h", "--help", "help"):
        print("agentmeister app-state    состояние для десктопного Agentmeister в JSON")
        return 0
    json.dump(collect(), sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
