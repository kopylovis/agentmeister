import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "libexec" / "claudemeister" / "lib"))
import codex_harness
import open_flow


class CodexHarness(unittest.TestCase):
    def test_resume_command_preserves_project_and_launch_options(self):
        state = {"dir": "/project path", "sid": "resume", "mode": "normal", "net": "direct"}
        command = open_flow.command(state, "codex")
        args, forwarded = codex_harness.launch_args(command[2:])
        self.assertEqual(command[:2], ["--harness", "codex"])
        self.assertEqual((args.project, args.mode, args.net), ("/project path", "normal", "direct"))
        self.assertEqual(forwarded, ["resume"])

    def test_install_and_remove_preserve_other_hooks(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {"CODEX_HOME": home}):
            path = Path(home) / "hooks.json"
            custom = {"hooks": [{"type": "command", "command": "/usr/bin/true"}]}
            original = {"hooks": {"UserPromptSubmit": [custom]}}
            path.write_text(json.dumps(original))
            codex_harness.configure_hooks(False)
            installed = path.read_text()
            codex_harness.configure_hooks(False)
            self.assertEqual(path.read_text(), installed)
            groups = json.loads(installed)["hooks"]
            self.assertEqual(groups["UserPromptSubmit"][0], custom)
            self.assertEqual(set(groups), set(codex_harness.HOOK_EVENTS))
            codex_harness.configure_hooks(True)
            self.assertEqual(json.loads(path.read_text()), original)
