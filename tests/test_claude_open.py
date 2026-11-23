import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "libexec/agentmeister/lib"))
import claude_open


class OpenTerminal(unittest.TestCase):
    def launch(self, term, response, **options):
        args = {"path": "/tmp/project", "remote_control": False, **options}
        with patch.dict(os.environ, TERM_PROGRAM=term, MNRH_PROXY="1234"), \
                patch.object(claude_open, "trusted", return_value=True), \
                patch.object(claude_open, "project_dirs", return_value=("/tmp", [])), \
                patch.object(claude_open.subprocess, "run", return_value=response) as run, \
                patch.object(claude_open, "claude_on", return_value=123):
            result = claude_open.open_claude(args, "agentmeister")
        run.assert_called_once()
        return result, run.call_args.args[0]

    def test_default_placement_and_window_override(self):
        ok = subprocess.CompletedProcess([], 0, "/dev/ttys001\n", "")
        for term, options, label in (("iTerm.app", {}, "auto"), ("iTerm.app", {"placement": "window"}, "window"),
                                     ("Apple_Terminal", {}, None), ("", {"placement": "tab"}, "tab")):
            with self.subTest(term=term, options=options):
                (text, error), cmd = self.launch(term, ok, **options)
                self.assertFalse(error)
                self.assertIn("/dev/ttys001", text)
                if label:
                    self.assertEqual(cmd[-1], label)
                    self.assertIn(" -x ", cmd[-2])
                else:
                    self.assertIn('tell application "Terminal"', cmd[2])

    def test_permission_failure_returns_manual_tab_command(self):
        denied = subprocess.CompletedProcess([], 1, "", "A privilege violation occurred. (-10004)")
        (text, error), cmd = self.launch("iTerm.app", denied)
        self.assertTrue(error)
        self.assertIn("⌘T", text)
        self.assertIn(cmd[-2], text)
