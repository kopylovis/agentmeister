import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "libexec", "agentmeister", "lib"))
import translate as t  # noqa: E402


class Skip(unittest.TestCase):
    def test_sent(self):
        for text in ("Исправь баг в src/main.py", "добавь тест для `make test`", "コードを直して",
                     "коммит 3f2a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a", "сессия 01a213dd-cc02-7e01-b76a-74e03f6db7d6",
                     "путь src/Components/MyViewController2Something/File.swift"):
            self.assertIsNone(t.skip_reason(text), text)

    def test_not_sent(self):
        cases = {
            "": "пусто",
            "fix the failing test": "без нелатинских букв",
            "Grüße aus München": "без нелатинских букв",
            "/humanize on": "слэш-команда",
            "а" * (t.MAX_CHARS + 1): "длиннее",
        }
        for text, reason in cases.items():
            self.assertIn(reason, t.skip_reason(text), text[:30])

    def test_secrets(self):
        cases = [
            "вот ключ sk-or-v1-0123456789abcdef0123456789abcdef",
            "подписка vless://8f1c@example.com:443?security=reality",
            "сервер hysteria2://pass@host:8443",
            "зайди на https://user:p4ssw0rd@example.com/admin",
            "ссылка https://example.com/api?token=abcdef123456",
            "токен ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123",
            "ключ AKIAABCDEFGHIJKLMNOP",
            "бот 123456789:AAEhBP0av28Ab1cDEfGhIjKlMnOpQrStUvW",
            "токен eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "поставь password=hunter2hunter2",
            "заголовок Authorization: Bearer abcdefghijklmnop1234",
            "ключ -----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n",
            "подписка https://sub.example.com/sub/aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY",
        ]
        for text in cases:
            reason = t.skip_reason(text)
            self.assertIsNotNone(reason, text)
            self.assertIn("секрет", reason, text)


class Hook(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.mkdtemp()
        self.log = os.path.join(tmp, "translate.log")
        patches = [mock.patch.object(t, "LOG", self.log), mock.patch.object(t, "enabled", lambda: True)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def run_hook(self, payload, result=None, error=None):
        calls = []

        def fake(text, key=None, timeout=t.TIMEOUT):
            calls.append(text)
            if error:
                raise error
            return result

        out = io.StringIO()
        with mock.patch.object(t, "translate", fake), mock.patch("sys.stdin", io.StringIO(payload)), \
                mock.patch("sys.stdout", out):
            self.assertEqual(t.hook(), 0)
        return out.getvalue(), calls

    def log_text(self):
        try:
            return open(self.log).read()
        except FileNotFoundError:
            return ""

    def event(self, prompt):
        return json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "abcdef12-0000", "prompt": prompt})

    def test_translates(self):
        out, calls = self.run_hook(self.event("Исправь баг"), result="Fix the bug")
        self.assertEqual(calls, ["Исправь баг"])
        data = json.loads(out)
        ctx = data["hookSpecificOutput"]["additionalContext"]
        self.assertEqual(data["hookSpecificOutput"]["hookEventName"], "UserPromptSubmit")
        self.assertIn("Fix the bug", ctx)
        self.assertIn("original wording wins", ctx)
        self.assertIn("переведен", self.log_text())
        self.assertNotIn("Исправь", self.log_text())

    def test_english_not_sent(self):
        out, calls = self.run_hook(self.event("fix the bug"), result="x")
        self.assertEqual((out, calls), ("", []))
        self.assertEqual(self.log_text(), "")

    def test_secret_not_sent_and_logged_without_text(self):
        prompt = "вот ключ sk-or-v1-0123456789abcdef0123456789abcdef"
        out, calls = self.run_hook(self.event(prompt), result="x")
        self.assertEqual((out, calls), ("", []))
        self.assertIn("похоже на секрет", self.log_text())
        self.assertNotIn("sk-or", self.log_text())

    def test_failure_passes_through(self):
        out, calls = self.run_hook(self.event("Исправь баг"), error=RuntimeError("HTTP 401"))
        self.assertEqual(out, "")
        self.assertEqual(len(calls), 1)
        self.assertIn("ошибка", self.log_text())

    def test_same_text_not_injected(self):
        out, _ = self.run_hook(self.event("Привет"), result="  Привет ")
        self.assertEqual(out, "")

    def test_junk_and_off(self):
        self.assertEqual(self.run_hook("junk")[0], "")
        self.assertEqual(self.run_hook("[1]")[0], "")
        with mock.patch.object(t, "enabled", lambda: False):
            out, calls = self.run_hook(self.event("Исправь баг"), result="Fix")
        self.assertEqual((out, calls), ("", []))


class Key(unittest.TestCase):
    def test_saved_with_600(self):
        tmp = tempfile.mkdtemp()
        path = os.path.join(tmp, "sub", "openrouter-key")
        with mock.patch.object(t, "KEY_FILE", path), mock.patch.dict(os.environ, {"OPENROUTER_API_KEY": ""}):
            self.assertIsNone(t.key_source())
            with mock.patch("sys.stdin", io.StringIO("sk-or-v1-abcdefabcdefabcdef\n")), \
                    mock.patch("sys.stdout", io.StringIO()):
                self.assertEqual(t.cmd_key([]), 0)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertEqual(t.api_key(), "sk-or-v1-abcdefabcdefabcdef")
            self.assertEqual(t.key_source(), "file")
            with mock.patch("sys.stdin", io.StringIO("not a key with spaces\n")), \
                    mock.patch("sys.stderr", io.StringIO()):
                self.assertEqual(t.cmd_key([]), 2)
            with mock.patch("sys.stdout", io.StringIO()):
                self.assertEqual(t.cmd_key(["rm"]), 0)
            self.assertFalse(os.path.exists(path))


class Request(unittest.TestCase):
    def test_body_and_cutoff(self):
        sent = {}

        class Resp(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def fake_open(req, timeout):
            sent.update(json.loads(req.data), auth=req.get_header("Authorization"), timeout=timeout)
            return Resp(json.dumps({"choices": [{"finish_reason": finish, "message": {"content": " Fix it "}}]}).encode())

        finish = "stop"
        with mock.patch("urllib.request.urlopen", fake_open), mock.patch.object(t, "model", lambda: "m/x"):
            self.assertEqual(t.translate("Почини", key="k"), "Fix it")
            self.assertEqual(sent["model"], "m/x")
            self.assertEqual(sent["auth"], "Bearer k")
            self.assertEqual(sent["messages"][1]["content"], "Почини")
            self.assertEqual(sent["timeout"], t.TIMEOUT)
            finish = "length"
            with self.assertRaises(RuntimeError):
                t.translate("Почини", key="k")
        with mock.patch.object(t, "api_key", lambda: ""):
            with self.assertRaises(RuntimeError):
                t.translate("Почини")


if __name__ == "__main__":
    unittest.main()
