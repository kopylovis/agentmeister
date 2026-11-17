import os
import shlex
import sys
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "libexec", "agentmeister", "lib"))
from mnrhlib import hook_command, is_hook  # noqa: E402


class IsHook(unittest.TestCase):
    def test_ours(self):
        for command in ("/x/mnrh claude notice", "mnrh claude notice", "/x/claudemeister notice",
                        "claudemeister notice", "'/a b/claudemeister' notice", "'/a b/mnrh' claude notice --x",
                        "/opt/homebrew/bin/claudemeister notice", "agentmeister notice",
                        "'/a b/agentmeister' notice"):
            self.assertTrue(is_hook(command, "notice"), command)

    def test_not_ours(self):
        for command in ("/x/claudemeister notice-x", "~/bin/my-claude notice", "npx @acme/claude notice",
                        "claude notice", "/x/notclaudemeister notice", "/x/notagentmeister notice",
                        "echo claudemeister", ""):
            self.assertFalse(is_hook(command, "notice"), command)

    def test_new_hooks_use_agentmeister(self):
        executable, subcommand = shlex.split(hook_command("notice"))
        self.assertEqual(os.path.basename(executable), "agentmeister")
        self.assertEqual(subcommand, "notice")


if __name__ == "__main__":
    unittest.main()
