"""Сессии Claude Code на диске (~/.claude/projects): поиск, чтение, перенос cwd, удаление без следа.

Без меню и вывода: это нужно и хукам (уборка пустых сессий, /forget), и командам agentmeister sessions.
"""
import glob
import json
import os
import re
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import CACHE, CLAUDE_HOME, DEV, HOME, UUID_RE, tilde, tr  # noqa: E402
import claude_search  # noqa: E402

CLAUDE = CLAUDE_HOME
PROJECTS = os.path.join(CLAUDE, "projects")
UUID = UUID_RE
# что agentmeister хранит про сессию сам: резервные копии slim, последний ответ для уведомлений, humanize, guard,
# полные логи сборок (agentmeister buildlog)
SESSION_CACHES = [os.path.join(CACHE, sub, "{sid}" + tail) for sub, tail in
                  (("slim-backup", ".*.jsonl.gz"), ("notify", ".json"), ("humanize", ".*"), ("guard", ".json"),
                   ("notice", ".json"), ("logs", "/*.log"))]


def encode(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def decode(name, base="/"):
    if not name.startswith("-"):
        return None
    rest = name[1:]
    if not rest:
        return base
    try:
        entries = os.listdir(base)
    except OSError:
        return None
    for e in sorted(entries, key=len, reverse=True):
        enc = encode(e)
        if rest == enc or rest.startswith(enc + "-"):
            full = os.path.join(base, e)
            if not os.path.isdir(full):
                continue
            if rest == enc:
                return full
            found = decode(rest[len(enc):], full)
            if found:
                return found
    return None


def tree_size(path):
    if os.path.islink(path) or not os.path.exists(path):
        return 0
    if not os.path.isdir(path):
        return os.lstat(path).st_size
    total = 0
    for root, dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    return total


def fmt_size(n):
    if n >= 1 << 30:
        return f"{n / (1 << 30):.1f} " + tr("ГБ", "GB")
    if n >= 10 << 20:
        return f"{n / (1 << 20):.0f} " + tr("МБ", "MB")
    if n >= 1 << 20:
        return f"{n / (1 << 20):.1f} " + tr("МБ", "MB")
    return f"{max(1, n // 1024)} " + tr("КБ", "KB") if n else "0"


def ago(ts):
    s = time.time() - ts
    if s < 3600:
        return f"{max(1, int(s // 60))} " + tr("мин назад", "min ago")
    if s < 86400:
        return f"{int(s // 3600)} " + tr("ч назад", "h ago")
    if s < 30 * 86400:
        return f"{int(s // 86400)} " + tr("дн назад", "d ago")
    return time.strftime("%d.%m.%Y", time.localtime(ts))


def clip(text, n):
    text = " ".join(str(text).split())
    return text if len(text) <= n else text[: n - 1] + "…"


def folder(cwd):
    if cwd.startswith(DEV + "/") and "/" not in cwd[len(DEV) + 1:]:
        return cwd[len(DEV) + 1:]
    return tilde(cwd)


def running_ids():
    ids = {}
    d = os.path.join(CLAUDE, "sessions")
    try:
        names = os.listdir(d)
    except OSError:
        return ids
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, n)) as f:
                o = json.load(f)
            pid = int(o.get("pid") or 0)
            if pid <= 0:
                continue
            try:
                os.kill(pid, 0)
            except PermissionError:
                pass
            ids[o["sessionId"]] = pid
        except (OSError, ValueError, KeyError, TypeError, ProcessLookupError):
            pass
    return ids


def read_meta(path):
    meta = {"cwd": None, "branch": None, "custom": None, "ai": None, "prompt": None, "answered": False}
    titles = {"custom-title": ("custom", "customTitle"), "ai-title": ("ai", "aiTitle"),
              "last-prompt": ("prompt", "lastPrompt")}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    record = json.loads(line)
                except ValueError:
                    record = None
                if not isinstance(record, dict):
                    if not meta["answered"]:
                        meta["answered"] = None
                    continue
                kind = record.get("type")
                if kind == "assistant":
                    meta["answered"] = True
                if meta["cwd"] is None and record.get("cwd"):
                    meta["cwd"] = record["cwd"]
                    meta["branch"] = record.get("gitBranch")
                if isinstance(kind, str) and kind in titles:
                    key, field = titles[kind]
                    if record.get(field):
                        meta[key] = record[field]
    except (OSError, UnicodeError):
        meta["answered"] = None
    return meta


LOCAL_MARKERS = ("<command-name>", "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>")


def is_junk(path):
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                record = json.loads(line)
                if not isinstance(record, dict) or not isinstance(record.get("type"), str):
                    return False
                if record["type"] == "assistant":
                    return False
                if record["type"] != "user" or record.get("isMeta"):
                    continue
                message = record.get("message")
                content = message.get("content") if isinstance(message, dict) else None
                if isinstance(content, str):
                    texts = [content]
                elif isinstance(content, list) and all(isinstance(b, dict) and b.get("type") == "text" for b in content):
                    texts = [b.get("text") for b in content]
                else:
                    return False
                if not texts or not all(isinstance(t, str) and t.lstrip().startswith(LOCAL_MARKERS) for t in texts):
                    return False
    except (OSError, ValueError):
        return False
    return True


_DECODE = object()


def entry(path, running=None, home=_DECODE, meta=True):
    """Сессия по пути к ее .jsonl, в том виде, как ее отдает load(). home: папка проекта, если уже известна.
    meta=False не читает сам файл: cwd берется по имени папки, title, branch и answered пустые."""
    pdir, name = os.path.split(path)
    d, sid = os.path.basename(pdir), name[:-6]
    if home is _DECODE:
        home = decode(d)
    link = os.path.islink(path)
    m = read_meta(path) if meta else {"cwd": None, "branch": None, "custom": None, "ai": None, "prompt": None,
                                      "answered": False}
    extra = os.path.join(pdir, sid)
    custom = m["custom"]
    if meta:
        try:
            with open(os.path.join(extra, "custom-title.json")) as fh:
                custom = json.load(fh).get("customTitle") or custom
        except (OSError, ValueError, AttributeError):
            pass
    return {
        "id": sid, "pdir": pdir, "path": path, "extra": extra, "link": link,
        "target": os.path.realpath(path) if link else None,
        "cwd": home or m["cwd"] or d, "started_in": m["cwd"], "branch": m["branch"],
        "title": custom or m["ai"] or m["prompt"] or "",
        "prompt": m["prompt"], "answered": m["answered"],
        "size": 0 if link else os.lstat(path).st_size + tree_size(extra),
        "mtime": os.stat(path).st_mtime,
        "running": (running or {}).get(sid),
    }


def load():
    running = running_ids()
    out = []
    try:
        dirs = sorted(os.listdir(PROJECTS))
    except OSError:
        return out
    for d in dirs:
        pdir = os.path.join(PROJECTS, d)
        if not os.path.isdir(pdir):
            continue
        home = decode(d)
        for f in os.listdir(pdir):
            path = os.path.join(pdir, f)
            if not f.endswith(".jsonl") or not UUID.match(f[:-6]) or not os.path.exists(path):
                continue
            out.append(entry(path, running, home))
    out.sort(key=lambda s: s["mtime"], reverse=True)
    return out


def by_id(sid, meta=True):
    """Сессии с этим id (обычно одна) без чтения остальных, новые первыми. Пусто, если id не UUID."""
    if not UUID.match(sid or ""):
        return []
    running = running_ids()
    out = []
    for path in glob.glob(os.path.join(glob.escape(PROJECTS), "*", sid + ".jsonl")):
        try:
            out.append(entry(path, running, meta=meta))
        except OSError:  # битая ссылка или файл только что удалили
            pass
    out.sort(key=lambda s: s["mtime"], reverse=True)
    return out


def find(ss, prefix):
    hits = [s for s in ss if s["id"].startswith(prefix.lower())]
    if not hits:
        hits = [s for s in ss if s["title"] == prefix]
    if len(hits) == 1:
        return hits[0]
    if hits:
        sys.exit(f"agentmeister sessions: «{prefix}» подходит к {len(hits)} сессиям, дай больше символов id")
    sys.exit(f"agentmeister sessions: сессии «{prefix}» нет")


def fast_session(sid):
    for path in glob.glob(os.path.join(glob.escape(PROJECTS), "*", sid + ".jsonl")):
        pdir = os.path.dirname(path)
        data = claude_search.update(sid, path) if not os.path.islink(path) else None
        title = claude_search.title(sid, data) if data else ""
        return {"id": sid, "path": path, "link": os.path.islink(path), "running": running_ids().get(sid),
                "title": "" if title == "без названия" else title,
                "cwd": decode(os.path.basename(pdir)) or (data or {}).get("cwd") or HOME}
    return None


def dump(o):
    text = json.dumps(o, ensure_ascii=False, separators=(",", ":"))
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        text = json.dumps(o, separators=(",", ":"))
    return text


def rewrite(src, dst, olds, new):
    tmp = dst + ".mnrh-tmp"
    changed = 0
    with open(src, encoding="utf-8", errors="surrogateescape", newline="") as fi, \
            open(tmp, "w", encoding="utf-8", errors="surrogateescape", newline="") as fo:
        for line in fi:
            if '"cwd"' in line:
                try:
                    o = json.loads(line)
                except ValueError:
                    o = None
                if isinstance(o, dict) and o.get("cwd") in olds:
                    o["cwd"] = new
                    line = dump(o) + ("\n" if line.endswith("\n") else "")
                    changed += 1
            fo.write(line)
    shutil.copystat(src, tmp)
    os.replace(tmp, dst)
    return changed


def remove_if_empty(pdir):
    try:
        if not os.listdir(pdir):
            os.rmdir(pdir)
    except OSError:
        pass


class SessionInUse(SystemExit):
    pass


def require_idle(s):
    if s["id"] in running_ids():
        raise SessionInUse("Сессия открыта в другом окне. Сначала закрой ее.")


def delete(s):
    require_idle(s)
    for p in (s["path"], s["extra"]):
        if os.path.islink(p) or os.path.isfile(p):
            os.remove(p)
        elif os.path.isdir(p):
            shutil.rmtree(p)
    remove_if_empty(s["pdir"])
    if any(not copy["link"] for copy in by_id(s["id"], meta=False)):
        return
    if not s["link"]:
        for sub in ("file-history", "session-env"):
            p = os.path.join(CLAUDE, sub, s["id"])
            if os.path.isdir(p) and not os.path.islink(p):
                shutil.rmtree(p)
        forget_history(s["id"])
        forget_caches(s["id"])
    claude_search.drop(s["id"])
    import claude_usage
    claude_usage.drop(s["id"])


def forget_caches(sid):
    """Удалить без следа значит и наши копии: в бэкапе slim весь разговор, в notify последний ответ."""
    if not UUID.match(sid):
        return
    for pattern in SESSION_CACHES:
        for p in glob.glob(pattern.format(sid=sid)):
            try:
                os.remove(p)
            except OSError:
                pass


def forget_history(sid):
    path = os.path.join(CLAUDE, "history.jsonl")
    for _ in range(3):
        try:
            size = os.stat(path).st_size
        except OSError:
            return
        with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
            lines = f.readlines()
        kept = [l for l in lines if f'"sessionId":"{sid}"' not in l]
        if len(kept) == len(lines):
            return
        tmp = path + ".mnrh-tmp"
        with open(tmp, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
            f.writelines(kept)
        shutil.copymode(path, tmp)
        if os.stat(path).st_size != size:
            os.remove(tmp)
            continue
        os.replace(tmp, path)
        return


def offline(home, encoded):
    """Папка на внешнем диске, который сейчас не подключен: проект, скорее всего, жив, удалять нельзя."""
    if home and home.startswith("/Volumes/"):
        volume = "/".join(home.split("/")[:3])
        return not (os.path.ismount(volume) or os.path.islink(volume))  # Macintosh HD — ссылка на /
    return home is None and encoded.startswith("-Volumes-")
