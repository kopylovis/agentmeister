import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "libexec" / "agentmeister" / "lib"))
import codex_harness
import codex_sessions
import open_flow


class CodexHarness(unittest.TestCase):
    def test_mcp_rename_moves_user_settings_in_one_versioned_write(self):
        legacy = {"command": "/tmp/claudemeister", "args": ["mcp"], "enabled": False,
                  "disabled_tools": ["todo_add"], "env": {"MODE": "test"}}
        config = {"mcp_servers": {"claudemeister": legacy}}
        layer = {"name": {"type": "user"}, "version": "previous", "config": config}
        with patch.object(codex_harness, "app_server") as server:
            request = server.return_value.__enter__.return_value
            request.side_effect = [{"layers": [layer], "config": config}, {"status": "ok"}]
            codex_harness.migrate_codex_mcp("codex", False)
            method, params = request.call_args.args
        self.assertEqual(method, "config/batchWrite")
        self.assertEqual(params["expectedVersion"], "previous")
        self.assertEqual([(edit["keyPath"], edit["value"]) for edit in params["edits"]],
                         [("mcp_servers.agentmeister", dict(legacy, command=codex_harness.CM,
                                                             args=codex_harness.MCP_ARGS)),
                          ("mcp_servers.claudemeister", None)])

    def test_launch_isolates_direct_and_vps_sessions_from_shared_daemon(self):
        sid = "11111111-2222-4333-8444-555555555555"
        for network in ("-d", "-x"):
            with self.subTest(network=network), \
                    patch("proxy.configured", return_value=True), \
                    patch.object(subprocess, "run", return_value=subprocess.CompletedProcess(
                        [], 0, stdout="Usage: codex [OPTIONS]\n  --no-daemon\n")), \
                    patch.object(os, "execvpe") as execute:
                args, passthrough = codex_harness.launch_args(["-n", network, "--", "resume", sid])
                codex_harness.launch("codex", args, passthrough)
                command = execute.call_args.args[1]
                self.assertEqual(command[-4:], ["codex", "--no-daemon", "resume", sid])

    def test_launch_keeps_older_codex_and_explicit_no_daemon_working(self):
        for help_result, forwarded, expected in (
                (subprocess.CompletedProcess([], 0, stdout="Usage: codex [OPTIONS]\n"), [], []),
                (subprocess.TimeoutExpired("codex", 5), [], []),
                (subprocess.CompletedProcess([], 0, stdout="--no-daemon\n"),
                 ["--no-daemon"], ["--no-daemon"])):
            with self.subTest(forwarded=forwarded, help_result=help_result), \
                    patch.object(subprocess, "run", side_effect=[help_result]), \
                    patch.object(os, "execvpe") as execute:
                args, passthrough = codex_harness.launch_args(["-n", "-d", "--", *forwarded, "--version"])
                codex_harness.launch("codex", args, passthrough)
                self.assertEqual(execute.call_args.args[1], ["codex", *expected, "--version"])

    def test_direct_launch_drops_inherited_proxy_settings(self):
        proxy = {
            "HTTP_PROXY": "http://127.0.0.1:9",
            "HTTPS_PROXY": "http://127.0.0.1:9",
            "ALL_PROXY": "socks5h://127.0.0.1:9",
            "NO_PROXY": "localhost",
            "MNRH_PROXY": "9",
            "PROMPTSILL_PROXY_LABEL": "XX",
            "PROMPTSILL_PROXY_DETAIL": "vless 203.0.113.7",
            "PROMPTSILL_PROXY_URL": "file:///tmp/proxy.html",
        }
        proxy.update({name.lower(): value for name, value in list(proxy.items()) if name.endswith("_PROXY")
                      and name != "MNRH_PROXY"})
        with tempfile.TemporaryDirectory() as folder:
            codex = Path(folder) / "codex"
            codex.write_text(f"#!{sys.executable}\nimport json, os\n"
                             f"keys = {list(proxy) + ['OPENAI_BASE_URL']!r}\n"
                             "print(json.dumps({key: os.environ[key] for key in keys if key in os.environ}))\n")
            codex.chmod(0o755)
            env = {**os.environ, **proxy, "PATH": folder + os.pathsep + os.environ.get("PATH", ""),
                   "OPENAI_BASE_URL": "https://api.example.com/v1"}
            for flags in (["-d"], []):
                with self.subTest(flags=flags):
                    result = subprocess.run(
                        [sys.executable, codex_harness.__file__, folder, "-n", *flags, "--", "--version"],
                        env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True, timeout=5)
                    child = json.loads(result.stdout)
                    self.assertEqual({name: child[name] for name in proxy if name in child}, {} if flags else proxy)
                    self.assertEqual(child["OPENAI_BASE_URL"], env["OPENAI_BASE_URL"])

    def test_proxy_launch_keeps_the_proxy_wrapper(self):
        args, passthrough = codex_harness.launch_args(["-n", "-x", "--", "--version"])
        with patch("proxy.configured", return_value=True), \
                patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="Usage: codex")), \
                patch.object(os, "execvpe") as execute, patch.object(os, "execvp"):
            codex_harness.launch("codex", args, passthrough)
        command = execute.call_args.args[1]
        self.assertEqual(command[0], sys.executable)
        self.assertEqual(Path(command[1]).name, "proxy.py")
        self.assertEqual(command[2:], ["run", "--", "codex", "--version"])
        self.assertEqual(execute.call_args.args[2], dict(os.environ))

    def test_proxy_probe_failure_stops_launch(self):
        args, passthrough = codex_harness.launch_args(["-n", "-x", "--", "--version"])
        with patch("proxy.configured", return_value=True), \
                patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired("codex", 5)) as probe, \
                patch.object(os, "execvpe") as execute:
            with self.assertRaises(ValueError):
                codex_harness.launch("codex", args, passthrough)
        self.assertEqual(probe.call_args.args[0][0], "/usr/bin/sandbox-exec")
        execute.assert_not_called()

    def test_restart_presets_use_free_slots_and_remove_only_their_own(self):
        custom = {"label": "My restart", "input": "/quit"}
        user = {"9": custom}
        effective = {**user, "8": {"input": "/compact"}}
        result = {"layers": [{"name": {"type": "user"}, "config": {"tui": {"presets": user}}, "version": "old"}],
                  "config": {"tui": {"presets": effective}}}
        with patch.object(codex_harness, "app_server") as app_server:
            request = app_server.return_value.__enter__.return_value
            request.side_effect = [result, {"status": "ok"}]
            codex_harness.configure_restart_presets("codex", False)
            self.assertEqual(request.call_args.args, ("config/batchWrite", {
                "edits": [{"keyPath": f"tui.presets.{slot}", "mergeStrategy": "upsert", "value": preset}
                          for slot, preset in zip("76", codex_harness.RESTART_PRESETS)],
                "expectedVersion": "old",
            }))
            request.reset_mock()
            user.update(zip("76", codex_harness.RESTART_PRESETS))
            effective.update(user)
            request.side_effect = [result]
            codex_harness.configure_restart_presets("codex", False)
            request.assert_called_once_with("config/read", {"includeLayers": True})
            request.reset_mock()
            request.side_effect = [result, {"status": "ok"}]
            codex_harness.configure_restart_presets("codex", True)
            self.assertEqual(request.call_args.args, ("config/batchWrite", {
                "edits": [{"keyPath": f"tui.presets.{slot}", "mergeStrategy": "upsert", "value": None}
                          for slot in "76"],
                "expectedVersion": "old",
            }))

    def test_restart_queues_exact_session_and_preserves_proxy(self):
        sid = "11111111-2222-4333-8444-555555555555"
        with tempfile.TemporaryDirectory() as queue, \
                patch.dict(os.environ, {"CODEX_THREAD_ID": sid, "MNRH_RESTART_HOOK": "2", "MNRH_PROXY": "1"}), \
                patch.object(codex_harness, "RESTART_QUEUE", queue), \
                patch("notify.codex_terminal", return_value="/dev/ttys123"):
            self.assertEqual(codex_harness.restart("codex", ["--after-exit", "--update"]), 0)
            self.assertEqual(codex_harness.restart("codex", ["--after-exit", "--update"]), 0)
            job = json.loads((Path(queue) / "ttys123").read_text())
        self.assertEqual({k: job[k] for k in ("kind", "session", "update", "proxy", "cwd")},
                         {"kind": "codex", "session": sid, "update": True, "proxy": True, "cwd": os.getcwd()})
        import restart_job
        argv = restart_job.steps(restart_job.validate(job))[-1][0]
        self.assertEqual(argv[-5:], ["codex", "restart", sid, "--update", "--proxy"])

    def test_restart_passes_the_saved_id_to_codex(self):
        sid = "11111111-2222-4333-8444-555555555555"
        with patch.object(codex_harness, "launch") as launch:
            codex_harness.restart("codex", [sid])
        self.assertEqual(launch.call_args.args[2], ["resume", "-C", os.getcwd(), sid])

    def test_skill_setup_keeps_a_user_owned_skill(self):
        with tempfile.TemporaryDirectory() as home, patch.object(codex_harness, "HOME", home):
            path = Path(home) / ".agents" / "skills" / "agentmeister" / "SKILL.md"
            codex_harness.configure_skill(False)
            installed = path.read_text()
            self.assertIn(codex_harness.SKILL_OWNER, installed)
            codex_harness.configure_skill(False)
            self.assertEqual(path.read_text(), installed)
            path.write_text(codex_harness.SKILL_OWNER + "\nold version")
            codex_harness.configure_skill(False)
            self.assertEqual(path.read_text(), installed)
            codex_harness.configure_skill(True)
            self.assertFalse(path.exists())

            path.write_text("My own skill")
            codex_harness.configure_skill(False)
            codex_harness.configure_skill(True)
            self.assertEqual(path.read_text(), "My own skill")

    def test_resume_command_preserves_project_and_launch_options(self):
        sid = "11111111-2222-4333-8444-555555555555"
        state = {"dir": "/project path", "sid": sid, "mode": "normal", "net": "direct"}
        command = open_flow.command(state, "codex")
        args, forwarded = codex_harness.launch_args(command[2:])
        self.assertEqual(command[:2], ["--harness", "codex"])
        self.assertEqual((args.project, args.mode, args.net), ("/project path", "normal", "direct"))
        self.assertEqual(forwarded, ["resume", "-C", "/project path", sid])

    def test_renamed_project_keeps_old_session_path_without_duplicate_menu_item(self):
        with tempfile.TemporaryDirectory() as home:
            root = Path(home).resolve()
            project, alias = root / "new", root / "old"
            project.mkdir()
            alias.symlink_to(project, target_is_directory=True)
            self.assertEqual(codex_sessions.project_paths(str(project)), [str(project), str(alias)])
            self.assertEqual(open_flow.project_dirs(str(root)), [str(project)])

    def test_picker_lists_named_local_sessions(self):
        sid = "11111111-2222-4333-8444-555555555555"
        thread = {"id": sid, "cwd": "/project", "name": "First\n\x1bSecond", "preview": "A task"}
        with patch.object(codex_sessions, "list_threads", return_value=[thread, dict(thread, cwd="/other")]):
            items, describe, _, sessions = codex_sessions.session_list("/project")
        self.assertEqual(sessions, [{"id": sid}])
        self.assertEqual(items[1][1], "First Second")
        self.assertIn("A task", describe(1, 80))

    def test_failed_query_keeps_the_native_picker_available(self):
        with patch.object(codex_sessions, "list_threads", side_effect=OSError):
            _, _, _, sessions = codex_sessions.session_list("/project")
        self.assertEqual(sessions, [{"id": "resume"}])

    def test_install_and_remove_preserve_other_hooks(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {"CODEX_HOME": home}):
            path = Path(home) / "hooks.json"
            custom = {"hooks": [{"type": "command", "command": "/usr/bin/true"}]}
            original = {"hooks": {"UserPromptSubmit": [custom]}}
            path.write_text(json.dumps(original))
            self.assertEqual(codex_harness.configured_humanize_hooks(), 0)
            codex_harness.configure_hooks(False)
            installed = path.read_text()
            codex_harness.configure_hooks(False)
            self.assertEqual(path.read_text(), installed)
            groups = json.loads(installed)["hooks"]
            self.assertEqual(groups["UserPromptSubmit"][0], custom)
            self.assertEqual(set(groups), {event for events in codex_harness.HOOK_COMMANDS.values() for event in events})
            self.assertEqual(codex_harness.configured_humanize_hooks(), len(codex_harness.HOOK_EVENTS))
            self.assertEqual(codex_harness.configured_hooks("notify-hook"), len(codex_harness.NOTIFY_EVENTS))
            codex_harness.configure_hooks(True)
            self.assertEqual(json.loads(path.read_text()), original)

    def test_existing_tool_hooks_keep_their_matchers_on_setup(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {"CODEX_HOME": home}):
            path = Path(home) / "hooks.json"
            guard = {"type": "command", "command": "agentmeister guard-hook"}
            group = {"matcher": "Bash|Read|Edit|Write", "hooks": [guard]}
            path.write_text(json.dumps({"hooks": {"PreToolUse": [group]}}))
            codex_harness.configure_hooks(False)
            installed = json.loads(path.read_text())["hooks"]["PreToolUse"]
            self.assertEqual([g["matcher"] for g in installed if g["hooks"][0]["command"] == guard["command"]],
                             [group["matcher"]])
            self.assertEqual(codex_harness.configured_hooks("guard-hook"), 1)
            codex_harness.configure_hooks(True)
            self.assertEqual(json.loads(path.read_text())["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
                             guard["command"])

    def test_labels_apply_to_existing_agentmeister_hooks(self):
        def hook(command, **metadata):
            return {"type": "command", "command": command, **metadata}

        foreign = hook("/tmp/it2 handle-agent-hook")
        legacy = hook('"/tmp/with spaces/agentmeister" guard-hook')
        custom = hook("/tmp/claudemeister humanize-hook", statusMessage="My own label")
        hooks = {"PreToolUse": [{"matcher": "Bash", "hooks": [foreign, legacy, custom]}]}
        self.assertTrue(codex_harness.label_hooks(hooks))
        self.assertEqual(legacy["statusMessage"], "Agentmeister guard")
        self.assertEqual(custom["statusMessage"], "My own label")
        self.assertNotIn("statusMessage", foreign)
        self.assertFalse(codex_harness.label_hooks(hooks))
