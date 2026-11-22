import os
import time
import unicodedata

from codex_harness import app_server, executable
from mnrhlib import UUID_RE, tilde, tr


def project_paths(cwd):
    real = os.path.realpath(cwd)
    parent = os.path.dirname(real)
    try:
        with os.scandir(parent) as entries:
            aliases = [entry.path for entry in entries if entry.is_symlink() and os.path.realpath(entry.path) == real]
    except OSError:
        aliases = []
    return [real, *sorted(aliases)]


def list_threads(cwd):
    codex = executable()
    if not codex:
        raise OSError("codex is missing from PATH")
    with app_server(codex, cwd) as request:
        paths = project_paths(cwd)
        params = {"cwd": paths[0] if len(paths) == 1 else paths, "sortKey": "updated_at", "limit": 100,
                  "sourceKinds": ["cli", "vscode", "appServer", "exec", "unknown"]}
        threads, seen = [], set()
        while True:
            page = request("thread/list", params)
            threads.extend(page["data"])
            cursor = page.get("nextCursor")
            if not cursor or cursor in seen:
                return threads
            seen.add(cursor)
            params["cursor"] = cursor


def clean(value):
    if not isinstance(value, str):
        return ""
    return " ".join("".join(" " if unicodedata.category(ch).startswith("C") else ch for ch in value).split())


def project_sessions(threads, cwd):
    project = os.path.realpath(cwd)
    for thread in threads:
        sid = thread.get("sessionId") or thread.get("id")
        if not isinstance(sid, str) or not UUID_RE.fullmatch(sid) or thread.get("ephemeral"):
            continue
        folder = thread.get("cwd")
        if not isinstance(folder, str) or os.path.realpath(folder) != project:
            continue
        yield sid, thread


def session_list(cwd):
    items = [("new", tr("Новая сессия", "New session"))]
    info = [[tr("Запустить Codex с чистым контекстом.", "Start Codex with a fresh context.")]]
    sessions = []
    try:
        threads = list_threads(cwd)
    except (OSError, ValueError, KeyError, TypeError):
        items.append(("resume", tr("Открыть список в Codex", "Open Codex's session picker")))
        info.append([tr("Не удалось прочитать список через Codex App Server.",
                        "The Codex App Server could not return a session list.")])
        threads = []
        sessions.append({"id": "resume"})
    for sid, thread in project_sessions(threads, cwd):
        preview = clean(thread.get("preview"))
        title = clean(thread.get("name")) or preview or sid[:8]
        timestamp = thread.get("updatedAt")
        date = time.strftime("%Y-%m-%d %H:%M", time.localtime(timestamp)) if isinstance(timestamp, int) else ""
        model = clean(thread.get("model"))
        label = title[:120] + (f"  {date}" if date else "")
        items.append((f"{sid} {title[:120]}", label))
        info.append([s for s in (title[:200], date, model, preview[:500] if preview != title else "") if s])
        sessions.append({"id": sid})
    if not sessions:
        return None
    title = tr(f"Сессии Codex в {tilde(cwd)}", f"Codex sessions in {tilde(cwd)}")
    return items, lambda index, _width: info[index], title, sessions
