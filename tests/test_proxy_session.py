from contextlib import redirect_stderr, redirect_stdout
import fcntl
import io
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "libexec/agentmeister/lib"))
import proxy
import host_run


class ProxySetup(unittest.TestCase):
    def test_failed_subscription_restores_all_four_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = {name: str(Path(tmp) / file) for name, file in
                     (("CONFIG", "config.yaml"), ("SUB_URL", "url"), ("SUB_FILE", "subscription.txt"))}
            with patch.multiple(proxy, CONF_DIR=tmp, STATE=tmp, LOCK=str(Path(tmp) / "lock"), **paths), \
                    patch.object(proxy, "mihomo_bin", return_value="mihomo"), \
                    patch.object(proxy, "holders", return_value=[]), patch.object(proxy, "stop"), \
                    patch.object(proxy, "listening", return_value=False), patch.object(proxy, "start"), \
                    patch.object(proxy, "check_exit", return_value=(None, None)), \
                    patch.object(proxy, "in_session", return_value=False):
                proxy.write_config("https://old.example.test", 17890, "KZ")
                for path in (Path(paths["SUB_FILE"]), Path(tmp) / "vps.yaml"):
                    path.write_bytes(b"old")
                old = {p: p.read_bytes() for p in Path(tmp).iterdir()}
                self.assertEqual(proxy.setup(["https://new.example.test"]), 1)
                self.assertEqual({p: p.read_bytes() for p in old}, old)


class ControllerGuard(unittest.TestCase):
    """Сокет управления mihomo и его настройка закрыты для сессии: через сокет mihomo загрузил бы любой конфиг."""

    def test_both_profiles_close_the_controller_and_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.realpath(tmp)
            with patch.multiple(proxy, SOCK=f"{real}/state/mihomo.sock", CONF_DIR=f"{real}/conf"):
                for claude in (True, False):
                    with self.subTest(claude=claude):
                        command = proxy.session_command(17890, ["true"], claude=claude)
                        self.assertIn(f"MIHOMO_SOCK0={real}/state/mihomo.sock", command)
                        self.assertIn(f"MIHOMO_CONF0={real}/conf", command)
                        profile = command[command.index("-p") + 1]
                        self.assertIn('(deny network-outbound (literal (param "MIHOMO_SOCK0")))', profile)
                        self.assertIn('(deny file-write* file-link (literal (param "MIHOMO_SOCK0")) '
                                      '(subpath (param "MIHOMO_CONF0")) (subpath (param "MIHOMO_STATE0")))', profile)

    def test_symlinked_paths_are_closed_in_both_forms(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.realpath(tmp)
            os.mkdir(f"{real}/state")
            os.symlink(f"{real}/state", f"{real}/link")
            with patch.multiple(proxy, SOCK=f"{real}/link/mihomo.sock", CONF_DIR=f"{real}/conf"):
                socks = proxy.guarded_paths()["SOCK"]
        self.assertEqual(socks, [f"{real}/link/mihomo.sock", f"{real}/state/mihomo.sock"])

    @unittest.skipUnless(sys.platform == "darwin" and host_run.nested_sandbox_ok(), "requires the macOS sandbox")
    def test_session_cannot_use_or_replace_the_controller(self):
        client = """\
import errno, os, socket, sys

sock, other, conf = sys.argv[1:]
for path, expected in ((sock, errno.EPERM), (other, 0)):
    with socket.socket(socket.AF_UNIX) as conn:
        result = conn.connect_ex(path)
        assert result == expected, (path, result)
for action in (lambda: os.remove(sock), lambda: open(os.path.join(conf, "config.yaml"), "w")):
    try:
        action()
    except PermissionError:
        pass
    else:
        sys.exit("changed mihomo's control files")
"""
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp, \
                socket.socket(socket.AF_UNIX) as controller, socket.socket(socket.AF_UNIX) as other:
            sock, near, conf = str(Path(tmp) / "mihomo.sock"), str(Path(tmp) / "other.sock"), str(Path(tmp) / "conf")
            os.mkdir(conf)
            controller.bind(sock)
            controller.listen()
            other.bind(near)
            other.listen()
            with patch.multiple(proxy, SOCK=sock, CONF_DIR=conf):
                command = proxy.session_command(17890, [sys.executable, "-c", client, sock, near, conf],
                                                       claude=True)
            subprocess.run(command, check=True, timeout=10)
            self.assertTrue(os.path.exists(sock))


def proxy_paths(root):
    state, conf = f"{root}/state/mnrh/proxy", f"{root}/conf/mnrh/proxy"
    return {"STATE": state, "LOCK": f"{state}/lock", "HOLDERS": f"{state}/holders", "SOCK": f"{state}/mihomo.sock",
            "EXIT": f"{state}/exit.json", "WATCH_LOG": f"{state}/watch.log", "CONF_DIR": conf}


class StateGuard(unittest.TestCase):
    """Папка состояния proxy закрыта для сессии: записи о сессиях, замок и журналы пишут только вне песочницы."""

    def test_both_profiles_close_the_state_folder_lock_and_parents(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.realpath(tmp)
            paths = proxy_paths(real)
            with patch.multiple(proxy, **paths):
                for claude in (True, False):
                    with self.subTest(claude=claude):
                        command = proxy.session_command(17890, ["true"], claude=claude)
                        params = dict(a.split("=", 1) for a in command if a.startswith("MIHOMO_"))
                        self.assertEqual(params["MIHOMO_STATE0"], paths["STATE"])
                        self.assertEqual(params["MIHOMO_LOCK0"], paths["LOCK"])
                        ups = {v for k, v in params.items() if k.startswith("MIHOMO_UP")}
                        for up in (f"{real}/state/mnrh", f"{real}/state", f"{real}/conf/mnrh", real):
                            self.assertIn(up, ups)
                        self.assertNotIn("/", ups)
                        profile = command[command.index("-p") + 1]
                        self.assertIn('(subpath (param "MIHOMO_STATE0")))', profile)
                        self.assertIn('(deny file-read* (literal (param "MIHOMO_LOCK0")))', profile)
                        self.assertIn(f'(literal (param "MIHOMO_UP{len(ups) - 1}"))', profile)
                        # запреты последними: в профиле побеждает последнее подходящее правило
                        self.assertTrue(profile.rstrip().endswith(proxy.sandbox_profile_lines()[-1]))

    def test_symlinked_state_is_closed_in_both_forms(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.realpath(tmp)
            os.mkdir(f"{real}/state")
            os.symlink(f"{real}/state", f"{real}/link")
            with patch.multiple(proxy, STATE=f"{real}/link", LOCK=f"{real}/link/lock"):
                paths = proxy.guarded_paths()
        self.assertEqual(paths["STATE"], [f"{real}/link", f"{real}/state"])
        self.assertEqual(paths["LOCK"], [f"{real}/link/lock", f"{real}/state/lock"])

    @unittest.skipUnless(os.path.exists("/usr/bin/sandbox-exec"), "requires sandbox-exec")
    def test_profiles_compile(self):
        """sandbox-exec разбирает профиль до того, как применить: ошибка в нем дала бы код 65, а не 0 или 71
        (71 — вложенная песочница, если тест идет в сессии через proxy)."""
        with tempfile.TemporaryDirectory() as tmp:
            with patch.multiple(proxy, **proxy_paths(os.path.realpath(tmp))):
                for claude in (True, False):
                    with self.subTest(claude=claude):
                        r = subprocess.run(proxy.session_command(17890, ["/usr/bin/true"], claude=claude),
                                           capture_output=True, text=True, timeout=10)
                        self.assertIn(r.returncode, (0, 71), r.stderr)

    @unittest.skipUnless(sys.platform == "darwin" and host_run.nested_sandbox_ok(), "requires the macOS sandbox")
    def test_session_cannot_touch_the_state_folder(self):
        """Живая проверка, запускать в обычном терминале: сессия не стирает записи, не берет замок, не пишет
        журнал сторожа и не подменяет папки, но читает exit.json и пишет рядом."""
        client = """\
import fcntl, os, sys

state, lock, holder, log, conf, root = sys.argv[1:]
assert open(os.path.join(state, "exit.json")).read() == "{}"
assert os.listdir(os.path.join(state, "holders")) == ["4242"]
attempts = {
    "remove a holder": lambda: os.remove(holder),
    "add a holder": lambda: open(os.path.join(state, "holders", "1"), "w"),
    "open the lock": lambda: open(lock),
    "open the lock for writing": lambda: open(lock, "a"),
    "link the lock": lambda: os.link(lock, os.path.join(root, "lock-link")),
    "link the config": lambda: os.link(os.path.join(conf, "config.yaml"), os.path.join(root, "conf-link")),
    "append to the watcher's log": lambda: open(log, "a"),
    "forge the mihomo pid": lambda: open(os.path.join(state, "mihomo.pid"), "w"),
    "rename the state folder": lambda: os.rename(state, state + ".old"),
    "rename a parent": lambda: os.rename(os.path.dirname(state), os.path.dirname(state) + ".old"),
}
for name, action in attempts.items():
    try:
        action()
    except PermissionError:
        continue
    sys.exit("could " + name)
open(os.path.join(root, "beside"), "w").close()
"""
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            paths = proxy_paths(os.path.realpath(tmp))
            os.makedirs(paths["HOLDERS"])
            os.makedirs(paths["CONF_DIR"])
            holder = os.path.join(paths["HOLDERS"], "4242")
            for path, text in ((holder, ""), (paths["EXIT"], "{}"), (paths["WATCH_LOG"], "watcher\n"),
                               (paths["LOCK"], ""), (os.path.join(paths["CONF_DIR"], "config.yaml"), "x")):
                Path(path).write_text(text)
            with patch.multiple(proxy, **paths):
                for claude in (True, False):
                    with self.subTest(claude=claude):
                        command = proxy.session_command(
                            17890, [sys.executable, "-c", client, paths["STATE"], paths["LOCK"], holder,
                                    paths["WATCH_LOG"], paths["CONF_DIR"], os.path.realpath(tmp)], claude=claude)
                        subprocess.run(command, check=True, timeout=10)
                        with open(paths["LOCK"]) as f:  # лаунчер по-прежнему берет замок сразу
                            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertTrue(os.path.exists(holder))
            self.assertEqual(Path(paths["WATCH_LOG"]).read_text(), "watcher\n")


class InsideSession(unittest.TestCase):
    """Изнутри песочницы mihomo не перезапустить и не поднять: нужен обычный терминал."""

    def setUp(self):
        guard = patch.object(proxy, "in_session", return_value=True)
        guard.start()
        self.addCleanup(guard.stop)
        lang = patch("mnrhlib.lang", return_value="ru")  # тесты сверяют русский вывод
        lang.start()
        self.addCleanup(lang.stop)

    def test_restart_and_start_refuse(self):
        with patch.object(proxy, "restart_mihomo") as restart, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(proxy.restart_cmd(), 1)
        restart.assert_not_called()
        self.assertIn("обычном терминале", out.getvalue())
        with patch.object(proxy, "read_pid", return_value=None), patch.object(proxy, "pin_config") as pin:
            with self.assertRaises(proxy.ProxyError):
                proxy.start()
        pin.assert_not_called()

    def test_no_watcher_from_inside(self):
        with patch.object(proxy.subprocess, "Popen") as popen, \
                patch.object(proxy, "watcher_alive", return_value=False):
            proxy.ensure_watch()
        popen.assert_not_called()

    def test_nested_run_and_test_skip_the_lock_and_holders(self):
        with tempfile.TemporaryDirectory() as tmp, \
                patch.multiple(proxy, **proxy_paths(os.path.realpath(tmp))), \
                patch.object(proxy, "configured", return_value=True), \
                patch.object(proxy, "read_pid", return_value=4242), \
                patch.object(proxy, "listening", return_value=True), \
                patch.object(proxy, "check_exit", return_value=(("1.1.1.1", "GE"), ("2.2.2.2", "KZ"))), \
                patch.object(proxy, "stop") as stop, patch.object(proxy.os, "execvpe") as execvpe, \
                patch.object(proxy.subprocess, "Popen") as popen, redirect_stderr(io.StringIO()):
            proxy.run(["codex", "--flag"])
            self.assertEqual(proxy.check(), (("1.1.1.1", "GE"), ("2.2.2.2", "KZ")))
            self.assertEqual(os.listdir(tmp), [])  # ни замка, ни записей о сессии
        stop.assert_not_called()
        popen.assert_not_called()
        name, argv, env = execvpe.call_args[0]
        self.assertEqual((name, argv), ("codex", ["codex", "--flag"]))
        self.assertEqual(env["HTTPS_PROXY"], f"http://127.0.0.1:{proxy.port()}")

    def test_nested_run_needs_a_running_mihomo(self):
        with patch.object(proxy, "configured", return_value=True), \
                patch.object(proxy, "read_pid", return_value=None), \
                patch.object(proxy.os, "execvpe") as execvpe, redirect_stderr(io.StringIO()) as err:
            self.assertEqual(proxy.run(["codex"]), 1)
        execvpe.assert_not_called()
        self.assertIn("обычном терминале", err.getvalue())

    def test_setup_remove_and_lock_refuse(self):
        with patch.object(proxy, "stop") as stop, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(proxy.setup(["https://example.test/sub"]), 1)
            self.assertEqual(proxy.remove(), 1)
        stop.assert_not_called()
        self.assertEqual(out.getvalue().count("обычном терминале"), 2)
        with self.assertRaises(proxy.ProxyError):
            with proxy.locked():
                pass

    def test_remember_survives_a_closed_state_folder(self):
        with patch.object(proxy.os, "makedirs", side_effect=PermissionError):
            self.assertEqual(proxy.remember("vps"), 1)

    def test_pid_without_ps_falls_back_to_a_liveness_check(self):
        # в песочнице ps не запускается (PermissionError): status и start не должны падать
        with tempfile.TemporaryDirectory() as tmp:
            pidfile = Path(tmp) / "mihomo.pid"
            pidfile.write_text(f"{os.getpid()}\n")
            with patch.object(proxy, "PIDFILE", str(pidfile)), \
                    patch.object(proxy.subprocess, "run", side_effect=PermissionError("denied")) as run:
                self.assertEqual(proxy.read_pid(), os.getpid())
                with patch.object(proxy, "alive", return_value=False):
                    self.assertIsNone(proxy.read_pid())
            self.assertEqual(run.call_args.args[0][0], "ps")

    def test_status_shows_the_server_from_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            exit_file = Path(tmp) / "exit.json"
            exit_file.write_text('{"node": "kz-1", "proto": "vless"}')
            with patch.object(proxy, "EXIT", str(exit_file)):
                self.assertIn("kz-1, протокол vless", proxy.started_node())


class InSessionCheck(unittest.TestCase):
    def test_leaked_variable_outside_a_sandbox_is_not_a_session(self):
        with patch.object(proxy, "_sandboxed", None), patch.dict(os.environ, MNRH_PROXY="17890"), \
                patch.object(host_run, "nested_sandbox_ok", return_value=True):
            self.assertFalse(proxy.in_session())
        with patch.object(proxy, "_sandboxed", None), patch.dict(os.environ, MNRH_PROXY="17890"), \
                patch.object(host_run, "nested_sandbox_ok", return_value=False):
            self.assertTrue(proxy.in_session())
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("MNRH_PROXY", None)
            self.assertFalse(proxy.in_session())


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS sandbox")
class ProxySession(unittest.TestCase):
    def test_only_selected_agent_socket_is_reachable(self):
        client = """\
import errno, socket, sys

for path, expected in zip(sys.argv[1:], (0, errno.EPERM)):
    with socket.socket(socket.AF_UNIX) as conn:
        result = conn.connect_ex(path)
        assert result == expected, (result, expected)
"""
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp, \
                socket.socket(socket.AF_UNIX) as agent, socket.socket(socket.AF_UNIX) as other:
            path = Path(tmp) / "agent socket"
            adjacent = str(Path(tmp) / "other")
            alias = Path(tmp) / "agent-link"
            agent.bind(str(path))
            agent.listen()
            other.bind(adjacent)
            other.listen()
            alias.symlink_to(path)
            with patch.dict(os.environ, SSH_AUTH_SOCK=str(alias)):
                command = proxy.session_command(17890, [sys.executable, "-c", client, str(alias), adjacent])
                subprocess.run(command, check=True, timeout=5)
            for missing in ("", str(Path(tmp) / "missing"), tmp):
                with self.subTest(missing=missing), patch.dict(os.environ, SSH_AUTH_SOCK=missing):
                    command = proxy.session_command(17890, ["true"])
                    self.assertFalse(any(a.startswith("SSH_AUTH_SOCK=") for a in command))

    def test_claude_allows_local_tools_and_blocks_direct_web(self):
        client = """\
import errno, socket, sys

with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1):
    pass
with socket.socket() as server:
    server.bind(("127.0.0.1", 0))
    server.listen()
with socket.socket(socket.AF_UNIX) as local:
    local.connect(sys.argv[2])
for family, target in [(socket.AF_INET, "192.0.2.1"), (socket.AF_INET6, "2001:db8::1")]:
    for port in (80, 443):
        with socket.socket(family) as tcp:
            tcp.settimeout(1)
            assert tcp.connect_ex((target, port)) == errno.EPERM
        with socket.socket(family, socket.SOCK_DGRAM) as udp:
            try:
                udp.sendto(b"", (target, port))
            except PermissionError:
                pass
            else:
                raise AssertionError("direct UDP was allowed")
"""
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp, socket.socket() as local, \
                socket.socket(socket.AF_UNIX) as unix:
            local.bind(("127.0.0.1", 0))
            local.listen()
            path = str(Path(tmp) / "fixture")
            unix.bind(path)
            unix.listen()
            cmd = [sys.executable, "-c", client, str(local.getsockname()[1]), path]
            subprocess.run(proxy.session_command(17890, cmd, claude=True), check=True, timeout=5)
        with patch.dict(os.environ, HTTPS_PROXY="http://old", NO_PROXY="*", no_proxy="*"):
            env = proxy.proxy_env(17890, claude=True)
            self.assertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:17890")
            self.assertEqual(env["no_proxy"], "localhost,127.0.0.1,::1")
            self.assertEqual(env["no_proxy"], env["NO_PROXY"])

    def test_session_and_children_remain_restricted_after_disconnect(self):
        with tempfile.TemporaryDirectory() as tmp, socket.socket() as upstream, socket.socket() as origin:
            for listener in (upstream, origin):
                listener.bind(("127.0.0.1", 0))
                listener.listen()
                listener.settimeout(5)
            proxy_port, origin_port = upstream.getsockname()[1], origin.getsockname()[1]
            requests = []

            def serve_once():
                conn, _ = upstream.accept()
                with conn:
                    requests.append(conn.recv(4096).splitlines()[0])
                    upstream.close()
                    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nproxied")

            server = threading.Thread(target=serve_once, daemon=True)
            server.start()
            client = Path(tmp) / "client.py"
            client.write_text("""\
import errno, os, socket, subprocess, sys

origin = int(sys.argv[1])
url = f"http://127.0.0.1:{origin}/fixture"
curl = ["/usr/bin/curl", "-q", "-fs", "--max-time", "2", url]
assert subprocess.check_output(curl) == b"proxied"
assert subprocess.run(curl).returncode != 0
assert subprocess.run([*curl, "--noproxy", "*"]).returncode != 0
with socket.socket() as direct:
    assert direct.connect_ex(("127.0.0.1", origin)) == errno.EPERM
with socket.socket(socket.AF_INET6) as direct:
    assert direct.connect_ex(("::1", origin)) == errno.EPERM
with socket.socket(type=socket.SOCK_DGRAM) as udp:
    try:
        udp.sendto(b"fixture", ("127.0.0.1", origin))
    except PermissionError:
        pass
    else:
        sys.exit("UDP was allowed")
""")
            signals = (signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP)
            for sig in signals:
                self.addCleanup(signal.signal, sig, signal.getsignal(sig))
            with patch.multiple(proxy, STATE=tmp, LOCK=tmp + "/lock", HOLDERS=tmp + "/holders",
                                EXIT=tmp + "/exit", PAGE=tmp + "/page"), \
                    patch.object(proxy, "configured", return_value=True), \
                    patch.object(proxy, "port", return_value=proxy_port), \
                    patch.object(proxy, "start"), patch.object(proxy, "stop"), \
                    patch.object(proxy, "ensure_watch"), \
                    patch.object(proxy, "in_session", return_value=False), \
                    patch.dict(os.environ, NO_PROXY="*", no_proxy="*"):
                self.assertEqual(proxy.run([sys.executable, str(client), str(origin_port)]), 0)
            server.join(timeout=5)
            self.assertEqual(requests, [f"GET http://127.0.0.1:{origin_port}/fixture HTTP/1.1".encode()])
            origin.settimeout(0.1)
            with self.assertRaises(socket.timeout):
                origin.accept()
            with socket.create_connection(("127.0.0.1", origin_port), timeout=1):
                connection, _ = origin.accept()
                connection.close()
