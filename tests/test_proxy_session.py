import os
from pathlib import Path
import signal
import socket
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "libexec/agentmeister/lib"))
import claude_proxy


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS sandbox")
class ProxySession(unittest.TestCase):
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
