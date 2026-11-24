import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "libexec", "agentmeister", "lib")
sys.path.insert(0, LIB)
import app_state  # noqa: E402


class AppState(unittest.TestCase):
    def test_broken_part_keeps_the_rest(self):
        with patch.object(app_state, "projects", return_value=[{"name": "kcalm", "path": "/w/kcalm"}]), \
             patch.object(app_state, "sessions", side_effect=RuntimeError("boom")), \
             patch.object(app_state, "live", return_value=[]), \
             patch.object(app_state, "proxy", return_value={"configured": False}), \
             patch.object(app_state, "modes", return_value={"humanize": True}):
            state = app_state.collect()
        self.assertEqual(state["projects"], [{"name": "kcalm", "path": "/w/kcalm"}])
        self.assertEqual(state["sessions"], [])
        self.assertIn("boom", state["errors"]["sessions"])
        self.assertEqual(state["modes"], {"humanize": True})
        self.assertNotIn("projects", state["errors"])

    def test_sessions_skip_unanswered_and_links(self):
        rows = [{"id": "a", "cwd": "/w/a", "title": "one", "branch": "main", "mtime": 2, "size": 10,
                 "running": None, "answered": True, "link": False},
                {"id": "b", "cwd": "/w/b", "title": "", "branch": None, "mtime": 1, "size": 1,
                 "running": None, "answered": False, "link": False},
                {"id": "c", "cwd": "/w/c", "title": "moved", "branch": None, "mtime": 1, "size": 0,
                 "running": None, "answered": True, "link": True}]
        import session_store
        with patch.object(session_store, "load", return_value=rows):
            out = app_state.sessions()
        self.assertEqual([s["id"] for s in out], ["a"])
        self.assertEqual(out[0]["running"], False)

    def test_command_prints_json(self):
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=os.path.join(home, ".config"),
                       MNRH_PROJECTS=os.path.join(home, "Developer"))
            os.makedirs(os.path.join(home, "Developer", "kcalm"))
            out = subprocess.run([os.path.join(ROOT, "bin", "agentmeister"), "app-state"], capture_output=True,
                                 text=True, env=env, timeout=60, stdin=subprocess.DEVNULL)
        self.assertEqual(out.returncode, 0, out.stderr)
        state = json.loads(out.stdout)
        self.assertEqual([p["name"] for p in state["projects"]], ["kcalm"])
        for key in ("version", "lang", "sessions", "live", "proxy", "modes", "errors"):
            self.assertIn(key, state)


if __name__ == "__main__":
    unittest.main()
