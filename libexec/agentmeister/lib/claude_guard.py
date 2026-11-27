import calendar
import datetime
import fcntl
import fnmatch
import hashlib
import json
import os
import re
import shlex
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import BADGES, CACHE, HOME, badge, lang, read_config, tilde, tr, write_config, write_json

LOG = os.path.join(HOME, "Library", "Logs", "mnrh-guard.log")
TAIL = 4 << 20

RULES = {
    "secrets-read": "чтение и правка секретов: .env, *.p8, *.p12, *.jks, *.keystore, приватные ключи SSH, "
                    "service-account/credentials *.json, keystore.properties, .netrc, пароли из связки ключей",
    "secrets-delete": "удаление секретов: rm файла-ключа или папки, где они лежат (~/.ssh, fastlane/ с ключами…), "
                      "security delete-* из связки ключей",
    "destructive": "необратимые команды: git reset --hard, push --force, clean -fd, checkout/restore всего, "
                   "branch -D, rm -r вне проекта, самого проекта или ~, curl | sh, dd на диск, diskutil erase, mkfs, "
                   "chmod -R системных папок; и внутри bash -c, eval, xargs, sudo",
}
# Те же правила по-английски, для окна настроек приложения
RULES_EN = {
    "secrets-read": "Reading or editing .env, .p8, .p12, .jks keys, private SSH keys, credentials and service-account JSON, "
                    ".netrc, .npmrc and keychain passwords",
    "secrets-delete": "Deleting keys or folders that hold them (~/.ssh, ~/.gnupg, ~/.aws, fastlane/ with keys), "
                      "security delete-*",
    "destructive": "git reset --hard, push --force, clean -fd, checkout or restore of everything, branch -D, rm -r outside "
                   "the project, curl | sh, dd to a disk. Finds them inside bash -c, eval, sudo too",
}
GUARD_STATE = os.path.join(CACHE, "guard")
YES = re.compile(r"^\W*(да|ага|угу|ок|окей|ok|okay|yes|y|давай|выполняй|можно|разрешаю|разреши|делай|go|sure|yep|yeah|proceed|confirm|approve|approved|allow)\b", re.I)
SENSITIVE_DIRS = ["~/.ssh", "~/.gnupg", "~/.aws", "~/Library/Keychains", "~/.config/gh"]
DELETERS = {"rm", "rmdir", "unlink", "shred", "srm", "trash"}
WALK_LIMIT = 3000

SECRET_NAMES = [".env", ".env.*", "*.p8", "*.p12", "*.pfx", "*.jks", "*.keystore", "*.pem", "*.key",
                "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "*service-account*.json", "*service_account*.json",
                "*credentials*.json", "credentials", "keystore.properties", "signing.properties", ".netrc",
                ".npmrc", ".pypirc", "*.mobileprovision"]
# имена, по которым видно, что маска Grep ("**/.env*", "id_*") захватит секреты; "*" и "*.*" ищут везде и не в счет
SECRET_SAMPLES = [".env", ".env.local", ".env.production", "id_rsa", "id_ed25519", ".netrc", ".npmrc", "key.p8",
                  "release.jks", "release.keystore"]
CATCH_ALL = {"*", "**", "**/*", "*.*"}
NOT_SECRET = [".env.example", ".env.sample", ".env.template", ".env.dist", "*.pub"]
READERS = {"cat", "less", "more", "head", "tail", "bat", "cp", "scp", "rsync", "base64", "xxd", "hexdump",
           "strings", "grep", "rg", "open", "pbcopy", "sed", "awk", "source", ".", "keytool", "openssl"}


def enabled():
    return read_config().get("guard", "on") != "off"


def sync_badge(on=None):
    """Метка guard во второй строке promptsill, пока защита включена."""
    on = enabled() if on is None else on
    badge("mnrh-guard", {"text": "guard", "color": "green"} if on else None)


def hold_badge(sid, rule):
    """На две минуты в этой сессии: guard остановил вызов."""
    if not sid:
        return
    try:
        for name in os.listdir(BADGES):
            if name.startswith("mnrh-guard_") and time.time() - os.path.getmtime(os.path.join(BADGES, name)) > 600:
                os.remove(os.path.join(BADGES, name))
    except OSError:
        pass
    what = {"secrets-read": tr("чтение секрета", "a secret read"), "secrets-delete": tr("удаление секрета", "a secret delete"),
            "destructive": tr("опасную команду", "a risky command")}.get(rule, rule)
    badge(f"mnrh-guard_{sid[:8]}", {"text": tr(f"остановил {what}", f"held {what}"), "color": "yellow", "session": sid,
                                    "expires": int(time.time() + 120)}, refresh=True)


def skipped():
    return {r.strip() for r in read_config().get("guard_skip", "").split(",") if r.strip()}


def log(line):
    try:
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + line + "\n")
    except OSError:
        pass


def user_secrets():
    """Свои маски секретов: guard_secrets в config через запятую. Маска без "/" сверяется с именем файла
    (*.tfvars), с "/" с полным путем (~/.kube/config, ~/.config/gcloud/ для всей папки)."""
    return [p.strip() for p in read_config().get("guard_secrets", "").split(",") if p.strip()]


def matches_user_secret(path, name):
    full = os.path.abspath(os.path.expanduser(path))
    for pattern in user_secrets():
        if "/" not in pattern:
            if fnmatch.fnmatch(name, pattern):
                return True
            continue
        want = os.path.abspath(os.path.expanduser(pattern))
        if pattern.endswith("/"):
            if full == want or full.startswith(want + "/"):
                return True
        elif fnmatch.fnmatch(full, want):
            return True
    return False


def is_secret(path):
    name = os.path.basename(path.rstrip("/"))
    if not name or any(fnmatch.fnmatch(name, p) for p in NOT_SECRET):
        return False
    if any(fnmatch.fnmatch(name, p) for p in SECRET_NAMES):
        return True
    if matches_user_secret(path, name):
        return True
    full = os.path.expanduser(path)
    for d in ("~/.ssh/", "~/.aws/", "~/.gnupg/", "~/.config/gh/hosts", "~/.claude/.credentials"):
        if full.startswith(os.path.expanduser(d)) and not name.endswith((".pub", "known_hosts", "config")):
            return True
    return False


def subst_end(cmd, i):
    """cmd[i] начинает подстановку: `…`, $(…), <(…) или >(…). -> (конец текста команды, конец подстановки)"""
    n = len(cmd)
    if cmd[i] == "`":
        j = i + 1
        while j < n and cmd[j] != "`":
            j += 2 if cmd[j] == "\\" else 1
        return min(j, n), min(j + 1, n)
    j, depth, quote = i + 2, 1, None
    while j < n:
        c = cmd[j]
        if quote == "'":
            if c == "'":
                quote = None
        elif c == "\\":
            j += 1
        elif c == "`" or cmd[j:j + 2] == "$(":
            j = subst_end(cmd, j)[1]
            continue
        elif quote == '"':
            if c == '"':
                quote = None
        elif c in "'\"":
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j, j + 1
        j += 1
    return n, n


def starts_subst(cmd, i, quote):
    """Начинается ли в cmd[i] подстановка команды; <(…) и >(…) бывают только вне кавычек."""
    two = cmd[i:i + 2]
    return cmd[i] == "`" or two == "$(" or (quote is None and two in ("<(", ">("))


def substitutions(cmd):
    """[(начало, конец, текст команды)] для `…`, $(…), <(…) и >(…) верхнего уровня, в том числе внутри "…"."""
    out, quote, i, n = [], None, 0, len(cmd)
    while i < n:
        c = cmd[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
        elif c == "\\":
            i += 2
        elif starts_subst(cmd, i, quote):
            inner, end = subst_end(cmd, i)
            text = cmd[i + (1 if c == "`" else 2):inner]
            if c == "`":  # внутри `…` \` — это вложенная подстановка, \\ и \$ — обычные символы
                text = re.sub(r"\\([`$\\])", r"\1", text)
            out.append((i, end, text))
            i = end
        elif quote == '"':
            if c == '"':
                quote = None
            i += 1
        elif c in "'\"":
            quote = c
            i += 1
        elif c == "#" and (i == 0 or cmd[i - 1].isspace()):
            while i < n and cmd[i] != "\n":
                i += 1
        else:
            i += 1
    return out


def split_pipelines(cmd):
    """Команды через ;, &&, ||, &, (, ) и перевод строки, каждая — список стадий конвейера через |.
    Разделители в кавычках, после \\, в комментарии # и внутри $(…) и `…` не считаются."""
    commands, stages, cur = [], [], []
    quote, i, n = None, 0, len(cmd)

    def end_stage():
        text = "".join(cur).strip()
        cur.clear()
        if text:
            stages.append(text)

    def end_command():
        end_stage()
        if stages:
            commands.append(list(stages))
        stages.clear()

    while i < n:
        c, two = cmd[i], cmd[i:i + 2]
        if quote != "'" and starts_subst(cmd, i, quote):
            end = subst_end(cmd, i)[1]
            cur.append(cmd[i:end])
            i = end
        elif quote:
            cur.append(c)
            if c == quote:
                quote = None
            elif c == "\\" and quote == '"' and i + 1 < n:
                cur.append(cmd[i + 1])
                i += 1
            i += 1
        elif c in "'\"":
            quote = c
            cur.append(c)
            i += 1
        elif c == "\\" and i + 1 < n:
            cur.append(two)
            i += 2
        elif c == "#" and (not cur or cur[-1].isspace()):
            while i < n and cmd[i] != "\n":
                i += 1
        elif two in ("&&", "||"):
            end_command()
            i += 2
        elif c in ";\n()":
            end_command()
            i += 1
        elif c == "|" and not (cur and cur[-1] == ">"):
            end_stage()
            i += 2 if two == "|&" else 1
        elif c == "&" and not (cur and cur[-1] in "<>") and two != "&>":
            end_command()
            i += 1
        else:
            cur.append(c)
            i += 1
    end_command()
    return commands


def split_segments(cmd):
    return [stage for stages in split_pipelines(cmd) for stage in stages]


def words(segment):
    try:
        return shlex.split(segment, comments=True)
    except ValueError:
        return segment.split()


ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Обертки, после которых идет сама команда, и их ключи со значением: sudo -u root rm → rm
WRAPPERS = {"sudo": {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T"}, "command": set(), "exec": {"-a"},
            "nohup": set(), "time": set(), "env": {"-u", "-S", "-C", "-P"}, "caffeinate": {"-t", "-w"},
            "xargs": {"-n", "-I", "-L", "-P", "-s", "-E", "-d", "-J", "-R", "-S", "-a"}, "nice": {"-n"},
            "timeout": {"-s", "-k"}}


# Слова оболочки перед командой: if rm …; then rm …; fi, { rm …; }, ! rm …
KEYWORDS = {"!", "{", "}", "if", "then", "elif", "else", "while", "until", "do", "noglob", "nocorrect",
            "builtin", "coproc"}


def strip_env(ws):
    ws = list(ws)
    while True:
        i = 0
        while i < len(ws) and (ASSIGN.match(ws[i]) or ws[i] in KEYWORDS):
            i += 1
        ws = ws[i:]
        name = os.path.basename(ws[0]) if ws else ""
        if name not in WRAPPERS:
            return ws
        ws = ws[1:]
        while ws and ws[0].startswith("-") and ws[0] != "-":
            opt = ws.pop(0)
            if opt == "--":
                break
            if opt in WRAPPERS[name] and ws:
                ws.pop(0)
        if name == "timeout" and ws:
            ws = ws[1:]


# $X, ${X}, ${X:-по умолчанию}, ${X:?ошибка}, ${X:+иначе}; дальше прочие ${…} и $1, $@, $?…
VAR = re.compile(r"\$\{([A-Za-z_]\w*)(?:(:?[-=?+])([^}]*))?\}|\$([A-Za-z_]\w*)|\$\{[^}]*\}|\$[0-9@*#?$!-]")
# Чем заменить подстановку команды в слове: сама команда проверяется отдельно, а в слове остается
# неизвестная переменная; $(pwd) — это текущая папка
CMD_SUB = "${__agentmeister_cmd__}"
PWD_SUB = re.compile(r"^(?:\$\(\s*pwd\s*\)|`\s*pwd\s*`)$")


class Unset(Exception):
    pass


def resolve(path, cwd, env, empty=False):
    """Абсолютный путь после подстановки известных переменных; None, если в пути остались неизвестные.
    empty: неизвестные переменные считаются пустыми (или берут значение по умолчанию); тогда None, если путь
    пуст или оболочка не выполнит команду (${X:?})."""
    def sub(m):
        name, op, word = m.group(1) or m.group(4), m.group(2) or "", m.group(3) or ""
        if name in env:
            return word if op.endswith("+") else env[name]
        if not empty:
            return m.group(0)
        if op.endswith(("-", "=")):
            return word
        if op.endswith("?"):
            raise Unset()
        return ""
    try:
        path = VAR.sub(sub, path)
    except Unset:
        return None
    if "$" in path or "`" in path or (empty and not path.strip()):
        return None
    path = os.path.expanduser(path)
    return os.path.normpath(os.path.join(cwd, path))


def assigned(value, cwd, env):
    if value.startswith(("/", "~", "$", ".")):
        return resolve(value, cwd, env) or value
    return value


def check_secrets_cmd(ws, segment):
    if not ws:
        return None
    exe = os.path.basename(ws[0])
    if exe == "security" and len(ws) > 1 and (ws[1] == "dump-keychain" or
                                               (ws[1].startswith("find-") and ("-w" in ws or "-g" in ws))):
        return "secrets-read", tr("пароль из связки ключей попадёт в переписку", "a keychain password would end up in the conversation")
    if exe in READERS:
        for w in ws[1:]:
            if not w.startswith("-") and is_secret(w):
                return "secrets-read", f"{exe} {tilde(os.path.expanduser(w))}: " + tr("содержимое секрета попадёт в переписку",
                                                                                        "the secret's contents would end up in the conversation")
    for m in re.finditer(r"<\s*([^\s<>|;&]+)", segment):
        if is_secret(m.group(1)):
            return "secrets-read", tr(f"чтение {m.group(1)}: содержимое секрета попадёт в переписку",
                                      f"reading {m.group(1)}: the secret's contents would end up in the conversation")
    return None


def holds_secrets(path):
    full = os.path.realpath(path)
    for d in SENSITIVE_DIRS:
        d = os.path.realpath(os.path.expanduser(d))
        if full == d or d.startswith(full.rstrip("/") + "/"):
            return tilde(d) + "/"
        if full.startswith(d + "/"):
            return tilde(path)
    if os.path.isfile(path):
        return tilde(path) if is_secret(path) else None
    if not os.path.isdir(path):
        return tilde(path) if is_secret(path) else None
    seen = 0
    for root, dirs, files in os.walk(path):
        dirs[:] = [x for x in dirs if x not in ("node_modules", ".git", "build", ".gradle", "Pods", "DerivedData")]
        for f in files:
            seen += 1
            if is_secret(os.path.join(root, f)):
                return tilde(os.path.join(root, f))
        if seen > WALK_LIMIT or root.count(os.sep) - path.count(os.sep) >= 4:
            dirs[:] = []
    return None


def check_secret_delete(ws, cwd, env):
    exe = os.path.basename(ws[0])
    if exe == "security" and len(ws) > 1 and ws[1].startswith("delete-"):
        return "secrets-delete", tr(f"security {ws[1]} удалит запись из связки ключей", f"security {ws[1]} deletes a keychain item")
    if exe not in DELETERS:
        return None
    for t in ws[1:]:
        if t.startswith("-"):
            continue
        p, unknown = resolve(t, cwd, env), False
        if p is None:  # неизвестная переменная: путь, каким он станет, если она пуста
            p, unknown = resolve(t, cwd, env, empty=True), True
            if p is None:
                continue
        found = holds_secrets(p)
        if found:
            what = (tr(f"папка с ключами {found}", f"the key folder {found}") if found.endswith("/") else
                    tr("это секрет", "it's a secret") if found == tilde(p) else tr(f"там секрет: {found}", f"a secret is inside: {found}"))
            lost = tr("восстановить не получится", "it can't be restored")
            if unknown:
                return "secrets-delete", tr(f"{exe} {t}: значение переменной неизвестно, а если она пуста, это "
                                            f"{exe} {tilde(p)} — {what}, {lost}",
                                            f"{exe} {t}: the variable's value is unknown, and if it's empty this is "
                                            f"{exe} {tilde(p)}, {what}, {lost}")
            return "secrets-delete", tr(f"{exe} {tilde(p)} — {what}, {lost}", f"{exe} {tilde(p)}: {what}, {lost}")
    return None


def short_flags(args):
    """Буквы коротких ключей до --: ['-fd', '-x'] → {'f', 'd', 'x'}."""
    letters = set()
    for a in args:
        if a == "--":
            break
        if a.startswith("-") and not a.startswith("--") and len(a) > 1:
            letters |= set(a[1:])
    return letters


def positional(args):
    """Аргументы, кроме ключей; после -- все."""
    out, dash = [], False
    for a in args:
        if dash or not a.startswith("-") or a == "-":
            out.append(a)
        elif a == "--":
            dash = True
    return out


def within(path, base, strict=False):
    """path совпадает с base или лежит внутри (strict: только внутри). Сравнивает и как есть, и после realpath."""
    for p, b in ((path, base), (os.path.realpath(path), os.path.realpath(base))):
        b = b.rstrip("/") or "/"
        if p.startswith(b if b == "/" else b + "/") or (not strict and p == b):
            return True
    return False


def project_of(cwd):
    """Корень git-репозитория над cwd, иначе сам cwd. Домашняя папка проектом не считается (там бывает dotfiles)."""
    d = cwd
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            break
        parent = os.path.dirname(d)
        if parent == d:
            return cwd
        d = parent
    return cwd if within(HOME, d) else d


# rm -r здесь не спрашиваем: временные папки и кеши.
# Системные временные папки — только их содержимое (/tmp/x, /tmp/*): саму /tmp или $TMPDIR удалять нельзя.
TEMP_DIRS = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders", os.environ.get("TMPDIR") or "/tmp"]
# Кеши пользователя можно и целиком: программы создают их заново
CACHE_DIRS = [os.path.join(HOME, "Library", "Caches"), os.path.join(HOME, ".cache"),
              os.path.join(HOME, "Library", "Developer", "Xcode", "DerivedData")]
SYSTEM_DIRS = {"/", "/System", "/Library", "/Applications", "/Users", "/usr", "/usr/local", "/bin", "/sbin", "/etc",
               "/var", "/private", "/opt", "/opt/homebrew", HOME, os.path.join(HOME, "Library")}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish"}
INTERPRETER = re.compile(r"^(?:python[\d.]*|perl|ruby|node)$")
FROM_NET = re.compile(r"[<$]\(\s*(?:\S*/)?(?:curl|wget)\b")
DISK_DEV = re.compile(r"^of=/dev/(?:r?disk\d|sd[a-z]|nvme|hd[a-z]|mmcblk|vd[a-z]|xvd|loop|md\d|mapper/)")
ERASE = {"secureerase", "zerodisk", "randomdisk", "partitiondisk", "reformat"}


def runs_stdin(ws):
    """Интерпретатор, который выполнит скрипт со стандартного ввода: curl … | sh, но не | python3 -m json.tool."""
    exe = os.path.basename(ws[0]) if ws else ""
    shell = exe in SHELLS
    if not shell and not INTERPRETER.match(exe):
        return False
    for a in ws[1:]:
        if a == "-":
            return True
        if a == "--":
            continue
        if a.startswith("--"):
            if a in ("--eval", "--print", "--command"):
                return False
            continue
        if a.startswith("-"):
            if shell and "s" in a[1:]:
                return True
            if (shell and "c" in a[1:]) or (not shell and a[1:2] in ("c", "m", "e", "E", "p")):
                return False
            continue
        return False
    return True


def shell_script(ws):
    """Текст команды из bash -c '…' и eval …, иначе None."""
    exe = os.path.basename(ws[0])
    if exe == "eval":
        return " ".join(ws[1:]) or None
    if exe not in SHELLS:
        return None
    has_c = False
    for a in ws[1:]:
        if a.startswith("--"):
            continue
        if a.startswith("-") and len(a) > 1:
            has_c = has_c or "c" in a[1:]
            continue
        return a if has_c else None
    return None


def whole_tree(spec, cwd, env):
    """Путь git, который накрывает всю рабочую папку (или cwd целиком): ., :/, *, .."""
    if spec in (":/", ":", ":/.", ":/*", "*", ":(top)"):
        return True
    p = resolve(spec, cwd, env)
    return p is not None and within(cwd, p)


def check_git(ws, cwd, env):
    args, i = ws[1:], 0
    while i < len(args) and args[i].startswith("-"):
        if args[i] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace") and i + 1 < len(args):
            if args[i] == "-C":
                cwd = resolve(args[i + 1], cwd, env) or cwd
            i += 2
        else:
            i += 1
    if i >= len(args):
        return None
    sub, rest = args[i], args[i + 1:]
    flags, longs, paths = short_flags(rest), set(rest[:rest.index("--")] if "--" in rest else rest), positional(rest)
    lost = tr("восстановить не получится", "they can't be restored")
    if sub == "reset" and "--hard" in longs:
        return tr(f"git reset --hard сотрёт незакоммиченные правки, {lost}", f"git reset --hard wipes uncommitted changes, {lost}")
    if sub == "push":
        force = next((a for a in rest if a == "--force" or a.startswith(("--force-with-lease", "--force-if-includes"))),
                     "-f" if "f" in flags else next((f"+{a[1:]}" for a in paths if a.startswith("+")), None))
        if force:
            return tr(f"git push {force} перепишет ветку на сервере, чужие коммиты там пропадут",
                      f"git push {force} rewrites the branch on the server, other people's commits there will be lost")
    if sub == "clean" and ("f" in flags or "--force" in longs) and flags & {"d", "x", "X"} and \
            "n" not in flags and "--dry-run" not in longs:
        ignored = tr(" и всё из .gitignore (.env, локальные настройки)", " and everything in .gitignore (.env, local settings)") \
            if flags & {"x", "X"} else ""
        return tr(f"git clean удалит неотслеживаемые файлы и папки{ignored}; их нет в git, {lost}",
                  f"git clean deletes untracked files and folders{ignored}; they aren't in git, {lost}")
    if sub == "checkout" and ("f" in flags or "--force" in longs):
        return tr(f"git checkout --force отменит все незакоммиченные правки, {lost}",
                  f"git checkout --force discards all uncommitted changes, {lost}")
    if sub in ("checkout", "restore"):
        staged_only = ("S" in flags or "--staged" in longs) and not ("W" in flags or "--worktree" in longs)
        spec = next((p for p in paths if whole_tree(p, cwd, env)), None)
        if spec and not (sub == "restore" and staged_only):
            return tr(f"git {sub} {spec} отменит все незакоммиченные правки в {tilde(cwd)}, {lost}",
                      f"git {sub} {spec} discards all uncommitted changes in {tilde(cwd)}, {lost}")
    if sub == "branch" and ("D" in flags or (("d" in flags or "--delete" in longs) and
                                             ("f" in flags or "--force" in longs))):
        return tr("git branch -D удалит ветку, даже если она никуда не влита", "git branch -D deletes the branch even if it isn't merged anywhere")
    return None


def check_rm(ws, cwd, env, root):
    args = ws[1:]
    if not (short_flags(args) & {"r", "R"} or "--recursive" in args):
        return None
    for t in positional(args):
        p, unknown = resolve(t, cwd, env), False
        if p is None:
            # rm -rf "$DIR"/ с пустой $DIR удалит /: проверяем путь, каким он станет без неизвестных переменных
            p, unknown = resolve(t, cwd, env, empty=True), True
            if p is None:
                continue
        glob = False  # rm -rf /tmp/* удаляет содержимое папки, а не её саму
        while os.path.basename(p) in ("*", ".*"):
            p, glob = os.path.dirname(p), True
        if p == "/":
            what = tr("это корень диска", "it's the disk root")
        elif within(HOME, p):
            what = tr("это домашняя папка", "it's the home folder") if p == HOME else tr("внутри домашняя папка", "the home folder is inside")
        elif os.path.normpath(p) == root or os.path.realpath(p) == os.path.realpath(root):
            what = tr("это сам проект", "it's the project itself")
        elif within(p, root) and not within(HOME, root):
            continue
        elif any(within(p, d) for d in CACHE_DIRS) or any(within(p, d, strict=not glob) for d in TEMP_DIRS) and (
                glob or not any(within(p, d) and within(d, p) for d in TEMP_DIRS)):
            continue
        else:
            what = tr(f"проекта нет, Claude запущен в {tilde(root)}", f"there's no project, Claude runs in {tilde(root)}") \
                if within(HOME, root) else tr(f"это вне проекта {tilde(root)}", f"it's outside the project {tilde(root)}")
        lost = tr("восстановить не получится", "it can't be restored")
        if unknown:
            return tr(f"rm -r {t}: значение переменной неизвестно, а если она пуста, это rm -r {tilde(p)} — {what}, {lost}",
                      f"rm -r {t}: the variable's value is unknown, and if it's empty this is rm -r {tilde(p)}, {what}, {lost}")
        return tr(f"rm -r {tilde(p)} — {what}, {lost}", f"rm -r {tilde(p)}: {what}, {lost}")
    return None


def check_destructive(ws, seg, cwd, env, root):
    exe = os.path.basename(ws[0])
    if exe == "git":
        return check_git(ws, cwd, env)
    if exe == "rm":
        return check_rm(ws, cwd, env, root)
    if (exe in SHELLS or INTERPRETER.match(exe) or exe in ("source", ".")) and FROM_NET.search(seg):
        return tr(f"{exe} выполнит скрипт прямо из сети, не глядя", f"{exe} runs a script straight from the network, unseen")
    if exe == "dd":
        dev = next((a for a in ws[1:] if DISK_DEV.match(a)), None)
        if dev:
            return tr(f"dd {dev} перезапишет диск, данные на нём пропадут", f"dd {dev} overwrites the disk, its data will be lost")
    if exe == "diskutil" and len(ws) > 1:
        sub = ws[1].lower()
        if sub.startswith("erase") or sub in ERASE or (sub == "apfs" and len(ws) > 2 and
                                                        ws[2].lower().startswith(("delete", "erase"))):
            what = ' '.join(ws[1:3] if sub == 'apfs' else ws[1:2])
            return tr(f"diskutil {what} сотрёт диск или раздел", f"diskutil {what} erases a disk or volume")
    if exe == "mkfs" or exe.startswith(("mkfs.", "newfs")):
        return tr(f"{exe} отформатирует раздел, данные на нём пропадут", f"{exe} formats a volume, its data will be lost")
    if exe in ("chmod", "chown", "chgrp") and "R" in short_flags(ws[1:]):
        for t in positional(ws[1:])[1:]:
            p = resolve(t, cwd, env)
            if p in SYSTEM_DIRS:
                return tr(f"{exe} -R {tilde(p)} поменяет права во всей папке, вернуть как было не получится",
                          f"{exe} -R {tilde(p)} changes permissions across the whole folder, they can't be put back")
    return None


def scan_bash(cmd, cwd, env, root, depth=0):
    """Находки (правило, почему) по порядку команд."""
    for stages in split_pipelines(cmd):
        fetched = False
        for seg in stages:
            # $(…) и `…` выполняются раньше самой команды; в её словах вместо них неизвестная переменная
            masked, last = [], 0
            for start, end, inner in substitutions(seg):
                if depth < 5:
                    yield from scan_bash(inner, cwd, dict(env), root, depth + 1)
                masked += [seg[last:start], "$PWD" if PWD_SUB.match(seg[start:end]) else CMD_SUB]
                last = end
            raw = words("".join(masked) + seg[last:])
            for w in raw:
                m2 = re.match(r"^([A-Za-z_]\w*)=(.*)$", w)
                if not m2:
                    break
                env[m2.group(1)] = assigned(m2.group(2), cwd, env)
            ws = strip_env(raw)
            if not ws:
                continue
            if ws[0] == "export":
                for w in ws[1:]:
                    m2 = re.match(r"^([A-Za-z_]\w*)=(.*)$", w)
                    if m2:
                        env[m2.group(1)] = assigned(m2.group(2), cwd, env)
                continue
            if ws[0] == "cd" and len(ws) > 1:
                nxt = resolve(ws[1], cwd, env)
                if nxt:
                    cwd = env["PWD"] = nxt
                continue
            for found in (check_secret_delete(ws, cwd, env), check_secrets_cmd(ws, seg)):
                if found:
                    yield found
            why = check_destructive(ws, seg, cwd, env, root)
            if not why and fetched and runs_stdin(ws):
                why = tr(f"curl | {os.path.basename(ws[0])} выполнит скрипт прямо из сети, не глядя",
                         f"curl | {os.path.basename(ws[0])} runs a script straight from the network, unseen")
            if why:
                yield "destructive", why
            fetched = fetched or os.path.basename(ws[0]) in ("curl", "wget")
            script = shell_script(ws)
            if script and depth < 3:
                yield from scan_bash(script, cwd, dict(env), root, depth + 1)


def check_bash(cmd, cwd, skip=()):
    env = {"HOME": HOME, "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "PWD": cwd}
    return next((f for f in scan_bash(cmd, cwd, env, project_of(cwd)) if f[0] not in skip), None)


def check(tool, inp, cwd, skip=()):
    """(правило, почему) для первого правила, которое не в skip, или None."""
    cwd = os.path.normpath(cwd or os.getcwd())
    if tool == "Bash":
        return check_bash(str(inp.get("command") or ""), cwd, skip)
    if tool == "apply_patch":
        for kind, path in re.findall(r"^\*\*\* (Add File|Update File|Delete File|Move to): (.+)$",
                                     str(inp.get("command") or ""), re.M):
            path = os.path.normpath(os.path.join(cwd, os.path.expanduser(path.strip())))
            if is_secret(path):
                rule = "secrets-delete" if kind == "Delete File" else "secrets-read"
                if rule not in skip:
                    return rule, tr(f"правка файла с секретом {tilde(path)}", f"editing the secret file {tilde(path)}")
        return None
    found = None
    if tool == "Grep":
        # Grep с output_mode content выводит строки файла в переписку так же, как Read
        path, mask = str(inp.get("path") or ""), str(inp.get("glob") or "")
        name = mask[3:] if mask.startswith("**/") else mask
        if (path and is_secret(path)) or (name and (is_secret(name) or name not in CATCH_ALL and any(
                fnmatch.fnmatch(sample, name) for sample in SECRET_SAMPLES))):
            found = "secrets-read", tr(f"поиск в {tilde(path or mask)}: это секрет, найденные строки попадут в переписку",
                                       f"searching {tilde(path or mask)}: it's a secret, matching lines would end up in the conversation")
    path = inp.get("file_path") or inp.get("notebook_path") or ""
    if tool in ("Read", "Edit", "Write", "MultiEdit", "NotebookEdit") and path and is_secret(path):
        if tool == "Read":
            found = "secrets-read", tr(f"чтение {tilde(path)}: это секрет, его содержимое попадёт в переписку",
                                       f"reading {tilde(path)}: it's a secret, its contents would end up in the conversation")
        else:
            found = "secrets-read", tr(f"правка {tilde(path)}: это секрет, его содержимое попадёт в переписку",
                                       f"editing {tilde(path)}: it's a secret, its contents would end up in the conversation")
    return found if found and found[0] not in skip else None


def call_key(sid, tool, inp):
    raw = json.dumps([sid, tool, inp.get("command") or inp.get("file_path") or inp.get("path") or inp.get("glob")
                      or ""], sort_keys=True)
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def pending_path(sid):
    return os.path.join(GUARD_STATE, re.sub(r"[^\w-]", "_", sid or "none") + ".json")


def load_pending(sid):
    try:
        with open(pending_path(sid)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_pending(sid, data):
    os.makedirs(GUARD_STATE, exist_ok=True)
    data = {k: v for k, v in data.items() if time.time() - v < 3600}
    path = pending_path(sid)
    write_json(path, data)


def last_user(path, codex=False):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - TAIL))
            chunk = f.read()
    except (OSError, TypeError):
        return "", 0
    for raw in reversed(chunk.split(b"\n")):
        if b'"user"' not in raw and not (codex and b'"user_message"' in raw):
            continue
        try:
            o = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            continue
        if codex:
            message = o.get("payload") or {}
            if o.get("type") == "response_item" and message.get("type") == "message" and message.get("role") == "user":
                blocks = message.get("content") or []
                text = blocks[0].get("text", "") if len(blocks) == 1 and blocks[0].get("type") == "input_text" else ""
            elif o.get("type") == "event_msg" and message.get("type") == "user_message":
                text = message.get("message", "")
            else:
                continue
            try:
                ts = datetime.datetime.fromisoformat(o["timestamp"].replace("Z", "+00:00")).timestamp()
            except (KeyError, ValueError, TypeError):
                ts = 0
            return text if isinstance(text, str) else "", ts
        if o.get("type") != "user" or o.get("isMeta") or o.get("isCompactSummary"):
            continue
        c = (o.get("message") or {}).get("content")
        text = c if isinstance(c, str) else "\n".join(
            b.get("text", "") for b in c or [] if isinstance(b, dict) and b.get("type") == "text") if isinstance(c, list) else ""
        if not text:
            continue
        try:
            ts = calendar.timegm(time.strptime(o.get("timestamp", "")[:19], "%Y-%m-%dT%H:%M:%S"))
        except ValueError:
            ts = 0
        return text, ts
    return "", 0


def codex_decision(payload, rule, why):
    sid = payload.get("session_id")
    reason = {"permissionDecision": "deny", "permissionDecisionReason": f"agentmeister guard: {why}"}
    if not sid:
        return reason
    # Bind confirmation to the directory and full input, including every file in a patch.
    request = [sid, payload.get("agent_id"), payload.get("cwd"), payload.get("tool_name"), payload["tool_input"]]
    key = hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()[:16]
    state_id = "codex-" + sid
    now = time.time()
    os.makedirs(GUARD_STATE, mode=0o700, exist_ok=True)
    with open(os.path.join(GUARD_STATE, "codex.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        pending = {k: v for k, v in load_pending(state_id).items() if now - v < 3600}
        reply, stamp = last_user(payload.get("transcript_path"), codex=True)
        answer = reply.strip().casefold()
        if (key in pending and stamp > pending[key] and
                (answer in ("да " + key, "yes " + key) or
                 (len(pending) == 1 and answer in ("да", "yes")))):
            del pending[key]
            save_pending(state_id, pending)
            log(f"allow {rule:<14} Codex {key}")
            return None
        pending[key] = now
        save_pending(state_id, pending)
        reply = tr("да", "yes") + (" " + key if len(pending) > 1 else "")
    log(f"hold  {rule:<14} Codex {key}")
    hold_badge(sid, rule)
    reason["permissionDecisionReason"] += tr(
        f'. Спроси у пользователя, разрешает ли он этот вызов. После ответа "{reply}" повтори его.',
        f'. Ask the user to confirm this exact action with "{reply}", then retry.')
    return reason


def decide(payload, codex=False):
    tool = payload.get("tool_name") or ""
    inp = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    found = check(tool, inp, payload.get("cwd"), skipped())
    if not found:
        return None
    rule, why = found
    if codex or "turn_id" in payload:
        return codex_decision(payload, rule, why)
    mode = payload.get("permission_mode") or "default"
    what = str(inp.get("command") or inp.get("file_path") or "")[:200].replace("\n", " ")
    if mode not in ("bypassPermissions", "auto", "dontAsk"):
        log(f"ask   {rule:<14} {what}")
        hold_badge(payload.get("session_id"), rule)
        return {"permissionDecision": "ask", "permissionDecisionReason": f"agentmeister guard: {why}"}
    sid = payload.get("session_id")
    key = call_key(sid, tool, inp)
    pending = load_pending(sid)
    text, ts = last_user(payload.get("transcript_path"))
    if key in pending and ts > pending[key] and YES.search(text.strip()):
        pending.pop(key)
        save_pending(sid, pending)
        log(f"allow {rule:<14} {what}")
        return {"permissionDecision": "allow", "permissionDecisionReason": "agentmeister guard: " + tr("пользователь разрешил", "the user allowed it")}
    pending[key] = time.time()
    save_pending(sid, pending)
    log(f"hold  {rule:<14} {what}")
    hold_badge(sid, rule)
    return {"permissionDecision": "deny", "permissionDecisionReason": f"agentmeister guard: {why}. " + tr(
        "Это не отказ: спроси пользователя одним коротким вопросом, выполнить ли это, и объясни "
        "зачем. Если он ответит «да» — повтори ровно этот же вызов, и он пройдёт. Если нет — не делай и не ищи "
        "обходной путь.",
        "This isn't a refusal: ask the user in one short question whether to do this, and explain why. If they "
        "answer yes, repeat exactly the same call and it will go through. If not, don't do it and don't look for a "
        "workaround.")}


def hook():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    on = enabled()
    sync_badge(on)
    if not isinstance(payload, dict) or not on:
        return 0
    try:
        out = decide(payload, "--codex" in sys.argv)
    except Exception as e:
        log(f"error {e!r}")
        if "--codex" not in sys.argv and "turn_id" not in payload:
            return 0
        out = {"permissionDecision": "deny", "permissionDecisionReason": "Agentmeister guard could not check this call."}
    if out:
        print(json.dumps({"hookSpecificOutput": dict({"hookEventName": "PreToolUse"}, **out)}, ensure_ascii=False))
    return 0


def usage():
    print(tr("""agentmeister guard                   состояние и правила
agentmeister guard on | off          включить или выключить совсем
agentmeister guard skip <правило>    не проверять правило; unskip <правило> — вернуть
agentmeister guard secret add <маска>  свой секрет: *.tfvars, ~/.kube/config, ~/.config/gcloud/; remove убирает
agentmeister guard test '<команда>'  что сделает guard с этой командой (в папке, где запущен)
agentmeister guard log               последние решения

Хук PreToolUse следит за чтением и удалением секретов и ключей и за необратимыми командами
(git reset --hard, push --force, rm -r вне проекта, curl | sh…). В обычном режиме Claude Code
спросит разрешение сам. В auto Claude спросит тебя в чате: ответишь «да» — этот вызов пройдёт.""",
             """agentmeister guard                   state and rules
agentmeister guard on | off          turn on or off entirely
agentmeister guard skip <rule>       don't check a rule; unskip <rule> brings it back
agentmeister guard secret add <mask>  your own secret: *.tfvars, ~/.kube/config, ~/.config/gcloud/; remove drops it
agentmeister guard test '<command>'  what guard does with this command (in the current folder)
agentmeister guard log               recent decisions

The PreToolUse hook watches for reading and deleting secrets and keys and for irreversible commands
(git reset --hard, push --force, rm -r outside the project, curl | sh…). In the default mode Claude Code
asks for permission itself. In auto mode Claude asks you in the chat: answer yes and that call goes through."""))


def status():
    skip = skipped()
    print(tr(f"agentmeister guard: {'включён' if enabled() else 'выключен'}. Лог: {tilde(LOG)}",
             f"agentmeister guard: {'on' if enabled() else 'off'}. Log: {tilde(LOG)}"))
    for rule, text in (RULES_EN if lang() == "en" else RULES).items():
        mark = tr("  выкл", "  off ") if rule in skip else tr("  вкл ", "  on  ")
        print(f"{mark} {rule:<11} {text}")


def main():
    args = sys.argv[1:]
    if args[:1] == ["guard-hook"]:
        return hook()
    rest = args[1:]
    if not rest:
        status()
        return 0
    cmd = rest[0]
    if cmd in ("-h", "--help"):
        usage()
        return 0
    if cmd in ("on", "off"):
        write_config(guard=cmd)
        sync_badge(cmd == "on")
        print(tr(f"agentmeister guard {'включён' if cmd == 'on' else 'выключен'}", f"agentmeister guard {cmd}"))
        return 0
    if cmd in ("skip", "unskip") and len(rest) == 2:
        if rest[1] not in RULES:
            print(tr(f"Нет правила «{rest[1]}». Есть: {', '.join(RULES)}", f"No rule \"{rest[1]}\". Rules: {', '.join(RULES)}"),
                  file=sys.stderr)
            return 2
        skip = skipped()
        skip = skip | {rest[1]} if cmd == "skip" else skip - {rest[1]}
        write_config(guard_skip=",".join(sorted(skip)))
        print(tr(f"Правило {rest[1]} {'выключено' if cmd == 'skip' else 'включено'}",
                 f"Rule {rest[1]} {'off' if cmd == 'skip' else 'on'}"))
        return 0
    if cmd == "secret":
        own = user_secrets()
        if len(rest) == 3 and rest[1] in ("add", "remove"):
            pattern = rest[2].strip()
            if not pattern or "," in pattern:
                print(tr("Маска без запятых: *.tfvars или ~/.kube/config", "A pattern without commas: *.tfvars or ~/.kube/config"),
                      file=sys.stderr)
                return 2
            own = own + [pattern] if rest[1] == "add" and pattern not in own else [p for p in own if p != pattern]
            write_config(guard_secrets=",".join(own) or None)
        elif len(rest) != 1:
            print("agentmeister guard secret [add|remove <маска>]", file=sys.stderr)
            return 2
        print(tr("Свои секреты: ", "Your secrets: ") + (", ".join(own) if own else tr("нет", "none")))
        return 0
    if cmd == "test" and len(rest) >= 2:
        text = " ".join(rest[1:])
        tool, inp = ("Read", {"file_path": text}) if not re.search(r"\s", text) and is_secret(text) else \
            ("Bash", {"command": text})
        found = check(tool, inp, os.getcwd())
        if not found:
            print(tr("пропущу", "would allow"))
        else:
            off = tr(", правило выключено", ", rule is off") if found[0] in skipped() else ""
            print(tr(f"остановлю ({found[0]}{off}): {found[1]}", f"would hold ({found[0]}{off}): {found[1]}"))
        return 0
    if cmd == "log":
        try:
            with open(LOG) as f:
                print("".join(f.readlines()[-30:]), end="")
        except OSError:
            print(tr("Лог пуст.", "The log is empty."))
        return 0
    usage()
    return 2


if __name__ == "__main__":
    sys.exit(main())
