#!/usr/bin/env python3
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import HOME, NOTICES, RESTART_QUEUE, UUID_RE, settings_path, tilde, tr, write_json  # noqa: E402
from claude_proc import (SHELLS, RestartError, argv_of, caffeinate_args, claude_version,  # noqa: E402
                         drop_name, find_claude, launcher, ps, resume_flags, session_file, session_path)
import claude_search  # noqa: E402
import restart_job  # noqa: E402

LOG = os.path.join(HOME, "Library", "Logs", "mnrh-claude-restart.log")
SLIM_MIN = 5 << 20
# с какого контекста /slim напоминает про /compact: сам /slim то, что видит модель, не трогает
COMPACT_HINT = 200_000
QUEUE = RESTART_QUEUE
NOTICE_TTL = 300

FIND_TAB = {
    "Apple_Terminal": '''
on run argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is (item 1 of argv) then
          if (count of argv) > 1 then do script (item 2 of argv) in t
          return "ok"
        end if
      end repeat
    end repeat
  end tell
  return "notfound"
end run''',
    "iTerm.app": '''
on run argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if tty of s is (item 1 of argv) then
            if (count of argv) > 1 then tell s to write text (item 2 of argv)
            return "ok"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "notfound"
end run''',
}


def no_hook_reason(pid, term):
    head = tr(f"в этом терминале ({term}) Claude возвращается во вкладку только через хук zsh, а его здесь нет: ",
              f"in this terminal ({term}) Claude can only return to the tab through the zsh hook, and it isn't here: ")
    parent = launcher(pid)
    if parent not in SHELLS:
        return head + tr(f"Claude запущен не из shell, а напрямую ({parent or 'неизвестно кем'}), например вкладкой "
                         "Claude Code в IDE, и после выхода вкладке некуда вернуться. Открой обычную вкладку терминала "
                         "и запусти claude там",
                         f"Claude was started directly, not from a shell ({parent or 'unknown parent'}), for example "
                         "by a Claude Code tab in an IDE, so the tab has nothing to return to. Open a regular "
                         "terminal tab and run claude there")
    if parent != "zsh":
        return head + tr(f"shell здесь {parent}, а хук есть только для zsh",
                         f"the shell here is {parent}, and the hook only exists for zsh")
    from setup_cmd import ZSHRC, is_zsh_hook, zshrc_lines
    hooked = any(is_zsh_hook(l) for l in zshrc_lines())
    if not hooked:
        return head + tr(f"в {tilde(ZSHRC)} нет строки с хуком. Выполни agentmeister setup и открой новую вкладку",
                         f"{tilde(ZSHRC)} has no hook line. Run agentmeister setup and open a new tab")
    return head + tr(f"в {tilde(ZSHRC)} он есть, но эта вкладка открыта раньше. Открой новую вкладку терминала "
                     "и запусти claude там",
                     f"{tilde(ZSHRC)} has it, but this tab was opened before that. Open a new terminal tab "
                     "and run claude there")


def proxy_sub_args():
    """Подписка, через которую строго идет эта сессия (agentmeister -x home), для команды перезапуска."""
    sub = os.environ.get("MNRH_PROXY_SUB", "") if os.environ.get("MNRH_PROXY") else ""
    return [sub] if restart_job.SUB_NAME.fullmatch(sub) else []


def proxy_job_value():
    """proxy в задании перезапуска: имя подписки, true для каскада или false без proxy."""
    sub = proxy_sub_args()
    return sub[0] if sub else bool(os.environ.get("MNRH_PROXY"))


def plan(update=True, forget=False, slim=False, fresh=False):
    if os.environ.get("CLAUDE_CODE_SKIP_PROMPT_HISTORY") == "1" and not (forget or fresh):
        # agentmeister -i: переписка не пишется на диск, открывать заново нечего
        raise RestartError(tr("эта сессия без записи на диск (agentmeister -i), открыть ее заново нечем. "
                              "/fresh или /forget откроют новую, тоже без записи",
                              "this session isn't saved to disk (agentmeister -i), so there's nothing to reopen. "
                              "/fresh or /forget will open a new one, also not saved"))
    from claude_proxy_restart import CHANNEL, session_pid
    proxy_restart = os.environ.get("MNRH_PROXY") and not (forget or slim or fresh)
    channel = os.environ.get(CHANNEL) if proxy_restart else None
    pid = session_pid(channel) if channel else find_claude()
    try:
        with open(session_file(pid)) as f:
            info = json.load(f)
    except (OSError, ValueError) as e:
        raise RestartError(tr(f"не прочитал {tilde(session_file(pid))}: {e}",
                              f"couldn't read {tilde(session_file(pid))}: {e}"))
    sid = info.get("sessionId") or os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not sid:
        raise RestartError(tr("не знаю id текущей сессии", "don't know the current session id"))
    cwd = info.get("cwd") or os.getcwd()
    if channel:
        if not UUID_RE.fullmatch(sid) or os.environ.get("CLAUDE_CODE_SESSION_ID") not in (None, "", sid):
            raise RestartError(tr("не удалось подтвердить номер этой прокси-сессии",
                                  "couldn't confirm the id of this proxy session"))
        return {"pid": pid, "sid": sid, "cwd": cwd, "via": "proxy", "channel": channel,
                "title": info.get("name") or sid}
    tty = ps("tty", pid)
    if not tty or tty in ("??", "-"):
        # в песочнице proxy-сессии ps запрещен: терминал передает вкладка (Agentmeister и хук zsh) в MNRH_TTY
        given = os.environ.get("MNRH_TTY", "")
        if re.fullmatch(r"/dev/ttys\d+", given):
            tty = given
    if not tty or tty in ("??", "-"):
        if proxy_restart:
            command = shlex.join(["agentmeister", "-x", *proxy_sub_args(), cwd, "--", "--resume", sid])
            raise RestartError(tr(f"не удалось определить терминал этой прокси-сессии. Введи /exit, "
                                  f"затем выполни в терминале:\n{command}",
                                  f"couldn't find the terminal of this proxy session. Type /exit, "
                                  f"then run in the terminal:\n{command}"))
        raise RestartError(tr("у Claude нет терминала, перезапускать некуда",
                              "Claude has no terminal, there's nowhere to restart it"))
    tty = "/dev/" + tty if not tty.startswith("/dev/") else tty
    term = os.environ.get("TERM_PROGRAM", "")
    hook = os.environ.get("MNRH_RESTART_HOOK")
    if hook == restart_job.HOOK_VERSION:
        via = "zsh"
    elif term in FIND_TAB:
        via = term
    elif hook:
        # хук старой версии выполняет задание как команду shell, новое задание в JSON он не поймет
        raise RestartError(tr("в этой вкладке хук zsh от старой версии agentmeister. Открой новую вкладку терминала "
                              "и запусти claude там",
                              "this tab has the zsh hook from an old agentmeister version. Open a new terminal tab "
                              "and run claude there"))
    else:
        raise RestartError(no_hook_reason(pid, term or os.environ.get("TERMINAL_EMULATOR")
                                          or tr("неизвестный", "unknown")))

    flags = resume_flags(argv_of(pid)[1:])
    caffeinate = caffeinate_args(pid)
    new = forget or fresh
    if new:
        flags = drop_name(flags)
    flags, dropped = restart_job.clean_flags(flags)
    if dropped:
        log(f"незнакомые флаги не переносятся: {shlex.join(dropped)}")

    new_sid = str(uuid.uuid4()) if new else sid
    mode = "forget" if forget else "fresh" if fresh else "slim" if slim else "restart"
    try:
        # сессия через proxy (agentmeister -x): её окружение досталось и нам, перезапускаем тоже через proxy
        job = restart_job.claude_job(cwd, mode, sid, new_sid, update=update and not new and not slim,
                                     proxy=proxy_job_value(), caffeinate=caffeinate, flags=flags)
    except restart_job.JobError as e:
        raise RestartError(tr(f"не собрал команду перезапуска: {e}", f"couldn't build the restart command: {e}"))
    line = restart_job.shell_line(job)
    return {"pid": pid, "sid": sid, "cwd": cwd, "tty": tty, "term": term, "via": via, "line": line, "job": job,
            "forget": forget,
            "slim": slim, "fresh": fresh,
            "title": session_title(sid) or info.get("name") or sid, "new_sid": new_sid,
            "version": claude_version()}


def osascript(term, *args):
    r = subprocess.run(["osascript", "-e", FIND_TAB[term], *args], capture_output=True, text=True, timeout=60)
    return r.returncode, (r.stdout.strip() or r.stderr.strip())


def preflight(p):
    if p["via"] == "zsh":
        os.makedirs(QUEUE, exist_ok=True)
        return
    code, out = osascript(p["term"], p["tty"])
    if code != 0:
        raise RestartError(tr("macOS не дал управлять терминалом: разреши в "
                              f"{settings_path('settings', 'privacy', 'automation')} ({out})",
                              "macOS didn't allow controlling the terminal. Allow it in "
                              f"{settings_path('settings', 'privacy', 'automation')} ({out})"))
    if out != "ok":
        raise RestartError(tr(f"не нашёл вкладку с {p['tty']}", f"couldn't find the tab with {p['tty']}"))


def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


def watcher(p, delay):
    time.sleep(delay)
    log(f"restart {p['sid']} pid {p['pid']} tty {p['tty']} via {p['via']}")
    write_notice(p, "pending" if p["forget"] or p.get("slim") else "done")
    if p["via"] == "zsh":
        restart_job.write(os.path.join(QUEUE, os.path.basename(p["tty"])), p["job"])
    try:
        os.kill(p["pid"], signal.SIGTERM)
    except ProcessLookupError:
        pass
    for _ in range(150):
        try:
            os.kill(p["pid"], 0)
        except ProcessLookupError:
            break
        time.sleep(0.1)
    else:
        log("SIGTERM не помог, SIGKILL")
        try:
            os.kill(p["pid"], signal.SIGKILL)
        except ProcessLookupError:
            pass
        time.sleep(0.5)
    if p["forget"]:
        ok = forget_session(p["sid"])
        write_notice(p, "done" if ok else "failed")
    if p["via"] == "zsh":
        log(f"zsh: {p['line']}")
        return
    time.sleep(0.8)
    code, out = osascript(p["term"], p["tty"], p["line"])
    log(f"osascript {code} {out}: {p['line']}")


def session_title(sid):
    path = session_path(sid)
    data = claude_search.update(sid, path) if path else None
    title = claude_search.title(sid, data) if data else ""
    return "" if title in ("без названия", "untitled") else title


def write_notice(p, status):
    os.makedirs(NOTICES, exist_ok=True)
    kind = "forget" if p["forget"] else "slim" if p.get("slim") else "fresh" if p.get("fresh") else "restart"
    data = {"kind": kind, "status": status, "title": p["title"],
            "old_sid": p["sid"], "version": p["version"], "at": time.time()}
    write_json(os.path.join(NOTICES, p["new_sid"] + ".json"), data, ensure_ascii=False)


def notice_text(n):
    title = n.get("title") or n.get("old_sid", "")
    if len(title) > 60:
        title = title[:59] + "…"
    now = claude_version()
    if n["kind"] == "slim":
        if n.get("status") == "done":
            return tr(f"✓ agentmeister: сессия «{title}» сжата: {n.get('before')} → {n.get('after')}, скриншотов убрано "
                      f"{n.get('images', 0)}. То, что видит модель, не менялось. Вернуть: "
                      f"agentmeister sessions slim {n.get('old_sid', '')[:8]} --undo.",
                      f"✓ agentmeister: session \"{title}\" compacted: {n.get('before')} → {n.get('after')}, "
                      f"screenshots removed: {n.get('images', 0)}. What the model sees didn't change. To undo: "
                      f"agentmeister sessions slim {n.get('old_sid', '')[:8]} --undo.") + compact_hint(n.get("context"))
        if n.get("status") == "failed":
            return tr(f"! agentmeister: сессию «{title}» сжать не удалось ({n.get('error')}). Она открыта без изменений.",
                      f"! agentmeister: couldn't compact session \"{title}\" ({n.get('error')}). "
                      "It's open unchanged.")
        return tr(f"… agentmeister: сессия «{title}» открыта, но сжатие не отчиталось — проверь: agentmeister sessions slim",
                  f"… agentmeister: session \"{title}\" is open, but compacting didn't report back. "
                  "Check: agentmeister sessions slim")
    if n["kind"] == "restart":
        was = n.get("version")
        if was and now and was != now:
            ver = tr(f"обновлён {was} → {now}", f"updated {was} → {now}")
        else:
            ver = (tr(f"версия {now or was}", f"version {now or was}")
                   + (tr(", обновлений не было", ", no updates") if was and now else ""))
        return tr(f"✓ agentmeister: Claude Code перезапущен ({ver}). Сессия «{title}» продолжается.",
                  f"✓ agentmeister: Claude Code restarted ({ver}). Session \"{title}\" continues.")
    if n["kind"] == "fresh":
        return tr(f"✓ agentmeister: новая чистая сессия. Прошлая «{title}» сохранена, вернуться к ней: "
                  f"/resume или claude --resume {n.get('old_sid', '')}",
                  f"✓ agentmeister: new clean session. The previous one, \"{title}\", is saved. To go back to it: "
                  f"/resume or claude --resume {n.get('old_sid', '')}")
    if n.get("status") == "done":
        return tr(f"✓ agentmeister: прошлая сессия «{title}» удалена — переписка, история запросов и file-history. "
                  "Это новая чистая сессия.",
                  f"✓ agentmeister: previous session \"{title}\" deleted, with its transcript, prompt history and "
                  "file-history. This is a new clean session.")
    if n.get("status") == "failed":
        return tr(f"! agentmeister: прошлую сессию «{title}» не удалось найти и удалить, проверь: agentmeister sessions -l",
                  f"! agentmeister: couldn't find and delete previous session \"{title}\". "
                  "Check: agentmeister sessions -l")
    return tr(f"… agentmeister: прошлая сессия «{title}» ещё удаляется, проверь позже: agentmeister sessions -l",
              f"… agentmeister: previous session \"{title}\" is still being deleted. "
              "Check later: agentmeister sessions -l")


def hook_payload():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return {}
    return payload if isinstance(payload, dict) else {}


def background(fn, *args):
    if os.fork():
        return
    os.setsid()
    if os.fork():
        os._exit(0)
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    try:
        fn(*args)
    except Exception as e:
        log(f"ошибка: {e!r}")
    os._exit(0)


def drop_junk(path, why):
    import session_store
    sid = os.path.basename(path)[:-6]
    if os.path.islink(path) or sid in session_store.running_ids() or not session_store.is_junk(path):
        return False
    for s in session_store.by_id(sid, meta=False):
        if not s["link"] and os.path.abspath(s["path"]) == os.path.abspath(path):
            try:
                session_store.delete(s)
            except session_store.SessionInUse:
                return False
            log(f"пустая сессия {sid} удалена ({why})")
            return True
    return False


def warm_up(pdir, keep):
    sweep(pdir, keep)
    claude_search.refresh()
    import claude_usage
    claude_usage.refresh()


def sweep(pdir, keep):
    for name in os.listdir(pdir):
        path = os.path.join(pdir, name)
        if not name.endswith(".jsonl") or not UUID_RE.match(name[:-6]) or name[:-6] == keep:
            continue
        try:
            if time.time() - os.path.getmtime(path) < 60:
                continue
        except OSError:
            continue
        drop_junk(path, "уборка при старте")


def remember_open(sid, payload):
    """Для agentmeister restore: что было открыто и как запущено. Процесс Claude ищем здесь, в фоне его уже не найти."""
    if os.environ.get("MNRH_CHILD") == "1" or os.environ.get("CLAUDE_CODE_SKIP_PROMPT_HISTORY") == "1":
        return
    from claude_proxy_restart import CHANNEL, session_pid
    # в песочнице proxy-сессии ps запрещен: pid дает канал перезапуска, терминал MNRH_TTY, как в plan()
    channel = os.environ.get(CHANNEL) if os.environ.get("MNRH_PROXY") else None
    try:
        pid = session_pid(channel) if channel else find_claude()
    except (RestartError, OSError, ValueError):
        return
    if not pid:
        return
    tty = ps("tty", pid)
    if not tty or "?" in tty or tty == "-":
        given = os.environ.get("MNRH_TTY", "")
        tty = given if re.fullmatch(r"/dev/ttys\d+", given) else ""
    if not tty:
        return
    import claude_live
    tty = tty if tty.startswith("/dev/") else "/dev/" + tty
    background(claude_live.remember, sid, payload.get("cwd") or os.getcwd(), pid, tty,
               os.environ.get("__CFBundleIdentifier", ""), proxy_job_value())


def session_end():
    payload = hook_payload()
    sid, path = payload.get("session_id"), payload.get("transcript_path")
    if sid and UUID_RE.match(sid):
        import claude_live
        claude_live.forget(sid)
    if not sid or not UUID_RE.match(sid) or not path or not path.endswith(sid + ".jsonl"):
        return 0
    try:
        pid = find_claude()
    except RestartError:
        pid = None

    def later():
        if payload.get("reason") == "clear" or pid is None:
            time.sleep(2)
        else:
            for _ in range(100):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            time.sleep(0.5)
        drop_junk(path, f"закрытие: {payload.get('reason') or '?'}")

    background(later)
    return 0


def read_notice(sid):
    path = os.path.join(NOTICES, sid + ".json")
    n = None
    for _ in range(30):
        try:
            with open(path) as f:
                n = json.load(f)
        except (OSError, ValueError):
            return None
        if n.get("status") != "pending":
            break
        time.sleep(0.1)
    try:
        os.remove(path)
    except OSError:
        pass
    return n if n and time.time() - n.get("at", 0) <= NOTICE_TTL else None


def brief_wanted(payload, n):
    import claude_brief
    if payload.get("source") != "startup" or (n and n.get("kind") in ("forget", "fresh")):
        return False
    if os.environ.get("MNRH_CHILD") == "1" or not claude_brief.enabled():
        return False
    try:
        tty = ps("tty", find_claude())
    except RestartError:
        return False
    return bool(tty) and "?" not in tty


def notice():
    import claude_guard
    claude_guard.sync_badge()
    payload = hook_payload()
    sid = payload.get("session_id")
    if not sid or not UUID_RE.match(sid):
        return 0
    path = payload.get("transcript_path")
    if path and os.path.isdir(os.path.dirname(path)):
        background(warm_up, os.path.dirname(path), sid)
    remember_open(sid, payload)
    n = read_notice(sid)
    messages, out = [notice_text(n)] if n else [], {}
    if brief_wanted(payload, n):
        import claude_brief
        try:
            context, line = claude_brief.context_for_model(payload.get("cwd") or os.getcwd(), exclude=sid)
        except Exception as e:
            log(f"brief: {e!r}")
            context, line = "", ""
        if context:
            out["hookSpecificOutput"] = {"hookEventName": "SessionStart", "additionalContext": context}
        if line:
            messages.append(line)
    if messages:
        out["systemMessage"] = "\n".join(messages)
    if out:
        print(json.dumps(out, ensure_ascii=False))
    return 0


def forget_session(sid):
    import session_store
    found = session_store.by_id(sid, meta=False)
    if not found:
        log(f"forget: сессии {sid} не нашёл")
        return False
    s = found[0]
    try:
        session_store.delete(s)
    except session_store.SessionInUse:
        return False
    log(f"forget: удалил {sid}")
    return True


def detach(p, delay):
    background(watcher, p, delay)


def restart(update=True, delay=1.5, dry=False, forget=False, slim=False, fresh=False):
    p = plan(update, forget, slim, fresh)
    if p["via"] == "proxy":
        if not dry:
            from claude_proxy_restart import schedule
            schedule(p["channel"], p["pid"], p["sid"], update, delay)
        return p
    preflight(p)
    if dry:
        return p
    detach(p, delay)
    return p


def cli(args, forget=False, fresh=False):
    name = "forget" if forget else "fresh" if fresh else "restart"
    if "-h" in args or "--help" in args:
        if fresh:
            print(tr("agentmeister fresh              изнутри Claude Code: закрыть его и открыть новую сессию без названия",
                     "agentmeister fresh              from inside Claude Code: close it and open a new untitled session"))
            print(tr("                               и с пустым контекстом в той же папке и вкладке; эта остаётся в /resume",
                     "                               with an empty context in the same folder and tab. This one stays in /resume"))
            print(tr("agentmeister fresh --dry-run    только показать, что будет сделано",
                     "agentmeister fresh --dry-run    only show what would be done"))
        elif forget:
            print(tr("agentmeister forget             изнутри Claude Code: закрыть его, удалить эту сессию без следа",
                     "agentmeister forget             from inside Claude Code: close it, delete this session without a trace"))
            print(tr("                               (переписка, история запросов, file-history) и открыть чистый Claude",
                     "                               (transcript, prompt history, file-history) and open a clean Claude"))
            print(tr("                               в той же папке и вкладке — как /clear, только старое не сохраняется",
                     "                               in the same folder and tab. Like /clear, but the old one isn't kept"))
            print(tr("agentmeister forget --dry-run   только показать, что будет сделано",
                     "agentmeister forget --dry-run   only show what would be done"))
        else:
            print(tr("agentmeister restart            изнутри Claude Code: закрыть его и открыть эту же сессию в той же вкладке",
                     "agentmeister restart            from inside Claude Code: close it and reopen this session in the same tab"))
            print(tr("                               перед запуском обновляется Claude Code (claude update или brew upgrade)",
                     "                               Claude Code is updated before it starts (claude update or brew upgrade)"))
            print(tr("agentmeister restart --no-update  без обновления",
                     "agentmeister restart --no-update  without the update"))
            print(tr("agentmeister restart --dry-run    только показать, что будет сделано",
                     "agentmeister restart --dry-run    only show what would be done"))
        print()
        print(tr(f"Обычно вызывается из Claude: /{name} или инструментом {name} из MCP-сервера agentmeister",
                 f"Usually called from Claude: /{name} or the {name} tool of the agentmeister MCP server"))
        print(tr("(установить: agentmeister setup). Лог: ", "(install: agentmeister setup). Log: ") + tilde(LOG))
        return 0
    try:
        import session_defaults
        update = "--update" in args or ("--no-update" not in args and session_defaults.restart_update())
        p = restart(update=update, dry="--dry-run" in args, forget=forget, fresh=fresh)
    except RestartError as e:
        print(f"agentmeister {name}: {e}", file=sys.stderr)
        return 1
    if "--dry-run" in args and p["via"] == "proxy":
        print(tr(f"продолжу сессию {p['sid']} в той же вкладке через текущий прокси",
                 f"would continue session {p['sid']} in the same tab through the current proxy"))
    elif "--dry-run" in args:
        extra = tr(f"удалю сессию {p['sid']}, ", f"delete session {p['sid']}, ") if forget else ""
        print(tr(f"закрою pid {p['pid']}, {extra}в {p['tty']} через {p['via']} выполню:\n  {p['line']}",
                 f"would close pid {p['pid']}, {extra}run in {p['tty']} via {p['via']}:\n  {p['line']}"))
    elif forget:
        print(tr(f"Через пару секунд Claude Code закроется, сессия «{p['title']}» будет удалена, и откроется чистая.",
                 f"In a couple of seconds Claude Code will close, session \"{p['title']}\" will be deleted, "
                 "and a clean one will open."))
    elif fresh:
        print(tr(f"Через пару секунд Claude Code закроется и откроется новая сессия. «{p['title']}» останется в /resume.",
                 f"In a couple of seconds Claude Code will close and a new session will open. "
                 f"\"{p['title']}\" stays in /resume."))
    else:
        print(tr(f"Перезапускаю Claude Code через пару секунд, сессия «{p['title']}» откроется снова в этой вкладке.",
                 f"Restarting Claude Code in a couple of seconds. Session \"{p['title']}\" will reopen in this tab."))
    return 0


def fmt_mb(n):
    unit = tr("МБ", "MB")
    return f"{n / 1048576:.0f} {unit}" if n >= 10 << 20 else f"{n / 1048576:.1f} {unit}"


def slim_current(dry=False, delay=1.5):
    import claude_slim
    pid = find_claude()
    try:
        with open(session_file(pid)) as f:
            sid = json.load(f).get("sessionId")
    except (OSError, ValueError):
        sid = None
    path = session_path(sid) if sid else None
    if not path:
        raise RestartError(tr("не нашёл файл этой сессии", "couldn't find this session's file"))
    tokens = claude_slim.context_tokens(path)
    hint = compact_hint(tokens)
    _, _, st = claude_slim.plan(path)
    if not st:
        return tr("Сжимать нечего: в сессии меньше двух /compact, а последние два отрезка не трогаются.",
                  "Nothing to compact: the session has fewer than two /compact, and the last two parts "
                  "are never touched.") + hint, False
    before, after = st["before"] + st["side_before"], st["after"] + st["side_after"]
    if before - after < SLIM_MIN:
        return tr(f"Сжимать почти нечего: {fmt_mb(before)} → {fmt_mb(after)}. "
                  "Старые скриншоты и выводы уже маленькие.",
                  f"Almost nothing to compact: {fmt_mb(before)} → {fmt_mb(after)}. "
                  "Old screenshots and outputs are already small.") + hint, False
    title = session_title(sid) or sid
    what = tr(f"«{title}»: {fmt_mb(before)} → {fmt_mb(after)} вместе с папкой сессии, "
              f"скриншотов {st['images']}, длинных выводов {st['texts']}",
              f"\"{title}\": {fmt_mb(before)} → {fmt_mb(after)} with the session folder, "
              f"screenshots: {st['images']}, long outputs: {st['texts']}")
    if st["side_files"] or st["side_agents"]:
        what += tr(f", старых файлов {st['side_files']}, переписок субагентов {st['side_agents']}",
                   f", old files: {st['side_files']}, subagent transcripts: {st['side_agents']}")
    if dry:
        return tr(f"Сожму {what}.", f"Would compact {what}.") + hint, False
    restart(update=False, delay=delay, slim=True)
    # «Сжимаю» и «Compacting» в начале проверяет текст /slim из slash.py
    return tr(f"Сжимаю {what}. Claude Code сейчас закроется, сессия сожмётся в этой вкладке и откроется снова; "
              "то, что видит модель, не меняется.",
              f"Compacting {what}. Claude Code is about to close, the session will be compacted in this tab "
              "and reopen. What the model sees doesn't change.") + compact_hint(tokens, later=True), True


def compact_hint(tokens, later=False):
    if not tokens or tokens < COMPACT_HINT:
        return ""
    if later:
        return tr(f" В контексте {tokens // 1000} тыс. токенов, а /slim их не убирает. Чтобы сжать сам разговор, "
                  "набери /compact, когда сессия откроется снова.",
                  f" The context holds {tokens // 1000}k tokens, and /slim doesn't remove them. To compact "
                  "the conversation itself, type /compact once the session reopens.")
    return tr(f" В контексте {tokens // 1000} тыс. токенов, а /slim их не убирает. Чтобы сжать сам разговор, "
              "набери /compact.",
              f" The context holds {tokens // 1000}k tokens, and /slim doesn't remove them. To compact "
              "the conversation itself, type /compact.")


def cli_slim(args):
    import session_slim
    if "-h" in args or "--help" in args:
        print(tr("agentmeister slim            изнутри Claude Code: закрыть его, сжать эту сессию (старые скриншоты и",
                 "agentmeister slim            from inside Claude Code: close it, compact this session (old screenshots and"))
        print(tr("                            длинные выводы до двух последних /compact) и открыть её снова",
                 "                            long outputs before the last two /compact) and reopen it"))
        print(tr("agentmeister slim --dry-run  только посчитать", "agentmeister slim --dry-run  only count"))
        print(tr("agentmeister slim list       что можно сжать среди закрытых сессий",
                 "agentmeister slim list       what can be compacted among closed sessions"))
        print(tr("agentmeister slim <id>       сжать закрытую сессию (вернуть: agentmeister sessions slim <id> --undo)",
                 "agentmeister slim <id>       compact a closed session (undo: agentmeister sessions slim <id> --undo)"))
        print()
        print(tr("Обычно вызывается из Claude: /slim или инструментом slim из MCP-сервера agentmeister.",
                 "Usually called from Claude: /slim or the slim tool of the agentmeister MCP server."))
        return 0
    rest = [a for a in args if a != "--dry-run"]
    if rest[:1] == ["list"]:
        return session_slim.slim_cmd([], True)
    if rest:
        return session_slim.slim_cmd(rest, True)
    try:
        text, _ = slim_current(dry="--dry-run" in args)
    except RestartError as e:
        print(f"agentmeister slim: {e}", file=sys.stderr)
        return 1
    print(text)
    return 0


if __name__ == "__main__":
    # mcp_server и setup_cmd импортируют этот модуль по имени: без этого он загрузился бы второй раз
    sys.modules.setdefault("claude_restart", sys.modules[__name__])
    cmd, rest = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ("restart", [])
    if cmd == "mcp":
        import mcp_server
        mcp_server.mcp()
    elif cmd == "notice":
        sys.exit(notice())
    elif cmd == "session-end":
        sys.exit(session_end())
    elif cmd == "setup":
        import setup_cmd
        sys.exit(setup_cmd.setup(rest))
    elif cmd == "slim":
        sys.exit(cli_slim(rest))
    else:
        sys.exit(cli(rest, forget=cmd == "forget", fresh=cmd == "fresh"))
