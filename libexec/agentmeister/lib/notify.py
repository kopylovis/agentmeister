import contextlib
import filecmp
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import CACHE, HOME, UUID_RE, read_config, settings_name, settings_path, tilde, tr, write_config, write_json
from swiftagent import SwiftAgent
import ntfy_alert
import telegram

AGENT = SwiftAgent("notify", "agentmeister Notify", "com.agentmeister.notify")
# Так приложение называлось, пока было частью mnrh. После сборки нового его удаляем.
OLD_APP = os.path.join(HOME, "Library", "Application Support", "mnrh", "mnrh Notify.app")
OLD_CLAUDE_APP = os.path.join(HOME, "Library", "Application Support", "claudemeister", "claudemeister Notify.app")
STATE = os.path.join(CACHE, "notify")
DEFAULT_AFTER = 20
TERMINALS = {"com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm2"}
# Десктопный Agentmeister: его вкладка кладет свой id в AGENTMEISTER_TAB, а не ищется по tty через ps.
# Приложение пишет в FRONT, какая вкладка выбрана и активно ли окно, и забирает из FOCUS запрос открыть вкладку.
APP_BUNDLE = "com.agentmeister.app"
APP_TAB_ENV = "AGENTMEISTER_TAB"
APP_DIR = os.path.join(CACHE, "app")
APP_FRONT = os.path.join(APP_DIR, "front.json")
APP_FOCUS = os.path.join(APP_DIR, "focus.json")

FOCUS = {
    "Terminal": '''
on run argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is (item 1 of argv) then
          set selected of t to true
          set index of w to 1
          activate
          return "ok"
        end if
      end repeat
    end repeat
  end tell
  return "notfound"
end run''',
    "iTerm2": '''
on run argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if tty of s is (item 1 of argv) then
            select w
            tell t to select
            tell s to select
            activate
            return "ok"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "notfound"
end run''',
}

# Сессия iTerm2 по ее id, а не по tty: в песочнице proxy-сессии ps не запустить, и tty не узнать.
# id приходит в ITERM_SESSION_ID ("w0t3p0:<GUID>"), в словаре AppleScript это свойство id у session.
ITERM_BUNDLE = "com.googlecode.iterm2"
GUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
FOCUS_ITERM_ID = '''
on run argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if id of s is (item 1 of argv) then
            select w
            tell t to select
            tell s to select
            activate
            return "ok"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "notfound"
end run'''
SELECTED_ITERM_ID = 'tell application "iTerm2" to return id of current session of current window'

SELECTED = {
    "Terminal": 'tell application "Terminal" to return tty of selected tab of front window',
    "iTerm2": 'tell application "iTerm2" to return tty of current session of current window',
}


def usage():
    topic = ntfy_alert.CLAUDE_TOPIC
    print(tr("agentmeister notify              уведомления, когда Claude ждёт тебя: состояние",
             "agentmeister notify              notifications when Claude is waiting for you: status"))
    print(tr("agentmeister notify on | off     включить или выключить",
             "agentmeister notify on | off     turn on or off"))
    print(tr(f"agentmeister notify after <сек>  о готовом ответе — только если ход шёл дольше (сейчас "
             f"{after()} с, по умолчанию {DEFAULT_AFTER})",
             f"agentmeister notify after <sec>  notify about a finished reply only if the turn took longer (now "
             f"{after()}s, default {DEFAULT_AFTER})"))
    print(tr("agentmeister notify sound on|off звук", "agentmeister notify sound on|off sound"))
    print(tr("agentmeister notify test        показать пробное уведомление",
             "agentmeister notify test        show a test notification"))
    print(tr("agentmeister notify telegram    ещё и в Telegram, когда ты не за Mac: подключить бота",
             "agentmeister notify telegram    also send to Telegram when you are away from the Mac: connect the bot"))
    print(tr(f"agentmeister notify phone away  ещё и в Tossling на телефон (канал {topic}), когда ты не за Mac",
             f"agentmeister notify phone away  also send to Tossling on the phone (channel {topic}) when you are away from the Mac"))
    print("  … phone always | off | test")
    print(tr("  … telegram test | off | always | away <сек>", "  … telegram test | off | always | away <sec>"))
    print(tr("  … telegram approve on | off  разрешать и отклонять запросы Claude кнопками в Telegram, когда ты не за Mac",
             "  … telegram approve on | off  allow or deny Claude's requests with Telegram buttons when you are away from the Mac"))
    print()
    print(tr("Уведомление приходит, если Claude просит разрешение или задаёт вопрос, долго ждёт ответа\n"
             "или закончил долгий ход, а ты смотришь не на его вкладку. Нажатие переключает на неё\n"
             "(Terminal и iTerm2 — на саму вкладку, в IDE — на окно приложения).\n"
             "Ставит agentmeister setup: хуки UserPromptSubmit, Stop и Notification, для кнопок в Telegram — PermissionRequest.",
             "A notification comes when Claude asks for permission or asks a question, waits a long time for a reply\n"
             "or finishes a long turn while you are not looking at its tab. Clicking it switches to that tab\n"
             "(Terminal and iTerm2 switch to the tab itself, an IDE to the app window).\n"
             "Installed by agentmeister setup: UserPromptSubmit, Stop and Notification hooks, PermissionRequest for Telegram buttons."))


def enabled():
    return read_config().get("notify", "on") != "off"


def after():
    try:
        return max(0, int(read_config().get("notify_after", DEFAULT_AFTER)))
    except ValueError:
        return DEFAULT_AFTER


def sound():
    return read_config().get("notify_sound", "on") != "off"


def install_sound():
    name = "Agentmeister-Prompt.wav"
    source = os.path.join(os.path.dirname(AGENT.src), name)
    directory = os.path.join(HOME, "Library", "Sounds")
    target = os.path.join(directory, name)
    if os.path.isfile(target) and filecmp.cmp(source, target, shallow=False):
        return
    os.makedirs(directory, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=directory) as tmp:
        staged = shutil.copyfile(source, os.path.join(tmp, name))
        os.replace(staged, target)


def ensure_app(background=False):
    """Приложение уведомлений собрано и свежее. setup и notify test собирают сразу. Хук (background=True)
    живет 10 с, swiftc в нем не успеет: сборку он запускает в фоне и сейчас отвечает False."""
    if not os.path.exists(AGENT.src):
        return False
    try:
        if background:
            if AGENT.needs_build():
                start_build()
                return False
        else:
            with contextlib.redirect_stdout(sys.stderr):
                AGENT.build()
    except (SystemExit, OSError) as exc:
        log_error(f"{AGENT.display}: {exc}")
        if background:
            return False
    ok = os.access(AGENT.bin, os.X_OK)
    if ok:
        try:
            install_sound()
        except OSError as exc:
            log_error(f"Prompt: {exc}")
        for legacy in (OLD_APP, OLD_CLAUDE_APP):
            if os.path.isdir(legacy):
                shutil.rmtree(legacy, ignore_errors=True)
        with contextlib.suppress(OSError):
            os.rmdir(os.path.dirname(OLD_CLAUDE_APP))
    return ok


def start_build():
    """Собрать приложение отдельным процессом, который переживет хук."""
    if AGENT.building():
        log_error(f"{AGENT.display} уже собирается, уведомление показал через osascript")
        return False
    if not shutil.which("swiftc"):
        log_error(f"{AGENT.display}: нет swiftc, нужен xcode-select --install; уведомление показал через osascript")
        return False
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "build-app"], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, cwd="/")
    log_error(f"{AGENT.display} собирается в фоне, уведомление показал через osascript")
    return True


FALLBACK = '''
on run argv
  set {t, s, b, snd} to argv
  if snd is "" then
    display notification b with title t subtitle s
  else
    display notification b with title t subtitle s sound name snd
  end if
end run'''


def fallback_post(title, subtitle, body):
    """Уведомление без нашего приложения, пока оно собирается: нажатие не переключит на вкладку."""
    snd = ""
    if sound() and os.path.exists(os.path.join(HOME, "Library", "Sounds", "Agentmeister-Prompt.wav")):
        snd = "Agentmeister-Prompt"
    try:
        r = subprocess.run(["osascript", "-e", FALLBACK, title, subtitle, body, snd],
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"osascript: {exc}"
    return "ok" if r.returncode == 0 else f"osascript: {r.stderr.strip()}"


def launch(args):
    try:
        subprocess.Popen([AGENT.bin, *args], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as exc:
        return f"{AGENT.display}: {exc.strerror}"
    return "ok"


def post(title, subtitle, body, sid, click=None, wait=False):
    args = ["post", "--title", title, "--subtitle", subtitle, "--body", body, "--id", sid]
    if click:
        args += ["--click", click]
    if not sound():
        args += ["--sound", "off"]
    with tempfile.TemporaryDirectory(prefix="agentmeister-notify-") as directory:
        result = os.path.join(directory, "result")
        started = launch(args + ["--result", result])
        if started != "ok":
            return started
        deadline = time.monotonic() + (60 if wait else 3)
        while time.monotonic() < deadline:
            if os.path.exists(result):
                with open(result) as f:
                    return f.read().strip()
            time.sleep(0.1)
        return "timeout"


def osascript(script, *args, timeout=5):
    try:
        r = subprocess.run(["osascript", "-e", script, *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def front_bundle():
    try:
        front = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True, timeout=3).stdout.strip()
        out = subprocess.run(["lsappinfo", "info", "-only", "bundleid", front],
                             capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""
    m = re.search(r'"CFBundleIdentifier"="([^"]*)"', out)
    return m.group(1) if m else ""


def app_tab():
    """id вкладки десктопного Agentmeister, в которой идет эта сессия, или пусто."""
    tab = os.environ.get(APP_TAB_ENV, "").lower()
    return tab if UUID_RE.match(tab) else ""


def iterm_session():
    """"iterm:<GUID>" из ITERM_SESSION_ID, если сессия идет в iTerm2, иначе пусто. Одной переменной мало:
    ITERM_SESSION_ID наследуют и программы, запущенные из iTerm2 в другом терминале или IDE."""
    if os.environ.get("TERM_PROGRAM") != "iTerm.app" and os.environ.get("LC_TERMINAL") != "iTerm2":
        return ""
    guid = os.environ.get("ITERM_SESSION_ID", "").rpartition(":")[2]
    return "iterm:" + guid if GUID_RE.match(guid) else ""


def app_front():
    """Вкладка, которая сейчас выбрана в активном окне Agentmeister, или пусто, если окно не впереди."""
    try:
        with open(APP_FRONT) as f:
            front = json.load(f)
    except (OSError, ValueError):
        return ""
    return str(front.get("tab") or "").lower() if isinstance(front, dict) and front.get("active") else ""


def focus_app(tab, sid=""):
    """Клик по уведомлению из вкладки Agentmeister: запрос в файл, который приложение забирает само, и ссылка
    agentmeister://, которая выводит окно вперед, если приложение собрано в .app. Id сессии нужен, когда вкладки
    с этим id уже нет: приложение найдет вкладку с той же сессией или продолжит ее в новой."""
    if not UUID_RE.match(tab):
        return 1
    sid = sid if UUID_RE.match(sid or "") else ""
    request = {"tab": tab, "at": time.time()}
    if sid:
        request["session"] = sid
    try:
        os.makedirs(APP_DIR, exist_ok=True)
        write_json(APP_FOCUS, request)
    except OSError:
        pass
    url = f"agentmeister://focus?tab={tab}" + (f"&session={sid}" if sid else "")
    if subprocess.run(["open", url], capture_output=True).returncode != 0:
        # ссылка работает, только если LaunchServices знает Agentmeister.app; иначе хотя бы выводим приложение,
        # а запрос оно заберет из focus.json
        subprocess.run(["open", "-b", APP_BUNDLE], capture_output=True)
    return 0


def watching(bundle, tty):
    if bundle == APP_BUNDLE and tty.startswith("app:"):
        return app_front() == tty[4:]
    if not bundle or front_bundle() != bundle:
        return False
    if tty.startswith("iterm:"):
        return osascript(SELECTED_ITERM_ID).lower() == tty[6:].lower()
    term = TERMINALS.get(bundle)
    if not term:
        return True
    return osascript(SELECTED[term]) == tty


def focus(tty, bundle, sid=""):
    if tty.startswith("app:"):
        return focus_app(tty[4:], sid)
    if tty.startswith("iterm:"):
        if GUID_RE.match(tty[6:]) and osascript(FOCUS_ITERM_ID, tty[6:]) == "ok":
            return 0
        subprocess.run(["open", "-b", ITERM_BUNDLE], capture_output=True)
        return 0
    term = TERMINALS.get(bundle)
    if term and tty and osascript(FOCUS[term], tty) == "ok":
        return 0
    if bundle:
        subprocess.run(["open", "-b", bundle], capture_output=True)
    return 0


def state_path(sid):
    return os.path.join(STATE, sid + ".json")


def load_state(sid):
    try:
        with open(state_path(sid)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(sid, st):
    os.makedirs(STATE, exist_ok=True)
    write_json(state_path(sid), st)


def prune_states():
    cutoff = time.time() - 7 * 86400
    for name in os.listdir(STATE) if os.path.isdir(STATE) else []:
        p = os.path.join(STATE, name)
        with contextlib.suppress(OSError):
            if os.path.getmtime(p) < cutoff:
                os.remove(p)


def plain(text, n=180):
    text = re.sub(r"```.*?```", " ", text or "", flags=re.S)
    text = re.sub(r"[*_`#>|]+", "", text)
    text = " ".join(text.split())
    return text if len(text) <= n else text[: n - 1] + "…"


def own_terminal():
    from claude_proc import RestartError, find_claude, ps
    try:
        pid = find_claude()
    except RestartError:
        return None
    tty = ps("tty", pid)
    if not tty or "?" in tty:
        return None
    return "/dev/" + tty if not tty.startswith("/dev/") else tty


def session_title(sid, path):
    import claude_search
    if not path or not os.path.isfile(path):
        return ""
    data = claude_search.update(sid, path)
    t = claude_search.title(sid, data) if data else ""
    return "" if t == "без названия" else t


def codex_terminal(sid):
    try:
        processes = subprocess.check_output(["/bin/ps", "-axo", "tty=,args="], text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return None
    for line in processes.splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3:
            tty, executable, args = fields
            if "?" not in tty and os.path.basename(executable) == "codex" and sid in args.split():
                return f"/dev/{tty}"
    return None


def codex_cli_session(path):
    if not isinstance(path, str) or not os.path.isfile(path):
        return False
    try:
        with open(path, "rb") as f:
            entry = json.loads(f.readline(1 << 20))
        meta = entry["payload"]
        return entry.get("type") == "session_meta" and (
            meta.get("originator") == "codex-tui" or meta.get("source") == "cli")
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return False


def message_for(payload, st, codex=False):
    event = payload.get("hook_event_name")
    if event == "Stop":
        started = st.get("prompt_at")
        if not started or time.time() - started < after():
            return None
        took = int(time.time() - started)
        m, sec = divmod(took, 60)
        took = tr(f"{m} мин {sec} с", f"{m}m {sec}s") if took >= 60 else tr(f"{took} с", f"{took}s")
        return (tr(f"Готово за {took}", f"Done in {took}"),
                plain(payload.get("last_assistant_message")) or tr("Ход закончен", "Turn finished"))
    if codex and event == "PermissionRequest":
        return (tr("Нужно разрешение", "Permission needed"),
                plain(payload.get("tool_name")) or tr("Codex ждет разрешения", "Codex is waiting for permission"))
    if event != "Notification":
        return None
    kind, msg = payload.get("notification_type"), payload.get("message") or ""
    if kind == "permission_prompt":
        m = re.search(r"permission to use (.+?)\.?$", msg)
        return tr("Нужно разрешение", "Permission needed"), (m.group(1) if m else plain(msg))
    if kind in ("elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"):
        return tr("Нужен ответ", "Answer needed"), plain(msg) or tr("Claude задаёт вопрос", "Claude has a question")
    if kind == "idle_prompt" and not st.get("notified"):
        return (tr("Ждёт тебя", "Waiting for you"),
                plain(st.get("last") or "") or tr("Claude ждёт ответа", "Claude is waiting for your reply"))
    return None


# Запросы, о которых Remote Control сам присылает push в приложение Claude, если в /config включено
# «Push when actions required» (inputNeededNotifEnabled): запрос разрешения и вопрос, ждущий ответа.
NATIVE_PUSH = {"permission_prompt", "elicitation_dialog", "elicitation_url_dialog"}


def native_push(payload):
    """Claude Code сам пришлет push на телефон об этом событии: сессия сейчас подключена к Remote Control
    (CLAUDE_CODE_BRIDGE_SESSION_ID есть в окружении хука) и включен push о запросах. Тогда наш push лишний."""
    if not os.environ.get("CLAUDE_CODE_BRIDGE_SESSION_ID"):
        return False
    if payload.get("hook_event_name") != "Notification" or payload.get("notification_type") not in NATIVE_PUSH:
        return False
    import claude_settings
    return claude_settings.setting("inputNeededNotifEnabled", payload.get("cwd")) is True


def approval_pending(payload, sid):
    """Запрос разрешения уже ушел в Telegram с кнопками (approve-hook): второе сообщение о нем там не нужно."""
    if payload.get("notification_type") != "permission_prompt":
        return False
    import telegram_approve
    return telegram_approve.pending_for(sid)


def hook(codex=False):
    # claude -p, который запускает /ask: он отвечает другому Claude, а не человеку, уведомлять не о чем
    if os.environ.get("MNRH_CHILD") == "1":
        return 0
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0
    sid = payload.get("session_id") or ""
    if not isinstance(sid, str) or not UUID_RE.fullmatch(sid):
        return 0
    if not codex:
        # заметки Heads up от Claude Code: снять новые, пока помним, чья это сессия (agentmeister headsup)
        try:
            import headsup
            headsup.from_hook(payload)
        except Exception:
            pass
    if not enabled():
        return 0
    st = load_state(sid)
    event = payload.get("hook_event_name")
    if event == "UserPromptSubmit":
        had = st.get("notified")
        save_state(sid, {"prompt_at": time.time()})
        if had and os.path.exists(AGENT.bin):
            launch(["remove", "--id", sid])
        prune_states()
        return 0
    if event == "Stop" and not codex and payload.get("last_assistant_message"):
        st["last"] = payload["last_assistant_message"][:2000]
        save_state(sid, st)
    what = message_for(payload, st, codex)
    if not what:
        return 0
    tab = app_tab()
    tty = "app:" + tab if tab else codex_terminal(sid) if codex else own_terminal()
    transcript = payload.get("transcript_path")
    if not tty:
        # без tty это может быть codex exec или claude -p: уведомляем только об интерактивной сессии
        from claude_proc import interactive_session
        if not (codex_cli_session(transcript) if codex else interactive_session(sid)):
            return 0
        # в песочнице proxy ps не работает и tty пустой: сессию iTerm2 узнаем по ее id из окружения
        tty = iterm_session()
    bundle = os.environ.get("__CFBundleIdentifier", "")
    if tab:
        bundle = APP_BUNDLE
    elif tty.startswith("iterm:"):
        bundle = ITERM_BUNDLE
    elif codex and tty and bundle not in TERMINALS:
        front = front_bundle()
        bundle = front if front in TERMINALS else ""
    native = native_push(payload)
    to_phone = not native and telegram.wanted() and not approval_pending(payload, sid)
    phone_mode = ntfy_alert.phone_mode()
    to_tossling = not native and ntfy_alert.configured() and (
        phone_mode == "always" or (phone_mode == "away" and telegram.away()))
    on_mac = not tty or not watching(bundle, tty)
    if not on_mac and not to_phone and not to_tossling:
        return 0
    head, body = what
    cwd = payload.get("cwd") or ""
    project = "~" if cwd.rstrip("/") == HOME else os.path.basename(cwd.rstrip("/")) or ("Codex" if codex else "Claude")
    title = "" if codex else session_title(sid, transcript)
    sent = False
    if on_mac:
        if ensure_app(background=True):
            cm = cm_path()
            click = f"{shlex.quote(cm)} focus {shlex.quote(tty)} {shlex.quote(bundle)}" if cm and tty and bundle else None
            if click and tab:
                click += f" {shlex.quote(sid)}"
            result = post(f"{project}: {head}", title, body, sid, click)
        else:
            result = fallback_post(f"{project}: {head}", title, body)
        sent = result == "ok"
        if not sent:
            log_error(result)
    if to_phone:
        try:
            telegram.send(f"{project}: {head}", title, body)
            sent = True
        except telegram.TelegramError as e:
            log_error(f"telegram: {e}")
    if to_tossling:
        try:
            ntfy_alert.publish(ntfy_alert.CLAUDE_TOPIC, "\n\n".join(p for p in (title, body) if p),
                               title=f"{project}: {head}", priority=3 if payload.get("hook_event_name") == "Stop" else 4)
            sent = True
        except ntfy_alert.AlertError as e:
            log_error(f"tossling: {e}")
    current = load_state(sid) if codex else st
    if sent and current.get("prompt_at") == st.get("prompt_at"):
        current["notified"] = True
        save_state(sid, current)
    return 0


def log_error(text):
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, "errors.log"), "a") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {text}\n")


def cm_path():
    from mnrhlib import CM
    return CM if os.access(CM, os.X_OK) else None


def status():
    on = enabled()
    print(f"Уведомления: {'включены' if on else 'выключены'}; о готовом ответе — если ход дольше {after()} с; "
          f"звук {'есть' if sound() else 'выключен'}")
    print(f"Приложение: {tilde(AGENT.app)}" + ("" if os.path.exists(AGENT.bin) else " (соберётся при первом уведомлении)"))
    import claude_settings
    rows = claude_settings.rows("notify-hook")
    try:
        lost = claude_settings.missing(claude_settings.load(), rows)
    except (OSError, ValueError):
        lost = rows
    have = [r[0] for r in rows if r not in lost]
    print("Хуки Claude Code: " + (", ".join(have) if have else "не стоят — agentmeister setup"))
    from codex_harness import NOTIFY_EVENTS, configured_hooks
    count = configured_hooks("notify-hook")
    print(f"Хуки Codex, настроено {count if count is not None else '?'} из {len(NOTIFY_EVENTS)}. "
          "Проверь доверие в /hooks или запусти agentmeister --harness codex setup.")
    print(telegram.describe())
    if telegram.configured():
        import telegram_approve
        print(telegram_approve.describe())
    if claude_settings.setting("inputNeededNotifEnabled", os.getcwd()) is True:
        print("Remote Control: в сессии с /remote-control о запросах разрешения и вопросах на телефон пишет сам "
              "Claude (Push when actions required), в Telegram и Tossling они не дублируются")
    mode = ntfy_alert.phone_mode()
    print("Tossling: " + {"off": "выключено — agentmeister notify phone away",
                       "away": f"когда ты не за Mac, канал «{ntfy_alert.CLAUDE_TOPIC}»",
                       "always": f"всегда, канал «{ntfy_alert.CLAUDE_TOPIC}»"}[mode])


def test():
    if not ensure_app():
        print("Не собрал приложение уведомлений: нужен swiftc из Xcode Command Line Tools")
        return 1
    tty = os.ttyname(0) if os.isatty(0) else ""
    bundle = os.environ.get("__CFBundleIdentifier", "")
    cm = cm_path()
    click = f"{shlex.quote(cm)} focus {shlex.quote(tty)} {shlex.quote(bundle)}" if cm and tty else None
    print("Отправляю пробное уведомление. В первый раз macOS спросит, можно ли agentmeister Notify их показывать — разреши.")
    r = post("agentmeister: пробное уведомление", "Claude Code", "Нажми, чтобы вернуться в эту вкладку",
             "00000000-0000-0000-0000-000000000000", click, wait=True)
    if r == "ok":
        print("Центр уведомлений macOS принял уведомление.")
        return 0
    if r.startswith("denied"):
        print(f"✗ macOS не разрешает уведомления: {settings_path('settings', 'notifications')} → agentmeister Notify → "
              f"{settings_name('allow')}")
    else:
        print(f"✗ не получилось: {r}")
    return 1


def phone(rest):
    value = rest[0] if rest else ""
    if value in ("on", "away", "always", "off"):
        if value != "off" and not ntfy_alert.configured():
            print("Сначала tossling setup: уведомления уходят через сервер Tossling")
            return 1
        write_config(notify_phone="away" if value == "on" else value)
        print({"off": "В Tossling больше не отправляю",
               "always": f"Отправляю в Tossling всегда, канал «{ntfy_alert.CLAUDE_TOPIC}»"}.get(
            value, f"Отправляю в Tossling, когда ты не за Mac, канал «{ntfy_alert.CLAUDE_TOPIC}»"))
        print(f"На телефоне: Tossling → Уведомления → + → канал {ntfy_alert.CLAUDE_TOPIC}")
        return 0
    if value == "test":
        try:
            ntfy_alert.publish(ntfy_alert.CLAUDE_TOPIC, "Так будут приходить вопросы и ответы Claude Code.",
                               title="Claude Code: проверка")
        except ntfy_alert.AlertError as e:
            print(f"Не отправил: {e}")
            return 1
        print("Отправил пробное уведомление")
        return 0
    print(f"В Tossling: {ntfy_alert.phone_mode()}. agentmeister notify phone away | always | off | test")
    return 0


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else ""
    if cmd == "notify-hook":
        return hook(codex=args[1:] == ["--codex"])
    if cmd == "build-app":  # фоновая сборка из хука
        return 0 if ensure_app() else 1
    if cmd == "focus":
        return focus(args[1] if len(args) > 1 else "", args[2] if len(args) > 2 else "",
                     args[3] if len(args) > 3 else "")
    rest = args[1:]
    if not rest or rest[0] in ("status",):
        status()
        return 0
    if rest[0] in ("-h", "--help"):
        usage()
        return 0
    if rest[0] in ("on", "off"):
        write_config(notify=rest[0])
        print(f"Уведомления {'включены' if rest[0] == 'on' else 'выключены'}")
        return 0
    if rest[0] == "sound" and len(rest) == 2 and rest[1] in ("on", "off"):
        write_config(notify_sound=rest[1])
        print(f"Звук {'включён' if rest[1] == 'on' else 'выключен'}")
        return 0
    if rest[0] == "after" and len(rest) == 2 and rest[1].isdigit():
        write_config(notify_after=rest[1])
        print(f"О готовом ответе — если ход шёл дольше {rest[1]} с")
        return 0
    if rest[0] == "test":
        return test()
    if rest[0] == "telegram":
        return telegram.main(rest[1:])
    if rest[0] == "phone":
        return phone(rest[1:])
    usage()
    return 2


if __name__ == "__main__":
    sys.exit(main())
