from contextlib import redirect_stdout
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
import claude_proxy
import host_run


class ProxySetup(unittest.TestCase):
    def test_failed_subscription_restores_all_four_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = {name: str(Path(tmp) / file) for name, file in
                     (("CONFIG", "config.yaml"), ("SUB_URL", "url"), ("SUB_FILE", "subscription.txt"))}
            with patch.multiple(claude_proxy, CONF_DIR=tmp, STATE=tmp, LOCK=str(Path(tmp) / "lock"), **paths), \
                    patch.object(claude_proxy, "mihomo_bin", return_value="mihomo"), \
                    patch.object(claude_proxy, "holders", return_value=[]), patch.object(claude_proxy, "stop"), \
                    patch.object(claude_proxy, "listening", return_value=False), patch.object(claude_proxy, "start"), \
                    patch.object(claude_proxy, "check_exit", return_value=(None, None)):
                claude_proxy.write_config("https://old.example.test", 17890, "KZ")
                for path in (Path(paths["SUB_FILE"]), Path(tmp) / "vps.yaml"):
                    path.write_bytes(b"old")
                old = {p: p.read_bytes() for p in Path(tmp).iterdir()}
                self.assertEqual(claude_proxy.setup(["https://new.example.test"]), 1)
                self.assertEqual({p: p.read_bytes() for p in old}, old)


class ControllerGuard(unittest.TestCase):
    """Сокет управления mihomo и его настройка закрыты для сессии: через сокет mihomo загрузил бы любой конфиг."""

    def test_both_profiles_close_the_controller_and_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.realpath(tmp)
            with patch.multiple(claude_proxy, SOCK=f"{real}/state/mihomo.sock", CONF_DIR=f"{real}/conf"):
                for claude in (True, False):
                    with self.subTest(claude=claude):
                        command = claude_proxy.session_command(17890, ["true"], claude=claude)
                        self.assertIn(f"MIHOMO_SOCK0={real}/state/mihomo.sock", command)
                        self.assertIn(f"MIHOMO_CONF0={real}/conf", command)
                        profile = command[command.index("-p") + 1]
                        self.assertIn('(deny network-outbound (literal (param "MIHOMO_SOCK0")))', profile)
                        self.assertIn('(deny file-write* (literal (param "MIHOMO_SOCK0")) '
                                      '(subpath (param "MIHOMO_CONF0")))', profile)

    def test_symlinked_paths_are_closed_in_both_forms(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.realpath(tmp)
            os.mkdir(f"{real}/state")
            os.symlink(f"{real}/state", f"{real}/link")
            with patch.multiple(claude_proxy, SOCK=f"{real}/link/mihomo.sock", CONF_DIR=f"{real}/conf"):
                socks, _ = claude_proxy.guarded_paths()
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
            with patch.multiple(claude_proxy, SOCK=sock, CONF_DIR=conf):
                command = claude_proxy.session_command(17890, [sys.executable, "-c", client, sock, near, conf],
                                                       claude=True)
            subprocess.run(command, check=True, timeout=10)
            self.assertTrue(os.path.exists(sock))


class InsideSession(unittest.TestCase):
    """Изнутри песочницы mihomo не перезапустить и не поднять: нужен обычный терминал."""

    def setUp(self):
        guard = patch.object(claude_proxy, "in_session", return_value=True)
        guard.start()
        self.addCleanup(guard.stop)

    def test_restart_and_start_refuse(self):
        with patch.object(claude_proxy, "restart_mihomo") as restart, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(claude_proxy.restart_cmd(), 1)
        restart.assert_not_called()
        self.assertIn("обычном терминале", out.getvalue())
        with patch.object(claude_proxy, "read_pid", return_value=None), patch.object(claude_proxy, "pin_config") as pin:
            with self.assertRaises(claude_proxy.ProxyError):
                claude_proxy.start()
        pin.assert_not_called()

    def test_no_watcher_from_inside(self):
        with patch.object(claude_proxy.subprocess, "Popen") as popen, \
                patch.object(claude_proxy, "watcher_alive", return_value=False):
            claude_proxy.ensure_watch()
        popen.assert_not_called()

    def test_status_shows_the_server_from_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            exit_file = Path(tmp) / "exit.json"
            exit_file.write_text('{"node": "kz-1", "proto": "vless"}')
            with patch.object(claude_proxy, "EXIT", str(exit_file)):
                self.assertIn("kz-1, протокол vless", claude_proxy.started_node())


class InSessionCheck(unittest.TestCase):
    def test_leaked_variable_outside_a_sandbox_is_not_a_session(self):
        with patch.object(claude_proxy, "_sandboxed", None), patch.dict(os.environ, MNRH_PROXY="17890"), \
                patch.object(host_run, "nested_sandbox_ok", return_value=True):
            self.assertFalse(claude_proxy.in_session())
        with patch.object(claude_proxy, "_sandboxed", None), patch.dict(os.environ, MNRH_PROXY="17890"), \
                patch.object(host_run, "nested_sandbox_ok", return_value=False):
            self.assertTrue(claude_proxy.in_session())
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("MNRH_PROXY", None)
            self.assertFalse(claude_proxy.in_session())


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
                command = claude_proxy.session_command(17890, [sys.executable, "-c", client, str(alias), adjacent])
                subprocess.run(command, check=True, timeout=5)
            for missing in ("", str(Path(tmp) / "missing"), tmp):
                with self.subTest(missing=missing), patch.dict(os.environ, SSH_AUTH_SOCK=missing):
                    command = claude_proxy.session_command(17890, ["true"])
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
            subprocess.run(claude_proxy.session_command(17890, cmd, claude=True), check=True, timeout=5)
        with patch.dict(os.environ, HTTPS_PROXY="http://old", NO_PROXY="*", no_proxy="*"):
            env = claude_proxy.proxy_env(17890, claude=True)
            self.assertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:17890")
            self.assertEqual(env["no_proxy"], "localhost,127.0.0.1,::1")
            self.assertEqual(env["no_proxy"], env["NO_PROXY"])

    def test_session_and_children_remain_restricted_after_disconnect(self):
        with tempfile.TemporaryDirectory() as tmp, socket.socket() as proxy, socket.socket() as origin:
            for listener in (proxy, origin):
                listener.bind(("127.0.0.1", 0))
                listener.listen()
                listener.settimeout(5)
            proxy_port, origin_port = proxy.getsockname()[1], origin.getsockname()[1]
            requests = []

            def serve_once():
                conn, _ = proxy.accept()
                with conn:
                    requests.append(conn.recv(4096).splitlines()[0])
                    proxy.close()
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
            with patch.multiple(claude_proxy, STATE=tmp, LOCK=tmp + "/lock", HOLDERS=tmp + "/holders",
                                EXIT=tmp + "/exit", PAGE=tmp + "/page"), \
                    patch.object(claude_proxy, "configured", return_value=True), \
                    patch.object(claude_proxy, "port", return_value=proxy_port), \
                    patch.object(claude_proxy, "start"), patch.object(claude_proxy, "stop"), \
                    patch.object(claude_proxy, "ensure_watch"), patch.dict(os.environ, NO_PROXY="*", no_proxy="*"):
                self.assertEqual(claude_proxy.run([sys.executable, str(client), str(origin_port)]), 0)
            server.join(timeout=5)
            self.assertEqual(requests, [f"GET http://127.0.0.1:{origin_port}/fixture HTTP/1.1".encode()])
            origin.settimeout(0.1)
            with self.assertRaises(socket.timeout):
                origin.accept()
            with socket.create_connection(("127.0.0.1", origin_port), timeout=1):
                connection, _ = origin.accept()
                connection.close()
