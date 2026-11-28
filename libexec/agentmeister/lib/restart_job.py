"""Задания перезапуска для хука zsh: ~/.cache/agentmeister/restart/<tty>, по одному на вкладку.

/restart, /forget, /fresh, /slim и перезапуск Codex кладут сюда JSON с данными: id сессии, папку, режим,
флаги. Сессия через proxy (agentmeister -x) пишет сюда из песочницы, поэтому файл не выполняется как команда
shell. Хук share/agentmeister/restart.zsh вызывает этот модуль: take читает и удаляет задание, проверяет
поля (только известные флаги, папка существует, id сессии похож на UUID) и печатает папку и строку для истории,
run строит argv сам и запускает. Модуль берет только stdlib, mnrhlib и claude_proc: хук ждет его перед
приглашением.
"""
import json
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import CM, LOCAL_CLI, RESTART_QUEUE, UUID_RE  # noqa: E402
from claude_proc import CLAUDE_BIN, DROP, FLAG_VALUES  # noqa: E402

FORMAT = 2
# MNRH_RESTART_HOOK из restart.zsh: хук, который понимает эти задания. Хук версии 1 выполнял файл через eval.
HOOK_VERSION = "2"
MAX_AGE = 120
MAX_SIZE = 256 * 1024
MODES = ("restart", "forget", "fresh", "slim")
CLAUDE_KEYS = {"v", "kind", "cwd", "mode", "session", "new_session", "update", "proxy", "caffeinate", "flags"}
CODEX_KEYS = {"v", "kind", "cwd", "session", "update", "proxy"}
CAFFEINATE_FLAG = re.compile(r"^-[dimsu]+$")
# имя подписки proxy, как SUB_NAME в proxy.py: задание пишет сессия из песочницы, лишнего не пропускаем
SUB_NAME = re.compile(r"[a-z][a-z0-9-]{0,19}")
# Флаги сессии задает само задание (--resume, --session-id), а имя (-n, --name) оставляем
SESSION_FLAGS = DROP - {"-n", "--name"}


class JobError(ValueError):
    pass


def queue_path(tty):
    return os.path.join(RESTART_QUEUE, os.path.basename(tty))


def known_flag(name):
    return name in FLAG_VALUES and name not in SESSION_FLAGS


def clean_flags(flags):
    """Для записи: убрать флаги, которых нет в списке, вместе с их значениями. (оставленные, убранные)."""
    kept, dropped, i = [], [], 0
    while i < len(flags):
        a = flags[i]
        i += 1
        name, eq, _ = a.partition("=")
        if a.startswith("-") and known_flag(name):
            kind = "none" if eq else FLAG_VALUES[name]
            if eq and FLAG_VALUES[name] == "none":
                dropped.append(a)
                continue
            take = 1 if kind == "one" else 0
            if kind in ("maybe", "many"):
                while i + take < len(flags) and not flags[i + take].startswith("-"):
                    take += 1
                    if kind == "maybe":
                        break
            if i + take > len(flags):
                dropped.append(a)
                continue
            kept += [a] + flags[i:i + take]
            i += take
            continue
        dropped.append(a)
        while i < len(flags) and not flags[i].startswith("-"):
            dropped.append(flags[i])
            i += 1
    return kept, dropped


def check_flags(flags):
    if not isinstance(flags, list) or not all(isinstance(a, str) and "\0" not in a for a in flags):
        raise JobError("flags должен быть списком строк")
    kept, dropped = clean_flags(flags)
    if dropped or kept != flags:
        raise JobError(f"незнакомые флаги claude: {' '.join(dropped) or ' '.join(flags)}")
    return flags


def check_caffeinate(flags):
    if flags is None:
        return None
    if not isinstance(flags, list) or not all(isinstance(a, str) for a in flags):
        raise JobError("caffeinate должен быть списком строк")
    i = 0
    while i < len(flags):
        if flags[i] in ("-t", "-w"):
            if i + 1 >= len(flags) or not flags[i + 1].isdigit():
                raise JobError(f"caffeinate {flags[i]} без числа")
            i += 2
        elif CAFFEINATE_FLAG.match(flags[i]):
            i += 1
        else:
            raise JobError(f"незнакомый флаг caffeinate: {flags[i]}")
    return flags


def check_session(value, field):
    if not isinstance(value, str) or not UUID_RE.fullmatch(value):
        raise JobError(f"{field} не похож на id сессии")
    return value


def validate(job):
    """Проверить задание и вернуть его в нормальном виде. Ошибка — JobError."""
    if not isinstance(job, dict) or job.get("v") != FORMAT:
        raise JobError("не задание agentmeister этой версии")
    kind = job.get("kind")
    keys = CLAUDE_KEYS if kind == "claude" else CODEX_KEYS if kind == "codex" else None
    if keys is None:
        raise JobError(f"неизвестный вид задания {kind!r}")
    extra = set(job) - keys
    if extra:
        raise JobError(f"лишние поля: {', '.join(sorted(extra))}")
    cwd = job.get("cwd")
    if not isinstance(cwd, str) or not os.path.isabs(cwd) or "\0" in cwd:
        raise JobError("cwd должен быть полным путем")
    if not os.path.isdir(cwd):
        raise JobError(f"папки {cwd} нет")
    if not isinstance(job.get("update", False), bool):
        raise JobError("update должен быть true или false")
    proxy = job.get("proxy", False)
    # proxy: true (каскад по подпискам) или имя подписки, через которую шла сессия
    if not isinstance(proxy, bool) and not (isinstance(proxy, str) and SUB_NAME.fullmatch(proxy)):
        raise JobError("proxy должен быть true, false или именем подписки")
    out = {"v": FORMAT, "kind": kind, "cwd": cwd, "session": check_session(job.get("session"), "session"),
           "update": job.get("update", False), "proxy": job.get("proxy", False)}
    if kind == "codex":
        return out
    mode = job.get("mode")
    if mode not in MODES:
        raise JobError(f"неизвестный режим {mode!r}")
    new = mode in ("forget", "fresh")
    out.update(mode=mode, new_session=check_session(job.get("new_session", out["session"]), "new_session"),
               caffeinate=check_caffeinate(job.get("caffeinate")), flags=check_flags(job.get("flags", [])))
    if new == (out["new_session"] == out["session"]):
        raise JobError("new_session нужен для forget и fresh и только для них")
    if out["update"] and mode != "restart":
        raise JobError("update бывает только у restart")
    return out


def claude_job(cwd, mode, session, new_session=None, update=False, proxy=False, caffeinate=None, flags=()):
    return validate({"v": FORMAT, "kind": "claude", "cwd": cwd, "mode": mode, "session": session,
                     "new_session": new_session or session, "update": update, "proxy": proxy,
                     "caffeinate": caffeinate, "flags": list(flags)})


def codex_job(cwd, session, update=False, proxy=False):
    return validate({"v": FORMAT, "kind": "codex", "cwd": cwd, "session": session, "update": update,
                     "proxy": proxy})


def steps(job):
    """Что выполнить по порядку: список (argv, тихо), последний шаг заменяет процесс."""
    via = ["--via", job["proxy"]] if isinstance(job["proxy"], str) else []
    if job["kind"] == "codex":
        program = LOCAL_CLI if job["proxy"] else shutil.which("agentmeister") or LOCAL_CLI
        return [([program, "--harness", "codex", "restart", job["session"]]
                 + (["--update"] if job["update"] else []) + ((via or ["--proxy"]) if job["proxy"] else []), False)]
    proxy = [LOCAL_CLI, "proxy", "run", "--claude", *via, "--"] if job["proxy"] else []
    new = job["mode"] in ("forget", "fresh")
    out = []
    if job["caffeinate"] is not None:
        # после agentmeister lid setup сторож держит Mac и с закрытой крышкой; без правила keep ничего не делает
        out.append(([CM, "lid", "keep"], True))
    if job["update"]:
        # claude update у установки из Homebrew ничего не ставит, agent-update выбирает brew upgrade или claude update
        # без песочницы, но через mihomo: brew upgrade распаковывает в своей песочнице, а вложенную macOS не дает
        update_proxy = [LOCAL_CLI, "proxy", "run", "--no-sandbox", *via, "--"] if job["proxy"] else []
        out.append((update_proxy + [LOCAL_CLI, "agent-update", "claude"], False))
    if new:
        out.append((["clear"], False))
    if job["mode"] == "slim":
        out.append(([CM, "sessions", "slim", job["session"], "-y", "--notice"], False))
    run = (proxy + (["caffeinate"] + job["caffeinate"] if job["caffeinate"] is not None else []) + [CLAUDE_BIN]
           + (["--session-id", job["new_session"]] if new else ["--resume", job["session"]]) + job["flags"])
    out.append((run, False))
    return out


def shell_line(job):
    """То же задание строкой shell: для истории zsh, лога и AppleScript в Terminal и iTerm2."""
    parts = []
    for argv, quiet in steps(job):
        if argv == ["clear"]:
            parts.append("clear; printf '\\033[3J'")
        else:
            parts.append(shlex.join(argv) + (" >/dev/null 2>&1" if quiet else ""))
    return f"cd {shlex.quote(job['cwd'])} && {{ " + "; ".join(parts) + "; }"


def write(path, job):
    """Положить задание атомарно, права 0600."""
    job = validate(job)
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(job, f, ensure_ascii=False, sort_keys=True)
            f.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    return job


def legacy_hint(text):
    """Задание старой версии было строкой shell. Выполнять его нельзя, но можно подсказать команду."""
    m = re.search(r"--resume[= ]'?([0-9a-f-]{36})", text) or re.search(r"--session-id[= ]'?([0-9a-f-]{36})", text)
    if m and UUID_RE.fullmatch(m.group(1)):
        return f"{CLAUDE_BIN} --resume {m.group(1)}"
    m = re.search(r"--harness codex restart '?([0-9a-f-]{36})", text)
    if m and UUID_RE.fullmatch(m.group(1)):
        return f"agentmeister --harness codex restart {m.group(1)}"
    return None


def read(path):
    """Прочитать и удалить задание. None: его нет или оно старше двух минут. Плохое — JobError."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError as e:
        try:
            os.unlink(path)
        except OSError:
            pass
        raise JobError(f"не открыл задание: {e.strerror or e}")
    try:
        info = os.fstat(fd)
        os.unlink(path)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise JobError("задание не обычный файл этого пользователя")
        if time.time() - info.st_mtime > MAX_AGE:
            return None
        if info.st_size > MAX_SIZE:
            raise JobError("задание слишком большое")
        raw = os.read(fd, MAX_SIZE + 1)
    finally:
        os.close(fd)
    text = raw.decode("utf-8", "replace")
    try:
        job = json.loads(text)
    except ValueError:
        hint = legacy_hint(text)
        raise JobError("задание в старом формате (строка shell), такие больше не выполняются"
                       + (f". Открыть сессию: {hint}" if hint else ""))
    return validate(job)


def take(path, out=None, err=None):
    """Для хука: прочитать задание, напечатать папку и строку для истории через NUL. 1: выполнять нечего."""
    out = out or sys.stdout
    err = err or sys.stderr
    try:
        job = read(path)
    except JobError as e:
        print(f"agentmeister: перезапуск пропущен: {e}", file=err)
        return 1
    if job is None:
        return 1
    out.write("\0".join([job["cwd"], shell_line(job), json.dumps(job, ensure_ascii=False)]))
    out.flush()
    return 0


def run(text):
    """Выполнить проверенное задание из take: шаги по очереди, последний заменяет процесс."""
    try:
        job = validate(json.loads(text))
    except (ValueError, JobError) as e:
        print(f"agentmeister: перезапуск пропущен: {e}", file=sys.stderr)
        return 1
    os.chdir(job["cwd"])
    todo = steps(job)
    try:
        for argv, quiet in todo[:-1]:
            quiet_io = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL} if quiet else {}
            try:
                subprocess.run(argv, **quiet_io)
            except OSError as e:
                if not quiet:
                    print(f"agentmeister: не запустил {argv[0]}: {e}", file=sys.stderr)
            if argv == ["clear"]:
                sys.stdout.write("\033[3J")
                sys.stdout.flush()
    except KeyboardInterrupt:
        return 130
    argv = todo[-1][0]
    # Python игнорирует SIGPIPE и SIGXFSZ, а exec это наследует
    for sig in (signal.SIGPIPE, signal.SIGXFSZ):
        signal.signal(sig, signal.SIG_DFL)
    try:
        os.execvp(argv[0], argv)
    except OSError as e:
        print(f"agentmeister: не запустил {argv[0]}: {e}", file=sys.stderr)
        return 127


def main(args):
    if len(args) == 2 and args[0] == "take":
        return take(args[1])
    if len(args) == 2 and args[0] == "run":
        return run(args[1])
    print("restart_job.py take <файл> | run <json>: вызывает хук share/agentmeister/restart.zsh", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
