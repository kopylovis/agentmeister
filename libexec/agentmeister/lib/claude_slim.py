import glob
import gzip
import hashlib
import json
import os
import re
import shutil
import tarfile
import time
import uuid

from mnrhlib import CACHE, tilde, tr

BACKUPS = os.path.join(CACHE, "slim-backup")
BACKUP_DAYS = 14
TEXT_LIMIT = 8000
HEAD, TAIL = 3000, 1500
PIXEL = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
MARK = "mnrh slim"


class SlimError(Exception):
    pass


def kb(n):
    return (f"{n / 1048576:.1f} " + tr("МБ", "MB")) if n >= 1048576 else f"{max(1, n // 1024)} " + tr("КБ", "KB")


def scan(path):
    info = []
    with open(path, "rb") as f:
        for raw in f:
            item = {"len": len(raw)}
            try:
                o = json.loads(raw)
            except ValueError:
                info.append(item)
                continue
            if not isinstance(o, dict):
                info.append(item)
                continue
            item.update(uuid=o.get("uuid"), parent=o.get("parentUuid"), logical=o.get("logicalParentUuid"),
                        type=o.get("type"), side=bool(o.get("isSidechain")))
            if o.get("type") == "system" and o.get("subtype") == "compact_boundary":
                meta = o.get("compactMetadata") or {}
                keep = set((meta.get("preservedMessages") or {}).get("allUuids") or [])
                keep |= set((meta.get("preservedMessages") or {}).get("uuids") or [])
                seg = meta.get("preservedSegment") or {}
                keep |= {seg.get(k) for k in ("headUuid", "anchorUuid", "tailUuid") if seg.get(k)}
                item["boundary"] = True
                item["preserved"] = keep
            info.append(item)
    return info


def protection(info, keep):
    bounds = [i for i, it in enumerate(info) if it.get("boundary")]
    if len(bounds) < keep:
        return None
    cut = bounds[-keep]
    guarded = set()
    for i in bounds[-keep:]:
        guarded |= info[i]["preserved"]
    by_uuid = {it["uuid"]: it for it in info if it.get("uuid")}
    leaf = next((it for it in reversed(info) if it.get("uuid") and not it.get("side")), None)
    crossed, node, seen = 0, leaf, set()
    while node and node["uuid"] not in seen:
        seen.add(node["uuid"])
        guarded.add(node["uuid"])
        if node.get("boundary"):
            crossed += 1
            if crossed >= keep:
                break
            nxt = node.get("logical")
        else:
            nxt = node.get("parent")
        node = by_uuid.get(nxt)
    guarded.discard(None)
    flags = [i >= cut or (it.get("uuid") in guarded) for i, it in enumerate(info)]
    return {"cut": cut, "flags": flags, "bounds": len(bounds)}


def placeholder(kind, size):
    return tr(f"[{kind} {kb(size)} удалён: {MARK}]", f"[{kind} {kb(size)} removed: {MARK}]")


def cut_text(text, stats):
    if len(text) <= TEXT_LIMIT or MARK in text[-200:]:
        return text
    stats["texts"] += 1
    return text[:HEAD] + tr(f"\n… [обрезано {len(text) - HEAD - TAIL} символов: {MARK}] …\n",
                            f"\n… [{len(text) - HEAD - TAIL} characters cut: {MARK}] …\n") + text[-TAIL:]


def image_size(block):
    src = block.get("source") or {}
    return len(src.get("data") or "") if isinstance(src, dict) else 0


def slim_blocks(blocks, stats):
    out = []
    for b in blocks:
        if not isinstance(b, dict):
            out.append(b)
        elif b.get("type") == "image" and image_size(b) > 2048:
            stats["images"] += 1
            stats["image_bytes"] += image_size(b)
            out.append({"type": "text", "text": placeholder(tr("скриншот", "screenshot"), image_size(b) * 3 // 4)})
        elif b.get("type") == "text" and isinstance(b.get("text"), str):
            out.append(dict(b, text=cut_text(b["text"], stats)))
        elif b.get("type") == "tool_result":
            c = b.get("content")
            if isinstance(c, list):
                out.append(dict(b, content=slim_blocks(c, stats)))
            elif isinstance(c, str):
                out.append(dict(b, content=cut_text(c, stats)))
            else:
                out.append(b)
        else:
            out.append(b)
    return out


def slim_ui(v, stats, key=None):
    if isinstance(v, dict):
        if isinstance(v.get("base64"), str) and len(v["base64"]) > 2048:
            stats["images"] += 1
            stats["image_bytes"] += len(v["base64"])
            return dict(v, base64=PIXEL, type="image/png") if "type" in v else dict(v, base64=PIXEL)
        src = v.get("source")
        if v.get("type") == "image" and isinstance(src, dict) and isinstance(src.get("data"), str) \
                and len(src["data"]) > 2048:
            stats["images"] += 1
            stats["image_bytes"] += len(src["data"])
            return dict(v, source=dict(src, data=PIXEL, media_type="image/png"))
        return {k: (x if k in ("structuredPatch", "oldString", "newString") else slim_ui(x, stats, k))
                for k, x in v.items()}
    if isinstance(v, list):
        return [slim_ui(x, stats, key) for x in v]
    if isinstance(v, str) and len(v) > TEXT_LIMIT:
        return cut_text(v, stats)
    return v


def slim_line(o, stats):
    kind = o.get("type")
    if kind == "user":
        msg = o.get("message")
        if isinstance(msg, dict) and isinstance(msg.get("content"), list):
            o = dict(o, message=dict(msg, content=slim_blocks(msg["content"], stats)))
        elif isinstance(msg, dict) and isinstance(msg.get("content"), str) and not o.get("isCompactSummary"):
            o = dict(o, message=dict(msg, content=cut_text(msg["content"], stats)))
        if "toolUseResult" in o:
            o = dict(o, toolUseResult=slim_ui(o["toolUseResult"], stats))
    elif kind == "attachment" and isinstance(o.get("attachment"), dict):
        att = o["attachment"]
        if isinstance(att.get("prompt"), list):
            o = dict(o, attachment=dict(att, prompt=slim_blocks(att["prompt"], stats)))
    return o


def dump(o):
    return json.dumps(o, ensure_ascii=False, separators=(",", ":"))


def write_slim(src, dst, info, prot, rename=None):
    stats = {"images": 0, "image_bytes": 0, "texts": 0, "changed": 0}
    sid_re = re.compile(rb'"sessionId":"' + re.escape(rename[0].encode()) + rb'"') if rename else None
    with open(src, "rb") as fi, open(dst, "wb") as fo:
        for i, raw in enumerate(fi):
            if i >= len(info):
                raise SlimError(tr("сессия изменилась во время сжатия, повтори",
                                   "the session changed while compacting, try again"))
            if sid_re:
                raw = sid_re.sub(b'"sessionId":"' + rename[1].encode() + b'"', raw)
            if prot["flags"][i] or info[i].get("type") not in ("user", "attachment"):
                fo.write(raw)
                continue
            try:
                o = json.loads(raw)
            except ValueError:
                fo.write(raw)
                continue
            new = slim_line(o, stats)
            if new is o or dump(new) == dump(o):
                fo.write(raw)
                continue
            stats["changed"] += 1
            fo.write(dump(new).encode("utf-8") + (b"\n" if raw.endswith(b"\n") else b""))
    return stats


def verify(src, dst, info, prot, keep, rename=None):
    info2 = scan(dst)
    if len(info2) != len(info):
        raise SlimError(tr(f"число строк изменилось: {len(info)} → {len(info2)}",
                           f"the line count changed: {len(info)} → {len(info2)}"))
    prot2 = protection(info2, keep)
    if not prot2 or prot2["flags"] != prot["flags"]:
        raise SlimError(tr("после сжатия иначе определяется то, что Claude Code отправит модели",
                           "after compacting, what Claude Code sends to the model would be determined differently"))
    back = (re.compile(rb'"sessionId":"' + re.escape(rename[1].encode()) + rb'"'),
            b'"sessionId":"' + rename[0].encode() + b'"') if rename else None
    with open(src, "rb") as fa, open(dst, "rb") as fb:
        for i, (a, b) in enumerate(zip(fa, fb)):
            if back:
                b = back[0].sub(back[1], b)
            if a == b:
                continue
            if prot["flags"][i]:
                raise SlimError(tr(f"строка {i + 1} попадает в контекст модели, но изменилась",
                                   f"line {i + 1} is in the model's context, but it changed"))
            try:
                oa, ob = json.loads(a), json.loads(b)
            except ValueError:
                raise SlimError(tr(f"строка {i + 1} перестала читаться как JSON",
                                   f"line {i + 1} no longer parses as JSON"))
            for k in ("uuid", "parentUuid", "logicalParentUuid", "type", "timestamp", "isSidechain", "sessionId"):
                if oa.get(k) != ob.get(k):
                    raise SlimError(tr(f"в строке {i + 1} изменилось поле {k}", f"field {k} changed in line {i + 1}"))
            if set(oa) != set(ob):
                raise SlimError(tr(f"в строке {i + 1} изменился набор полей", f"the set of fields changed in line {i + 1}"))
    return True


# Папка рядом с файлом сессии (<sid>/): tool-results с сохраненными скриншотами и длинными выводами и subagents
# с переписками субагентов. promptsill и размер сессии считают ее вместе с файлом.
AGENT_FILE = re.compile(r"agent-([0-9a-z]+)\.jsonl")


def side_dir(path):
    folder = path[:-6] if path.endswith(".jsonl") else ""
    return folder if folder and os.path.isdir(folder) else None


def mentioned(path, prot, words):
    """Какие из words встречаются в строках, которые модель видит (и в строках, дописанных после scan)."""
    if not words:
        return set()
    pattern = re.compile(b"|".join(re.escape(w.encode()) for w in sorted(words, key=len, reverse=True)))
    found = set()
    with open(path, "rb") as f:
        for i, raw in enumerate(f):
            if i < len(prot["flags"]) and not prot["flags"][i]:
                continue
            found.update(m.decode() for m in pattern.findall(raw))
    return found


def slim_agent(src, dst):
    """Переписка субагента, которого модель уже не видит: все строки сжимаются как старая часть сессии."""
    stats = {"images": 0, "image_bytes": 0, "texts": 0, "changed": 0}
    with open(src, "rb") as fi, open(dst, "wb") as fo:
        for raw in fi:
            try:
                o = json.loads(raw)
            except ValueError:
                fo.write(raw)
                continue
            new = slim_line(o, stats) if isinstance(o, dict) and o.get("type") in ("user", "attachment") else o
            if new is o or dump(new) == dump(o):
                fo.write(raw)
                continue
            stats["changed"] += 1
            fo.write(dump(new).encode("utf-8") + (b"\n" if raw.endswith(b"\n") else b""))
    return stats


def folder_size(folder):
    total = 0
    for root, _, files in os.walk(folder or ""):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def side_plan(path, prot, run=False, backup_to=None):
    """Что делать с папкой сессии. Файлы tool-results, о которых модель уже не знает, уходят в резервную копию,
    переписки субагентов, которых модель не видит, сжимаются. run=False только считает."""
    folder = side_dir(path)
    out = {"side_before": folder_size(folder), "side_after": 0, "side_files": 0, "side_agents": 0, "side_backup": None}
    if not folder or not prot:
        out["side_after"] = out["side_before"]
        return out
    results = os.path.join(folder, "tool-results")
    names = [n for n in (os.listdir(results) if os.path.isdir(results) else []) if os.path.isfile(os.path.join(results, n))]
    agents_dir = os.path.join(folder, "subagents")
    agents = {}
    for n in (os.listdir(agents_dir) if os.path.isdir(agents_dir) else []):
        m = AGENT_FILE.fullmatch(n)
        if m:
            agents[m.group(1)] = os.path.join(agents_dir, n)
    seen = mentioned(path, prot, set(names) | set(agents))
    drop = [os.path.join(results, n) for n in names if n not in seen]
    rewrites = []
    for agent_id, agent_path in sorted(agents.items()):
        if agent_id in seen:
            continue
        tmp = agent_path + ".mnrh-slim"
        try:
            if slim_agent(agent_path, tmp)["changed"] and os.path.getsize(tmp) < os.path.getsize(agent_path):
                rewrites.append((agent_path, tmp))
            else:
                os.remove(tmp)
        except OSError:
            if os.path.exists(tmp):
                os.remove(tmp)
    saved = sum(os.path.getsize(p) for p in drop) + sum(os.path.getsize(a) - os.path.getsize(t) for a, t in rewrites)
    out.update(side_after=out["side_before"] - saved, side_files=len(drop), side_agents=len(rewrites))
    try:
        if run and (drop or rewrites):
            tar = backup_to + ".side.tar.gz"
            with tarfile.open(tar, "w:gz", compresslevel=1) as t:
                for p in drop + [a for a, _ in rewrites]:
                    t.add(p, arcname=os.path.relpath(p, folder))
            os.chmod(tar, 0o600)
            out["side_backup"] = tar
            for p in drop:
                os.remove(p)
            for agent_path, tmp in rewrites:
                shutil.copystat(agent_path, tmp)
                os.replace(tmp, agent_path)
    finally:
        for _, tmp in rewrites:
            if os.path.exists(tmp):
                os.remove(tmp)
    return out


def side_backups_of(sid):
    return sorted(glob.glob(os.path.join(BACKUPS, f"{sid}.*.side.tar.gz")))


def restore_side(path, tar):
    folder = path[:-6]
    with tarfile.open(tar) as t:
        for member in t.getmembers():
            if not member.isfile() or member.name.startswith("/") or ".." in member.name.split("/"):
                raise SlimError(tr(f"в {tilde(tar)} странный путь {member.name}",
                                   f"{tilde(tar)} has a strange path {member.name}"))
        # фильтр data есть с Python 3.12 (и в поздних 3.8–3.11), пути выше уже проверены
        if hasattr(tarfile, "data_filter"):
            t.extractall(folder, filter="data")
        else:
            t.extractall(folder)


def context_tokens(path, tail=8 << 20):
    """Сколько токенов в контексте по последней записи: ответ модели или /compact. None, если не видно."""
    try:
        with open(path, "rb") as f:
            size = f.seek(0, os.SEEK_END)
            f.seek(max(0, size - tail))
            lines = f.read().split(b"\n")
    except OSError:
        return None
    for raw in reversed(lines):
        if b'"compact_boundary"' not in raw and b'"usage"' not in raw:
            continue
        try:
            o = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(o, dict) or o.get("isSidechain"):
            continue
        if o.get("type") == "system" and o.get("subtype") == "compact_boundary":
            return (o.get("compactMetadata") or {}).get("postTokens")
        usage = (o.get("message") or {}).get("usage") if o.get("type") == "assistant" else None
        if isinstance(usage, dict):
            total = sum(usage.get(k) or 0 for k in ("input_tokens", "cache_read_input_tokens",
                                                    "cache_creation_input_tokens"))
            if total:
                return total
    return None


def plan(path, keep=2):
    info = scan(path)
    prot = protection(info, keep)
    if not prot:
        return info, None, None
    tmp = path + ".mnrh-slim-probe"
    try:
        stats = write_slim(path, tmp, info, prot)
        stats["after"] = os.path.getsize(tmp)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    stats["before"] = os.path.getsize(path)
    stats["guarded"] = sum(1 for f in prot["flags"] if f)
    stats["bounds"] = prot["bounds"]
    stats.update(side_plan(path, prot))
    return info, prot, stats


def prune_backups():
    cutoff = time.time() - BACKUP_DAYS * 86400
    for f in glob.glob(os.path.join(BACKUPS, "*")):
        try:
            if os.path.getmtime(f) < cutoff:
                os.remove(f)
        except OSError:
            pass


def prefix_digest(f, size):
    """sha256 первых size байт открытого файла; None, если файл короче."""
    h = hashlib.sha256()
    left = size
    while left:
        chunk = f.read(min(left, 4 << 20))
        if not chunk:
            return None
        h.update(chunk)
        left -= len(chunk)
    return h.hexdigest()


def backup_base(sid):
    os.makedirs(BACKUPS, mode=0o700, exist_ok=True)
    prune_backups()
    return os.path.join(BACKUPS, f"{sid}.{time.strftime('%Y%m%d-%H%M%S')}")


def backup(path, sid, slim_size, slim_file=None, base=None):
    """slim_file: сжатый файл, который сейчас встанет на место path. Его inode и sha256 нужны undo: только
    так видно, что после сжатия файл не переписали (sessions mv меняет cwd и длину строк)."""
    gz = (base or backup_base(sid)) + ".jsonl.gz"
    with open(path, "rb") as fi, gzip.open(gz, "wb", compresslevel=1) as fo:
        shutil.copyfileobj(fi, fo, 4 << 20)
    os.chmod(gz, 0o600)
    meta = {"sid": sid, "path": path, "orig_size": os.path.getsize(path), "slim_size": slim_size,
            "at": time.time()}
    if slim_file:
        with open(slim_file, "rb") as f:
            info = os.fstat(f.fileno())
            meta.update(slim_dev=info.st_dev, slim_ino=info.st_ino, slim_sha256=prefix_digest(f, slim_size))
    with open(gz[:-9] + ".json", "w") as f:
        json.dump(meta, f)
    return gz


def apply(path, sid, keep=2):
    size = os.path.getsize(path)
    info = scan(path)
    prot = protection(info, keep)
    if not prot:
        raise SlimError(tr(f"в сессии меньше {keep} сжатий /compact, сжимать нечего",
                           f"the session has fewer than {keep} /compact, nothing to compact"))
    tmp = path + ".mnrh-slim"
    base = backup_base(sid)
    try:
        stats = write_slim(path, tmp, info, prot)
        if not stats["changed"]:
            stats.update(before=size, after=size, backup=None)
        else:
            verify(path, tmp, info, prot, keep)
            shutil.copystat(path, tmp)
            # строки, дописанные после scan, в tmp не попали; заменить файл можно, только пока он того же размера
            stats["before"] = size
            stats["after"] = os.path.getsize(tmp)
            stats["backup"] = backup(path, sid, stats["after"], tmp, base)
            if os.path.getsize(path) != size:
                raise SlimError(tr("сессия изменилась во время сжатия, повтори",
                                   "the session changed while compacting, try again"))
            os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    try:
        stats.update(side_plan(path, prot, run=True, backup_to=base))
    except (OSError, tarfile.TarError) as e:
        # сама сессия уже сжата, папка рядом осталась как была
        side = folder_size(side_dir(path))
        stats.update(side_before=side, side_after=side, side_files=0, side_agents=0, side_backup=None,
                     side_error=str(e))
    return stats


def copy(path, sid, title, keep=2):
    info = scan(path)
    prot = protection(info, keep)
    if not prot:
        raise SlimError(tr(f"в сессии меньше {keep} сжатий /compact, сжимать нечего",
                           f"the session has fewer than {keep} /compact, nothing to compact"))
    new_sid = str(uuid.uuid4())
    dst = os.path.join(os.path.dirname(path), new_sid + ".jsonl")
    tmp = dst + ".mnrh-slim"
    try:
        stats = write_slim(path, tmp, info, prot, rename=(sid, new_sid))
        verify(path, tmp, info, prot, keep, rename=(sid, new_sid))
        with open(tmp, "ab") as f:
            f.write(dump({"type": "custom-title", "customTitle": tr(f"{title} (сжатая копия)", f"{title} (compacted copy)"),
                          "sessionId": new_sid}).encode() + b"\n")
        shutil.copymode(path, tmp)
        os.replace(tmp, dst)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    stats["before"] = os.path.getsize(path)
    stats["after"] = os.path.getsize(dst)
    stats["new_sid"] = new_sid
    return stats


def backups_of(sid):
    return sorted(glob.glob(os.path.join(BACKUPS, f"{sid}.*.jsonl.gz")))


def undo(path, sid):
    found, sides = backups_of(sid), side_backups_of(sid)
    if not found and not sides:
        raise SlimError(tr(f"резервной копии нет в {tilde(BACKUPS)} (хранятся {BACKUP_DAYS} дней)",
                           f"no backup in {tilde(BACKUPS)} (they're kept for {BACKUP_DAYS} days)"))
    added = undo_file(path, found[-1]) if found else 0
    for tar in reversed(sides):
        restore_side(path, tar)
        os.remove(tar)
    return added


def undo_file(path, gz):
    with open(gz[:-9] + ".json") as f:
        meta = json.load(f)
    rewritten = SlimError(tr("сессию после сжатия переписали (перенос или другая правка), вернуть автоматически нельзя; "
                             f"оригинал лежит в {tilde(gz)}",
                             "the session was rewritten after compacting (a move or another edit), so it can't be "
                             f"restored automatically. The original is in {tilde(gz)}"))
    if not meta.get("slim_sha256"):
        raise SlimError(tr("копию сделала старая версия agentmeister: не видно, переписывали ли сессию после сжатия, "
                           f"поэтому вернуть автоматически нельзя; оригинал лежит в {tilde(gz)}",
                           "an old agentmeister version made this backup. It can't tell whether the session was "
                           "rewritten after compacting, so it can't be restored automatically. "
                           f"The original is in {tilde(gz)}"))
    tmp = path + ".mnrh-undo"
    try:
        with open(path, "rb") as cur:
            info = os.fstat(cur.fileno())
            # Claude Code только дописывает строки в конец; первые slim_size байт должны остаться теми, что записал slim
            if (info.st_dev, info.st_ino) != (meta.get("slim_dev"), meta.get("slim_ino")) \
                    or info.st_size < meta["slim_size"] or prefix_digest(cur, meta["slim_size"]) != meta["slim_sha256"]:
                raise rewritten
            with gzip.open(gz, "rb") as fi, open(tmp, "wb") as fo:
                shutil.copyfileobj(fi, fo, 4 << 20)
                while True:
                    shutil.copyfileobj(cur, fo, 4 << 20)
                    if os.fstat(cur.fileno()).st_size <= cur.tell():
                        break
            added = cur.tell() - meta["slim_size"]
        shutil.copystat(path, tmp)
        info = os.stat(path)
        if (info.st_dev, info.st_ino) != (meta["slim_dev"], meta["slim_ino"]) or info.st_size != meta["slim_size"] + added:
            raise SlimError(tr("сессия изменилась во время возврата, повтори",
                               "the session changed while restoring, try again"))
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    os.remove(gz)
    os.remove(gz[:-9] + ".json")
    return added
