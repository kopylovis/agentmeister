"""Команды из белого списка, которые сессия через proxy запускает вне своей песочницы.

Сессию -x macOS держит в sandbox-exec. Внутри нее не работают программы со своей песочницей
(xcodebuild с пакетами Swift и макросами) и программы, которым нужна прямая сеть (firebase-tools).
Исполнитель запускается вместе с сессией через proxy еще до песочницы и слушает Unix-сокет.
Сессия просит его выполнить команду по имени. Список команд лежит в папке, куда песочница
сессии писать не дает, так что добавить в него команду может только человек.

Список защищает от случайного прямого трафика, а не от агента, который поправит скрипт релиза:
команда выполняет то, что лежит в проекте.
"""
import fcntl
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import BAD, HOME, OK, WARN, paint, tilde  # noqa: E402

CONF_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "mnrh", "host-run")
COMMANDS = os.path.join(CONF_DIR, "commands.json")
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), "mnrh", "host-run")
SOCK = os.path.join(STATE, "host-run.sock")
PIDFILE = os.path.join(STATE, "host-run.pid")
LOG = os.path.join(STATE, "host-run.log")
VERSION_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "VERSION")
RESERVED = ("list", "status", "serve", "stop", "help", "-h", "--help")
# Переменные proxy сессии: команда из списка ходит в сеть напрямую, как в обычном терминале.
PROXY_VARS = ("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "all_proxy",
              "no_proxy", "MNRH_PROXY", "PROMPTSILL_PROXY_LABEL", "PROMPTSILL_PROXY_DETAIL", "PROMPTSILL_PROXY_URL")
MAX_REQUEST = 256 * 1024
EXAMPLE = """{
  "commands": {
    "tossling-ios": {"cwd": "~/Developer/tossling-mobile", "run": ["bundle", "exec", "fastlane", "ios_beta"]},
    "tossling-firebase": {"cwd": "~/Developer/tossling-mobile", "run": ["bundle", "exec", "fastlane", "upload"],
                          "args": true}
  }
}"""


class RuleError(Exception):
    pass


def version():
    try:
        with open(VERSION_FILE) as f:
            return f.read().strip()
    except OSError:
        return "?"


def load(path=None):
    """Имя команды -> {"cwd", "run", "args"}. Ошибка в файле — RuleError с понятным текстом."""
    path = str(path or COMMANDS)
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        raise RuleError(f"{tilde(path)} не читается: {e}")
    commands = data.get("commands") if isinstance(data, dict) else None
    if not isinstance(commands, dict):
        raise RuleError(f"в {tilde(path)} нет объекта commands")
    rules = {}
    for name, rule in commands.items():
        run = rule.get("run") if isinstance(rule, dict) else None
        cwd = rule.get("cwd") if isinstance(rule, dict) else None
        if name in RESERVED or not name or name.startswith("-"):
            raise RuleError(f"имя {name!r} занято командами host-run")
        if not (isinstance(run, list) and run and all(isinstance(a, str) and a for a in run)):
            raise RuleError(f"{name}: run должен быть непустым списком строк")
        if not isinstance(cwd, str) or not cwd:
            raise RuleError(f"{name}: нужна папка cwd")
        cwd = os.path.expanduser(cwd)
        if not os.path.isabs(cwd):
            raise RuleError(f"{name}: cwd должен быть полным путем")
        rules[name] = {"cwd": cwd, "run": run, "args": rule.get("args") is True}
    return rules


def resolve(name, args, rules):
    rule = rules.get(name)
    if not rule:
        known = ", ".join(sorted(rules)) or "список пуст"
        raise RuleError(f"команды {name!r} нет в {tilde(COMMANDS)} ({known})")
    if args and not rule["args"]:
        raise RuleError(f"{name} запускается без аргументов, в списке у нее нет \"args\": true")
    if not all(isinstance(a, str) for a in args):
        raise RuleError("аргументы должны быть строками")
    return rule["run"] + list(args), rule["cwd"]


def command_env(base=None):
    env = dict(os.environ if base is None else base)
    for name in PROXY_VARS:
        env.pop(name, None)
    return env


def sandbox_profile_lines():
    """Для профиля сессии: список и сокет исполнителя менять нельзя, подключаться к сокету можно."""
    return ['(deny file-write* (subpath (param "HOST_RUN_CONF")) (subpath (param "HOST_RUN_STATE")))']


def sandbox_params():
    return ["-D", f"HOST_RUN_CONF={os.path.realpath(CONF_DIR)}", "-D", f"HOST_RUN_STATE={os.path.realpath(STATE)}"]


# Кадры по сокету: тип (1 байт) и длина (4 байта). o вывод, e сообщение исполнителя, x код выхода, v версия.
def send_frame(conn, kind, payload):
    conn.sendall(struct.pack(">cI", kind, len(payload)) + payload)


def recv_exact(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def recv_frame(conn):
    head = recv_exact(conn, 5)
    if head is None:
        return None, None
    kind, size = struct.unpack(">cI", head)
    payload = recv_exact(conn, size) if size else b""
    return (kind, payload) if payload is not None else (None, None)


def log(text):
    try:
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + text + "\n")
    except OSError:
        pass


def nested_sandbox_ok():
    """Исполнитель имеет смысл только вне песочницы: тогда sandbox-exec внутри него работает."""
    try:
        return subprocess.run(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


class Server:
    def __init__(self, sock_path=SOCK, commands=None):
        self.sock_path = sock_path
        self.commands = commands or COMMANDS
        self.jobs = 0
        self.lock = threading.Lock()

    def handle(self, conn):
        with conn:
            line = b""
            while not line.endswith(b"\n"):
                chunk = conn.recv(4096)
                if not chunk or len(line) > MAX_REQUEST:
                    return
                line += chunk
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise ValueError("ожидался объект")
            except ValueError as e:
                send_frame(conn, b"e", f"плохой запрос: {e}".encode())
                send_frame(conn, b"x", b"2")
                return
            if request.get("op") == "ping":
                send_frame(conn, b"v", json.dumps({"version": version(), "pid": os.getpid(), "jobs": self.jobs}).encode())
                return
            try:
                name, args = request.get("name"), request.get("args") or []
                if not isinstance(name, str) or not isinstance(args, list):
                    raise RuleError("нужны name и args")
                argv, cwd = resolve(name, args, load(self.commands))
            except RuleError as e:
                send_frame(conn, b"e", str(e).encode())
                send_frame(conn, b"x", b"2")
                return
            self.run(conn, name, argv, cwd)

    def run(self, conn, name, argv, cwd):
        try:
            child = subprocess.Popen(argv, cwd=cwd, env=command_env(), stdin=subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        except OSError as e:
            send_frame(conn, b"e", f"не запустил {argv[0]}: {e}".encode())
            send_frame(conn, b"x", b"127")
            return
        with self.lock:
            self.jobs += 1
        log(f"start {name} pid {child.pid}: {' '.join(argv)}")

        def stop_child():
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except OSError:
                    return
                try:
                    child.wait(10)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except OSError:
                        pass

        def watch_client():
            # Клиент больше ничего не пишет: EOF значит, что его прервали, и команду надо остановить.
            try:
                while conn.recv(4096):
                    pass
            except OSError:
                pass
            if child.poll() is None:
                log(f"client gone, stop {name} pid {child.pid}")
                stop_child()

        threading.Thread(target=watch_client, daemon=True).start()
        alive = True
        try:
            while True:
                chunk = os.read(child.stdout.fileno(), 65536)
                if not chunk:
                    break
                if alive:
                    try:
                        send_frame(conn, b"o", chunk)
                    except OSError:
                        alive = False
                        stop_child()
            code = child.wait()
            code = code if code >= 0 else 128 - code
            log(f"end {name} pid {child.pid}: exit {code}")
            if alive:
                send_frame(conn, b"x", str(code).encode())
        except OSError:
            stop_child()
        finally:
            child.stdout.close()
            with self.lock:
                self.jobs -= 1

    def serve_forever(self, listener):
        while True:
            conn, _ = listener.accept()
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()


def listen(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass
    listener = socket.socket(socket.AF_UNIX)
    old = os.umask(0o177)
    try:
        listener.bind(path)
    finally:
        os.umask(old)
    listener.listen(8)
    return listener


def serve():
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    os.chmod(STATE, 0o700)
    pid = open(PIDFILE, "a+")
    try:
        fcntl.flock(pid, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0  # уже работает другой
    if not nested_sandbox_ok():
        log("refuse: running inside a sandbox")
        print("agentmeister host-run: исполнитель запущен внутри песочницы, вне ее запусти agentmeister host-run serve",
              file=sys.stderr)
        return 1
    pid.seek(0)
    pid.truncate()
    pid.write(str(os.getpid()))
    pid.flush()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    log(f"serve {version()} pid {os.getpid()}")
    try:
        Server().serve_forever(listen(SOCK))
    finally:
        try:
            os.remove(SOCK)
        except OSError:
            pass
    return 0


def ping(path=SOCK, timeout=2):
    try:
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(timeout)
            conn.connect(path)
            conn.sendall(b'{"op": "ping"}\n')
            kind, payload = recv_frame(conn)
            return json.loads(payload) if kind == b"v" else None
    except (OSError, ValueError):
        return None


def ensure():
    """Поднять исполнитель из лаунчера сессии, пока песочницы еще нет. Без списка команд не нужен."""
    if not os.path.exists(COMMANDS):
        return
    info = ping()
    if info and info.get("version") == version():
        return
    if info and info.get("jobs"):
        return  # старая версия занята командой, обновится в следующий раз
    if info and isinstance(info.get("pid"), int):
        try:
            os.kill(info["pid"], signal.SIGTERM)
            time.sleep(0.3)
        except OSError:
            pass
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "serve"], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, cwd="/",
                     env=command_env())


def call(name, args, path=SOCK, out=None, err=None):
    out = out or sys.stdout.buffer
    err = err or sys.stderr
    try:
        conn = socket.socket(socket.AF_UNIX)
        conn.connect(path)
    except OSError:
        print("agentmeister host-run: исполнитель не запущен. Он стартует с новой сессией через proxy, "
              "если есть " + tilde(COMMANDS) + ", или запусти agentmeister host-run serve в обычном терминале",
              file=err)
        return 125
    with conn:
        conn.sendall(json.dumps({"name": name, "args": args}).encode() + b"\n")
        while True:
            kind, payload = recv_frame(conn)
            if kind is None:
                print("agentmeister host-run: исполнитель оборвал соединение", file=err)
                return 125
            if kind == b"o":
                out.write(payload)
                out.flush()
            elif kind == b"e":
                print(f"agentmeister host-run: {payload.decode(errors='replace')}", file=err)
            elif kind == b"x":
                return int(payload)


def show_list():
    try:
        rules = load()
    except RuleError as e:
        print(f"{BAD} {e}")
        return 1
    if not rules:
        print(f"{WARN} список пуст. Создай {tilde(COMMANDS)} в обычном терминале, например\n{EXAMPLE}")
        return 0
    for name, rule in sorted(rules.items()):
        tail = " [аргументы]" if rule["args"] else ""
        print(f"  {name:<20} {' '.join(rule['run'])}{tail}  " + paint(f"в {tilde(rule['cwd'])}", "2"))
    return 0


def status():
    info = ping()
    if info:
        print(f"{OK} исполнитель работает (pid {info.get('pid')}, версия {info.get('version')}, "
              f"команд идет {info.get('jobs')})")
    else:
        print(f"{WARN} исполнитель не запущен")
    return show_list()


def stop():
    info = ping()
    if not info:
        print(f"{OK} исполнитель не запущен")
        return 0
    os.kill(info["pid"], signal.SIGTERM)
    print(f"{OK} исполнитель остановлен")
    return 0


USAGE = f"""agentmeister host-run <имя> [аргументы]   выполнить команду из белого списка вне песочницы сессии
agentmeister host-run list                  команды из списка
agentmeister host-run status                работает ли исполнитель
agentmeister host-run serve                 запустить исполнитель (в обычном терминале)
agentmeister host-run stop                  остановить исполнитель

Сессия через proxy работает в песочнице macOS. Команда из списка выполняется вне ее, как в обычном
терминале, и ходит в сеть напрямую. Вывод и код выхода возвращаются в сессию, Ctrl+C останавливает
команду. Список лежит в {tilde(COMMANDS)}, из песочницы его менять нельзя. Пример:
{EXAMPLE}
"args": true разрешает дописывать аргументы в конец команды."""


def main(argv):
    cmd = argv[0] if argv else "status"
    if cmd in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    if cmd == "list":
        return show_list()
    if cmd == "status":
        return status()
    if cmd == "serve":
        return serve()
    if cmd == "stop":
        return stop()
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    return call(cmd, argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
