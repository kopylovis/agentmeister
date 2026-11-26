"""agentmeister app-state: состояние для десктопного Agentmeister одним JSON.

Приложение не разбирает вывод для людей и не дублирует логику CLI. Оно раз в несколько секунд спрашивает
эту команду: проекты из папки проектов, сохраненные сессии Claude Code и Codex, открытые сейчас сессии с их статусом
(ждет, работает, свободна), состояние proxy и режимов. Каждая часть собирается отдельно: если одна упала,
остальные приходят как обычно, а в errors остается причина.
"""
import collections
import glob
import json
import os
import re
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
    dirs = open_flow.project_dirs()
    return [{"name": mnrhlib.project_label(p, dirs), "path": p} for p in dirs]


META_CACHE = os.path.join(mnrhlib.CACHE, "app-state", "sessions.json")


def session_meta(s, cache, fresh):
    """Заголовок, ветка, папка и answered сессии. Переписку читаем, только если файл изменился с прошлого раза:
    приложение спрашивает app-state часто, а разбор всех строк всех переписок стоит больше полсекунды."""
    import session_store
    version = list(s["transcript_version"] or [])
    old = cache.get(s["path"])
    if old and old.get("v") == version:
        fresh[s["path"]] = old
        return old
    m = session_store.read_meta(s["path"])
    custom = m["custom"]
    try:
        with open(os.path.join(s["extra"], "custom-title.json")) as fh:
            custom = json.load(fh).get("customTitle") or custom
    except (OSError, ValueError, AttributeError):
        pass
    item = {"v": version, "cwd": m["cwd"], "branch": m["branch"] or "", "answered": bool(m["answered"]),
            "title": custom or m["ai"] or m["prompt"] or ""}
    fresh[s["path"]] = item
    return item


def sessions():
    """Сохраненные сессии Claude Code, новые первыми. Пустые, без ответа Claude, приложению не нужны."""
    import session_store
    try:
        with open(META_CACHE) as f:
            cache = json.load(f)
        if not isinstance(cache, dict):
            cache = {}
    except (OSError, ValueError):
        cache = {}
    fresh, out = {}, []
    for s in session_store.load(meta=False):
        if s.get("link"):
            continue
        m = session_meta(s, cache, fresh)
        if not m["answered"] or len(out) >= SESSION_LIMIT:
            continue
        cwd = s["cwd"] or m["cwd"] or ""
        out.append({
            "id": s["id"], "cwd": cwd, "title": m["title"], "branch": m["branch"],
            "mtime": s["mtime"], "size": s["size"], "running": bool(s.get("running")),
            "cwdExists": bool(cwd) and os.path.isdir(cwd), "agent": "claude",
        })
    if fresh != cache:
        try:
            os.makedirs(os.path.dirname(META_CACHE), exist_ok=True)
            mnrhlib.write_json(META_CACHE, fresh, mode=0o600, ensure_ascii=False, separators=(",", ":"))
        except OSError:
            pass
    return out


CODEX_CACHE = os.path.join(mnrhlib.CACHE, "app-state", "codex.json")
# служебные сообщения, которые Codex сам кладет в начало разговора от имени пользователя: это не запрос
CODEX_INJECTED = ("# AGENTS.md instructions", "<environment_context>", "<user_instructions>", "<image", "</image>",
                  "<turn_aborted>", "<user_shell_command>", "<permissions instructions>", "<collaboration_mode>")


def codex_home():
    return os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")


def codex_names(home):
    """Названия тредов из session_index.jsonl. Codex дописывает файл, поэтому последняя запись для id главная."""
    names = {}
    try:
        with open(os.path.join(home, "session_index.jsonl"), encoding="utf-8") as f:
            for line in f:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and isinstance(row.get("id"), str) and isinstance(row.get("thread_name"), str):
                    names[row["id"]] = row["thread_name"]
    except OSError:
        pass
    return names


def codex_text(content):
    if not isinstance(content, list):
        return ""
    return "\n".join(c["text"] for c in content if isinstance(c, dict) and isinstance(c.get("text"), str)).strip()


def codex_item(line):
    """Строка rollout: что это (user, codex, tool или None), текст и время. Разбираем только завершенные элементы
    (event_msg item_completed) и сообщения response_item, остальное пропускаем, не читая JSON.
    Строку не того вида пропускаем: одна битая строка не должна прятать весь тред или все треды."""
    if '"item_completed"' not in line and ('"response_item"' not in line or '"message"' not in line):
        return None, "", None
    try:
        return codex_row(json.loads(line))
    except (ValueError, AttributeError, TypeError):
        return None, "", None


def codex_row(row):
    if not isinstance(row, dict) or not isinstance(row.get("payload"), dict):
        return None, "", None
    p = row["payload"]
    ts = row.get("timestamp")
    if row.get("type") == "event_msg" and p.get("type") == "item_completed":
        item = p.get("item")
        if not isinstance(item, dict):
            return None, "", None
        kind = item.get("type")
        if kind == "UserMessage":
            return "user", codex_text(item.get("content")), ts
        if kind == "AgentMessage":
            return "codex", codex_text(item.get("content")), ts
        if kind == "CommandExecution":
            cmds = item.get("parsed_cmd") if isinstance(item.get("parsed_cmd"), list) else []
            parsed = [c.get("cmd") for c in cmds if isinstance(c, dict) and isinstance(c.get("cmd"), str)]
            command = item.get("command")
            text = " && ".join(parsed) or (" ".join(command) if isinstance(command, list) else str(command or ""))
            return "tool", "$ " + text, ts
        return None, "", None
    if row.get("type") == "response_item" and p.get("type") == "message":
        text = codex_text(p.get("content"))
        if p.get("role") == "assistant":
            return "codex-raw", text, ts
        if p.get("role") == "user" and text and not text.startswith(CODEX_INJECTED):
            return "user-raw", text, ts
    return None, "", None


def codex_meta(path):
    """id, папка, ветка из первой строки rollout (session_meta), первый запрос и был ли ответ. Читаем до первого
    ответа Codex, а не весь файл: переписка бывает в десятки мегабайт, а нужное лежит в начале."""
    item = {"id": None, "cwd": "", "branch": "", "created": None, "title": "", "answered": False, "sub": False}
    with open(path, encoding="utf-8", errors="replace") as f:
        try:
            first = json.loads(f.readline())
        except ValueError:
            return item
        meta = first.get("payload") if isinstance(first, dict) and first.get("type") == "session_meta" else None
        if not isinstance(meta, dict):
            return item
        git = meta.get("git") if isinstance(meta.get("git"), dict) else {}
        source = meta.get("source")
        item.update(id=meta.get("id") if isinstance(meta.get("id"), str) else None,
                    cwd=meta.get("cwd") if isinstance(meta.get("cwd"), str) else "",
                    branch=git.get("branch") if isinstance(git.get("branch"), str) else "",
                    created=epoch(meta.get("timestamp")),
                    # треды субагентов Codex заводит сам, продолжать их отдельно незачем
                    sub=isinstance(source, dict) or meta.get("thread_source") == "subagent")
        for line in f:
            role, text, _ = codex_item(line)
            if role in ("codex", "codex-raw"):
                item["answered"] = True
            elif role in ("user", "user-raw") and text and not item["title"] and not text.lstrip().startswith(COMMAND_TAGS):
                # служебная запись команды (<command-name>…) заголовком не годится, ждем настоящий запрос
                item["title"] = " ".join(text.split())[:200]
            if item["answered"] and item["title"]:
                break
    return item


def codex_rollouts(home):
    """Переписки Codex: sessions/ГГГГ/ММ/ДД/rollout-*.jsonl. archived_sessions не берем: их Codex прячет сам."""
    for directory, children, files in os.walk(os.path.join(home, "sessions")):
        children[:] = [d for d in children if not d.startswith(".")]
        for name in files:
            if name.startswith("rollout-") and name.endswith(".jsonl"):
                yield os.path.join(directory, name)


# служебные записи команд в переписке, их текст в заголовок не берем
COMMAND_TAGS = ("<command-name>", "<command-message>", "<command-args>", "<local-command-stdout>",
                "<local-command-stderr>", "<local-command-caveat>")
# формат заголовка в кеше: старые записи с заголовком из служебной записи разбираются заново
TITLE_FORMAT = 2


def codex_sessions(cache_path=None):
    """Сохраненные треды Codex в том же виде, что сессии Claude Code, плюс agent: codex и путь к файлу.
    Файл разбираем заново, только если он изменился и в прошлый раз в нем не нашлось запроса и ответа:
    дальше rollout только растет, а заголовок и папка лежат в начале."""
    home = codex_home()
    cache_path = cache_path or CODEX_CACHE
    try:
        with open(cache_path) as f:
            cache = json.load(f)
        if not isinstance(cache, dict):
            cache = {}
    except (OSError, ValueError):
        cache = {}
    names = codex_names(home)
    fresh, out = {}, []
    for path in codex_rollouts(home):
        try:
            st = os.stat(path)
        except OSError:
            continue
        version = [st.st_mtime_ns, st.st_size]
        item = cache.get(path)
        if not isinstance(item, dict) or item.get("t") != TITLE_FORMAT or \
                (item.get("v") != version and not (item.get("answered") and item.get("title"))):
            try:
                item = codex_meta(path)
            except OSError:
                continue
        item = dict(item, v=version, t=TITLE_FORMAT)
        fresh[path] = item
        sid = item.get("id")
        if not sid or item.get("sub") or not item.get("answered"):
            continue
        cwd = item.get("cwd") or ""
        out.append({"id": sid, "agent": "codex", "cwd": cwd, "title": names.get(sid) or item.get("title") or "",
                    "branch": item.get("branch") or "", "mtime": st.st_mtime, "size": st.st_size, "running": False,
                    "cwdExists": bool(cwd) and os.path.isdir(cwd), "created": item.get("created"), "path": path})
    if fresh != cache:
        try:
            os.makedirs(os.path.dirname(cache_path), exist_ok=True)
            mnrhlib.write_json(cache_path, fresh, mode=0o600, ensure_ascii=False, separators=(",", ":"))
        except OSError:
            pass
    out.sort(key=lambda s: -s["mtime"])
    return out[:SESSION_LIMIT]


def codex_rollout(sid):
    """Файл треда Codex по id, прямо по имени: sessions/ГГГГ/ММ/ДД/rollout-<время>-<id>.jsonl. Так читается
    и тред старше тех, что попали в список, и не нужно разбирать все треды ради одного."""
    if not mnrhlib.UUID_RE.match(sid or ""):
        return None
    pattern = os.path.join(glob.escape(codex_home()), "sessions", "*", "*", "*", f"rollout-*-{sid}.jsonl")
    found = []
    for path in glob.glob(pattern):
        try:
            found.append((os.path.getmtime(path), path))
        except OSError:
            continue
    return max(found)[1] if found else None


def codex_read(sid, tail=12, chars=700):
    """Последние сообщения треда Codex для превью, как read для Claude Code. None, если такого треда нет.
    В памяти держим только хвост: переписка бывает в десятки мегабайт."""
    path = codex_rollout(sid)
    if not path:
        return None
    try:
        meta = codex_meta(path)
    except OSError:
        return None
    if meta["id"] != sid:
        return None
    tail = max(0, tail)
    # в старых rollout нет item_completed, там берем сами сообщения модели
    parts = {kind: {"tail": collections.deque(maxlen=tail), "total": 0, "first": None} for kind in ("item", "raw")}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                role, text, ts = codex_item(line)
                if not role or not text:
                    continue
                part = parts["raw" if role.endswith("-raw") else "item"]
                if not part["total"]:
                    part["first"] = ts
                part["total"] += 1
                part["tail"].append((role.replace("-raw", ""), ts, text))
    except OSError:
        return None
    part = parts["item"] if parts["item"]["total"] else parts["raw"]
    msgs, total = list(part["tail"]), part["total"]
    start = total - len(msgs)
    return {"id": sid, "agent": "codex", "title": codex_names(codex_home()).get(sid) or meta["title"],
            "home": meta["cwd"], "total": total,
            "first": epoch(part["first"]) if total else None, "last": epoch(msgs[-1][1]) if msgs else None,
            "messages": [{"at": i, "role": role, "time": epoch(ts),
                          "text": text if len(text) <= chars else text[:chars] + "…"}
                         for i, (role, ts, text) in enumerate(msgs, start)]}


def live():
    """Открытые сейчас сессии из реестра Claude Code: статус waiting, busy или idle."""
    import claude_live
    return [{"sessionId": s.get("sessionId"), "pid": s.get("pid"), "cwd": s.get("cwd"), "status": s.get("status"),
             "name": s.get("name"), "statusUpdatedAt": s.get("statusUpdatedAt")} for s in claude_live.live()]


def proxy_state():
    import proxy
    configured = proxy.configured()
    p = proxy.port() if configured else None
    # read_pid спрашивает ps, из песочницы proxy-сессии ps не запустить: тогда он сам проверяет, жив ли процесс
    pid = proxy.read_pid() if configured else None
    running = bool(pid and proxy.listening(p))
    try:
        with open(proxy.EXIT) as f:
            info = json.load(f)
    except (OSError, ValueError):
        info = {}
    loc = info.get("loc")
    held = len(proxy.holders()) if configured else 0
    names = proxy.sub_names() if configured else []
    cascade = proxy.cascade_subs() if configured else []
    remembered = proxy.last() if os.path.exists(proxy.LAST) else ""
    default_sub = remembered[4:] if remembered.startswith("vps:") and remembered[4:] in names and len(names) > 1 else None
    subs = []
    for n in names:
        # выход через порт только этой подписки, записан при запуске mihomo
        try:
            # у основной без дополнительных своего порта нет, ее выход и есть общий
            with open(proxy.exit_file(proxy.resolve_sub(n))) as f:
                one = json.load(f)
        except (OSError, ValueError):
            one = {}
        where = one.get("loc")
        subs.append({"name": n, "port": proxy.sub_port(n), "country": proxy.sub_country(n) or None,
                     "exit": where.upper() if isinstance(where, str) and len(where) == 2 else None,
                     "inCascade": n in cascade})
    current = None
    if running and len(names) > 1:
        # живой ответ mihomo через сокет управления: на какой подписке каскад сейчас. Из песочницы сессии сокет
        # закрыт, тогда остается подписка, записанная при запуске mihomo
        now = proxy.node_info(None) or {}
        current = now.get("sub") if now.get("sub") in names else info.get("sub") if info.get("sub") in names else None
    return {"configured": configured, "running": running, "port": p, "current": current,
            "exit": loc.upper() if isinstance(loc, str) and len(loc) == 2 else None,
            "protocol": info.get("proto") if isinstance(info.get("proto"), str) else None,
            "ip": info.get("ip") if isinstance(info.get("ip"), str) else None,
            "node": info.get("node") if isinstance(info.get("node"), str) else None,
            # без сохраненного выбора новая сессия идет через proxy, как в правилах пользователя и в меню
            "defaultRoute": "direct" if os.path.exists(proxy.LAST) and proxy.last() == "direct" else "proxy",
            "sessions": held,
            # подписка новых сессий, если в меню или настройках выбрана одна: last() хранит vps:<имя>
            "defaultSubscription": default_sub,
            "subscriptions": subs}


def modes():
    import main_menu
    return main_menu.modes()


def retention_days():
    """Сколько дней Claude Code хранит переписки: cleanupPeriodDays, по умолчанию 30."""
    import claude_settings
    try:
        days = claude_settings.load().get("cleanupPeriodDays")
    except (OSError, ValueError):
        days = None
    return days if type(days) is int else 30  # bool тоже int, а приложение ждет число


def host_run_summary():
    """Работает ли исполнитель host-run и сколько команд в белом списке, для строки внизу боковой панели."""
    import host_run as hr
    try:
        running = bool(hr.ping())
    except Exception:
        running = False
    try:
        count = len(hr.load())
    except Exception:
        count = 0
    return {"running": running, "commands": count, "log": hr.LOG}


def collect():
    state = {"version": version(), "lang": mnrhlib.lang(), "langSetting": lang_setting(), "projectsDir": mnrhlib.projects_dir(),
             "projectsDirs": mnrhlib.projects_dirs(),
             "generatedAt": time.time(), "errors": {}}
    for name, part, empty in (("projects", projects, []), ("sessions", sessions, []), ("live", live, []),
                              ("proxy", proxy_state, None), ("modes", modes, {}), ("hostRun", host_run_summary, None),
                              ("signedIn", lambda: {b: signed_in(b)["signedIn"] for b in ("claude", "codex")}, None),
                              ("retentionDays", retention_days, None),
                              # модель из настроек агентов для панели сессии: два маленьких файла, без запуска бинарников
                              ("models", lambda: {b: agent_model(b) for b in ("claude", "codex")}, None)):
        try:
            state[name] = part()
        except Exception as e:  # одна сломанная часть не должна оставить окно пустым
            state[name] = empty
            state["errors"][name] = f"{type(e).__name__}: {e}"
    # треды Codex отдельным ключом: приложение старой сборки считало бы любую сессию из sessions сессией
    # Claude Code и продолжало бы ее через claude --resume. Новое приложение само сливает два списка.
    try:
        state["codexSessions"] = [{k: v for k, v in c.items() if k != "path"} for c in codex_sessions()]
    except Exception as e:  # сломанный разбор Codex не трогает сессии Claude Code
        state["codexSessions"] = []
        state["errors"]["codexSessions"] = f"{type(e).__name__}: {e}"
    return state


def epoch(ts):
    """ISO-время из переписки в секунды Unix, как mtime у сессий."""
    from datetime import datetime
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def file_size(path):
    try:
        return os.path.getsize(path) if path else None
    except OSError:
        return None


def search(query, limit=30):
    """Поиск по всем сессиям всех проектов тем же индексом, что agentmeister sessions search и session_search."""
    import claude_search
    q = claude_search.Query(query)
    if not query.strip() or not q.terms:
        return {"query": query, "exact": False, "scanned": 0, "results": []}
    r = claude_search.find_sessions(q)
    results = []
    for _, sid, data, found in r.chosen[:limit]:
        results.append({
            "id": sid, "title": claude_search.title(sid, data), "home": claude_search.home_of(data),
            "last": epoch(data.get("last")), "count": len(found), "size": file_size(data.get("path")),
            "hits": [{"at": i, "role": data["msgs"][i][0], "time": epoch(data["msgs"][i][1]),
                      "snippet": claude_search.snippet(data["msgs"][i][2], q, r.idf, width=240)}
                     for i in found[:3]],
        })
    return {"query": query, "exact": r.exact, "scanned": len(r.scope), "results": results}


def codex_like(ref):
    """Id треда Codex: полный UUID версии 7 (время в начале id). Claude Code дает сессиям UUID версии 4."""
    return bool(mnrhlib.UUID_RE.match(ref or "")) and ref[14] == "7"


def read(ref, tail=12, chars=700):
    """Последние сообщения сессии для превью в библиотеке. Полный id треда Codex читается из его rollout:
    сразу, если id похож на Codex, иначе только когда среди сессий Claude Code такого нет."""
    if codex_like(ref):
        codex = codex_read(ref, tail, chars)
        if codex:
            return codex
    import claude_search
    idx = claude_search.refresh()
    sid, err = claude_search.resolve(ref, idx)
    if err:
        codex = codex_read(ref, tail, chars) if mnrhlib.UUID_RE.match(ref or "") and not codex_like(ref) else None
        return codex or {"error": err}
    data = idx[sid]
    msgs = data["msgs"]
    start = max(0, len(msgs) - tail)
    return {"id": sid, "title": claude_search.title(sid, data), "home": claude_search.home_of(data),
            "total": len(msgs), "first": epoch(data.get("first")), "last": epoch(data.get("last")),
            "messages": [{"at": i, "role": role, "time": epoch(ts),
                          "text": text if len(text) <= chars else text[:chars] + "…"}
                         for i, (role, ts, text) in enumerate(msgs[start:], start)]}


def usage(days=7):
    """Статистика как у agentmeister usage, но числами: по проектам, по моделям, тяжелые сессии и активное время
    по дням для графика. days=0 значит за все время."""
    import claude_search
    import claude_usage
    rows = claude_usage.collect(days)
    since = claude_usage.period_start(days) if days else None
    total = [0] * 5
    by_project, by_model = {}, {}
    for r in rows:
        home = claude_search.home_of(r["data"])
        name = claude_search.folder(r["data"])
        p = by_project.setdefault(name, {"name": name, "home": home, "sessions": 0, "active": 0.0, "tokens": [0] * 5})
        p["sessions"] += 1
        p["active"] += r["active"]
        for model, row in r["models"].items():
            m = by_model.setdefault(model, {"name": model, "sessions": 0, "tokens": [0] * 5})
            m["sessions"] += 1
            for i in range(5):
                m["tokens"][i] += row[i]
                p["tokens"][i] += row[i]
                total[i] += row[i]
    # активное время по дням: промежутки работы режутся по местной полуночи
    daily = {}
    for r in rows:
        for a, b in r["data"]["spans"]:
            if since:
                a = max(a, since)
            while a < b:
                lt = time.localtime(a)
                midnight = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday + 1, 0, 0, 0, 0, 0, -1))
                end = min(b, midnight)
                day = time.strftime("%Y-%m-%d", lt)
                daily[day] = daily.get(day, 0.0) + (end - a)
                a = end
    heavy = []
    for r in sorted(rows, key=lambda r: -r["total"])[:8]:
        d = r["data"]
        heavy.append({"id": r["sid"], "title": d.get("custom") or d.get("ai") or d.get("prompt") or "",
                      "project": claude_search.folder(d), "active": r["active"], "last": r["last"],
                      "total": r["total"], "output": sum(m[1] for m in r["models"].values())})
    return {"days": days, "since": since, "sessions": len(rows), "active": sum(r["active"] for r in rows),
            "requests": total[4], "tokens": total[:4],
            "projects": sorted(by_project.values(), key=lambda p: -p["active"]),
            "models": sorted(by_model.values(), key=lambda m: -sum(m["tokens"][:4])),
            "heavy": heavy,
            "daily": [{"day": k, "active": v} for k, v in sorted(daily.items())]}


def agent_info(binary):
    """Путь и версия агента. Версию спрашиваем у самого бинарника, как agentmeister doctor."""
    import shutil
    import subprocess
    import agent_update
    # обертку вроде codex от promptsill пропускаем: путь, версия и способ установки у самого агента
    path = agent_update.binary_path(binary) if binary in agent_update.AGENTS else shutil.which(binary)
    if not path:
        return {"installed": False, "path": None, "version": None}
    try:
        out = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=10).stdout.split()
    except (OSError, subprocess.TimeoutExpired):
        out = []
    version = next((w for w in out if w[:1].isdigit()), None)
    via = agent_update.installed_via(binary, path)
    return {"installed": True, "path": path, "version": version, "installedVia": via, "model": agent_model(binary),
            **signed_in(binary)}


PLANS = {"claude_max": "Max", "claude_pro": "Pro", "claude_team": "Team", "claude_enterprise": "Enterprise"}


def agent_model(binary):
    """Модель и усилие из настроек агента: ~/.claude/settings.json или ~/.codex/config.toml."""
    home = os.path.expanduser("~")
    try:
        if binary == "claude":
            with open(os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude"), "settings.json")) as f:
                s = json.load(f)
            return " ".join(x for x in (s.get("model"), s.get("effortLevel")) if isinstance(x, str)) or None
        if binary == "codex":
            with open(os.path.join(os.environ.get("CODEX_HOME") or os.path.join(home, ".codex"), "config.toml")) as f:
                text = f.read()
            top = re.split(r"^\[", text, maxsplit=1, flags=re.M)[0]  # только ключи верхнего уровня, не профили
            found = dict(re.findall(r"""^(model|model_reasoning_effort)\s*=\s*["']([^"']*)["']""", top, re.M))
            return " ".join(x for x in (found.get("model"), found.get("model_reasoning_effort")) if x) or None
    except (OSError, ValueError, AttributeError):
        pass
    return None


def signed_in(binary):
    """Выполнен ли вход, по файлам самих агентов. Сами токены не читаются и никуда не идут."""
    home = os.path.expanduser("~")
    try:
        if binary == "claude":
            with open(os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or home, ".claude.json")) as f:
                account = json.load(f).get("oauthAccount") or {}
            org = account.get("organizationType")
            return {"signedIn": bool(account), "email": account.get("emailAddress"),
                    "plan": PLANS.get(org, org.replace("_", " ") if isinstance(org, str) else None)}
        if binary == "codex":
            with open(os.path.join(os.environ.get("CODEX_HOME") or os.path.join(home, ".codex"), "auth.json")) as f:
                auth = json.load(f)
            mode = auth.get("auth_mode")
            # email и тариф Codex лежат только внутри id_token, а токены мы не читаем
            return {"signedIn": bool(auth.get("tokens") or auth.get("OPENAI_API_KEY")), "email": None,
                    "plan": {"chatgpt": "ChatGPT", "apikey": "API key"}.get(mode, mode)}
    except (OSError, ValueError, AttributeError):
        pass
    return {"signedIn": False, "plan": None}


def settings():
    """Все, что показывает окно настроек: уведомления, Telegram, телефон, guard, host-run, proxy, агенты."""
    cfg = mnrhlib.read_config()
    out = {"errors": {}}

    def part(name, fn):
        try:
            out[name] = fn()
        except Exception as e:  # окно настроек показывает остальное и причину
            out[name] = None
            out["errors"][name] = f"{type(e).__name__}: {e}"

    def notify():
        import ntfy_alert
        import telegram
        try:
            after = int(cfg.get("notify_after", 20))
        except ValueError:
            after = 20
        try:
            away = int(cfg.get("telegram_away", telegram.DEFAULT_AWAY))
        except ValueError:
            away = telegram.DEFAULT_AWAY
        return {"on": cfg.get("notify", "on") != "off", "after": after, "sound": cfg.get("notify_sound", "on") != "off",
                "telegram": {"connected": bool(cfg.get("telegram_chat")), "bot": cfg.get("telegram_bot") or None,
                             "when": "always" if cfg.get("telegram_when") == "always" else "away", "away": away,
                             "approve": cfg.get("telegram_approve", "off") == "on"},
                "phone": {"mode": ntfy_alert.phone_mode(), "configured": ntfy_alert.configured()}}

    def guard():
        import claude_guard
        skipped = claude_guard.skipped()
        return {"on": claude_guard.enabled() if hasattr(claude_guard, "enabled") else cfg.get("guard", "on") != "off",
                "rules": [{"id": rid, "text": text, "textEn": claude_guard.RULES_EN.get(rid, text), "on": rid not in skipped}
                          for rid, text in claude_guard.RULES.items()],
                "log": guard_log(), "logPath": claude_guard.LOG}

    def modes_info():
        import claude_buildlog
        import claude_lid
        try:
            lid_ready = claude_lid.ready()
        except Exception:
            lid_ready = False
        return {"buildlogDays": claude_buildlog.KEEP_DAYS, "buildlogLines": claude_buildlog.MAX_LINES,
                "buildlogDir": claude_buildlog.LOGS, "lidReady": lid_ready}

    def host_run():
        import host_run as hr
        try:
            info = hr.ping()
        except Exception:
            info = None
        try:
            rules = hr.load()
        except Exception as e:
            rules, out["errors"]["hostRunList"] = {}, str(e)
        cmds = [{"name": name, "cwd": r.get("cwd"), "run": r.get("run"), "args": bool(r.get("args"))}
                for name, r in sorted(rules.items())]
        return {"running": bool(info), "pid": (info or {}).get("pid"), "version": (info or {}).get("version"),
                "commands": cmds}

    def proxy_settings():
        import proxy
        base = proxy_state()
        base["country"] = proxy.setting("country") or None if proxy.configured() else None
        return base

    part("notify", notify)
    part("guard", guard)
    part("hostRun", host_run)
    part("modesInfo", modes_info)
    part("proxy", proxy_settings)
    part("modes", modes)
    part("claude", lambda: agent_info("claude"))
    part("codex", lambda: agent_info("codex"))
    return out


def doctor():
    """Проверки agentmeister doctor данными: группа, уровень ok, warn или bad, текст."""
    import doctor
    rows = []
    for check in doctor.CHECKS:
        name = check.__name__[6:]
        try:
            found = check()
        except Exception as e:
            found = [("bad", mnrhlib.tr(f"{name}: проверка упала ({e!r})", f"{name}: the check crashed ({e!r})"))]
        rows += [{"check": name, "level": level, "text": text} for level, text in found]
    return {"rows": rows}


def guard_log(n=4):
    """Последние срабатывания guard короче, как в окне настроек: "24.11 13:56  hold  secrets-read  /x/.env"."""
    import claude_guard
    try:
        with open(claude_guard.LOG) as f:
            lines = f.readlines()[-n:]
    except OSError:
        return []
    out = []
    for line in lines:
        m = re.match(r"\d{4}-(\d\d)-(\d\d) (\d\d:\d\d):\d\d (.*)", line.rstrip("\n"))
        out.append(f"{m.group(2)}.{m.group(1)} {m.group(3)}  {m.group(4)}" if m else line.rstrip("\n"))
    return out


def guard_test(command, cwd=None):
    """Что guard сделает с командой: правило и причина или ничего. Как agentmeister guard test, но данными."""
    import claude_guard
    text = " ".join(command.split())
    tool, inp = (("Read", {"file_path": text}) if text and not re.search(r"\s", text) and claude_guard.is_secret(text)
                 else ("Bash", {"command": text}))
    found = claude_guard.check(tool, inp, cwd or os.getcwd())
    if not found:
        return {"rule": None}
    return {"rule": found[0], "why": found[1], "off": found[0] in claude_guard.skipped()}


def project(path):
    """Все для экрана проекта: git, прошлая сессия, бэклог, параллельные задачи, что из инструментов подходит."""
    import subprocess
    root = os.path.realpath(os.path.expanduser(path))

    def git(*args):
        try:
            return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, timeout=5).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            return ""

    out = {"path": root, "name": os.path.basename(root), "errors": {}}
    is_git = bool(git("rev-parse", "--git-dir"))
    out["git"] = None
    if is_git:
        commits = []
        for line in git("log", "-3", "--no-merges", "--format=%h%x09%ct%x09%s").splitlines():
            sha, ts, subject = (line.split("\t", 2) + ["", ""])[:3]
            commits.append({"sha": sha, "time": int(ts) if ts.isdigit() else None, "subject": subject})
        out["git"] = {"branch": git("branch", "--show-current") or None,
                      "dirty": len(git("status", "--porcelain").splitlines()), "commits": commits}

    def last():
        import claude_brief
        import claude_search
        sid, data = claude_brief.last_session(root, root)
        if not data:
            return None
        replies = [m for m in data["msgs"] if m[0] == "claude"]
        text = " ".join(replies[-1][2].split()) if replies else ""
        return {"id": sid, "title": claude_search.title(sid, data), "last": epoch(data.get("last")),
                "size": file_size(data.get("path")), "summary": text[:400]}

    def todos():
        import mnrh_todo
        items = mnrh_todo.load(root)
        opened = [it for it in items if not it["done"]]
        done = [it for it in items if it["done"]][-3:]
        return ([{"n": i + 1, "text": it["text"], "done": False} for i, it in enumerate(opened)]
                + [{"n": None, "text": it["text"], "done": True} for it in done])

    def parallel():
        import claude_parallel
        return [{"branch": e["branch"], "task": e.get("task") or "", "ahead": e.get("ahead"), "dirty": e.get("dirty", 0),
                 "running": bool(e.get("running")), "path": e["path"]} for e in claude_parallel.entries(root)] if is_git else []

    def tools():
        import release_notes
        since = release_notes.since_point(root)[0] if is_git else None
        return {"releaseSince": since if since and not since.startswith("@") else None,
                "gradle": os.path.exists(os.path.join(root, "gradle", "libs.versions.toml"))}

    for name, fn, empty in (("last", last, None), ("todos", todos, []), ("parallel", parallel, []), ("tools", tools, {})):
        try:
            out[name] = fn()
        except Exception as e:
            out[name] = empty
            out["errors"][name] = f"{type(e).__name__}: {e}"
    return out


def lang_setting():
    """Что выбрано в config: ru, en или auto, если язык берется из macOS."""
    value = mnrhlib.read_config().get("lang", "").lower()
    return value if value in ("ru", "en") else "auto"


def set_lang(value):
    """agentmeister lang ru|en|auto. auto убирает выбор, и язык снова берется из macOS."""
    value = (value or "").lower()
    if value not in ("ru", "en", "auto"):
        print("agentmeister lang ru|en|auto", file=sys.stderr)
        return 2
    mnrhlib.write_config(lang=None if value == "auto" else value)
    print(mnrhlib.tr(f"язык: {mnrhlib.lang()}" + (" (как в macOS)" if value == "auto" else ""),
                     f"language: {mnrhlib.lang()}" + (" (from macOS)" if value == "auto" else "")))
    return 0


def write_projects_dirs(dirs):
    """Записать список папок проектов; ровно ~/Developer по умолчанию убирает строку из config."""
    if dirs == [mnrhlib.DEFAULT_DEV]:
        mnrhlib.write_config(projects=None)
    else:
        mnrhlib.write_config(projects=":".join(mnrhlib.tilde(d) for d in dirs))


def check_projects_folder(path):
    """Папка с проектами, а не сам проект. -> текст ошибки или None."""
    if not os.path.isdir(path):
        return mnrhlib.tr(f"папки {mnrhlib.tilde(path)} нет", f"no folder {mnrhlib.tilde(path)}")
    if os.path.exists(os.path.join(path, ".git")):
        parent = mnrhlib.tilde(os.path.dirname(path))
        return mnrhlib.tr(f"{mnrhlib.tilde(path)} сам проект, а нужна папка, в которой лежат проекты, например {parent}",
                          f"{mnrhlib.tilde(path)} is a project itself, pick the folder that holds projects, for example {parent}")
    if ":" in path:
        return mnrhlib.tr("в пути папки не должно быть двоеточия", "the folder path can't contain a colon")
    real = os.path.realpath(path)
    for existing in mnrhlib.projects_dirs():
        other = os.path.realpath(existing)
        if real == other:
            return mnrhlib.tr(f"{mnrhlib.tilde(path)} уже в списке как {mnrhlib.tilde(existing)}",
                              f"{mnrhlib.tilde(path)} is already listed as {mnrhlib.tilde(existing)}")
        if real.startswith(other + "/") or other.startswith(real + "/"):
            return mnrhlib.tr(f"{mnrhlib.tilde(path)} вложена в {mnrhlib.tilde(existing)} или наоборот, проекты задвоятся",
                              f"{mnrhlib.tilde(path)} and {mnrhlib.tilde(existing)} are nested, projects would show twice")
    return None


def check_projects_folder_alone(path):
    """Как check_projects_folder, но для замены всего списка: с прежними папками не сравниваем."""
    if not os.path.isdir(path):
        return mnrhlib.tr(f"папки {mnrhlib.tilde(path)} нет", f"no folder {mnrhlib.tilde(path)}")
    if os.path.exists(os.path.join(path, ".git")):
        parent = mnrhlib.tilde(os.path.dirname(path))
        return mnrhlib.tr(f"{mnrhlib.tilde(path)} сам проект, а нужна папка, в которой лежат проекты, например {parent}",
                          f"{mnrhlib.tilde(path)} is a project itself, pick the folder that holds projects, for example {parent}")
    return None


def show_projects_dirs():
    for d in mnrhlib.projects_dirs():
        count = sum(os.path.isdir(os.path.join(d, n, ".git")) for n in os.listdir(d)) if os.path.isdir(d) else 0
        print(mnrhlib.tr(f"{mnrhlib.tilde(d)}  проектов с git: {count}", f"{mnrhlib.tilde(d)}  git projects: {count}"))
    return 0


def set_projects_dir(args):
    """agentmeister projects-dir [add|remove] <папка> или default. Это папки, в которых лежат проекты, а не проекты:
    проектами считаются их подпапки. Без add/remove папка заменяет весь список."""
    usage = "agentmeister projects-dir [add|remove] <папка> | default"
    if os.environ.get("MNRH_PROJECTS"):
        # переменная перекрывает config: запись в config ничего бы не поменяла
        print(mnrhlib.tr("задан MNRH_PROJECTS, он перекрывает список в config. Убери переменную или поменяй ее",
                         "MNRH_PROJECTS is set and overrides the list in config. Unset or change the variable"),
              file=sys.stderr)
        return 2
    op = args[0] if args[0] in ("add", "remove") else "set"
    value = args[1] if op != "set" and len(args) > 1 else args[0] if op == "set" else None
    if not value:
        print(usage, file=sys.stderr)
        return 2
    dirs = mnrhlib.projects_dirs()
    if op == "set" and value in ("default", "auto"):
        write_projects_dirs([mnrhlib.DEFAULT_DEV])
        return show_projects_dirs()
    path = os.path.abspath(os.path.expanduser(value))
    if op == "remove":
        if path not in dirs:
            print(mnrhlib.tr(f"{mnrhlib.tilde(path)} нет в списке", f"{mnrhlib.tilde(path)} isn't in the list"), file=sys.stderr)
            return 2
        rest = [d for d in dirs if d != path]
        write_projects_dirs(rest or [mnrhlib.DEFAULT_DEV])
        return show_projects_dirs()
    if op == "add" and path in dirs:
        return show_projects_dirs()
    error = check_projects_folder(path) if op == "add" else check_projects_folder_alone(path)
    if error:
        print(error, file=sys.stderr)
        return 2
    write_projects_dirs([path] if op == "set" else dirs + ([] if path in dirs else [path]))
    return show_projects_dirs()


def main(argv):
    if argv and argv[0] in ("-h", "--help", "help"):
        print(mnrhlib.tr("agentmeister app-state                состояние для десктопного Agentmeister в JSON\n"
                         "agentmeister app-state search <слова>  поиск по всем сессиям\n"
                         "agentmeister app-state read <id>       последние сообщения сессии\n"
                         "agentmeister app-state usage [дней]    статистика, 0 значит за все время\n"
                         "agentmeister app-state settings        что показывает окно настроек\n"
                         "agentmeister app-state doctor          проверки agentmeister doctor\n"
                         "agentmeister app-state lang [ru|en|auto]  язык интерфейса\n"
                         "agentmeister app-state projects-dir [add|remove] <папка>|default  папки с проектами",
                         "agentmeister app-state                state for the Agentmeister desktop app as JSON\n"
                         "agentmeister app-state search <words>  search all sessions\n"
                         "agentmeister app-state read <id>       latest messages of a session\n"
                         "agentmeister app-state usage [days]    usage stats, 0 means all time\n"
                         "agentmeister app-state settings        what the settings window shows\n"
                         "agentmeister app-state doctor          agentmeister doctor checks\n"
                         "agentmeister app-state lang [ru|en|auto]  interface language\n"
                         "agentmeister app-state projects-dir [add|remove] <folder>|default  folders that hold projects"))
        return 0
    if argv and argv[0] == "projects-dir":
        return show_projects_dirs() if len(argv) == 1 else set_projects_dir(argv[1:])
    if argv and argv[0] == "lang":
        if len(argv) == 1:
            print(f"{mnrhlib.lang()} ({lang_setting()})")
            return 0
        return set_lang(argv[1])
    if argv and argv[0] == "project" and len(argv) > 1:
        out = project(argv[1])
    elif argv and argv[0] == "guard-test":
        rest = argv[1:]
        cwd = None
        if rest[:1] == ["--cwd"] and len(rest) > 1:
            cwd, rest = rest[1], rest[2:]
        out = guard_test(" ".join(rest), cwd)
    elif argv and argv[0] == "search":
        out = search(" ".join(argv[1:]))
    elif argv and argv[0] == "read" and len(argv) > 1:
        out = read(argv[1])
    elif argv and argv[0] == "settings":
        out = settings()
    elif argv and argv[0] == "doctor":
        out = doctor()
    elif argv and argv[0] == "usage":
        out = usage(int(argv[1]) if len(argv) > 1 and argv[1].isdigit() else 7)
    elif argv:
        print(mnrhlib.tr(f"agentmeister app-state: не знаю {argv[0]}", f"agentmeister app-state: unknown command {argv[0]}"),
              file=sys.stderr)
        return 2
    else:
        out = collect()
    json.dump(out, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
