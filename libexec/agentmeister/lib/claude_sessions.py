#!/usr/bin/env python3
"""agentmeister sessions: список, меню, продолжить, перенести, удалить, уборка; slim — в session_slim."""
import collections
from contextlib import ExitStack
import os
import shutil
import stat
import tempfile
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mac_files import RENAME_EXCL, rename_with_flags
from mnrhlib import HOME, confirm, has_flag, paint, projects, tilde, tr  # noqa: E402
from menu import Quit, Screen, pick  # noqa: E402
from session_store import (PROJECTS, UUID, ago, clip, decode, delete, encode, find, forget_deleted_session, fmt_size, folder,  # noqa: E402
                           is_junk, load, offline, remove_if_empty, require_idle, rewrite, running_ids, SessionInUse, tree_size)
import claude_search  # noqa: E402

CLAUDE_BIN = os.environ.get("MNRH_CLAUDE_BIN", "claude")


def usage():
    print("agentmeister sessions     сохранённые сессии: выбрать стрелками, продолжить, перенести, удалить")
    print("agentmeister sessions -l  просто список")
    print("agentmeister sessions resume <id> [-n] продолжить в её папке (по умолчанию через caffeinate, -n обычная)")
    print("agentmeister sessions mv <id> <папка>  перенести в другую папку: путь, имя проекта из папки проектов или root")
    print("agentmeister sessions rm <id>... [-y]  удалить вместе с историей запросов этой сессии")
    print("agentmeister sessions clean [-y]       битые ссылки, сессии без единого ответа, папки удалённых проектов")
    print("agentmeister sessions search <слова>   поиск по всем сессиям; -p <проект>, -d <дней>, -r error — по ошибкам")
    print("agentmeister sessions show <id> [N]    прочитать сессию с сообщения N (из search), -N — с конца")
    print("agentmeister sessions slim             что даст сжатие старых частей сессий (скриншоты, длинные выводы)")
    print("agentmeister sessions slim <id> [-y]   сжать; --copy — сжатую копию с новым id для проверки;")
    print("                                      --undo — вернуть оригинал; --keep N — не трогать N последних")
    print("                                      отрезков между /compact (по умолчанию 2)")
    print()
    print("<id> — начало id из списка, 4–8 символов обычно хватает.")
    print("Перенос переписывает cwd внутри сессии, так что `claude --resume` найдёт её уже в новой папке.")


def flags(s):
    out = ""
    if s["running"]:
        out += " ● открыта"
    if s["link"]:
        out += " ↪ ссылка"
    if not os.path.isdir(s["cwd"]):
        out += " ✗ папки нет"
    return out


def row(s):
    return (f"{ago(s['mtime']):>13}  {fmt_size(s['size']):>7}  {clip(folder(s['cwd']), 24):<24}  "
            f"{clip(s['title'] or '—', 60)}{flags(s)}")


def summary(ss):
    return f"Сессии Claude Code: {len(ss)}, {fmt_size(sum(s['size'] for s in ss))} в {tilde(PROJECTS)}"


def print_list(ss):
    print(summary(ss))
    print()
    print(paint(f"  {'id':<8}  {'когда':>13}  {'размер':>7}  {'папка':<24}  название", "2"))
    for s in ss:
        print(f"  {s['id'][:8]}  {row(s)}")


def resolve_dest(arg):
    if arg in ("root", "~"):
        return HOME
    path = os.path.abspath(os.path.expanduser(arg))
    if os.path.isdir(path):
        return path
    names = [p for p in projects() if os.path.basename(p) == arg] or \
            [p for p in projects() if os.path.basename(p).startswith(arg)]
    if len(names) == 1:
        return names[0]
    if names:
        sys.exit(f"agentmeister sessions: «{arg}» подходит к нескольким проектам: "
                 + " ".join(os.path.basename(p) for p in names))
    sys.exit(f"agentmeister sessions: папки «{arg}» нет")


def stage_sidecar(source, staged, olds, dest, rewrite_paths):
    if os.path.islink(source) or not os.path.isdir(source):
        shutil.copy2(source, staged, follow_symlinks=False)
        return 0
    shutil.copytree(source, staged, symlinks=True)
    changed = 0
    if rewrite_paths:
        for root, _, files in os.walk(staged):
            for name in files:
                path = os.path.join(root, name)
                if name.endswith(".jsonl") and not os.path.islink(path):
                    changed += rewrite(path, path, olds, dest)
    return changed


def move(s, dest):
    require_idle(s)
    dest = os.path.abspath(dest)
    tdir = os.path.join(PROJECTS, encode(dest))
    if tdir == s["pdir"]:
        print(f"Сессия уже в {tilde(dest)}")
        return
    target = os.path.join(tdir, s["id"] + ".jsonl")
    extra = os.path.join(tdir, s["id"])
    if any(os.path.lexists(path) for path in (target, extra)):
        sys.exit(f"agentmeister sessions: в {tilde(tdir)} уже есть файлы с таким id")
    os.makedirs(tdir, exist_ok=True)
    olds = {s["cwd"], s["started_in"]} - {None}
    source, sidecar = s["path"], s["extra"]
    original = file_version(os.lstat(source))
    sidecar_state = tree_snapshot(sidecar) if os.path.lexists(sidecar) else {}
    changed = 0
    with tempfile.TemporaryDirectory(dir=tdir) as staging, tempfile.TemporaryDirectory(dir=s["pdir"]) as backup:
        transcript = os.path.join(staging, "transcript")
        staged_extra = os.path.join(staging, "extra")
        if s["link"]:
            link = os.readlink(source)
            if not os.path.isabs(link):
                link = os.path.relpath(os.path.join(s["pdir"], link), tdir)
            os.symlink(link, transcript)
        else:
            changed = rewrite(source, transcript, olds, dest)
        if sidecar_state:
            changed += stage_sidecar(sidecar, staged_extra, olds, dest, rewrite_paths=not s["link"])
        require_idle(s)
        current = tree_snapshot(sidecar) if os.path.lexists(sidecar) else {}
        if current != sidecar_state or file_version(os.lstat(source)) != original:
            sys.exit("agentmeister sessions: файлы сессии изменились во время переноса")

        with ExitStack() as rollback:
            if sidecar_state:
                rename_with_flags(staged_extra, extra, RENAME_EXCL)
                rollback.callback(os.rename, extra, staged_extra)
            rename_with_flags(transcript, target, RENAME_EXCL)
            rollback.callback(os.rename, target, transcript)
            if sidecar_state:
                saved = os.path.join(backup, "extra")
                os.rename(sidecar, saved)
                rollback.callback(os.rename, saved, sidecar)
            os.unlink(source)
            rollback.pop_all()
    remove_if_empty(s["pdir"])
    print(f"Перенесено: {tilde(s['cwd'])} → {tilde(dest)}" + (f", cwd переписан в {changed} строках" if changed else ""))
    print(paint(f"Продолжить: cd {tilde(dest)} && claude --resume {s['id']}", "2"))


def resume(s, mode):
    if s["running"]:
        sys.exit("agentmeister sessions: сессия уже открыта в другом окне")
    if not os.path.isdir(s["cwd"]):
        sys.exit(f"agentmeister sessions: папки {tilde(s['cwd'])} больше нет, перенеси сессию: "
                 f"agentmeister sessions mv {s['id'][:8]} <папка>")
    os.chdir(s["cwd"])
    print(f"-> {tilde(s['cwd'])} · {mode} · {s['title'] or s['id']}")
    sys.stdout.flush()
    cmd = [CLAUDE_BIN, "--resume", s["id"]]
    if mode == "caffeinate":
        cmd = ["caffeinate", "-is"] + cmd
    try:
        os.execvp(cmd[0], cmd)
    except OSError as e:
        sys.exit(f"agentmeister sessions: не запустился {cmd[0]}: {e}")


def file_version(info):
    return info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def tree_snapshot(path):
    entries = {}

    def visit(name):
        info = os.lstat(name)
        entries[name] = file_version(info)
        if stat.S_ISDIR(info.st_mode):
            for child in os.listdir(name):
                visit(os.path.join(name, child))

    visit(path)
    return entries


def remove_orphan(pdir, home, sessions, snapshot):
    name = os.path.basename(pdir)
    if offline(home, name) or (home and os.path.isdir(home)) or decode(name):
        return False
    if any(s["running"] for s in sessions) or running_ids().keys() & {s["id"] for s in sessions}:
        return False
    if tree_snapshot(pdir) != snapshot:
        return False
    # Only unlink listed entries. A new file keeps its parent directory alive.
    def prune(fd, path):
        for child in os.listdir(fd):
            full = os.path.join(path, child)
            info = os.stat(child, dir_fd=fd, follow_symlinks=False)
            if file_version(info) != snapshot.get(full):
                return False
            if stat.S_ISDIR(info.st_mode):
                sub = os.open(child, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    if not os.path.samestat(info, os.fstat(sub)) or not prune(sub, full):
                        return False
                finally:
                    os.close(sub)
                os.rmdir(child, dir_fd=fd)
            else:
                os.unlink(child, dir_fd=fd)
        return True

    fd = os.open(pdir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if file_version(os.fstat(fd)) != snapshot[pdir] or not prune(fd, pdir):
            return False
        os.rmdir(pdir)
    finally:
        os.close(fd)
    for session in sessions:
        forget_deleted_session(session)
    return True


def clean(assume_yes):
    everything = load()
    broken, empty, orphans, away = [], [], [], []
    for d in sorted(os.listdir(PROJECTS)):
        pdir = os.path.join(PROJECTS, d)
        if not os.path.isdir(pdir) or os.path.islink(pdir):
            continue
        sessions = [s for s in everything if s["pdir"] == pdir]
        cwds = collections.Counter(s["cwd"] for s in sessions if s["cwd"])
        home = cwds.most_common(1)[0][0] if cwds else decode(d)
        if home is None or not os.path.isdir(home):
            if offline(home, d):
                away.append(home or d)
            elif os.listdir(pdir):
                try:
                    snapshot = tree_snapshot(pdir)
                except OSError:
                    continue
                orphans.append((pdir, home, sessions, snapshot))
            continue
        for f in os.listdir(pdir):
            path = os.path.join(pdir, f)
            try:
                version = file_version(os.lstat(path))
                if stat.S_ISLNK(version[2]) and not os.path.exists(path):
                    broken.append((path, version, os.readlink(path)))
            except FileNotFoundError:
                continue
        for s in sessions:
            if s["answered"] is False and not s["running"] and not s["link"]:
                empty.append(s)

    did = False
    if away:
        print(f"Проекты на отключенных дисках ({len(away)}) не трогаю: " + ", ".join(tilde(h) for h in away[:5])
              + (" и другие" if len(away) > 5 else ""))
        print()
    if broken:
        print(f"Битые ссылки ({len(broken)}):")
        for p, _, target in broken:
            print(f"  {tilde(p)} → {target}")
        if confirm("Удалить?", assume_yes):
            for p, version, target in broken:
                try:
                    if file_version(os.lstat(p)) == version and os.readlink(p) == target and not os.path.exists(p):
                        os.unlink(p)
                        did = True
                except FileNotFoundError:
                    continue
        print()
    if empty:
        print(f"Сессии без единого ответа Claude ({len(empty)}, {fmt_size(sum(s['size'] for s in empty))}):")
        for s in empty:
            print(f"  {s['id'][:8]}  {row(s)}")
        if confirm("Удалить?", assume_yes):
            for s in empty:
                try:
                    removed = delete(s, unanswered_only=True)
                except SessionInUse:
                    removed = False
                if removed:
                    did = True
                else:
                    print(f"  {s['id'][:8]}  пропускаю: состояние сессии изменилось или файл недоступен")
        print()
    if orphans:
        print("Папки проектов, которых больше нет на диске:")
        for pdir, home, sessions, _ in orphans:
            mem = " + memory" if os.path.isdir(os.path.join(pdir, "memory")) else ""
            print(f"  {tilde(home) if home else os.path.basename(pdir)}: {len(sessions)} сесс.{mem}, "
                  f"{fmt_size(tree_size(pdir))}")
        if any(s["running"] for _, _, ss, _ in orphans for s in ss):
            print("  среди них есть открытые сессии, эти папки пропущу")
        if confirm("Удалить вместе с сессиями и памятью?", assume_yes):
            for pdir, home, sessions, snapshot in orphans:
                try:
                    removed = remove_orphan(pdir, home, sessions, snapshot)
                except OSError:
                    removed = False
                if removed:
                    did = True
                else:
                    print(f"  {tilde(pdir)}: пропускаю, папка изменилась, занята или недоступна")
        print()
    for d in os.listdir(PROJECTS):
        p = os.path.join(PROJECTS, d)
        if os.path.isdir(p) and not os.path.islink(p):
            remove_if_empty(p)
    if not (broken or empty or orphans):
        print("Чистить нечего.")
    elif did:
        print("Готово.")


def pick_dest(screen, s):
    options = [(os.path.basename(p), p) for p in projects() if p != s["cwd"]]
    if s["cwd"] != HOME:
        options.insert(0, ("~", HOME))
    items = [(k, "🏠 ~ (домашний каталог)" if p == HOME else f"📁 {k}") for k, p in options]
    items.append(("другая", "📝 другая папка, ввести путь"))
    i = screen.pick(items, title=f"Куда перенести из {tilde(s['cwd'])}")
    if i is None:
        return None
    if i < len(options):
        return options[i][1]
    note = ["Полный путь или через ~, например ~/Developer/x."]
    while True:
        raw = screen.ask("Путь", title=f"Куда перенести из {tilde(s['cwd'])}", note=note)
        if not raw or not raw.strip():
            return None
        path = os.path.abspath(os.path.expanduser(raw.strip()))
        if os.path.isdir(path):
            return path
        note = [f"\x1b[33mПапки {tilde(path)} нет.\x1b[0m", "Полный путь или через ~, например ~/Developer/x."]


def dim(text):
    return f"\x1b[2m{text}\x1b[0m"


def details(s):
    """Строки о сессии для правой панели меню."""
    lines = [f"\x1b[1m{s['title'] or 'без названия'}\x1b[0m", ""]
    facts = [("id", s["id"]), ("папка", tilde(s["cwd"]) + (f" ({s['branch']})" if s["branch"] else "")),
             ("размер", fmt_size(s["size"])), ("изменена", ago(s["mtime"]))]
    if s["started_in"] and s["started_in"] != s["cwd"]:
        facts.append(("начата в", tilde(s["started_in"])))
    if s["link"]:
        facts.append(("ссылка на", tilde(s["target"])))
    lines += [dim(f"{k:<10}") + v for k, v in facts]
    if s["running"]:
        lines += ["", f"\x1b[33mоткрыта сейчас (pid {s['running']})\x1b[0m", "переносить и удалять ее нельзя"]
    if s["prompt"] and s["prompt"] != s["title"]:
        lines += ["", dim("ПОСЛЕДНИЙ ЗАПРОС"), clip(" ".join(s["prompt"].split()), 400)]
    return lines


def browse(screen):
    """Сохраненные сессии на экране screen: список, действие, перенос, удаление. Продолжение сессии запускает
    вызывающий: ответ ("resume", сессия, режим). None: Esc в списке. Строка: сообщение для заголовка."""
    pos = 0
    while True:
        ss = load()
        if not ss:
            return "Сохраненных сессий нет"
        items = [(f"{folder(s['cwd'])} {s['title']} {s['id']}", row(s)) for s in ss]
        i = screen.pick(items, title=summary(ss), default=min(pos, len(ss) - 1),
                        describe=lambda i, w: details(ss[i]))
        if i is None:
            return None
        pos = i
        s = ss[i]
        if s["running"]:
            actions = [("назад", "🔙 к списку")]
        else:
            actions = [("caffeinate", "☕ продолжить, Mac не уснет"),
                       ("обычная", "🌙 продолжить обычной сессией"),
                       ("перенести", "📤 перенести в другую папку"),
                       ("удалить", f"❌ удалить ({fmt_size(s['size'])})"),
                       ("назад", "🔙 к списку")]
        a = screen.pick(actions, title=f"Что сделать: {clip(s['title'] or s['id'], 50)}",
                        describe=lambda i, w: details(s))
        act = None if a is None else actions[a][0]
        if act in ("caffeinate", "обычная"):
            return "resume", s, "caffeinate" if act == "caffeinate" else "normal"
        if act == "перенести":
            dest = pick_dest(screen, s)
            if dest:
                with screen.suspend():
                    try:
                        move(s, dest)
                    except SessionInUse as error:
                        return str(error)
                    input(paint("Enter, к списку ", "2"))
        elif act == "удалить":
            sure = screen.pick([("нет", "🔙 нет, оставить"), ("да", "❌ да, удалить безвозвратно")],
                               title=f"Удалить {clip(s['title'] or s['id'], 50)}?", describe=lambda i, w: details(s))
            if sure == 1:
                try:
                    delete(s)
                except SessionInUse as error:
                    return str(error)


def interactive():
    with Screen() as screen:
        try:
            got = browse(screen)
        except Quit:
            got = None
    if isinstance(got, str):
        print(got + ".")
    elif got:
        resume(got[1], got[2])
    return 0


def project_sessions(cwd):
    pdir = os.path.join(PROJECTS, encode(os.path.abspath(cwd)))
    running = running_ids()
    out, busy = [], 0
    try:
        names = os.listdir(pdir)
    except OSError:
        return out, busy
    for f in names:
        sid = f[:-6]
        path = os.path.join(pdir, f)
        if not f.endswith(".jsonl") or not UUID.match(sid) or os.path.islink(path) or not os.path.isfile(path):
            continue
        if sid in running:
            busy += 1
            continue
        if is_junk(path):
            continue
        data = claude_search.update(sid, path)
        if not data:
            continue
        talk = [m for m in data["msgs"] if m[0] in ("user", "claude")]
        out.append({"id": sid, "title": claude_search.title(sid, data), "mtime": os.stat(path).st_mtime,
                    "size": os.lstat(path).st_size + tree_size(os.path.join(pdir, sid)),
                    "msgs": len(talk), "tail": [(m[0], clip(" ".join(str(m[2]).split()), 300)) for m in talk[-4:]]})
    out.sort(key=lambda x: x["mtime"], reverse=True)
    return out, busy


def session_list(cwd):
    """Сессии проекта для меню: (пункты, describe, заголовок, сессии) или None, если сохраненных нет.
    Пункт 0 новая сессия, дальше сессии по времени."""
    ss, busy = project_sessions(cwd)
    if not ss:
        return None
    new = tr("Новая сессия", "New session")
    messages = tr("сообщ.", "msgs")
    items = [(new, f"✨ {new}")]
    for x in ss:
        items.append((x["title"], f"💬 {ago(x['mtime']):>13}  {fmt_size(x['size']):>7}  {x['msgs']:>5} {messages}  "
                                  f"{clip(x['title'], 60)}"))
    note = tr(f" (еще {busy} открыты в других окнах)", f" ({busy} open in other windows)") if busy else ""

    def describe(i, w):
        if i == 0:
            return [f"\x1b[1m{new}\x1b[0m", "", tr("Пустой контекст. Старые сессии останутся в /resume и в этом списке.",
                    "Start with an empty context. Previous sessions stay available here and in /resume.")]
        x = ss[i - 1]
        lines = [f"\x1b[1m{x['title']}\x1b[0m", dim(f"{ago(x['mtime'])} · {fmt_size(x['size'])} · {x['msgs']} {messages}"),
                 "", dim(tr("ПОСЛЕДНИЕ СООБЩЕНИЯ", "RECENT MESSAGES"))]
        for role, text in reversed(x["tail"]):
            lines += ["", dim(tr("вы", "you") if role == "user" else "Claude"), text]
        return lines

    name = folder(os.path.abspath(cwd))
    return items, describe, tr(f"Сессии в {name}", f"Sessions in {name}") + note, ss


def choose_session(cwd):
    found = session_list(cwd)
    if not found:
        print("new")
        return 0
    items, describe, title, ss = found
    i = pick(items, title=title, label="Сессия", start=0, describe=describe)
    if i is None:
        return 130
    print("new" if i == 0 else ss[i - 1]["id"])
    return 0


def main():
    args = sys.argv[1:]
    if has_flag(args, "-h", "--help"):
        usage()
        return 0
    if args[:1] == ["choose"] and len(args) == 2:
        return choose_session(args[1])
    yes = has_flag(args, "-y", "--yes")
    args = [a for a in args if a not in ("-y", "--yes")]
    cmd = args[0] if args else None
    if cmd in (None, "-l", "--list", "ls", "list", "clean") and not os.path.isdir(PROJECTS):
        print(f"Нет {tilde(PROJECTS)}, сессий нет.")
        return 0

    if cmd is None:
        if sys.stdin.isatty() and sys.stdout.isatty():
            return interactive()
        print_list(load())
    elif cmd in ("-l", "--list", "ls", "list"):
        print_list(load())
    elif cmd == "resume" and len(args) >= 2:
        mode = "normal" if has_flag(args, "-n", "--normal") else "caffeinate"
        resume(find(load(), args[1]), mode)
    elif cmd == "mv" and len(args) == 3:
        move(find(load(), args[1]), resolve_dest(args[2]))
    elif cmd == "rm" and len(args) >= 2:
        ss = load()
        targets = [find(ss, a) for a in args[1:]]
        for s in targets:
            print(f"  {s['id'][:8]}  {row(s)}")
        if confirm(f"Удалить {len(targets)}?", yes):
            for s in targets:
                delete(s)
            print("Удалено.")
    elif cmd == "clean":
        clean(yes)
    elif cmd == "slim":
        import session_slim
        return session_slim.slim_cmd(args[1:], yes)
    elif cmd == "search" and len(args) >= 2:
        rest, opts = [], {}
        i = 1
        while i < len(args):
            if args[i] in ("-p", "-d", "-r") and i + 1 < len(args):
                opts[args[i]] = args[i + 1]
                i += 2
                continue
            rest.append(args[i])
            i += 1
        days = opts.get("-d")
        if days is not None and not days.isdigit():
            sys.exit("agentmeister sessions: после -d нужно число дней")
        roles = opts.get("-r", "").split(",") if opts.get("-r") else None
        if roles and not set(roles) <= set(claude_search.ROLES):
            sys.exit("agentmeister sessions: после -r одна из ролей: " + ", ".join(claude_search.ROLES))
        text, err = claude_search.search(" ".join(rest), project=opts.get("-p"), days=int(days) if days else None,
                                         roles=roles,
                                         exclude=[os.environ["CLAUDE_CODE_SESSION_ID"]]
                                         if os.environ.get("CLAUDE_CODE_SESSION_ID") else None)
        print(text.replace("session_read с id и at=<номер после #>", "agentmeister sessions show <id> <номер после #>"))
        return 1 if err else 0
    elif cmd == "show" and len(args) in (2, 3):
        at = None
        if len(args) == 3:
            try:
                at = int(args[2].lstrip("#"))
            except ValueError:
                sys.exit("agentmeister sessions: номер сообщения — число, например 120 или -10")
        text, err = claude_search.read(args[1], at=at)
        print(text)
        return 1 if err else 0
    else:
        usage()
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
