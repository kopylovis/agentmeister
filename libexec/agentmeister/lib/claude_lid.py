"""agentmeister lid: Mac не засыпает от закрытой крышки, пока идут caffeinate-сессии Claude Code или Codex.

caffeinate -is держит Mac от простоя, а от сети и с закрытой крышкой. На батарее крышку
перебивает только pmset disablesleep 1: его держит сторож, пока жива хоть одна caffeinate-сессия
Claude, и снимает через GRACE секунд после последней или когда батарея садится до LOW_BATTERY.
pmset нужен root: agentmeister lid setup ставит правило sudoers ровно на две команды.

Перенесено из mnrh sleep lid. Правило, pid-файл и журнал те же, что у mnrh: уже настроенное правило
подхватывается, и при обоих установленных сторож все равно один.
"""
import getpass
import os
import re
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import HOME, config_int, lang, read_config, run, tilde, tr, write_config

# Файлы lid остаются под старым именем mnrh и после agentmeister migrate: pid-файл и журнал общие с mnrh
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), "mnrh")
PIDFILE = os.path.join(STATE, "lid.pid")
LOG = os.path.join(STATE, "lid.log")
SUDOERS = "/etc/sudoers.d/mnrh-pmset"
PMSET = "/usr/bin/pmset"
ON = [PMSET, "-a", "disablesleep", "1"]
OFF = [PMSET, "-a", "disablesleep", "0"]
GRACE = 120  # перезапуск сессии с claude update бывает дольше минуты
POLL = 15
LOW_BATTERY = 15


def grace():
    """Секунды после последней сессии, через которые сторож отпускает крышку: lid_grace_min в config, 1-60 мин."""
    return config_int("lid_grace_min", GRACE // 60, 1, 60) * 60


def low_battery():
    """Заряд, при котором сторож отпускает крышку на батарее: lid_battery в config, 5-50%."""
    return config_int("lid_battery", LOW_BATTERY, 5, 50)


SESSION = re.compile(r"^(?:\S*/)?caffeinate(?:\s+-\S+)*\s+(?:\S*/)?(?:claude|codex)(?:\s|$)")
# "Не спать" во вкладке приложения: caffeinate -is -w <pid оболочки вкладки>, родитель сам Agentmeister
APP_SESSION = re.compile(r"^(\S*/)?caffeinate(\s+-\S+)*\s+-w\s+\d+\s*$")
APP = re.compile(r"(^|/)Agentmeister$")
# сторож agentmeister (claude_lid.py watch) или mnrh (lid.py watch): pid-файл у них общий
WATCHER = re.compile(r"(^|[\s/])(claude_)?lid\.py\s+watch(\s|$)")


def ready():
    """Правило sudoers на месте: pmset можно звать без пароля.

    Одного sudo -n мало: с закешированным паролем он тоже проходит, сторож включил бы
    disablesleep, а когда кеш истечёт, уже не смог бы его снять.
    None, если sudo не запустить вовсе: так бывает в песочнице proxy-сессии, и проверить правило оттуда нельзя.
    """
    if not os.path.exists(SUDOERS):
        return False
    try:
        return all(subprocess.run(["sudo", "-n", "-l", *c], capture_output=True).returncode == 0 for c in (ON, OFF))
    except OSError:
        return None


def disabled():
    return re.search(r"^\s*SleepDisabled\s+1\b", run([PMSET, "-g"]), re.M) is not None


def set_disabled(on):
    return subprocess.run(["sudo", "-n", *(ON if on else OFF)], capture_output=True).returncode == 0


def sessions():
    """pid caffeinate, которые держат сессии Claude Code или Codex: agentmeister -k, open_claude, перезапуск и кнопка
    "Не спать" во вкладке приложения."""
    procs = {}
    for line in run(["ps", "-axo", "pid=,ppid=,args="]).splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            procs[int(parts[0])] = (int(parts[1]), parts[2])
    return [pid for pid, (ppid, args) in procs.items()
            if SESSION.match(args) or (APP_SESSION.match(args) and APP.search(procs.get(ppid, (0, ""))[1].split(" -", 1)[0].strip()))]


def battery():
    """(от сети ли, процент или None)"""
    out = run([PMSET, "-g", "batt"])
    pct = re.search(r"(\d+)%", out)
    return "AC Power" in out, int(pct.group(1)) if pct else None


def is_watcher(pid):
    """Под этим pid сейчас идет сторож, а не чужой процесс, которому pid достался после сбоя или перезагрузки."""
    return WATCHER.search(run(["ps", "-o", "command=", "-p", str(pid)]).strip()) is not None


def watcher_pid():
    """pid живого сторожа из lid.pid. Устаревший файл (процесса нет или pid уже чужой) удаляется."""
    try:
        with open(PIDFILE) as f:
            pid = int(f.read().strip())
    except (OSError, ValueError):
        return None
    try:
        os.kill(pid, 0)
        alive = True
    except PermissionError:
        alive = True  # процесс есть, но не наш пользователь: проверит командная строка
    except OSError:
        alive = False
    if alive and is_watcher(pid):
        return pid
    try:
        with open(PIDFILE) as f:
            same = f.read().strip() == str(pid)  # новый сторож мог уже записать свой pid
        if same:
            os.remove(PIDFILE)
    except OSError:
        pass
    return None


def log(text):
    os.makedirs(STATE, exist_ok=True)
    with open(LOG, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + text + "\n")


def notify(text):
    subprocess.run(["osascript", "-e", f'display notification "{text}" with title "agentmeister"'],
                   capture_output=True)


def watch():
    os.makedirs(STATE, exist_ok=True)
    with open(PIDFILE, "w") as f:
        f.write(str(os.getpid()))
    def stop(*_):
        raise SystemExit(0)  # прерывает и time.sleep, finally снимет запрет
    signal.signal(signal.SIGTERM, stop)
    held, low, idle_since = False, False, None
    log("сторож запущен")
    try:
        while True:
            ac, pct = battery()
            floor = low_battery()
            if not ac and pct is not None and pct <= floor:
                if not low:
                    low = True
                    notify(tr(f"Батарея {pct}%: Mac снова уснёт, если закрыть крышку",
                              f"Battery {pct}%: the Mac will sleep again if you close the lid"))
                    log(f"батарея {pct}%, отпускаю")
            elif low and (ac or (pct or 0) > floor + 5):
                low = False
            alive = bool(sessions())
            idle_since = None if alive else (idle_since or time.time())
            if idle_since and time.time() - idle_since >= grace():
                break
            want = alive and not low
            if want != held or (want and not disabled()):
                if set_disabled(want):
                    held = want
                    log("держу: крышка не усыпляет" if want else "отпустил")
                else:
                    log("sudo -n pmset не сработал: agentmeister lid setup")
                    break
            time.sleep(POLL)
    finally:
        if held or disabled():
            set_disabled(False)
            log("отпустил при выходе")
        try:
            os.remove(PIDFILE)
        except OSError:
            pass


def switched_on():
    """Не выключено ли командой agentmeister lid off (строка lid=off в конфиге)."""
    return read_config().get("lid", "on") != "off"


def active():
    """Крышка не усыпляет caffeinate-сессии: правило есть и режим не выключен. Из песочницы, где sudo
    не запустить, правило на месте считаем рабочим."""
    return switched_on() and ready() is not False


def keep():
    """Запустить сторожа, если правило есть, режим включен и сторож ещё не идёт. Иначе тихо ничего не делает."""
    if watcher_pid() or not switched_on() or not ready():
        return False
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "watch"], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, cwd="/")
    return True


def release():
    pid = watcher_pid()
    if pid:
        os.kill(pid, signal.SIGTERM)
        for _ in range(20):
            if not watcher_pid():
                break
            time.sleep(0.25)
    if disabled():
        set_disabled(False)


def setup():
    user = getpass.getuser()
    rule = f"{user} ALL=(root) NOPASSWD: {' '.join(ON)}, {' '.join(OFF)}\n"
    tmp = os.path.join(STATE, "mnrh-pmset.sudoers")
    os.makedirs(STATE, exist_ok=True)
    with open(tmp, "w") as f:
        f.write(rule)
    if subprocess.run(["/usr/sbin/visudo", "-cf", tmp], capture_output=True).returncode:
        sys.exit(tr("visudo не принял правило, ничего не поставил", "visudo rejected the rule, nothing installed"))
    print(tr(f"Ставлю {SUDOERS}, sudo спросит пароль:\n  {rule.strip()}",
             f"Installing {SUDOERS}, sudo will ask for your password:\n  {rule.strip()}"))
    r = subprocess.run(["sudo", "install", "-m", "0440", "-o", "root", "-g", "wheel", tmp, SUDOERS])
    os.remove(tmp)
    if r.returncode:
        sys.exit(tr("не поставил", "not installed"))
    print(tr("Готово. Caffeinate-сессии Claude Code и Codex теперь не дают Mac уснуть и с закрытой крышкой на батарее.",
             "Done. Caffeinate sessions of Claude Code and Codex now keep the Mac awake with the lid closed on battery."))


def remove():
    release()
    r = subprocess.run(["sudo", "rm", "-f", SUDOERS])
    print(tr("Правило убрано, крышка снова усыпляет Mac.", "Rule removed, closing the lid puts the Mac to sleep again.")
          if r.returncode == 0 else tr("не убрал", "not removed"))


def status_lines():
    lines = []
    if not switched_on():
        lines.append(tr("Крышка: выключено, закрытая крышка усыпит Mac и в caffeinate-сессии. Включить: agentmeister lid on",
                        "Lid: off, closing the lid puts the Mac to sleep even in a caffeinate session. "
                        "Turn on: agentmeister lid on"))
        return lines
    if not ready():
        lines.append(tr("Крышка: закрытая крышка на батарее усыпит Mac и в caffeinate-сессии. "
                        "Чтобы не усыпляла: agentmeister lid setup",
                        "Lid: on battery, closing the lid puts the Mac to sleep even in a caffeinate session. "
                        "To keep it awake: agentmeister lid setup"))
        return lines
    n = len(sessions())
    if disabled():
        lines.append(tr(f"Крышка: Mac не уснёт и с закрытой крышкой, caffeinate-сессий {n}"
                        + (f", сторож pid {watcher_pid()}" if watcher_pid() else ", сторожа нет: agentmeister lid release"),
                        f"Lid: the Mac stays awake with the lid closed, caffeinate sessions {n}"
                        + (f", watcher pid {watcher_pid()}" if watcher_pid() else ", no watcher: agentmeister lid release")))
    else:
        lines.append(tr("Крышка: правило есть, сейчас не держу" + (f" (сессий {n}, сторож их подхватит)" if n else ""),
                        "Lid: rule is set, not holding now"
                        + (f" (sessions {n}, the watcher will pick them up)" if n else "")))
    return lines


def main(args):
    cmd = args[0] if args else "status"
    if cmd in ("-h", "--help"):
        if lang() == "en":
            print("agentmeister lid           whether the lid keeps the Mac awake right now")
            print("agentmeister lid setup     sudoers rule for pmset: agent caffeinate sessions stay awake with the lid")
            print(f"                            closed on battery (down to {low_battery()}% charge)")
            print("agentmeister lid on | off  turn on or off (on without the rule installs it first)")
            print("agentmeister lid release   let go now, until the next caffeinate session")
            print("agentmeister lid remove    turn off and remove the rule")
            print(f"agentmeister lid grace <min>|default    how long to wait after the last session (now {grace() // 60})")
            print(f"agentmeister lid battery <%>|default    battery level to let go at (now {low_battery()})")
            return 0
        print("agentmeister lid           держит ли сейчас крышка Mac от сна")
        print("agentmeister lid setup     правило sudoers для pmset: caffeinate-сессии агентов не уснут и с закрытой")
        print(f"                            крышкой на батарее (до {low_battery()}% заряда)")
        print("agentmeister lid on | off  включить или выключить (on без правила сначала поставит его)")
        print("agentmeister lid release   отпустить сейчас, до следующей caffeinate-сессии")
        print("agentmeister lid remove    выключить и убрать правило")
        print(f"agentmeister lid grace <мин>|default    через сколько отпустить после последней сессии (сейчас {grace() // 60})")
        print(f"agentmeister lid battery <%>|default    при каком заряде отпустить на батарее (сейчас {low_battery()})")
        return 0
    if cmd in ("grace", "battery") and len(args) == 2:
        key, low, high = {"grace": ("lid_grace_min", 1, 60), "battery": ("lid_battery", 5, 50)}[cmd]
        if args[1] == "default":
            write_config(**{key: None})
        elif not args[1].isdigit() or not low <= int(args[1]) <= high:
            print(tr(f"{cmd}: число от {low} до {high} или default", f"{cmd}: a number from {low} to {high} or default"),
                  file=sys.stderr)
            return 2
        else:
            write_config(**{key: args[1]})
        print(tr(f"Отпускаю через {grace() // 60} мин после последней сессии или при {low_battery()}% батареи",
                 f"Letting go {grace() // 60} min after the last session or at {low_battery()}% battery"))
        return 0
    if cmd == "watch":
        watch()
    elif cmd == "keep":
        keep()
    elif cmd == "setup":
        setup()
    elif cmd == "remove":
        remove()
    elif cmd == "on":
        write_config(lid="on")
        if not ready():
            setup()
        if sessions():
            keep()  # сессии уже идут: держать их сейчас, а не со следующей
        print(tr("Включено: caffeinate-сессии агентов не уснут и с закрытой крышкой.",
                 "On: agent caffeinate sessions stay awake with the lid closed."))
    elif cmd == "off":
        write_config(lid="off")
        release()
        print(tr("Выключено: крышка снова усыпляет Mac. Правило sudoers осталось, agentmeister lid on вернет режим.",
                 "Off: closing the lid puts the Mac to sleep again. The sudoers rule stays, agentmeister lid on brings the mode back."))
    elif cmd == "release":
        release()
        print(tr("Отпустил: крышка снова усыпляет Mac, до следующей caffeinate-сессии.",
                 "Let go: closing the lid puts the Mac to sleep again, until the next caffeinate session."))
    elif cmd == "status":
        print("\n".join(status_lines()))
        if os.path.exists(LOG):
            print(tr(f"Журнал сторожа: {tilde(LOG)}", f"Watcher log: {tilde(LOG)}"))
    else:
        print(tr(f"agentmeister lid: не знаю {cmd}, см. agentmeister lid -h",
                 f"agentmeister lid: unknown command {cmd}, see agentmeister lid -h"), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
