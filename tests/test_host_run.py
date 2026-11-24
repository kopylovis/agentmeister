import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "libexec/agentmeister/lib"))
import claude_proxy
import host_run


def write_commands(path, commands):
    Path(path).write_text(json.dumps({"commands": commands}))


class Rules(unittest.TestCase):
    def test_load_and_resolve(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "commands.json"
            write_commands(path, {
                "ios": {"cwd": "~/x", "run": ["bundle", "exec", "fastlane", "ios_beta"]},
                "fire": {"cwd": tmp, "run": ["fastlane", "upload"], "args": True},
            })
            rules = host_run.load(path)
            self.assertEqual(rules["ios"]["cwd"], os.path.expanduser("~/x"))
            self.assertEqual(host_run.resolve("fire", ["notes:hi"], rules), (["fastlane", "upload", "notes:hi"], tmp))
            self.assertEqual(host_run.resolve("ios", [], rules)[0], ["bundle", "exec", "fastlane", "ios_beta"])
            with self.assertRaises(host_run.RuleError):
                host_run.resolve("ios", ["--evil"], rules)
            with self.assertRaises(host_run.RuleError):
                host_run.resolve("rm", [], rules)

    def test_bad_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "commands.json"
            self.assertEqual(host_run.load(path), {})
            for commands in ({"list": {"cwd": tmp, "run": ["x"]}}, {"a": {"cwd": tmp, "run": "x"}},
                             {"a": {"cwd": "rel", "run": ["x"]}}, {"a": {"run": ["x"]}}):
                with self.subTest(commands=commands):
                    write_commands(path, commands)
                    with self.assertRaises(host_run.RuleError):
                        host_run.load(path)
            path.write_text("{")
            with self.assertRaises(host_run.RuleError):
                host_run.load(path)

    def test_env_drops_proxy(self):
        env = host_run.command_env({"HTTPS_PROXY": "http://127.0.0.1:1", "all_proxy": "x", "MNRH_PROXY": "1",
                                    "PATH": "/bin"})
        self.assertEqual(env, {"PATH": "/bin"})


class TrustedRead(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp")  # /tmp — системная ссылка root, ее можно
        self.addCleanup(self.tmp.cleanup)
        self.conf = Path(self.tmp.name) / "conf"
        self.conf.mkdir()
        self.path = self.conf / "commands.json"
        write_commands(self.path, {"t": {"cwd": self.tmp.name, "run": ["true"]}})
        self.path.chmod(0o600)

    def test_reads_a_private_file(self):
        self.assertIn("t", host_run.load(self.path))

    def test_refuses_a_symlinked_parent(self):
        link = Path(self.tmp.name) / "link"
        link.symlink_to(self.conf)
        with self.assertRaisesRegex(host_run.RuleError, "ссылка"):
            host_run.load(link / "commands.json")

    def test_refuses_a_symlinked_file(self):
        link = self.conf / "other.json"
        link.symlink_to(self.path)
        with self.assertRaises(host_run.RuleError):
            host_run.load(link)

    def test_refuses_writable_by_others(self):
        self.path.chmod(0o620)
        with self.assertRaisesRegex(host_run.RuleError, "chmod 600"):
            host_run.load(self.path)
        self.path.chmod(0o600)
        self.conf.chmod(0o777)
        try:
            with self.assertRaisesRegex(host_run.RuleError, "другие"):
                host_run.load(self.path)
        finally:
            self.conf.chmod(0o700)

    def test_missing_file_is_an_empty_list(self):
        self.assertEqual(host_run.load(self.conf / "none.json"), {})
        self.assertEqual(host_run.load(Path(self.tmp.name) / "none" / "commands.json"), {})


class Roundtrip(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.sock = str(Path(self.tmp.name) / "s")
        self.commands = str(Path(self.tmp.name) / "commands.json")
        write_commands(self.commands, {
            "echo": {"cwd": self.tmp.name, "run": [sys.executable, "-c",
                                                   "import os, sys; print(os.getcwd(), *sys.argv[1:]); "
                                                   "print(os.environ.get('HTTPS_PROXY')); sys.exit(3)"],
                     "args": True},
            "fixed": {"cwd": self.tmp.name, "run": ["true"]},
            "sleep": {"cwd": self.tmp.name, "run": [sys.executable, "-c",
                                                    f"import time, pathlib; pathlib.Path({self.tmp.name!r}, 'started').touch(); "
                                                    "time.sleep(30)"]},
        })
        self.server = host_run.Server(self.sock, self.commands)
        listener = host_run.listen(self.sock)
        self.addCleanup(listener.close)
        threading.Thread(target=self.server.serve_forever, args=(listener,), daemon=True).start()

    def tearDown(self):
        self.tmp.cleanup()

    def call(self, name, args):
        out, err = io.BytesIO(), io.StringIO()
        with patch.dict(os.environ, HTTPS_PROXY="http://127.0.0.1:9"):
            code = host_run.call(name, args, self.sock, out, err)
        return code, out.getvalue().decode(), err.getvalue()

    def test_runs_with_output_and_code(self):
        code, out, _ = self.call("echo", ["a b", "c"])
        self.assertEqual(code, 3)
        self.assertEqual(out.splitlines(), [f"{os.path.realpath(self.tmp.name)} a b c", "None"])

    def test_refuses_unknown_and_extra_args(self):
        for name, args in (("rm", []), ("fixed", ["-rf"])):
            with self.subTest(name=name):
                code, out, err = self.call(name, args)
                self.assertEqual((code, out), (2, ""))
                self.assertIn("agentmeister host-run:", err)

    def test_ping(self):
        info = host_run.ping(self.sock)
        self.assertEqual(info["pid"], os.getpid())
        self.assertEqual(info["jobs"], 0)

    def test_client_gone_stops_command(self):
        conn = socket.socket(socket.AF_UNIX)
        conn.connect(self.sock)
        conn.sendall(b'{"name": "sleep", "args": []}\n')
        started = Path(self.tmp.name) / "started"
        for _ in range(100):
            if started.exists() and self.server.jobs == 1:
                break
            time.sleep(0.05)
        self.assertEqual(self.server.jobs, 1)
        conn.close()
        for _ in range(100):
            if self.server.jobs == 0:
                break
            time.sleep(0.05)
        self.assertEqual(self.server.jobs, 0)

    def test_no_server(self):
        err = io.StringIO()
        self.assertEqual(host_run.call("echo", [], str(Path(self.tmp.name) / "none"), io.BytesIO(), err), 125)
        self.assertIn("не запущен", err.getvalue())


class Restart(unittest.TestCase):
    def test_old_runner_keeps_a_newer_socket(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            path = str(Path(tmp) / "s")
            old = host_run.listen(path)
            mine = os.stat(path).st_ino
            new = host_run.listen(path)  # новый исполнитель занял путь своим сокетом
            self.addCleanup(old.close)
            self.addCleanup(new.close)
            host_run.remove_own_socket(path, mine)
            self.assertTrue(os.path.exists(path))
            host_run.remove_own_socket(path, os.stat(path).st_ino)
            self.assertFalse(os.path.exists(path))

    def test_waits_for_the_old_runner_to_exit(self):
        child = subprocess.Popen([sys.executable, "-c", "import signal, sys, time\n"
                                  "signal.signal(signal.SIGTERM, lambda *_: (time.sleep(0.5), sys.exit(0)))\n"
                                  "print('ready', flush=True)\ntime.sleep(30)"], stdout=subprocess.PIPE)
        self.assertEqual(child.stdout.readline(), b"ready\n")
        child.stdout.close()
        threading.Thread(target=child.wait, daemon=True).start()  # как launchd: выход виден сразу
        start = time.monotonic()
        with patch.object(host_run, "log"):
            host_run.stop_old(child.pid)
        self.assertGreaterEqual(time.monotonic() - start, 0.4)
        with self.assertRaises(ProcessLookupError):
            os.kill(child.pid, 0)

    def test_lock_waits_for_the_old_holder(self):
        import fcntl
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "pid"
            held = open(path, "a+")
            fcntl.flock(held, fcntl.LOCK_EX)
            with open(path, "a+") as f:
                self.assertFalse(host_run.lock(f, wait=0.2))
                threading.Timer(0.2, held.close).start()
                self.assertTrue(host_run.lock(f, wait=2))


class Profile(unittest.TestCase):
    def test_claude_profile_protects_the_list(self):
        command = claude_proxy.session_command(17890, ["true"], claude=True)
        self.assertIn(f"HOST_RUN_CONF={os.path.realpath(host_run.CONF_DIR)}", command)
        self.assertIn(f"HOST_RUN_STATE={os.path.realpath(host_run.STATE)}", command)
        self.assertIn(f"HOST_RUN_PID={os.path.realpath(host_run.PIDFILE)}", command)
        profile = command[command.index("-p") + 1]
        self.assertIn('(deny file-write* file-link (subpath (param "HOST_RUN_CONF"))', profile)
        self.assertIn('(deny file-read* (literal (param "HOST_RUN_PID")))', profile)

    def test_claude_profile_protects_parents(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.realpath(tmp)
            with patch.multiple(host_run, CONF_DIR=f"{real}/a/b/host-run", STATE=f"{real}/s/host-run"):
                command = claude_proxy.session_command(17890, ["true"], claude=True)
                parents = host_run.protected_parents()
        params = {a.split("=", 1)[1] for a in command if a.startswith("HOST_RUN_UP")}
        for path in (f"{real}/a/b", f"{real}/a", real, f"{real}/s", os.path.dirname(real)):
            self.assertIn(path, params)
        self.assertNotIn("/", params)
        self.assertEqual(len(params), len(parents))
        profile = command[command.index("-p") + 1]
        self.assertIn(f'(literal (param "HOST_RUN_UP{len(parents) - 1}"))', profile)
        self.assertNotIn(f'HOST_RUN_UP{len(parents)}"', profile)

    @unittest.skipUnless(sys.platform == "darwin" and host_run.nested_sandbox_ok(), "requires the macOS sandbox")
    def test_sandboxed_session_reaches_socket_but_cannot_write(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            conf, state = Path(tmp) / "up" / "conf", Path(tmp) / "state"
            conf.mkdir(parents=True)
            state.mkdir()
            sock = str(state / "s")
            listener = host_run.listen(sock)
            self.addCleanup(listener.close)
            write_commands(conf / "commands.json", {"t": {"cwd": tmp, "run": ["true"]}})
            (state / "host-run.pid").write_text("1")
            threading.Thread(target=host_run.Server(sock, str(conf / "commands.json")).serve_forever,
                             args=(listener,), daemon=True).start()
            client = f"""\
import sys
sys.path.insert(0, {str(Path(host_run.__file__).parent)!r})
import host_run
for path in ({str(conf / 'commands.json')!r}, {str(state / 'x')!r}):
    try:
        open(path, 'w')
    except PermissionError:
        pass
    else:
        sys.exit('wrote ' + path)
import os
attempts = {{
    'rename a parent of the list': lambda: os.rename({str(Path(tmp) / 'up')!r}, {str(Path(tmp) / 'moved')!r}),
    'link the list': lambda: os.link({str(conf / 'commands.json')!r}, {str(Path(tmp) / 'list-link')!r}),
    'open the pid file': lambda: open({str(state / 'host-run.pid')!r}),
}}
for name, action in attempts.items():
    try:
        action()
    except PermissionError:
        continue
    sys.exit('could ' + name)
open({str(Path(tmp) / 'other')!r}, 'w').close()  # рядом писать можно
sys.exit(host_run.call('t', [], {sock!r}))
"""
            with patch.multiple(host_run, CONF_DIR=str(conf), STATE=str(state), PIDFILE=str(state / "host-run.pid")):
                command = claude_proxy.session_command(17890, [sys.executable, "-c", client], claude=True)
            subprocess.run(command, check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
