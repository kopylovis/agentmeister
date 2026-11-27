import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(ROOT, "libexec", "agentmeister", "lib"))
import mnrhlib  # noqa: E402
import session_defaults as d  # noqa: E402


class SessionDefaults(unittest.TestCase):
    def setUp(self):
        self.conf = os.path.join(tempfile.mkdtemp(prefix="cm-defaults-"), "config")
        self.patch = patch.object(mnrhlib, "CONFIG", self.conf)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()

    def test_defaults_without_config(self):
        self.assertEqual(d.state(), {"mode": "caffeinate", "remoteControl": True, "restartUpdate": True,
                                     "askModel": "sonnet"})

    def test_set_and_reset(self):
        self.assertEqual(d.main(["mode", "normal"]), 0)
        self.assertEqual(d.main(["remote-control", "off"]), 0)
        self.assertEqual(d.main(["ask-model", "opus"]), 0)
        self.assertEqual(d.state(), {"mode": "normal", "remoteControl": False, "restartUpdate": True,
                                     "askModel": "opus"})
        with open(self.conf) as f:
            self.assertIn("open_mode=normal", f.read())
        d.main(["mode", "caffeinate"])
        with open(self.conf) as f:
            self.assertNotIn("open_mode", f.read())

    def test_bad_values_are_refused_and_ignored(self):
        self.assertEqual(d.main(["mode", "sleepy"]), 2)
        self.assertEqual(d.main(["nope", "on"]), 2)
        with open(self.conf, "w") as f:
            f.write("open_remote_control=maybe\n")
        self.assertTrue(d.remote_control())

    def test_open_claude_uses_the_defaults(self):
        import claude_open
        d.main(["mode", "normal"])
        d.main(["remote-control", "off"])
        ok = subprocess.CompletedProcess([], 0, "/dev/ttys001\n", "")
        with patch.dict(os.environ, TERM_PROGRAM="Apple_Terminal", MNRH_PROXY="1234"), \
                patch.object(claude_open, "trusted", return_value=True), \
                patch.object(claude_open, "project_dirs", return_value=("/tmp", [])), \
                patch.object(claude_open.subprocess, "run", return_value=ok) as run, \
                patch.object(claude_open, "claude_on", return_value=123):
            claude_open.open_claude({"path": "/tmp/project"}, "agentmeister")
        script = " ".join(run.call_args.args[0])
        self.assertIn(" -n ", script)
        self.assertNotIn("--remote-control", script)


if __name__ == "__main__":
    unittest.main()
