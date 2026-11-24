import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
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


class Trust(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cm-trust-test-")
        self.path = os.path.join(self.tmp, ".claude.json")
        self.write({"numStartups": 3, "projects": {"/a": {"allowedTools": ["x"]}}})
        os.chmod(self.path, 0o600)
        self.patch = patch.object(claude_open, "CLAUDE_JSON", self.path)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        shutil.rmtree(self.tmp, True)

    def write(self, data):
        with open(self.path, "w") as f:
            json.dump(data, f)

    def read(self):
        with open(self.path) as f:
            return json.load(f)

    def test_marks_folder_and_keeps_the_rest(self):
        claude_open.trust("/a")
        claude_open.trust("/b")
        data = self.read()
        self.assertEqual(data["numStartups"], 3)
        self.assertEqual(data["projects"]["/a"], {"allowedTools": ["x"], "hasTrustDialogAccepted": True})
        self.assertTrue(data["projects"]["/b"]["hasTrustDialogAccepted"])
        self.assertTrue(claude_open.trusted("/b/sub"))
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        self.assertEqual(os.listdir(self.tmp), [".claude.json"])

    def test_concurrent_write_is_not_lost(self):
        real_load = json.load
        calls = []

        def load(f):
            data = real_load(f)
            if not calls:
                # другой Claude Code переписал файл, пока мы готовили свою запись
                self.write({"numStartups": 4, "projects": {"/a": {}}, "newKey": "from claude"})
            calls.append(1)
            return data

        with patch.object(claude_open.json, "load", side_effect=load):
            claude_open.trust("/b")
        data = self.read()
        self.assertEqual(len(calls), 2)
        self.assertEqual(data["newKey"], "from claude")
        self.assertEqual(data["numStartups"], 4)
        self.assertTrue(data["projects"]["/b"]["hasTrustDialogAccepted"])
        self.assertEqual(os.listdir(self.tmp), [".claude.json"])

    def test_gives_up_when_file_keeps_changing(self):
        real_load = json.load
        n = []

        def load(f):
            data = real_load(f)
            n.append(1)
            self.write({"projects": {}, "n": len(n) * "x"})
            return data

        with patch.object(claude_open.json, "load", side_effect=load), \
                patch.object(claude_open.time, "sleep"):
            with self.assertRaises(OSError):
                claude_open.trust("/b", attempts=3)
        self.assertEqual(len(n), 3)
        self.assertNotIn("/b", self.read()["projects"])
        self.assertEqual(os.listdir(self.tmp), [".claude.json"])
