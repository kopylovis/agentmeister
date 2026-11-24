import os
import sys
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_sessions import in_sandbox  # noqa: E402


LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "libexec", "agentmeister", "lib")
sys.path.insert(0, LIB)
import re  # noqa: E402
import time  # noqa: E402
from unittest.mock import patch  # noqa: E402
import claude_live  # noqa: E402
import mnrhlib  # noqa: E402


class Labels(unittest.TestCase):
    def rows(self, lang):
        now = time.time() * 1000
        sessions = [{"status": "waiting", "cwd": "/w/app", "statusUpdatedAt": now - 5000},
                    {"status": "busy", "cwd": "/w/app", "name": "fix", "statusUpdatedAt": now - 120000},
                    {"status": "idle", "cwd": "/w/app", "statusUpdatedAt": now - 7200000}]
        with patch.object(mnrhlib, "lang", return_value=lang):
            return [re.sub(r"\x1b\[[0-9;]*m", "", claude_live.row(s)) for s in sessions]

    def test_rows_follow_the_language_setting(self):
        en = self.rows("en")
        self.assertTrue(en[0].startswith("waiting "), en[0])
        self.assertIn("untitled", en[0])
        self.assertTrue(en[0].rstrip().endswith(" s"), en[0])
        self.assertTrue(en[1].startswith("working "), en[1])
        self.assertTrue(en[1].rstrip().endswith("2 min"), en[1])
        self.assertTrue(en[2].startswith("idle "), en[2])
        self.assertTrue(en[2].rstrip().endswith("2 h"), en[2])
        self.assertFalse(re.search("[а-яА-Я]", "".join(en)), en)
        ru = self.rows("ru")
        self.assertTrue(ru[0].startswith("ждет тебя"), ru[0])
        self.assertIn("без названия", ru[0])
        self.assertTrue(ru[1].rstrip().endswith("2 мин"), ru[1])

    def test_unknown_status_is_shown_as_is(self):
        with patch.object(mnrhlib, "lang", return_value="en"):
            self.assertEqual(claude_live.status({"status": "odd"}), ("odd", ""))
            self.assertEqual(claude_live.status({}), ("?", ""))


class Lost(unittest.TestCase):
    def test_restore_keeps_revoked_trust(self):
        r, _ = in_sandbox("""
            import claude_live, claude_open
            from pathlib import Path
            from unittest.mock import patch
            settings = Path(claude_open.CLAUDE_JSON)
            settings.write_text('{"projects": {}}')
            with patch.object(claude_open, "open_claude") as launch:
                _, error = claude_live.reopen({"cwd": str(settings.parent), "sid": "test"})
                assert error
                launch.assert_not_called()
            assert settings.read_text() == '{"projects": {}}'
        """)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_only_dead_sessions_with_a_transcript_come_back(self):
        r, _ = in_sandbox("""
            import json, os, time, claude_live as l
            home = os.environ["HOME"]
            gone, alive, empty = ("11111111-0000-0000-0000-000000000001", "11111111-0000-0000-0000-000000000002",
                                  "11111111-0000-0000-0000-000000000003")
            proj = os.path.join(home, ".claude", "projects", "-w-app")
            reg = os.path.join(home, ".claude", "sessions")
            os.makedirs(proj); os.makedirs(reg); os.makedirs(l.OPEN)
            for sid in (gone, alive):
                open(os.path.join(proj, sid + ".jsonl"), "w").write("{}\\n")
            json.dump({"pid": os.getpid(), "sessionId": alive}, open(os.path.join(reg, f"{os.getpid()}.json"), "w"))
            for sid, pid in ((gone, 99999999), (alive, os.getpid()), (empty, 99999998)):
                l.write_json(l.record_path(sid), {"sid": sid, "cwd": "/w/app", "pid": pid, "at": time.time()})
            l.write_json(l.record_path("old"), {"sid": "old", "at": time.time() - 40 * 86400})
            print(" ".join(r["sid"][-1] for r in l.lost()))
            print(sorted(os.listdir(l.OPEN)))
        """)
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertEqual(lines[0], "1")
        self.assertNotIn("old.json", lines[1])
        self.assertNotIn("0003", lines[1])


if __name__ == "__main__":
    unittest.main()
