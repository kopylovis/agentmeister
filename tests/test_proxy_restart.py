import json
import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import textwrap
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "libexec/agentmeister/lib"))
import claude_proxy_restart as restart


class ProxyRestart(unittest.TestCase):
    def test_caffeinate_wraps_the_whole_session(self):
        command = restart.supervised_command(["caffeinate", "-is", "claude", "--model", "opus"])
        self.assertEqual(command[:2], ["caffeinate", "-is"])
        self.assertEqual(command[-3:], ["claude", "--model", "opus"])
        for cmd in (["claude", "update"], ["claude", "-p", "hello"], ["echo", "hi"]):
            self.assertEqual(restart.supervised_command(cmd), cmd)

    def test_restart_resumes_in_original_terminal_with_proxy_and_flags(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            fake = home / "claude"
            fake.write_text("#!" + sys.executable + "\n" + textwrap.dedent("""\
                import json, os, signal, subprocess, sys
                from pathlib import Path
                home = Path(os.environ["HOME"])
                args = sys.argv[1:]
                with (home / "calls").open("a") as f:
                    print(json.dumps([args, os.ttyname(0), os.environ["HTTPS_PROXY"]]), file=f)
                if args[:1] in (["--resume"], ["update"]):
                    sys.exit(0)
                pid = os.getpid()
                sid = os.environ["TEST_SESSION"]
                (home / ".claude/sessions" / f"{pid}.json").write_text(json.dumps({"sessionId":sid, "cwd":str(home)}))
                os.environ.pop("CLAUDE_PID", None)
                subprocess.run([os.environ["TEST_AM"], "restart"], check=True)
                while True:
                    signal.pause()
            """))
            fake.chmod(0o700)
            (home / ".claude/sessions").mkdir(parents=True)
            sid = str(uuid.uuid4())
            proxy = "http://127.0.0.1:17890"
            env = dict(os.environ, HOME=tmp, MNRH_CLAUDE_HOME=str(home / ".claude"), TEST_SESSION=sid,
                       MNRH_PROXY="17890", HTTPS_PROXY=proxy, TEST_AM=str(ROOT / "bin/agentmeister"))
            env.pop("CLAUDE_CODE_SESSION_ID", None)
            master, slave = pty.openpty()
            try:
                tty = os.ttyname(slave)
                subprocess.run(restart.supervised_command([str(fake), "--model", "opus", "first prompt"]),
                               stdin=slave, stdout=slave, stderr=slave, env=env, check=True, timeout=12)
            finally:
                os.close(slave)
                os.close(master)
            calls = [json.loads(line) for line in (home / "calls").read_text().splitlines()]
            self.assertEqual(calls, [[["--model", "opus", "first prompt"], tty, proxy],
                                     [["update"], tty, proxy], [["--resume", sid, "--model", "opus"], tty, proxy]])
