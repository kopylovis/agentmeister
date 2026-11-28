import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "libexec", "agentmeister", "lib")


def in_sandbox(code):
    """Пути считаются при импорте, поэтому каждый тест идет в своем процессе с временным HOME."""
    home = tempfile.mkdtemp(prefix="cm-test-")
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME=os.path.join(home, ".cache"), PYTHONDONTWRITEBYTECODE="1")
    env.pop("MNRH_CLAUDE_HOME", None)
    r = subprocess.run([sys.executable, "-c", f"import sys; sys.path.insert(0, {LIB!r})\n" + textwrap.dedent(code)],
                       env=env, capture_output=True, text=True)
    shutil.rmtree(home, True)
    return r, home


class Forget(unittest.TestCase):
    def test_forget_caches_removes_only_this_session(self):
        r, home = in_sandbox("""
            import os, session_store as s
            sid, other = "11111111-2222-3333-4444-555555555555", "99999999-2222-3333-4444-555555555555"
            cache = os.path.join(os.environ["HOME"], ".cache", "agentmeister")
            files = ["slim-backup/{}.20260101-000000.jsonl.gz", "notify/{}.json", "humanize/{}.hits",
                     "humanize/{}.primed", "guard/{}.json", "notice/{}.json"]
            for f in files:
                for x in (sid, other):
                    p = os.path.join(cache, f.format(x))
                    os.makedirs(os.path.dirname(p), exist_ok=True)
                    open(p, "w").close()
            s.forget_caches(sid)
            s.forget_caches("../../etc")
            left = sorted(os.path.relpath(os.path.join(d, n), cache) for d, _, ns in os.walk(cache) for n in ns)
            print("\\n".join(left))
        """)
        self.assertEqual(r.returncode, 0, r.stderr)
        left = r.stdout.split()
        self.assertEqual(len(left), 6, left)
        self.assertTrue(all("99999999" in p for p in left), left)


class History(unittest.TestCase):
    def test_lines_appended_while_forgetting_are_kept(self):
        r, _ = in_sandbox("""
            import os, session_store as s
            os.makedirs(s.CLAUDE)
            path = os.path.join(s.CLAUDE, "history.jsonl")
            sid, other = "11111111-2222-3333-4444-555555555555", "99999999-2222-3333-4444-555555555555"
            line = lambda x, n: '{"display":"%s","sessionId":"%s"}\\n' % (n, x)
            with open(path, "w") as f:
                f.write(line(other, "a") + line(sid, "b") + line(other, "c"))
            os.chmod(path, 0o600)
            def append():
                with open(path, "a") as f:
                    f.write(line(other, "late"))
            s.forget_history(sid, on_written=append)
            print(open(path).read().replace("\\n", "|"))
            print(oct(os.stat(path).st_mode & 0o777), sorted(os.listdir(s.CLAUDE)))
        """)
        self.assertEqual(r.returncode, 0, r.stderr)
        text, mode = r.stdout.splitlines()
        other = '{"display":"%s","sessionId":"99999999-2222-3333-4444-555555555555"}|'
        self.assertEqual(text, other % "a" + other % "c" + other % "late")
        self.assertEqual(mode, "0o600 ['history.jsonl']")


class Offline(unittest.TestCase):
    def test_unplugged_drive_is_not_an_orphan(self):
        r, _ = in_sandbox("""
            import session_store as s
            print(s.offline("/Volumes/NoSuchDrive-cm/proj", "-Volumes-NoSuchDrive-cm-proj"))
            print(s.offline(None, "-Volumes-NoSuchDrive-cm-proj"))
            print(s.offline("/Users/x/gone", "-Users-x-gone"))
            print(s.offline(None, "-Users-x-gone"))
        """)
        self.assertEqual(r.stdout.split(), ["True", "True", "False", "False"], r.stderr)


class Statusline(unittest.TestCase):
    def run_case(self, settings):
        code = """
            import json, os, setup_steps as c
            c.promptsill_path = lambda: "/opt/homebrew/bin/promptsill"
            os.makedirs(c.CLAUDE, exist_ok=True)
            path = os.path.join(c.CLAUDE, "settings.json")
            if SETTINGS is not None:
                json.dump(SETTINGS, open(path, "w"))
            c.promptsill_statusline()
            print(json.dumps(json.load(open(path)).get("statusLine")))
        """.replace("SETTINGS", repr(settings))
        r, _ = in_sandbox(code)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout.splitlines()[-1])

    def test_empty_settings_get_promptsill(self):
        self.assertEqual(self.run_case(None)["command"], "/opt/homebrew/bin/promptsill")
        self.assertEqual(self.run_case({"theme": "dark"})["command"], "/opt/homebrew/bin/promptsill")

    def test_stub_is_replaced_and_foreign_line_kept(self):
        stub = {"type": "command", "command": "/usr/local/bin/claudemeister statusline"}
        self.assertEqual(self.run_case({"statusLine": stub})["command"], "/opt/homebrew/bin/promptsill")
        mine = {"type": "command", "command": "~/bin/my-line.sh"}
        self.assertEqual(self.run_case({"statusLine": mine}), mine)


class Parallel(unittest.TestCase):
    def test_running_in_matches_whole_folders(self):
        r, _ = in_sandbox("""
            import json, os, claude_parallel as p
            d = os.path.join(os.environ["HOME"], ".claude", "sessions")
            os.makedirs(d)
            json.dump({"pid": os.getpid(), "cwd": "/w/app-fix-login"}, open(os.path.join(d, "1.json"), "w"))
            json.dump({"cwd": "/w/app-drop"}, open(os.path.join(d, "2.json"), "w"))
            print(p.running_in("/w/app-fix"), p.running_in("/w/app-fix-login"), p.running_in("/w/app-drop"))
        """)
        self.assertEqual(r.stdout.split(), ["False", "True", "False"], r.stderr)

    def test_prepare_makes_worktree_without_a_window(self):
        r, _ = in_sandbox("""
            import os, subprocess, claude_parallel as p
            repo = os.path.join(os.environ["HOME"], "Developer", "demo")
            os.makedirs(repo)
            run = lambda *a: subprocess.run(["git", "-C", repo, *a], check=True, capture_output=True)
            run("init", "-q", "-b", "main")
            run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
            job, err = p.prepare("Fix the login", repo, sid="abc")
            assert err is None, err
            print(job["branch"], os.path.isdir(job["path"]), job["flags"], "Fix the login" in job["prompt"])
            print(p.prepare("", repo)[1])
        """)
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertEqual(lines[0], "parallel/fix-the-login True ['--resume', 'abc', '--fork-session'] True")
        self.assertIn("Нужна задача", lines[1])


SESSIONS = """
    import json, os, re, time
    home = os.environ["HOME"]
    proj = os.path.join(home, "proj")
    os.makedirs(proj)
    pdir = os.path.join(home, ".claude", "projects", re.sub("[^A-Za-z0-9]", "-", proj))
    os.makedirs(pdir)
    ids = {"real": "11111111-2222-3333-4444-555555555555", "junk": "22222222-2222-3333-4444-555555555555",
           "other": "33333333-2222-3333-4444-555555555555"}
    def write(sid, lines):
        with open(os.path.join(pdir, sid + ".jsonl"), "w") as f:
            f.writelines(json.dumps(l, separators=(",", ":")) + "\\n" for l in lines)
    user = {"type": "user", "cwd": proj, "gitBranch": "main", "message": {"content": "fix it"}}
    write(ids["real"], [user, {"type": "assistant", "message": {"content": [{"type": "text", "text": "done"}]}},
                        {"type": "ai-title", "aiTitle": "Fixing"}])
    write(ids["other"], [user, {"type": "assistant", "message": {"content": [{"type": "text", "text": "done"}]}}])
    write(ids["junk"], [{"type": "user", "message": {"content": "<command-name>/model</command-name>"}}])
    os.makedirs(os.path.join(pdir, ids["real"], "subagents"))
    open(os.path.join(pdir, ids["real"], "subagents", "a.jsonl"), "w").write("{}\\n")
    old = time.time() - 3600
    for sid in ids.values():
        os.utime(os.path.join(pdir, sid + ".jsonl"), (old, old))
"""


def with_sessions(code):
    return in_sandbox(textwrap.dedent(SESSIONS) + textwrap.dedent(code))


class ProjectDirs(unittest.TestCase):
    def test_encode_matches_claude_code(self):
        r, _ = in_sandbox("""
            import session_store as s
            print(s.encode("/Users/x/my.proj"), s.encode("/Users/x/a😀b"))
            print(s.encode("/a/" + "b" * 250)[-8:], s.encode("/p" + "9" * 300)[-7:], len(s.encode("/" + "z" * 199)))
        """)
        self.assertEqual(r.returncode, 0, r.stderr)
        # значения посчитаны функцией из бинарника Claude Code 2.1.325
        self.assertEqual(r.stdout.split(), ["-Users-x-my-proj", "-Users-x-a--b", "b-hvza71", "-eemjkv", "200"])

    def test_long_paths_decode_move_and_survive_clean(self):
        r, _ = with_sessions("""
            import claude_sessions as c, session_store as s
            deep = os.path.join(home, *["папка-с-длинным-именем-%d" % i for i in range(8)])
            tail = os.path.join(home, "x" * 230)
            below = os.path.join(home, "y" * 120, "z" * 120, "app")
            for p in (deep, tail, below):
                os.makedirs(p)
                name = s.encode(p)
                assert len(name) > 200 and s.decode(name) == p, (p, name, s.decode(name))
            session = s.by_id(ids["real"])[0]
            c.move(session, deep)
            moved = s.by_id(ids["real"])[0]
            assert os.path.basename(moved["pdir"]) == s.encode(deep) and moved["cwd"] == deep, moved
            os.makedirs(os.path.join(moved["pdir"], "memory"))
            open(os.path.join(moved["pdir"], "memory", "MEMORY.md"), "w").write("notes")
            c.clean(True)
            assert os.path.exists(os.path.join(moved["pdir"], "memory", "MEMORY.md"))
            assert os.path.exists(moved["path"])
            print("ok")
        """)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split()[-1], "ok", r.stdout)

    def test_clean_needs_a_record_of_the_gone_path_and_keeps_memory(self):
        r, _ = with_sessions("""
            import shutil, claude_sessions as c, session_store as s
            projects = s.PROJECTS
            def project(cwd, record_cwd, memory=True):
                pdir = os.path.join(projects, s.encode(cwd))
                os.makedirs(os.path.join(pdir, "memory") if memory else pdir)
                if memory:
                    open(os.path.join(pdir, "memory", "MEMORY.md"), "w").write("notes")
                sid = "%08d-2222-3333-4444-555555555555" % len(os.listdir(projects))
                if record_cwd is not False:
                    line = {"type": "user", "message": {"content": "hi"}}
                    if record_cwd:
                        line["cwd"] = record_cwd
                    with open(os.path.join(pdir, sid + ".jsonl"), "w") as f:
                        f.write(json.dumps(line) + "\\n")
                        f.write(json.dumps({"type": "assistant", "message": {"content": "ok"}}) + "\\n")
                return pdir, sid
            gone, gone_sid = project(os.path.join(home, "gone"), os.path.join(home, "gone"))
            plain, _ = project(os.path.join(home, "gone2"), os.path.join(home, "gone2"), memory=False)
            only_memory, _ = project(os.path.join(home, "gone3"), False)
            no_cwd, no_cwd_sid = project(os.path.join(home, "gone4"), None)
            other, other_sid = project(os.path.join(home, "gone5"), os.path.join(home, "elsewhere"))
            c.clean(True)
            assert not os.path.exists(os.path.join(gone, gone_sid + ".jsonl"))
            assert os.listdir(gone) == ["memory"], os.listdir(gone)
            assert not os.path.exists(plain)
            assert os.path.exists(os.path.join(only_memory, "memory", "MEMORY.md"))
            assert os.path.exists(os.path.join(no_cwd, no_cwd_sid + ".jsonl"))
            assert os.path.exists(os.path.join(other, other_sid + ".jsonl"))
            print("ok")
        """)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split()[-1], "ok", r.stdout)


MISNAMED = """
    import json, os
    from unittest.mock import patch
    import claude_sessions as c, session_store as s
    home = os.environ["HOME"]
    A, B = "11111111-2222-3333-4444-555555555555", "22222222-2222-3333-4444-555555555555"
    def session(pdir, sid, cwd, text="hi"):
        os.makedirs(pdir, exist_ok=True)
        with open(os.path.join(pdir, sid + ".jsonl"), "w") as f:
            f.write(json.dumps({"type": "user", "cwd": cwd, "message": {"content": text}}) + "\\n")
            f.write(json.dumps({"type": "assistant", "message": {"content": "ok"}}) + "\\n")
    def put(path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").write(text)
    def tree(d):
        return {os.path.relpath(os.path.join(r, n), d): open(os.path.join(r, n)).read()
                for r, _, ns in os.walk(d) for n in ns}
    def misnamed(cwd):
        os.makedirs(cwd, exist_ok=True)
        old = os.path.join(s.PROJECTS, s.old_encode(cwd))
        new = os.path.join(s.PROJECTS, s.encode(cwd))
        assert old != new
        session(old, A, cwd)
        put(os.path.join(old, A, "subagents", "a.jsonl"), "{}\\n")
        put(os.path.join(old, "memory", "MEMORY.md"), "mine")
        return old, new
    def plan(old):
        name = os.path.basename(old)
        ss = [x for x in s.load() if x["pdir"] == old]
        return old, s.misnamed_home(name, ss), ss, c.tree_snapshot(old)
"""


def with_misnamed(code):
    return in_sandbox(textwrap.dedent(MISNAMED) + textwrap.dedent(code))


class Misnamed(unittest.TestCase):
    def test_long_path_moves_whole_folder(self):
        r, _ = with_misnamed("""
            cwd = os.path.join(home, "x" * (230 - len(home)))  # over 200, but within the 255 a file name can hold
            old, new = misnamed(cwd)
            assert len(os.path.basename(old)) > 200 and s.decode(os.path.basename(old)) == cwd
            c.clean(True)
            assert not os.path.exists(old)
            assert tree(new) == {A + ".jsonl": tree(new)[A + ".jsonl"], A + "/subagents/a.jsonl": "{}\\n",
                                 "memory/MEMORY.md": "mine"}, tree(new)
            assert s.by_id(A)[0]["pdir"] == new
            print("ok")
        """)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn("Claude Code", r.stdout)
        self.assertEqual(r.stdout.split()[-1], "ok", r.stdout)

    def test_emoji_path_and_ambiguous_folder(self):
        r, _ = with_misnamed("""
            cwd = os.path.join(home, "a😀b")
            old, new = misnamed(cwd)
            assert os.path.basename(new).endswith("-a--b") and os.path.basename(old).endswith("-a-b")
            c.clean(True)
            assert not os.path.exists(old) and os.path.isfile(os.path.join(new, A + ".jsonl"))
            # the old name is also the right name for "a-b": a folder with a session from there stays
            os.makedirs(os.path.join(home, "a-b"))
            session(old, B, os.path.join(home, "a-b"))
            session(old, A, cwd)
            before = tree(old)
            c.clean(True)
            assert tree(old) == before
            print("ok")
        """)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(r.stdout.split()[-1], "ok", r.stdout)

    def test_merges_into_existing_folder(self):
        r, _ = with_misnamed("""
            cwd = os.path.join(home, "a😀b")
            old, new = misnamed(cwd)
            session(new, B, cwd)
            put(os.path.join(new, "memory", "other.md"), "theirs")
            c.clean(True)
            assert not os.path.exists(old)
            got = tree(new)
            assert sorted(got) == sorted([A + ".jsonl", B + ".jsonl", A + "/subagents/a.jsonl", "memory/MEMORY.md",
                                          "memory/other.md"]), got
            assert got["memory/MEMORY.md"] == "mine" and got["memory/other.md"] == "theirs"
            assert {x["id"] for x in s.load() if x["pdir"] == new} == {A, B}
            print("ok")
        """)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(r.stdout.split()[-1], "ok", r.stdout)

    def test_name_clash_keeps_both(self):
        r, _ = with_misnamed("""
            cwd = os.path.join(home, "a😀b")
            old, new = misnamed(cwd)
            session(new, A, cwd, text="their copy")
            put(os.path.join(new, "memory", "MEMORY.md"), "theirs")
            put(os.path.join(new, "memory", "MEMORY.migrated.md"), "earlier")
            status, clashes = c.migrate_misnamed(*plan(old))
            assert status == "moved", status
            got = tree(new)
            assert "their copy" in got[A + ".jsonl"] and "their copy" not in got[A + ".migrated.jsonl"]
            assert got["memory/MEMORY.md"] == "theirs" and got["memory/MEMORY.migrated.md"] == "earlier"
            assert got["memory/MEMORY.migrated-2.md"] == "mine"
            assert got[A + "/subagents/a.jsonl"] == "{}\\n"
            assert sorted(clashes) == [(A + ".jsonl", A + ".migrated.jsonl"),
                                       ("memory/MEMORY.md", "memory/MEMORY.migrated-2.md")], clashes
            assert not os.path.exists(old)
            print("ok")
        """)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(r.stdout.split()[-1], "ok", r.stdout)

    def test_running_session_is_refused(self):
        r, _ = with_misnamed("""
            cwd = os.path.join(home, "a😀b")
            old, new = misnamed(cwd)
            planned = plan(old)
            registry = os.path.join(s.CLAUDE, "sessions")
            os.makedirs(registry)
            json.dump({"pid": os.getpid(), "sessionId": A}, open(os.path.join(registry, "1.json"), "w"))
            before = tree(old)
            assert c.migrate_misnamed(*planned) == ("busy", [])
            c.clean(True)
            assert tree(old) == before and not os.path.exists(new)
            print("ok")
        """)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertTrue(any(w in r.stdout for w in ("skipped", "пропускаю")), r.stdout)
        self.assertEqual(r.stdout.split()[-1], "ok", r.stdout)

    def test_failure_rolls_back(self):
        r, _ = with_misnamed("""
            cwd = os.path.join(home, "a😀b")
            old, new = misnamed(cwd)
            session(new, B, cwd)
            put(os.path.join(new, "memory", "other.md"), "theirs")
            before_old, before_new = tree(old), tree(new)
            rename = c.rename_with_flags
            def fail_memory(src, dst, flags):
                if dst.endswith("MEMORY.md"):
                    raise OSError("disk full")
                rename(src, dst, flags)
            with patch.object(c, "rename_with_flags", side_effect=fail_memory):
                try:
                    c.migrate_misnamed(*plan(old))
                except OSError:
                    pass
                else:
                    raise AssertionError("failure was swallowed")
            assert tree(old) == before_old and tree(new) == before_new, (tree(old), tree(new))
            # a folder changed after planning is left alone
            planned = plan(old)
            put(os.path.join(old, "late.txt"), "new")
            assert c.migrate_misnamed(*planned) == ("changed", [])
            assert os.path.isfile(os.path.join(old, A + ".jsonl"))
            print("ok")
        """)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(r.stdout.split()[-1], "ok", r.stdout)


class Lookup(unittest.TestCase):
    def test_by_id_matches_load(self):
        r, _ = with_sessions("""
            import session_store as s
            full = {x["id"]: x for x in s.load()}
            for sid in ids.values():
                assert s.by_id(sid) == [full[sid]], sid
                quick = s.by_id(sid, meta=False)[0]
                assert all(quick[k] == full[sid][k] for k in ("id", "pdir", "path", "extra", "link", "size", "cwd")), sid
            print(full[ids["real"]]["title"], s.by_id("nope"), s.by_id("44444444-2222-3333-4444-555555555555"))
        """)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split(), ["Fixing", "[]", "[]"])

    def test_rename_sets_the_title_like_slash_rename(self):
        r, _ = with_sessions("""
            import session_store as s, claude_sessions as cs
            target = s.by_id(ids["real"])[0]
            extra = target["extra"]
            os.makedirs(extra, exist_ok=True)
            with open(os.path.join(extra, "custom-title.json"), "w") as f:
                json.dump({"customTitle": "old"}, f)
            cs.rename(target, "  New   name ")
            print(s.by_id(ids["real"])[0]["title"])
            print(json.load(open(os.path.join(extra, "custom-title.json")))["customTitle"])
        """)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.splitlines()[-2:], ["New name", "New name"])

    def test_rename_after_a_line_without_newline(self):
        r, _ = with_sessions("""
            import session_store as s, claude_sessions as cs
            path = os.path.join(pdir, ids["real"] + ".jsonl")
            with open(path, "a") as f:
                f.write('{"type":"user","cwd":"x"')
            cs.rename(s.by_id(ids["real"])[0], "Fresh")
            print(s.by_id(ids["real"])[0]["title"])
        """)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.splitlines()[-1], "Fresh")

    def test_forget_and_drop_junk_touch_only_their_session(self):
        r, _ = with_sessions("""
            import claude_restart as cr
            print(cr.drop_junk(os.path.join(pdir, ids["real"] + ".jsonl"), "test"))
            print(cr.drop_junk(os.path.join(pdir, ids["junk"] + ".jsonl"), "test"))
            print(cr.forget_session(ids["real"]), cr.forget_session(ids["real"]))
            print(sorted(os.listdir(pdir)))
        """)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.splitlines(), ["False", "True", "True False",
                                                 "['33333333-2222-3333-4444-555555555555.jsonl']"])

    def test_cleanup_preserves_another_copy_with_the_same_id(self):
        r, _ = with_sessions("""
            import shutil, claude_restart as cr
            path = os.path.join(pdir, ids["junk"] + ".jsonl")
            copy = os.path.join(os.path.dirname(pdir), "other", os.path.basename(path))
            os.makedirs(os.path.dirname(copy))
            shutil.copyfile(os.path.join(pdir, ids["real"] + ".jsonl"), copy)
            assert cr.drop_junk(path, "test")
            assert not os.path.exists(path) and os.path.exists(copy)
        """)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_cleanup_accepts_spaced_json_and_keeps_unreadable_records(self):
        r, _ = with_sessions("""
            import session_store as s
            path = os.path.join(pdir, ids["junk"] + ".jsonl")
            for data, answered in [(json.dumps({"type": "assistant"}), True), ("{", None)]:
                with open(path, "w") as f:
                    f.write(data)
                assert not s.is_junk(path)
                assert s.read_meta(path)["answered"] is answered
        """)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_session_opened_after_selection_cannot_be_moved_or_deleted(self):
        r, _ = with_sessions("""
            import claude_sessions as c, session_store as s
            session = s.by_id(ids["real"])[0]
            registry = os.path.join(home, ".claude", "sessions")
            os.makedirs(registry)
            with open(os.path.join(registry, f"{os.getpid()}.json"), "w") as f:
                json.dump({"pid": os.getpid(), "sessionId": session["id"]}, f)
            for action in (lambda: s.delete(session), lambda: c.move(session, home)):
                try:
                    action()
                except s.SessionInUse:
                    pass
                else:
                    raise AssertionError("active transcript changed")
            assert os.path.isfile(session["path"])
        """)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_move_keeps_source_on_collision_or_publish_failure(self):
        r, _ = with_sessions("""
            from pathlib import Path
            from unittest.mock import patch
            import claude_sessions as c
            import session_store as store

            session = store.by_id(ids["real"])[0]
            dest = Path(home) / "dest"
            dest.mkdir()
            target = Path(store.PROJECTS) / store.encode(str(dest))
            target.mkdir()
            extra = target / session["id"]
            extra.write_text("keep")
            try:
                c.move(session, str(dest))
            except SystemExit:
                pass
            else:
                raise AssertionError("collision accepted")
            assert extra.read_text() == "keep"
            extra.unlink()
            rename = c.rename_with_flags
            def fail_transcript(src, dst, flags):
                if dst.endswith(".jsonl"):
                    raise OSError("publish failed")
                rename(src, dst, flags)
            with patch.object(c, "rename_with_flags", side_effect=fail_transcript):
                try:
                    c.move(session, str(dest))
                except OSError:
                    pass
            assert not list(target.iterdir())
            assert Path(session["path"]).exists()
            assert (Path(session["extra"]) / "subagents" / "a.jsonl").exists()
            c.move(session, str(dest))
            assert not Path(session["path"]).exists()
            assert not Path(session["extra"]).exists()
            assert store.by_id(ids["real"])[0]["started_in"] == str(dest)
            assert (extra / "subagents" / "a.jsonl").exists()
        """)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_clean_rechecks_each_transcript_after_confirmation(self):
        r, _ = with_sessions("""
            from pathlib import Path
            from unittest.mock import patch
            import claude_sessions as cli
            from session_store import CLAUDE

            names = ("answered", "replaced", "removed", "invalid", "running", "untouched")
            paths = {}
            for n, name in enumerate(names, 1):
                sid = f"aaaaaaaa-2222-3333-4444-{n:012}"
                write(sid, [user])
                paths[name] = Path(pdir) / (sid + ".jsonl")
            extra = paths["answered"].with_suffix("")
            extra.mkdir()
            (extra / "notes.txt").write_text("keep")

            def confirm(question, assume_yes):
                with paths["answered"].open("a") as out:
                    print(json.dumps({"type": "assistant", "message": {"content": "done"}}), file=out)
                replacement = Path(home) / "replacement"
                replacement.write_bytes(paths["replaced"].read_bytes())
                replacement.replace(paths["replaced"])
                paths["removed"].unlink()
                paths["invalid"].write_text("{")
                registry = Path(CLAUDE) / "sessions"
                registry.mkdir()
                (registry / f"{os.getpid()}.json").write_text(json.dumps({
                    "pid": os.getpid(), "sessionId": paths["running"].stem}))
                return True

            with patch.object(cli, "confirm", side_effect=confirm):
                cli.clean(False)
            for name in ("answered", "replaced", "invalid", "running"):
                assert paths[name].is_file(), name
            assert (extra / "notes.txt").read_text() == "keep"
            assert not paths["untouched"].exists()
        """)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_clean_preserves_restored_links_and_changed_orphan_trees(self):
        r, _ = with_sessions("""
            from pathlib import Path
            from unittest.mock import patch
            import claude_sessions as c

            link = Path(pdir) / "broken"
            link.symlink_to("absent")
            def replace_link(*args):
                if link.is_symlink():
                    link.unlink()
                    link.write_text("restored")
                return True
            with patch.object(c, "confirm", side_effect=replace_link):
                c.clean(False)
            assert link.read_text() == "restored"
            os.rmdir(proj)
            memory = Path(pdir) / "memory"
            memory.mkdir()
            def change_memory(*args):
                (memory / "new.md").write_text("keep")
                return True
            with patch.object(c, "confirm", side_effect=change_memory):
                c.clean(False)
            assert (memory / "new.md").is_file()
            with patch.object(c, "confirm", side_effect=lambda *a: os.mkdir(proj) or True):
                c.clean(False)
            assert (memory / "new.md").is_file()
            os.rmdir(proj)
            c.clean(True)
            assert os.listdir(pdir) == ["memory"] and (memory / "new.md").is_file()
        """)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_sweep_removes_old_junk_only(self):
        r, _ = with_sessions("""
            import claude_restart as cr
            cr.sweep(pdir, ids["other"])
            print(sorted(os.listdir(pdir)))
        """)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("22222222", r.stdout)
        self.assertIn("11111111-2222-3333-4444-555555555555.jsonl", r.stdout)

    def test_last_session_survives_a_vanishing_file(self):
        r, _ = with_sessions("""
            import claude_brief as b
            real = os.path.getmtime
            def flaky(p):
                if ids["other"] in p:
                    raise FileNotFoundError(p)
                return real(p)
            b.os.path.getmtime = flaky
            print(b.last_session(proj, proj)[0])
        """)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "11111111-2222-3333-4444-555555555555")


if __name__ == "__main__":
    unittest.main()


class CleanForTheApp(unittest.TestCase):
    def test_report_changes_nothing_and_only_cleans_chosen_groups(self):
        r, _ = with_misnamed("""
            import json
            cwd = os.path.join(home, "a😀b")
            old, new = misnamed(cwd)
            proj = os.path.join(home, "proj")
            os.makedirs(proj)
            pdir = os.path.join(s.PROJECTS, s.encode(proj))
            session(pdir, B, proj)
            link = os.path.join(pdir, "gone.jsonl")
            os.symlink(os.path.join(home, "nowhere.jsonl"), link)
            before = sorted(os.listdir(old))
            report = c.clean_report()
            json.dumps(report, ensure_ascii=False)
            assert len(report["misnamed"]) == 1 and report["misnamed"][0]["sessions"] == 1, report
            assert [b["target"] for b in report["broken"]] == [os.path.join(home, "nowhere.jsonl")], report
            assert sorted(os.listdir(old)) == before and os.path.islink(link)
            c.clean(True, only={"broken"})
            assert os.path.exists(old) and not os.path.lexists(link)
            c.clean(True, only={"misnamed"})
            assert not os.path.exists(old)
            print("ok")
        """)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(r.stdout.split()[-1], "ok", r.stdout)
