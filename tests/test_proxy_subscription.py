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
import claude_proxy as p  # noqa: E402

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
