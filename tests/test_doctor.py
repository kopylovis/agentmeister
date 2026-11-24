import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "libexec", "agentmeister", "lib"))

import claude_doctor  # noqa: E402


def hooks(*commands):
    return {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": c} for c in commands]}]}}


class Doctor(unittest.TestCase):
    def test_codex_hooks_count_only_enabled_and_trusted_handlers(self):
        base = {"command": "/test/agentmeister humanize-hook --codex", "enabled": True,
                "trustStatus": "trusted"}
        hooks = [dict(base, eventName="sessionStart"),
                 dict(base, eventName="userPromptSubmit", trustStatus="untrusted"),
                 dict(base, eventName="stop", enabled=False)]

        level, text = claude_doctor.check_codex_hooks(hooks)
        self.assertEqual(level, "bad")
        self.assertIn("1 из 3", text)

    def test_codex_mcp_does_not_start_an_unrelated_command(self):
        config = {"mcp_servers": {"agentmeister": {"command": "/usr/bin/true", "enabled": True}}}
        with patch.object(claude_doctor, "run") as run:
            self.assertEqual(claude_doctor.check_codex_mcp(config)[0], "warn")
        run.assert_not_called()

    def test_fresh_home_is_reported_broken(self):
        home = tempfile.mkdtemp(prefix="cm-doctor-")
        env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=os.path.join(home, ".config"), ZDOTDIR=home,
                   PYTHONDONTWRITEBYTECODE="1", MNRH_CLAUDE_BIN="/nonexistent/claude")
        env.pop("MNRH_CLAUDE_HOME", None)
        r = subprocess.run([os.path.join(ROOT, "bin", "agentmeister"), "doctor"], env=env, capture_output=True,
                           text=True, timeout=60)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("нет /nonexistent/claude в PATH", r.stdout)
        self.assertIn("нет команд", r.stdout)
        self.assertIn("agentmeister setup", r.stdout)
        self.assertNotIn("Traceback", r.stdout + r.stderr)


class ItermHooks(unittest.TestCase):
    def test_no_iterm_integration_says_nothing(self):
        self.assertEqual(claude_doctor.iterm_rows(hooks("claudemeister notify-hook")), [])
        self.assertEqual(claude_doctor.iterm_rows({}), [])

    def test_new_hook_is_ok(self):
        rows = claude_doctor.iterm_rows(hooks("~/.config/iterm2/it2 handle-agent-hook", "claudemeister notify-hook"))
        self.assertEqual([r[0] for r in rows], ["ok"])

    def test_old_hook_that_still_exists_warns(self):
        path = tempfile.mkdtemp(prefix="cm-iterm-")
        binary = os.path.join(path, "cc-status")
        open(binary, "w").close()
        rows = claude_doctor.iterm_rows(hooks(binary, binary))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][0], "warn")
        self.assertIn("Install Claude Code Integration", rows[0][1])

    def test_old_hook_with_missing_file_is_broken(self):
        rows = claude_doctor.iterm_rows(hooks("/nonexistent-cm/iterm2/cc-status"))
        self.assertEqual(rows[0][0], "bad")
        self.assertIn("/nonexistent-cm/iterm2/cc-status", rows[0][1])

    def test_unparsable_command_is_skipped(self):
        self.assertEqual(claude_doctor.iterm_rows(hooks("cc-status 'unclosed")), [])

    def test_crashed_check_text_follows_the_language(self):
        def check_boom():
            raise ValueError("x")

        for lang, expected in (("en", "boom: the check crashed (ValueError('x'))"),
                               ("ru", "boom: проверка упала (ValueError('x'))")):
            out = io.StringIO()
            with self.subTest(lang=lang), patch("mnrhlib.lang", return_value=lang), \
                    patch.object(claude_doctor, "CHECKS", [check_boom]), contextlib.redirect_stdout(out):
                self.assertEqual(claude_doctor.main([]), 1)
                self.assertIn(expected, out.getvalue())


if __name__ == "__main__":
    unittest.main()
