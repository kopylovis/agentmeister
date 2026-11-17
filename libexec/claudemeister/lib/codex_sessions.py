import json
import os
import shutil
import subprocess
import threading
import time
import unicodedata

from mnrhlib import UUID_RE, tilde, tr


def list_threads(cwd):
    codex = shutil.which("codex")
    if not codex:
        raise OSError("codex is missing from PATH")
    with subprocess.Popen([codex, "app-server", "--listen", "stdio://"], cwd=cwd,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          encoding="utf-8") as server:
        timeout = threading.Timer(5, server.kill)
        timeout.start()
        try:
            def send(message):
                server.stdin.write(json.dumps(message) + "\n")
                server.stdin.flush()

            def request(request_id, method, params):
                send({"id": request_id, "method": method, "params": params})
                for line in server.stdout:
                    reply = json.loads(line)
                    if reply.get("id") == request_id:
                        if "error" in reply:
                            raise ValueError(reply["error"].get("message", method))
                        return reply["result"]
                raise OSError("Codex App Server closed the connection")

            request(1, "initialize", {"clientInfo": {"name": "agentmeister", "version": "1"}})
            send({"method": "initialized"})
            params = {"cwd": os.path.realpath(cwd), "sortKey": "updated_at", "limit": 100,
                      "sourceKinds": ["cli", "vscode", "appServer", "exec", "unknown"]}
            threads, seen, request_id = [], set(), 2
            while True:
                page = request(request_id, "thread/list", params)
                threads.extend(page["data"])
                cursor = page.get("nextCursor")
                if not cursor or cursor in seen:
                    return threads
                seen.add(cursor)
                params["cursor"] = cursor
                request_id += 1
        finally:
            timeout.cancel()
            if server.poll() is None:
                server.kill()


def clean(value):
    if not isinstance(value, str):
        return ""
    return " ".join("".join(" " if unicodedata.category(ch).startswith("C") else ch for ch in value).split())


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
    project = os.path.realpath(cwd)
    for thread in threads:
        sid = thread.get("sessionId") or thread.get("id")
        if not isinstance(sid, str) or not UUID_RE.fullmatch(sid) or thread.get("ephemeral"):
            continue
        folder = thread.get("cwd")
        if not isinstance(folder, str) or os.path.realpath(folder) != project:
            continue
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
