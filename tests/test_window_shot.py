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

import window_shot  # noqa: E402

CYRILLIC = re.compile("[А-Яа-яЁё]")
WINDOWS = [{"id": 7, "app": "Safari", "title": "", "w": 1200, "h": 800},
           {"id": 8, "app": "Xcode", "title": "Проект", "w": 1400, "h": 900}]

RU_HELP = ("agentmeister shot                           список открытых окон\n"
           "agentmeister shot <приложение> [заголовок]  снимок переднего окна приложения в ~/.cache/agentmeister/shots\n"
           "\n"
           "Снимки уменьшаются до 1600 px по большей стороне и удаляются через 3 дня.\n"
           "Нужно разрешение «Запись экрана» для терминала. В Claude Code: /shot или инструмент window_screenshot.\n")


def run_main(*args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), patch.object(sys, "argv", ["window_shot.py", *args]):
        code = window_shot.main()
    return code, out.getvalue()


class ShotHelp(unittest.TestCase):
    def test_english_help_has_no_cyrillic(self):
        with patch("mnrhlib.lang", return_value="en"):
            code, out = run_main("-h")
        self.assertEqual(code, 0)
        self.assertIsNone(CYRILLIC.search(out), out)
        self.assertIn("Screen Recording", out)
        self.assertIn("window_screenshot", out)

    def test_russian_help_is_unchanged(self):
        with patch("mnrhlib.lang", return_value="ru"):
            self.assertEqual(run_main("--help"), (0, RU_HELP))


class ShotMessages(unittest.TestCase):
    def test_window_list_in_english_keeps_titles(self):
        with patch("mnrhlib.lang", return_value="en"), patch.object(window_shot, "windows", return_value=WINDOWS):
            result = window_shot.handle({})
        text = result["content"][0]["text"]
        self.assertFalse(result["isError"])
        self.assertTrue(text.startswith("Open windows (frontmost first):\n"), text)
        self.assertIn("Safari: (untitled)  [1200×800]", text)
        self.assertIn("Xcode: Проект", text)

    def test_window_list_in_russian(self):
        with patch("mnrhlib.lang", return_value="ru"), patch.object(window_shot, "windows", return_value=WINDOWS):
            text = window_shot.handle({})["content"][0]["text"]
        self.assertTrue(text.startswith("Открытые окна (сверху — переднее):\n"), text)
        self.assertIn("Safari: (без заголовка)", text)

    def test_no_windows_in_english(self):
        with patch("mnrhlib.lang", return_value="en"), patch.object(window_shot, "windows", return_value=[]), \
                patch.object(window_shot, "settings_path", return_value="System Settings → Privacy"):
            result = window_shot.handle({"app": "Safari"})
        self.assertTrue(result["isError"])
        self.assertEqual(result["content"][0]["text"], "I don't see any windows. The terminal running Claude needs "
                         "the Screen Recording permission: System Settings → Privacy.")

    def test_missing_window_in_english(self):
        with patch("mnrhlib.lang", return_value="en"), patch.object(window_shot, "windows", return_value=WINDOWS):
            w, err = window_shot.choose("Figma")
        self.assertIsNone(w)
        self.assertTrue(err.startswith('No window "Figma". Visible:\n'), err)
        self.assertIsNone(CYRILLIC.search(err.replace("Проект", "")), err)

    def test_failed_capture_in_english(self):
        failed = subprocess.CompletedProcess([], 1, "", "could not create image")
        with tempfile.TemporaryDirectory() as tmp, patch("mnrhlib.lang", return_value="en"), \
                patch.object(window_shot, "SHOTS", tmp), patch.object(window_shot.subprocess, "run", return_value=failed):
            path, err = window_shot.capture(WINDOWS[0])
        self.assertIsNone(path)
        self.assertEqual(err, "The screenshot failed (could not create image). The terminal running Claude needs "
                         "the Screen Recording permission.")


if __name__ == "__main__":
    unittest.main()
