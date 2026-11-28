import contextlib
import io
import os
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "libexec", "agentmeister", "lib"))

import release_notes  # noqa: E402

CYRILLIC = re.compile("[А-Яа-яЁё]")


def git(root, *args):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com", GIT_CONFIG_GLOBAL=os.devnull)
    subprocess.run(["git", "-C", root, *args], check=True, capture_output=True, env=env)


class ReleaseNotesHelp(unittest.TestCase):
    def run_main(self, lang, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), patch("mnrhlib.lang", return_value=lang), \
                patch.object(sys, "argv", ["release_notes.py", *args]):
            code = release_notes.main()
        return code, out.getvalue()

    def test_english_help_has_no_cyrillic(self):
        code, out = self.run_main("en", "-h")
        self.assertEqual(code, 0)
        self.assertIsNone(CYRILLIC.search(out), out)
        self.assertIn("--since <tag|commit>", out)

    def test_russian_help(self):
        code, out = self.run_main("ru", "--help")
        self.assertEqual(code, 0)
        self.assertTrue(out.startswith("agentmeister release-notes [проект] [--since <тег|коммит>]\n"), out)


class ReleaseNotesProject(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = os.path.join(tmp.name, "app")
        os.mkdir(self.root)
        git(self.root, "init", "-q")
        with open(os.path.join(self.root, "a.txt"), "w") as f:
            f.write("x")
        git(self.root, "add", "a.txt")
        git(self.root, "commit", "-q", "-m", "экран: новая кнопка")
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch.object(release_notes, "find_project", return_value=(self.root, None)))
        stack.enter_context(patch.object(release_notes, "sessions_since", return_value=[]))

    def test_context_labels_in_english_keep_commit_titles(self):
        with patch("mnrhlib.lang", return_value="en"):
            text, bad = release_notes.context("app")
        self.assertFalse(bad)
        self.assertIn("Commits (newest first):", text)
        self.assertIn("экран: новая кнопка", text)
        self.assertIn("\"What's new\" limits: Google Play 500 characters", text)
        self.assertIsNone(CYRILLIC.search(text.replace("экран: новая кнопка", "")), text)

    def test_context_labels_in_russian(self):
        with patch("mnrhlib.lang", return_value="ru"):
            text, _ = release_notes.context("app")
        self.assertIn("Коммиты (новые сверху):", text)

    def test_write_errors_in_english(self):
        cases = [({}, "notes is required"),
                 ({"notes": {"../x": "t"}}, "these don't fit: ../x"),
                 ({"notes": {"en-US": "t"}, "version": "1 0"}, "doesn't look like a version number"),
                 ({"notes": {"en-US": "t"}, "version": "1.0", "version_code": "x"}, "is not a number")]
        for args, expected in cases:
            with self.subTest(args=args), patch("mnrhlib.lang", return_value="en"):
                text, bad = release_notes.write("app", args.get("version"), args.get("notes"),
                                                args.get("version_code"))
                self.assertTrue(bad)
                self.assertIn(expected, text)
                self.assertIsNone(CYRILLIC.search(text), text)

    def test_write_report_in_english(self):
        notes = {"ru-RU": "Новая кнопка. " * 40, "en-US": "A new button."}
        with patch("mnrhlib.lang", return_value="en"):
            text, bad = release_notes.write("app", "1.2.0", notes)
        self.assertFalse(bad)
        self.assertTrue(text.startswith("Wrote:\n"), text)
        self.assertIn("ru-RU: 560 characters", text)
        self.assertIn("bundle exec fastlane <lane>", text)
        self.assertIsNone(CYRILLIC.search(text), text)
        with open(os.path.join(self.root, release_notes.NOTES_DIR, "1.2.0.ru-RU.txt"), encoding="utf-8") as f:
            self.assertTrue(f.read().startswith("Новая кнопка."))


if __name__ == "__main__":
    unittest.main()
