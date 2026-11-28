import contextlib
import io
import json
import os
import re
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "libexec", "agentmeister", "lib"))

import claude_ask  # noqa: E402

CYRILLIC = re.compile("[А-Яа-яЁё]")

RU_HELP = ("agentmeister ask <проект> <вопрос>   спросить отдельный Claude про другой проект (только чтение)\n"
           "agentmeister ask <проект> <вопрос> --model opus\n"
           "\n"
           "В Claude Code: /ask <проект> <вопрос> или инструмент ask_project.\n")


def run_main(*args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), patch.object(sys, "argv", ["claude_ask.py", *args]):
        code = claude_ask.main()
    return code, out.getvalue()


class AskHelp(unittest.TestCase):
    def test_english_help_has_no_cyrillic(self):
        with patch("mnrhlib.lang", return_value="en"):
            code, out = run_main("-h")
        self.assertEqual(code, 0)
        self.assertIsNone(CYRILLIC.search(out), out)
        self.assertIn("--model opus", out)
        self.assertIn("ask_project", out)

    def test_russian_help_is_unchanged(self):
        with patch("mnrhlib.lang", return_value="ru"):
            code, out = run_main("--help")
        self.assertEqual(code, 0)
        self.assertEqual(out, RU_HELP)



class AskMessages(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.project = os.path.join(self.tmp.name, "backend")
        os.mkdir(self.project)
        self.argv_file = os.path.join(self.tmp.name, "argv.json")

    def fake_claude(self, payload):
        path = os.path.join(self.tmp.name, "claude")
        with open(path, "w") as f:
            f.write("#!/usr/bin/python3\nimport json, sys\n"
                    f"json.dump(sys.argv[1:], open({self.argv_file!r}, 'w'))\n"
                    f"print({payload!r})\n")
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        return path

    def ask(self, payload, lang):
        patches = [patch("mnrhlib.lang", return_value=lang),
                   patch.object(claude_ask, "CLAUDE_BIN", self.fake_claude(payload)),
                   patch.object(claude_ask, "find_project", return_value=(self.project, None)),
                   patch.object(claude_ask, "default_model", return_value="sonnet")]
        with contextlib.ExitStack() as stack:
            for p in patches:
                stack.enter_context(p)
            return claude_ask.ask("backend", "какой формат у /login?")

    def test_missing_question_in_english(self):
        with patch("mnrhlib.lang", return_value="en"):
            text, bad = claude_ask.ask("backend", "  ")
        self.assertTrue(bad)
        self.assertEqual(text, "Give a project and a question.")

    def test_missing_question_in_russian(self):
        with patch("mnrhlib.lang", return_value="ru"):
            text, bad = claude_ask.ask("", "вопрос")
        self.assertEqual((text, bad), ("Нужны проект и вопрос.", True))

    def test_answer_label_in_english_keeps_answer_and_question_as_is(self):
        payload = json.dumps({"result": "Ответ: JSON с полем token", "usage": {"input_tokens": 12000}})
        text, bad = self.ask(payload, "en")
        self.assertFalse(bad)
        label, answer = text.split("\n\n", 1)
        self.assertIsNone(CYRILLIC.search(label), label)
        self.assertIn("~12k tokens", label)
        self.assertEqual(answer, "Ответ: JSON с полем token")
        with open(self.argv_file) as f:
            prompt = json.load(f)[-1]
        self.assertTrue(prompt.endswith("какой формат у /login?"), prompt)

    def test_answer_label_in_russian(self):
        text, bad = self.ask(json.dumps({"result": "ok", "usage": {"input_tokens": 3000}}), "ru")
        self.assertFalse(bad)
        self.assertTrue(text.startswith("Ответ из backend ("), text)
        self.assertIn("~3k токенов):", text)

    def test_failures_in_english(self):
        cases = {"not json": "answered with something other than JSON",
                 json.dumps({"is_error": True, "subtype": "error_max_turns"}): "failed: error_max_turns",
                 json.dumps({"result": ""}): "failed: empty answer"}
        for payload, expected in cases.items():
            with self.subTest(payload=payload):
                text, bad = self.ask(payload, "en")
                self.assertTrue(bad)
                self.assertIn(expected, text)
                self.assertIsNone(CYRILLIC.search(text), text)

    def test_claude_that_does_not_start_in_english(self):
        with patch("mnrhlib.lang", return_value="en"), \
                patch.object(claude_ask, "CLAUDE_BIN", os.path.join(self.tmp.name, "missing")), \
                patch.object(claude_ask, "find_project", return_value=(self.project, None)), \
                patch.object(claude_ask, "default_model", return_value="sonnet"):
            text, bad = claude_ask.ask("backend", "q")
        self.assertTrue(bad)
        self.assertTrue(text.startswith("claude didn't start: "), text)


if __name__ == "__main__":
    unittest.main()
