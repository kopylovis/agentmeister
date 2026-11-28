import os
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "libexec", "agentmeister", "lib"))
import claude_lid as lid  # noqa: E402

PS = """  101     1 /bin/zsh -l
  202   101 caffeinate -is /Users/me/.local/bin/claude --resume 1234
  302   101 caffeinate -is /opt/homebrew/bin/codex --no-daemon
  303   101 caffeinate -is claude
  404   101 caffeinate -i make
  505   101 /usr/bin/python3 proxy.py run -- caffeinate -is claude
  606   101 caffeinate -is /opt/claude-tools/bin/claude-wrapper
  900     1 /Applications/Agentmeister.app/Contents/MacOS/Agentmeister
  707   900 /usr/bin/caffeinate -is -w 811
  808   101 caffeinate -is -w 811
  909   900 /usr/bin/caffeinate -i -w 812 make
"""


class Lid(unittest.TestCase):
    def setUp(self):
        self.saved = lid.run, lid.SUDOERS

    def tearDown(self):
        lid.run, lid.SUDOERS = self.saved

    def test_sessions_are_caffeinate_wrapping_claude(self):
        lid.run = lambda cmd, **kw: PS
        self.assertEqual(lid.sessions(), [202, 302, 303, 707])

    def test_install_command_uses_sudo_or_macos_password_window(self):
        lid.SUDOERS = "/etc/sudoers.d/mnrh-pmset"
        self.assertEqual(lid.install_command("/tmp/a b/rule", gui=False)[:2], ["sudo", "install"])
        cmd = lid.install_command("/tmp/a b/rule", gui=True)
        self.assertEqual(cmd[:2], ["/usr/bin/osascript", "-e"])
        self.assertIn('quoted form of "/tmp/a b/rule"', cmd[2])
        self.assertIn('quoted form of "/etc/sudoers.d/mnrh-pmset"', cmd[2])
        self.assertIn("with administrator privileges", cmd[2])

    def test_not_ready_without_rule(self):
        lid.SUDOERS = "/nonexistent-cm/sudoers.d/mnrh-pmset"
        self.assertFalse(lid.ready())
        self.assertFalse(lid.keep())
        self.assertIn("agentmeister lid setup", lid.status_lines()[0])

    def test_disabled_reads_pmset(self):
        lid.run = lambda cmd, **kw: " SleepDisabled\t\t1\n hibernatemode 3\n"
        self.assertTrue(lid.disabled())
        lid.run = lambda cmd, **kw: " hibernatemode 3\n"
        self.assertFalse(lid.disabled())

    def pidfile(self, pid):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        path = os.path.join(d.name, "lid.pid")
        with open(path, "w") as f:
            f.write(str(pid))
        patcher = mock.patch.object(lid, "PIDFILE", path)
        patcher.start()
        self.addCleanup(patcher.stop)
        return path

    def test_watcher_pid_trusts_only_our_watcher(self):
        path = self.pidfile(os.getpid())  # живой pid
        for cmd in ("/usr/bin/python3 /x/libexec/agentmeister/lib/claude_lid.py watch",
                    "/usr/bin/python3 /Users/me/mnrh-utils/libexec/mnrh/lib/lid.py watch"):
            lid.run = lambda c, _cmd=cmd, **kw: _cmd + "\n"
            self.assertEqual(lid.watcher_pid(), os.getpid())
            self.assertTrue(os.path.exists(path))

    def test_reused_pid_is_stale_and_removed(self):
        path = self.pidfile(os.getpid())
        seen = []
        lid.run = lambda c, **kw: seen.append(c) or "/Applications/Safari.app/Contents/MacOS/Safari\n"
        self.assertIsNone(lid.watcher_pid())
        self.assertEqual(seen[0][:4], ["ps", "-o", "command=", "-p"])
        self.assertFalse(os.path.exists(path))

    def test_dead_pid_is_stale_and_removed(self):
        path = self.pidfile(999999)
        lid.run = lambda c, **kw: ""
        with mock.patch.object(lid.os, "kill", side_effect=ProcessLookupError):
            self.assertIsNone(lid.watcher_pid())
        self.assertFalse(os.path.exists(path))

    def test_release_does_not_signal_foreign_process(self):
        self.pidfile(os.getpid())
        lid.run = lambda c, **kw: "/usr/sbin/cupsd -l\n"
        kills = []
        with mock.patch.object(lid.os, "kill", side_effect=lambda pid, sig: kills.append(sig)), \
                mock.patch.object(lid, "disabled", return_value=False):
            lid.release()
        self.assertNotIn(lid.signal.SIGTERM, kills)

    def test_keep_starts_watcher_over_stale_pid(self):
        path = self.pidfile(os.getpid())
        lid.run = lambda c, **kw: "/bin/zsh -l\n"
        with mock.patch.object(lid, "switched_on", return_value=True), \
                mock.patch.object(lid, "ready", return_value=True), \
                mock.patch.object(lid.subprocess, "Popen") as popen:
            self.assertTrue(lid.keep())
        popen.assert_called_once()
        self.assertFalse(os.path.exists(path))

    def test_unknown_command(self):
        self.assertEqual(lid.main(["nope"]), 2)


if __name__ == "__main__":
    unittest.main()
