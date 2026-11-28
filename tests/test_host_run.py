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
import claude_open
import proxy
import host_run


def setUpModule():
    # тексты проверяются на русском, язык машины не важен; английский проверяет отдельный тест
    patcher = patch("mnrhlib.lang", return_value="ru")
    patcher.start()
    unittest.addModuleCleanup(patcher.stop)


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
        self.assertEqual(info["code"], host_run.CODE)
        self.assertEqual(info["ops"], ["add", "remove", "open"])

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


class EditList(unittest.TestCase):
    """add и remove: окно подменено, проверяется, что и когда пишется в список."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.sock = str(self.dir / "s")
        self.commands = self.dir / "conf" / "commands.json"
        self.commands.parent.mkdir()
        self.project = self.dir / "project"
        self.project.mkdir()
        self.commands.write_text(json.dumps({"commands": {
            "keep": {"cwd": str(self.project), "run": ["make", "test"], "note": "чужое поле остается"},
            "fire": {"cwd": str(self.project), "run": ["fastlane", "upload"], "args": True},
        }}, indent=4))
        self.commands.chmod(0o600)
        listener = host_run.listen(self.sock)
        self.addCleanup(listener.close)
        threading.Thread(target=host_run.Server(self.sock, str(self.commands)).serve_forever, args=(listener,),
                         daemon=True).start()
        self.answer = "allow"
        self.asked = []

        def ask(conn, change):
            self.asked.append(change)
            return self.answer

        patcher = patch.object(host_run, "ask_human", side_effect=ask)
        patcher.start()
        self.addCleanup(patcher.stop)

    def edit(self, op, argv):
        out, err = io.BytesIO(), io.StringIO()
        request = host_run.parse_add(argv) if op == "add" else host_run.parse_remove(argv)
        code = host_run.send_op(request, self.sock, out, err)
        return code, out.getvalue().decode(), err.getvalue()

    def rules(self):
        return json.loads(self.commands.read_text())["commands"]

    def test_add_keeps_the_other_entries(self):
        before = self.rules()
        code, out, _ = self.edit("add", ["hello", "--cwd", str(self.project), "--run", "echo", "hello world"])
        self.assertEqual(code, 0)
        self.assertIn("hello добавлена", out)
        rules = self.rules()
        self.assertEqual(rules["hello"], {"cwd": host_run.tilde(str(self.project)), "run": ["echo", "hello world"]})
        self.assertEqual({k: v for k, v in rules.items() if k != "hello"}, before)
        self.assertEqual(list(rules), ["keep", "fire", "hello"])
        self.assertEqual(self.commands.stat().st_mode & 0o777, 0o600)
        self.assertIn("hello", host_run.load(self.commands))
        self.assertEqual(len(self.asked), 1)
        with patch("mnrhlib.lang", return_value="ru"):
            args = host_run.dialog_args(self.asked[0])
        shown = dict(zip(args[::2], args[1::2]))
        self.assertEqual(shown["--title"], "agentmeister host-run: добавить команду")
        self.assertEqual(shown["--heading"], "Сессия просит новую команду для host-run")
        self.assertEqual(shown["--code"], '"hello": {\n  "cwd": %s,\n  "run": ["echo", "hello world"]\n}'
                         % json.dumps(host_run.tilde(str(self.project))))
        self.assertNotIn("аргументы", shown["--text"])
        self.assertEqual((shown["--allow"], shown["--deny"]), ("Разрешить", "Отказать"))
        self.assertIn("{left}", shown["--expiry"])
        self.assertEqual(shown["--timeout"], str(host_run.CONFIRM_TIMEOUT))
        self.assertEqual([p.name for p in self.commands.parent.iterdir()], ["commands.json"])

    def test_add_creates_the_list(self):
        self.commands.unlink()
        self.commands.parent.rmdir()
        code, _, _ = self.edit("add", ["one", "--args", "--cwd", str(self.project), "--run", "true"])
        self.assertEqual(code, 0)
        self.assertEqual(self.rules(), {"one": {"cwd": host_run.tilde(str(self.project)), "run": ["true"],
                                                "args": True}})
        self.assertEqual(self.commands.parent.stat().st_mode & 0o777, 0o700)

    def test_refusal_leaves_the_file(self):
        before = self.commands.read_bytes()
        for answer, reason in (("deny", "отказ"), ("closed", "закрыли"), ("timeout", "нет ответа")):
            with self.subTest(answer=answer):
                self.answer = answer
                code, out, err = self.edit("add", ["hello", "--cwd", str(self.project), "--run", "true"])
                self.assertEqual((code, out), (1, ""))
                self.assertIn("hello не добавлена", err)
                self.assertIn(reason, err)
                self.assertEqual(self.commands.read_bytes(), before)

    def test_existing_name_needs_replace(self):
        before = self.commands.read_bytes()
        code, _, err = self.edit("add", ["keep", "--cwd", str(self.project), "--run", "make", "lint"])
        self.assertEqual(code, 2)
        self.assertIn("--replace", err)
        self.assertEqual(self.asked, [])
        self.assertEqual(self.commands.read_bytes(), before)

        code, out, _ = self.edit("add", ["keep", "--cwd", str(self.project), "--run", "make", "lint", "--replace"])
        self.assertEqual(code, 0)
        self.assertIn("заменена", out)
        with patch("mnrhlib.lang", return_value="ru"):
            code = dict(zip(*[iter(host_run.dialog_args(self.asked[0]))] * 2))["--code"]
        now, becomes = code.split("// станет")
        self.assertIn("// сейчас", now)
        self.assertIn('["make", "test"]', now)
        self.assertIn('"note": "чужое поле остается"', now)
        self.assertIn('["make", "lint"]', becomes)
        self.assertEqual(self.rules()["keep"]["run"], ["make", "lint"])
        self.assertEqual(list(self.rules()), ["keep", "fire"])

    def test_dialog_follows_the_language(self):
        self.edit("add", ["one", "--args", "--cwd", str(self.project), "--run", "true"])
        self.edit("remove", ["fire"])
        add, remove = self.asked
        with patch("mnrhlib.lang", return_value="en"):
            shown = dict(zip(*[iter(host_run.dialog_args(add))] * 2))
            gone = dict(zip(*[iter(host_run.dialog_args(remove))] * 2))
        self.assertEqual(shown["--heading"], "A session wants a new host-run command")
        self.assertTrue(shown["--text"].startswith("The command runs outside the sandbox with direct network access. "
                                                   "Once allowed, any proxied session can run it."))
        self.assertIn("append their own arguments", shown["--text"])
        self.assertIn('"args": true', shown["--code"])
        self.assertEqual((shown["--allow"], shown["--deny"]), ("Allow", "Deny"))
        self.assertEqual(shown["--expiry"], "No answer in {left} counts as deny")
        self.assertIn("mouse or trackpad", shown["--note"])
        self.assertIn("allowlist", shown["--context"])
        self.assertEqual(gone["--title"], "agentmeister host-run: remove a command")
        self.assertIn("fire", gone["--heading"])
        self.assertIn('["fastlane", "upload"]', gone["--code"])

    def test_same_entry_needs_no_window(self):
        self.commands.write_text(json.dumps({"commands": {
            "same": {"cwd": host_run.tilde(str(self.project)), "run": ["true"]}}}))
        code, out, _ = self.edit("add", ["same", "--cwd", str(self.project), "--run", "true"])
        self.assertEqual((code, self.asked), (0, []))
        self.assertIn("том же виде", out)

    def test_remove(self):
        code, out, _ = self.edit("remove", ["fire"])
        self.assertEqual(code, 0)
        self.assertIn("удалена", out)
        self.assertEqual(list(self.rules()), ["keep"])
        self.assertEqual(self.rules()["keep"]["note"], "чужое поле остается")
        code, _, err = self.edit("remove", ["fire"])
        self.assertEqual(code, 2)
        self.assertIn("нет в списке", err)

    def test_refused_remove_keeps_the_entry(self):
        self.answer = "deny"
        code, _, err = self.edit("remove", ["fire"])
        self.assertEqual(code, 1)
        self.assertIn("fire не удалена", err)
        self.assertIn("fire", self.rules())

    def test_bad_requests(self):
        cases = (["list", "--cwd", str(self.project), "--run", "x"],
                 ["bad name", "--cwd", str(self.project), "--run", "x"],
                 ["x", "--cwd", str(self.dir / "none"), "--run", "x"])
        for argv in cases:
            with self.subTest(argv=argv):
                code, _, _ = self.edit("add", argv)
                self.assertEqual(code, 2)
        self.assertEqual(self.asked, [])

    def test_list_changed_while_the_window_was_open(self):
        def ask(conn, change):
            self.commands.write_text(json.dumps({"commands": {}}))
            return "allow"

        with patch.object(host_run, "ask_human", side_effect=ask):
            code, _, err = self.edit("add", ["hello", "--cwd", str(self.project), "--run", "true"])
        self.assertEqual(code, 2)
        self.assertIn("поменялся", err)
        self.assertEqual(self.rules(), {})

    def test_old_runner_is_not_asked(self):
        err = io.StringIO()
        with patch.object(host_run, "ping", return_value={"version": "1.17.0", "pid": 1, "jobs": 0}):
            code = host_run.send_op(host_run.parse_remove(["fire"]), self.sock, io.BytesIO(), err)
        self.assertEqual(code, 125)
        self.assertIn("не умеет remove", err.getvalue())
        self.assertIn("fire", self.rules())

    def test_parse_add(self):
        with patch("os.getcwd", return_value="/work"):
            request = host_run.parse_add(["n", "--cwd", "sub", "--run", "a", "--flag", "b", "--args", "--replace"])
        self.assertEqual(request, {"op": "add", "replace": True,
                                   "command": {"name": "n", "cwd": "/work/sub", "run": ["a", "--flag", "b"],
                                               "args": True}})
        for argv in ([], ["--cwd", "x"], ["n", "--run", "x"], ["n", "--cwd", "/x"], ["n", "--bogus"]):
            with self.subTest(argv=argv), self.assertRaises(host_run.RuleError):
                host_run.parse_add(argv)


class OpenTab(unittest.TestCase):
    """host-run open: исполнитель получает первый запрос целиком и открывает вкладку сам."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.sock = str(Path(self.tmp.name) / "s")
        listener = host_run.listen(self.sock)
        self.addCleanup(listener.close)
        threading.Thread(target=host_run.Server(self.sock, str(Path(self.tmp.name) / "none")).serve_forever,
                         args=(listener,), daemon=True).start()

    def open(self, argv, result=("Открыл новую вкладку iTerm2", False)):
        out, err = io.BytesIO(), io.StringIO()
        with patch.object(claude_open, "open_tab", return_value=result) as tab:
            code = host_run.send_op({"op": "open", "argv": argv}, self.sock, out, err)
        return code, out.getvalue().decode(), err.getvalue(), tab

    def test_prompt_reaches_the_runner_whole(self):
        prompt = 'строка 1\nстрока "2" с \'кавычками\'\n\t$HOME `date` \\ конец'
        code, out, _, tab = self.open(["tossling", "--", "--remote-control", "tossling", prompt])
        self.assertEqual(code, 0)
        self.assertIn("Открыл", out)
        cmd = tab.call_args.args[0]
        self.assertEqual(cmd[1:], ["open", "tossling", "-k", "-x", "--new", "--", "--remote-control", "tossling",
                                   prompt])

    def test_direct_is_refused(self):
        code, _, err, tab = self.open(["tossling", "-d", "--", "hi"])
        self.assertEqual(code, 2)
        self.assertIn("-d", err)
        tab.assert_not_called()

    def test_failure_is_reported(self):
        code, out, err, _ = self.open(["tossling"], ("iTerm2 не открыл вкладку (нет окна).", True))
        self.assertEqual((code, out), (1, ""))
        self.assertIn("не открыл", err)


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


class English(unittest.TestCase):
    def test_messages_follow_the_language(self):
        with patch("mnrhlib.lang", return_value="en"):
            with self.assertRaisesRegex(host_run.RuleError, "no command 'nope'"):
                host_run.resolve("nope", [], {})
            self.assertIn("<name>", host_run.usage())
            self.assertIn("isn't running", host_run.not_running())
            self.assertEqual(host_run.answer_text("deny"), "denied in the window")
            self.assertNotRegex(host_run.usage() + host_run.add_usage(), "[а-яА-Я]")


class EntryText(unittest.TestCase):
    def test_non_latin_characters_are_named(self):
        found = host_run.foreign_chars({"x": {"cwd": "~/Developer/t\u043essling", "run": ["echo", "a\u00a0b"]}})
        self.assertEqual(found, ["\u043e U+043E CYRILLIC SMALL LETTER O", "  U+00A0 NO-BREAK SPACE"])

    def test_lone_surrogate_is_refused_before_the_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            request = {"op": "add", "command": {"name": "x", "cwd": tmp, "run": ["echo", "\ud800"]}}
            with self.assertRaises(host_run.RuleError):
                host_run.plan_change(request, os.path.join(tmp, "commands.json"))


class PinnedConfirm(unittest.TestCase):
    def test_window_is_built_from_the_source_read_at_start(self):
        import hashlib
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "main.swift"
            src.write_bytes(b"// honest window\n")
            out = Path(tmp) / "confirm"
            out.mkdir()
            digest = hashlib.sha256(b"// honest window\n").hexdigest()[:16]
            built = out / f"agentmeister-confirm-{digest}"
            built.write_text("#!/bin/sh\n")
            built.chmod(0o755)
            with patch.object(host_run, "CONFIRM_SRC", str(src)), patch.object(host_run, "CONFIRM_DIR", str(out)), \
                    patch.object(host_run, "PINNED_CONFIRM", None):
                host_run.pin_confirm()
                src.write_bytes(b"// window that answers allow by itself\n")  # сессия переписала исходник
                self.assertEqual(host_run.confirm_helper(), str(built))

    def test_code_hash_covers_the_window_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "main.swift"
            src.write_bytes(b"a")
            with patch.object(host_run, "CONFIRM_SRC", str(src)):
                first = host_run.code_hash()
                src.write_bytes(b"b")
                self.assertNotEqual(first, host_run.code_hash())


class Profile(unittest.TestCase):
    def test_claude_profile_protects_the_list(self):
        command = proxy.session_command(17890, ["true"], claude=True)
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
                command = proxy.session_command(17890, ["true"], claude=True)
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
                command = proxy.session_command(17890, [sys.executable, "-c", client], claude=True)
            subprocess.run(command, check=True, timeout=10)


class ServeForever(unittest.TestCase):
    def test_closing_the_listener_stops_the_loop_quietly(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            listener = host_run.listen(str(Path(tmp) / "s"))
            errors = []

            def serve():
                try:
                    host_run.Server(str(Path(tmp) / "s"), str(Path(tmp) / "none")).serve_forever(listener)
                except BaseException as e:  # noqa: BLE001
                    errors.append(e)

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            time.sleep(0.1)
            listener.close()
            thread.join(3)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()


class FreshHome(unittest.TestCase):
    """Новый пользователь: ни ~/.config/mnrh, ни ~/.config/agentmeister еще нет, host-run берет папки agentmeister."""

    BIN = str(Path(host_run.__file__).resolve().parents[3] / "bin" / "agentmeister")

    def setUp(self):
        self.home = tempfile.mkdtemp(dir="/tmp", prefix="hr-")  # короткий путь: у сокета предел длины
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("XDG_", "MNRH_", "AGENTMEISTER_")) and k.lower() not in
                    ("https_proxy", "http_proxy", "all_proxy", "no_proxy")}
        self.env.update(HOME=self.home, PYTHONDONTWRITEBYTECODE="1")

    def tearDown(self):
        subprocess.run([self.BIN, "host-run", "stop"], env=self.env, capture_output=True, timeout=20)
        import shutil
        shutil.rmtree(self.home, True)

    def cli(self, *args, timeout=30):
        return subprocess.run([self.BIN, "host-run", *args], env=self.env, capture_output=True, text=True,
                              timeout=timeout, stdin=subprocess.DEVNULL)

    def test_default_paths_and_sandbox_rules(self):
        code = (f"import sys; sys.path.insert(0, {str(Path(host_run.__file__).parent)!r}); import host_run; "
                "print(host_run.CONF_DIR); print(host_run.STATE); print(' '.join(host_run.sandbox_params()))")
        out = subprocess.run([sys.executable, "-c", code], env=self.env, capture_output=True, text=True,
                             check=True).stdout.splitlines()
        home = os.path.realpath(self.home)
        self.assertEqual(out[0], f"{self.home}/.config/agentmeister/host-run")
        self.assertEqual(out[1], f"{self.home}/.local/state/agentmeister/host-run")
        self.assertIn(f"HOST_RUN_CONF={home}/.config/agentmeister/host-run", out[2])
        self.assertIn(f"HOST_RUN_STATE={home}/.local/state/agentmeister/host-run", out[2])
        self.assertNotIn("mnrh", out[2])

    @unittest.skipUnless(sys.platform == "darwin" and host_run.nested_sandbox_ok(), "requires running outside a sandbox")
    def test_runner_serves_a_new_user(self):
        conf = Path(self.home, ".config", "agentmeister", "host-run")
        conf.mkdir(parents=True)
        work = Path(self.home, "work")
        work.mkdir()
        write_commands(conf / "commands.json", {"hello": {"cwd": str(work), "run": ["/bin/echo", "hi from host-run"]}})
        (conf / "commands.json").chmod(0o600)
        runner = subprocess.Popen([self.BIN, "host-run", "serve"], env=self.env, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(lambda: runner.poll() is None and runner.kill())
        sock = Path(self.home, ".local", "state", "agentmeister", "host-run", "host-run.sock")
        deadline = time.time() + 15
        while not sock.exists() and time.time() < deadline and runner.poll() is None:
            time.sleep(0.2)
        self.assertTrue(sock.exists(), "the runner didn't open its socket")
        r = self.cli("hello")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("hi from host-run", r.stdout)
        self.assertFalse(Path(self.home, ".config", "mnrh").exists())
        self.assertFalse(Path(self.home, ".local", "state", "mnrh").exists())
