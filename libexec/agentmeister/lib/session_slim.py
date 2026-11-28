"""agentmeister sessions slim: что даст сжатие, сжать, копия, --undo и сжатие при перезапуске (/slim)."""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import NOTICES, confirm, paint, tilde, tr, write_json  # noqa: E402
from session_store import UUID, clip, fast_session, find, fmt_size, folder, load  # noqa: E402
import claude_search  # noqa: E402


def saved(st):
    """Сколько освободит сжатие: файл сессии и папка рядом с ним."""
    return st["before"] - st["after"] + st.get("side_before", 0) - st.get("side_after", 0)


def side_report(st):
    if not (st.get("side_files") or st.get("side_agents")):
        return ""
    return tr(f"; папка сессии {fmt_size(st['side_before'])} → {fmt_size(st['side_after'])}, "
              f"убрано старых файлов {st['side_files']}, сжато переписок субагентов {st['side_agents']}",
              f"; session folder {fmt_size(st['side_before'])} → {fmt_size(st['side_after'])}, "
              f"old files removed: {st['side_files']}, subagent transcripts compacted: {st['side_agents']}")


def slim_report(st):
    return tr(f"{fmt_size(st['before'])} → {fmt_size(st['after'])}: скриншотов {st['images']}, "
              f"обрезано длинных выводов {st['texts']}, изменено строк {st['changed']}",
              f"{fmt_size(st['before'])} → {fmt_size(st['after'])}: screenshots: {st['images']}, "
              f"long outputs cut: {st['texts']}, lines changed: {st['changed']}") + side_report(st)


def slim_notice(sid, **fields):
    path = os.path.join(NOTICES, sid + ".json")
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return
    data.update(fields, at=time.time())
    write_json(path, data, ensure_ascii=False)


def slim_in_tab(sid):
    import claude_slim
    s = fast_session(sid)
    try:
        if not s:
            raise claude_slim.SlimError(tr("сессия не найдена", "session not found"))
        if s["running"]:
            raise claude_slim.SlimError(tr("сессия всё ещё открыта", "the session is still open"))
        print(tr(f"agentmeister: сжимаю «{s['title'] or sid}»…", f"agentmeister: compacting \"{s['title'] or sid}\"…"),
              flush=True)
        st = claude_slim.apply(s["path"], sid)
        claude_search.drop(sid)
        context = claude_slim.context_tokens(s["path"])
    except claude_slim.SlimError as e:
        print(tr(f"agentmeister: не сжал: {e}. Открываю как есть.",
                 f"agentmeister: couldn't compact: {e}. Opening it as is."))
        slim_notice(sid, status="failed", error=str(e))
        return 1
    print(f"agentmeister: {slim_report(st)}")
    slim_notice(sid, status="done", before=fmt_size(st["before"] + st.get("side_before", 0)),
                after=fmt_size(st["after"] + st.get("side_after", 0)), images=st["images"] + st.get("side_files", 0),
                context=context)
    return 0


def slim_cmd(args, yes):
    import claude_slim
    if "--notice" in args:
        ids = [a for a in args if UUID.match(a)]
        return slim_in_tab(ids[0]) if ids else 2
    keep = 2
    if "--keep" in args:
        try:
            keep = max(1, int(args[args.index("--keep") + 1]))
        except (IndexError, ValueError):
            sys.exit(tr("agentmeister sessions: после --keep нужно число",
                        "agentmeister sessions: --keep needs a number"))
    ids = [a for a in args if not a.startswith("-") and not (args.index(a) > 0 and args[args.index(a) - 1] == "--keep")]
    ss = load() if not ids or not UUID.match(ids[0]) else []
    if not ids:
        found = []
        for s in ss:
            if s["running"] or s["link"] or s["size"] < 20 << 20:
                continue
            _, prot, st = claude_slim.plan(s["path"], keep)
            if st and saved(st) >= 5 << 20:
                found.append((s, st))
        if not found:
            print(tr("Сжимать нечего: нет закрытых сессий, где старая часть занимает заметное место.",
                     "Nothing to compact: no closed session has an old part that takes noticeable space."))
            return 0
        total = sum(saved(st) for _, st in found)
        print(tr(f"Можно освободить {fmt_size(total)}:", f"You can free {fmt_size(total)}:"))
        for s, st in found:
            print(f"  {s['id'][:8]}  {clip(folder(s['cwd']), 20):<20}  "
                  f"{fmt_size(st['before'] + st.get('side_before', 0)):>7} → "
                  f"{fmt_size(st['after'] + st.get('side_after', 0)):>7}  {clip(s['title'] or '—', 50)}")
        print(paint(tr(f"Сжать: agentmeister sessions slim <id>. Проверить сначала на копии: slim <id> --copy",
                       "Compact: agentmeister sessions slim <id>. Try it on a copy first: slim <id> --copy"), "2"))
        return 0
    s = fast_session(ids[0]) if UUID.match(ids[0]) else find(ss, ids[0])
    if not s:
        sys.exit(tr(f"agentmeister sessions: сессии «{ids[0]}» нет", f"agentmeister sessions: no session \"{ids[0]}\""))
    if s["link"]:
        sys.exit(tr("agentmeister sessions: это ссылка на другую сессию, сжимай оригинал",
                    "agentmeister sessions: this is a link to another session, compact the original"))
    if s["running"]:
        sys.exit(tr("agentmeister sessions: сессия сейчас открыта, сначала закрой её",
                    "agentmeister sessions: the session is open right now, close it first"))
    try:
        if "--undo" in args:
            added = claude_slim.undo(s["path"], s["id"])
            claude_search.drop(s["id"])
            print(tr(f"Оригинал возвращён", "Original restored")
                  + (tr(f", новые сообщения после сжатия сохранены ({fmt_size(added)})",
                        f", new messages after compacting kept ({fmt_size(added)})") if added else ""))
            return 0
        if "--copy" in args:
            st = claude_slim.copy(s["path"], s["id"], s["title"] or s["id"][:8], keep)
            print(tr(f"Сжатая копия: {slim_report(st)}. Проверка: всё, что уходит модели, совпадает побайтно.",
                     f"Compacted copy: {slim_report(st)}. Check: everything sent to the model matches byte for byte."))
            print(tr(f"Открой её и спроси про последнюю работу: cd {shlex_quote(s['cwd'])} && claude --resume {st['new_sid']}",
                     f"Open it and ask about the latest work: cd {shlex_quote(s['cwd'])} && claude --resume {st['new_sid']}"))
            print(paint(tr(f"Удалить копию потом: agentmeister sessions rm {st['new_sid'][:8]}",
                           f"Delete the copy later: agentmeister sessions rm {st['new_sid'][:8]}"), "2"))
            return 0
        _, prot, st = claude_slim.plan(s["path"], keep)
        if not st:
            print(tr(f"В сессии меньше {keep} сжатий /compact, сжимать нечего.",
                     f"The session has fewer than {keep} /compact, nothing to compact."))
            return 0
        print(tr(f"«{s['title'] or s['id']}»: {slim_report(st)}", f"\"{s['title'] or s['id']}\": {slim_report(st)}"))
        print(tr(f"Не трогаю {st['guarded']} строк: всё после {keep}-го с конца /compact (из {st['bounds']}) и "
                 "сообщения, которые /compact сохранил. Сообщения Claude и историю файлов не трогаю.",
                 f"Leaving {st['guarded']} lines alone: everything after the {keep}th /compact from the end "
                 f"(of {st['bounds']}) and the messages /compact kept. Claude's messages and file history "
                 "aren't touched."))
        if not confirm(tr("Сжать? Оригинал сохранится на 14 дней, вернуть: --undo",
                          "Compact? The original is kept for 14 days, undo with --undo"), yes):
            print(tr("Отменено.", "Cancelled."))
            return 0
        st = claude_slim.apply(s["path"], s["id"], keep)
        claude_search.drop(s["id"])
        if not st["backup"] and not st.get("side_backup"):
            print(tr("Менять нечего: старая часть уже сжата.", "Nothing to change: the old part is already compacted."))
            return 0
        print(tr(f"Готово: {slim_report(st)}. Проверка пройдена: всё, что уходит модели, совпадает побайтно.",
                 f"Done: {slim_report(st)}. Check passed: everything sent to the model matches byte for byte."))
        print(paint(tr(f"Оригинал: {tilde(st['backup'] or st['side_backup'])}",
                       f"Original: {tilde(st['backup'] or st['side_backup'])}"), "2"))
    except claude_slim.SlimError as e:
        sys.exit(tr(f"agentmeister sessions slim: {e}. Ничего не изменено.",
                    f"agentmeister sessions slim: {e}. Nothing was changed."))
    return 0


def shlex_quote(s):
    import shlex
    return shlex.quote(s)
