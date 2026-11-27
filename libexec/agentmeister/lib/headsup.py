"""История заметок Heads up и You should know из Claude Code.

Их показывает встроенный плагин you-should-know@builtin. Закрытую карточку больше не открыть, а сам плагин хранит
только заголовки последних 50 в ~/.claude/plugins/store/cc-plugin-you-should-know_builtin-<хеш>.json (seen), без
времени, сессии и текста пояснения. Мы этот файл только читаем: сравниваем его seen с прошлым снимком и новые
заголовки дописываем в свою историю со временем, сессией и папкой проекта.

Снимает хук notify-hook на UserPromptSubmit и Stop (сессия та, чей хук сработал, если плагин не показал, что
заметку получила другая), а agentmeister headsup и окно настроек сначала досматривают то, что хуки пропустили.
"""
import fcntl
import glob
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mnrhlib  # noqa: E402
from mnrhlib import CLAUDE_HOME, HOME, UUID_RE, tilde, tr  # noqa: E402

STORE_GLOB = os.path.join(CLAUDE_HOME, "plugins", "store", "cc-plugin-you-should-know_builtin-*.json")
# не в ~/.cache/mnrh: историю не должна стереть уборка кеша
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), "mnrh")
HISTORY = os.path.join(STATE, "headsup.jsonl")
# прошлый снимок файла плагина: размер и время, seen и offeredTurn сессий
MARK = os.path.join(STATE, "headsup-mark.json")
LOCK = os.path.join(STATE, "headsup.lock")
MAX_ENTRIES = 500
MAX_HEADLINE = 2000


def store_path():
    """Файл плагина; если их несколько (сменился хеш), самый свежий."""
    best, best_mtime = None, -1.0
    for path in glob.glob(STORE_GLOB):
        try:
            mtime = os.stat(path).st_mtime
        except OSError:
            continue
        if mtime > best_mtime:
            best, best_mtime = path, mtime
    return best


def _load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _strings(items):
    return [x for x in items if isinstance(x, str) and x.strip()] if isinstance(items, list) else []


def offered(store):
    """{id сессии: offeredTurn} по sessions плагина: у сессии, которой заметку показали, offeredTurn новый."""
    out = {}
    for s in store.get("sessions") or []:
        if isinstance(s, dict) and isinstance(s.get("id"), str) and isinstance(s.get("offeredTurn"), str):
            out[s["id"]] = s["offeredTurn"]
    return out


def tags(store):
    return {s["id"]: s["tag"] for s in store.get("sessions") or []
            if isinstance(s, dict) and isinstance(s.get("id"), str) and isinstance(s.get("tag"), str)}


def new_items(prev, cur):
    """Что дописано в seen после prev. Плагин дописывает в конец и срезает начало, повторно показанная заметка уходит
    в конец. Самое длинное начало cur, которое по порядку есть в prev, старое, все после него новое."""
    i = j = 0
    while i < len(cur):
        while j < len(prev) and prev[j] != cur[i]:
            j += 1
        if j == len(prev):
            break
        i += 1
        j += 1
    return cur[i:]


def read_history(path=None):
    out = []
    try:
        with open(path or HISTORY, encoding="utf-8") as f:
            for line in f:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and isinstance(row.get("headline"), str):
                    out.append(row)
    except OSError:
        pass
    return out


def write_history(rows):
    os.makedirs(STATE, exist_ok=True)
    rows = rows[-MAX_ENTRIES:]
    tmp = f"{HISTORY}.{os.getpid()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            for row in rows:
                f.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, HISTORY)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def session_cwd(sid):
    """Папка сессии по ее переписке: поле cwd в первых строках."""
    if not UUID_RE.fullmatch(sid or ""):
        return None
    for path in glob.glob(os.path.join(glob.escape(CLAUDE_HOME), "projects", "*", sid + ".jsonl")):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                for _ in range(50):
                    line = f.readline()
                    if not line:
                        break
                    if '"cwd"' in line:
                        try:
                            cwd = json.loads(line).get("cwd")
                        except (ValueError, AttributeError):
                            continue
                        if isinstance(cwd, str) and cwd:
                            return cwd
        except OSError:
            continue
    return None


def capture(sid=None, cwd=None, now=None):
    """Сверить файл плагина с прошлым снимком и дописать новые заголовки. Возвращает, сколько дописано.
    Без изменений в файле плагина это stat и чтение маленького снимка."""
    path = store_path()
    if not path:
        return 0
    try:
        st = os.stat(path)
    except OSError:
        return 0
    mark = _load_json(MARK)
    stamp = [path, st.st_mtime_ns, st.st_size]
    if mark and mark.get("stamp") == stamp:
        return 0
    os.makedirs(STATE, exist_ok=True)
    with open(os.open(LOCK, os.O_WRONLY | os.O_CREAT, 0o600), "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return 0  # снимает другой хук; что он не увидит, заберет следующий
        mark = _load_json(MARK)  # пока ждали, снимок мог обновиться
        if mark and mark.get("stamp") == stamp:
            return 0
        store = _load_json(path)
        if store is None:
            return 0  # плагин как раз пишет файл
        cur = _strings(store.get("seen"))
        now_offered = offered(store)
        rows = read_history()
        added = 0
        if mark is None:
            # первый раз: заголовки, что уже лежат у плагина, без времени, их порядок известен
            have = {r["headline"] for r in rows}
            for h in cur:
                if h not in have:
                    rows.append({"ts": None, "headline": h[:MAX_HEADLINE], "session": None, "cwd": None,
                                 "tag": None, "source": "import"})
                    have.add(h)
                    added += 1
        else:
            fresh = new_items(_strings(mark.get("seen")), cur)
            if fresh:
                prev_offered = mark.get("offered") if isinstance(mark.get("offered"), dict) else {}
                changed = [k for k, v in now_offered.items() if prev_offered.get(k) != v]
                who, where = (sid, cwd) if sid else (None, None)
                if not (sid and sid in changed) and len(changed) == 1:
                    # плагин отметил другую сессию: заметка пришла туда, а хук сработал раньше у этой
                    who = changed[0]
                    where = cwd if who == sid else session_cwd(who)
                tag = tags(store).get(who) if who else None
                ts = time.time() if now is None else now
                for h in fresh:
                    h = h[:MAX_HEADLINE]
                    old = [r for r in rows if r["headline"] == h]
                    rows = [r for r in rows if r["headline"] != h]
                    row = {"ts": ts, "headline": h, "session": who, "cwd": where, "tag": tag,
                           "source": "hook" if sid else "scan"}
                    if old:
                        row["times"] = sum(int(r.get("times") or 1) for r in old) + 1
                    rows.append(row)
                    added += 1
        if added:
            write_history(rows)
        mnrhlib.write_json(MARK, {"stamp": stamp, "seen": cur, "offered": now_offered}, mode=0o600,
                           ensure_ascii=False, separators=(",", ":"))
        return added


def from_hook(payload):
    """Из notify-hook: никогда не падает, хук от этого не должен ломаться."""
    try:
        if not isinstance(payload, dict) or payload.get("hook_event_name") not in ("UserPromptSubmit", "Stop"):
            return 0
        sid = payload.get("session_id")
        sid = sid if isinstance(sid, str) and UUID_RE.fullmatch(sid) else None
        cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None
        return capture(sid, cwd or None)
    except Exception:
        return 0


def scan():
    """Досмотреть то, что хуки пропустили: эти записи без сессии, если плагин не отметил ее сам."""
    try:
        return capture()
    except Exception:
        return 0


def forget(sid):
    """/forget удаляет сессию без следа: и ее заметки из истории."""
    if not UUID_RE.fullmatch(sid or ""):
        return
    rows = read_history()
    kept = [r for r in rows if r.get("session") != sid]
    if len(kept) != len(rows):
        write_history(kept)


def project_of(cwd):
    if not cwd:
        return None
    cwd = cwd.rstrip("/") or "/"
    return "~" if cwd == HOME else os.path.basename(cwd)


def entries(limit=None):
    """История новыми первыми, с project для показа."""
    rows = read_history()[::-1]
    if limit:
        rows = rows[:limit]
    for r in rows:
        r["project"] = project_of(r.get("cwd"))
    return rows


def when(ts):
    if not isinstance(ts, (int, float)):
        return tr("раньше", "earlier")
    t = time.localtime(ts)
    return time.strftime("%d.%m %H:%M" if t.tm_year == time.localtime().tm_year else "%d.%m.%Y", t)


def usage():
    print(tr("agentmeister headsup            заметки Heads up и You should know от Claude Code, новые первыми\n"
             "agentmeister headsup -n <N>     последние N (по умолчанию 20), --all все\n"
             "agentmeister headsup --json     то же в JSON\n"
             "\n"
             "Плагин Claude Code хранит только заголовки 50 последних заметок, без времени и пояснения.\n"
             "agentmeister записывает их сам, когда срабатывает хук notify-hook (agentmeister setup), и\n"
             f"хранит до {MAX_ENTRIES} в {tilde(HISTORY)}. Текст пояснения из карточки не сохраняется нигде.",
             "agentmeister headsup            Claude Code Heads up and You should know notes, newest first\n"
             "agentmeister headsup -n <N>     last N (20 by default), --all for all\n"
             "agentmeister headsup --json     the same as JSON\n"
             "\n"
             "The Claude Code plugin keeps only the headlines of the last 50 notes, with no time or explanation.\n"
             "agentmeister records them itself when the notify-hook fires (agentmeister setup) and\n"
             f"keeps up to {MAX_ENTRIES} in {tilde(HISTORY)}. The explanation text of the card is not saved anywhere."))


def main(argv):
    limit, as_json = 20, False
    args = list(argv)
    while args:
        a = args.pop(0)
        if a in ("-h", "--help", "help"):
            usage()
            return 0
        if a == "--json":
            as_json = True
        elif a == "--all":
            limit = None
        elif a == "-n" and args and args[0].isdigit():
            limit = int(args.pop(0)) or None
        else:
            print(tr(f"agentmeister headsup: не знаю {a}", f"agentmeister headsup: unknown argument {a}"), file=sys.stderr)
            return 2
    scan()
    rows = entries(limit)
    if as_json:
        json.dump(rows, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0
    if not rows:
        print(tr("Заметок пока нет." if store_path() else "Заметок нет: плагин you-should-know в Claude Code еще "
                 "ничего не показывал.",
                 "No notes yet." if store_path() else "No notes: the Claude Code you-should-know plugin has not "
                 "shown anything yet."))
        return 0
    for r in rows:
        place = r.get("project") or "-"
        print(f"{when(r.get('ts')):<11}  {place}")
        print(f"  {r['headline']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
