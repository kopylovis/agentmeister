import base64
import contextlib
import fcntl
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "libexec", "agentmeister", "lib"))
import notify  # noqa: E402
import headsup  # noqa: E402,F401
import claude_proc  # noqa: E402
import mnrhlib  # noqa: E402
import claude_settings  # noqa: E402
import swiftagent  # noqa: E402

# Тесты не должны зависеть от терминала, в котором их запустили: во вкладке Agentmeister есть AGENTMEISTER_TAB,
# в iTerm2 ITERM_SESSION_ID, и хук принял бы их за свою вкладку. Нужные значения тесты ставят сами. Переменные
# убираются только на время этого модуля: остальные тесты discover видят окружение как есть.
_TERMINAL_ENV = mock.patch.dict(os.environ)
# хук еще снимает заметки Heads up в историю (headsup.py): тесты уведомлений не должны писать в настоящую
_HEADSUP = mock.patch("headsup.from_hook", return_value=0)


# настоящий config не читается: с подключенным ntfy или Tossling хуки в тестах слали бы настоящие уведомления
_CONFIG_DIR = tempfile.mkdtemp()
_CONFIG = mock.patch("mnrhlib.CONFIG", os.path.join(_CONFIG_DIR, "config"))


def setUpModule():
    _TERMINAL_ENV.start()
    _HEADSUP.start()
    _CONFIG.start()
    for name in ("AGENTMEISTER_TAB", "ITERM_SESSION_ID", "TERM_PROGRAM", "LC_TERMINAL"):
        os.environ.pop(name, None)


def tearDownModule():
    _CONFIG.stop()
    shutil.rmtree(_CONFIG_DIR, True)
    _HEADSUP.stop()
    _TERMINAL_ENV.stop()


def pin_lang(case, lang):
    """Язык уведомлений берется из config или macOS: тест задает его сам."""
    patcher = mock.patch("mnrhlib.lang", return_value=lang)
    patcher.start()
    case.addCleanup(patcher.stop)


class BannerText(unittest.TestCase):
    """Текст уведомления по-английски, если язык не ru, и прежний русский для ru."""

    def messages(self, lang):
        pin_lang(self, lang)
        st = {"prompt_at": time.time() - 125, "last": ""}
        with mock.patch.object(notify, "after", return_value=0):
            return [notify.message_for({"hook_event_name": "Stop"}, st),
                    notify.message_for({"hook_event_name": "Stop"}, {"prompt_at": time.time() - 5}),
                    notify.message_for({"hook_event_name": "PermissionRequest"}, st, codex=True),
                    notify.message_for({"hook_event_name": "Notification", "notification_type": "permission_prompt",
                                               "message": "Claude needs your permission to use Bash"}, st),
                    notify.message_for({"hook_event_name": "Notification",
                                               "notification_type": "agent_needs_input"}, st),
                    notify.message_for({"hook_event_name": "Notification", "notification_type": "idle_prompt"}, st)]

    def test_english(self):
        self.assertEqual(self.messages("en"), [
            ("Done in 2m 5s", "Turn finished"), ("Done in 5s", "Turn finished"),
            ("Permission needed", "Codex is waiting for permission"), ("Permission needed", "Bash"),
            ("Answer needed", "Claude has a question"), ("Waiting for you", "Claude is waiting for your reply")])

    def test_russian(self):
        self.assertEqual(self.messages("ru"), [
            ("Готово за 2 мин 5 с", "Ход закончен"), ("Готово за 5 с", "Ход закончен"),
            ("Нужно разрешение", "Codex ждет разрешения"), ("Нужно разрешение", "Bash"),
            ("Нужен ответ", "Claude задаёт вопрос"), ("Ждёт тебя", "Claude ждёт ответа")])


class TosslingPush(unittest.TestCase):
    def test_completion_uses_agent_name_and_project_icon(self):
        pin_lang(self, "en")
        sid = "a812d4fa-e535-463a-8369-f1433fa25652"
        payload = {"session_id": sid, "hook_event_name": "Stop", "cwd": "/work/agentmeister",
                   "last_assistant_message": "Finished the build"}
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(notify, "STATE", tmp), \
                mock.patch.object(notify, "enabled", return_value=True), \
                mock.patch.object(notify, "after", return_value=20), \
                mock.patch.object(notify.time, "time", return_value=1741), \
                mock.patch.object(notify, "app_tab", return_value=sid), \
                mock.patch.object(notify, "watching", return_value=True), \
                mock.patch.object(notify.channels.telegram, "configured", return_value=False), \
                mock.patch.object(notify.ntfy_alert, "phone_mode", return_value="always"), \
                mock.patch.object(notify.ntfy_alert, "endpoint", return_value=("https://example.com", "test")), \
                mock.patch.object(notify.ntfy_alert, "publisher_token", side_effect=["project-token", ""]), \
                mock.patch("urllib.request.urlopen") as send:
            for codex, agent in ((False, "Claude Code"), (True, "Codex")):
                with self.subTest(agent=agent), mock.patch.object(sys, "stdin", io.StringIO(json.dumps(payload))):
                    notify.save_state(sid, {"prompt_at": 1000})
                    send.reset_mock()
                    self.assertEqual(notify.hook(codex=codex), 0)
                    send.assert_called_once()
                    expected_token = "test" if codex else "project-token"
                    self.assertEqual(send.call_args.args[0].get_header("Authorization"), f"Bearer {expected_token}")
                    self.assertEqual(json.loads(send.call_args.args[0].data), {
                        "topic": "agentmeister", "title": f"{agent}: Done in 12m 21s", "message": "Finished the build",
                        "priority": 3, "icon": notify.ntfy_alert.AGENTMEISTER_ICON,
                    })


class AwayThreshold(unittest.TestCase):
    """Порог "не за Mac" общий для каналов: notify_away, без него прежний telegram_away, без обоих 120 с."""

    def setUp(self):
        fd, self.conf = tempfile.mkstemp()
        os.close(fd)
        self.addCleanup(os.remove, self.conf)
        patcher = mock.patch("mnrhlib.CONFIG", self.conf)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, text):
        with open(self.conf, "w") as f:
            f.write(text)

    def test_default(self):
        self.assertEqual(notify.presence.away_after(), 120)

    def test_old_telegram_value_is_read(self):
        self.write("telegram_away=300\n")
        self.assertEqual(notify.presence.away_after(), 300)

    def test_new_value_wins_and_replaces_old(self):
        self.write("telegram_away=300\nnotify_away=60\n")
        self.assertEqual(notify.presence.away_after(), 60)
        notify.presence.set_away_after("45")
        with open(self.conf) as f:
            self.assertEqual(f.read(), "notify_away=45\n")

    def test_telegram_command_sets_shared_value(self):
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(notify.telegram, "configured", return_value=False):
            self.assertEqual(notify.telegram.main(["away", "600"]), 0)
        self.assertEqual(notify.presence.away_after(), 600)


class PhoneTargets(unittest.TestCase):
    """Какие каналы получат сообщение: режим, "не за Mac" и запросы, на которые канал отвечает сам."""

    class Fake(notify.channels.Channel):
        def __init__(self, name, mode, approvals=False):
            self.name, self._mode, self.handles_approvals = name, mode, approvals

        def configured(self):
            return self._mode != "off"

        def mode(self):
            return self._mode

    def names(self, chans, away, pending=False):
        presence_away = mock.Mock(return_value=away)
        with mock.patch.object(notify.channels, "ALL", chans), mock.patch.object(notify.presence, "away", presence_away):
            out = [ch.name for ch in notify.channels.targets(lambda: pending)]
        return out, presence_away.call_count

    def test_modes(self):
        chans = (self.Fake("tg", "away", approvals=True), self.Fake("ts", "always"), self.Fake("off", "off"))
        self.assertEqual(self.names(chans, away=True), (["tg", "ts"], 1))
        self.assertEqual(self.names(chans, away=False), (["ts"], 1))

    def test_presence_checked_only_when_needed(self):
        self.assertEqual(self.names((self.Fake("ts", "always"),), away=False), (["ts"], 0))

    def test_pending_approval_skips_only_the_answering_channel(self):
        chans = (self.Fake("tg", "always", approvals=True), self.Fake("ts", "always"))
        self.assertEqual(self.names(chans, away=True, pending=True), (["ts"], 0))

    def test_send_error_is_logged_and_other_channels_still_get_it(self):
        bad, good = self.Fake("bad", "always"), self.Fake("good", "always")
        bad.send = mock.Mock(side_effect=notify.channels.SendError("HTTP 500"))
        good.send = mock.Mock()
        pin_lang(self, "en")
        sid = "b812d4fa-e535-463a-8369-f1433fa25652"
        payload = {"session_id": sid, "hook_event_name": "Notification", "notification_type": "agent_needs_input",
                   "cwd": "/work/agentmeister"}
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(notify, "STATE", tmp), \
                mock.patch.object(notify, "enabled", return_value=True), \
                mock.patch.object(notify, "app_tab", return_value=sid), \
                mock.patch.object(notify, "watching", return_value=True), \
                mock.patch.object(notify, "log_error") as log, \
                mock.patch.object(notify.channels, "ALL", (bad, good)), \
                mock.patch.object(sys, "stdin", io.StringIO(json.dumps(payload))):
            notify.save_state(sid, {"prompt_at": 1000})
            self.assertEqual(notify.hook(), 0)
        log.assert_called_once_with("bad: HTTP 500")
        msg = good.send.call_args.args[0]
        self.assertEqual((msg.agent, msg.project, msg.urgent), ("Claude Code", "agentmeister", True))


def empty_config(case):
    """Пустой временный config до и после теста: настройки каналов из одного теста не доходят до хуков в других."""
    path = mnrhlib.CONFIG

    def clear():
        with open(path, "w"):
            pass
    clear()
    case.addCleanup(clear)


class NtfyChannel(unittest.TestCase):
    """Канал ntfy: случайный канал, авторизация, только заголовок на ntfy.sh, CLI."""

    def setUp(self):
        empty_config(self)
        self.keys = {}
        for name, fn in (("find", lambda account, service="agentmeister.notify": self.keys.get((service, account), "")),
                         ("save", lambda account, value, label, service="agentmeister.notify": self.keys.update({(service, account): value}) or True),
                         ("delete", lambda account, service="agentmeister.notify": self.keys.pop((service, account), None))):
            patcher = mock.patch.object(notify.keychain, name, fn)
            patcher.start()
            self.addCleanup(patcher.stop)

    def cli(self, *args, stdin=""):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), mock.patch.object(sys, "stdin", io.StringIO(stdin)):
            code = notify.ntfy_channel.main(list(args))
        return code, out.getvalue()

    def sent(self, title="t", text="m", priority=3):
        with mock.patch("urllib.request.urlopen") as urlopen:
            notify.ntfy_channel.send(title, text, priority)
        req = urlopen.call_args.args[0]
        return req.full_url, req.get_header("Authorization"), json.loads(req.data)

    def test_setup_makes_random_topic_and_turns_on(self):
        pin_lang(self, "en")
        code, out = self.cli("setup")
        self.assertEqual(code, 0)
        topic = notify.ntfy_channel.topic()
        self.assertRegex(topic, r"^agentmeister-[A-Za-z0-9]{20}$")
        self.assertEqual((notify.ntfy_channel.mode(), notify.ntfy_channel.body_mode()), ("away", "title"))
        self.assertIn("https://ntfy.sh/" + topic, out)
        self.assertIn("anyone who knows the topic name", out)
        self.cli("topic", "new")
        self.assertNotEqual(notify.ntfy_channel.topic(), topic)

    def test_public_server_without_token(self):
        self.cli("setup", "--topic", "agentmeister-abc")
        url, auth, data = self.sent("Claude Code: Done", "proj", 3)
        self.assertEqual((url, auth), ("https://ntfy.sh", None))
        self.assertEqual(data, {"topic": "agentmeister-abc", "message": "proj", "title": "Claude Code: Done",
                                "priority": 3, "icon": notify.ntfy_alert.AGENTMEISTER_ICON})

    def test_own_server_with_token_or_login(self):
        self.assertEqual(self.cli("setup", "--server", "https://ntfy.example.com/", "--topic", "ag")[0], 0)
        self.assertEqual(notify.ntfy_channel.body_mode(), "full")
        self.assertEqual(self.cli("token", stdin="tk_abc\n")[0], 0)
        self.assertEqual(self.keys, {("agentmeister.notify", "ntfy"): "tk_abc"})
        self.assertEqual(self.sent()[:2], ("https://ntfy.example.com", "Bearer tk_abc"))
        self.cli("token", stdin="me:pw")
        self.assertEqual(self.sent()[1], "Basic bWU6cHc=")
        self.cli("forget")
        self.assertEqual((self.keys, notify.ntfy_channel.configured(), notify.ntfy_channel.mode()), ({}, False, "off"))

    def test_bad_input(self):
        self.assertEqual(self.cli("setup", "--server", "ntfy.example.com")[0], 2)
        self.assertEqual(self.cli("setup", "--topic", "bad topic")[0], 2)
        self.assertFalse(notify.ntfy_channel.configured())
        self.assertEqual(self.cli("away")[0], 1)

    def test_hook_sends_only_title_and_project_to_ntfy_sh(self):
        pin_lang(self, "en")
        self.cli("setup", "--topic", "agentmeister-abc")
        self.cli("always")
        sid = "c812d4fa-e535-463a-8369-f1433fa25652"
        payload = {"session_id": sid, "hook_event_name": "Notification", "notification_type": "permission_prompt",
                   "message": "Claude needs your permission to use Bash", "cwd": "/work/secret-project"}
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(notify, "STATE", tmp), \
                mock.patch.object(notify, "enabled", return_value=True), \
                mock.patch.object(notify, "app_tab", return_value=sid), \
                mock.patch.object(notify, "watching", return_value=True), \
                mock.patch.object(notify, "session_title", return_value="Rotate the prod keys"), \
                mock.patch.object(notify.telegram, "configured", return_value=False), \
                mock.patch.object(notify.ntfy_alert, "endpoint", return_value=None), \
                mock.patch.object(sys, "stdin", io.StringIO(json.dumps(payload))), \
                mock.patch("urllib.request.urlopen") as urlopen:
            notify.save_state(sid, {"prompt_at": 1000})
            self.assertEqual(notify.hook(), 0)
        data = json.loads(urlopen.call_args.args[0].data)
        self.assertEqual((data["title"], data["message"], data["priority"]),
                         ("Claude Code: Permission needed", "secret-project", 4))


class BarkChannel(unittest.TestCase):
    """Bark: ключ из адреса приложения, только заголовок на api.day.app, шифрование AES-256-CBC как в приложении."""

    def setUp(self):
        empty_config(self)
        self.keys = {}
        for name, fn in (("find", lambda account, service="agentmeister.notify": self.keys.get((service, account), "")),
                         ("save", lambda account, value, label, service="agentmeister.notify": self.keys.update({(service, account): value}) or True),
                         ("delete", lambda account, service="agentmeister.notify": self.keys.pop((service, account), None))):
            patcher = mock.patch.object(notify.keychain, name, fn)
            patcher.start()
            self.addCleanup(patcher.stop)

    def cli(self, *args, stdin=""):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), mock.patch.object(sys, "stdin", io.StringIO(stdin)):
            code = notify.bark_channel.main(list(args))
        return code, out.getvalue()

    def sent(self, urgent=False):
        with mock.patch("urllib.request.urlopen") as urlopen:
            notify.bark_channel.send("Claude Code: Answer needed", "Which branch?", urgent)
        req = urlopen.call_args.args[0]
        return req.full_url, json.loads(req.data)

    def decrypt(self, data):
        key = self.keys[("agentmeister.notify", "bark-key")]
        r = subprocess.run(["/usr/bin/openssl", "enc", "-d", "-aes-256-cbc", "-K", key.encode().hex(),
                            "-iv", data["iv"].encode().hex()], input=base64.b64decode(data["ciphertext"]),
                           capture_output=True, check=True)
        return json.loads(r.stdout)

    def test_parse_key(self):
        self.assertEqual(notify.bark_channel.parse_key("https://api.day.app/AbC123xyz/Hello"), ("https://api.day.app", "AbC123xyz"))
        self.assertEqual(notify.bark_channel.parse_key(" AbC123xyz "), (None, "AbC123xyz"))
        self.assertEqual(notify.bark_channel.parse_key("https://bark.example.com:8080/k1/"), ("https://bark.example.com:8080", "k1"))

    def test_setup_from_app_url_on_stdin(self):
        pin_lang(self, "en")
        code, out = self.cli("setup", stdin="https://api.day.app/AbC123xyz/\n")
        self.assertEqual(code, 0)
        self.assertEqual(self.keys, {("agentmeister.notify", "bark"): "AbC123xyz"})
        self.assertEqual((notify.bark_channel.mode(), notify.bark_channel.body_mode()), ("away", "title"))
        self.assertIn("bark encrypt on", out)
        url, data = self.sent(urgent=True)
        self.assertEqual(url, "https://api.day.app/push")
        self.assertEqual(data, {"device_key": "AbC123xyz", "level": "timeSensitive", "title": "Claude Code: Answer needed",
                                "body": "Which branch?", "group": "Agentmeister", "icon": notify.ntfy_alert.AGENTMEISTER_ICON})

    def test_bad_key(self):
        self.assertEqual(self.cli("setup", "not a key!")[0], 2)
        self.assertFalse(notify.bark_channel.configured())

    def test_encryption_hides_everything_but_the_key(self):
        pin_lang(self, "en")
        self.cli("setup", "AbC123xyz")
        code, out = self.cli("encrypt", "on")
        self.assertEqual(code, 0)
        key = self.keys[("agentmeister.notify", "bark-key")]
        self.assertRegex(key, r"^[A-Za-z0-9]{32}$")
        self.assertIn("Key " + key, out)
        self.assertEqual(notify.bark_channel.body_mode(), "full")
        _, first = self.sent()
        _, second = self.sent()
        self.assertEqual(set(first), {"device_key", "level", "ciphertext", "iv"})
        self.assertNotEqual(first["iv"], second["iv"])
        self.assertEqual(self.decrypt(first), {"title": "Claude Code: Answer needed", "body": "Which branch?",
                                               "group": "Agentmeister", "icon": notify.ntfy_alert.AGENTMEISTER_ICON})
        self.cli("encrypt", "off")
        self.assertNotIn(("agentmeister.notify", "bark-key"), self.keys)
        self.assertIn("title", self.sent()[1])

    def test_unknown_device_key(self):
        err = notify.bark_channel.urllib.error.HTTPError(
            "https://api.day.app/push", 400, "x", {},
            io.BytesIO(b'{"code":400,"message":"failed to get device token: failed to get [x] device token"}'))
        self.cli("setup", "AbC123xyz")
        with mock.patch("urllib.request.urlopen", side_effect=err), \
                self.assertRaisesRegex(notify.bark_channel.BarkError, "ключ устройства"):
            notify.bark_channel.send("t", "b")

    def test_forget_and_own_server(self):
        self.cli("setup", "https://bark.example.com/k1")
        self.assertEqual((notify.bark_channel.server(), notify.bark_channel.body_mode()), ("https://bark.example.com", "full"))
        self.cli("server", "auto")
        self.assertEqual(notify.bark_channel.server(), "https://api.day.app")
        self.cli("encrypt", "on")
        self.cli("forget")
        self.assertEqual((self.keys, notify.bark_channel.mode()), ({}, "off"))


class TosslingPreset(unittest.TestCase):
    """Tossling как пресет ntfy: настройки tossling CLI или адрес вручную с токеном из Связки ключей."""

    def setUp(self):
        self.conf = mnrhlib.CONFIG
        empty_config(self)
        self.keys = {}
        patcher = mock.patch.object(notify.keychain, "find",
                                    lambda account, service="agentmeister.notify": self.keys.get((service, account), ""))
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_old_phone_mode_is_read_and_replaced(self):
        with open(self.conf, "w") as f:
            f.write("notify_phone=always\n")
        self.assertEqual(notify.ntfy_alert.phone_mode(), "always")
        notify.ntfy_alert.set_mode("away")
        with open(self.conf) as f:
            self.assertEqual(f.read(), "notify_tossling=away\n")

    def test_endpoint_from_cli_then_manual(self):
        cli = {"server": "https://t.example.com/", "token": "tk_room"}
        with mock.patch.object(notify.ntfy_alert, "tossling_config", return_value=cli):
            self.assertEqual(notify.ntfy_alert.endpoint(), ("https://t.example.com", "tk_room"))
            self.assertEqual(notify.ntfy_alert.source(), "cli")
            # другой сервер вручную: токен комнаты от него не годится, нужен токен публикации
            notify.write_config(notify_tossling_server="https://other.example.com")
            self.assertIsNone(notify.ntfy_alert.endpoint())
            self.keys[("agentmeister.notify", "tossling")] = "tk_pub"
            self.assertEqual(notify.ntfy_alert.endpoint(), ("https://other.example.com", "tk_pub"))
            self.assertEqual(notify.ntfy_alert.source(), "manual")

    def test_token_saved_before_129_is_still_read(self):
        self.keys[("agentmeister.tossling", "https://t.example.com")] = "tk_old"
        with mock.patch.object(notify.ntfy_alert, "tossling_config", return_value={}):
            notify.write_config(notify_tossling_server="https://t.example.com")
            self.assertEqual(notify.ntfy_alert.endpoint(), ("https://t.example.com", "tk_old"))

    def test_title_only_body(self):
        msg = notify.channels.Message("Codex", "Answer needed", "app", "Session", "Which branch?", True)
        self.assertEqual(notify.channels.ntfy_text(msg, "title"), ("Codex: Answer needed", "app"))
        self.assertEqual(notify.channels.ntfy_text(msg, "full"), ("Codex: Answer needed", "Session\n\nWhich branch?"))


class HelpText(unittest.TestCase):
    """agentmeister notify -h по-английски, если язык не ru, и прежний русский для ru."""

    def usage(self, lang):
        pin_lang(self, lang)
        out = io.StringIO()
        with mock.patch.object(notify, "after", return_value=30), contextlib.redirect_stdout(out):
            notify.usage()
        return out.getvalue()

    def test_english(self):
        text = self.usage("en")
        self.assertIn("agentmeister notify on | off     turn on or off\n", text)
        self.assertIn("(now 30s, default 20)", text)
        self.assertIn("Installed by agentmeister setup:", text)
        self.assertNotRegex(text, "[а-яё]")

    def test_russian(self):
        text = self.usage("ru")
        self.assertIn("agentmeister notify on | off     включить или выключить\n", text)
        self.assertIn("(сейчас 30 с, по умолчанию 20)", text)
        self.assertIn("Ставит agentmeister setup:", text)


class Setting(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.user = self.file("user.json")
        self.legacy = self.file("legacy.json")
        self.managed = self.file("managed.json")

    def file(self, name, data=None):
        path = os.path.join(self.dir, name)
        if data is not None:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                json.dump(data, f)
        return path

    def get(self, cwd=None):
        return claude_settings.setting("inputNeededNotifEnabled", cwd, self.user, self.legacy, self.managed)

    def test_missing_everywhere(self):
        self.assertIsNone(self.get())

    def test_order(self):
        self.file("legacy.json", {"inputNeededNotifEnabled": True})
        self.assertIs(self.get(), True)
        self.file("user.json", {"inputNeededNotifEnabled": False})
        self.assertIs(self.get(), False)
        proj = os.path.join(self.dir, "proj")
        self.file("proj/.claude/settings.local.json", {"inputNeededNotifEnabled": True})
        self.assertIs(self.get(proj), True)
        self.file("managed.json", {"inputNeededNotifEnabled": False})
        self.assertIs(self.get(proj), False)

    def test_broken_file_skipped(self):
        with open(self.user, "w") as f:
            f.write("{nope")
        self.file("legacy.json", {"inputNeededNotifEnabled": True})
        self.assertIs(self.get(), True)


class NativePush(unittest.TestCase):
    def native(self, env, enabled, **payload):
        p = {"hook_event_name": "Notification", "notification_type": "permission_prompt", "cwd": "/p"}
        p.update(payload)
        with mock.patch.dict(os.environ, env, clear=False), \
                mock.patch.object(claude_settings, "setting", lambda key, cwd=None: enabled):
            if "CLAUDE_CODE_BRIDGE_SESSION_ID" not in env:
                os.environ.pop("CLAUDE_CODE_BRIDGE_SESSION_ID", None)
            return notify.native_push(p)

    def test_remote_control_with_push_on(self):
        rc = {"CLAUDE_CODE_BRIDGE_SESSION_ID": "session_abc"}
        self.assertTrue(self.native(rc, True))
        self.assertTrue(self.native(rc, True, notification_type="elicitation_dialog"))

    def test_our_push_stays(self):
        rc = {"CLAUDE_CODE_BRIDGE_SESSION_ID": "session_abc"}
        self.assertFalse(self.native({}, True))
        self.assertFalse(self.native(rc, False))
        self.assertFalse(self.native(rc, None))
        # «Готово» и долгое ожидание Claude присылает, только если сам решит: их не отключаем
        self.assertFalse(self.native(rc, True, notification_type="idle_prompt"))
        self.assertFalse(self.native(rc, True, hook_event_name="Stop"))


class ClaudeNotify(unittest.TestCase):
    def test_prompt_installed_in_user_sounds_and_repaired_after_change(self):
        with tempfile.TemporaryDirectory() as home, mock.patch.object(notify, "HOME", home):
            target = os.path.join(home, "Library", "Sounds", "Agentmeister-Prompt.wav")
            source = os.path.join(os.path.dirname(notify.AGENT.src), "Agentmeister-Prompt.wav")
            with open(source, "rb") as f:
                expected = f.read()
            for _ in range(2):
                notify.install_sound()
                with open(target, "rb") as f:
                    self.assertEqual(f.read(), expected)
                with open(target, "wb") as f:
                    f.write(b"old sound")

    def test_helper_receives_post_arguments_and_confirms_delivery(self):
        def accept(args, **kwargs):
            self.assertEqual(args[:4], [notify.AGENT.bin, "post", "--title", "tab name"])
            self.assertFalse(kwargs.get("shell"))
            with open(args[args.index("--result") + 1], "w") as receipt:
                receipt.write("ok")

        with mock.patch.object(notify.subprocess, "Popen", side_effect=accept), \
                mock.patch.object(notify, "sound", return_value=True):
            self.assertEqual(notify.post("tab name", "", "ready", "test"), "ok")

    def test_interactive_question_without_tty(self):
        sid = "a812d4fa-e535-463a-8369-f1433fa25652"
        data = {"session_id": sid, "hook_event_name": "Notification", "notification_type": "agent_needs_input"}
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(claude_proc, "CLAUDE", tmp), \
                mock.patch.object(notify, "STATE", tmp), mock.patch.object(notify, "enabled", return_value=True), \
                mock.patch.object(notify, "own_terminal", return_value=None), \
                mock.patch.object(notify, "iterm_session", return_value=""), \
                mock.patch.object(notify, "ensure_app", return_value=True), \
                mock.patch.object(notify.channels.telegram, "configured", return_value=False), \
                mock.patch.object(notify.ntfy_alert, "configured", return_value=False), \
                mock.patch.object(notify, "post", side_effect=["open failed", "ok"]) as post:
            os.mkdir(os.path.join(tmp, "sessions"))
            for session, kind in [(sid, "headless"), ("another", "interactive"), (sid, "interactive"), (sid, "interactive")]:
                with open(claude_proc.session_file(123), "w") as f:
                    json.dump({"sessionId": session, "kind": kind, "entrypoint": "cli"}, f)
                with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(data))):
                    self.assertEqual(notify.hook(), 0)
                if session != sid or kind != "interactive":
                    post.assert_not_called()
                self.assertEqual(bool(notify.load_state(sid).get("notified")), post.call_count == 2)
            self.assertEqual(post.call_count, 2)
            self.assertIsNone(post.call_args.args[-1])


class AppTab(unittest.TestCase):
    TAB = "5f0c7a52-3b1e-4c4e-9b5a-2d9f1c0e7a11"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        for name, value in (("APP_DIR", self.tmp.name), ("APP_FRONT", os.path.join(self.tmp.name, "front.json")),
                            ("APP_FOCUS", os.path.join(self.tmp.name, "focus.json"))):
            patcher = mock.patch.object(notify, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def front(self, tab, active):
        with open(notify.APP_FRONT, "w") as f:
            json.dump({"tab": tab, "active": active}, f)

    def test_tab_id_comes_from_env_and_must_be_a_uuid(self):
        with mock.patch.dict(os.environ, {notify.APP_TAB_ENV: self.TAB.upper()}):
            self.assertEqual(notify.app_tab(), self.TAB)
        with mock.patch.dict(os.environ, {notify.APP_TAB_ENV: "../etc"}):
            self.assertEqual(notify.app_tab(), "")

    def test_watching_only_when_this_tab_is_front_in_an_active_window(self):
        tty = "app:" + self.TAB
        self.assertFalse(notify.watching(notify.APP_BUNDLE, tty))
        self.front(self.TAB, True)
        self.assertTrue(notify.watching(notify.APP_BUNDLE, tty))
        self.front(self.TAB, False)
        self.assertFalse(notify.watching(notify.APP_BUNDLE, tty))
        self.front("00000000-0000-0000-0000-000000000000", True)
        self.assertFalse(notify.watching(notify.APP_BUNDLE, tty))

    SID = "a812d4fa-e535-463a-8369-f1433fa25652"

    def test_click_leaves_a_focus_request_and_opens_the_url(self):
        with mock.patch.object(notify.subprocess, "run", return_value=mock.Mock(returncode=0)) as run:
            self.assertEqual(notify.focus("app:" + self.TAB, notify.APP_BUNDLE), 0)
        with open(notify.APP_FOCUS) as f:
            request = json.load(f)
        self.assertEqual(request["tab"], self.TAB)
        self.assertNotIn("session", request)
        self.assertEqual(run.call_args.args[0], ["open", f"agentmeister://focus?tab={self.TAB}"])

    def test_click_carries_the_session_id(self):
        with mock.patch.object(notify.subprocess, "run", return_value=mock.Mock(returncode=0)) as run:
            notify.focus("app:" + self.TAB, notify.APP_BUNDLE, self.SID)
        with open(notify.APP_FOCUS) as f:
            self.assertEqual(json.load(f)["session"], self.SID)
        self.assertEqual(run.call_args_list[0].args[0],
                         ["open", f"agentmeister://focus?tab={self.TAB}&session={self.SID}"])
        self.assertEqual(run.call_count, 1)
        # кривой id сессии не попадает ни в ссылку, ни в запрос
        with mock.patch.object(notify.subprocess, "run", return_value=mock.Mock(returncode=0)) as run:
            notify.focus("app:" + self.TAB, notify.APP_BUNDLE, "x&tab=evil")
        self.assertEqual(run.call_args.args[0], ["open", f"agentmeister://focus?tab={self.TAB}"])

    def test_click_opens_the_app_by_bundle_when_the_url_fails(self):
        with mock.patch.object(notify.subprocess, "run",
                               side_effect=[mock.Mock(returncode=1), mock.Mock(returncode=0)]) as run:
            self.assertEqual(notify.focus("app:" + self.TAB, notify.APP_BUNDLE, self.SID), 0)
        self.assertEqual(run.call_args_list[1].args[0], ["open", "-b", notify.APP_BUNDLE])
        self.assertTrue(os.path.exists(notify.APP_FOCUS))

    def test_bad_tab_in_click_is_ignored(self):
        with mock.patch.object(notify.subprocess, "run") as run:
            self.assertEqual(notify.focus("app:nope", notify.APP_BUNDLE), 1)
        run.assert_not_called()
        self.assertFalse(os.path.exists(notify.APP_FOCUS))


class NotifyBuild(unittest.TestCase):
    """Сборка приложения: замок, фон из хука, уборка .build-*. swiftc и настоящий ~/Library не трогаются."""

    def setUp(self):
        pin_lang(self, "ru")  # тесты сверяют русский текст уведомления
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.agent = swiftagent.SwiftAgent("notify", "agentmeister Notify", "com.agentmeister.notify",
                                           app_dir=self.dir)
        patcher = mock.patch.object(notify, "AGENT", self.agent)
        patcher.start()
        self.addCleanup(patcher.stop)

    def hold_lock(self):
        fd = os.open(os.path.join(self.dir, ".notify.build.lock"), os.O_RDWR | os.O_CREAT)
        self.addCleanup(os.close, fd)
        fcntl.flock(fd, fcntl.LOCK_EX)

    def test_build_skips_when_another_process_holds_lock(self):
        self.hold_lock()
        self.assertTrue(self.agent.building())
        with mock.patch.object(swiftagent.subprocess, "run") as run:
            self.assertIsNone(self.agent.build(wait=False))
        run.assert_not_called()

    def test_build_lock_free_after_use(self):
        self.assertFalse(self.agent.building())
        with self.agent.build_lock(wait=False) as got:
            self.assertTrue(got)
        self.assertFalse(self.agent.building())

    def test_stale_build_dirs_removed_on_next_build(self):
        old, fresh = os.path.join(self.dir, ".build-old"), os.path.join(self.dir, ".build-fresh")
        for d in (old, fresh):
            os.makedirs(os.path.join(d, "x"))
        past = time.time() - 2 * swiftagent.STALE_BUILD
        os.utime(old, (past, past))
        with mock.patch.object(swiftagent.shutil, "which", return_value=None), \
                self.assertRaises(SystemExit):
            self.agent.build()
        self.assertFalse(os.path.exists(old))
        self.assertTrue(os.path.exists(fresh))

    def test_hook_starts_background_build_and_does_not_wait(self):
        with mock.patch.object(self.agent, "build") as build, \
                mock.patch.object(notify.shutil, "which", return_value="/usr/bin/swiftc"), \
                mock.patch.object(notify, "STATE", self.dir), \
                mock.patch.object(notify.subprocess, "Popen") as popen:
            self.assertFalse(notify.ensure_app(background=True))
        build.assert_not_called()
        args, kwargs = popen.call_args
        self.assertEqual(args[0][-1], "build-app")
        self.assertTrue(kwargs["start_new_session"])

    def test_hook_does_not_start_second_build(self):
        self.hold_lock()
        with mock.patch.object(notify, "STATE", self.dir), \
                mock.patch.object(notify.subprocess, "Popen") as popen:
            self.assertFalse(notify.ensure_app(background=True))
        popen.assert_not_called()
        with open(os.path.join(self.dir, "errors.log")) as f:
            self.assertIn("уже собирается", f.read())

    def test_hook_falls_back_to_osascript_while_building(self):
        sid = "a812d4fa-e535-463a-8369-f1433fa25652"
        data = {"session_id": sid, "hook_event_name": "Notification", "notification_type": "agent_needs_input",
                "message": "Какой вариант?", "cwd": "/work/project"}
        calls = []

        def run(args, **kwargs):
            calls.append(args)
            return mock.Mock(returncode=0, stdout="", stderr="")

        with mock.patch.object(notify, "STATE", self.dir), \
                mock.patch.object(notify, "enabled", return_value=True), \
                mock.patch.object(notify, "own_terminal", return_value="/dev/ttys001"), \
                mock.patch.object(notify, "watching", return_value=False), \
                mock.patch.object(notify, "session_title", return_value=""), \
                mock.patch.object(notify, "ensure_app", return_value=False) as ensure, \
                mock.patch.object(notify, "post") as post, \
                mock.patch.object(notify.channels.telegram, "configured", return_value=False), \
                mock.patch.object(notify.ntfy_alert, "configured", return_value=False), \
                mock.patch.object(notify.subprocess, "run", side_effect=run), \
                mock.patch.object(sys, "stdin", io.StringIO(json.dumps(data))):
            self.assertEqual(notify.hook(), 0)
            self.assertTrue(notify.load_state(sid).get("notified"))
        ensure.assert_called_once_with(background=True)
        post.assert_not_called()
        self.assertEqual(calls[0][:2], ["osascript", "-e"])
        self.assertEqual(calls[0][3:6], ["project: Нужен ответ", "", "Какой вариант?"])


class ItermSession(unittest.TestCase):
    """Сессия iTerm2 в песочнице proxy: ps не работает, tty пустой, клик ведет в сессию по ее id."""
    GUID = "1C7B5E0A-9F3D-4D7E-8A21-3E5F6B7C8D90"

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if k not in ("TERM_PROGRAM", "LC_TERMINAL", "ITERM_SESSION_ID")}
        return mock.patch.dict(os.environ, dict(env, **extra), clear=True)

    def test_session_id_comes_from_env_and_must_be_a_guid(self):
        with self.env(ITERM_SESSION_ID="w0t3p0:" + self.GUID, TERM_PROGRAM="iTerm.app"):
            self.assertEqual(notify.iterm_session(), "iterm:" + self.GUID)
        with self.env(ITERM_SESSION_ID="w0t3p0:" + self.GUID, LC_TERMINAL="iTerm2"):
            self.assertEqual(notify.iterm_session(), "iterm:" + self.GUID)
        with self.env(ITERM_SESSION_ID="w0t3p0:../etc", TERM_PROGRAM="iTerm.app"):
            self.assertEqual(notify.iterm_session(), "")
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(notify.iterm_session(), "")

    def test_session_id_is_ignored_outside_iterm(self):
        # ITERM_SESSION_ID унаследован программой, которую запустили из iTerm2 в другом терминале
        with self.env(ITERM_SESSION_ID="w0t3p0:" + self.GUID, TERM_PROGRAM="Apple_Terminal"):
            self.assertEqual(notify.iterm_session(), "")
        with self.env(ITERM_SESSION_ID="w0t3p0:" + self.GUID):
            self.assertEqual(notify.iterm_session(), "")

    def hook_patches(self, tmp, interactive):
        return [mock.patch.object(notify, "STATE", tmp),
                mock.patch.object(notify, "app_tab", return_value=""),
                mock.patch.object(notify, "enabled", return_value=True),
                mock.patch.object(notify, "own_terminal", return_value=None),
                mock.patch.object(claude_proc, "interactive_session", return_value=interactive),
                mock.patch.object(notify, "session_title", return_value=""),
                mock.patch.object(notify, "ensure_app", return_value=True),
                mock.patch.object(notify, "cm_path", return_value="/bin/agentmeister"),
                mock.patch.object(notify.telegram, "configured", return_value=False),
                mock.patch.object(notify.ntfy_alert, "configured", return_value=False)]

    def test_headless_run_in_an_iterm_tab_does_not_notify(self):
        # claude -p из вкладки iTerm2 в песочнице: tty нет, ITERM_SESSION_ID есть, но сессия не интерактивная
        data = {"session_id": "a812d4fa-e535-463a-8369-f1433fa25652", "hook_event_name": "Notification",
                "notification_type": "agent_needs_input", "message": "Какой вариант?", "cwd": "/work/project"}
        with tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack, \
                self.env(ITERM_SESSION_ID="w0t3p0:" + self.GUID, TERM_PROGRAM="iTerm.app"):
            for p in self.hook_patches(tmp, interactive=False):
                stack.enter_context(p)
            post = stack.enter_context(mock.patch.object(notify, "post", return_value="ok"))
            stack.enter_context(mock.patch.object(sys, "stdin", io.StringIO(json.dumps(data))))
            self.assertEqual(notify.hook(), 0)
        post.assert_not_called()

    def test_codex_exec_in_an_iterm_tab_does_not_notify(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack, \
                self.env(ITERM_SESSION_ID="w0t3p0:" + self.GUID, TERM_PROGRAM="iTerm.app"):
            for p in self.hook_patches(tmp, interactive=True):
                stack.enter_context(p)
            stack.enter_context(mock.patch.object(notify, "codex_terminal", return_value=None))
            post = stack.enter_context(mock.patch.object(notify, "post", return_value="ok"))
            path = os.path.join(tmp, "rollout.jsonl")
            with open(path, "w") as f:
                json.dump({"type": "session_meta", "payload": {"originator": "codex_exec", "source": "exec"}}, f)
            data = {"session_id": "a812d4fa-e535-463a-8369-f1433fa25652", "cwd": "/project",
                    "transcript_path": path, "hook_event_name": "PermissionRequest", "tool_name": "Bash"}
            stack.enter_context(mock.patch.object(sys, "stdin", io.StringIO(json.dumps(data))))
            self.assertEqual(notify.hook(codex=True), 0)
        post.assert_not_called()

    def test_hook_without_tty_clicks_into_the_iterm_session(self):
        sid = "a812d4fa-e535-463a-8369-f1433fa25652"
        data = {"session_id": sid, "hook_event_name": "Notification", "notification_type": "agent_needs_input",
                "message": "Какой вариант?", "cwd": "/work/project"}
        env = {"ITERM_SESSION_ID": "w0t3p0:" + self.GUID, "__CFBundleIdentifier": "com.googlecode.iterm2",
               "TERM_PROGRAM": "iTerm.app"}
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(notify, "STATE", tmp), \
                self.env(**env), \
                mock.patch.object(notify, "app_tab", return_value=""), \
                mock.patch.object(notify, "enabled", return_value=True), \
                mock.patch.object(notify, "own_terminal", return_value=None), \
                mock.patch.object(claude_proc, "interactive_session", return_value=True), \
                mock.patch.object(notify, "watching", return_value=False) as watching, \
                mock.patch.object(notify, "session_title", return_value=""), \
                mock.patch.object(notify, "ensure_app", return_value=True), \
                mock.patch.object(notify, "cm_path", return_value="/bin/agentmeister"), \
                mock.patch.object(notify.channels.telegram, "configured", return_value=False), \
                mock.patch.object(notify.ntfy_alert, "configured", return_value=False), \
                mock.patch.object(notify, "post", return_value="ok") as post, \
                mock.patch.object(sys, "stdin", io.StringIO(json.dumps(data))):
            self.assertEqual(notify.hook(), 0)
        watching.assert_called_once_with("com.googlecode.iterm2", "iterm:" + self.GUID)
        self.assertEqual(post.call_args.args[-1], f"/bin/agentmeister focus iterm:{self.GUID} com.googlecode.iterm2")

    def test_focus_selects_the_session_by_id_and_falls_back_to_the_app(self):
        with mock.patch.object(notify, "osascript", return_value="ok") as osa, \
                mock.patch.object(notify.subprocess, "run") as run:
            self.assertEqual(notify.focus("iterm:" + self.GUID, "com.googlecode.iterm2"), 0)
        self.assertEqual(osa.call_args.args[1:], (self.GUID,))
        self.assertIn("id of s is", osa.call_args.args[0])
        run.assert_not_called()
        with mock.patch.object(notify, "osascript", return_value="notfound"), \
                mock.patch.object(notify.subprocess, "run") as run:
            notify.focus("iterm:" + self.GUID, "com.googlecode.iterm2")
        self.assertEqual(run.call_args.args[0], ["open", "-b", "com.googlecode.iterm2"])
        with mock.patch.object(notify, "osascript") as osa, mock.patch.object(notify.subprocess, "run"):
            notify.focus("iterm:nope\" & do shell script", "com.googlecode.iterm2")
        osa.assert_not_called()

    def test_osascript_that_cannot_start_counts_as_not_watching(self):
        # в песочнице exec osascript может быть запрещен: тогда показываем уведомление, а не падаем
        with mock.patch.object(notify.subprocess, "run", side_effect=PermissionError("denied")):
            self.assertEqual(notify.osascript(notify.SELECTED_ITERM_ID), "")
        with mock.patch.object(notify, "front_bundle", return_value="com.googlecode.iterm2"), \
                mock.patch.object(notify.subprocess, "run", side_effect=PermissionError("denied")):
            self.assertFalse(notify.watching("com.googlecode.iterm2", "iterm:" + self.GUID))

    def test_watching_compares_the_current_session_id(self):
        with mock.patch.object(notify, "front_bundle", return_value="com.googlecode.iterm2"), \
                mock.patch.object(notify, "osascript", return_value=self.GUID.lower()):
            self.assertTrue(notify.watching("com.googlecode.iterm2", "iterm:" + self.GUID))
        with mock.patch.object(notify, "front_bundle", return_value="com.googlecode.iterm2"), \
                mock.patch.object(notify, "osascript", return_value="0F0F0F0F-0000-0000-0000-000000000000"):
            self.assertFalse(notify.watching("com.googlecode.iterm2", "iterm:" + self.GUID))


class CodexNotify(unittest.TestCase):
    def setUp(self):
        pin_lang(self, "ru")  # тесты сверяют русский текст уведомления

    def test_codex_cli_can_notify_when_daemon_has_no_terminal(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(notify, "STATE", tmp), \
                mock.patch.object(notify, "enabled", return_value=True), \
                mock.patch.object(notify, "after", return_value=0), \
                mock.patch.object(notify, "codex_terminal", return_value=None), \
                mock.patch.object(notify, "iterm_session", return_value=""), \
                mock.patch.object(notify, "ensure_app", return_value=True), \
                mock.patch.object(notify.telegram, "configured", return_value=True), \
                mock.patch.object(notify.telegram, "mode", return_value="always"), \
                mock.patch.object(notify.telegram, "send") as send, \
                mock.patch.object(notify.ntfy_alert, "configured", return_value=False), \
                mock.patch.object(notify, "post", return_value="ok") as post:
            path = os.path.join(tmp, "rollout.jsonl")
            with open(path, "w") as f:
                json.dump({"type": "session_meta", "payload": {"originator": "codex-tui"}}, f)
            payload = {"session_id": "a812d4fa-e535-463a-8369-f1433fa25652", "cwd": "/project",
                       "transcript_path": path}
            for event, extra in (("UserPromptSubmit", {}), ("PermissionRequest", {"tool_name": "Bash"}),
                                 ("Stop", {"last_assistant_message": "Проверки прошли."})):
                data = dict(payload, hook_event_name=event, **extra)
                with mock.patch.object(notify.sys, "stdin", io.StringIO(json.dumps(data))):
                    self.assertEqual(notify.hook(codex=True), 0)
            approval, done = [call.args for call in post.call_args_list]
            self.assertEqual(approval[:3], ("project: Нужно разрешение", "", "Bash"))
            self.assertIn("Готово", done[0])
            self.assertEqual(done[2], "Проверки прошли.")
            self.assertIsNone(done[-1])
            telegram_approval, telegram_done = [call.args for call in send.call_args_list]
            self.assertEqual(telegram_approval, ("Codex: Нужно разрешение", "project", "Bash"))
            self.assertEqual(telegram_done, (done[0].replace("project:", "Codex:"), "project", done[2]))


if __name__ == "__main__":
    unittest.main()
