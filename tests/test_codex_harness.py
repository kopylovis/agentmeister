import json
import os
import shlex
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "libexec" / "agentmeister" / "lib"))
import codex_harness
import codex_sessions
import open_flow


class CodexHarness(unittest.TestCase):
    def test_restart_queues_exact_session_and_preserves_proxy(self):
        sid = "11111111-2222-4333-8444-555555555555"
        with tempfile.TemporaryDirectory() as queue, \
                patch.dict(os.environ, {"CODEX_THREAD_ID": sid, "MNRH_RESTART_HOOK": "1", "MNRH_PROXY": "1"}), \
                patch.object(codex_harness, "RESTART_QUEUE", queue), \
                patch("claude_notify.codex_terminal", return_value="/dev/ttys123"):
            self.assertEqual(codex_harness.restart("codex", ["--after-exit", "--update"]), 0)
            self.assertEqual(codex_harness.restart("codex", ["--after-exit", "--update"]), 0)
            job = shlex.split((Path(queue) / "ttys123").read_text())
        self.assertEqual(job[-6:], ["--harness", "codex", "restart", sid, "--update", "--proxy"])

    def test_restart_passes_the_saved_id_to_codex(self):
        sid = "11111111-2222-4333-8444-555555555555"
        with patch.object(codex_harness, "launch") as launch:
            codex_harness.restart("codex", [sid])
        self.assertEqual(launch.call_args.args[2], ["resume", "-C", os.getcwd(), sid])

    def test_skill_setup_keeps_a_user_owned_skill(self):
        with tempfile.TemporaryDirectory() as home, patch.object(codex_harness, "HOME", home):
            path = Path(home) / ".agents" / "skills" / "agentmeister" / "SKILL.md"
            codex_harness.configure_skill(False)
            installed = path.read_text()
            self.assertIn(codex_harness.SKILL_OWNER, installed)
            codex_harness.configure_skill(False)
            self.assertEqual(path.read_text(), installed)
            path.write_text(codex_harness.SKILL_OWNER + "\nold version")
            codex_harness.configure_skill(False)
            self.assertEqual(path.read_text(), installed)
            codex_harness.configure_skill(True)
            self.assertFalse(path.exists())

            path.write_text("My own skill")
            codex_harness.configure_skill(False)
            codex_harness.configure_skill(True)
            self.assertEqual(path.read_text(), "My own skill")

    def test_resume_command_preserves_project_and_launch_options(self):
        sid = "11111111-2222-4333-8444-555555555555"
        state = {"dir": "/project path", "sid": sid, "mode": "normal", "net": "direct"}
        command = open_flow.command(state, "codex")
        args, forwarded = codex_harness.launch_args(command[2:])
        self.assertEqual(command[:2], ["--harness", "codex"])
        self.assertEqual((args.project, args.mode, args.net), ("/project path", "normal", "direct"))
        self.assertEqual(forwarded, ["resume", "-C", "/project path", sid])

    def test_renamed_project_keeps_old_session_path_without_duplicate_menu_item(self):
        with tempfile.TemporaryDirectory() as home:
            root = Path(home).resolve()
            project, alias = root / "new", root / "old"
            project.mkdir()
            alias.symlink_to(project, target_is_directory=True)
            self.assertEqual(codex_sessions.project_paths(str(project)), [str(project), str(alias)])
            self.assertEqual(open_flow.project_dirs(str(root)), [str(project)])

    def test_picker_lists_named_local_sessions(self):
        sid = "11111111-2222-4333-8444-555555555555"
        thread = {"id": sid, "cwd": "/project", "name": "First\n\x1bSecond", "preview": "A task"}
        with patch.object(codex_sessions, "list_threads", return_value=[thread, dict(thread, cwd="/other")]):
            items, describe, _, sessions = codex_sessions.session_list("/project")
        self.assertEqual(sessions, [{"id": sid}])
        self.assertEqual(items[1][1], "First Second")
        self.assertIn("A task", describe(1, 80))

    def test_failed_query_keeps_the_native_picker_available(self):
        with patch.object(codex_sessions, "list_threads", side_effect=OSError):
            _, _, _, sessions = codex_sessions.session_list("/project")
        self.assertEqual(sessions, [{"id": "resume"}])

    def test_install_and_remove_preserve_other_hooks(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {"CODEX_HOME": home}):
            path = Path(home) / "hooks.json"
            custom = {"hooks": [{"type": "command", "command": "/usr/bin/true"}]}
            original = {"hooks": {"UserPromptSubmit": [custom]}}
            path.write_text(json.dumps(original))
            self.assertEqual(codex_harness.configured_humanize_hooks(), 0)
            codex_harness.configure_hooks(False)
            installed = path.read_text()
            codex_harness.configure_hooks(False)
            self.assertEqual(path.read_text(), installed)
            groups = json.loads(installed)["hooks"]
            self.assertEqual(groups["UserPromptSubmit"][0], custom)
            self.assertEqual(set(groups), set(codex_harness.HOOK_EVENTS + codex_harness.NOTIFY_EVENTS))
            self.assertEqual(codex_harness.configured_humanize_hooks(), len(codex_harness.HOOK_EVENTS))
            self.assertEqual(codex_harness.configured_hooks("notify-hook"), len(codex_harness.NOTIFY_EVENTS))
            codex_harness.configure_hooks(True)
            self.assertEqual(json.loads(path.read_text()), original)

    def test_labels_apply_to_existing_agentmeister_hooks(self):
        def hook(command, **metadata):
            return {"type": "command", "command": command, **metadata}

        foreign = hook("/tmp/it2 handle-agent-hook")
        legacy = hook('"/tmp/with spaces/agentmeister" guard-hook')
        custom = hook("/tmp/claudemeister humanize-hook", statusMessage="My own label")
        hooks = {"PreToolUse": [{"matcher": "Bash", "hooks": [foreign, legacy, custom]}]}
        self.assertTrue(codex_harness.label_hooks(hooks))
        self.assertEqual(legacy["statusMessage"], "Agentmeister guard")
        self.assertEqual(custom["statusMessage"], "My own label")
        self.assertNotIn("statusMessage", foreign)
        self.assertFalse(codex_harness.label_hooks(hooks))
