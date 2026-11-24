"""agentmeister app-state: состояние для десктопного Agentmeister одним JSON.

Приложение не разбирает вывод для людей и не дублирует логику CLI. Оно раз в несколько секунд спрашивает
эту команду: проекты из папки проектов, сохраненные сессии Claude Code, открытые сейчас сессии с их статусом
(ждет, работает, свободна), состояние proxy и режимов. Каждая часть собирается отдельно: если одна упала,
остальные приходят как обычно, а в errors остается причина.
"""
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
        cwd = s["cwd"] or m["cwd"] or ""
        out.append({
            "id": s["id"], "cwd": cwd, "title": m["title"], "branch": m["branch"],
            "mtime": s["mtime"], "size": s["size"], "running": bool(s.get("running")),
            "cwdExists": bool(cwd) and os.path.isdir(cwd),
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
            "ip": info.get("ip") if isinstance(info.get("ip"), str) else None,
            "node": info.get("node") if isinstance(info.get("node"), str) else None,
            # без сохраненного выбора новая сессия идет через proxy, как в правилах пользователя и в меню
            "defaultRoute": "direct" if os.path.exists(claude_proxy.LAST) and claude_proxy.last() == "direct" else "proxy",
            "sessions": held}


def modes():
    import claude_menu
    return claude_menu.modes()


def retention_days():
    """Сколько дней Claude Code хранит переписки: cleanupPeriodDays, по умолчанию 30."""
    import claude_settings
    try:
        days = claude_settings.load().get("cleanupPeriodDays")
    except (OSError, ValueError):
        days = None
    return days if isinstance(days, int) else 30


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
             "generatedAt": time.time(), "errors": {}}
    for name, part, empty in (("projects", projects, []), ("sessions", sessions, []), ("live", live, []),
                              ("proxy", proxy, None), ("modes", modes, {}), ("hostRun", host_run_summary, None),
                              ("signedIn", lambda: {b: signed_in(b)["signedIn"] for b in ("claude", "codex")}, None),
                              ("retentionDays", retention_days, None)):
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
    real = os.path.realpath(path)
    via = ("homebrew" if "/Caskroom/" in real or "/Cellar/" in real or real.startswith("/opt/homebrew/") else
           "installer" if binary == "claude" and "/.local/" in real else "other")
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
            found = dict(re.findall(r'^(model|model_reasoning_effort)\s*=\s*"([^"]*)"', text, re.M))
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
        import claude_proxy
        base = proxy()
        base["country"] = claude_proxy.setting("country") or None if claude_proxy.configured() else None
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


def guard_test(command):
    """Что guard сделает с командой: правило и причина или ничего. Как agentmeister guard test, но данными."""
    import claude_guard
    text = " ".join(command.split())
    tool, inp = (("Read", {"file_path": text}) if text and not re.search(r"\s", text) and claude_guard.is_secret(text)
                 else ("Bash", {"command": text}))
    found = claude_guard.check(tool, inp, os.getcwd())
    if not found:
        return {"rule": None}
    return {"rule": found[0], "why": found[1], "off": found[0] in claude_guard.skipped()}


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


def main(argv):
    if argv and argv[0] in ("-h", "--help", "help"):
        print("agentmeister app-state                состояние для десктопного Agentmeister в JSON\n"
              "agentmeister app-state search <слова>  поиск по всем сессиям\n"
              "agentmeister app-state read <id>       последние сообщения сессии\n"
              "agentmeister app-state usage [дней]    статистика, 0 значит за все время\n"
              "agentmeister app-state settings        что показывает окно настроек\n"
              "agentmeister app-state doctor          проверки agentmeister doctor\n"
              "agentmeister app-state lang [ru|en|auto]  язык интерфейса")
        return 0
    if argv and argv[0] == "lang":
        if len(argv) == 1:
            print(f"{mnrhlib.lang()} ({lang_setting()})")
            return 0
        return set_lang(argv[1])
    if argv and argv[0] == "guard-test":
        out = guard_test(" ".join(argv[1:]))
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
        print(f"agentmeister app-state: не знаю {argv[0]}", file=sys.stderr)
        return 2
    else:
        out = collect()
    json.dump(out, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
