import contextlib
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "libexec", "agentmeister", "lib"))
import headsup  # noqa: E402

SID = "11111111-2222-4333-8444-555555555555"
OTHER = "66666666-7777-4888-9999-000000000000"


class Base(unittest.TestCase):
    """Своя ~/.claude и своя папка состояния: настоящие файлы плагина и история не трогаются."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = tmp.name
        self.claude = os.path.join(self.tmp, "claude")
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(os.path.join(self.claude, "plugins", "store"))
        self.store = os.path.join(self.claude, "plugins", "store", "cc-plugin-you-should-know_builtin-19776595df2c.json")
        for name, value in (("CLAUDE_HOME", self.claude), ("STATE", self.state),
                            ("STORE_GLOB", os.path.join(self.claude, "plugins", "store",
                                                        "cc-plugin-you-should-know_builtin-*.json")),
                            ("HISTORY", os.path.join(self.state, "headsup.jsonl")),
                            ("MARK", os.path.join(self.state, "headsup-mark.json")),
                            ("LOCK", os.path.join(self.state, "headsup.lock"))):
            patcher = mock.patch.object(headsup, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.tick = 0

    def write_store(self, seen, sessions=()):
        data = {"sessions": list(sessions), "seen": list(seen), "typedPastInARow": 0, "looksToSkip": 0,
                "known": list(seen)}
        with open(self.store, "w") as f:
            json.dump(data, f, ensure_ascii=False)
        # mtime_ns на быстрой записи может совпасть: сдвигаем вручную, как будто прошло время
        self.tick += 1
        os.utime(self.store, ns=(10**18 + self.tick, 10**18 + self.tick))

    def history(self):
        return headsup.read_history()


class Diff(unittest.TestCase):
    def test_append_and_drop_from_front(self):
        self.assertEqual(headsup.new_items(["a", "b", "c"], ["b", "c", "d", "e"]), ["d", "e"])

    def test_no_change(self):
        self.assertEqual(headsup.new_items(["a", "b"], ["a", "b"]), [])

    def test_reshown_moves_to_end(self):
        self.assertEqual(headsup.new_items(["a", "b", "c"], ["b", "c", "a"]), ["a"])
        self.assertEqual(headsup.new_items(["a", "b", "c"], ["a", "b", "c", "a"]), ["a"])

    def test_reset_store_is_all_new(self):
        self.assertEqual(headsup.new_items(["a", "b"], ["x", "y"]), ["x", "y"])


class Capture(Base):
    def test_first_run_imports_existing_without_time(self):
        self.write_store(["old 1", "old 2"])
        self.assertEqual(headsup.capture(SID, "/p/app", now=100), 2)
        rows = self.history()
        self.assertEqual([r["headline"] for r in rows], ["old 1", "old 2"])
        self.assertTrue(all(r["ts"] is None and r["session"] is None and r["source"] == "import" for r in rows))

    def test_new_headline_gets_session_cwd_and_time(self):
        self.write_store(["old"])
        headsup.capture()
        self.write_store(["old", "new one"], sessions=[{"id": SID, "askedTurn": "t1", "offeredTurn": "t1",
                                                        "tag": "Heads up"}])
        self.assertEqual(headsup.capture(SID, "/p/app", now=200), 1)
        row = self.history()[-1]
        self.assertEqual((row["headline"], row["session"], row["cwd"], row["ts"], row["tag"], row["source"]),
                         ("new one", SID, "/p/app", 200, "Heads up", "hook"))
        self.assertEqual(headsup.entries(1)[0]["project"], "app")

    def test_unchanged_store_is_only_a_stat(self):
        self.write_store(["a"])
        headsup.capture()
        with mock.patch.object(headsup, "_load_json", wraps=headsup._load_json) as load:
            self.assertEqual(headsup.capture(SID, "/p"), 0)
        self.assertEqual([c.args[0] for c in load.call_args_list], [headsup.MARK])

    def test_same_headline_later_is_one_entry(self):
        self.write_store(["a"])
        headsup.capture()
        self.write_store(["a", "b"])
        headsup.capture(SID, "/p/one", now=10)
        self.write_store(["a", "b", "c"])
        headsup.capture(SID, "/p/one", now=20)
        self.write_store(["a", "c", "b"])  # b показали снова
        self.assertEqual(headsup.capture(OTHER, "/p/two", now=30), 1)
        rows = self.history()
        self.assertEqual([r["headline"] for r in rows], ["a", "c", "b"])
        self.assertEqual((rows[-1]["ts"], rows[-1]["cwd"], rows[-1]["times"]), (30, "/p/two", 2))

    def test_lost_mark_does_not_duplicate_or_reorder(self):
        self.write_store(["a"])
        headsup.capture()
        self.write_store(["a", "b"])
        headsup.capture(SID, "/p", now=5)
        os.remove(headsup.MARK)
        self.write_store(["a", "b", "c"])
        headsup.capture()
        rows = self.history()
        self.assertEqual([r["headline"] for r in rows], ["a", "b", "c"])
        self.assertEqual(rows[1]["ts"], 5)

    def test_plugin_marks_other_session(self):
        self.write_store(["a"], sessions=[{"id": OTHER, "askedTurn": "x", "offeredTurn": "x", "tag": "Heads up"}])
        headsup.capture()
        proj = os.path.join(self.claude, "projects", "-p-other")
        os.makedirs(proj)
        with open(os.path.join(proj, OTHER + ".jsonl"), "w") as f:
            f.write(json.dumps({"type": "user", "cwd": "/p/other", "sessionId": OTHER}) + "\n")
        self.write_store(["a", "b"], sessions=[{"id": OTHER, "askedTurn": "y", "offeredTurn": "y",
                                                "tag": "You should know"}])
        headsup.capture(SID, "/p/mine", now=1)
        row = self.history()[-1]
        self.assertEqual((row["session"], row["cwd"], row["tag"]), (OTHER, "/p/other", "You should know"))

    def test_scan_without_session(self):
        self.write_store(["a"])
        headsup.scan()
        self.write_store(["a", "b"])
        self.assertEqual(headsup.scan(), 1)
        row = self.history()[-1]
        self.assertEqual((row["session"], row["cwd"], row["source"]), (None, None, "scan"))

    def test_size_cap(self):
        self.write_store([])
        headsup.capture()
        with mock.patch.object(headsup, "MAX_ENTRIES", 5):
            seen = []
            for i in range(8):
                seen = (seen + [f"n{i}"])[-3:]
                self.write_store(seen)
                headsup.capture(SID, "/p", now=i)
        rows = self.history()
        self.assertEqual([r["headline"] for r in rows], [f"n{i}" for i in range(3, 8)])

    def test_files_are_private(self):
        self.write_store(["a"])
        headsup.capture()
        for path in (headsup.HISTORY, headsup.MARK):
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600, path)

    def snapshot(self):
        with open(self.store, "rb") as f:
            return os.stat(self.store).st_mtime_ns, f.read()

    def test_store_is_not_modified(self):
        self.write_store(["a"])
        headsup.capture()
        self.write_store(["a", "b"])
        before = self.snapshot()
        headsup.capture(SID, "/p")
        self.assertEqual(self.snapshot(), before)

    def test_no_store(self):
        self.assertEqual(headsup.capture(SID, "/p"), 0)
        self.assertFalse(os.path.exists(headsup.HISTORY))

    def test_forget_drops_session_entries(self):
        self.write_store(["a"])
        headsup.capture()
        self.write_store(["a", "b"])
        headsup.capture(SID, "/p")
        headsup.forget(SID)
        self.assertEqual([r["headline"] for r in self.history()], ["a"])


class HookNeverFails(Base):
    def test_bad_payloads(self):
        for payload in (None, [], "x", {}, {"hook_event_name": "Stop", "session_id": 5, "cwd": ["x"]},
                        {"hook_event_name": "Notification", "session_id": SID}):
            self.assertEqual(headsup.from_hook(payload), 0)

    def test_broken_store(self):
        with open(self.store, "w") as f:
            f.write("{not json")
        self.assertEqual(headsup.from_hook({"hook_event_name": "Stop", "session_id": SID, "cwd": "/p"}), 0)
        with open(self.store, "w") as f:
            json.dump({"seen": "oops", "sessions": [1, None, {"id": 3}]}, f)
        os.utime(self.store, ns=(5, 5))
        self.assertEqual(headsup.from_hook({"hook_event_name": "Stop", "session_id": SID}), 0)

    def test_unwritable_state(self):
        self.write_store(["a"])
        with open(os.path.join(self.tmp, "file"), "w"):
            pass
        with mock.patch.object(headsup, "STATE", os.path.join(self.tmp, "file", "sub")), \
                mock.patch.object(headsup, "LOCK", os.path.join(self.tmp, "file", "sub", "l")):
            self.assertEqual(headsup.from_hook({"hook_event_name": "UserPromptSubmit", "session_id": SID}), 0)

    def test_unexpected_error(self):
        with mock.patch.object(headsup, "capture", side_effect=RuntimeError("boom")):
            self.assertEqual(headsup.from_hook({"hook_event_name": "Stop", "session_id": SID}), 0)
            self.assertEqual(headsup.scan(), 0)

    def test_notify_hook_survives_headsup_failure(self):
        import notify
        payload = json.dumps({"hook_event_name": "Stop", "session_id": SID, "cwd": "/p"})
        with mock.patch.object(headsup, "capture", side_effect=RuntimeError("boom")) as cap, \
                mock.patch.object(notify, "enabled", return_value=False), \
                mock.patch.dict(os.environ, {"MNRH_CHILD": ""}), \
                mock.patch("sys.stdin", io.StringIO(payload)):
            self.assertEqual(notify.hook(), 0)
        cap.assert_called_once_with(SID, "/p")


class Light(unittest.TestCase):
    def test_hook_import_is_light(self):
        import subprocess
        code = (f"import sys; sys.path.insert(0, {os.path.dirname(headsup.__file__)!r}); import headsup; "
                "print(' '.join(sys.modules))")
        mods = set(subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True).stdout.split())
        self.assertEqual(mods & {"session_store", "claude_search", "mcp_server", "urllib.request", "http.client"}, set())


class Cli(Base):
    def test_list_newest_first(self):
        self.write_store(["a"])
        headsup.capture()
        self.write_store(["a", "b"])
        headsup.capture(SID, "/p/app", now=1_700_000_000)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), mock.patch("mnrhlib.lang", return_value="en"):
            self.assertEqual(headsup.main([]), 0)
        lines = out.getvalue().splitlines()
        self.assertIn("app", lines[0])
        self.assertEqual(lines[1].strip(), "b")
        self.assertTrue(lines[2].startswith("earlier"))

    def test_json(self):
        self.write_store(["a"])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(headsup.main(["--json"]), 0)
        self.assertEqual(json.loads(out.getvalue())[0]["headline"], "a")

    def test_bad_argument(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(headsup.main(["--bogus"]), 2)


if __name__ == "__main__":
    unittest.main()
