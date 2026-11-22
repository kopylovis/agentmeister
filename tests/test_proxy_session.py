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
                    self.assertNotIn("-D", claude_proxy.session_command(17890, ["true"]))

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
