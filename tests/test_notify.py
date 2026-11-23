import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "libexec", "agentmeister", "lib"))
import claude_notify  # noqa: E402
import claude_proc  # noqa: E402
import claude_settings  # noqa: E402


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


class CodexNotify(unittest.TestCase):
    def test_codex_cli_can_notify_when_daemon_has_no_terminal(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(claude_notify, "STATE", tmp), \
                mock.patch.object(claude_notify, "enabled", return_value=True), \
                mock.patch.object(claude_notify, "after", return_value=0), \
                mock.patch.object(claude_notify, "codex_terminal", return_value=None), \
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
