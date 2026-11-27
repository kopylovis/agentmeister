"""Прокси для сессий Claude Code и Codex.

mihomo слушает HTTP/SOCKS на 127.0.0.1 и отправляет всё через подписку (VLESS, Hysteria2: какой жив).
К серверу он ходит через физический интерфейс, мимо TUN-туннелей VPN вроде Happ.
Внешний веб-трафик Claude Code идет через mihomo. Для Codex действует отдельный строгий профиль.
mihomo запускается с первой такой сессией и останавливается после последней.

Песочница сессии ограничивает сеть и защищает файлы, через которые agentmeister выпускает команды из нее:
список и сокет host-run и папки над ними, настройку и подписку mihomo и его сокет управления (через него
mihomo загрузил бы любой конфиг), папку состояния proxy (записи о сессиях, замок, pid mihomo, журналы) и папки
над ними. Замок сессия не может даже открыть: flock берется и на файле, открытом только для чтения. В папку
состояния пишут лаунчер сессии до песочницы, сторож и команды из обычного терминала. Запись о сессии лаунчер
делает под своим pid, а живой ли он, проверяют сторож и лаунчеры. Поэтому изнутри сессии mihomo не
перезапустить и текущий сервер не узнать: это делается в обычном терминале. proxy test и вложенный proxy run
в сессии обходятся без замка: mihomo для них держит лаунчер этой сессии. Задание перезапуска сессия пишет
сама, поэтому оно только данные (restart_job.py). Границей для кода песочница не служит: сессия может
писать ~/.zshrc, хуки git, настройки Claude и другие файлы, которые потом выполнятся вне нее.
"""
import base64
import fcntl
import ipaddress
import json
import os
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
from pathlib import Path
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from menu import secret  # noqa: E402
from mnrhlib import BAD, HOME, OK, WARN, paint, tilde, tr  # noqa: E402
import mnrhlib  # noqa: E402
import host_run  # noqa: E402

CONF_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "mnrh", "proxy")
CONFIG = os.path.join(CONF_DIR, "config.yaml")
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), "mnrh", "proxy")
HOLDERS = os.path.join(STATE, "holders")
PIDFILE = os.path.join(STATE, "mihomo.pid")
LOCK = os.path.join(STATE, "lock")
LOG = os.path.join(STATE, "mihomo.log")
LAST = os.path.join(STATE, "last")
EXIT = os.path.join(STATE, "exit.json")
# через сокет mnrh спрашивает mihomo, какой сервер из подписки сейчас выбран и по какому протоколу
SOCK = os.path.join(STATE, "mihomo.sock")
# страница с подробностями о выходе: на нее ведет метка proxy в promptsill, если терминал умеет ссылки
PAGE = os.path.join(STATE, "exit.html")
WATCH_PID = os.path.join(STATE, "watch.pid")
WATCH_LOG = os.path.join(STATE, "watch.log")
WATCH_POLL = 2        # как часто сторож смотрит на сеть, группы и серверы: смену сервера он ловит за эти секунды
GUARD_TTL = 1800      # столько сторож верит проверке страны сервера
GUARD_RETRY = 300     # закрытая подписка: так часто сторож заново ищет в ней сервер нужной страны
RESTART_AFTER = 30    # столько секунд группа может стоять на REJECT при живой сети, потом перезапуск mihomo
RESTART_GAP = 300     # если сервер и правда лежит, перезапускать не чаще раза в пять минут
SUB_URL = os.path.join(CONF_DIR, "subscription.url")
SUB_FILE = os.path.join(CONF_DIR, "subscription.txt")
DEFAULT_PORT = 17890
PORT_WINDOW = 50  # порты mihomo выбираются из DEFAULT_PORT..DEFAULT_PORT+49
PROBE_PORT = DEFAULT_PORT + PORT_WINDOW - 1  # порт проверки сторожа, последний в окне; подпискам его не дают
CHECK_URL = "https://1.1.1.1/cdn-cgi/trace"
PROBE_URL = "https://www.gstatic.com/generate_204"


def check_url():
    """Адрес, по которому видно IP и страну выхода: proxy_check_url в config, ответ в формате Cloudflare
    /cdn-cgi/trace (строки ip= и loc=). Нужен, если 1.1.1.1 в сети закрыт."""
    url = mnrhlib.read_config().get("proxy_check_url", "").strip()
    return url if re.match(r"^https?://\S+$", url) else CHECK_URL


def probe_url():
    """Адрес проверки живости серверов в mihomo: proxy_probe_url в config, отвечает 204 или 200. Нужен, если
    gstatic.com в сети закрыт. Меняется после agentmeister proxy restart."""
    url = mnrhlib.read_config().get("proxy_probe_url", "").strip()
    return url if re.match(r"^https?://\S+$", url) else PROBE_URL
SESSION_PROFILE = """(version 1)
(allow default)
(deny network*)
(deny system-socket)
(deny mach-lookup
    (global-name "com.apple.dnssd.service")
    (global-name "com.apple.nsurlsessiond")
    (global-name "com.apple.nsurlsessiond.privileged"))
(allow network-outbound (remote tcp "localhost:{port}"))
"""

CLAUDE_PROFILE = """(version 1)
(allow default)
(deny mach-lookup
    (global-name "com.apple.nsurlsessiond")
    (global-name "com.apple.nsurlsessiond.privileged"))
(deny network-outbound
    (require-all
        (require-any (remote ip "*:80") (remote ip "*:443"))
        (require-not (remote ip "localhost:*"))))
"""

TEMPLATE = """# agentmeister proxy: через proxy идут только сессии agentmeister -x. Файл создаёт agentmeister proxy setup.
# mnrh-country: {country}
mixed-port: {port}
bind-address: 127.0.0.1
allow-lan: false
mode: rule
log-level: warning
interface-name: en0
ipv6: false
# выбор в группах после перезапуска сбрасывается: сторож заново проверяет страну, а не верит старому выбору
profile:
  store-selected: false
proxy-providers:
  vps:
    type: file
    path: ./subscription.txt{filter}
    health-check:
      enable: true
      url: {probe_url}
      interval: 300
{providers}proxy-groups:
  - name: VPS
    type: fallback
    use: [{chain}]
    proxies: [REJECT]
    url: {probe_url}
    interval: 300
  - name: GATE
    type: select
    proxies: [VPS, REJECT]
    use: [{chain}]
{groups}  - name: PROBE
    type: select
    proxies: [REJECT]
    use: [{every}]
listeners:
{listeners}  - name: in-probe
    type: mixed
    port: {probe}
    listen: 127.0.0.1
    proxy: PROBE
rules:
  - MATCH,GATE
"""

# Дополнительная подписка: свой провайдер, своя группа и свой порт. Группа VPS на основном порту идет по всем
# подпискам по очереди (сначала основная), а порт подписки ведет только через ее серверы.
PROVIDER = """  {name}:
    type: file
    path: ./subs/{name}.txt{filter}
    health-check:
      enable: true
      url: {probe_url}
      interval: 300
"""

# Ворота GATE перед каждой группой: обычно в них VPS (выбор fallback), а если сервер вывел не в ту страну, сторож
# ставит в них сервер нужной страны или REJECT. Выбор в группе fallback mihomo через API закрепить не дает.
# PROBE со своим портом в закрытом для сессий окне нужен сторожу, чтобы проверить страну сервера без трафика сессий.
GROUP = """  - name: VPS-{name}
    type: fallback
    use: [{provider}]
    proxies: [REJECT]
    url: {probe_url}
    interval: 300
  - name: GATE-{name}
    type: select
    proxies: [VPS-{name}, REJECT]
    use: [{provider}]
"""

LISTENER = """  - name: in-{name}
    type: mixed
    port: {port}
    listen: 127.0.0.1
    proxy: GATE-{name}
"""

MAIN = "main"  # основная подписка (из proxy setup); в mihomo ее провайдер vps
SUB_NAME = re.compile(r"^[a-z][a-z0-9-]{0,19}$")
RESERVED = {MAIN, "vps", "direct", "reject", "all"}


class ProxyError(Exception):
    pass


def mihomo_bin():
    found = shutil.which("mihomo")
    if found:
        return found
    for path in ("/opt/homebrew/bin/mihomo", "/usr/local/bin/mihomo"):
        if os.access(path, os.X_OK):
            return path
    return None


def configured():
    return os.path.isfile(CONFIG)


def setting(name):
    try:
        with open(CONFIG) as f:
            m = re.search(r"^# mnrh-" + name + r":[ \t]*(\S*)", f.read(), re.M)
        return m.group(1) if m else ""
    except OSError:
        return ""


def port():
    try:
        with open(CONFIG) as f:
            m = re.search(r"^mixed-port:\s*(\d+)", f.read(), re.M)
        return int(m.group(1)) if m else DEFAULT_PORT
    except OSError:
        return DEFAULT_PORT


def subs_meta():
    return os.path.join(CONF_DIR, "subs.json")


def read_subs():
    """subs.json: {"main": {"port"}, "<имя>": {"port", "country", "only"}}. Порядок ключей задает каскад."""
    try:
        with open(subs_meta()) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def good_port(p):
    return isinstance(p, int) and not isinstance(p, bool) and 1 <= p <= 65535


def extra_subs():
    """Дополнительные подписки по порядку каскада: {имя: {"port", "country", "only"}}."""
    out = {}
    for name, v in read_subs().items():
        if name in RESERVED or not SUB_NAME.match(name) or not isinstance(v, dict) or not good_port(v.get("port")):
            continue
        out[name] = {"port": v["port"], "country": str(v.get("country") or "").upper(), "only": str(v.get("only") or "")}
    return out


def main_strict_port():
    """Порт только основной подписки. Он есть, пока есть дополнительные: без них каскад и есть основная."""
    v = read_subs().get(MAIN)
    p = v.get("port") if isinstance(v, dict) else None
    return p if good_port(p) and extra_subs() else None


def sub_names():
    return [MAIN] + list(extra_subs())


def cascade_subs(extras=None):
    """Подписки каскада (просто -x) по порядку. Если у основной задана страна, в каскад идут только подписки
    с той же страной: иначе mihomo посреди сессии перешел бы на запасную в другой стране, а страну проверяют
    только при запуске. Остальные доступны через -x <имя>."""
    extras = extra_subs() if extras is None else extras
    want = setting("country").upper()
    return [MAIN] + [n for n, v in extras.items() if not want or (v.get("country") or "").upper() == want]


def resolve_sub(name):
    """-x <имя>: None (каскад по всем подпискам), MAIN или имя дополнительной. -x main запоминается как выбор
    только основной и без дополнительных подписок: перезапуск после proxy add пойдет через ее отдельный порт."""
    if name in (None, ""):
        return None
    if name == MAIN or name in extra_subs():
        return name
    raise ProxyError(f'нет подписки "{name}", есть {", ".join(sub_names())}')


def sub_port(sub=None):
    if sub is None:
        return port()
    if sub == MAIN:
        return main_strict_port() or port()
    extra = extra_subs().get(sub)
    if not extra:
        raise ProxyError(f'нет подписки "{sub}"')
    return extra["port"]


def sub_files(sub=None):
    """(файл со ссылкой, скачанная подписка)."""
    if sub in (None, MAIN):
        return SUB_URL, SUB_FILE
    folder = os.path.join(CONF_DIR, "subs")
    return os.path.join(folder, f"{sub}.url"), os.path.join(folder, f"{sub}.txt")


def port_key(sub):
    """Чей порт у подписки: у основной без дополнительных своего порта нет, она идет через порт каскада."""
    return None if sub == MAIN and not main_strict_port() else sub


def sub_group(sub=None):
    key = port_key(sub)
    return "VPS" if key is None else f"VPS-{key}"


def gate_group(sub=None):
    key = port_key(sub)
    return "GATE" if key is None else f"GATE-{key}"


def sub_providers(sub=None):
    """Провайдеры mihomo, через которые идет sub: у каскада все по порядку."""
    names = cascade_subs() if sub is None else [sub]
    return ["vps" if name == MAIN else name for name in names]


def sub_country(sub):
    if sub in (None, MAIN):
        return setting("country").upper()
    return (extra_subs().get(sub) or {}).get("country", "")


def exit_file(sub=None):
    key = port_key(sub)
    return EXIT if key is None else os.path.join(STATE, f"exit-{key}.json")


def page_file(sub=None):
    key = port_key(sub)
    return PAGE if key is None else os.path.join(STATE, f"exit-{key}.html")


def read_exit(sub=None):
    try:
        with open(exit_file(sub)) as f:
            info = json.load(f)
    except (OSError, ValueError):
        return {}
    return info if isinstance(info, dict) else {}


def country_problem(sub):
    """Текст, если выход подписки не в стране из ее настройки, иначе None. Берется из exit-файлов, которые
    start пишет для каждого порта. У каскада проверяется его выход, а еще каждая подписка очереди со своим
    портом: если она уже выходит не там, mihomo перешел бы на нее посреди сессии."""
    def where(info):
        return fmt((info["ip"], info.get("loc")) if info.get("ip") else None)

    for key in {sub, port_key(sub)}:
        if read_exit(key).get("blocked"):
            return f"сторож закрыл {sub or 'очередь подписок'}: ни один живой сервер не выходит в нужной стране"
    if sub is not None:
        want, info = sub_country(sub), read_exit(sub)
        if want and (info.get("loc") or "").upper() != want:
            return f"выход через {sub} {where(info)}, а нужен {want}"
        return None
    info = read_exit(None)
    want = sub_country(info.get("sub") or MAIN)
    if want and (info.get("loc") or "").upper() != want:
        return f"выход через {where(info)}, а нужен {want}"
    if main_strict_port():
        for name in cascade_subs():
            need, one = sub_country(name), read_exit(name)
            # подписка без ответа не опасна: mihomo на нее не перейдет, пока ее серверы лежат
            if need and one.get("loc") and one["loc"].upper() != need:
                return f"подписка {name} из очереди выходит через {where(one)}, а нужен {need}"
    return None


def guarded_ports(own):
    """Порты mihomo, закрытые для сессии Claude Code, кроме ее собственного: настроенные сейчас и окно, из
    которого proxy add берет порты новым подпискам. Иначе сессия только через home вышла бы через каскад, а
    каскадная через подписку другой страны."""
    ports = set(range(DEFAULT_PORT, DEFAULT_PORT + PORT_WINDOW)) | set(all_ports().values())
    return sorted(ports - {own} if own else ports)


def all_ports():
    """{подписка: порт} для всех портов mihomo: None (каскад) на mixed-port и порты отдельных подписок."""
    out = {None: port()}
    if main_strict_port():
        out[MAIN] = main_strict_port()
    for name, v in extra_subs().items():
        out[name] = v["port"]
    return out


def owned_by_mihomo(q, pid):
    """Порт слушает именно mihomo с этим pid, а не программа, которая заняла его, пока mihomo перезапускался.
    None: lsof не запустился, проверить нечем."""
    try:
        r = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), f"-iTCP:{q}", "-sTCP:LISTEN", "-t"],
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout.split() == [str(pid)]


def check_owner(sub):
    """Порт каскада и порт подписки сессии слушает mihomo. Иначе трафик сессии ушел бы чужой программе."""
    pid = read_pid()
    for q in sorted({port(), sub_port(sub)}):
        if pid and owned_by_mihomo(q, pid) is False:
            raise ProxyError(f"порт {q} слушает не mihomo. Сессию через proxy не запускаю: agentmeister proxy restart")


def listening(p):
    with socket.socket() as s:
        s.settimeout(1.0)
        return s.connect_ex(("127.0.0.1", p)) == 0


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def read_pid():
    try:
        with open(PIDFILE) as f:
            pid = int(f.read().strip())
    except (OSError, ValueError):
        return None
    try:
        cmd = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    except OSError:
        # в песочнице proxy-сессии ps не запустить: имя не проверить, остается только узнать, жив ли процесс
        return pid if alive(pid) else None
    return pid if os.path.basename(cmd) == "mihomo" else None


def holders():
    try:
        names = os.listdir(HOLDERS)
    except OSError:
        return []
    live = []
    for name in names:
        if name.isdigit() and alive(int(name)):
            live.append(int(name))
        else:
            try:
                os.remove(os.path.join(HOLDERS, name))
            except OSError:
                pass
    return live


def held_subs():
    """Через какие подписки идут сессии: None у каскада, иначе имя. Подписку пишет в запись о сессии лаунчер."""
    used = set()
    for pid in holders():
        try:
            with open(os.path.join(HOLDERS, str(pid))) as f:
                name = f.read().strip()
        except OSError:
            name = ""
        used.add(name if name == MAIN or SUB_NAME.match(name) else None)
    return used


class locked:
    def __enter__(self):
        if in_session():
            raise ProxyError(IN_SESSION)  # папка состояния и замок для сессии закрыты
        os.makedirs(STATE, exist_ok=True)
        os.chmod(STATE, 0o700)  # тут сокет управления mihomo, другим пользователям Mac он ни к чему
        self.f = open(LOCK, "w")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def default_route():
    """Интерфейс маршрута по умолчанию или None, если сети нет."""
    out = subprocess.run(["route", "-n", "get", "default"], capture_output=True, text=True).stdout
    m = re.search(r"interface:\s*(\S+)", out)
    return m.group(1) if m else None


def physical_interface(route=None):
    """Интерфейс маршрута по умолчанию. VPN вроде Happ в режиме TUN ставят свои маршруты 0/1 и 128.0/1,
    а default оставляют на Wi-Fi или Ethernet: его и берём, чтобы ходить к серверу мимо их туннеля."""
    route = default_route() if route is None else route
    return route if route and not route.startswith("utun") else None


def pinned_interface():
    try:
        with open(CONFIG) as f:
            m = re.search(r"(?m)^interface-name:\s*(\S+)", f.read())
    except OSError:
        return None
    return m.group(1) if m else None


def set_line(text, key, line):
    """Заменить строку key: в конфиге на line (пустая line убирает ее) или добавить после log-level."""
    if re.search(rf"^{key}:", text, re.M):
        return re.sub(rf"^{key}:.*$\n?", line + "\n" if line else "", text, flags=re.M)
    return text.replace("log-level: warning\n", f"log-level: warning\n{line}\n") if line else text


def pin_config():
    """Перед стартом mihomo: интерфейс маршрута по умолчанию и сокет управления (в старых конфигах его нет)."""
    iface = physical_interface()
    with open(CONFIG) as f:
        text = f.read()
    new = set_line(text, "interface-name", f"interface-name: {iface}" if iface else "")
    # путь к unix-сокету в macOS не длиннее 104 байт; длиннее mihomo его не откроет, и протокола просто не будет
    sock = f"external-controller-unix: {json.dumps(SOCK)}" if len(SOCK.encode()) < 104 else ""
    new = set_line(new, "external-controller-unix", sock)
    if new != text:
        fd = os.open(CONFIG + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(new)
        os.replace(CONFIG + ".tmp", CONFIG)


# схемы ссылок на серверы в подписке; http(s):// сюда не входит, такие ссылки есть в любой странице
PROXY_SCHEMES = ("vless", "vmess", "trojan", "ss", "ssr", "hysteria", "hysteria2", "hy2", "tuic", "wireguard", "wg",
                 "anytls", "socks", "socks5")


def subscription_text(raw):
    """Текст подписки: как есть или раскодированный base64, если в нем нет ни YAML, ни ссылок."""
    text = raw.decode("utf-8", "replace")
    if "proxies:" not in text and "://" not in text:
        packed = re.sub(rb"\s", b"", raw)
        for decode in (base64.b64decode, base64.urlsafe_b64decode):
            try:
                text = decode(packed + b"=" * (-len(packed) % 4)).decode("utf-8", "replace")
                break
            except ValueError:
                pass
    return text


def proxy_links(text):
    links = []
    for word in text.split():
        scheme = word.partition("://")[0].lower()
        if scheme in PROXY_SCHEMES:
            try:
                if urllib.parse.urlsplit(word).hostname:
                    links.append(word)
            except ValueError:
                pass
    return links


def subscription_ok(raw):
    """В ответе есть хоть один сервер: ссылка vless://, hysteria2:// и т. п. (можно в base64) или YAML mihomo
    с proxies: и server:. Страница входа в Wi-Fi или ошибка с кодом 200 подпиской не считаются."""
    text = subscription_text(raw)
    if proxy_links(text):
        return True
    block = re.search(r"(?m)^proxies:", text)
    return bool(block and re.search(r"\bserver:\s*['\"]?[\w.:-]+", text[block.end():]))


def subscription_servers():
    """Имена серверов из скачанных подписок: YAML mihomo (server: ...) или base64 со ссылками vless://, hysteria2://."""
    names = []
    for name in sub_names():
        try:
            with open(sub_files(name)[1], "rb") as f:
                raw = f.read()
        except OSError:
            continue
        text = subscription_text(raw)
        names += re.findall(r"\bserver:\s*['\"]?([\w.-]+)", text)
        for word in text.split():
            if "://" in word:
                try:
                    names.append(urllib.parse.urlsplit(word).hostname or "")
                except ValueError:
                    pass
    found = set()
    for name in names:
        try:
            ipaddress.ip_address(name)
        except ValueError:
            if re.match(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$", name):
                found.add(name.lower())
    return sorted(found)


def pin_hosts():
    """Адреса серверов подписки в hosts mihomo. mihomo ходит к DNS через Wi-Fi, мимо VPN, и если DNS в системе
    корпоративный (доступен только через туннель), имя сервера он не узнает. Системный резолвер знает его всегда."""
    with open(CONFIG) as f:
        text = f.read()
    block = re.search(r"(?m)^hosts:\n((?:[ \t]+.*\n?)*)", text)
    old = dict(re.findall(r"(?m)^[ \t]+['\"]?([\w.-]+)['\"]?:[ \t]*['\"]?([\d.]+)", block.group(1))) if block else {}
    mapping = {}
    for name in subscription_servers():
        try:
            mapping[name] = socket.getaddrinfo(name, None, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
        except (OSError, IndexError):
            if name in old:
                mapping[name] = old[name]  # сейчас не узнали: остается прошлый адрес
    new = re.sub(r"(?m)^# mnrh-hosts:.*\n", "", text)
    new = re.sub(r"(?m)^hosts:\n(?:[ \t]+.*\n?)*", "", new)
    if mapping:
        new = new.rstrip("\n") + "\n# mnrh-hosts: адреса серверов подписки, agentmeister узнает их через DNS системы при запуске mihomo\n" \
            + "hosts:\n" + "".join(f"  {json.dumps(k)}: {v}\n" for k, v in sorted(mapping.items()))
    if new != text:
        fd = os.open(CONFIG + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(new)
        os.replace(CONFIG + ".tmp", CONFIG)


def mihomo_api(path, method="GET", body=None, timeout=2):
    cmd = ["curl", "-s", "--noproxy", "*", "--max-time", str(timeout), "--unix-socket", SOCK, "-X", method]
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "--data", json.dumps(body)]
    r = subprocess.run(cmd + ["http://mihomo" + path], capture_output=True, text=True)
    try:
        data = json.loads(r.stdout)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def node_info(sub=None):
    """Сервер в группе подписки sub сейчас: {"node", "proto", "sub"}, где sub — подписка, из которой он взят.
    None, если mihomo не ответил или живых серверов нет."""
    # трафик идет через ворота: в них выбор fallback, закрепленный сторожем сервер или REJECT
    gate = mihomo_api(f"/proxies/{gate_group(sub)}").get("now")
    name = mihomo_api(f"/proxies/{sub_group(sub)}").get("now") if gate in (None, "", sub_group(sub)) else gate
    if not isinstance(name, str) or not name or name == "REJECT":
        return None
    # серверы из подписки mihomo по /proxies/<имя> не отдает, только списком провайдера
    for provider in sub_providers(sub):
        nodes = mihomo_api(f"/providers/proxies/{provider}").get("proxies")
        for n in nodes if isinstance(nodes, list) else []:
            if isinstance(n, dict) and n.get("name") == name:
                kind = n.get("type")
                return {"node": name, "proto": kind.lower() if isinstance(kind, str) and kind else None,
                        "sub": MAIN if provider == "vps" else provider}
    return {"node": name, "proto": None, "sub": None}


def active_node(sub=None):
    """(имя сервера, протокол) в группе подписки сейчас; (None, None), если mihomo не ответил или живых нет."""
    info = node_info(sub)
    return (info["node"], info["proto"]) if info else (None, None)


def html(text):
    return str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def write_page(info, p, path=None):
    rows = [("Страна", info.get("loc")), ("IP выхода", info.get("ip")), ("Протокол", info.get("proto")),
            ("Подписка", info.get("sub") if info.get("subs", 1) > 1 else None),
            ("Сервер из подписки", info.get("node")), ("Порт на этом Mac", f"127.0.0.1:{p}"),
            ("mihomo запущен", info.get("since"))]
    body = "".join(f"<tr><th>{html(k)}</th><td>{html(v)}</td></tr>" for k, v in rows if v)
    page = f"""<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Прокси agentmeister</title>
<style>
:root {{ color-scheme: light dark; --bg: #fff; --fg: #1d1d1f; --dim: #6e6e73; --line: #e5e5ea; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg: #1c1c1e; --fg: #f5f5f7; --dim: #98989d; --line: #38383a; }} }}
body {{ background: var(--bg); color: var(--fg); font: 15px -apple-system, system-ui, sans-serif;
       max-width: 560px; margin: 40px auto; padding: 0 16px; }}
h1 {{ font-size: 20px; margin: 0 0 16px; }}
table {{ border-collapse: collapse; width: 100%; }}
th, td {{ text-align: left; padding: 8px 0; border-bottom: 1px solid var(--line); vertical-align: top; }}
th {{ font-weight: 400; color: var(--dim); width: 45%; }}
td {{ font-family: ui-monospace, Menlo, monospace; word-break: break-all; }}
p {{ color: var(--dim); font-size: 13px; line-height: 1.5; }}
</style></head><body>
<h1>Сессия идет через proxy</h1>
<table>{body}</table>
<p>Данные на момент запуска mihomo. Если сервер с тех пор сменился, текущий покажет
<code>agentmeister proxy</code>, а проверка выхода заново <code>agentmeister proxy test</code>.</p>
</body></html>
"""
    with open(path or PAGE, "w") as f:
        f.write(page)


def write_private(path, data):
    fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(path + ".tmp", path)


def refresh_subscription(sub=None):
    """Скачать подписку мимо VPN (сами, а не mihomo). Не вышло: остаётся прошлая копия, если она есть."""
    url_file, sub_file = sub_files(sub)
    try:
        with open(url_file) as f:
            url = f.read().strip()
    except OSError:
        url = ""
    label = f"agentmeister proxy ({sub})" if sub not in (None, MAIN) else "agentmeister proxy"
    if url:
        iface = physical_interface()
        # ссылку curl читает из stdin (-K -), а не из аргументов: их видит ps любого процесса на этом Mac
        cmd = ["curl", "-sf", "--max-time", "15", "-A", "mihomo"] + (["--interface", iface] if iface else []) + ["-K", "-"]
        quoted = url.replace("\\", "\\\\").replace('"', '\\"')
        r = subprocess.run(cmd, input=f'url = "{quoted}"\n'.encode(), capture_output=True)
        if r.returncode == 0 and subscription_ok(r.stdout):
            write_private(sub_file, r.stdout)
            return True
        if r.returncode == 0:
            why = "по ссылке пришел ответ без серверов (страница входа в Wi-Fi или ошибка?)"
        else:
            why = "подписка не скачалась"
    else:
        why = "нет ссылки на подписку"
    if not os.path.exists(sub_file):
        fix = "agentmeister proxy setup" if sub in (None, MAIN) else f"agentmeister proxy add {sub}"
        raise ProxyError(f"{why}, а прошлой копии нет. Проверь ссылку: {fix}")
    print(f"{label}: {why}, беру прошлую копию", file=sys.stderr)
    return False


def refresh_all(need=None):
    """Скачать все подписки разом. Без копии нельзя только основной и подписки этой сессии: файл другой
    mihomo пропустит, и ее порт просто останется без серверов."""
    must = {MAIN, need}

    def one(name):
        try:
            refresh_subscription(name)
        except ProxyError as e:
            if name in must:
                raise
            print(f"agentmeister proxy ({name}): {e}", file=sys.stderr)

    with ThreadPoolExecutor(max_workers=max(1, len(sub_names()))) as pool:
        for future in [pool.submit(one, name) for name in sub_names()]:
            future.result()


_sandboxed = None


def in_session():
    """Мы в сессии через proxy, то есть в ее песочнице: сокет управления mihomo и его настройка закрыты.
    MNRH_PROXY мог и просочиться в обычный терминал, поэтому проверяем и саму песочницу."""
    global _sandboxed
    if not os.environ.get("MNRH_PROXY"):
        return False
    if _sandboxed is None:
        _sandboxed = not host_run.nested_sandbox_ok()
    return _sandboxed


IN_SESSION = "из сессии через proxy это не сделать: песочница закрывает управление mihomo. Выполни в обычном терминале"


def wait_ready(p, deadline):
    """Порт открывается раньше, чем mihomo прочитает подписку: ждём первого настоящего ответа через proxy."""
    while time.time() < deadline:
        r = subprocess.run(["curl", "-q", "--noproxy", "", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "4",
                            "-x", f"http://127.0.0.1:{p}", probe_url()], capture_output=True, text=True)
        if r.stdout.strip() in ("204", "200"):
            return True
        time.sleep(0.5)
    return False


def promptsill_view(key, info):
    """Поля для promptsill (PROMPTSILL_PROXY_FILE): подпись, подробности и закрыта ли подписка. promptsill читает
    файл выхода при каждой отрисовке, так что подпись каскада меняется вместе с его подпиской."""
    loc = info.get("loc")
    country = loc.upper() if isinstance(loc, str) and re.match(r"^[A-Za-z]{2}$", loc) else None
    many = isinstance(info.get("subs"), int) and info["subs"] > 1
    name = (key if key is not None else info.get("sub")) if many else None
    detail = [v for v in (info.get("proto"), info.get("ip")) if isinstance(v, str) and re.match(r"^[\w.:-]{1,40}$", v)]
    return {"label": " ".join(v for v in (name, country) if v), "detail": " ".join(detail),
            "closed": bool(info.get("blocked"))}


def exit_info(sub, p, since, count):
    """Выход через порт подписки: IP и страна от Cloudflare, сервер и протокол от mihomo."""
    got = trace(proxy_env(p))
    node = node_info(sub) or {}
    info = dict({"ip": got[0], "loc": got[1]} if got else {}, node=node.get("node"), proto=node.get("proto"),
                sub=node.get("sub") or (sub if sub else None), subs=count, since=since)
    return dict(info, **promptsill_view(sub, info))


def start(strict=True, sub=None):
    """mihomo на нашем порту: уже запущенный или новый. Вызывать под locked(). sub: подписка сессии (None — каскад
    по всем). strict: если выход не в стране из настройки подписки, выдать ProxyError (новую сессию не
    запускаем), а mihomo, который только что подняли для нее, остановить. Без strict mihomo остается работать,
    а start возвращает текст о не той стране: так перезапускают его при живых сессиях."""
    p = port()
    if read_pid() and listening(p):
        if sub is not None and not listening(sub_port(sub)):
            raise ProxyError(f"mihomo запущен без порта подписки {sub}, перезапусти его: agentmeister proxy restart")
        if not in_session():
            check_owner(sub)
        # страну проверяем и у запущенного: подписка могла начать выходить не там после прошлого запуска
        problem = country_problem(sub)
        if problem and strict:
            raise ProxyError(f"{problem}. Сессию через прокси не запускаю, проверь сервер: agentmeister proxy test")
        return problem
    if in_session():
        # mihomo из песочницы не смог бы ни поправить свою настройку, ни выйти к серверу напрямую
        raise ProxyError(f"mihomo не запущен. {IN_SESSION}: agentmeister proxy restart")
    text = Path(CONFIG).read_text()
    if "GATE" not in text:
        # конфиг до ворот и проверки страны: собрать заново. mixed-port, страна, --only и подписки остаются, а
        # ручные правки уходят, поэтому прежний файл остается рядом
        write_private(CONFIG + ".bak", text.encode())
        rerender()
        print(f"agentmeister proxy: настройка mihomo собрана заново, прежняя в {tilde(CONFIG)}.bak", file=sys.stderr)
    pin_config()
    refresh_all(sub)
    pin_hosts()
    ports = all_ports()
    for name, q in ports.items():
        if listening(q):
            where = f"mixed-port в {tilde(CONFIG)}" if name is None else f"port у {name} в {tilde(subs_meta())}"
            # без порта каскада и порта этой сессии запускать нечего, чужой порт mihomo просто пропустит
            if name is None or name == port_key(sub):
                raise ProxyError(f"порт {q} занят другой программой. Поменяй {where}")
            print(f"agentmeister proxy: порт {q} подписки {name} занят другой программой, она не заработает. "
                  f"Поменяй {where}", file=sys.stderr)
    exe = mihomo_bin()
    if not exe:
        raise ProxyError("нет mihomo: brew install mihomo")
    os.makedirs(STATE, exist_ok=True)
    with open(LOG, "a") as log:
        proc = subprocess.Popen([exe, "-d", CONF_DIR, "-f", CONFIG], stdin=subprocess.DEVNULL, stdout=log,
                                stderr=subprocess.STDOUT, start_new_session=True)
    with open(PIDFILE, "w") as f:
        f.write(str(proc.pid))
    for _ in range(100):
        if listening(p) or proc.poll() is not None:
            break
        time.sleep(0.1)
    if not listening(p):
        raise ProxyError(f"mihomo не поднялся на порту {p}, смотри {tilde(LOG)}")
    try:
        check_owner(sub)
    except ProxyError:
        if not holders():
            stop()
        raise
    since = time.strftime("%Y-%m-%d %H:%M")

    def ready_and_exit(item):
        # каждый порт ждет свои 15 секунд: мертвая подписка не съедает время у остальных
        name, q = item
        ok = wait_ready(q, time.time() + 15)
        return ok, exit_info(name, q, since, len(sub_names()))

    with ThreadPoolExecutor(max_workers=len(ports)) as pool:
        results = dict(zip(ports, pool.map(ready_and_exit, ports.items())))
    if not results.get(port_key(sub), (True, None))[0]:
        print(f"agentmeister proxy: proxy пока не отвечает, запросы могут завершаться ошибкой (лог {tilde(LOG)})",
              file=sys.stderr)
    for name, (_, info) in results.items():
        try:
            with open(exit_file(name), "w") as f:
                json.dump(info, f, ensure_ascii=False)
            write_page(info, ports[name], page_file(name))
        except OSError:
            pass
    problem = country_problem(sub)
    if problem and strict:
        if not holders():
            stop()  # mihomo подняли для этой сессии; сессии, которые его держат, без него остались бы без сети
        raise ProxyError(f"{problem}. Сессию через прокси не запускаю, проверь сервер: agentmeister proxy test")
    return problem


def stop():
    pid = read_pid()
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        for _ in range(30):
            if not alive(pid):
                break
            time.sleep(0.1)
    extra = [os.path.join(STATE, n) for n in (os.listdir(STATE) if os.path.isdir(STATE) else [])
             if re.match(r"^exit-[a-z][a-z0-9-]*\.(json|html)$", n)]
    for path in [PIDFILE, EXIT, PAGE] + extra:
        try:
            os.remove(path)
        except OSError:
            pass
    return pid is not None


def watch_step(state, now, route, pinned, group):
    """Одно решение сторожа. state: dict с reject_since и restarted_at, меняется на месте. route: интерфейс
    маршрута по умолчанию или None без сети, pinned: interface-name в конфиге, group: кто сейчас в группе VPS.
    Возвращает список действий: repin, healthcheck, restart."""
    if route is None:
        state["reject_since"] = None  # сети нет: ждать нечего, сервер честно недоступен
        return []
    if physical_interface(route) != pinned:
        state["reject_since"] = None
        return ["repin", "healthcheck"]
    if group != "REJECT":
        state["reject_since"] = None
        return []
    if state.get("reject_since") is None:
        state["reject_since"] = now
        return ["healthcheck"]
    restarted = state.get("restarted_at")
    if now - state["reject_since"] >= RESTART_AFTER and (restarted is None or now - restarted >= RESTART_GAP):
        state["reject_since"], state["restarted_at"] = None, now
        return ["restart"]
    return []


def watch_log(text):
    try:
        with open(WATCH_LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + text + "\n")
    except OSError:
        pass


def restart_mihomo():
    """Перезапустить mihomo на месте: сессии через proxy остаются, их текущие запросы обрываются. Под locked().
    Страну выхода не требуем: если остановить mihomo, все сессии через proxy останутся без сети, а сервер
    часто недоступен как раз тогда, когда его перезапускают. Возвращает текст о не той стране или None."""
    stop()
    return start(strict=False)


REVIVE_GAP = 30  # mihomo упал при живых сессиях: поднимать снова не чаще раза в 30 секунд


def revive(state, now):
    """mihomo не работает. False: сессий через proxy больше нет и сторожу пора выйти. Под locked()."""
    if not holders():
        return False
    if read_pid() and listening(port()):
        return True
    if now - state.get("revived_at", 0) < REVIVE_GAP:
        return True
    state["revived_at"] = now
    watch_log("mihomo не работает, а сессии через proxy идут: запускаю его снова")
    try:
        problem = start(strict=False)
    except (ProxyError, OSError) as e:
        watch_log(f"запуск: {e}")
    else:
        if problem:
            watch_log(f"{problem}, но mihomo оставлен: сессии через proxy без него остались бы без сети")
    return True


class Guard:
    """Страна выхода во время работы. Сторож видит, что mihomo переключился на другой сервер, сразу закрывает
    ворота подписки (REJECT), проверяет страну нового сервера через порт PROBE и открывает ворота, только если
    она та. Если нет, ставит в ворота живой сервер нужной страны из той же подписки, а если такого нет, ворота
    остаются закрыты, и сессия получает отказ, как при упавших серверах. Между переключением в mihomo и тем,
    как сторож его увидит, проходит до WATCH_POLL секунд."""

    def __init__(self, api=None, probe=None, clock=time.time, log=None):
        self.api = api or mihomo_api
        self.probe_fn = probe or self.probe_exit
        self.clock = clock
        self.log = log or watch_log
        self.seen = {}      # подписка -> сервер, который выбрал fallback при прошлом взгляде
        self.cache = {}     # сервер -> (страна или None, когда проверен)
        self.searched = {}  # подписка с закрытыми воротами -> когда искали сервер нужной страны
        self.pid = None

    def reset(self, pid=None):
        """mihomo перезапущен или перечитал конфиг: ворота снова на выборе fallback, проверять заново."""
        self.seen.clear()
        self.searched.clear()
        self.pid = pid
        for key in all_ports():
            info = read_exit(key)
            if info.get("node") and info.get("loc") and not info.get("blocked"):
                self.cache[info["node"]] = (info["loc"].upper(), self.clock())

    def probe_exit(self, node):
        """Страна выхода сервера: PROBE на этот сервер и запрос через порт PROBE."""
        self.api("/proxies/PROBE", "PUT", {"name": node})
        got = trace({"HTTPS_PROXY": f"http://127.0.0.1:{PROBE_PORT}"})
        return (got[1] or "").upper() or None if got else None

    def country(self, node):
        loc, at = self.cache.get(node, (None, 0))
        if node in self.cache and self.clock() - at < GUARD_TTL:
            return loc
        loc = self.probe_fn(node)
        self.cache[node] = (loc, self.clock())
        return loc

    def nodes(self, key):
        """Живые серверы подписки (у каскада всех подписок очереди) по порядку: (имя, подписка)."""
        out = []
        for provider in sub_providers(key):
            listed = self.api(f"/providers/proxies/{provider}").get("proxies")
            for n in listed if isinstance(listed, list) else []:
                if isinstance(n, dict) and isinstance(n.get("name"), str) and n.get("alive") is not False:
                    out.append((n["name"], MAIN if provider == "vps" else provider))
        return out

    def want(self, key, node_sub):
        return sub_country(key) if key is not None else sub_country(node_sub or MAIN)

    def node_sub(self, key, node):
        return next((sub for name, sub in self.nodes(key) if name == node), None)

    def record(self, key, node, sub, loc, blocked=False):
        info = dict(read_exit(key), node=node, sub=sub, loc=loc, blocked=blocked, checked=time.strftime("%H:%M:%S"))
        if blocked:
            info.pop("ip", None)
        info.update(promptsill_view(key, info))
        try:
            with open(exit_file(key), "w") as f:
                json.dump(info, f, ensure_ascii=False)
        except OSError:
            pass

    def search(self, key, gate):
        """Найти живой сервер нужной страны и поставить его в ворота. Не нашелся: ворота закрыты."""
        self.searched[key] = self.clock()
        for node, sub in self.nodes(key):
            want = self.want(key, sub)
            if want and self.country(node) == want:
                self.api(f"/proxies/{gate}", "PUT", {"name": node})
                self.record(key, node, sub, want)
                self.log(f"{gate}: закреплен сервер {node} ({want})")
                return True
        self.api(f"/proxies/{gate}", "PUT", {"name": "REJECT"})
        self.record(key, None, None, None, blocked=True)
        self.log(f"{gate}: живого сервера нужной страны нет, подписка закрыта")
        return False

    def step(self, key):
        fallback, gate = sub_group(key), gate_group(key)
        chosen = self.api(f"/proxies/{fallback}").get("now")
        current = self.api(f"/proxies/{gate}").get("now")
        if not current or not chosen:
            return  # mihomo не ответил или конфиг без ворот
        changed = self.seen.get(key) != chosen
        self.seen[key] = chosen
        if chosen == "REJECT" and current in (fallback, "REJECT"):
            return  # живых серверов нет, трафик и так отклоняется
        if current == fallback:
            if not changed:
                return  # сервер тот же и уже проверен: список серверов каждые 2 секунды не запрашиваем
            sub = self.node_sub(key, chosen)
            want = self.want(key, sub)
            if not want:
                # страна не задана: закрывать нечего, но подпись в promptsill должна показать новый сервер
                self.record(key, chosen, sub, self.country(chosen))
                return
            if self.cache.get(chosen, (None, 0))[0] == want and self.clock() - self.cache[chosen][1] < GUARD_TTL:
                # страна уже проверена: закрывать не нужно, но файл выхода (и подпись promptsill) про новый сервер
                self.record(key, chosen, sub, want)
                return
            # новый сервер: закрыть, пока не проверен, чтобы трафик сессий не ушел через другую страну
            self.api(f"/proxies/{gate}", "PUT", {"name": "REJECT"})
            loc = self.country(chosen)
            if loc == want:
                self.api(f"/proxies/{gate}", "PUT", {"name": fallback})
                self.record(key, chosen, sub, loc)
                self.log(f"{gate}: сервер {chosen} выходит в {loc}, открыто")
                return
            self.log(f"{gate}: сервер {chosen} выходит в {loc or 'неизвестно где'}, а нужен {want}")
            self.search(key, gate)
            return
        # ворота держит сторож: закрыты или на закрепленном сервере. fallback сменил сервер: может, он подходит
        if changed and chosen != "REJECT":
            sub = self.node_sub(key, chosen)
            want = self.want(key, sub)
            if want and self.country(chosen) == want:
                self.api(f"/proxies/{gate}", "PUT", {"name": fallback})
                self.searched.pop(key, None)
                self.record(key, chosen, sub, want)
                self.log(f"{gate}: fallback снова на {chosen} ({want}), открыто")
                return
        if self.clock() - self.searched.get(key, 0) < (GUARD_RETRY if current == "REJECT" else 30):
            return
        if current == "REJECT":
            self.search(key, gate)
        elif not any(name == current for name, _ in self.nodes(key)):
            self.log(f"{gate}: закрепленный сервер {current} перестал отвечать")
            self.api(f"/proxies/{gate}", "PUT", {"name": "REJECT"})
            self.search(key, gate)
        else:
            self.searched[key] = self.clock()  # закрепленный жив, следующая проверка через 30 секунд


def watch():
    """Сторож, пока идут сессии через proxy. mihomo сам не узнает, что сеть вернулась через другой интерфейс,
    а мертвый сервер перепроверяет раз в пять минут, и все это время группа VPS отклоняет запросы."""
    with open(WATCH_PID, "w") as f:
        f.write(str(os.getpid()))
    state = {}
    guard = Guard()
    watch_log("сторож запущен")
    try:
        while True:
            time.sleep(WATCH_POLL)
            if not (read_pid() and listening(port())):
                with locked():
                    if not revive(state, time.time()):
                        break  # mihomo остановлен после последней сессии
                continue
            route = default_route()
            used = held_subs() or {None}
            pid = read_pid()
            if pid != guard.pid:
                guard.reset(pid)
            if route:
                for key in {port_key(sub) for sub in used}:
                    try:
                        guard.step(key)
                    except (ProxyError, OSError) as e:
                        watch_log(f"проверка страны: {e}")
            nows = {sub: mihomo_api(f"/proxies/{sub_group(sub)}").get("now") for sub in used} if route else {}
            dead = {sub for sub, now in nows.items() if now == "REJECT"}
            # подписка только что осталась без живых серверов: перепроверить ее серверы сразу, а не через 5 минут
            for sub in dead - state.get("dead", set()):
                for provider in sub_providers(sub):
                    mihomo_api(f"/providers/proxies/{provider}/healthcheck", timeout=10)
            state["dead"] = dead
            # mihomo перезапускаем, только когда лежат все подписки сессий: иначе перезапуск оборвал бы запросы
            # живых сессий из-за одной мертвой подписки
            group = "REJECT" if nows and len(dead) == len(nows) else \
                next((n for n in nows.values() if n and n != "REJECT"), None)
            for action in watch_step(state, time.time(), route, pinned_interface(), group):
                try:
                    if action == "repin":
                        with locked():
                            old = pinned_interface()
                            pin_config()
                            mihomo_api("/configs?force=true", "PUT", {"path": CONFIG}, timeout=10)
                        guard.reset(read_pid())  # перезагрузка сбросила ворота
                        watch_log(f"интерфейс {old} -> {pinned_interface()}, конфиг mihomo перезагружен")
                    elif action == "healthcheck":
                        for provider in dict.fromkeys(p for sub in used for p in sub_providers(sub)):
                            mihomo_api(f"/providers/proxies/{provider}/healthcheck", timeout=10)
                    elif action == "restart":
                        watch_log(f"сеть есть, а сервер недоступен {RESTART_AFTER} с, перезапускаю mihomo")
                        with locked():
                            problem = restart_mihomo()
                        if problem:
                            watch_log(f"{problem}, но mihomo оставлен: сессии через proxy без него остались бы "
                                      "без сети")
                except (ProxyError, OSError) as e:
                    watch_log(f"{action}: {e}")
    finally:
        watch_log("сторож остановлен")
        try:
            os.remove(WATCH_PID)
        except OSError:
            pass


def is_watcher(pid):
    """pid из watch.pid — правда наш сторож? После сбоя или перезагрузки номер мог достаться другому процессу.
    None: ps не запустился, проверить нечем."""
    try:
        line = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
    except OSError:
        return None
    args = line.split()
    # claude_proxy.py: сторож, запущенный до переименования файла, тоже наш
    return args[-1:] == ["watch"] and any(os.path.basename(a) in ("proxy.py", "claude_proxy.py") for a in args[:-1])


def watcher_alive():
    try:
        with open(WATCH_PID) as f:
            pid = int(f.read().strip())
    except (OSError, ValueError):
        return False
    return pid > 0 and alive(pid) and is_watcher(pid) is not False


def ensure_watch():
    """Запустить сторожа, если его еще нет. Под locked(), после start(). Из песочницы сторож до mihomo не
    достучится, его запускает только лаунчер сессии."""
    if in_session() or watcher_alive():
        return
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "watch"], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, cwd="/")


def both_forms(path):
    out = []
    for form in (os.path.abspath(path), os.path.realpath(path)):
        if form not in out:
            out.append(form)
    return out


def guarded_paths():
    """Что закрыто для сессии, как есть и после раскрытия ссылок: сокет управления mihomo, папки настройки
    и состояния, замок и папки над ними."""
    secrets = [f for path in (SUB_URL, SUB_FILE, os.path.join(CONF_DIR, "vps.yaml")) for f in both_forms(path)]
    return {"SOCK": both_forms(SOCK), "CONF": both_forms(CONF_DIR), "STATE": both_forms(STATE),
            "LOCK": both_forms(LOCK), "UP": host_run.parents(CONF_DIR, STATE),
            "SECRET": secrets, "SUBS": both_forms(os.path.join(CONF_DIR, "subs"))}


def sandbox_profile_lines():
    """Сокет управления mihomo: подключиться, удалить или подменить нельзя. Настройку и подписку менять нельзя:
    mihomo прочитал бы их при следующем запуске вне песочницы. В папке состояния нельзя ничего менять (сессия
    стерла бы чужие записи или подделала pid mihomo), а замок нельзя и открыть. Жесткая ссылка на эти файлы
    писала бы в них же и открывала бы замок под другим именем, поэтому их тоже нельзя. Папки над настройкой
    и состоянием нельзя переименовать или заменить ссылкой."""
    paths = guarded_paths()

    def refs(kind, kind_filter):
        return " ".join(f'({kind_filter} (param "MIHOMO_{kind}{i}"))' for i in range(len(paths[kind])))

    # ссылки на подписки и скачанные подписки с ключами серверов сессии не нужны: читать их нельзя.
    # config.yaml и subs.json читать можно, по ним сессия узнает свой порт и имена подписок
    lines = [f"(deny network-outbound {refs('SOCK', 'literal')})",
             f"(deny file-write* file-link {refs('SOCK', 'literal')} {refs('CONF', 'subpath')} "
             f"{refs('STATE', 'subpath')})",
             f"(deny file-read* {refs('LOCK', 'literal')} {refs('SECRET', 'literal')} {refs('SUBS', 'subpath')})"]
    if paths["UP"]:
        lines.append(f"(deny file-write* {refs('UP', 'literal')})")
    return lines


def sandbox_params():
    return [a for kind, paths in guarded_paths().items() for i, path in enumerate(paths)
            for a in ("-D", f"MIHOMO_{kind}{i}={path}")]


def session_command(p, cmd, *, claude=False):
    if not 1 <= p <= 65535:
        raise ValueError(f"Недопустимый порт proxy: {p}")
    guard = "\n".join(sandbox_profile_lines()) + "\n"
    if claude:
        # Список команд host-run и его сокет сессия видит, но поменять не может. mihomo ей не подвластен.
        # Чужие порты mihomo закрыты: сессия идет только через свою подписку или свой каскад.
        # "*:" а не "localhost:": адрес ::ffff:127.0.0.1 тоже ведет на mihomo. Занять порты mihomo сессия тоже
        # не может, свой в том числе: пока mihomo перезапускается, на порту оказалась бы ее программа
        ports = "".join(f'(deny network-outbound (remote ip "*:{q}"))\n' for q in guarded_ports(p)) + \
            "".join(f'(deny network-bind (local ip "*:{q}"))\n' for q in guarded_ports(None))
        profile = CLAUDE_PROFILE + "\n".join(host_run.sandbox_profile_lines()) + "\n" + ports + guard
        return ["/usr/bin/sandbox-exec", *host_run.sandbox_params(), *sandbox_params(), "-p", profile, "--", *cmd]
    # список команд host-run исполнитель выполняет вне песочницы с прямой сетью: менять его нельзя и здесь
    profile = SESSION_PROFILE.format(port=p) + "\n".join(host_run.sandbox_profile_lines()) + "\n"
    params = host_run.sandbox_params() + sandbox_params()
    agent = os.environ.get("SSH_AUTH_SOCK", "")
    if os.path.isabs(agent):
        path = os.path.realpath(agent)
        try:
            info = os.stat(path)
        except OSError:
            pass
        else:
            if info.st_uid == os.getuid() and stat.S_ISSOCK(info.st_mode):
                params += ["-D", f"SSH_AUTH_SOCK={path}"]
                profile += '(allow network-outbound (literal (param "SSH_AUTH_SOCK")))\n'
    # запреты mihomo последними: в профиле побеждает последнее подходящее правило
    return ["/usr/bin/sandbox-exec", *params, "-p", profile + guard, "--", *cmd]


def proxy_env(p, *, claude=False, sub=None):
    url = f"http://127.0.0.1:{p}"
    env = dict(os.environ)
    for name in ("HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"):
        env[name] = url
    env["ALL_PROXY"] = env["all_proxy"] = f"socks5h://127.0.0.1:{p}"
    env["NO_PROXY"] = env["no_proxy"] = "localhost,127.0.0.1,::1" if claude else ""
    env["MNRH_PROXY"] = str(p)
    # подписка сессии: перезапуск и новые окна из нее пойдут через нее же
    if sub is None:
        env.pop("MNRH_PROXY_SUB", None)
    else:
        env["MNRH_PROXY_SUB"] = sub
    # promptsill (строка состояния) покажет "proxy KZ", а рядом "vless 203.0.113.7" или, если терминал
    # умеет ссылки, сделает метку ссылкой на страницу с подробностями. Все это проверено при старте mihomo.
    try:
        with open(exit_file(sub)) as f:
            info = json.load(f)
    except (OSError, ValueError):
        info = {}
    loc, ip, proto = info.get("loc"), info.get("ip"), info.get("proto")
    # подписку в строке состояния видно, только когда их несколько
    shown = info.get("sub") if isinstance(info.get("subs"), int) and info["subs"] > 1 else None
    for name in ("PROMPTSILL_PROXY_LABEL", "PROMPTSILL_PROXY_DETAIL", "PROMPTSILL_PROXY_URL"):
        env.pop(name, None)
    # сессия только через одну подписку видит ее имя рядом со страной: "proxy test GE". У каскада подписка
    # меняется на ходу, а переменная задается при запуске, поэтому там только страна
    strict = sub if sub is not None and shown else None
    country = loc.upper() if isinstance(loc, str) and re.match(r"^[A-Za-z]{2}$", loc) else None
    label = " ".join(v for v in (strict, country) if v)
    if label:
        env["PROMPTSILL_PROXY_LABEL"] = label
    detail = [v for v in (None if strict else shown, proto, ip) if isinstance(v, str) and re.match(r"^[\w.:-]{1,40}$", v)]
    if detail:
        env["PROMPTSILL_PROXY_DETAIL"] = " ".join(detail)
    if os.path.exists(page_file(sub)):
        env["PROMPTSILL_PROXY_URL"] = "file://" + urllib.parse.quote(page_file(sub))
    # promptsill читает этот файл при каждой отрисовке: подпись следует за каскадом и показывает закрытую подписку
    env.pop("PROMPTSILL_PROXY_FILE", None)
    if os.path.exists(exit_file(sub)):
        env["PROMPTSILL_PROXY_FILE"] = os.path.abspath(exit_file(sub))
    return env


def run(cmd, *, claude=False, sandbox=True, sub=None):
    """sandbox=False (proxy run --no-sandbox): mihomo и переменные proxy без sandbox-exec. Для обновления
    агентов: brew upgrade распаковывает в своей песочнице macOS, а вложенную песочницу macOS не дает.
    sub (proxy run --via <имя>): только через эту подписку, без него каскад по всем."""
    if not cmd:
        print("agentmeister proxy run [--via <подписка>] -- <команда>", file=sys.stderr)
        return 2
    if not configured():
        print(f"agentmeister proxy: прокси не настроен, сначала agentmeister proxy setup", file=sys.stderr)
        return 2
    try:
        sub = resolve_sub(sub)
    except ProxyError as e:
        # подписку удалили или в имени опечатка. Каскадом ее не подменяем: он мог бы выйти из другой страны
        print(f"agentmeister proxy: {e}. Сессию не запускаю: выбери подписку или просто -x (по очереди)",
              file=sys.stderr)
        return 2
    if in_session():
        return run_inside(cmd, claude=claude, sub=sub)
    with locked():
        try:
            start(sub=sub)
        except ProxyError as e:
            print(f"agentmeister proxy: {e}", file=sys.stderr)
            return 1
        ensure_watch()
        if claude:
            host_run.ensure()
        os.makedirs(HOLDERS, exist_ok=True)
        mark = os.path.join(HOLDERS, str(os.getpid()))
        with open(mark, "w") as f:
            f.write(sub or "")
    # Ctrl+C и Ctrl+\ достаются Claude Code, а не нам: мы только ждём и убираем за собой.
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGQUIT, signal.SIG_IGN)
    try:
        p = sub_port(sub)
        if claude and sys.stdin.isatty() and sys.stdout.isatty():
            from claude_proxy_restart import supervised_command
            cmd = supervised_command(cmd)
        child = subprocess.Popen(session_command(p, cmd, claude=claude) if sandbox else cmd,
                                 env=proxy_env(p, claude=claude, sub=sub))
    except (OSError, ValueError, ProxyError) as e:
        print(f"agentmeister proxy: не запустил {cmd[0]}: {e}", file=sys.stderr)
        child = None

    def forward(sig, _frame):
        if child and child.poll() is None:
            child.send_signal(sig)

    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, forward)
    code = 127
    if child:
        while True:
            try:
                code = child.wait()
                break
            except InterruptedError:
                continue
    with locked():
        try:
            os.remove(mark)
        except OSError:
            pass
        if not holders():
            stop()
    return code if code >= 0 else 128 - code


def run_inside(cmd, *, claude=False, sub=None):
    """proxy run изнутри сессии через proxy. mihomo держит лаунчер этой сессии, поэтому ни замок, ни своя
    запись о сессии не нужны (папка состояния для сессии закрыта). Вложенную песочницу macOS не дает:
    команда остается в песочнице этой сессии. Без --via она идет через подписку этой сессии."""
    try:
        mine = resolve_sub(os.environ.get("MNRH_PROXY_SUB"))
    except ProxyError:
        mine = None
    if sub is not None and sub != mine:
        # порт другой подписки песочница сессии все равно закрывает
        print(f"agentmeister proxy: эта сессия идет через {mine or 'подписки по очереди'}, другую подписку "
              "изнутри не выбрать", file=sys.stderr)
        return 2
    sub = mine
    try:
        start(strict=False, sub=sub)  # в сессии только проверяет, что mihomo работает
        p = sub_port(sub)
    except ProxyError as e:
        print(f"agentmeister proxy: {e}", file=sys.stderr)
        return 1
    if not claude:
        print("agentmeister proxy: команда идет в песочнице этой сессии, вложенную macOS не дает", file=sys.stderr)
    if claude and sys.stdin.isatty() and sys.stdout.isatty():
        from claude_proxy_restart import supervised_command
        cmd = supervised_command(cmd)
    try:
        os.execvpe(cmd[0], cmd, proxy_env(p, claude=claude, sub=sub))
    except OSError as e:
        print(f"agentmeister proxy: не запустил {cmd[0]}: {e}", file=sys.stderr)
        return 127


def trace(env=None):
    proxy = env.get("HTTPS_PROXY") if env else None
    cmd = ["curl", "-q", "-s", "--max-time", "12", "--noproxy", "" if proxy else "*"]
    if proxy:
        cmd += ["-x", proxy]
    cmd.append(check_url())
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    info = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    return (info.get("ip"), info.get("loc")) if info.get("ip") else None


def check():
    """(напрямую, через proxy) для каскада, как check_all без дополнительных подписок."""
    return check_all()[0][1:]


def check_all(subs=(None,)):
    """Запустить mihomo, если надо, и сравнить выход напрямую и через proxy: [(подписка, напрямую, через нее)].
    В сессии mihomo уже держит ее лаунчер: замок не нужен, а запустить или остановить mihomo оттуда все равно
    нельзя."""
    if in_session():
        start(strict=False)  # только проверяет, что mihomo работает
        return [(sub,) + check_exit(sub) for sub in subs]
    with locked():
        start(strict=False)  # proxy test показывает и не ту страну, а не отказывает
        was_held = bool(holders())
    try:
        return [(sub,) + check_exit(sub) for sub in subs]
    finally:
        with locked():
            if not was_held and not holders():
                stop()


def check_exit(sub=None):
    direct, via = trace(), None
    for _ in range(3):  # подписку mihomo качает при старте, первая попытка может не успеть
        via = trace(proxy_env(sub_port(sub)))
        if via:
            break
        time.sleep(2)
    return direct, via


def main_only(text=None):
    """Выражение --only основной подписки: строка filter у провайдера vps в конфиге."""
    if text is None:
        try:
            with open(CONFIG) as f:
                text = f.read()
        except OSError:
            return ""
    block = re.search(r"(?m)^  vps:\n((?:    .*\n?)*)", text)
    m = re.search(r"(?m)^    filter:[ \t]*(.+?)[ \t]*$", block.group(1)) if block else None
    if not m:
        return ""
    try:
        value = json.loads(m.group(1))
    except ValueError:
        return m.group(1).strip("'\"")
    return value if isinstance(value, str) else ""


def only_line(only):
    return f"\n    filter: {json.dumps(only)}" if only else ""


def render_config(p, country, only, data):
    """Конфиг mihomo целиком: основная подписка и дополнительные из data (содержимое subs.json)."""
    want = country.upper()
    extras = {n: v for n, v in data.items() if n not in RESERVED and SUB_NAME.match(n) and isinstance(v, dict)
              and good_port(v.get("port"))}
    strict = (data.get(MAIN) or {}).get("port") if extras else None
    groups = listeners = ""
    if extras and good_port(strict):
        groups = GROUP.format(name=MAIN, provider="vps", probe_url=probe_url()) + \
            "".join(GROUP.format(name=n, provider=n, probe_url=probe_url()) for n in extras)
        listeners = LISTENER.format(name=MAIN, port=strict) + \
            "".join(LISTENER.format(name=n, port=v["port"]) for n, v in extras.items())
    return TEMPLATE.format(port=p, country=country.upper(), filter=only_line(only),
                           probe_url=probe_url(),
                           providers="".join(PROVIDER.format(name=n, filter=only_line(str(v.get("only") or "")),
                                                             probe_url=probe_url())
                                             for n, v in extras.items()),
                           chain=", ".join(["vps"] + [n for n, v in extras.items()
                                                      if not want or str(v.get("country") or "").upper() == want]),
                           every=", ".join(["vps"] + list(extras)), probe=PROBE_PORT,
                           groups=groups, listeners=listeners)


def save_subs(data):
    """Записать subs.json. Без дополнительных подписок файл не нужен: порт только основной тоже."""
    if not [n for n in data if n != MAIN]:
        Path(subs_meta()).unlink(missing_ok=True)
        return
    write_private(subs_meta(), (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode())


def place_main_port(data, main_port=None):
    """У основной подписки есть свой порт, пока есть дополнительные: -x main идет только через нее."""
    if [n for n in data if n != MAIN] and not good_port((data.get(MAIN) or {}).get("port")):
        taken = {main_port or port()} | {v.get("port") for v in data.values() if isinstance(v, dict)}
        data[MAIN] = {"port": free_port(taken)}
    return data


def rerender(data=None):
    """Пересобрать конфиг из основной подписки и subs.json. Правки руками, кроме mixed-port, пропадут, а
    interface-name, сокет управления и hosts start допишет сам."""
    data = place_main_port(read_subs() if data is None else data)
    text = render_config(port(), setting("country"), main_only(), data)
    write_private(CONFIG, text.encode())
    return data


def write_config(url, p, country="", only=""):
    os.makedirs(CONF_DIR, mode=0o700, exist_ok=True)
    os.chmod(CONF_DIR, 0o700)
    data = read_subs()
    if MAIN in data and (data[MAIN] or {}).get("port") == p:
        data.pop(MAIN)  # основной порт занял порт только основной подписки: выберем ей новый
    data = place_main_port(data, p)
    save_subs(data)
    write_private(CONFIG, render_config(p, country, only, data).encode())
    write_private(SUB_URL, url.encode())
    for old in (SUB_FILE, os.path.join(CONF_DIR, "vps.yaml")):
        if os.path.exists(old):
            os.remove(old)


def free_port(taken=()):
    p = DEFAULT_PORT
    while (p in taken or listening(p) or p == PROBE_PORT) and p < DEFAULT_PORT + PORT_WINDOW - 2:
        p += 1
    return p


def install_mihomo():
    brew = shutil.which("brew") or next((b for b in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew")
                                         if os.access(b, os.X_OK)), None)
    if not brew:
        print(f"{BAD} нет mihomo и нет Homebrew. Поставь mihomo: https://wiki.metacubex.one")
        return False
    if sys.stdin.isatty():
        answer = input("Нужен mihomo. Поставить через brew install mihomo? [Y/n] ").strip().lower()
        if answer not in ("", "y", "yes", "д", "да"):
            return False
    print("brew install mihomo …")
    subprocess.run([brew, "install", "mihomo"])
    return bool(mihomo_bin())


def sub_options(args):
    """Разобрать [ссылка] --country XX --only RE. -> (rest, country, only) или None, если ошибка уже напечатана."""
    opts, rest, it = {}, [], iter(args)
    for a in it:
        if a in ("--country", "--only"):
            opts[a[2:]] = next(it, "")
        else:
            rest.append(a)
    country, only = opts.get("country", "").strip(), opts.get("only", "").strip()
    if country and not re.match(r"^[A-Za-z]{2}$", country):
        print(f"{BAD} --country ждёт код страны из двух букв, например DE")
        return None
    if only:
        try:
            re.compile(only)
        except re.error as e:
            print(f"{BAD} --only: неправильное регулярное выражение ({e})")
            return None
    return rest, country, only


def ask_url(given, usage):
    """Ссылка на подписку из аргумента или со скрытым вводом. None, если ее нет или она не подходит."""
    url = given
    if not url:
        if not sys.stdin.isatty():
            print(usage, file=sys.stderr)
            return None
        print("Ссылка на подписку для Clash, mihomo или v2ray (из 3x-ui, Marzban, та же, что в Happ). На экране её видно не будет.")
        url = secret("Подписка: ").strip()
    if url.startswith("happ://"):
        print(f"{BAD} это зашифрованная ссылка Happ (happ://crypt…), её читает только сам Happ. "
              "Нужна обычная https://… ссылка на подписку от того, кто её выдал")
        return None
    if not re.match(r"^https?://\S+$", url):
        print(f"{BAD} это не ссылка на подписку: нужна https://…, а не vless:// или hysteria2://")
        return None
    return url


def snapshot(paths):
    return {Path(path): Path(path).read_bytes() if Path(path).exists() else None for path in paths}


def restore(previous):
    for path, data in previous.items():
        if data is None:
            path.unlink(missing_ok=True)
        else:
            write_private(str(path), data)


def setup(args):
    if in_session():
        print(f"{WARN} {IN_SESSION}: agentmeister proxy setup")
        return 1
    if not mihomo_bin() and not install_mihomo():
        print(f"{BAD} без mihomo прокси не заработает: brew install mihomo")
        return 1
    parsed = sub_options(args)
    if parsed is None:
        return 2
    rest, country, only = parsed
    url = ask_url(rest[0] if rest else "", "agentmeister proxy setup <ссылка на подписку>")
    if not url:
        return 2
    with locked():
        if holders():
            print(f"{WARN} сейчас идут сессии через proxy ({len(holders())}). Закрой их и повтори setup.")
            return 1
        stop()
        old = port() if configured() else None
        taken = {v.get("port") for n, v in read_subs().items() if n != MAIN and isinstance(v, dict)}
        p = old if old and not listening(old) else free_port(taken)
        previous = snapshot((CONFIG, SUB_URL, SUB_FILE, os.path.join(CONF_DIR, "vps.yaml"), subs_meta()))
        verified = False
        try:
            write_config(url, p, country, only)
            start()
            direct, via = check_exit()
            if not via:
                raise ProxyError("Не удалось подключиться через новую подписку.")
            verified = True
        except (OSError, ProxyError) as error:
            print(f"{BAD} {error}")
            return 1
        finally:
            try:
                stop()
            finally:
                if not verified:
                    restore(previous)
    print(f"{OK} настройка в {tilde(CONFIG)} (права 600), порт {p}"
          + (f", только серверы «{only}»" if only else "") + (f", выход должен быть в {country.upper()}" if country else ""))
    print(f"{OK} напрямую {fmt(direct)}, через proxy {fmt(via)}")
    print('Выбери "через proxy" в меню Agentmeister или запусти agentmeister <проект> -x.')
    return 0


def add_sub(args):
    """proxy add <имя> [ссылка] [--country XX] [--only RE]: еще одна подписка со своим портом. Та же команда
    с тем же именем меняет ссылку и настройки подписки."""
    if in_session():
        print(f"{WARN} {IN_SESSION}: agentmeister proxy add")
        return 1
    if not configured():
        print(f"{WARN} сначала основная подписка: agentmeister proxy setup")
        return 1
    parsed = sub_options(args)
    if parsed is None:
        return 2
    rest, country, only = parsed
    name = rest[0] if rest else ""
    if not SUB_NAME.match(name) or name in RESERVED:
        print(f"{BAD} имя подписки: латинские строчные буквы, цифры и дефис, до 20 знаков, с буквы. "
              f"Нельзя {', '.join(sorted(RESERVED))}")
        return 2
    url = ask_url(rest[1] if len(rest) > 1 else "", "agentmeister proxy add <имя> <ссылка на подписку>")
    if not url:
        return 2
    url_file, sub_file = sub_files(name)
    with locked():
        held = held_subs()
        if name in held:
            print(f"{WARN} через {name} идут сессии. Закрой их и повтори.")
            return 1
        if MAIN in held and not main_strict_port():
            # у основной пока нет своего порта: ее строгие сессии на порту каскада, а он начнет переходить на name
            print(f"{WARN} идут сессии только через {MAIN} (-x {MAIN}). Закрой их и повтори: с новой подпиской "
                  f"у {MAIN} появится свой порт, а их порт станет общим для очереди.")
            return 1
        data = read_subs()
        known = (data.get(name) or {}).get("port") if isinstance(data.get(name), dict) else None
        taken = {port()} | {v.get("port") for n, v in data.items() if n != name and isinstance(v, dict)}
        p = known if good_port(known) and known not in taken else free_port(taken)
        data[name] = {"port": p, "country": country.upper(), "only": only}
        running = bool(read_pid() and listening(port()))
        previous = snapshot((CONFIG, subs_meta(), url_file, sub_file))
        verified = False
        try:
            os.makedirs(os.path.dirname(url_file), mode=0o700, exist_ok=True)
            write_private(url_file, url.encode())
            Path(sub_file).unlink(missing_ok=True)
            save_subs(place_main_port(data))
            rerender()
            # сессии через другие подписки переживут перезапуск mihomo, как при proxy restart
            stop()
            start(strict=False)
            direct, via = check_exit(name)
            if not via:
                raise ProxyError(f"не удалось подключиться через подписку {name}")
            if country and (via[1] or "").upper() != country.upper():
                raise ProxyError(f"через {name} выход {fmt(via)}, а нужен {country.upper()}")
            verified = True
        except (OSError, ProxyError) as error:
            print(f"{BAD} {error}")
            return 1
        finally:
            if not verified:
                restore(previous)
            try:
                if running and not verified:
                    stop()
                    start(strict=False)
                elif not running and not holders():
                    stop()
            except (OSError, ProxyError) as error:
                print(f"{WARN} mihomo после отката: {error}")
            if running:
                ensure_watch()
    print(f"{OK} подписка {name}: порт {p}, напрямую {fmt(direct)}, через нее {fmt(via)}"
          + (f", только серверы «{only}»" if only else ""))
    print(f"agentmeister <проект> -x {name} пойдет только через {name}. "
          f"Просто -x идет по подпискам по очереди: {', '.join(cascade_subs())}.")
    if name not in cascade_subs():
        print(paint(f"  {name} не в очереди: у основной подписки выход должен быть в {setting('country')}, "
                    f"а у {name} {country.upper() or 'страна не задана'}. Иначе сессия посреди работы могла бы "
                    "сменить страну выхода", "2"))
    return 0


def remove_sub(name):
    if in_session():
        print(f"{WARN} {IN_SESSION}: agentmeister proxy remove {name}")
        return 1
    if name == MAIN:
        print(f"{WARN} основную подписку меняет agentmeister proxy setup, а удаляет все agentmeister proxy remove")
        return 2
    if name not in extra_subs():
        print(f"{BAD} нет подписки {name}, есть {', '.join(sub_names())}")
        return 1
    with locked():
        data = read_subs()
        data.pop(name, None)
        last = not [n for n in data if n != MAIN]
        held = held_subs()
        if name in held or (last and MAIN in held):
            # без дополнительных подписок пропадет и порт только основной
            print(f"{WARN} через {name if name in held else MAIN} идут сессии. Закрой их и повтори.")
            return 1
        if last:
            data.pop(MAIN, None)
        save_subs(data)
        for path in sub_files(name):
            Path(path).unlink(missing_ok=True)
        rerender(data)
        if read_pid() and listening(port()):
            try:
                restart_mihomo()
                ensure_watch()
            except ProxyError as error:
                print(f"{WARN} mihomo: {error}")
    print(f"{OK} подписка {name} удалена")
    return 0


def list_subs():
    if not configured():
        print(f"{WARN} прокси не настроен: agentmeister proxy setup")
        return 1
    extras = extra_subs()
    if not extras:
        print(f"{OK} одна подписка {MAIN}, порт {port()}"
              + (f", выход должен быть в {setting('country')}" if setting("country") else ""))
        print(paint("  Добавить еще: agentmeister proxy add <имя> <ссылка>", "2"))
        return 0
    rows = [("-x", f"по очереди: {', '.join(cascade_subs())}", port(), "")]
    rows += [(f"-x {n}", f"только {n}", sub_port(n), sub_country(n)) for n in sub_names()]
    width = max(len(r[0]) for r in rows)
    text = max(len(r[1]) for r in rows)
    for flag, what, p, want in rows:
        print(f"  {flag.ljust(width)}  {what.ljust(text)}  порт {p}" + (f", выход {want}" if want else ""))
    return 0


VERSION_RE = re.compile(r"\bv?(\d+\.\d+\.\d+)\b")


def parse_version(text):
    m = VERSION_RE.search(text or "")
    return m.group(1) if m else None


def newer(a, b):
    """Версия a новее b (обе вида 1.19.33)."""
    return bool(a and b) and tuple(map(int, a.split("."))) > tuple(map(int, b.split(".")))


def brew_bin():
    return shutil.which("brew") or next((b for b in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew")
                                         if os.access(b, os.X_OK)), None)


def from_brew(exe):
    return "/Cellar/mihomo/" in os.path.realpath(exe or "")


def installed_version(exe=None):
    exe = exe or mihomo_bin()
    if not exe:
        return None
    try:
        out = subprocess.run([exe, "-v"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    return parse_version(out)


def running_version():
    """Версия запущенного mihomo по его API или None, если он не отвечает."""
    return parse_version(str(mihomo_api("/version").get("version") or ""))


def brew_latest():
    """Свежая версия mihomo по данным Homebrew на этом Mac, без сети: brew update обновляет их сам."""
    brew = brew_bin()
    if not brew:
        return None
    try:
        out = subprocess.run([brew, "info", "--json=v2", "mihomo"], capture_output=True, text=True, timeout=10,
                             env=dict(os.environ, HOMEBREW_NO_AUTO_UPDATE="1")).stdout
        return parse_version(json.loads(out)["formulae"][0]["versions"]["stable"])
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, IndexError):
        return None


def version_line():
    exe = mihomo_bin()
    have = installed_version(exe)
    if not have:
        return None
    line = f"mihomo {have}" + (tr(" из Homebrew", " from Homebrew") if from_brew(exe) else f", {tilde(exe)}")
    latest = brew_latest() if from_brew(exe) else None
    if newer(latest, have):
        line += tr(f", есть {latest}: agentmeister proxy update", f", {latest} is out: agentmeister proxy update")
    running = running_version()
    if running and running != have:
        line += tr(f". Запущен еще {running}, новая версия заработает после перезапуска mihomo",
                   f". {running} is still running, the new version starts after a mihomo restart")
    return line


def update():
    """Обновить mihomo через Homebrew и перезапустить запущенный, чтобы заработала новая версия."""
    exe = mihomo_bin()
    if not exe:
        return 0 if install_mihomo() else 1
    if not from_brew(exe):
        print(f"{WARN} mihomo стоит не из Homebrew ({tilde(exe)}), обнови его тем же способом, каким ставил. "
              "Релизы: https://github.com/MetaCubeX/mihomo/releases")
        return 1
    before = installed_version(exe)
    print("brew upgrade mihomo …", flush=True)
    if subprocess.run([brew_bin(), "upgrade", "mihomo"]).returncode != 0:
        print(f"{BAD} brew upgrade mihomo не сработал")
        return 1
    after = installed_version()
    print(f"{OK} mihomo {before} → {after}" if newer(after, before) else f"{OK} mihomo {after}, это последняя версия")
    if in_session():
        print(f"{WARN} запущенный mihomo не перезапускаю: песочница сессии закрывает управление им. Если новая "
              "версия нужна сейчас, выполни в обычном терминале agentmeister proxy restart")
        return 0
    running = running_version()
    if not running or running == after:
        return 0
    live = holders()
    if not live:
        with locked():
            stop()
        print(f"{OK} старый mihomo {running} остановлен, новый запустится с первой сессией через proxy")
        return 0
    question = (f"Сейчас через proxy идут сессии ({len(live)}), они работают на mihomo {running}. Перезапустить его сейчас? "
                "Запросы, которые идут в эту секунду, оборвутся, Claude Code их повторит [y/N] ")
    if sys.stdin.isatty() and input(question).strip().lower() in ("y", "yes", "д", "да"):
        try:
            with locked():
                problem = restart_mihomo()
                ensure_watch()
        except ProxyError as e:
            print(f"{BAD} {e}")
            return 1
        if problem:
            print(f"{WARN} {problem}: сессии через proxy работают через этот выход, проверь сервер")
        print(f"{OK} mihomo перезапущен, работает {running_version() or after}")
    else:
        print(f"{OK} mihomo {running} работает, пока идут сессии через proxy. {after} заработает после последней")
    return 0


def restart_cmd():
    if in_session():
        print(f"{WARN} {IN_SESSION}: agentmeister proxy restart")
        return 1
    if not (read_pid() and listening(port())):
        print(paint("  mihomo не запущен: он поднимется вместе с первой сессией через proxy", "2"))
        return 0
    try:
        with locked():
            problem = restart_mihomo()
            ensure_watch()
    except ProxyError as e:
        print(f"{BAD} {e}")
        return 1
    if problem:
        print(f"{WARN} {problem}: сессии через proxy работают через этот выход, проверь сервер")
    node, proto = active_node()
    print(f"{OK} mihomo перезапущен" + (f", сервер {node}" + (f", протокол {proto}" if proto else "") if node else ""))
    return 0


def started_node():
    """Сервер из exit.json, который записан при запуске mihomo."""
    try:
        with open(EXIT) as f:
            info = json.load(f)
    except (OSError, ValueError):
        info = {}
    node, proto = info.get("node"), info.get("proto")
    if not isinstance(node, str) or not node:
        return tr("При запуске mihomo сервер не определился", "mihomo didn't report a server at start")
    return tr(f"При запуске mihomo был сервер {node}", f"At start mihomo used server {node}") + \
        (tr(f", протокол {proto}", f", protocol {proto}") if isinstance(proto, str) else "")


def fmt(t):
    return f"{t[0]} ({t[1]})" if t else tr("не открылось", "didn't open")


def status(test=False):
    if not configured():
        print(f"{WARN} " + tr("прокси не настроен: agentmeister proxy setup", "proxy isn't set up: agentmeister proxy setup"))
        return 1
    p, pid, live = port(), read_pid(), holders()
    want = setting("country")
    print(f"{OK} " + tr(f"настроен: {tilde(CONFIG)}, порт {p}", f"set up: {tilde(CONFIG)}, port {p}")
          + (tr(f", выход должен быть в {want}", f", the exit must be in {want}") if want else ""))
    extras = extra_subs()
    if extras:
        print(f"{OK} " + tr(f"подписки по очереди: {', '.join(cascade_subs())}. Только одна: ",
                            f"subscriptions in order: {', '.join(cascade_subs())}. Just one: ")
              + ", ".join(f"-x {n} ({tr('порт', 'port')} {sub_port(n)}"
                          + (f", {sub_country(n)}" if n != MAIN and sub_country(n) else "") + ")" for n in sub_names()))
    if not mihomo_bin():
        print(f"{BAD} " + tr("нет mihomo: brew install mihomo", "mihomo is missing: brew install mihomo"))
    else:
        line = version_line()
        if line:
            stale = "proxy update" in line or tr("Запущен еще", "still running") in line
            print(f"{WARN if stale else OK} {line}")
    if pid and listening(p):
        print(f"{OK} " + tr(f"mihomo работает (pid {pid}), сессий через proxy {len(live)}",
                            f"mihomo is running (pid {pid}), proxied sessions {len(live)}"))
        print(f"{OK} " + tr("сторож сети работает", "the network watcher is running") if watcher_alive() else
              f"{WARN} " + tr("сторожа сети нет, он запустится с новой сессией через proxy или agentmeister proxy restart",
                              "the network watcher isn't running, it starts with a new proxied session or agentmeister proxy restart"))
        node = node_info()
        if node:
            print(f"{OK} " + tr(f"сейчас сервер {node['node']}", f"current server {node['node']}")
                  + (tr(f" из {node['sub']}", f" from {node['sub']}") if extras and node["sub"] else "")
                  + (tr(f", протокол {node['proto']}", f", protocol {node['proto']}") if node["proto"] else ""))
            for name in sub_names() if extras else []:
                one = node_info(name)
                print(paint(f"  -x {name}: " + (tr(f"сервер {one['node']}", f"server {one['node']}")
                                                 + (f", {one['proto']}" if one["proto"] else "") if one else
                                                 tr("живых серверов нет", "no live servers")), "2"))
        elif in_session():
            print(paint("  " + started_node() + tr(". Текущий сервер из сессии не виден: песочница закрывает "
                                                   "сокет управления mihomo, смотри agentmeister proxy в обычном терминале",
                                                   ". The current server isn't visible from a session: the sandbox closes "
                                                   "the mihomo control socket, run agentmeister proxy in a regular terminal"), "2"))
    else:
        print(paint("  " + tr("mihomo не запущен: он поднимется вместе с первой сессией через proxy",
                              "mihomo isn't running: it starts with the first proxied session"), "2"))
    for key in [None] + [n for n in sub_names() if port_key(n) is not None]:
        if read_exit(key).get("blocked"):
            who = tr("очередь подписок", "the subscription order") if key is None else key
            print(f"{BAD} " + tr(f"сторож закрыл {who}: ни один живой сервер не выходит в {sub_country(key) or 'нужной стране'}",
                                 f"the watcher closed {who}: no live server exits in {sub_country(key) or 'the required country'}"))
    if os.environ.get("MNRH_PROXY"):
        mine = os.environ.get("MNRH_PROXY_SUB")
        print(f"{OK} " + (tr(f"эта сессия идёт только через {mine}", f"this session goes through {mine} only") if mine
                          else tr("эта сессия идёт через proxy", "this session goes through the proxy")))
    if test:
        try:
            results = check_all([None] + (sub_names() if extras else []))
        except ProxyError as e:
            print(f"{BAD} {e}")
            return 1
        for sub, direct, via in results:
            label = tr("через proxy", "via proxy") if sub is None else f"-x {sub}"
            print(f"{OK if via else BAD} " + tr(f"напрямую {fmt(direct)}, {label} {fmt(via)}",
                                                f"direct {fmt(direct)}, {label} {fmt(via)}"))
        return 0 if results and results[0][2] else 1
    return 0


def remove():
    if in_session():
        print(f"{WARN} {IN_SESSION}: agentmeister proxy remove")
        return 1
    with locked():
        if holders():
            print(f"{WARN} сейчас идут сессии через proxy. Закрой их и повтори.")
            return 1
        stop()
    if os.path.isdir(CONF_DIR):
        shutil.rmtree(CONF_DIR)
    print(f"{OK} прокси удалён: {tilde(CONF_DIR)}")
    return 0


def remember(choice):
    if choice not in ("vps", "direct") and not (choice.startswith("vps:") and choice[4:] in sub_names()):
        return 2
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(LAST, "w") as f:
            f.write(choice)
    except OSError:
        return 1  # из сессии через proxy папка состояния закрыта, выбор просто не запомнится
    return 0


def last():
    try:
        with open(LAST) as f:
            return f.read().strip()
    except OSError:
        return "direct"


USAGE = """agentmeister proxy                 статус: настроен ли, запущен ли mihomo, сколько сессий через proxy
agentmeister proxy test            сравнить выход напрямую и через proxy (IP и страна)
agentmeister proxy setup [ссылка] [--country DE] [--only DE]
                                  настроить по ссылке на подписку (https://…, Clash, mihomo или v2ray).
                                  --country: если выход окажется в другой стране, сессия не запустится;
                                  --only: брать из подписки только серверы, чьё имя подходит под это выражение
agentmeister proxy add <имя> [ссылка] [--country NL] [--only RE]
                                  еще одна подписка. agentmeister <проект> -x <имя> идет только через нее,
                                  а просто -x по всем по очереди: следующая, когда в прошлой нет живых серверов
agentmeister proxy list            подписки, их порты и флаги -x
agentmeister proxy remove <имя>    удалить одну дополнительную подписку
agentmeister proxy update          обновить mihomo через Homebrew и перезапустить, если он запущен
agentmeister proxy restart         перезапустить mihomo, не закрывая сессии через proxy
agentmeister proxy remove          удалить настройку
agentmeister proxy check-url <адрес>|default  где проверять IP и страну выхода (формат /cdn-cgi/trace)
agentmeister proxy probe-url <адрес>|default  чем mihomo проверяет живость серверов (ответ 204 или 200)
agentmeister proxy run [--via <имя>] -- <cmd>
                                  запустить команду с доступом к сети только через mihomo

Claude Code с -x обращается к API Anthropic через mihomo. При обрыве proxy запросы завершаются
ошибкой. Обычный SSH и локальные сервисы доступны. Внешние HTTP и HTTPS на портах 80 и 443 требуют proxy.
Для Codex с -x и proxy run сохраняется строгий режим с доступом к порту mihomo и сокету ssh-agent.
Нужен mihomo: brew install mihomo.
Он слушает 127.0.0.1:{port}, стартует с первой такой сессией и останавливается после последней.
К серверу mihomo ходит через Wi-Fi или Ethernet в обход TUN Happ и других VPN, поэтому Happ можно
включать и выключать во время сессии. Если живых серверов нет, соединения отклоняются, а не идут напрямую."""


def main(argv):
    cmd = argv[0] if argv else "status"
    rest = argv[1:]
    if cmd in ("-h", "--help", "help"):
        print(USAGE.format(port=port()))
        return 0
    if cmd == "status":
        return status()
    if cmd == "test":
        return status(test=True)
    if cmd == "setup":
        return setup(rest)
    if cmd == "remove":
        return remove_sub(rest[0]) if rest else remove()
    if cmd == "add":
        return add_sub(rest)
    if cmd == "list":
        return list_subs()
    if cmd == "names":
        # для cli.sh и меню: имена подписок, по одному в строке
        print("\n".join(sub_names()) if configured() else "")
        return 0
    if cmd == "update":
        return update()
    if cmd in ("check-url", "probe-url") and len(rest) == 1:
        key = {"check-url": "proxy_check_url", "probe-url": "proxy_probe_url"}[cmd]
        value = rest[0].strip()
        if value != "default" and not re.match(r"^https?://\S+$", value):
            print(f"{BAD} нужен адрес https://… или default", file=sys.stderr)
            return 2
        mnrhlib.write_config(**{key: None if value == "default" else value})
        print(f"{OK} проверка выхода: {check_url()}\n{OK} проверка серверов: {probe_url()}"
              + ("\nНовый адрес проверки серверов mihomo возьмет после agentmeister proxy restart." if cmd == "probe-url" else ""))
        return 0
    if cmd == "restart":
        return restart_cmd()
    if cmd == "watch":
        watch()
        return 0
    if cmd == "run":
        claude, sandbox, via = False, True, None
        while rest[:1] and rest[0] in ("--claude", "--no-sandbox", "--via") or rest[:1] and rest[0].startswith("--via="):
            flag = rest.pop(0)
            if flag == "--claude":
                claude = True
            elif flag == "--no-sandbox":
                sandbox = False
            elif flag == "--via":
                via = rest.pop(0) if rest else ""
            else:
                via = flag.partition("=")[2]
        return run(rest[1:] if rest[:1] == ["--"] else rest, claude=claude, sandbox=sandbox, sub=via)
    if cmd == "configured":
        return 0 if configured() and mihomo_bin() else 1
    if cmd == "remember":
        return remember(rest[0] if rest else "")
    if cmd == "last":
        print(last())
        return 0
    print(f"agentmeister proxy: не знаю «{cmd}»\n\n{USAGE.format(port=port())}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
