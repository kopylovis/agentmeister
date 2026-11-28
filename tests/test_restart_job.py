import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "libexec", "agentmeister", "lib"))
import restart_job as rj  # noqa: E402

SID = "11111111-2222-4333-8444-555555555555"
NEW = "66666666-7777-4888-9999-aaaaaaaaaaaa"


class Validate(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def job(self, **over):
        job = {"v": 2, "kind": "claude", "cwd": self.dir, "mode": "restart", "session": SID, "new_session": SID,
               "update": True, "proxy": False, "caffeinate": None, "flags": ["--model", "opus"]}
        job.update(over)
        return job

    def test_good_job(self):
        self.assertEqual(rj.validate(self.job())["flags"], ["--model", "opus"])

    def test_rejects_bad_fields(self):
        bad = [
            {"flags": ["--model", "opus", "--evil"]},
            {"flags": ["--verbose", "prompt"]},
            {"flags": ["--resume", SID]},
            {"flags": "--model opus"},
            {"cwd": "relative"},
            {"cwd": os.path.join(self.dir, "missing")},
            {"session": "$(touch x)"},
            {"mode": "shell"},
            {"update": "yes"},
            {"caffeinate": ["-i", "; rm"]},
            {"caffeinate": ["-t"]},
            {"mode": "forget"},
            {"mode": "fresh", "new_session": NEW, "update": True},
            {"line": "cd / && sh"},
            {"v": 1},
            {"kind": "sh"},
        ]
        for over in bad:
            with self.assertRaises(rj.JobError, msg=over):
                rj.validate(self.job(**over))

    def test_clean_flags_drops_unknown(self):
        kept, dropped = rj.clean_flags(["--model", "opus", "--mystery", "val", "--add-dir", "a", "b", "--verbose",
                                        "-n", "name", "--resume", SID])
        self.assertEqual(kept, ["--model", "opus", "--add-dir", "a", "b", "--verbose", "-n", "name"])
        self.assertEqual(dropped, ["--mystery", "val", "--resume", SID])

    def test_values_are_argv_not_shell(self):
        job = rj.validate(self.job(flags=["--append-system-prompt", "x; touch /tmp/pwned", "--model=opus"]))
        run = rj.steps(job)[-1][0]
        self.assertEqual(run[-3:], ["--append-system-prompt", "x; touch /tmp/pwned", "--model=opus"])
        self.assertIn("'x; touch /tmp/pwned'", rj.shell_line(job))

    def test_steps(self):
        job = rj.claude_job(self.dir, "slim", SID, proxy=True, caffeinate=["-is"], flags=["--verbose"])
        argvs = [argv for argv, _ in rj.steps(job)]
        self.assertEqual(argvs[0][1:], ["lid", "keep"])
        self.assertEqual(argvs[1][1:], ["sessions", "slim", SID, "-y", "--notice"])
        self.assertEqual(argvs[2][1:], ["proxy", "run", "--claude", "--", "caffeinate", "-is", rj.CLAUDE_BIN,
                                        "--resume", SID, "--verbose"])
        fresh = rj.claude_job(self.dir, "fresh", SID, NEW)
        self.assertEqual([argv for argv, _ in rj.steps(fresh)],
                         [["clear"], [rj.CLAUDE_BIN, "--session-id", NEW]])
        self.assertTrue(rj.shell_line(fresh).startswith(f"cd {self.dir} && {{ clear; printf"))


class Read(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "ttys001")

    def take(self):
        out, err = io.StringIO(), io.StringIO()
        return rj.take(self.path, out, err), out.getvalue(), err.getvalue()

    def test_round_trip_consumes_the_file(self):
        rj.write(self.path, rj.claude_job(self.dir, "restart", SID, update=True))
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        code, out, _ = self.take()
        self.assertEqual(code, 0)
        cwd, line, data = out.split("\0")
        self.assertEqual(cwd, self.dir)
        self.assertIn(f"--resume {SID}", line)
        self.assertEqual(json.loads(data)["session"], SID)
        self.assertFalse(os.path.exists(self.path))
        self.assertEqual(self.take()[0], 1)

    def test_legacy_shell_line_is_not_run(self):
        with open(self.path, "w") as f:
            f.write(f"cd /tmp && {{ claude --resume {SID}; }}")
        code, out, err = self.take()
        self.assertEqual((code, out), (1, ""))
        self.assertIn(f"--resume {SID}", err)
        self.assertFalse(os.path.exists(self.path))

    def test_stale_job_is_dropped(self):
        rj.write(self.path, rj.claude_job(self.dir, "restart", SID))
        old = time.time() - rj.MAX_AGE - 5
        os.utime(self.path, (old, old))
        self.assertEqual(self.take(), (1, "", ""))
        self.assertFalse(os.path.exists(self.path))

    def test_symlink_is_refused(self):
        target = os.path.join(self.dir, "target")
        rj.write(target, rj.claude_job(self.dir, "restart", SID))
        os.symlink(target, self.path)
        code, _, err = self.take()
        self.assertEqual(code, 1)
        self.assertIn("перезапуск пропущен", err)
        self.assertTrue(os.path.exists(target))


class ZshHook(unittest.TestCase):
    """Хук целиком в zsh: задание из JSON запускает claude с этими argv, а строка shell не выполняется."""

    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.work = os.path.realpath(tempfile.mkdtemp())
        self.log = os.path.join(self.home, "argv.json")
        self.fake = os.path.join(self.home, "claude")
        with open(self.fake, "w") as f:
            f.write("#!/usr/bin/python3\nimport json, os, sys\n"
                    f"json.dump([os.getcwd()] + sys.argv[1:], open({self.log!r}, 'w'))\n")
        os.chmod(self.fake, 0o755)
        self.queue = os.path.join(self.home, ".cache", "agentmeister", "restart")
        os.makedirs(self.queue)

    def hook(self):
        script = (f"source {os.path.join(ROOT, 'share', 'agentmeister', 'restart.zsh')!r}; "
                  "TTY=/dev/ttys999; _mnrh_restart; print -r -- PWD=$PWD")
        env = dict(os.environ, HOME=self.home, MNRH_CLAUDE_BIN=self.fake)
        return subprocess.run(["zsh", "-f", "-c", script], env=env, capture_output=True, text=True, timeout=30)

    def test_runs_the_job(self):
        with patch.object(rj, "CLAUDE_BIN", self.fake):
            rj.write(os.path.join(self.queue, "ttys999"),
                     rj.claude_job(self.work, "restart", SID, flags=["--append-system-prompt", "a; touch pwned"]))
        r = self.hook()
        with open(self.log) as f:
            self.assertEqual(json.load(f), [self.work, "--resume", SID, "--append-system-prompt", "a; touch pwned"])
        self.assertIn(f"PWD={self.work}", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.work, "pwned")))

    def test_shell_line_is_ignored(self):
        with open(os.path.join(self.queue, "ttys999"), "w") as f:
            f.write(f"touch {self.home}/pwned")
        r = self.hook()
        self.assertFalse(os.path.exists(os.path.join(self.home, "pwned")))
        self.assertIn("перезапуск пропущен", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.queue, "ttys999")))


if __name__ == "__main__":
    unittest.main()
