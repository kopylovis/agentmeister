import contextlib
import fcntl
import io
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.dont_write_bytecode = True
# Тесты не должны зависеть от терминала, в котором их запустили: во вкладке Agentmeister есть AGENTMEISTER_TAB,
# в iTerm2 ITERM_SESSION_ID, и хук принял бы их за свою вкладку. Нужные значения тесты ставят сами.
for _name in ("AGENTMEISTER_TAB", "ITERM_SESSION_ID", "TERM_PROGRAM", "LC_TERMINAL"):
    os.environ.pop(_name, None)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "libexec", "agentmeister", "lib"))
import claude_notify  # noqa: E402
import claude_proc  # noqa: E402
import claude_settings  # noqa: E402
import swiftagent  # noqa: E402


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
        with mock.patch.object(claude_notify, "after", return_value=0):
            return [claude_notify.message_for({"hook_event_name": "Stop"}, st),
                    claude_notify.message_for({"hook_event_name": "Stop"}, {"prompt_at": time.time() - 5}),
                    claude_notify.message_for({"hook_event_name": "PermissionRequest"}, st, codex=True),
                    claude_notify.message_for({"hook_event_name": "Notification", "notification_type": "permission_prompt",
                                               "message": "Claude needs your permission to use Bash"}, st),
                    claude_notify.message_for({"hook_event_name": "Notification",
                                               "notification_type": "agent_needs_input"}, st),
                    claude_notify.message_for({"hook_event_name": "Notification", "notification_type": "idle_prompt"}, st)]

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


class HelpText(unittest.TestCase):
    """agentmeister notify -h по-английски, если язык не ru, и прежний русский для ru."""

    def usage(self, lang):
        pin_lang(self, lang)
        out = io.StringIO()
        with mock.patch.object(claude_notify, "after", return_value=30), contextlib.redirect_stdout(out):
            claude_notify.usage()
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
            return claude_notify.native_push(p)

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
        with tempfile.TemporaryDirectory() as home, mock.patch.object(claude_notify, "HOME", home):
            target = os.path.join(home, "Library", "Sounds", "Agentmeister-Prompt.wav")
            source = os.path.join(os.path.dirname(claude_notify.AGENT.src), "Agentmeister-Prompt.wav")
            with open(source, "rb") as f:
                expected = f.read()
            for _ in range(2):
                claude_notify.install_sound()
                with open(target, "rb") as f:
                    self.assertEqual(f.read(), expected)
                with open(target, "wb") as f:
                    f.write(b"old sound")

    def test_helper_receives_post_arguments_and_confirms_delivery(self):
        def accept(args, **kwargs):
            self.assertEqual(args[:4], [claude_notify.AGENT.bin, "post", "--title", "tab name"])
            self.assertFalse(kwargs.get("shell"))
            with open(args[args.index("--result") + 1], "w") as receipt:
                receipt.write("ok")

        with mock.patch.object(claude_notify.subprocess, "Popen", side_effect=accept), \
                mock.patch.object(claude_notify, "sound", return_value=True):
            self.assertEqual(claude_notify.post("tab name", "", "ready", "test"), "ok")

    def test_interactive_question_without_tty(self):
        sid = "a812d4fa-e535-463a-8369-f1433fa25652"
        data = {"session_id": sid, "hook_event_name": "Notification", "notification_type": "agent_needs_input"}
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(claude_proc, "CLAUDE", tmp), \
                mock.patch.object(claude_notify, "STATE", tmp), mock.patch.object(claude_notify, "enabled", return_value=True), \
                mock.patch.object(claude_notify, "own_terminal", return_value=None), \
                mock.patch.object(claude_notify, "iterm_session", return_value=""), \
                mock.patch.object(claude_notify, "ensure_app", return_value=True), \
                mock.patch.object(claude_notify.telegram, "wanted", return_value=False), \
                mock.patch.object(claude_notify.ntfy_alert, "configured", return_value=False), \
                mock.patch.object(claude_notify, "post", side_effect=["open failed", "ok"]) as post:
            os.mkdir(os.path.join(tmp, "sessions"))
            for session, kind in [(sid, "headless"), ("another", "interactive"), (sid, "interactive"), (sid, "interactive")]:
                with open(claude_proc.session_file(123), "w") as f:
                    json.dump({"sessionId": session, "kind": kind, "entrypoint": "cli"}, f)
                with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(data))):
                    self.assertEqual(claude_notify.hook(), 0)
                if session != sid or kind != "interactive":
                    post.assert_not_called()
                self.assertEqual(bool(claude_notify.load_state(sid).get("notified")), post.call_count == 2)
            self.assertEqual(post.call_count, 2)
            self.assertIsNone(post.call_args.args[-1])


class AppTab(unittest.TestCase):
    TAB = "5f0c7a52-3b1e-4c4e-9b5a-2d9f1c0e7a11"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        for name, value in (("APP_DIR", self.tmp.name), ("APP_FRONT", os.path.join(self.tmp.name, "front.json")),
                            ("APP_FOCUS", os.path.join(self.tmp.name, "focus.json"))):
            patcher = mock.patch.object(claude_notify, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def front(self, tab, active):
        with open(claude_notify.APP_FRONT, "w") as f:
            json.dump({"tab": tab, "active": active}, f)

    def test_tab_id_comes_from_env_and_must_be_a_uuid(self):
        with mock.patch.dict(os.environ, {claude_notify.APP_TAB_ENV: self.TAB.upper()}):
            self.assertEqual(claude_notify.app_tab(), self.TAB)
        with mock.patch.dict(os.environ, {claude_notify.APP_TAB_ENV: "../etc"}):
            self.assertEqual(claude_notify.app_tab(), "")

    def test_watching_only_when_this_tab_is_front_in_an_active_window(self):
        tty = "app:" + self.TAB
        self.assertFalse(claude_notify.watching(claude_notify.APP_BUNDLE, tty))
        self.front(self.TAB, True)
        self.assertTrue(claude_notify.watching(claude_notify.APP_BUNDLE, tty))
        self.front(self.TAB, False)
        self.assertFalse(claude_notify.watching(claude_notify.APP_BUNDLE, tty))
        self.front("00000000-0000-0000-0000-000000000000", True)
        self.assertFalse(claude_notify.watching(claude_notify.APP_BUNDLE, tty))

    SID = "a812d4fa-e535-463a-8369-f1433fa25652"

    def test_click_leaves_a_focus_request_and_opens_the_url(self):
        with mock.patch.object(claude_notify.subprocess, "run", return_value=mock.Mock(returncode=0)) as run:
            self.assertEqual(claude_notify.focus("app:" + self.TAB, claude_notify.APP_BUNDLE), 0)
        with open(claude_notify.APP_FOCUS) as f:
            request = json.load(f)
        self.assertEqual(request["tab"], self.TAB)
        self.assertNotIn("session", request)
        self.assertEqual(run.call_args.args[0], ["open", f"agentmeister://focus?tab={self.TAB}"])

    def test_click_carries_the_session_id(self):
        with mock.patch.object(claude_notify.subprocess, "run", return_value=mock.Mock(returncode=0)) as run:
            claude_notify.focus("app:" + self.TAB, claude_notify.APP_BUNDLE, self.SID)
        with open(claude_notify.APP_FOCUS) as f:
            self.assertEqual(json.load(f)["session"], self.SID)
        self.assertEqual(run.call_args_list[0].args[0],
                         ["open", f"agentmeister://focus?tab={self.TAB}&session={self.SID}"])
        self.assertEqual(run.call_count, 1)
        # кривой id сессии не попадает ни в ссылку, ни в запрос
        with mock.patch.object(claude_notify.subprocess, "run", return_value=mock.Mock(returncode=0)) as run:
            claude_notify.focus("app:" + self.TAB, claude_notify.APP_BUNDLE, "x&tab=evil")
        self.assertEqual(run.call_args.args[0], ["open", f"agentmeister://focus?tab={self.TAB}"])

    def test_click_opens_the_app_by_bundle_when_the_url_fails(self):
        with mock.patch.object(claude_notify.subprocess, "run",
                               side_effect=[mock.Mock(returncode=1), mock.Mock(returncode=0)]) as run:
            self.assertEqual(claude_notify.focus("app:" + self.TAB, claude_notify.APP_BUNDLE, self.SID), 0)
        self.assertEqual(run.call_args_list[1].args[0], ["open", "-b", claude_notify.APP_BUNDLE])
        self.assertTrue(os.path.exists(claude_notify.APP_FOCUS))

    def test_bad_tab_in_click_is_ignored(self):
        with mock.patch.object(claude_notify.subprocess, "run") as run:
            self.assertEqual(claude_notify.focus("app:nope", claude_notify.APP_BUNDLE), 1)
        run.assert_not_called()
        self.assertFalse(os.path.exists(claude_notify.APP_FOCUS))


class NotifyBuild(unittest.TestCase):
    """Сборка приложения: замок, фон из хука, уборка .build-*. swiftc и настоящий ~/Library не трогаются."""

    def setUp(self):
        pin_lang(self, "ru")  # тесты сверяют русский текст уведомления
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.agent = swiftagent.SwiftAgent("notify", "agentmeister Notify", "com.agentmeister.notify",
                                           app_dir=self.dir)
        patcher = mock.patch.object(claude_notify, "AGENT", self.agent)
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
                mock.patch.object(claude_notify.shutil, "which", return_value="/usr/bin/swiftc"), \
                mock.patch.object(claude_notify, "STATE", self.dir), \
                mock.patch.object(claude_notify.subprocess, "Popen") as popen:
            self.assertFalse(claude_notify.ensure_app(background=True))
        build.assert_not_called()
        args, kwargs = popen.call_args
        self.assertEqual(args[0][-1], "build-app")
        self.assertTrue(kwargs["start_new_session"])

    def test_hook_does_not_start_second_build(self):
        self.hold_lock()
        with mock.patch.object(claude_notify, "STATE", self.dir), \
                mock.patch.object(claude_notify.subprocess, "Popen") as popen:
            self.assertFalse(claude_notify.ensure_app(background=True))
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

        with mock.patch.object(claude_notify, "STATE", self.dir), \
                mock.patch.object(claude_notify, "enabled", return_value=True), \
                mock.patch.object(claude_notify, "own_terminal", return_value="/dev/ttys001"), \
                mock.patch.object(claude_notify, "watching", return_value=False), \
                mock.patch.object(claude_notify, "session_title", return_value=""), \
                mock.patch.object(claude_notify, "ensure_app", return_value=False) as ensure, \
                mock.patch.object(claude_notify, "post") as post, \
                mock.patch.object(claude_notify.telegram, "wanted", return_value=False), \
                mock.patch.object(claude_notify.ntfy_alert, "configured", return_value=False), \
                mock.patch.object(claude_notify.subprocess, "run", side_effect=run), \
                mock.patch.object(sys, "stdin", io.StringIO(json.dumps(data))):
            self.assertEqual(claude_notify.hook(), 0)
            self.assertTrue(claude_notify.load_state(sid).get("notified"))
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
            self.assertEqual(claude_notify.iterm_session(), "iterm:" + self.GUID)
        with self.env(ITERM_SESSION_ID="w0t3p0:" + self.GUID, LC_TERMINAL="iTerm2"):
            self.assertEqual(claude_notify.iterm_session(), "iterm:" + self.GUID)
        with self.env(ITERM_SESSION_ID="w0t3p0:../etc", TERM_PROGRAM="iTerm.app"):
            self.assertEqual(claude_notify.iterm_session(), "")
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(claude_notify.iterm_session(), "")

    def test_session_id_is_ignored_outside_iterm(self):
        # ITERM_SESSION_ID унаследован программой, которую запустили из iTerm2 в другом терминале
        with self.env(ITERM_SESSION_ID="w0t3p0:" + self.GUID, TERM_PROGRAM="Apple_Terminal"):
            self.assertEqual(claude_notify.iterm_session(), "")
        with self.env(ITERM_SESSION_ID="w0t3p0:" + self.GUID):
            self.assertEqual(claude_notify.iterm_session(), "")

    def hook_patches(self, tmp, interactive):
        return [mock.patch.object(claude_notify, "STATE", tmp),
                mock.patch.object(claude_notify, "app_tab", return_value=""),
                mock.patch.object(claude_notify, "enabled", return_value=True),
                mock.patch.object(claude_notify, "own_terminal", return_value=None),
                mock.patch.object(claude_proc, "interactive_session", return_value=interactive),
                mock.patch.object(claude_notify, "session_title", return_value=""),
                mock.patch.object(claude_notify, "ensure_app", return_value=True),
                mock.patch.object(claude_notify, "cm_path", return_value="/bin/agentmeister"),
                mock.patch.object(claude_notify.telegram, "wanted", return_value=False),
                mock.patch.object(claude_notify.ntfy_alert, "configured", return_value=False)]

    def test_headless_run_in_an_iterm_tab_does_not_notify(self):
        # claude -p из вкладки iTerm2 в песочнице: tty нет, ITERM_SESSION_ID есть, но сессия не интерактивная
        data = {"session_id": "a812d4fa-e535-463a-8369-f1433fa25652", "hook_event_name": "Notification",
                "notification_type": "agent_needs_input", "message": "Какой вариант?", "cwd": "/work/project"}
        with tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack, \
                self.env(ITERM_SESSION_ID="w0t3p0:" + self.GUID, TERM_PROGRAM="iTerm.app"):
            for p in self.hook_patches(tmp, interactive=False):
                stack.enter_context(p)
            post = stack.enter_context(mock.patch.object(claude_notify, "post", return_value="ok"))
            stack.enter_context(mock.patch.object(sys, "stdin", io.StringIO(json.dumps(data))))
            self.assertEqual(claude_notify.hook(), 0)
        post.assert_not_called()

    def test_codex_exec_in_an_iterm_tab_does_not_notify(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack, \
                self.env(ITERM_SESSION_ID="w0t3p0:" + self.GUID, TERM_PROGRAM="iTerm.app"):
            for p in self.hook_patches(tmp, interactive=True):
                stack.enter_context(p)
            stack.enter_context(mock.patch.object(claude_notify, "codex_terminal", return_value=None))
            post = stack.enter_context(mock.patch.object(claude_notify, "post", return_value="ok"))
            path = os.path.join(tmp, "rollout.jsonl")
            with open(path, "w") as f:
                json.dump({"type": "session_meta", "payload": {"originator": "codex_exec", "source": "exec"}}, f)
            data = {"session_id": "a812d4fa-e535-463a-8369-f1433fa25652", "cwd": "/project",
                    "transcript_path": path, "hook_event_name": "PermissionRequest", "tool_name": "Bash"}
            stack.enter_context(mock.patch.object(sys, "stdin", io.StringIO(json.dumps(data))))
            self.assertEqual(claude_notify.hook(codex=True), 0)
        post.assert_not_called()

    def test_hook_without_tty_clicks_into_the_iterm_session(self):
        sid = "a812d4fa-e535-463a-8369-f1433fa25652"
        data = {"session_id": sid, "hook_event_name": "Notification", "notification_type": "agent_needs_input",
                "message": "Какой вариант?", "cwd": "/work/project"}
        env = {"ITERM_SESSION_ID": "w0t3p0:" + self.GUID, "__CFBundleIdentifier": "com.googlecode.iterm2",
               "TERM_PROGRAM": "iTerm.app"}
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(claude_notify, "STATE", tmp), \
                self.env(**env), \
                mock.patch.object(claude_notify, "app_tab", return_value=""), \
                mock.patch.object(claude_notify, "enabled", return_value=True), \
                mock.patch.object(claude_notify, "own_terminal", return_value=None), \
                mock.patch.object(claude_proc, "interactive_session", return_value=True), \
                mock.patch.object(claude_notify, "watching", return_value=False) as watching, \
                mock.patch.object(claude_notify, "session_title", return_value=""), \
                mock.patch.object(claude_notify, "ensure_app", return_value=True), \
                mock.patch.object(claude_notify, "cm_path", return_value="/bin/agentmeister"), \
                mock.patch.object(claude_notify.telegram, "wanted", return_value=False), \
                mock.patch.object(claude_notify.ntfy_alert, "configured", return_value=False), \
                mock.patch.object(claude_notify, "post", return_value="ok") as post, \
                mock.patch.object(sys, "stdin", io.StringIO(json.dumps(data))):
            self.assertEqual(claude_notify.hook(), 0)
        watching.assert_called_once_with("com.googlecode.iterm2", "iterm:" + self.GUID)
        self.assertEqual(post.call_args.args[-1], f"/bin/agentmeister focus iterm:{self.GUID} com.googlecode.iterm2")

    def test_focus_selects_the_session_by_id_and_falls_back_to_the_app(self):
        with mock.patch.object(claude_notify, "osascript", return_value="ok") as osa, \
                mock.patch.object(claude_notify.subprocess, "run") as run:
            self.assertEqual(claude_notify.focus("iterm:" + self.GUID, "com.googlecode.iterm2"), 0)
        self.assertEqual(osa.call_args.args[1:], (self.GUID,))
        self.assertIn("id of s is", osa.call_args.args[0])
        run.assert_not_called()
        with mock.patch.object(claude_notify, "osascript", return_value="notfound"), \
                mock.patch.object(claude_notify.subprocess, "run") as run:
            claude_notify.focus("iterm:" + self.GUID, "com.googlecode.iterm2")
        self.assertEqual(run.call_args.args[0], ["open", "-b", "com.googlecode.iterm2"])
        with mock.patch.object(claude_notify, "osascript") as osa, mock.patch.object(claude_notify.subprocess, "run"):
            claude_notify.focus("iterm:nope\" & do shell script", "com.googlecode.iterm2")
        osa.assert_not_called()

    def test_osascript_that_cannot_start_counts_as_not_watching(self):
        # в песочнице exec osascript может быть запрещен: тогда показываем уведомление, а не падаем
        with mock.patch.object(claude_notify.subprocess, "run", side_effect=PermissionError("denied")):
            self.assertEqual(claude_notify.osascript(claude_notify.SELECTED_ITERM_ID), "")
        with mock.patch.object(claude_notify, "front_bundle", return_value="com.googlecode.iterm2"), \
                mock.patch.object(claude_notify.subprocess, "run", side_effect=PermissionError("denied")):
            self.assertFalse(claude_notify.watching("com.googlecode.iterm2", "iterm:" + self.GUID))

    def test_watching_compares_the_current_session_id(self):
        with mock.patch.object(claude_notify, "front_bundle", return_value="com.googlecode.iterm2"), \
                mock.patch.object(claude_notify, "osascript", return_value=self.GUID.lower()):
            self.assertTrue(claude_notify.watching("com.googlecode.iterm2", "iterm:" + self.GUID))
        with mock.patch.object(claude_notify, "front_bundle", return_value="com.googlecode.iterm2"), \
                mock.patch.object(claude_notify, "osascript", return_value="0F0F0F0F-0000-0000-0000-000000000000"):
            self.assertFalse(claude_notify.watching("com.googlecode.iterm2", "iterm:" + self.GUID))


class CodexNotify(unittest.TestCase):
    def setUp(self):
        pin_lang(self, "ru")  # тесты сверяют русский текст уведомления

    def test_codex_cli_can_notify_when_daemon_has_no_terminal(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(claude_notify, "STATE", tmp), \
                mock.patch.object(claude_notify, "enabled", return_value=True), \
                mock.patch.object(claude_notify, "after", return_value=0), \
                mock.patch.object(claude_notify, "codex_terminal", return_value=None), \
                mock.patch.object(claude_notify, "iterm_session", return_value=""), \
                mock.patch.object(claude_notify, "ensure_app", return_value=True), \
                mock.patch.object(claude_notify.telegram, "wanted", return_value=False), \
                mock.patch.object(claude_notify.ntfy_alert, "configured", return_value=False), \
                mock.patch.object(claude_notify, "post", return_value="ok") as post:
            path = os.path.join(tmp, "rollout.jsonl")
            with open(path, "w") as f:
                json.dump({"type": "session_meta", "payload": {"originator": "codex-tui"}}, f)
            payload = {"session_id": "a812d4fa-e535-463a-8369-f1433fa25652", "cwd": "/project",
                       "transcript_path": path}
            for event, extra in (("UserPromptSubmit", {}), ("PermissionRequest", {"tool_name": "Bash"}),
                                 ("Stop", {"last_assistant_message": "Проверки прошли."})):
                data = dict(payload, hook_event_name=event, **extra)
                with mock.patch.object(claude_notify.sys, "stdin", io.StringIO(json.dumps(data))):
                    self.assertEqual(claude_notify.hook(codex=True), 0)
            approval, done = [call.args for call in post.call_args_list]
            self.assertEqual(approval[:3], ("project: Нужно разрешение", "", "Bash"))
            self.assertIn("Готово", done[0])
            self.assertEqual(done[2], "Проверки прошли.")
            self.assertIsNone(done[-1])


if __name__ == "__main__":
    unittest.main()
