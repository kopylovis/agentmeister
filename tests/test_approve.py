import io
import json
import os
import shlex
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "libexec", "agentmeister", "lib"))
import notify  # noqa: E402
import telegram  # noqa: E402
import telegram_approve as ta  # noqa: E402
from mnrhlib import HOOK_TIMEOUTS, HOOKS  # noqa: E402
import mnrhlib  # noqa: E402

# тесты сверяют русские тексты, а без lang в config язык берется из macOS
RU = mock.patch.object(mnrhlib, "lang", lambda: "ru")


def setUpModule():
    RU.start()


def tearDownModule():
    RU.stop()

SID = "11111111-2222-3333-4444-555555555555"
CHAT = "4242"


def payload(**over):
    p = {"session_id": SID, "hook_event_name": "PermissionRequest", "cwd": "/Users/x/Developer/app",
         "tool_name": "Bash", "tool_input": {"command": "rm -rf build", "description": "Remove build"}}
    p.update(over)
    return p


class FakeTelegram:
    """Подмена telegram.call: запоминает вызовы, на getUpdates отдает заранее заданные пачки."""

    def __init__(self, batches=None, user=CHAT, chat=CHAT, answer="y"):
        self.calls = []
        self.batches = list(batches or [])
        self.user, self.chat, self.answer = user, chat, answer
        self.sent = None

    def __call__(self, method, tok=None, wait=15, **params):
        self.calls.append((method, params))
        if method == "sendMessage":
            self.sent = params
            return {"message_id": 77}
        if method == "getUpdates":
            if "offset" in params or "allowed_updates" in params:
                return []
            if self.batches:
                return self.batches.pop(0)(self)
            return []
        return True

    def press(self, data=None, message_id=77, update_id=500):
        rid = json.loads(self.sent["reply_markup"])["inline_keyboard"][0][0]["callback_data"].split(":")[1]
        return [{"update_id": update_id, "callback_query": {
            "id": "cb1", "data": data or f"cm1:{rid}:{self.answer}", "from": {"id": int(self.user)},
            "message": {"message_id": message_id, "chat": {"id": int(self.chat)}}}}]

    def methods(self):
        return [m for m, _ in self.calls]


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        patches = [mock.patch.object(ta, "DIR", self.dir),
                   mock.patch.object(ta, "enabled", lambda: True),
                   mock.patch.object(ta, "session_title", lambda p: "Сессия"),
                   mock.patch.object(telegram, "chat", lambda: CHAT),
                   mock.patch.object(telegram, "token", lambda: "t"),
                   mock.patch.object(telegram, "away", lambda: True),
                   mock.patch.object(telegram, "plugin_token", lambda: ""),
                   mock.patch.object(ta.time, "sleep", lambda s: None)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.addCleanup(shutil.rmtree, self.dir, True)

    def run_hook(self, p, fake):
        out = io.StringIO()
        with mock.patch.object(telegram, "call", fake):
            self.assertEqual(ta.hook(io.StringIO(json.dumps(p)), out), 0)
        return out.getvalue()


class Hook(Base):
    def test_allow_from_telegram(self):
        fake = FakeTelegram([lambda f: f.press()])
        out = json.loads(self.run_hook(payload(), fake))
        self.assertEqual(out["hookSpecificOutput"], {"hookEventName": "PermissionRequest",
                                                     "decision": {"behavior": "allow"}})
        self.assertIn("rm -rf build", fake.sent["text"])
        self.assertIn("<b>Claude Code: нужно разрешение</b>\n<i>app</i>", fake.sent["text"])
        self.assertIn("answerCallbackQuery", fake.methods())
        # прочитанное подтверждено, кнопки убраны, файлы ожидания стерты
        self.assertIn(("getUpdates", {"offset": 501, "timeout": 0}), fake.calls)
        edit = [p for m, p in fake.calls if m == "editMessageText"][0]
        self.assertIn("Разрешено", edit["text"])
        self.assertNotIn("reply_markup", edit)
        self.assertEqual(sorted(os.listdir(self.dir)), ["poll.lock", "updates.reset"])

    def test_polling_does_not_narrow_allowed_updates(self):
        for _ in range(2):
            fake = FakeTelegram([lambda f: f.press()])
            self.run_hook(payload(), fake)
            polls = [p for m, p in fake.calls if m == "getUpdates"]
            narrowing = [p for p in polls if p.get("allowed_updates") not in (None, "[]")]
            self.assertEqual(narrowing, [])
            resets = [p for p in polls if p.get("allowed_updates") == "[]"]
            self.assertEqual(len(resets), 1 if _ == 0 else 0)  # вернуть умолчание один раз

    def test_non_callback_updates_are_skipped(self):
        fake = FakeTelegram([lambda f: [{"update_id": 400, "message": {"text": "привет"}}] + f.press()])
        out = json.loads(self.run_hook(payload(), fake))
        self.assertEqual(out["hookSpecificOutput"]["decision"]["behavior"], "allow")

    def test_conflict_stops_polling(self):
        def conflict(f):
            raise telegram.TelegramConflict(telegram.CONFLICT)
        fake = FakeTelegram([conflict, lambda f: f.press()])
        with mock.patch.object(ta, "log_error") as log:
            self.assertEqual(self.run_hook(payload(), fake), "")
        self.assertIn("плагин Telegram", log.call_args.args[0])
        self.assertIn("другая программа", [p for m, p in fake.calls if m == "editMessageText"][0]["text"])
        self.assertEqual(len(fake.batches), 1)  # больше не опрашивал

    def test_deny(self):
        fake = FakeTelegram([lambda f: f.press()], answer="n")
        out = json.loads(self.run_hook(payload(), fake))
        self.assertEqual(out["hookSpecificOutput"]["decision"]["behavior"], "deny")
        self.assertTrue(out["hookSpecificOutput"]["decision"]["message"])

    def test_press_from_another_user_is_ignored(self):
        fake = FakeTelegram([lambda f: f.press()], user="999")
        with mock.patch.object(ta, "WAIT", 1.5):
            out = self.run_hook(payload(), fake)
        self.assertEqual(out, "")
        self.assertIn("Время вышло", [p for m, p in fake.calls if m == "editMessageText"][0]["text"])

    def test_press_in_another_chat_or_message_is_ignored(self):
        for fake in (FakeTelegram([lambda f: f.press()], chat="-100"),
                     FakeTelegram([lambda f: f.press(message_id=12)]),
                     FakeTelegram([lambda f: f.press(data="cm1:0123456789abcdef:y")])):
            with mock.patch.object(ta, "WAIT", 1.5):
                self.assertEqual(self.run_hook(payload(), fake), "")

    def test_user_back_at_mac(self):
        state = iter([True, True, False])
        fake = FakeTelegram()
        with mock.patch.object(telegram, "away", lambda: next(state)):
            self.assertEqual(self.run_hook(payload(), fake), "")
        self.assertIn("вернулся", [p for m, p in fake.calls if m == "editMessageText"][0]["text"])

    def test_network_error_keeps_waiting(self):
        def broken(f):
            raise telegram.TelegramError("нет связи")
        fake = FakeTelegram([broken, lambda f: f.press()])
        with mock.patch.object(ta, "log_error"):
            out = json.loads(self.run_hook(payload(), fake))
        self.assertEqual(out["hookSpecificOutput"]["decision"]["behavior"], "allow")

    def test_send_failure_falls_back(self):
        def fail(method, **kw):
            raise telegram.TelegramError("нет связи")
        with mock.patch.object(ta, "log_error"):
            self.assertEqual(self.run_hook(payload(), fail), "")


class Skips(Base):
    def assert_silent(self, p):
        fake = FakeTelegram()
        self.assertEqual(self.run_hook(p, fake), "")
        self.assertEqual(fake.calls, [])

    def test_off(self):
        with mock.patch.object(ta, "enabled", lambda: False):
            self.assert_silent(payload())

    def test_at_the_mac(self):
        with mock.patch.object(telegram, "away", lambda: False):
            self.assert_silent(payload())

    def test_no_bot(self):
        with mock.patch.object(telegram, "chat", lambda: ""):
            self.assert_silent(payload())

    def test_same_bot_as_telegram_plugin(self):
        with mock.patch.object(telegram, "plugin_token", lambda: "t"), mock.patch.object(ta, "log_error"):
            self.assert_silent(payload())

    def test_questions_and_plans(self):
        for tool in ("AskUserQuestion", "ExitPlanMode"):
            self.assert_silent(payload(tool_name=tool))

    def test_child_and_junk(self):
        with mock.patch.dict(os.environ, {"MNRH_CHILD": "1"}):
            self.assert_silent(payload())
        self.assert_silent(payload(session_id="x"))
        self.assert_silent(payload(hook_event_name="PreToolUse"))
        out = io.StringIO()
        self.assertEqual(ta.hook(io.StringIO("junk"), out), 0)
        self.assertEqual(out.getvalue(), "")


class Api(unittest.TestCase):
    def http_error(self, code, body):
        import urllib.error
        return urllib.error.HTTPError("https://api.telegram.org/botX/getUpdates", code, "x", {}, io.BytesIO(body))

    def test_409_is_reported_as_conflict(self):
        body = json.dumps({"ok": False, "error_code": 409,
                           "description": "Conflict: terminated by other getUpdates request"}).encode()
        for err in (self.http_error(409, body), self.http_error(409, b"<html>")):
            with mock.patch.object(telegram.urllib.request, "urlopen", side_effect=err), \
                    self.assertRaises(telegram.TelegramConflict) as ctx:
                telegram.call("getUpdates", "1:x", timeout=0)
            self.assertIn("плагин Telegram", str(ctx.exception))
        other = json.dumps({"ok": False, "error_code": 401, "description": "Unauthorized"}).encode()
        with mock.patch.object(telegram.urllib.request, "urlopen", side_effect=self.http_error(401, other)), \
                self.assertRaises(telegram.TelegramError) as ctx:
            telegram.call("getMe", "1:x")
        self.assertNotIsInstance(ctx.exception, telegram.TelegramConflict)

    def test_plugin_token_read_from_channel_env(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        with mock.patch.dict(os.environ, {"TELEGRAM_STATE_DIR": d}):
            self.assertEqual(telegram.plugin_token(), "")
            with open(os.path.join(d, ".env"), "w") as f:
                f.write("OTHER=1\nTELEGRAM_BOT_TOKEN=123456:abc\n")
            self.assertEqual(telegram.plugin_token(), "123456:abc")
            self.assertTrue(telegram.shares_plugin_bot("123456:abc"))
            self.assertFalse(telegram.shares_plugin_bot("999:zzz"))

    def test_wait_for_start_filters_client_side(self):
        calls = []
        batches = [[{"update_id": 1, "callback_query": {"id": "c"}},
                    {"update_id": 2, "message": {"text": "/start c0de", "chat": {"id": 5, "type": "private"},
                                                 "from": {"id": 5}}}]]

        def fake(method, tok=None, wait=15, **params):
            calls.append(params)
            if "allowed_updates" in params or "offset" in params and params.get("timeout") == 0:
                return []
            return batches.pop(0) if batches else []
        with mock.patch.object(telegram, "call", fake):
            self.assertEqual(telegram.wait_for_start("1:x", "c0de", seconds=5)["id"], 5)
        self.assertEqual(calls[0].get("allowed_updates"), "[]")
        self.assertTrue(all("allowed_updates" not in p for p in calls[1:]))

    def test_wait_for_start_needs_one_time_code(self):
        def start(uid, text, kind="private", sender=None):
            return {"update_id": uid, "message": {"text": text, "chat": {"id": uid, "type": kind, "first_name": "Eve",
                                                                         "username": "eve"},
                                                  "from": {"id": sender or uid}}}
        batches = [[start(10, "/start"), start(11, "/start wrong"), start(12, "/start c0de", kind="group"),
                    start(13, "/start c0de", sender=99), start(14, "/start c0de")]]

        def fake(method, tok=None, wait=15, **params):
            if "allowed_updates" in params or params.get("timeout") == 0:
                return []
            return batches.pop(0) if batches else []
        out = io.StringIO()
        with mock.patch.object(telegram, "call", fake), mock.patch("sys.stdout", out):
            self.assertEqual(telegram.wait_for_start("1:x", "c0de", seconds=5)["id"], 14)
        self.assertIn("Eve @eve", out.getvalue())
        with mock.patch.object(telegram, "call", lambda *a, **k: []), \
                mock.patch.object(telegram.time, "time", side_effect=[0, 0, 10]):
            self.assertIsNone(telegram.wait_for_start("1:x", "c0de", seconds=5))

    def test_setup_links_with_code_and_saves_only_matching_chat(self):
        tok = "123456:" + "a" * 35
        opened, saved = [], {}
        with mock.patch.object(telegram, "read_token", lambda stdin=False: tok), \
                mock.patch.object(telegram, "call", lambda *a, **k: {"username": "bot"}), \
                mock.patch.object(telegram, "plugin_token", lambda: ""), \
                mock.patch.object(telegram, "save_token"), \
                mock.patch.object(telegram.subprocess, "run", lambda args, **k: opened.append(args)), \
                mock.patch.object(telegram, "wait_for_start",
                                  lambda t, code: {"id": 7, "first_name": "Me"} if opened[0][1].endswith(
                                      "?start=" + code) else None), \
                mock.patch.object(telegram, "write_config", lambda **kw: saved.update(kw)), \
                mock.patch.object(telegram, "away_after", lambda: 120), \
                mock.patch("sys.stdout", io.StringIO()):
            self.assertEqual(telegram.setup(), 0)
        self.assertEqual(saved["telegram_chat"], "7")

    def test_setup_warns_about_plugin_bot(self):
        tok = "123456:" + "a" * 35
        out = io.StringIO()
        with mock.patch.object(telegram, "read_token", lambda stdin=False: tok), \
                mock.patch.object(telegram, "call", lambda *a, **k: {"username": "bot"}), \
                mock.patch.object(telegram, "plugin_token", lambda: tok), \
                mock.patch.object(telegram, "save_token") as save, \
                mock.patch.object(telegram.sys, "stdin", io.StringIO("")), \
                mock.patch("sys.stdout", out):
            self.assertEqual(telegram.setup(), telegram.SHARED_BOT)
        save.assert_not_called()
        self.assertIn("плагине Telegram", out.getvalue())


class Render(unittest.TestCase):
    def test_secrets_hidden(self):
        body, _, _ = ta.render("Bash", {"command": "curl -H 'Authorization: Bearer abcdef123' "
                                                  "https://u:hunter22@x.io?token=s3cr3tvalue"})
        for secret in ("abcdef123", "hunter22", "s3cr3tvalue"):
            self.assertNotIn(secret, body)

    def test_long_command_marked(self):
        body, _, cut = ta.render("Bash", {"command": "echo " + "x" * 2000})
        self.assertTrue(cut)
        self.assertLessEqual(len(body), ta.SHOW + 1)
        self.assertIn("не целиком", ta.message(payload(tool_input={"command": "x" * 2000})))

    def test_paths_and_html(self):
        self.assertEqual(ta.render("Edit", {"file_path": os.path.expanduser("~/a.txt")})[0], "~/a.txt")
        text = ta.message(payload(tool_input={"command": "echo '<b>' && ls\x1b[2J"}))
        self.assertIn("&lt;b&gt;", text)
        self.assertNotIn("\x1b", text)


class Guard(unittest.TestCase):
    def test_guard_reason_shown(self):
        text = ta.message(payload(tool_name="Read", tool_input={"file_path": "/p/.env"}, cwd="/p"))
        self.assertIn("agentmeister guard", text)
        self.assertNotIn("agentmeister guard", ta.message(payload()))


class Wiring(unittest.TestCase):
    def test_hook_row_and_timeout(self):
        self.assertIn(("PermissionRequest", "approve-hook", False, None), HOOKS)
        self.assertGreater(HOOK_TIMEOUTS["approve-hook"], ta.WAIT + ta.POLL + 15)
        import claude_settings
        entry = claude_settings.entry("approve-hook", False, None)
        self.assertEqual(entry["hooks"][0]["timeout"], HOOK_TIMEOUTS["approve-hook"])
        self.assertEqual(claude_settings.entry("notify-hook", True, None)["hooks"][0]["timeout"], 10)

    def test_notify_skips_duplicate_telegram(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        with mock.patch.object(ta, "DIR", d):
            prompt = {"notification_type": "permission_prompt"}
            self.assertFalse(notify.approval_pending(prompt, SID))
            with open(os.path.join(d, "abc.pending"), "w") as f:
                json.dump({"sid": SID, "message_id": 1, "at": ta.time.time()}, f)
            self.assertTrue(notify.approval_pending(prompt, SID))
            self.assertFalse(notify.approval_pending({"notification_type": "idle_prompt"}, SID))
            self.assertFalse(notify.approval_pending(prompt, "other"))


class Keychain(unittest.TestCase):
    """Токен бота живет под agentmeister.notify/telegram. Старая запись mnrh-telegram/bot копируется туда
    и остается для старых версий, пока канал не отключат."""

    def fake_security(self, store, argv=None):
        def run(cmd, **kw):
            if argv is not None:
                argv.append(list(cmd))
            if cmd == ["security", "-i"]:  # команда с секретом приходит через stdin
                cmd = ["security"] + shlex.split(kw["input"])
            op, service, account = cmd[1], cmd[cmd.index("-s") + 1], cmd[cmd.index("-a") + 1]
            key = (service, account)
            if op == "find-generic-password":
                return mock.Mock(returncode=0 if key in store else 44, stdout=store.get(key, "") + "\n")
            if op == "add-generic-password":
                store[key] = cmd[cmd.index("-w") + 1]
            if op == "delete-generic-password":
                store.pop(key, None)
            return mock.Mock(returncode=0, stdout="")
        return run

    def test_old_token_is_copied_and_kept(self):
        store = {("mnrh-telegram", "bot"): "123:old"}
        with mock.patch.object(telegram.subprocess, "run", self.fake_security(store)):
            self.assertEqual(telegram.token(), "123:old")
        self.assertEqual(store, {("mnrh-telegram", "bot"): "123:old", ("agentmeister.notify", "telegram"): "123:old"})

    def test_new_token_wins(self):
        store = {("mnrh-telegram", "bot"): "123:old", ("agentmeister.notify", "telegram"): "456:new"}
        with mock.patch.object(telegram.subprocess, "run", self.fake_security(store)):
            self.assertEqual(telegram.token(), "456:new")

    def test_token_never_in_argv(self):
        store, argv = {}, []
        token = '123:a"b\\c d'
        with mock.patch.object(telegram.subprocess, "run", self.fake_security(store, argv)):
            telegram.save_token(token)
        self.assertEqual(store, {("agentmeister.notify", "telegram"): token})
        self.assertFalse([cmd for cmd in argv if any("123:" in part for part in cmd)])

    def test_forget_removes_both(self):
        store = {("mnrh-telegram", "bot"): "123:old", ("agentmeister.notify", "telegram"): "456:new"}
        with mock.patch.object(telegram.subprocess, "run", self.fake_security(store)):
            telegram.forget_token()
        self.assertEqual(store, {})


if __name__ == "__main__":
    unittest.main()
