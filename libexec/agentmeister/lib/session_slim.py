"""agentmeister sessions slim: что даст сжатие, сжать, копия, --undo и сжатие при перезапуске (/slim)."""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import NOTICES, confirm, paint, tilde, write_json  # noqa: E402
from session_store import UUID, clip, fast_session, find, fmt_size, folder, load  # noqa: E402
import claude_search  # noqa: E402


def saved(st):
    """Сколько освободит сжатие: файл сессии и папка рядом с ним."""
    return st["before"] - st["after"] + st.get("side_before", 0) - st.get("side_after", 0)


def side_report(st):
    if not (st.get("side_files") or st.get("side_agents")):
        return ""
    return (f"; папка сессии {fmt_size(st['side_before'])} → {fmt_size(st['side_after'])}, "
            f"убрано старых файлов {st['side_files']}, сжато переписок субагентов {st['side_agents']}")


def slim_report(st):
    return (f"{fmt_size(st['before'])} → {fmt_size(st['after'])}: скриншотов {st['images']}, "
            f"обрезано длинных выводов {st['texts']}, изменено строк {st['changed']}" + side_report(st))


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
            raise claude_slim.SlimError("сессия не найдена")
        if s["running"]:
            raise claude_slim.SlimError("сессия всё ещё открыта")
        print(f"agentmeister: сжимаю «{s['title'] or sid}»…", flush=True)
        st = claude_slim.apply(s["path"], sid)
        claude_search.drop(sid)
        context = claude_slim.context_tokens(s["path"])
    except claude_slim.SlimError as e:
        print(f"agentmeister: не сжал: {e}. Открываю как есть.")
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
            sys.exit("agentmeister sessions: после --keep нужно число")
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
            print("Сжимать нечего: нет закрытых сессий, где старая часть занимает заметное место.")
            return 0
        total = sum(saved(st) for _, st in found)
        print(f"Можно освободить {fmt_size(total)}:")
        for s, st in found:
            print(f"  {s['id'][:8]}  {clip(folder(s['cwd']), 20):<20}  "
                  f"{fmt_size(st['before'] + st.get('side_before', 0)):>7} → "
                  f"{fmt_size(st['after'] + st.get('side_after', 0)):>7}  {clip(s['title'] or '—', 50)}")
        print(paint(f"Сжать: agentmeister sessions slim <id>. Проверить сначала на копии: slim <id> --copy", "2"))
        return 0
    s = fast_session(ids[0]) if UUID.match(ids[0]) else find(ss, ids[0])
    if not s:
        sys.exit(f"agentmeister sessions: сессии «{ids[0]}» нет")
    if s["link"]:
        sys.exit("agentmeister sessions: это ссылка на другую сессию, сжимай оригинал")
    if s["running"]:
        sys.exit("agentmeister sessions: сессия сейчас открыта, сначала закрой её")
    try:
        if "--undo" in args:
            added = claude_slim.undo(s["path"], s["id"])
            claude_search.drop(s["id"])
            print(f"Оригинал возвращён" + (f", новые сообщения после сжатия сохранены ({fmt_size(added)})" if added else ""))
            return 0
        if "--copy" in args:
            st = claude_slim.copy(s["path"], s["id"], s["title"] or s["id"][:8], keep)
            print(f"Сжатая копия: {slim_report(st)}. Проверка: всё, что уходит модели, совпадает побайтно.")
            print(f"Открой её и спроси про последнюю работу: cd {shlex_quote(s['cwd'])} && claude --resume {st['new_sid']}")
            print(paint(f"Удалить копию потом: agentmeister sessions rm {st['new_sid'][:8]}", "2"))
            return 0
        _, prot, st = claude_slim.plan(s["path"], keep)
        if not st:
            print(f"В сессии меньше {keep} сжатий /compact, сжимать нечего.")
            return 0
        print(f"«{s['title'] or s['id']}»: {slim_report(st)}")
        print(f"Не трогаю {st['guarded']} строк: всё после {keep}-го с конца /compact (из {st['bounds']}) и "
              "сообщения, которые /compact сохранил. Сообщения Claude и историю файлов не трогаю.")
        if not confirm("Сжать? Оригинал сохранится на 14 дней, вернуть: --undo", yes):
            print("Отменено.")
            return 0
        st = claude_slim.apply(s["path"], s["id"], keep)
        claude_search.drop(s["id"])
        if not st["backup"] and not st.get("side_backup"):
            print("Менять нечего: старая часть уже сжата.")
            return 0
        print(f"Готово: {slim_report(st)}. Проверка пройдена: всё, что уходит модели, совпадает побайтно.")
        print(paint(f"Оригинал: {tilde(st['backup'] or st['side_backup'])}", "2"))
    except claude_slim.SlimError as e:
        sys.exit(f"agentmeister sessions slim: {e}. Ничего не изменено.")
    return 0


def shlex_quote(s):
    import shlex
    return shlex.quote(s)
