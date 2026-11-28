"""agentmeister migrate: перенести папки со старым именем mnrh в папки agentmeister.

~/.config/mnrh, ~/.cache/mnrh и ~/.local/state/mnrh переезжают в ~/.config/agentmeister, ~/.cache/agentmeister
и ~/.local/state/agentmeister. Пока ~/.config/mnrh есть, а новой нет, agentmeister читает старые (mnrhlib.app_dir).

Запускать в обычном терминале, когда закрыты proxy-сессии, mihomo, исполнитель host-run и приложение Agentmeister:
песочница уже запущенных сессий закрывает ссылки на подписки и белый список host-run по старому пути, и после
переноса эти правила к новым файлам не относятся. Поэтому перенос из proxy-сессии не делается, и ссылок со
старого пути на новый не остается. Исключения два: файлы lid (lid.pid, lid.log) остаются в ~/.local/state/mnrh,
их делит с agentmeister утилита mnrh, и если mnrh установлена, ~/.config/mnrh/config остается ссылкой на новый
config, потому что mnrh читает его же.
"""
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import CONFIG_HOME, HOME, STATE_HOME, tilde, tr  # noqa: E402

LID_FILES = ("lid.pid", "lid.log")


def places():
    """[(старая, новая, что оставить на месте)], конфиг последним: его перенос переключает agentmeister на новые."""
    caches = []
    for base in dict.fromkeys([os.path.join(HOME, ".cache"), os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache")]):
        caches.append((os.path.join(base, "mnrh"), os.path.join(base, "agentmeister"), ()))
    return caches + [(os.path.join(STATE_HOME, "mnrh"), os.path.join(STATE_HOME, "agentmeister"), LID_FILES),
                     (os.path.join(CONFIG_HOME, "mnrh"), os.path.join(CONFIG_HOME, "agentmeister"), ())]


def running(pidfile):
    try:
        with open(pidfile) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return True
    except (OSError, ValueError):
        return False


def blockers():
    out = []
    if os.environ.get("MNRH_PROXY"):
        out.append(tr("это сессия через proxy: ее песочница не даст перенести папки. Запусти в обычном терминале",
                      "this is a proxy session; its sandbox won't let the folders move. Run it in a regular terminal"))
    state = os.path.join(STATE_HOME, "mnrh")
    if running(os.path.join(state, "proxy", "mihomo.pid")):
        out.append(tr("работает mihomo: закрой сессии через proxy, он остановится после последней",
                      "mihomo is running: close the proxy sessions, it stops after the last one"))
    if running(os.path.join(state, "host-run", "host-run.pid")):
        out.append(tr("работает исполнитель host-run: agentmeister host-run stop",
                      "the host-run runner is running: agentmeister host-run stop"))
    try:
        app = subprocess.run(["pgrep", "-x", "Agentmeister"], capture_output=True, text=True).stdout.strip()
    except OSError:
        app = ""
    if app:
        out.append(tr("открыто приложение Agentmeister: закрой его, оно держит пути в памяти",
                      "the Agentmeister app is open: quit it, it keeps the paths in memory"))
    return out


def move(old, new, keep):
    """Перенести содержимое old в new. -> (перенесено, конфликты)."""
    moved, clashes = [], []
    if not os.path.isdir(old) or os.path.islink(old):
        return moved, clashes
    os.makedirs(new, mode=0o700, exist_ok=True)
    for name in sorted(os.listdir(old)):
        if name in keep:
            continue
        src, dst = os.path.join(old, name), os.path.join(new, name)
        if os.path.lexists(dst):
            clashes.append(dst)
            continue
        os.rename(src, dst)
        moved.append(name)
    try:
        os.rmdir(old)
    except OSError:
        pass
    return moved, clashes


def main(args):
    if args[:1] in (["-h"], ["--help"]):
        print(__doc__.strip())
        print("\nagentmeister migrate [--dry-run]")
        return 0
    todo = [(o, n, k) for o, n, k in places() if os.path.isdir(o) and not os.path.islink(o)
            and any(name not in k for name in os.listdir(o))]
    if not todo:
        print(tr("Переносить нечего: папок mnrh нет.", "Nothing to move: there are no mnrh folders."))
        return 0
    for old, new, keep in todo:
        print(f"{tilde(old)} → {tilde(new)}" + (tr(f" (кроме {', '.join(keep)})", f" (except {', '.join(keep)})") if keep else ""))
    if "--dry-run" in args:
        return 0
    stop = blockers()
    if stop:
        print(tr("Не переношу:", "Not moving:"), file=sys.stderr)
        for line in stop:
            print(f"  {line}", file=sys.stderr)
        return 1
    problems = []
    for old, new, keep in todo:
        _, clashes = move(old, new, keep)
        problems += clashes
    config_old = os.path.join(CONFIG_HOME, "mnrh")
    config_new = os.path.join(CONFIG_HOME, "agentmeister", "config")
    if shutil.which("mnrh") and os.path.exists(config_new) and not os.path.lexists(os.path.join(config_old, "config")):
        os.makedirs(config_old, exist_ok=True)
        os.symlink(config_new, os.path.join(config_old, "config"))
        print(tr(f"{tilde(config_old)}/config теперь ссылка на новый config: его читает mnrh",
                 f"{tilde(config_old)}/config now links to the new config, mnrh reads it"))
    for path in problems:
        print(tr(f"! {tilde(path)} уже есть, старый файл оставил на месте", f"! {tilde(path)} already exists, kept the old one in place"))
    print(tr("Готово. Открой приложение и сессии заново, они возьмут новые пути.",
             "Done. Reopen the app and the sessions, they'll pick up the new paths."))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[2:] if sys.argv[1:2] == ["migrate"] else sys.argv[1:]))
