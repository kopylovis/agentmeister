import base64
import io
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "libexec", "agentmeister", "lib"))
import proxy as p  # noqa: E402

LINKS = (b"vless://uuid@kz.example.net:443?security=reality#KZ\n"
         b"hysteria2://pass@kz2.example.net:8443/?sni=x#KZ2\n")
YAML = b"proxies:\n- name: kz\n  type: vless\n  server: kz.example.net\n  port: 443\n"
PORTAL = b"<html><body><a href=\"https://login.example.net/\">Log in to Wi-Fi</a></body></html>"


class Valid(unittest.TestCase):
    def test_accepts_links_base64_and_yaml(self):
        for raw in (LINKS, base64.b64encode(LINKS), base64.urlsafe_b64encode(LINKS).rstrip(b"="), YAML,
                    b"proxies: [{name: kz, type: ss, server: 1.2.3.4, port: 1}]\n"):
            with self.subTest(raw=raw[:30]):
                self.assertTrue(p.subscription_ok(raw))

    def test_rejects_pages_and_empty_answers(self):
        for raw in (PORTAL, b"", b"   \n", b"null", b"{\"error\": \"expired\"}", base64.b64encode(b"nothing here"),
                    b"proxies: []\n", b"https://example.net/sub\n"):
            with self.subTest(raw=raw[:30]):
                self.assertFalse(p.subscription_ok(raw))


class Refresh(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.url = os.path.join(self.tmp, "subscription.url")
        self.file = os.path.join(self.tmp, "subscription.txt")
        with open(self.url, "w") as f:
            f.write("https://sub.example.net/x")

    def refresh(self, body, code=0):
        answer = subprocess.CompletedProcess([], code, body, b"")
        err = io.StringIO()
        with patch.multiple(p, SUB_URL=self.url, SUB_FILE=self.file), \
                patch.object(p, "physical_interface", return_value=None), \
                patch.object(p.subprocess, "run", return_value=answer), redirect_stderr(err):
            return p.refresh_subscription(), err.getvalue()

    def test_good_answer_replaces_the_copy(self):
        self.assertEqual(self.refresh(LINKS), (True, ""))
        with open(self.file, "rb") as f:
            self.assertEqual(f.read(), LINKS)

    def test_captive_portal_keeps_the_last_good_copy(self):
        with open(self.file, "wb") as f:
            f.write(YAML)
        ok, err = self.refresh(PORTAL)
        self.assertFalse(ok)
        self.assertIn("без серверов", err)
        with open(self.file, "rb") as f:
            self.assertEqual(f.read(), YAML)

    def test_bad_answer_without_a_copy_is_an_error(self):
        with self.assertRaises(p.ProxyError):
            self.refresh(PORTAL)
        self.assertFalse(os.path.exists(self.file))


if __name__ == "__main__":
    unittest.main()


class Upstream(unittest.TestCase):
    def test_accepts_socks_and_http_with_a_port_only(self):
        for good in ("socks5://127.0.0.1:1080", "socks5h://u:p@proxy.corp:1080", "http://proxy.corp:3128",
                     "https://proxy.corp:443/"):
            self.assertEqual(p.upstream_url(good), good)
        for bad in ("socks5://127.0.0.1", "ftp://x:21", "http://proxy.corp:3128/sub/abc", "vless://x@y:443",
                    "https://sub.example.net/x?token=1", "nonsense"):
            self.assertIsNone(p.upstream_url(bad), bad)

    def test_yaml_with_credentials_tls_and_interface(self):
        with patch.object(p, "route_interface", return_value="utun4"):
            text = p.upstream_yaml("https://me%40corp:p%3Ass@proxy.corp:8443")
        self.assertIn("    type: http\n    server: \"proxy.corp\"\n    port: 8443\n    tls: true\n", text)
        self.assertIn('    username: "me@corp"\n    password: "p:ss"\n    interface-name: utun4\n', text)
        self.assertTrue(p.subscription_ok(text.encode()))

    def test_localhost_goes_through_lo0(self):
        self.assertEqual(p.route_interface("127.0.0.1"), "lo0")

    def test_flag_takes_the_place_of_the_link(self):
        with redirect_stderr(io.StringIO()), patch("sys.stdout", io.StringIO()):
            self.assertEqual(p.sub_options(["--upstream", "socks5://127.0.0.1:1080", "--country", "de"]),
                             (["upstream:socks5://127.0.0.1:1080"], "de", ""))
            self.assertEqual(p.sub_options(["work", "--upstream", "http://h:3128"]), (["work", "upstream:http://h:3128"], "", ""))
            self.assertIsNone(p.sub_options(["--upstream", "socks5://nohost"]))
            with patch("sys.stdin", io.StringIO("")):
                self.assertIsNone(p.sub_options(["--upstream", "-"]))  # без терминала адрес не спросить
        self.assertEqual(p.ask_url("upstream:socks5://127.0.0.1:1080", "usage"), "upstream:socks5://127.0.0.1:1080")

    def test_refresh_builds_the_file_without_network(self):
        tmp = tempfile.mkdtemp()
        url, sub = os.path.join(tmp, "subscription.url"), os.path.join(tmp, "subscription.txt")
        with open(url, "w") as f:
            f.write("upstream:socks5://127.0.0.1:1080")
        with patch.multiple(p, SUB_URL=url, SUB_FILE=sub), patch.object(p.subprocess, "run") as run:
            self.assertTrue(p.refresh_subscription())
        run.assert_not_called()
        with open(sub) as f:
            text = f.read()
        self.assertIn("type: socks5", text)
        self.assertIn("interface-name: lo0", text)
