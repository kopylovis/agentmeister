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
import host_run


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
        with patch.object(host_run, "send_op", return_value=125) as send:
            (text, error), cmd = self.launch("iTerm.app", denied)
        send.assert_called_once()
        self.assertTrue(error)
        self.assertIn("⌘T", text)
        self.assertIn(cmd[-2], text)

    def test_permission_failure_opens_the_tab_through_host_run(self):
        denied = subprocess.CompletedProcess([], 1, "", "A privilege violation occurred. (-10004)")
        prompt = 'первая строка\nвторая "в кавычках" и \'одинарных\''

        def send(request, out, err):
            out.write("Открыл новую вкладку iTerm2 (/dev/ttys009)\n".encode())
            return 0

        with patch.object(host_run, "send_op", side_effect=send) as sent:
            (text, error), _ = self.launch("iTerm.app", denied, remote_control=True, prompt=prompt)
        self.assertFalse(error)
        self.assertIn("/dev/ttys009", text)
        argv = sent.call_args.args[0]["argv"]
        self.assertEqual(argv[:4], ["/tmp/project", "-k", "-x", "--new"])
        self.assertEqual(argv[-3:], ["--remote-control", "project", prompt])

    def test_direct_session_does_not_use_host_run(self):
        denied = subprocess.CompletedProcess([], 1, "", "A privilege violation occurred. (-10004)")
        with patch.dict(os.environ, {}, clear=False), patch.object(host_run, "send_op") as send:
            os.environ.pop("MNRH_PROXY", None)
            args = {"path": "/tmp/project", "remote_control": False}
            with patch.dict(os.environ, TERM_PROGRAM="iTerm.app"), \
                    patch.object(claude_open, "trusted", return_value=True), \
                    patch.object(claude_open, "project_dirs", return_value=("/tmp", [])), \
                    patch.object(claude_open.subprocess, "run", return_value=denied):
                text, error = claude_open.open_claude(args, "agentmeister")
        send.assert_not_called()
        self.assertTrue(error)
        self.assertIn("⌘T", text)


class ShellLine(unittest.TestCase):
    WORDS = ["plain", "two words", "it's", 'say "hi"', "строка 1\nстрока 2", "tab\there", "back\\slash\n",
             "$HOME `date` $(id) !! *", "\x01\x7f\x85 конец", "emoji 🙂\r\nend", "\\x41'\n'", ""]

    def roundtrip(self, shell):
        line = claude_open.shell_line(self.WORDS)
        self.assertNotIn("\n", line)
        self.assertNotIn("\r", line)
        out = subprocess.run([shell, "-c", "printf '%s\\0' " + line], capture_output=True, check=True).stdout
        self.assertEqual(out.decode().split("\0")[:-1], self.WORDS)

    def test_zsh(self):
        self.roundtrip("/bin/zsh")

    def test_bash(self):
        self.roundtrip("/bin/bash")


class HostOpenCommand(unittest.TestCase):
    def test_defaults_and_flags(self):
        cmd = claude_open.host_open_command(["kcalm"])
        self.assertEqual(cmd[1:], ["open", "kcalm", "-k", "-x", "--new"])
        cmd = claude_open.host_open_command(["kcalm", "-n", "-i", "--new", "--", "--continue", "-d"])
        self.assertEqual(cmd[1:], ["open", "kcalm", "-n", "-x", "--new", "-i", "--", "--continue", "-d"])

    def test_refuses(self):
        for argv in ([], ["--", "x"], ["kcalm", "-d"], ["kcalm", "--direct"], ["kcalm", "--bogus"], ["a", "b"]):
            with self.subTest(argv=argv), self.assertRaises(ValueError):
                claude_open.host_open_command(argv)


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
