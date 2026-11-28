"""MCP-сервер agentmeister: agentmeister mcp."""
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import CM, HOME, MNRH, lang, tilde, tr  # noqa: E402
from claude_proc import RestartError, current_sid  # noqa: E402
from claude_restart import restart, slim_current  # noqa: E402
import mac_status  # noqa: E402
import claude_open  # noqa: E402
import claude_search  # noqa: E402
import codex_context  # noqa: E402
import claude_usage  # noqa: E402
import gradle_deps  # noqa: E402
import claude_ask  # noqa: E402
import claude_parallel  # noqa: E402
import mnrh_todo  # noqa: E402
import release_notes  # noqa: E402
import window_shot  # noqa: E402

MCP_NAME = "agentmeister"


TOOL = {
    "name": "restart",
    "description": ("Перезапустить этот Claude Code: процесс закроется и через пару секунд откроется снова "
                    "с этой же сессией в той же вкладке терминала. Перед запуском выполняется claude update, "
                    "так что это же способ поставить обновление. Вызывай только когда пользователь сам просит "
                    "перезапуститься или обновиться; после вызова ничего больше не делай, процесс завершится."),
    "inputSchema": {
        "type": "object",
        "properties": {"update": {"type": "boolean", "description": "выполнить claude update перед запуском",
                                  "default": True}},
    },
}


FORGET_TOOL = {
    "name": "forget",
    "description": ("Забыть эту сессию: Claude Code закроется, текущая переписка удалится с диска без следа "
                    "(вместе с историей запросов), и в той же папке и вкладке откроется новый чистый Claude — "
                    "как /clear, только старое не сохраняется. Вызывай только когда пользователь сам просит забыть "
                    "или удалить эту сессию; после вызова ничего больше не делай."),
    "inputSchema": {"type": "object", "properties": {}},
}


FRESH_TOOL = {
    "name": "fresh",
    "description": ("Начать новую сессию: Claude Code закроется, и в той же папке и вкладке откроется новый Claude "
                    "с пустым контекстом и без названия. Текущая сессия остаётся на диске и в /resume, как после "
                    "/clear, но название в новую не переходит. Вызывай только когда пользователь сам просит начать "
                    "новую сессию; после вызова ничего больше не делай."),
    "inputSchema": {"type": "object", "properties": {}},
}


def version():
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__)))))
    try:
        with open(os.path.join(root, "VERSION")) as f:
            return f.read().strip() or "0"
    except OSError:
        return "0"


def call_restart(tool, a):
    import session_defaults
    update = a.get("update", session_defaults.restart_update())
    try:
        if tool == "forget":
            p = restart(update=False, delay=2.5, forget=True)
            return tr(f"Готово: через пару секунд Claude Code закроется, сессия {p['sid']} будет удалена, "
                      f"и в {tilde(p['cwd'])} откроется новая.",
                      f"Done: in a couple of seconds Claude Code will close, session {p['sid']} will be deleted, "
                      f"and a new one will open in {tilde(p['cwd'])}."), False
        if tool == "fresh":
            p = restart(update=False, delay=2.5, fresh=True)
            return tr(f"Готово: через пару секунд Claude Code закроется, и в {tilde(p['cwd'])} откроется новая сессия. "
                      f"Сессия {p['sid']} останется в /resume.",
                      f"Done: in a couple of seconds Claude Code will close and a new session will open in {tilde(p['cwd'])}. "
                      f"Session {p['sid']} stays in /resume."), False
        p = restart(update=bool(update), delay=2.5)
        return tr(f"Перезапуск запущен: через пару секунд Claude Code закроется"
                  f"{', обновится' if update else ''} и снова откроет сессию {p['sid']} в {tilde(p['cwd'])}.",
                  f"Restart started: in a couple of seconds Claude Code will close"
                  f"{', update' if update else ''} and reopen session {p['sid']} in {tilde(p['cwd'])}."), False
    except RestartError as e:
        return tr(f"Не получилось: {e}", f"Failed: {e}"), True


SLIM_TOOL = {
    "name": "slim",
    "description": ("Сжать эту сессию: Claude Code закроется, из старой части сессии (до двух последних /compact) "
                    "уберутся скриншоты и длинные выводы инструментов, и сессия откроется снова в той же вкладке. "
                    "То, что получает модель, не меняется, оригинал хранится 14 дней. Если сжимать нечего, "
                    "ничего не закрывается. Вызывай только когда пользователь сам просит сжать сессию; если ответ "
                    "говорит, что Claude закроется, больше ничего не делай."),
    "inputSchema": {"type": "object", "properties": {
        "dry_run": {"type": "boolean", "description": "только посчитать, сколько освободится"}}},
}


def call_slim(a):
    try:
        text, _ = slim_current(dry=bool(a.get("dry_run")), delay=2.5)
        return text, False
    except RestartError as e:
        return tr(f"Не получилось: {e}", f"Failed: {e}"), True


def schema_args(tool, a):
    """Только аргументы из inputSchema инструмента. open_claude внутри agentmeister принимает и path, и flags
    (claude_live, claude_parallel), но модель не должна открыть Claude в любой папке с любыми ключами."""
    allowed = (tool.get("inputSchema") or {}).get("properties") or {}
    return {k: v for k, v in a.items() if k in allowed}


# parallel_finish pr ждёт CI до трёх часов. Его работа идёт в отдельном процессе: он переживёт и таймаут вызова
# в Claude Code, и перезапуск этого сервера. Если за FINISH_WAIT секунд он не закончил, отвечаем сразу,
# а итог придёт уведомлением macOS и останется в логе.
FINISH_WAIT = 40
FINISH_LOGS = os.path.join(HOME, "Library", "Logs", "agentmeister-parallel")
FINISH_LIB = os.path.dirname(os.path.abspath(__file__))
DETACHED = []
FINISH_RUNNER = r"""
import json, os, subprocess, sys
lib, args, cwd, base = sys.argv[1:5]
sys.path.insert(0, lib)
try:
    from mnrhlib import tr
except Exception:
    def tr(ru, en):
        return ru
try:
    import claude_parallel
    text, bad = claude_parallel.handle("parallel_finish", json.loads(args), cwd)
except Exception as e:
    text, bad = tr("Не получилось: %r", "Failed: %r") % (e,), True
print(text, flush=True)
with open(base + ".json.tmp", "w") as f:
    json.dump({"text": text, "error": bool(bad)}, f, ensure_ascii=False)
os.replace(base + ".json.tmp", base + ".json")
if os.path.exists(base + ".detached"):
    title = "agentmeister: PR " + (tr("не слит", "not merged") if bad else tr("готов", "done"))
    try:
        subprocess.run(["osascript", "-e", "on run argv", "-e",
                        "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run",
                        title, text[-400:]], capture_output=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        pass
"""


def finish_result(base):
    try:
        with open(base + ".json") as f:
            r = json.load(f)
        return str(r.get("text") or ""), bool(r.get("error"))
    except (OSError, ValueError, AttributeError):
        return None


def parallel_finish(a):
    if a.get("action") != "pr":
        return claude_parallel.handle("parallel_finish", a, os.getcwd())
    os.makedirs(FINISH_LOGS, exist_ok=True)
    branch = re.sub(r"[^\w.-]+", "_", str(a.get("branch") or "")) or "branch"
    base = os.path.join(FINISH_LOGS, f"{time.strftime('%Y%m%d-%H%M%S')}-{branch}-{os.getpid()}")
    with open(base + ".log", "w") as log:
        proc = subprocess.Popen([sys.executable, "-c", FINISH_RUNNER, FINISH_LIB, json.dumps(a), os.getcwd(), base],
                                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                start_new_session=True)
    deadline = time.monotonic() + FINISH_WAIT
    while proc.poll() is None and time.monotonic() < deadline:
        time.sleep(0.2)
    if proc.poll() is None:
        open(base + ".detached", "w").close()
        DETACHED.append(proc)  # процесс живёт дальше сам; ссылка, чтобы Popen не ругался при сборке мусора
    if proc.poll() is not None:
        result = finish_result(base)
        if result:
            return result
        return tr(f"Фоновый parallel_finish завершился без результата, лог: {tilde(base + '.log')}",
                  f"Background parallel_finish ended without a result, log: {tilde(base + '.log')}"), True
    return tr(f"PR для {a.get('branch')} в работе: процесс {proc.pid} ждёт CI и сливает в фоне. Когда закончит, "
              f"придёт уведомление macOS; итог будет в {tilde(base + '.log')}. Ждать ответа здесь не нужно.",
              f"PR for {a.get('branch')} is in progress: process {proc.pid} waits for CI and merges in the background. "
              f"When it's done, a macOS notification arrives; the result will be in {tilde(base + '.log')}. "
              f"No need to wait for an answer here."), False


HANDLERS = {
    "restart": lambda a: call_restart("restart", a),
    "forget": lambda a: call_restart("forget", a),
    "fresh": lambda a: call_restart("fresh", a),
    "slim": call_slim,
    "open_claude": lambda a: claude_open.open_claude(schema_args(claude_open.TOOL, a), CM),
    "session_search": lambda a: claude_search.handle("session_search", a, current_sid()),
    "session_read": lambda a: claude_search.handle("session_read", a),
    "usage_report": claude_usage.handle,
    "codex_context": codex_context.handle,
    # без полного mnrh этих инструментов нет и в tools/list
    **({"mac_status": lambda a: mac_status.handle("mac_status", a, MNRH),
        "free_memory": lambda a: mac_status.handle("free_memory", a, MNRH)} if MNRH else {}),
    "deps_outdated": lambda a: gradle_deps.handle(a),
    "todo_list": lambda a: mnrh_todo.handle("todo_list", a, os.getcwd()),
    "todo_add": lambda a: mnrh_todo.handle("todo_add", a, os.getcwd()),
    "todo_done": lambda a: mnrh_todo.handle("todo_done", a, os.getcwd()),
    "release_notes_context": lambda a: release_notes.handle("release_notes_context", a, os.getcwd()),
    "release_notes_write": lambda a: release_notes.handle("release_notes_write", a, os.getcwd()),
    "parallel_task": lambda a: claude_parallel.handle("parallel_task", a, os.getcwd(), CM),
    "parallel_list": lambda a: claude_parallel.handle("parallel_list", a, os.getcwd()),
    "parallel_finish": parallel_finish,
    "window_screenshot": lambda a: window_shot.handle(a),
    "ask_project": lambda a: claude_ask.ask(a.get("project"), a.get("question"), a.get("model")),
}
# mac_status и free_memory запускают команды mnrh, поэтому они есть, только когда стоит полный mnrh
EXTRA_TOOLS = (claude_search.TOOLS + [claude_usage.TOOL, codex_context.TOOL] + (mac_status.TOOLS if MNRH else []) + [gradle_deps.TOOL] + mnrh_todo.TOOLS + release_notes.TOOLS
               + claude_parallel.TOOLS + [window_shot.TOOL, claude_ask.TOOL])
READ_ONLY = [t["name"] for t in EXTRA_TOOLS if (t.get("annotations") or {}).get("readOnlyHint")] + \
    ["todo_add", "todo_done"]


def tools():
    if os.environ.get("MNRH_MCP_HARNESS") == "codex":
        found = [gradle_deps.TOOL] + mnrh_todo.TOOLS + release_notes.TOOLS
    else:
        found = [TOOL, FORGET_TOOL, FRESH_TOOL, SLIM_TOOL, claude_open.TOOL] + EXTRA_TOOLS
    if lang() == "en":
        import mcp_en
        found = mcp_en.english(found)
    return found


LIB = os.path.dirname(os.path.abspath(__file__))
PENDING = "MNRH_MCP_PENDING"
TOOL_NAMES = "MNRH_MCP_TOOLS"


def code_stamp():
    """Отпечаток кода: меняется после brew upgrade или git pull, тогда сервер перезапускает себя."""
    try:
        files = [os.path.join(LIB, n) for n in os.listdir(LIB) if n.endswith(".py")]
        files.append(os.path.join(os.path.dirname(os.path.dirname(LIB)), "..", "VERSION"))
        return len(files), max(os.path.getmtime(f) for f in files)
    except (OSError, ValueError):
        return None


HOME_DIR = os.path.realpath(os.path.join(LIB, "..", "..", ".."))
OWN_BIN = os.path.join(HOME_DIR, "bin", "agentmeister")


def brew_bin():
    """agentmeister из Homebrew в PATH, если этот сервер запущен из Cellar; иначе None."""
    if not any(f"/Cellar/{name}/" in HOME_DIR + "/" for name in ("agentmeister", "claudemeister")):
        return None
    return shutil.which("agentmeister")


def installed_elsewhere():
    """brew upgrade ставит новую версию в другую папку Cellar: agentmeister в PATH уже не наш."""
    found = brew_bin()
    return bool(found) and os.path.dirname(os.path.dirname(os.path.realpath(found))) != HOME_DIR


def reload(pending):
    """Заменить процесс свежим agentmeister mcp на тех же stdin и stdout: Claude Code этого не заметит.
    Непрочитанные запросы уходят новому процессу через файл."""
    import tempfile
    fd, path = tempfile.mkstemp(prefix="cm-mcp-")
    with os.fdopen(fd, "wb") as f:
        f.write(pending)
    os.environ[PENDING] = path
    os.environ[TOOL_NAMES] = ",".join(sorted(t["name"] for t in tools()))
    target = brew_bin() or OWN_BIN
    sys.stdout.flush()
    os.execv(target, [target, "mcp"])


def lines_from(fd, carry=b""):
    """Строки stdin без буфера Python: при перезапуске нельзя потерять уже прочитанное."""
    buf = carry
    while True:
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            yield line, buf
        chunk = os.read(fd, 65536)
        if not chunk:
            if buf.strip():
                yield buf, b""
            return
        buf += chunk


def mcp():
    out_lock = threading.Lock()
    calls = []  # потоки tools/call, которые ещё работают

    def send(msg):
        data = json.dumps(msg, ensure_ascii=False) + "\n"
        with out_lock:
            try:
                sys.stdout.write(data)
                sys.stdout.flush()
            except (OSError, ValueError):  # Claude Code уже закрыл канал
                pass

    def call(rid, handler, args):
        try:
            result = handler(args)
        except Exception as e:
            result = (tr(f"Не получилось: {e!r}", f"Failed: {e!r}"), True)
        if isinstance(result, dict):
            send({"jsonrpc": "2.0", "id": rid, "result": result})
            return
        text, err = result
        send({"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": text}], "isError": err}})

    visible_tools = {tool["name"] for tool in tools()}
    carry = b""
    path = os.environ.pop(PENDING, "")
    if path:
        try:
            with open(path, "rb") as f:
                carry = f.read()
            os.remove(path)
        except OSError:
            pass
    before = os.environ.pop(TOOL_NAMES, None)
    if before is not None and before != ",".join(sorted(t["name"] for t in tools())):
        send({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
    stamp = code_stamp()

    for raw, rest in lines_from(sys.stdin.fileno(), carry):
        calls[:] = [t for t in calls if t.is_alive()]
        now = code_stamp()
        # пока вызов работает, перезапуск оборвал бы его без ответа: старый код дослужит до следующего запроса
        if not calls and (now != stamp or now is None or installed_elsewhere()):
            reload(raw + b"\n" + rest)
        try:
            req = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            continue
        if not isinstance(req, dict):  # пакеты JSON-RPC (массивы) MCP не использует, а падать из-за них нельзя
            continue
        rid, method = req.get("id"), req.get("method")
        if rid is None:
            continue
        if method == "initialize":
            ver = (req.get("params") or {}).get("protocolVersion") or "2025-06-18"
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": ver,
                "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": {"name": MCP_NAME, "version": version()}}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": rid, "result": {"tools": tools()}})
        elif method == "tools/call":
            params = req.get("params") or {}
            name = params.get("name")
            handler = HANDLERS.get(name) if isinstance(name, str) and name in visible_tools else None
            if not handler:
                send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": tr("нет такого инструмента", "no such tool")}})
                continue
            args = params.get("arguments")
            # каждый вызов в своём потоке: долгий инструмент не держит остальные
            t = threading.Thread(target=call, args=(rid, handler, args if isinstance(args, dict) else {}),
                                 name=f"mcp-{name}")
            t.start()
            calls.append(t)
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": rid, "result": {}})
        else:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": tr(f"не умею {method}", f"unsupported method {method}")}})
