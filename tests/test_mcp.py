import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(ROOT, "libexec", "agentmeister", "lib"))
import mcp_server  # noqa: E402


def request(rid, method, **params):
    return json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n"


class Reload(unittest.TestCase):
    def setUp(self):
        # копия agentmeister: тест меняет время файлов, рабочую папку не трогаем
        self.copy = tempfile.mkdtemp(prefix="cm-mcp-test-")
        for name in ("bin", "libexec", "share", "VERSION"):
            src = os.path.join(ROOT, name)
            (shutil.copytree if os.path.isdir(src) else shutil.copy2)(src, os.path.join(self.copy, name))
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        self.proc = subprocess.Popen([os.path.join(self.copy, "bin", "agentmeister"), "mcp"], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, env=env)

    def tearDown(self):
        self.proc.kill()
        self.proc.wait()
        shutil.rmtree(self.copy, True)

    def send(self, text):
        self.proc.stdin.write(text.encode())
        self.proc.stdin.flush()

    def read(self):
        return json.loads(self.proc.stdout.readline())

    def test_code_change_reloads_without_losing_requests(self):
        self.send(request(1, "initialize"))
        self.assertTrue(self.read()["result"]["capabilities"]["tools"]["listChanged"])
        pid = self.proc.pid
        lib = os.path.join(self.copy, "libexec", "agentmeister", "lib", "mnrhlib.py")
        later = time.time() + 5
        os.utime(lib, (later, later))
        # два запроса одним куском: оба должны дойти до нового процесса
        self.send(request(2, "ping") + request(3, "tools/list"))
        first, second = self.read(), self.read()
        self.assertEqual((first["id"], second["id"]), (2, 3))
        self.assertTrue(second["result"]["tools"])
        self.assertEqual(self.proc.pid, pid)
        self.assertIsNone(self.proc.poll())


class OpenClaudeArgs(unittest.TestCase):
    def test_only_schema_arguments_reach_open_claude(self):
        args = {"project": "x", "mode": "normal", "placement": "tab", "prompt": "hi", "continue": True,
                "trust": True, "remote_control": False,
                "path": "/", "flags": ["--dangerously-skip-permissions"], "other": 1}
        with patch.object(mcp_server.claude_open, "open_claude", return_value=("ok", False)) as opened:
            self.assertEqual(mcp_server.HANDLERS["open_claude"](args), ("ok", False))
        passed = opened.call_args.args[0]
        self.assertEqual(set(passed), {"project", "mode", "placement", "prompt", "continue", "trust",
                                       "remote_control"})
        self.assertNotIn("path", passed)
        self.assertNotIn("flags", passed)

    def test_missing_placement_stays_missing(self):
        # open_claude выбирает вкладку или окно сам, если placement не передан
        with patch.object(mcp_server.claude_open, "open_claude", return_value=("ok", False)) as opened:
            mcp_server.HANDLERS["open_claude"]({"project": "x"})
        self.assertEqual(opened.call_args.args[0], {"project": "x"})


if __name__ == "__main__":
    unittest.main()
