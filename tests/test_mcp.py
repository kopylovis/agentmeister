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


class Concurrency(unittest.TestCase):
    def test_slow_call_does_not_block_others(self):
        import threading
        release = threading.Event()

        def slow(a):
            release.wait(10)
            return "slow", False

        rin, win = os.pipe()
        rout, wout = os.pipe()
        stdout = os.fdopen(wout, "w")
        with patch.dict(mcp_server.HANDLERS, usage_report=slow, todo_list=lambda a: ("fast", False)), \
                patch.object(mcp_server.sys, "stdin", type("In", (), {"fileno": lambda self: rin})()), \
                patch.object(mcp_server.sys, "stdout", stdout), \
                patch.object(mcp_server, "installed_elsewhere", return_value=False):
            server = threading.Thread(target=mcp_server.mcp)
            server.start()
            os.write(win, (request(1, "tools/call", name="usage_report", arguments={}) +
                           request(2, "tools/call", name="todo_list", arguments={}) +
                           request(3, "ping")).encode())
            reader = os.fdopen(rout)
            first = [json.loads(reader.readline()) for _ in range(2)]
            self.assertEqual(sorted(m["id"] for m in first), [2, 3])
            release.set()
            last = json.loads(reader.readline())
            self.assertEqual(last["id"], 1)
            self.assertEqual(last["result"]["content"][0]["text"], "slow")
            os.close(win)
            server.join(10)
            self.assertFalse(server.is_alive())
        stdout.close()
        reader.close()
        os.close(rin)


FAKE_PARALLEL = """
import json, time
def handle(name, a, cwd=None, cm=None):
    time.sleep(a.get("sleep", 0))
    with open(a["record"], "w") as f:
        json.dump([name, a, cwd], f)
    return "done " + a["branch"], bool(a.get("fail"))
"""


class ParallelFinishInBackground(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cm-finish-test-")
        self.lib = os.path.join(self.tmp, "lib")
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.lib)
        os.makedirs(self.bin)
        with open(os.path.join(self.lib, "claude_parallel.py"), "w") as f:
            f.write(FAKE_PARALLEL)
        self.shown = os.path.join(self.tmp, "notified")
        fake = os.path.join(self.bin, "osascript")
        with open(fake, "w") as f:
            f.write(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{self.shown}"\n')
        os.chmod(fake, 0o755)
        self.patches = [patch.object(mcp_server, "FINISH_LIB", self.lib),
                        patch.object(mcp_server, "FINISH_LOGS", os.path.join(self.tmp, "logs")),
                        patch.dict(os.environ, PATH=self.bin + os.pathsep + os.environ.get("PATH", ""))]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()
        shutil.rmtree(self.tmp, True)

    def args(self, **extra):
        return dict(branch="feat/x", action="pr", record=os.path.join(self.tmp, "record.json"), **extra)

    def wait_for(self, path, text, seconds=15):
        """Ждать, пока в файле появится text. Файл создается раньше, чем в него пишут, поэтому мало его наличия."""
        deadline = time.time() + seconds
        while True:
            try:
                with open(path) as f:
                    if text in f.read():
                        return True
            except OSError:
                pass
            if time.time() >= deadline:
                return False
            time.sleep(0.1)

    def test_quick_result_comes_back_directly(self):
        text, err = mcp_server.HANDLERS["parallel_finish"](self.args(fail=True))
        self.assertEqual((text, err), ("done feat/x", True))
        with open(os.path.join(self.tmp, "record.json")) as f:
            name, a, cwd = json.load(f)
        self.assertEqual((name, a["branch"], cwd), ("parallel_finish", "feat/x", os.getcwd()))
        time.sleep(0.3)
        self.assertFalse(os.path.exists(self.shown))

    def test_long_run_returns_early_and_notifies(self):
        # ответ приходит через FINISH_WAIT, задолго до конца работы (4 секунды); запас на занятый Mac
        with patch.object(mcp_server, "FINISH_WAIT", 0.3):
            started = time.time()
            text, err = mcp_server.HANDLERS["parallel_finish"](self.args(sleep=4))
        self.assertLess(time.time() - started, 3)
        self.assertFalse(err)
        self.assertIn("в фоне", text)
        self.assertTrue(self.wait_for(self.shown, "done feat/x"))
        logs = os.listdir(os.path.join(self.tmp, "logs"))
        log = next(n for n in logs if n.endswith(".log"))
        self.assertIn("feat_x", log)
        with open(os.path.join(self.tmp, "logs", log)) as f:
            self.assertIn("done feat/x", f.read())


if __name__ == "__main__":
    unittest.main()
