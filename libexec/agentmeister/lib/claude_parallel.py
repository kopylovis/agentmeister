import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import CLAUDE_HOME, find_project, projects_dir, tilde, tr

TRANSLIT = dict(zip("абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
                    ["a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "y", "k", "l", "m", "n", "o", "p", "r", "s",
                     "t", "u", "f", "h", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya"]))
# Без своего .worktreeinclude в проекте копируем неотслеживаемые файлы по этому списку, как раньше
COPY = ["local.properties", ".env", ".env.*", "fastlane/.env", "fastlane/.env.*"]


def git(root, *args, check=False):
    r = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, timeout=120)
    if check and r.returncode:
        raise RuntimeError((r.stderr or r.stdout).strip() or tr(f"git {' '.join(args)} упал", f"git {' '.join(args)} failed"))
    return r.stdout.strip()


def slug(text):
    low = "".join(TRANSLIT.get(ch, ch) for ch in text.lower())
    out = ""
    for w in re.findall(r"[a-z0-9]+", low):
        if len(out) + len(w) + 1 > 28:
            break
        out = f"{out}-{w}" if out else w
    return out or time.strftime("task-%m%d-%H%M")


def worktree_root(root):
    return os.path.join(projects_dir(), ".worktrees", os.path.basename(root.rstrip("/")))


def worktree_include(root):
    """Файлы по .worktreeinclude, как их берёт Claude Code для своих worktree: шаблоны в синтаксисе .gitignore,
    и только то, что git игнорирует, так что отслеживаемое не дублируется. None, если файла нет."""
    inc = os.path.join(root, ".worktreeinclude")
    if not os.path.isfile(inc):
        return None
    r = subprocess.run(["git", "-C", root, "ls-files", "-z", "--others", "--ignored", f"--exclude-from={inc}"],
                       capture_output=True, text=True, timeout=120)
    if r.returncode or not r.stdout:
        return []
    r = subprocess.run(["git", "-C", root, "check-ignore", "-z", "--stdin"], input=r.stdout,
                       capture_output=True, text=True, timeout=120)
    return sorted(f for f in r.stdout.split("\0") if f)


def copy_local(root, path):
    """-> (скопированные пути, взяты ли они по .worktreeinclude)"""
    files = worktree_include(root)
    native = files is not None
    if not native:
        files = []
        for pattern in COPY:
            for src in glob.glob(os.path.join(glob.escape(root), pattern)):
                rel = os.path.relpath(src, root)
                if not git(root, "ls-files", rel):
                    files.append(rel)
    copied = []
    for rel in files:
        src, dst = os.path.join(root, rel), os.path.join(path, rel)
        if os.path.isfile(src) and not os.path.lexists(dst):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
            copied.append(rel)
    return copied, native


PERMISSION_MODES = ["default", "acceptEdits", "auto", "plan"]


def prepare(task, project=None, branch=None, cwd=None, sid=None):
    """Ветка, worktree и первый запрос для второго Claude, без открытия окна. Возвращает (dict, None) или
    (None, ошибка). dict: root, path, branch, base, task, prompt, flags (для claude после --), copied, native, dirty."""
    root, err = find_project(project, cwd)
    if err:
        return None, err
    if not git(root, "rev-parse", "--git-dir"):
        return None, tr(f"{tilde(root)} — не git-репозиторий, worktree не сделать",
                        f"{tilde(root)} is not a git repository, can't make a worktree")
    task = " ".join((task or "").split())
    if not task:
        return None, tr("Нужна задача: что сделать параллельно", "A task is required: what to do in parallel")
    base = git(root, "branch", "--show-current") or git(root, "rev-parse", "--short", "HEAD")
    name = branch or f"parallel/{slug(task)}"
    if git(root, "rev-parse", "--verify", "--quiet", f"refs/heads/{name}"):
        name = f"{name}-{time.strftime('%H%M%S')}"
    path = os.path.join(worktree_root(root), name.replace("/", "-"))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        git(root, "worktree", "add", "-b", name, path, "HEAD", check=True)
    except RuntimeError as e:
        return None, tr(f"Не создал worktree: {e}", f"Couldn't create the worktree: {e}")
    git(root, "config", f"branch.{name}.mnrhBase", base)
    git(root, "config", f"branch.{name}.mnrhTask", task)
    copied, native = copy_local(root, path)
    dirty = git(root, "status", "--porcelain")
    rules = tr(f"Работай только в этой папке. Если нужны зависимости (node_modules и т. п.), поставь их здесь. "
               f"Когда закончишь, закоммить результат в ветку {name} (не сливай и не пушь) и коротко отчитайся, "
               f"что сделано и как проверить.",
               f"Work only in this folder. If you need dependencies (node_modules and so on), install them here. "
               f"When you're done, commit the result to the branch {name} (don't merge or push) and briefly report "
               f"what was done and how to check it.")
    if sid:
        prompt = tr(f"Это форк разговора выше для параллельной задачи. Теперь ты в отдельном git worktree {path}, "
                    f"ветка {name}, ответвлена от {base} проекта {root}. Всё, что было выше, — контекст; файлы в "
                    f"{root} больше не трогай. Задача: {task}\n\n{rules}",
                    f"This is a fork of the conversation above for a parallel task. You are now in a separate git "
                    f"worktree {path}, branch {name}, branched from {base} of the project {root}. Everything above is "
                    f"context; don't touch the files in {root} anymore. Task: {task}\n\n{rules}")
    else:
        prompt = tr(f"Это параллельная задача в отдельном git worktree {path}, ветка {name}, ответвлена от {base} "
                    f"проекта {root}. Задача: {task}\n\n{rules}",
                    f"This is a parallel task in a separate git worktree {path}, branch {name}, branched from {base} "
                    f"of the project {root}. Task: {task}\n\n{rules}")
    # --resume по id ищет сессию и в git worktree проекта, а форк начинается в папке запуска
    flags = ["--resume", sid, "--fork-session"] if sid else []
    return {"root": root, "path": path, "branch": name, "base": base, "task": task, "prompt": prompt, "flags": flags,
            "copied": copied, "native": native, "dirty": bool(dirty)}, None


def start(task, project=None, branch=None, mode=None, cwd=None, cm=None, permission=None, rc=None,
          fork=False):
    import session_defaults
    mode = mode or session_defaults.open_mode()
    rc = session_defaults.remote_control() if rc is None else rc
    sid = None
    if fork:
        import claude_proc
        sid = claude_proc.current_sid()
        if not sid:
            return tr("Форк возможен только изнутри сессии Claude Code (/parallel или MCP): "
                      "не нашёл, какая сессия сейчас идёт.",
                      "A fork works only from inside a Claude Code session (/parallel or MCP): "
                      "couldn't find which session is running."), True
    job, err = prepare(task, project, branch, cwd, sid)
    if err:
        return err, True
    root, path, name, base, prompt = job["root"], job["path"], job["branch"], job["base"], job["prompt"]
    copied, native, dirty = job["copied"], job["native"], job["dirty"]
    import claude_open
    flags = job["flags"] + (["--permission-mode", permission]
                            if permission in PERMISSION_MODES and permission != "default" else [])
    text, bad = claude_open.open_claude({"placement": "window", "path": path, "mode": mode, "prompt": prompt, "flags": flags,
                                         "trust": claude_open.trusted(root), "remote_control": rc, "subtask": True,
                                         "name": f"{os.path.basename(root.rstrip('/'))} · {name}"},
                                        cm or "agentmeister")
    lines = [tr(f"Ветка {name} от {base}, worktree {tilde(path)}.", f"Branch {name} from {base}, worktree {tilde(path)}.")]
    if sid:
        lines.append(tr(f"Второй Claude продолжает эту переписку: форк сессии {sid[:8]}, эта остаётся как была.",
                        f"The second Claude continues this conversation: a fork of session {sid[:8]}, this one stays as it was."))
    if copied and native:
        lines.append(tr("Скопировал по .worktreeinclude: ", "Copied by .worktreeinclude: ") + ", ".join(copied) + ".")
    elif copied:
        lines.append(tr("Скопировал неотслеживаемые настройки: ", "Copied untracked settings: ") + ", ".join(copied)
                     + tr(" (своего .worktreeinclude у проекта нет, поэтому по списку agentmeister).",
                          " (the project has no .worktreeinclude of its own, so by the agentmeister list)."))
    if dirty:
        lines.append(tr("В основной папке есть незакоммиченные изменения — в worktree их нет, он от последнего коммита.",
                        "The main folder has uncommitted changes. The worktree doesn't have them, it starts from the last commit."))
    lines.append(text)
    lines.append(tr(f"Потом: agentmeister parallel pr {name} — через PR, merge {name} — влить локально, "
                    f"drop {name} — выбросить.",
                    f"Then: agentmeister parallel pr {name} to go through a PR, merge {name} to merge locally, "
                    f"drop {name} to throw it away."))
    return "\n".join(lines), bad


def running_in(path):
    """Claude открыт в этом worktree или глубже. Соседний worktree fix-login для fix не в счет."""
    claude = CLAUDE_HOME
    for f in glob.glob(os.path.join(claude, "sessions", "*.json")):
        try:
            with open(f) as fh:
                info = json.load(fh)
            cwd, pid = str(info.get("cwd") or ""), int(info.get("pid") or 0)
            # pid 0 в kill означает всю группу процессов, такой kill всегда удается
            if pid > 0 and (cwd == path or cwd.startswith(path.rstrip("/") + "/")):
                os.kill(pid, 0)
                return True
        except (OSError, ValueError, TypeError, OverflowError):
            continue
    return False


def entries(root):
    out, cur = [], {}
    for line in git(root, "worktree", "list", "--porcelain").splitlines() + [""]:
        if not line:
            if cur.get("path", "").startswith(worktree_root(root) + "/") and cur.get("branch"):
                out.append(cur)
            cur = {}
        elif line.startswith("worktree "):
            cur["path"] = line[9:]
        elif line.startswith("branch "):
            cur["branch"] = line[7:].replace("refs/heads/", "")
    for e in out:
        b = e["branch"]
        e["base"] = git(root, "config", f"branch.{b}.mnrhBase") or git(root, "branch", "--show-current")
        e["task"] = git(root, "config", f"branch.{b}.mnrhTask")
        e["ahead"] = git(root, "rev-list", "--count", f"{e['base']}..{b}") or "?"
        e["dirty"] = len(git(e["path"], "status", "--porcelain").splitlines())
        e["running"] = running_in(e["path"])
    return out


def listing(project=None, cwd=None):
    root, err = find_project(project, cwd)
    if err:
        return err, True
    es = entries(root)
    if not es:
        return tr(f"Параллельных задач в {os.path.basename(root)} нет.",
                  f"No parallel tasks in {os.path.basename(root)}."), False
    lines = [tr(f"Параллельные задачи {os.path.basename(root)}:", f"Parallel tasks in {os.path.basename(root)}:")]
    for e in es:
        state = tr("Claude работает", "Claude is running") if e["running"] else tr("Claude закрыт", "Claude is closed")
        lines.append(tr(f"  {e['branch']}: коммитов {e['ahead']} поверх {e['base']}, незакоммичено {e['dirty']}, {state}",
                        f"  {e['branch']}: {e['ahead']} commits on top of {e['base']}, {e['dirty']} uncommitted, {state}"))
        if e["task"]:
            lines.append(tr(f"    задача: {e['task'][:160]}", f"    task: {e['task'][:160]}"))
    return "\n".join(lines), False


def pick(branch, project=None, cwd=None):
    """-> (root, задача, ошибка)"""
    root, err = find_project(project, cwd)
    if err:
        return None, None, err
    match = [e for e in entries(root) if e["branch"] == branch or e["branch"].endswith("/" + branch)]
    if len(match) != 1:
        return root, None, tr(f"Нет параллельной задачи «{branch}». ",
                              f"No parallel task \"{branch}\". ") + listing(project, cwd)[0]
    return root, match[0], None


def forget_task(root, e, delete="-D"):
    """Убрать worktree, ветку и записи о задаче."""
    subprocess.run(["git", "-C", root, "worktree", "remove", "--force", e["path"]], capture_output=True)
    git(root, "branch", delete, e["branch"])
    for key in ("mnrhBase", "mnrhTask"):
        git(root, "config", "--unset", f"branch.{e['branch']}.{key}")


def finish(branch, action, project=None, cwd=None, force=False):
    root, e, err = pick(branch, project, cwd)
    if err:
        return err, True
    if e["running"]:
        return tr(f"В {tilde(e['path'])} ещё работает Claude — сначала закрой его.",
                  f"Claude is still running in {tilde(e['path'])}. Close it first."), True
    if action == "drop" and not force and (e["dirty"] or e["ahead"] != "0"):
        ahead = tr("не посчитать", "unknown") if e["ahead"] == "?" else e["ahead"]
        return tr(f"В {e['branch']} есть работа: незакоммичено файлов {e['dirty']}, коммитов не влито в {e['base']}: "
                  f"{ahead}. Выбрасывать не стал. Если не нужна, повтори с --force "
                  f"(agentmeister parallel drop {e['branch']} --force; в parallel_finish force: true).",
                  f"{e['branch']} has work in it: {e['dirty']} uncommitted files, commits not merged into {e['base']}: "
                  f"{ahead}. I didn't drop it. If you don't need it, repeat with --force "
                  f"(agentmeister parallel drop {e['branch']} --force; in parallel_finish force: true)."), True
    if action == "merge":
        if e["dirty"]:
            return tr(f"В worktree незакоммичено файлов: {e['dirty']}. Сначала закоммить их там.",
                      f"Uncommitted files in the worktree: {e['dirty']}. Commit them there first."), True
        if git(root, "status", "--porcelain", "--untracked-files=no"):
            return tr("В основной папке есть незакоммиченные изменения — сначала закоммить или отложи их.",
                      "The main folder has uncommitted changes. Commit or stash them first."), True
        current = git(root, "branch", "--show-current")
        if current != e["base"]:
            return tr(f"Основная папка сейчас на ветке {current}, а задача ответвлена от {e['base']}. Переключись на неё.",
                      f"The main folder is on the branch {current}, but the task branched from {e['base']}. "
                      f"Switch to it."), True
        r = subprocess.run(["git", "-C", root, "merge", "--no-ff", "--no-edit", e["branch"]],
                           capture_output=True, text=True)
        if r.returncode:
            subprocess.run(["git", "-C", root, "merge", "--abort"], capture_output=True)
            tail = (r.stdout + r.stderr).strip()[-1500:]
            return tr(f"Слить без конфликтов не вышло, слияние отменено:\n{tail}",
                      f"Couldn't merge without conflicts, the merge was aborted:\n{tail}"), True
    forget_task(root, e, "-d" if action == "merge" else "-D")
    if action == "merge":
        return tr(f"Влил {e['branch']} в {e['base']} ({e['ahead']} коммитов), worktree и ветку убрал. Пушить — сам.",
                  f"Merged {e['branch']} into {e['base']} ({e['ahead']} commits), removed the worktree and the branch. "
                  f"Push it yourself."), False
    return tr(f"Выбросил {e['branch']}: worktree и ветка удалены.",
              f"Dropped {e['branch']}: the worktree and the branch are deleted."), False


# Сколько ждать, пока у свежего PR появятся проверки: GitHub Actions заводит их через несколько секунд
CHECKS_APPEAR = 15
CHECKS_APPEAR_ACTIONS = 90
# если workflow запускается на pull_request, проверки обязаны появиться; ждем дольше и без них не сливаем
CHECKS_APPEAR_PR = 300
CI_TIMEOUT = 3 * 3600


def gh(cwd, *args, timeout=120):
    try:
        return subprocess.run(["gh", *args], cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as ex:
        return subprocess.CompletedProcess(ex.cmd, 124, "", tr(f"gh не ответил за {timeout} с",
                                                                 f"gh didn't answer in {timeout} s"))


def out_of(r, limit=1500):
    return ((r.stdout or "") + (r.stderr or "")).strip()[-limit:]


def github_repo(url):
    """owner/repo (или host/owner/repo не на github.com) из адреса remote; None, если это не похоже на GitHub."""
    m = re.match(r"^(?:[a-z+]+://)?(?:[^@/]+@)?([^/:]+)[:/]+([^/]+/[^/]+?)(?:\.git)?/*$", url or "")
    if not m or "." not in m.group(1):
        return None
    host, path = m.groups()
    return path if host == "github.com" else f"{host}/{path}"


def pr_workflows(path):
    """Workflow GitHub Actions в ветке, которые запускаются на pull_request (или pull_request_target)."""
    found = []
    for f in sorted(glob.glob(os.path.join(glob.escape(path), ".github", "workflows", "*.y*ml"))):
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                text = re.sub(r"(?m)(^|\s)#.*$", "", fh.read())
        except OSError:
            continue
        if re.search(r"\bpull_request(_target)?\b", text):
            found.append(os.path.basename(f))
    return found


def pr_checks(repo, num, path, log):
    """-> (есть ли проверки, прошли ли, текст про упавшие)"""
    expected = pr_workflows(path)
    if expected:
        wait = CHECKS_APPEAR_PR
    else:
        wait = CHECKS_APPEAR_ACTIONS if os.path.isdir(os.path.join(path, ".github", "workflows")) else CHECKS_APPEAR
    deadline = time.time() + wait
    while True:
        r = gh(path, "pr", "checks", str(num), "-R", repo, "--json", "name,bucket,link")
        try:
            found = json.loads(r.stdout or "null")
        except ValueError:
            found = None
        if isinstance(found, list) and found:
            break
        if "no checks reported" not in out_of(r) and not isinstance(found, list):
            return True, False, tr(f"gh pr checks не ответил: {out_of(r) or r.returncode}",
                                   f"gh pr checks didn't answer: {out_of(r) or r.returncode}")
        if time.time() >= deadline:
            if expected:
                flows = ', '.join(expected)
                return False, False, tr(f"за {wait} с у PR не появилось ни одной проверки, хотя {flows} "
                                        "запускается на pull_request. Посмотри Actions; если проверок и не должно "
                                        f"быть (фильтр paths или branches), слей сам: gh pr merge {num} -R {repo}",
                                        f"no checks appeared on the PR in {wait} s, though {flows} "
                                        "runs on pull_request. Look at Actions; if there should be no checks "
                                        f"(a paths or branches filter), merge it yourself: gh pr merge {num} -R {repo}")
            return False, True, ""
        time.sleep(5)
    log(tr(f"Жду CI ({len(found)} проверок)…", f"Waiting for CI ({len(found)} checks)…"))
    r = gh(path, "pr", "checks", str(num), "-R", repo, "--watch", "--fail-fast", "-i", "15", timeout=CI_TIMEOUT)
    if r.returncode == 0:
        return True, True, ""
    r = gh(path, "pr", "checks", str(num), "-R", repo, "--json", "name,bucket,link")
    try:
        bad = [c for c in json.loads(r.stdout or "[]") if c.get("bucket") in ("fail", "cancel")]
    except (ValueError, AttributeError):
        bad = []
    if not bad:
        return True, False, out_of(r) or tr("gh pr checks --watch завершился с ошибкой", "gh pr checks --watch failed")
    return True, False, "\n".join(f"  {c.get('name')}: {c.get('bucket')} {c.get('link') or ''}".rstrip() for c in bad)


def pr(branch, project=None, cwd=None, merge=True, log=None):
    """Отправить ветку параллельной задачи в PR, дождаться CI, слить и убрать worktree. -> (текст, ошибка ли)"""
    log = log or (lambda text: None)
    root, e, err = pick(branch, project, cwd)
    if err:
        return err, True
    name, base, path = e["branch"], e["base"], e["path"]
    if e["running"]:
        return tr(f"В {tilde(path)} ещё работает Claude — сначала закрой его.",
                  f"Claude is still running in {tilde(path)}. Close it first."), True
    if e["dirty"]:
        return tr(f"В worktree незакоммичено файлов: {e['dirty']}. Сначала закоммить их там.",
                  f"Uncommitted files in the worktree: {e['dirty']}. Commit them there first."), True
    if e["ahead"] == "0":
        return tr(f"В {name} нет коммитов поверх {base}, отправлять нечего.",
                  f"{name} has no commits on top of {base}, nothing to send."), True
    if not shutil.which("gh"):
        return tr("Нужен GitHub CLI: brew install gh, потом gh auth login.",
                  "You need the GitHub CLI: brew install gh, then gh auth login."), True
    remote = git(root, "config", f"branch.{base}.remote") or "origin"
    repo = github_repo(git(root, "config", f"remote.{remote}.url"))
    if not repo:
        return tr(f"Remote {remote} проекта не на GitHub, PR не открыть.",
                  f"The project's remote {remote} is not on GitHub, can't open a PR."), True

    r = subprocess.run(["git", "-C", root, "push", "--no-follow-tags", "-u", remote, f"refs/heads/{name}:refs/heads/{name}"],
                       capture_output=True, text=True, timeout=300)
    if r.returncode:
        return tr(f"Не запушил {name} в {remote}:\n{out_of(r)}", f"Couldn't push {name} to {remote}:\n{out_of(r)}"), True
    # что именно ушло в PR: push обновляет remote-tracking ветку ровно до отправленного коммита
    pushed = git(root, "rev-parse", "--verify", "--quiet", f"refs/remotes/{remote}/{name}") or \
        git(root, "rev-parse", "--verify", "--quiet", f"refs/heads/{name}")
    log(tr(f"Запушил {name} в {remote}.", f"Pushed {name} to {remote}."))

    r = gh(path, "pr", "list", "-R", repo, "--head", name, "--state", "open", "--json", "number,url")
    try:
        opened = json.loads(r.stdout or "[]")
    except ValueError:
        opened = []
    if opened:
        num, url = opened[0]["number"], opened[0]["url"]
        log(tr(f"PR уже открыт: {url}", f"PR is already open: {url}"))
    else:
        r = gh(path, "pr", "create", "-R", repo, "--fill", "--base", base, "--head", name)
        url = (r.stdout or "").strip().splitlines()[-1:] or [""]
        url = url[0]
        m = re.search(r"/pull/(\d+)", url)
        if r.returncode or not m:
            return tr(f"Не открыл PR:\n{out_of(r)}", f"Couldn't open the PR:\n{out_of(r)}"), True
        num = int(m.group(1))
        log(tr(f"Открыл PR: {url}", f"Opened the PR: {url}"))
    if not merge:
        return tr(f"Ветка {name} в PR #{num}, сливать не стал. Worktree на месте: {tilde(path)}.",
                  f"Branch {name} is in PR #{num}, not merged. The worktree is still there: {tilde(path)}."), False

    subprocess.run(["git", "-C", root, "fetch", "--no-tags", "-q", remote, base], capture_output=True, timeout=300)
    ref = f"{remote}/{base}" if git(root, "rev-parse", "--verify", "--quiet", f"refs/remotes/{remote}/{base}") else base
    how = "--merge" if git(root, "rev-list", "--merges", "-1", ref) else "--rebase"

    has, ok, bad = pr_checks(repo, num, path, log)
    if not ok:
        return tr(f"CI по PR #{num} не прошёл, сливать не стал. Worktree оставил: {tilde(path)}.\n{bad}\n"
                  f"Почини там, закоммить и снова: agentmeister parallel pr {name}",
                  f"CI on PR #{num} failed, not merged. Kept the worktree: {tilde(path)}.\n{bad}\n"
                  f"Fix it there, commit and run again: agentmeister parallel pr {name}"), True
    log(tr("CI прошёл.", "CI passed.") if has else tr("Проверок у PR нет, сливаю сразу.", "The PR has no checks, merging now."))

    r = gh(path, "pr", "merge", str(num), "-R", repo, how, "--delete-branch", "--match-head-commit", pushed,
           timeout=300)
    if r.returncode:
        return tr(f"PR #{num} не слился ({how}), worktree оставил:\n{out_of(r)}",
                  f"PR #{num} didn't merge ({how}), kept the worktree:\n{out_of(r)}"), True
    git(root, "branch", "-d", "-r", f"{remote}/{name}")
    # CI мог идти часами: за это время в worktree могли снова открыть Claude, что-то поменять или закоммитить
    keep = []
    if running_in(path):
        keep.append(tr("там снова работает Claude", "Claude is running there again"))
    dirty = len(git(path, "status", "--porcelain").splitlines())
    if dirty:
        keep.append(tr(f"незакоммичено файлов: {dirty}", f"uncommitted files: {dirty}"))
    if git(root, "rev-parse", "--verify", "--quiet", f"refs/heads/{name}") != pushed:
        keep.append(tr(f"в ветке {name} есть коммиты, которых нет в PR", f"the branch {name} has commits that aren't in the PR"))
    if keep:
        why = '; '.join(keep)
        lines = [tr(f"Слил PR #{num} в {base} ({how[2:]}), ветку на GitHub удалил. Worktree {tilde(path)} и ветку {name} "
                    f"оставил: {why}. Когда разберёшься: agentmeister parallel drop {name} --force.",
                    f"Merged PR #{num} into {base} ({how[2:]}), deleted the branch on GitHub. Kept the worktree "
                    f"{tilde(path)} and the branch {name}: {why}. When you've sorted it out: "
                    f"agentmeister parallel drop {name} --force.")]
    else:
        forget_task(root, e)
        lines = [tr(f"Слил PR #{num} в {base} ({how[2:]}), ветку на GitHub удалил, worktree и локальную ветку убрал.",
                    f"Merged PR #{num} into {base} ({how[2:]}), deleted the branch on GitHub, removed the worktree "
                    f"and the local branch.")]
    subprocess.run(["git", "-C", root, "fetch", "--no-tags", "-q", remote, base], capture_output=True, timeout=300)
    if git(root, "branch", "--show-current") != base:
        lines.append(tr(f"Основная папка не на {base}, её не трогал.", f"The main folder is not on {base}, left it alone."))
    elif git(root, "status", "--porcelain", "--untracked-files=no"):
        lines.append(tr(f"В основной папке есть незакоммиченные изменения, {base} не подтягивал: git pull --ff-only сам.",
                        f"The main folder has uncommitted changes, didn't update {base}: run git pull --ff-only yourself."))
    else:
        r = subprocess.run(["git", "-C", root, "merge", "--ff-only", "-q", f"{remote}/{base}"],
                           capture_output=True, text=True)
        lines.append(tr(f"Подтянул {base} в основной папке.", f"Updated {base} in the main folder.") if not r.returncode else
                     tr(f"{base} в основной папке не подтягивается перемоткой: {out_of(r, 300)}",
                        f"{base} in the main folder can't fast-forward: {out_of(r, 300)}"))
    return "\n".join(lines), False


START_TOOL = {
    "name": "parallel_task",
    "description": ("Запустить задачу параллельно: создать git worktree на новой ветке (от текущего коммита проекта) "
                    "и открыть там второй Claude Code в новой вкладке iTerm2 (в Terminal в новом окне) с этой задачей и Remote Control. "
                    "Второй Claude закоммитит результат в свою ветку; потом parallel_finish вольёт или выбросит её. "
                    "Вызывай, когда пользователь просит сделать что-то параллельно, в фоне или в отдельной ветке."),
    "inputSchema": {"type": "object", "properties": {
        "task": {"type": "string", "description": "задача для второго Claude, понятная без контекста этой сессии"},
        "project": {"type": "string", "description": "проект; по умолчанию текущий"},
        "branch": {"type": "string", "description": "имя ветки; по умолчанию parallel/<по задаче>"},
        "mode": {"type": "string", "enum": ["caffeinate", "normal"]},
        "permission_mode": {"type": "string", "enum": PERMISSION_MODES,
                            "description": "режим разрешений второго Claude; по умолчанию обычный (спрашивает, "
                                           "вопрос приходит уведомлением). auto или acceptEdits — только если "
                                           "пользователь так сказал"},
        "remote_control": {"type": "boolean", "description": "Remote Control; по умолчанию как в agentmeister defaults"},
        "fork": {"type": "boolean",
                 "description": "открыть второй Claude с этой же перепиской (форк сессии), чтобы он знал весь "
                                "контекст; эта сессия не меняется. По умолчанию нет: новая сессия только с задачей. "
                                "Ставь, если пользователь просит взять контекст с собой"}},
        "required": ["task"]},
}
LIST_TOOL = {
    "name": "parallel_list",
    "description": "Параллельные задачи проекта: ветки, сколько коммитов, есть ли незакоммиченное, работает ли там Claude.",
    "annotations": {"readOnlyHint": True},
    "inputSchema": {"type": "object", "properties": {"project": {"type": "string"}}},
}
FINISH_TOOL = {
    "name": "parallel_finish",
    "description": ("Закончить параллельную задачу: merge — влить её ветку в ветку, от которой она ответвлена "
                    "(без пуша), drop — выбросить ветку и worktree, pr — запушить ветку, открыть PR в исходную "
                    "ветку, дождаться CI, слить его и убрать worktree (no_merge: только открыть PR). pr может "
                    "ждать CI долго. Только с согласия пользователя."),
    "annotations": {"destructiveHint": True},
    "inputSchema": {"type": "object", "properties": {
        "branch": {"type": "string"}, "action": {"type": "string", "enum": ["merge", "drop", "pr"]},
        "no_merge": {"type": "boolean", "description": "для pr: только запушить и открыть PR, не сливать"},
        "force": {"type": "boolean", "description": "для drop: выбросить, даже если есть незакоммиченные файлы или "
                                                    "невлитые коммиты. Только если пользователь так сказал"},
        "project": {"type": "string"}}, "required": ["branch", "action"]},
}
TOOLS = [START_TOOL, LIST_TOOL, FINISH_TOOL]


def handle(name, a, cwd=None, cm=None):
    if name == "parallel_task":
        rc = a.get("remote_control")
        return start(a.get("task"), a.get("project"), a.get("branch"), a.get("mode"), cwd, cm,
                     a.get("permission_mode"), None if rc is None else rc is not False, bool(a.get("fork")))
    if name == "parallel_list":
        return listing(a.get("project"), cwd)
    if a.get("action") == "pr":
        done = []
        text, bad = pr(a.get("branch", ""), a.get("project"), cwd, merge=not a.get("no_merge"), log=done.append)
        return "\n".join(done + [text]), bad
    return finish(a.get("branch", ""), a.get("action"), a.get("project"), cwd, force=a.get("force") is True)


def main():
    args = sys.argv[2:] if sys.argv[1:2] == ["parallel"] else sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(tr('agentmeister parallel "<задача>" [-p проект] [-b ветка] [-n] [--permission-mode auto] [--no-rc] [--fork]',
                 'agentmeister parallel "<task>" [-p project] [-b branch] [-n] [--permission-mode auto] [--no-rc] [--fork]'))
        print(tr("                         новая ветка и worktree от текущего коммита, в новой вкладке — Claude с задачей;",
                 "                         new branch and worktree from the current commit, Claude with the task in a new tab;"))
        print(tr("                         --fork изнутри Claude: второй Claude продолжает эту переписку (форк сессии)",
                 "                         --fork from inside Claude: the second Claude continues this conversation (session fork)"))
        print(tr('agentmeister parallel "<задача>" -p проект --prepare [--fork-sid <id>]',
                 'agentmeister parallel "<task>" -p project --prepare [--fork-sid <id>]'))
        print(tr("                         только ветка и worktree, ответ JSON: так вкладку открывает приложение Agentmeister",
                 "                         only the branch and worktree, JSON answer: this is how the Agentmeister app opens a tab"))
        print(tr("agentmeister parallel list           параллельные задачи этого проекта",
                 "agentmeister parallel list            parallel tasks of this project"))
        print(tr("agentmeister parallel merge <ветка>  влить в исходную ветку (без пуша) и убрать worktree",
                 "agentmeister parallel merge <branch>  merge into the source branch (no push) and remove the worktree"))
        print(tr("agentmeister parallel drop <ветка> [--force]", "agentmeister parallel drop <branch> [--force]"))
        print(tr("                         выбросить ветку и worktree; с незакоммиченным или невлитым — только с --force",
                 "                         throw away the branch and worktree; with uncommitted or unmerged work only with --force"))
        print(tr("agentmeister parallel pr <ветка> [--no-merge]", "agentmeister parallel pr <branch> [--no-merge]"))
        print(tr("                         запушить, открыть PR в исходную ветку, дождаться CI, слить, убрать worktree",
                 "                         push, open a PR into the source branch, wait for CI, merge, remove the worktree"))
        print()
        wt = tilde(os.path.join(projects_dir(), '.worktrees'))
        print(tr(f"Worktree лежат в {wt}/<проект>/. В Claude Code: /parallel.",
                 f"Worktrees live in {wt}/<project>/. In Claude Code: /parallel."))
        return 0 if args else 2
    opts = {}
    rest = []
    i = 0
    while i < len(args):
        if args[i] in ("-p", "-b", "--permission-mode", "--fork-sid") and i + 1 < len(args):
            opts[args[i]] = args[i + 1]
            i += 2
            continue
        if args[i] in ("-n", "-k", "--no-rc", "--no-merge", "--fork", "--force", "--prepare"):
            opts[args[i]] = True
        else:
            rest.append(args[i])
        i += 1
    if opts.get("--prepare"):
        job, err = prepare(" ".join(rest), opts.get("-p"), opts.get("-b"), sid=opts.get("--fork-sid"))
        if job:
            import claude_open
            if claude_open.trusted(job["root"]):
                claude_open.trust(job["path"])  # корень проекта доверенный, значит и его worktree
        print(json.dumps(job or {"error": err}, ensure_ascii=False))
        return 0  # ошибка внутри JSON: приложение читает ее и показывает как есть
    if rest[:1] == ["list"]:
        text, bad = listing(opts.get("-p"))
    elif rest[:1] in (["merge"], ["drop"]) and len(rest) == 2:
        text, bad = finish(rest[1], rest[0], opts.get("-p"), force=bool(opts.get("--force")))
    elif rest[:1] == ["pr"] and len(rest) == 2:
        text, bad = pr(rest[1], opts.get("-p"), merge=not opts.get("--no-merge"), log=lambda t: print(t, flush=True))
    else:
        from mnrhlib import CM
        text, bad = start(" ".join(rest), opts.get("-p"), opts.get("-b"), "normal" if opts.get("-n") else "caffeinate" if opts.get("-k") else None,
                          cm=CM, permission=opts.get("--permission-mode"), rc=False if opts.get("--no-rc") else None,
                          fork=bool(opts.get("--fork")))
    print(text)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
