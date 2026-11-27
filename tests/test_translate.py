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
        self.dir = os.path.join(tmp, "handoff")
        self.tab = ""
        patches = [mock.patch.object(t, "LOG", self.log), mock.patch.object(t, "enabled", lambda: True),
                   mock.patch.object(t, "fallback", lambda: None), mock.patch.object(t, "provider", lambda: "openrouter"),
                   mock.patch.object(t, "HANDOFF_DIR", self.dir), mock.patch.object(t, "app_tab", lambda: self.tab),
                   mock.patch.object(t, "HANDOFF_WAIT", 0.5)]
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

    def event(self, prompt, transcript=None):
        return json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "abcdef12-0000", "prompt": prompt,
                           "transcript_path": transcript})

    def app(self, ok=True):
        """Приложение: берет первый запрос из папки обмена и отвечает. -> поток и список взятых запросов."""
        taken = []

        def serve():
            deadline = time.time() + 2
            while time.time() < deadline:
                for name in os.listdir(self.dir) if os.path.isdir(self.dir) else []:
                    if name.endswith(".json") and not name.endswith(".reply.json") and len(name) == 41:
                        path = os.path.join(self.dir, name)
                        with open(path) as f:
                            taken.append(json.load(f))
                        os.remove(path)
                        with open(path[:-5] + ".reply.json", "w") as f:
                            json.dump({"ok": ok}, f)
                        return
                time.sleep(0.01)

        thread = threading.Thread(target=serve)
        thread.start()
        return thread, taken

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


class HandOff(Hook):
    def setUp(self):
        super().setUp()
        self.tab = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
        self.replace = True
        p = mock.patch.object(t, "replace_on", lambda: self.replace)
        p.start()
        self.addCleanup(p.stop)

    def test_off_keeps_context(self):
        self.replace = False
        out, _ = self.run_hook(self.event("Исправь баг"), result="Fix the bug")
        self.assertIn("additionalContext", out)
        self.assertFalse(os.path.isdir(self.dir))

    def test_app_replaces_prompt(self):
        thread, taken = self.app()
        out, _ = self.run_hook(self.event("Исправь баг"), result="Fix the bug")
        thread.join()
        self.assertEqual(json.loads(out)["decision"], "block")
        self.assertEqual(taken[0]["english"], "Fix the bug")
        self.assertEqual((taken[0]["from"], taken[0]["session"], taken[0]["original"]),
                         (self.tab, "abcdef12-0000", "Исправь баг"))
        self.assertIn("ушел вместо оригинала", self.log_text())

    def test_refused_or_silent_app_keeps_context(self):
        thread, _ = self.app(ok=False)
        out, _ = self.run_hook(self.event("Исправь баг"), result="Fix the bug")
        thread.join()
        self.assertIn("additionalContext", out)
        out, _ = self.run_hook(self.event("Почини тест"), result="Fix the test")
        self.assertIn("additionalContext", out)
        self.assertEqual([n for n in os.listdir(self.dir) if not n.endswith("state.json")], [])

    def test_outside_app_and_pasted_text_keep_context(self):
        out, _ = self.run_hook(self.event("Вот лог [Pasted text #1 +40 lines]"), result="Here is the log")
        self.assertIn("additionalContext", out)
        self.tab = ""
        out, _ = self.run_hook(self.event("Исправь баг"), result="Fix the bug")
        self.assertIn("additionalContext", out)

    def test_same_prompt_again_is_not_blocked_twice(self):
        thread, _ = self.app()
        self.run_hook(self.event("Исправь баг"), result="Fix the bug")
        thread.join()
        out, _ = self.run_hook(self.event("Исправь  баг"), result="Fix the bug")
        self.assertIn("additionalContext", out)

    def test_resubmit_passes_with_one_note(self):
        transcript = os.path.join(os.path.dirname(self.dir), "t.jsonl")
        with open(transcript, "w") as f:
            f.write('{"type":"user"}\n')
        thread, _ = self.app()
        self.run_hook(self.event("Исправь баг"), result="Fix the bug")
        thread.join()

        def resubmit():
            open(os.path.join(self.dir, "sent-abcdef12-0000"), "w").close()
            return self.run_hook(self.event("Fix the bug «Ответ»", transcript), result="x")

        out, calls = resubmit()
        self.assertEqual(calls, [])
        ctx = json.loads(out)["hookSpecificOutput"]["additionalContext"]
        self.assertIn("Reply in Russian", ctx)
        self.assertEqual(resubmit(), ("", []))
        with open(transcript, "a") as f:
            f.write('{"type":"system","subtype":"compact_boundary"}\n')
        self.assertIn("Reply in Russian", resubmit()[0])
        self.assertEqual(resubmit(), ("", []))

    def test_stale_sent_mark_is_ignored(self):
        os.makedirs(self.dir)
        mark = os.path.join(self.dir, "sent-abcdef12-0000")
        open(mark, "w").close()
        os.utime(mark, (time.time() - 60, time.time() - 60))
        out, calls = self.run_hook(self.event("Исправь баг"), result="Fix the bug")
        self.assertEqual(len(calls), 1)
        self.assertFalse(os.path.exists(mark))

    def test_language(self):
        self.assertEqual(t.language("Привет"), "Russian")
        self.assertEqual(t.language("Привіт, їжак"), "Ukrainian")
        self.assertEqual(t.language("コードを直して"), "Japanese")


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
