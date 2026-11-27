import io
import json
import os
import sys
import tempfile
import threading
import time
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
        patches = [mock.patch.object(t, "LOG", self.log), mock.patch.object(t, "enabled", lambda: True),
                   mock.patch.object(t, "fallback", lambda: None), mock.patch.object(t, "provider", lambda: "openrouter")]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def run_hook(self, payload, result=None, error=None):
        calls = []

        def fake(text, key=None, timeout=t.TIMEOUT, name=None):
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


class Editor(unittest.TestCase):
    TAB = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"

    def setUp(self):
        tmp = tempfile.mkdtemp()
        self.dir = os.path.join(tmp, "edit")
        os.makedirs(self.dir)
        self.file = os.path.join(tmp, "claude-prompt.md")
        self.execs = []
        patches = [mock.patch.object(t, "EDIT_DIR", self.dir), mock.patch.object(t, "LOG", os.path.join(tmp, "log")),
                   mock.patch.object(t, "app_tab", lambda: self.TAB), mock.patch.object(t, "fallback", lambda: None),
                   mock.patch.object(t, "provider", lambda: "openrouter"), mock.patch.object(t, "model", lambda name=None: "m"),
                   mock.patch.object(t.os, "execv", lambda *a: self.execs.append(a))]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def edit(self, text, result="", request=True, delay=0, cancel_after=None):
        with open(self.file, "w") as f:
            f.write(text)
        if request:
            open(os.path.join(self.dir, f"edit-{self.TAB}.json"), "w").close()

        def fake(text, key=None, timeout=t.TIMEOUT, name=None):
            time.sleep(delay)
            return result

        if cancel_after is not None:
            threading.Timer(cancel_after, lambda: open(os.path.join(self.dir, f"edit-{self.TAB}.cancel"), "w").close()).start()
        with mock.patch.object(t, "translate", fake):
            t.editor_main([self.file])
        with open(self.file) as f:
            out = f.read()
        try:
            with open(os.path.join(self.dir, f"edit-{self.TAB}.status.json")) as f:
                status = json.load(f)
        except FileNotFoundError:
            status = None
        return out, status

    def test_translates_in_place_with_images_and_reply_language(self):
        out, status = self.edit("Посмотри на [Image #1] и исправь отступ\n", "Look at [Image #1] and fix the padding")
        self.assertEqual(out, "Look at [Image #1] and fix the padding\n\n(Reply in Russian.)\n")
        self.assertEqual((status["state"], status["ok"]), ("done", True))
        self.assertEqual(status["english"], "Look at [Image #1] and fix the padding\n\n(Reply in Russian.)")
        self.assertEqual(self.execs, [])
        self.assertFalse(os.path.exists(os.path.join(self.dir, f"edit-{self.TAB}.json")))

    def test_without_request_opens_own_editor(self):
        with mock.patch.dict(os.environ, {"AGENTMEISTER_EDITOR": "nano -w"}):
            out, status = self.edit("Привет\n", "Hi", request=False)
        self.assertEqual(out, "Привет\n")
        self.assertIsNone(status)
        self.assertEqual(self.execs[0][1][:3], ["/bin/sh", "-c", 'nano -w "$@"'])
        self.assertEqual(self.execs[0][1][-1], self.file)

    def test_stale_request_opens_own_editor(self):
        req = os.path.join(self.dir, f"edit-{self.TAB}.json")
        open(req, "w").close()
        os.utime(req, (time.time() - 60, time.time() - 60))
        self.edit("Привет\n", "Hi", request=False)
        self.assertEqual(len(self.execs), 1)

    def test_lost_image_keeps_original(self):
        out, status = self.edit("Посмотри на [Image #1]\n", "Look at the picture")
        self.assertEqual(out, "Посмотри на [Image #1]\n")
        self.assertFalse(status["ok"])
        self.assertIn("картинки", status["error"])

    def test_cancel_keeps_original(self):
        out, status = self.edit("Исправь баг\n", "Fix the bug", delay=0.5, cancel_after=0.1)
        self.assertEqual(out, "Исправь баг\n")
        self.assertTrue(status["cancelled"])

    def test_english_and_secrets_are_not_sent(self):
        out, status = self.edit("fix the bug\n", "x")
        self.assertEqual((out, status["ok"]), ("fix the bug\n", False))
        out, status = self.edit("ключ sk-or-v1-0123456789abcdef0123456789abcdef\n", "x")
        self.assertIn("секрет", status["error"])


class Text(unittest.TestCase):
    def run_text(self, text, result):
        out = io.StringIO()
        with mock.patch.object(t, "translate", lambda *a, **k: result), mock.patch.object(t, "fallback", lambda: None), \
                mock.patch.object(t, "LOG", os.path.join(tempfile.mkdtemp(), "log")), \
                mock.patch("sys.stdin", io.StringIO(text)), mock.patch("sys.stdout", out):
            code = t.cmd_text()
        return code, out.getvalue()

    def test_translates_stdin(self):
        self.assertEqual(self.run_text("Исправь баг\n", "Fix the bug"), (0, "Fix the bug\n\n(Reply in Russian.)\n"))

    def test_english_is_refused(self):
        code, out = self.run_text("fix the bug\n", "x")
        self.assertEqual(code, 1)
        self.assertIn("без нелатинских букв", out)


class Key(unittest.TestCase):
    def test_saved_with_600(self):
        tmp = tempfile.mkdtemp()
        path = os.path.join(tmp, "sub", "openrouter-key")
        conf = {}
        with mock.patch.object(t, "key_file", lambda name=None: path), \
                mock.patch.object(t, "read_config", lambda: conf), \
                mock.patch.object(t, "write_config", lambda **kw: conf.update(kw)), \
                mock.patch.dict(os.environ, {"OPENROUTER_API_KEY": ""}):
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


class Providers(unittest.TestCase):
    def test_key_picks_provider(self):
        self.assertEqual(t.key_provider("sk-or-v1-" + "a" * 64), "openrouter")
        self.assertEqual(t.key_provider("AIza" + "B" * 35), "google")
        self.assertEqual(t.key_provider("AQ.Ab8RN6" + "x" * 44), "google")
        self.assertIsNone(t.key_provider("hello world"))
        self.assertIsNone(t.key_provider("sk-ant-api03-" + "a" * 40))

    def test_google_key_is_a_secret(self):
        self.assertIn("секрет", t.skip_reason("вот ключ AQ.Ab8RN6" + "x" * 44))

    def test_fallback_after_timeout(self):
        calls = []

        def fake(text, key=None, timeout=t.TIMEOUT, name=None):
            calls.append((name, timeout))
            if name == "google":
                raise TimeoutError("slow")
            return "Fix"

        with mock.patch.object(t, "translate", fake), mock.patch.object(t, "provider", lambda: "google"), \
                mock.patch.object(t, "fallback", lambda: "openrouter"):
            self.assertEqual(t.translate_any("Почини"), ("Fix", "openrouter"))
        self.assertEqual(calls[0], ("google", t.FIRST_TIMEOUT))
        self.assertEqual(calls[1][0], "openrouter")
        self.assertLessEqual(calls[1][1], t.TIMEOUT)
        with mock.patch.object(t, "translate", fake), mock.patch.object(t, "provider", lambda: "google"), \
                mock.patch.object(t, "fallback", lambda: None):
            with self.assertRaises(TimeoutError):
                t.translate_any("Почини")
        self.assertEqual(calls[-1], ("google", t.TIMEOUT))


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
        with mock.patch("urllib.request.urlopen", fake_open), mock.patch.object(t, "model", lambda name=None: "m/x"):
            self.assertEqual(t.translate("Почини", key="g", name="google"), "Fix it")
            self.assertEqual(sent["reasoning_effort"], "minimal")
            self.assertNotIn("reasoning", sent)
            sent.clear()
            self.assertEqual(t.translate("Почини", key="k", name="openrouter"), "Fix it")
            self.assertIn("reasoning", sent)
            self.assertEqual(sent["model"], "m/x")
            self.assertEqual(sent["auth"], "Bearer k")
            self.assertEqual(sent["messages"][1]["content"], "Почини")
            self.assertEqual(sent["timeout"], t.TIMEOUT)
            finish = "length"
            with self.assertRaises(RuntimeError):
                t.translate("Почини", key="k", name="openrouter")
        with mock.patch.object(t, "api_key", lambda name=None: ""):
            with self.assertRaises(RuntimeError):
                t.translate("Почини")


if __name__ == "__main__":
    unittest.main()
