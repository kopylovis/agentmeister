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
        out.append({
            "id": s["id"], "cwd": s["cwd"] or m["cwd"] or "", "title": m["title"], "branch": m["branch"],
            "mtime": s["mtime"], "size": s["size"], "running": bool(s.get("running")),
        })
    if fresh != cache:
        try:
            os.makedirs(os.path.dirname(META_CACHE), exist_ok=True)
            mnrhlib.write_json(META_CACHE, fresh, mode=0o600, ensure_ascii=False, separators=(",", ":"))
        except OSError:
            pass
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


def epoch(ts):
    """ISO-время из переписки в секунды Unix, как mtime у сессий."""
    from datetime import datetime
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
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
            "last": epoch(data.get("last")), "count": len(found),
            "hits": [{"at": i, "role": data["msgs"][i][0], "time": epoch(data["msgs"][i][1]),
                      "snippet": claude_search.snippet(data["msgs"][i][2], q, r.idf, width=240)}
                     for i in found[:3]],
        })
    return {"query": query, "exact": r.exact, "scanned": len(r.scope), "results": results}


def read(ref, tail=12, chars=700):
    """Последние сообщения сессии для превью в библиотеке."""
    import claude_search
    idx = claude_search.refresh()
    sid, err = claude_search.resolve(ref, idx)
    if err:
        return {"error": err}
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
    path = shutil.which(binary)
    if not path:
        return {"installed": False, "path": None, "version": None}
    try:
        out = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=10).stdout.split()
    except (OSError, subprocess.TimeoutExpired):
        out = []
    version = next((w for w in out if w[:1].isdigit()), None)
    return {"installed": True, "path": path, "version": version, **signed_in(binary)}


def signed_in(binary):
    """Выполнен ли вход, по файлам самих агентов. Сами токены не читаются и никуда не идут."""
    home = os.path.expanduser("~")
    try:
        if binary == "claude":
            with open(os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or home, ".claude.json")) as f:
                account = json.load(f).get("oauthAccount") or {}
            return {"signedIn": bool(account), "plan": account.get("billingType")}
        if binary == "codex":
            with open(os.path.join(os.environ.get("CODEX_HOME") or os.path.join(home, ".codex"), "auth.json")) as f:
                auth = json.load(f)
            return {"signedIn": bool(auth.get("tokens") or auth.get("OPENAI_API_KEY")), "plan": auth.get("auth_mode")}
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
                "rules": [{"id": rid, "text": text, "on": rid not in skipped} for rid, text in claude_guard.RULES.items()]}

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
        import claude_proxy
        base = proxy()
        base["country"] = claude_proxy.setting("country") or None if claude_proxy.configured() else None
        return base

    part("notify", notify)
    part("guard", guard)
    part("hostRun", host_run)
    part("proxy", proxy_settings)
    part("modes", modes)
    part("claude", lambda: agent_info("claude"))
    part("codex", lambda: agent_info("codex"))
    return out


def doctor():
    """Проверки agentmeister doctor данными: группа, уровень ok, warn или bad, текст."""
    import claude_doctor
    rows = []
    for check in claude_doctor.CHECKS:
        name = check.__name__[6:]
        try:
            found = check()
        except Exception as e:
            found = [("bad", f"{name}: проверка упала ({e!r})")]
        rows += [{"check": name, "level": level, "text": text} for level, text in found]
    return {"rows": rows}


def main(argv):
    if argv and argv[0] in ("-h", "--help", "help"):
        print("agentmeister app-state                состояние для десктопного Agentmeister в JSON\n"
              "agentmeister app-state search <слова>  поиск по всем сессиям\n"
              "agentmeister app-state read <id>       последние сообщения сессии\n"
              "agentmeister app-state usage [дней]    статистика, 0 значит за все время\n"
              "agentmeister app-state settings        что показывает окно настроек\n"
              "agentmeister app-state doctor          проверки agentmeister doctor")
        return 0
    if argv and argv[0] == "search":
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
        print(f"agentmeister app-state: не знаю {argv[0]}", file=sys.stderr)
        return 2
    else:
        out = collect()
    json.dump(out, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
