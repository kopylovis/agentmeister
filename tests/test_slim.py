import json
import os
import shutil
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "libexec", "agentmeister", "lib"))
import claude_slim as slim  # noqa: E402
import session_store  # noqa: E402


class Race(unittest.TestCase):
    def test_lines_added_after_scan_stop_the_rewrite(self):
        folder = tempfile.mkdtemp()
        src, dst = os.path.join(folder, "s.jsonl"), os.path.join(folder, "out")
        with open(src, "w") as f:
            f.write('{"type":"user"}\n{"type":"assistant"}\n')
        info = slim.scan(src)
        with open(src, "a") as f:
            f.write('{"type":"user"}\n')
        prot = {"flags": [True] * len(info)}
        with self.assertRaises(slim.SlimError):
            slim.write_slim(src, dst, info, prot)


def line(o):
    return json.dumps(o, separators=(",", ":")) + "\n"


class Undo(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.folder, True)
        self.saved = slim.BACKUPS
        slim.BACKUPS = os.path.join(self.folder, "backups")
        self.addCleanup(setattr, slim, "BACKUPS", self.saved)
        self.path = os.path.join(self.folder, "11111111-2222-3333-4444-555555555555.jsonl")
        self.sid = "11111111-2222-3333-4444-555555555555"
        cwd = "/Users/x/proj"
        lines = [{"type": "user", "uuid": "u1", "cwd": cwd, "message": {"content": "x" * 20000}},
                 {"type": "system", "subtype": "compact_boundary", "uuid": "b1", "cwd": cwd},
                 {"type": "user", "uuid": "u2", "parentUuid": "b1", "cwd": cwd, "message": {"content": "y" * 20000}},
                 {"type": "system", "subtype": "compact_boundary", "uuid": "b2", "cwd": cwd},
                 {"type": "user", "uuid": "u3", "parentUuid": "b2", "cwd": cwd, "message": {"content": "hi"}}]
        with open(self.path, "w") as f:
            f.writelines(line(o) for o in lines)
        with open(self.path, "rb") as f:
            self.original = f.read()
        stats = slim.apply(self.path, self.sid)
        self.assertTrue(stats["changed"])
        with open(self.path, "rb") as f:
            self.slimmed = f.read()

    def test_appended_lines_survive_undo(self):
        extra = line({"type": "assistant", "uuid": "a1", "cwd": "/Users/x/proj"}).encode()
        with open(self.path, "ab") as f:
            f.write(extra)
        self.assertEqual(slim.undo(self.path, self.sid), len(extra))
        with open(self.path, "rb") as f:
            self.assertEqual(f.read(), self.original + extra)
        self.assertEqual(slim.backups_of(self.sid), [])

    def test_moved_session_is_not_spliced(self):
        session_store.rewrite(self.path, self.path, {"/Users/x/proj"}, "/Users/x/a-much-longer-project-path")
        with open(self.path, "rb") as f:
            moved = f.read()
        self.assertGreater(len(moved), len(self.slimmed))
        with self.assertRaises(slim.SlimError) as e:
            slim.undo(self.path, self.sid)
        self.assertIn("переписали", str(e.exception))
        with open(self.path, "rb") as f:
            self.assertEqual(f.read(), moved)
        self.assertEqual(len(slim.backups_of(self.sid)), 1)

    def test_rewrite_in_place_is_noticed(self):
        with open(self.path, "r+b") as f:
            f.write(self.slimmed.replace(b"/Users/x/proj", b"/Users/x/prok"))
        with self.assertRaises(slim.SlimError):
            slim.undo(self.path, self.sid)

    def test_backup_without_fingerprint_is_refused(self):
        meta_path = slim.backups_of(self.sid)[-1][:-9] + ".json"
        with open(meta_path) as f:
            meta = json.load(f)
        for k in ("slim_sha256", "slim_ino", "slim_dev"):
            meta.pop(k)
        with open(meta_path, "w") as f:
            json.dump(meta, f)
        with self.assertRaises(slim.SlimError):
            slim.undo(self.path, self.sid)
        with open(self.path, "rb") as f:
            self.assertEqual(f.read(), self.slimmed)


class SideFolder(unittest.TestCase):
    """Папка рядом с сессией: файлы, о которых модель не знает, уходят в копию, остальные остаются."""

    def setUp(self):
        self.folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.folder, True)
        self.saved = slim.BACKUPS
        slim.BACKUPS = os.path.join(self.folder, "backups")
        self.addCleanup(setattr, slim, "BACKUPS", self.saved)
        self.sid = "11111111-2222-3333-4444-555555555555"
        self.path = os.path.join(self.folder, self.sid + ".jsonl")
        side = self.path[:-6]
        os.makedirs(os.path.join(side, "tool-results"))
        os.makedirs(os.path.join(side, "subagents"))
        self.old_shot = os.path.join(side, "tool-results", "old.png")
        self.new_shot = os.path.join(side, "tool-results", "new.png")
        self.old_agent = os.path.join(side, "subagents", "agent-aold1.jsonl")
        self.new_agent = os.path.join(side, "subagents", "agent-anew2.jsonl")
        for p in (self.old_shot, self.new_shot):
            with open(p, "wb") as f:
                f.write(b"\x89PNG" + b"0" * 50000)
        self.agent_text = line({"type": "user", "uuid": "s1", "message": {"content": "z" * 30000}})
        for p in (self.old_agent, self.new_agent):
            with open(p, "w") as f:
                f.write(self.agent_text)
        lines = [{"type": "user", "uuid": "u1", "message": {"content": f"{self.old_shot} agentId: aold1"}},
                 {"type": "system", "subtype": "compact_boundary", "uuid": "b1"},
                 {"type": "user", "uuid": "u2", "parentUuid": "b1", "message": {"content": "y" * 20000}},
                 {"type": "system", "subtype": "compact_boundary", "uuid": "b2"},
                 {"type": "user", "uuid": "u3", "parentUuid": "b2", "message": {"content": f"{self.new_shot} anew2"}},
                 {"type": "assistant", "uuid": "a3", "parentUuid": "u3",
                  "message": {"usage": {"input_tokens": 5, "cache_read_input_tokens": 250000}}}]
        with open(self.path, "w") as f:
            f.writelines(line(o) for o in lines)

    def test_old_files_go_and_come_back(self):
        _, _, planned = slim.plan(self.path)
        self.assertEqual((planned["side_files"], planned["side_agents"]), (1, 1))
        self.assertTrue(os.path.exists(self.old_shot))
        st = slim.apply(self.path, self.sid)
        self.assertEqual(st["side_after"], planned["side_after"])
        self.assertFalse(os.path.exists(self.old_shot))
        self.assertTrue(os.path.exists(self.new_shot))
        with open(self.new_agent) as f:
            self.assertEqual(f.read(), self.agent_text)
        with open(self.old_agent) as f:
            self.assertIn("mnrh slim", f.read())
        slim.undo(self.path, self.sid)
        self.assertTrue(os.path.exists(self.old_shot))
        with open(self.old_agent) as f:
            self.assertEqual(f.read(), self.agent_text)
        self.assertEqual(slim.side_backups_of(self.sid), [])

    def test_context_tokens(self):
        self.assertEqual(slim.context_tokens(self.path), 250005)
        with open(self.path, "a") as f:
            f.write(line({"type": "system", "subtype": "compact_boundary", "uuid": "b3",
                          "compactMetadata": {"postTokens": 21000}}))
        self.assertEqual(slim.context_tokens(self.path), 21000)


if __name__ == "__main__":
    unittest.main()
