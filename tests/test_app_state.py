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
LIB = os.path.join(ROOT, "libexec", "agentmeister", "lib")
sys.path.insert(0, LIB)
import app_state  # noqa: E402


def isolate_codex(case):
    """Тесты не читают настоящий ~/.codex и не пишут в настоящий кэш."""
    tmp = tempfile.TemporaryDirectory()
    case.addCleanup(tmp.cleanup)
    for patcher in (patch.object(app_state, "CODEX_CACHE", os.path.join(tmp.name, "codex.json")),
                    patch.dict(os.environ, {"CODEX_HOME": os.path.join(tmp.name, "codex")})):
        patcher.start()
        case.addCleanup(patcher.stop)
    return tmp.name


def isolate_agents(case, keep=()):
    """collect() без настоящих ~/.claude.json, ~/.claude/settings.json, ~/.codex и сокета host-run: части,
    которые их читают, подменены. keep оставляет настоящими те, что тест проверяет сам."""
    parts = {"signed_in": {"signedIn": False, "plan": None}, "retention_days": 30, "agent_model": None,
             "host_run_summary": None}
    for name, value in parts.items():
        if name in keep:
            continue
        patcher = patch.object(app_state, name, return_value=value)
        patcher.start()
        case.addCleanup(patcher.stop)


class AppState(unittest.TestCase):
    def setUp(self):
        isolate_codex(self)
        isolate_agents(self)

    def test_broken_part_keeps_the_rest(self):
        with patch.object(app_state, "projects", return_value=[{"name": "kcalm", "path": "/w/kcalm"}]), \
             patch.object(app_state, "sessions", side_effect=RuntimeError("boom")), \
             patch.object(app_state, "live", return_value=[]), \
             patch.object(app_state, "proxy_state", return_value={"configured": False}), \
             patch.object(app_state, "modes", return_value={"humanize": True}):
            state = app_state.collect()
        self.assertEqual(state["projects"], [{"name": "kcalm", "path": "/w/kcalm"}])
        self.assertEqual(state["sessions"], [])
        self.assertIn("boom", state["errors"]["sessions"])
        self.assertEqual(state["modes"], {"humanize": True})
        self.assertNotIn("projects", state["errors"])

    def test_sessions_skip_unanswered_and_links(self):
        import session_store

        def row(sid, link=False):
            return {"id": sid, "path": f"/p/{sid}.jsonl", "extra": f"/p/{sid}", "link": link, "cwd": f"/w/{sid}",
                    "mtime": 1, "size": 1, "running": None, "transcript_version": (1, ord(sid), 1, 1, 1)}

        answered = {"/p/a.jsonl": True, "/p/b.jsonl": False, "/p/c.jsonl": True}

        def meta(path):
            return {"cwd": None, "branch": None, "custom": None, "ai": "t", "prompt": None, "answered": answered[path]}

        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(app_state, "META_CACHE", os.path.join(tmp, "sessions.json")), \
             patch.object(session_store, "load", return_value=[row("a"), row("b"), row("c", link=True)]), \
             patch.object(session_store, "read_meta", side_effect=meta):
            out = app_state.sessions()
        self.assertEqual([s["id"] for s in out], ["a"])
        self.assertEqual(out[0]["running"], False)

    def test_sessions_read_only_changed_transcripts(self):
        import session_store
        rows = [{"id": "a", "path": "/p/a.jsonl", "extra": "/p/a", "link": False, "cwd": "/w/a", "mtime": 2,
                 "size": 10, "running": None, "transcript_version": (1, 2, 10, 5, 5)},
                {"id": "b", "path": "/p/b.jsonl", "extra": "/p/b", "link": False, "cwd": "/w/b", "mtime": 1,
                 "size": 5, "running": None, "transcript_version": (1, 3, 5, 5, 5)}]
        meta = {"cwd": "/w/a", "branch": "main", "custom": None, "ai": "Тема", "prompt": None, "answered": True}
        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(app_state, "META_CACHE", os.path.join(tmp, "sessions.json")), \
             patch.object(session_store, "load", return_value=rows), \
             patch.object(session_store, "read_meta", return_value=meta) as read:
            first = app_state.sessions()
            self.assertEqual(read.call_count, 2)
            app_state.sessions()
            self.assertEqual(read.call_count, 2)
            rows[1]["transcript_version"] = (1, 3, 9, 6, 6)
            app_state.sessions()
            self.assertEqual(read.call_count, 3)
        self.assertEqual([s["title"] for s in first], ["Тема", "Тема"])
        self.assertEqual(first[0]["branch"], "main")

    def test_command_prints_json(self):
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=os.path.join(home, ".config"),
                       MNRH_PROJECTS=os.path.join(home, "Developer"))
            for name in ("CLAUDE_CONFIG_DIR", "MNRH_CLAUDE_HOME"):  # иначе прочтет настоящие файлы Claude Code
                env.pop(name, None)
            os.makedirs(os.path.join(home, "Developer", "kcalm"))
            out = subprocess.run([os.path.join(ROOT, "bin", "agentmeister"), "app-state"], capture_output=True,
                                 text=True, env=env, timeout=60, stdin=subprocess.DEVNULL)
        self.assertEqual(out.returncode, 0, out.stderr)
        state = json.loads(out.stdout)
        self.assertEqual([p["name"] for p in state["projects"]], ["kcalm"])
        for key in ("version", "lang", "sessions", "live", "proxy", "modes", "errors"):
            self.assertIn(key, state)


class SearchAndRead(unittest.TestCase):
    def setUp(self):
        # основы слов поиск кладет в свою папку кэша, тесты не должны трогать настоящую
        import claude_search
        self.tmp = tempfile.TemporaryDirectory()
        patcher = patch.object(claude_search, "INDEX", self.tmp.name)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)

    def index(self):
        return {"11111111-2222-3333-4444-555555555555": {
            "path": "/c/projects/-w-app/11111111-2222-3333-4444-555555555555.jsonl",
            "ai": "Сборка релиза", "first": "2026-11-20T10:00:00Z", "last": "2026-11-20T11:00:00Z",
            "msgs": [["user", "2026-11-20T10:00:00Z", "почини сборку релиза"],
                     ["claude", "2026-11-20T10:05:00Z", "Сборка релиза падала на подписи, поправил fastlane"],
                     ["tool", "2026-11-20T10:06:00Z", "$ bundle exec fastlane release"]]}}

    def test_empty_query_returns_no_results(self):
        out = app_state.search("   ")
        self.assertEqual(out["results"], [])

    def test_search_returns_sessions_with_snippets(self):
        import claude_search
        idx = self.index()
        with patch.object(claude_search, "refresh", return_value=idx), \
             patch.object(claude_search, "home_of", return_value="/w/app"):
            out = app_state.search("сборки релиза")
        self.assertTrue(out["exact"])
        self.assertEqual(len(out["results"]), 1)
        r = out["results"][0]
        self.assertEqual(r["title"], "Сборка релиза")
        self.assertEqual(r["home"], "/w/app")
        self.assertGreater(r["last"], 0)
        self.assertTrue(any("релиза" in h["snippet"] for h in r["hits"]))

    def test_read_returns_last_messages(self):
        import claude_search
        with patch.object(claude_search, "refresh", return_value=self.index()), \
             patch.object(claude_search, "home_of", return_value="/w/app"):
            out = app_state.read("11111111", tail=2)
            missing = app_state.read("99999999")
        self.assertEqual(out["total"], 3)
        self.assertEqual([m["at"] for m in out["messages"]], [1, 2])
        self.assertEqual(out["messages"][1]["role"], "tool")
        self.assertIn("error", missing)


class Usage(unittest.TestCase):
    def test_usage_sums_projects_models_and_days(self):
        import claude_search
        import claude_usage
        day = time.mktime((2026, 11, 23, 23, 0, 0, 0, 0, -1))
        rows = [{"sid": "a", "data": {"spans": [[day, day + 7200]], "ai": "Сборка"}, "active": 7200.0, "last": day + 7200,
                 "models": {"opus": [10, 20, 300, 40, 5]}, "total": 370},
                {"sid": "b", "data": {"spans": [[day + 3600, day + 5400]], "prompt": "тест"}, "active": 1800.0,
                 "last": day + 5400, "models": {"opus": [1, 2, 3, 4, 1]}, "total": 10}]
        homes = {"a": "/w/app", "b": "/w/app"}
        with patch.object(claude_usage, "collect", return_value=rows), \
             patch.object(claude_usage, "period_start", return_value=day - 86400), \
             patch.object(claude_search, "home_of", side_effect=lambda d: "/w/app"), \
             patch.object(claude_search, "folder", side_effect=lambda d: "app"):
            out = app_state.usage(7)
        self.assertEqual(out["sessions"], 2)
        self.assertEqual(out["active"], 9000.0)
        self.assertEqual(out["requests"], 6)
        self.assertEqual(out["tokens"], [11, 22, 303, 44])
        self.assertEqual(out["projects"][0]["sessions"], 2)
        self.assertEqual(out["heavy"][0]["title"], "Сборка")
        self.assertEqual(out["heavy"][0]["output"], 20)
        # два часа с 23:00 делятся полуночью на два дня
        self.assertEqual(sum(d["active"] for d in out["daily"]), 9000.0)
        self.assertEqual(len(out["daily"]), 2)
        self.assertEqual(out["daily"][0]["active"], 3600.0)


class SettingsAndDoctor(unittest.TestCase):
    def test_doctor_rows_keep_going_after_a_crash(self):
        import claude_doctor

        def check_ok():
            return [("ok", "все хорошо")]

        def check_boom():
            raise RuntimeError("boom")

        with patch.object(claude_doctor, "CHECKS", [check_ok, check_boom]):
            rows = app_state.doctor()["rows"]
        self.assertEqual(rows[0], {"check": "ok", "level": "ok", "text": "все хорошо"})
        self.assertEqual(rows[1]["level"], "bad")
        self.assertIn("boom", rows[1]["text"])

    def test_settings_report_a_broken_part_and_keep_the_rest(self):
        import claude_guard
        import host_run
        with patch.object(app_state, "agent_info", return_value={"installed": False, "path": None, "version": None}), \
             patch.object(host_run, "ping", return_value=None), patch.object(host_run, "load", return_value={}), \
             patch.object(app_state, "proxy_state", side_effect=RuntimeError("no proxy")), \
             patch.object(app_state, "modes", return_value={"guard": True}), \
             patch.object(claude_guard, "skipped", return_value={"destructive"}):
            out = app_state.settings()
        self.assertIsNone(out["proxy"])
        self.assertIn("no proxy", out["errors"]["proxy"])
        rules = {r["id"]: r["on"] for r in out["guard"]["rules"]}
        self.assertFalse(rules["destructive"])
        self.assertTrue(rules["secrets-read"])
        self.assertIn("after", out["notify"])
        self.assertFalse(out["claude"]["installed"])


class SignedIn(unittest.TestCase):
    def test_sign_in_comes_from_the_agents_own_files(self):
        with tempfile.TemporaryDirectory() as home:
            with patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": home, "CODEX_HOME": os.path.join(home, ".codex")}):
                self.assertEqual(app_state.signed_in("claude"), {"signedIn": False, "plan": None})
                with open(os.path.join(home, ".claude.json"), "w") as f:
                    json.dump({"oauthAccount": {"billingType": "stripe_subscription", "organizationType": "claude_max",
                                                "emailAddress": "me@example.com"}}, f)
                self.assertEqual(app_state.signed_in("claude"), {"signedIn": True, "email": "me@example.com", "plan": "Max"})
                os.makedirs(os.path.join(home, ".codex"))
                with open(os.path.join(home, ".codex", "auth.json"), "w") as f:
                    json.dump({"auth_mode": "chatgpt", "tokens": {"id_token": "x"}}, f)
                self.assertEqual(app_state.signed_in("codex"), {"signedIn": True, "email": None, "plan": "ChatGPT"})


class Models(unittest.TestCase):
    def setUp(self):
        isolate_codex(self)
        isolate_agents(self, keep=("agent_model",))

    def test_collect_reports_the_model_of_each_agent(self):
        with tempfile.TemporaryDirectory() as home:
            codex = os.path.join(home, ".codex")
            os.makedirs(codex)
            with open(os.path.join(home, "settings.json"), "w") as f:
                json.dump({"model": "opus", "effortLevel": "high"}, f)
            with open(os.path.join(codex, "config.toml"), "w") as f:
                f.write('model = "gpt-5.5"\nmodel_reasoning_effort = "high"\n\n[profiles.fast]\nmodel = "gpt-5-mini"\n')
            with patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": home, "CODEX_HOME": codex}), \
                 patch.object(app_state, "codex_sessions", return_value=[]), \
                 patch.object(app_state, "projects", return_value=[]), \
                 patch.object(app_state, "sessions", return_value=[]), \
                 patch.object(app_state, "live", return_value=[]), \
                 patch.object(app_state, "proxy_state", return_value=None), \
                 patch.object(app_state, "modes", return_value={}), \
                 patch.object(app_state, "host_run_summary", return_value=None):
                state = app_state.collect()
                self.assertEqual(state["models"], {"claude": "opus high", "codex": "gpt-5.5 high"})
                os.remove(os.path.join(codex, "config.toml"))
                self.assertEqual(app_state.collect()["models"]["codex"], None)


class CodexSessions(unittest.TestCase):
    SID = "01a20d90-9260-7593-b017-582ceb5058cb"

    def setUp(self):
        self.tmp = isolate_codex(self)
        isolate_agents(self)
        self.home = os.environ["CODEX_HOME"]
        self.project = os.path.join(self.tmp, "app")
        os.makedirs(self.project)

    def rollout(self, sid, lines, day="2026/11/24", source="cli"):
        folder = os.path.join(self.home, "sessions", *day.split("/"))
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, f"rollout-2026-11-24T12-38-28-{sid}.jsonl")
        meta = {"timestamp": "2026-11-24T12:38:28.263Z", "type": "session_meta",
                "payload": {"id": sid, "session_id": sid, "cwd": self.project, "source": source,
                            "timestamp": "2026-11-24T12:38:28.263Z", "git": {"branch": "main"}}}
        with open(path, "w") as f:
            for row in [meta] + lines:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
        return path

    @staticmethod
    def msg(role, text, ts="2026-11-24T12:39:00.000Z"):
        return {"timestamp": ts, "type": "response_item",
                "payload": {"type": "message", "role": role, "content": [{"type": "input_text", "text": text}]}}

    @staticmethod
    def done(kind, text, ts="2026-11-24T12:39:00.000Z", **extra):
        item = {"type": kind, "id": "x", "content": [{"type": "text", "text": text}], **extra}
        return {"timestamp": ts, "type": "event_msg", "payload": {"type": "item_completed", "item": item}}

    def test_answered_threads_with_title_branch_and_agent(self):
        self.rollout(self.SID, [self.msg("user", "# AGENTS.md instructions for /x"),
                                self.msg("user", "<environment_context>…</environment_context>"),
                                self.msg("user", "почини  сборку\nрелиза"), self.msg("assistant", "Поправил.")])
        # без ответа Codex и треды субагентов в список не идут
        self.rollout("01a20d90-0000-7593-b017-582ceb5058cb", [self.msg("user", "привет")])
        self.rollout("01a20d90-1111-7593-b017-582ceb5058cb", [self.msg("user", "часть"), self.msg("assistant", "да")],
                     source={"subagent": {"thread_spawn": {}}})
        out = app_state.codex_sessions()
        self.assertEqual([s["id"] for s in out], [self.SID])
        s = out[0]
        self.assertEqual((s["agent"], s["cwd"], s["branch"], s["title"]), ("codex", self.project, "main", "почини сборку релиза"))
        self.assertTrue(s["cwdExists"])
        self.assertGreater(s["created"], 0)
        with open(os.path.join(self.home, "session_index.jsonl"), "w") as f:
            f.write(json.dumps({"id": self.SID, "thread_name": "Старое"}) + "\n")
            f.write(json.dumps({"id": self.SID, "thread_name": "Сборка релиза"}) + "\n")
        self.assertEqual(app_state.codex_sessions()[0]["title"], "Сборка релиза")

    def test_known_threads_are_not_parsed_again(self):
        path = self.rollout(self.SID, [self.done("UserMessage", "сделай тесты"), self.done("AgentMessage", "Сделал")])
        self.assertEqual(app_state.codex_sessions()[0]["title"], "сделай тесты")
        with open(path, "a") as f:
            f.write(json.dumps(self.done("AgentMessage", "еще")) + "\n")
        with patch.object(app_state, "codex_meta") as meta:
            out = app_state.codex_sessions()
        meta.assert_not_called()
        self.assertEqual(out[0]["size"], os.path.getsize(path))

    def test_collect_keeps_codex_apart_from_claude_sessions(self):
        self.rollout(self.SID, [self.msg("user", "вопрос"), self.msg("assistant", "ответ")])
        claude = [{"id": "c1", "agent": "claude", "mtime": 200.0}]
        with patch.object(app_state, "projects", return_value=[]), \
             patch.object(app_state, "sessions", return_value=claude), \
             patch.object(app_state, "live", return_value=[]), \
             patch.object(app_state, "proxy_state", return_value=None), \
             patch.object(app_state, "modes", return_value={}), \
             patch.object(app_state, "host_run_summary", return_value=None):
            state = app_state.collect()
            with patch.object(app_state, "codex_sessions", side_effect=RuntimeError("bad rollout")):
                broken = app_state.collect()
        # старое приложение читает только sessions и не примет тред Codex за сессию Claude Code
        self.assertEqual([s["id"] for s in state["sessions"]], ["c1"])
        self.assertEqual([s["id"] for s in state["codexSessions"]], [self.SID])
        self.assertNotIn("path", state["codexSessions"][0])
        self.assertEqual(broken["codexSessions"], [])
        self.assertIn("bad rollout", broken["errors"]["codexSessions"])
        self.assertEqual(broken["sessions"], claude)

    def test_read_returns_codex_messages(self):
        self.rollout(self.SID, [self.done("UserMessage", "запусти тесты", "2026-11-24T12:39:00.000Z"),
                                self.done("CommandExecution", "", command=["/bin/zsh", "-lc", "make test"],
                                          parsed_cmd=[{"type": "unknown", "cmd": "make test"}]),
                                self.msg("assistant", "сырой ответ"),
                                self.done("AgentMessage", "Все прошло", "2026-11-24T12:40:00.000Z")])
        out = app_state.read(self.SID, tail=2)
        self.assertEqual(out["agent"], "codex")
        self.assertEqual(out["total"], 3)
        self.assertEqual([(m["role"], m["text"]) for m in out["messages"]], [("tool", "$ make test"), ("codex", "Все прошло")])
        self.assertEqual(out["home"], self.project)

    def test_malformed_lines_are_skipped(self):
        bad = ['{"type":"event_msg","payload":"item_completed"}', '["item_completed"]',
               '{"type":"event_msg","payload":{"type":"item_completed","item":"x"}}',
               '{"type":"response_item","payload":["message"]}', '{"item_completed": ']
        path = self.rollout(self.SID, [self.done("UserMessage", "запусти тесты")])
        with open(path, "a") as f:
            for line in bad:
                f.write(line + "\n")
            f.write(json.dumps(self.done("CommandExecution", "", command=["make", "test"], parsed_cmd=5)) + "\n")
            f.write(json.dumps(self.done("AgentMessage", "Все прошло")) + "\n")
        # раньше первая же такая строка роняла разбор, и список тредов Codex приходил пустым
        self.assertEqual([s["id"] for s in app_state.codex_sessions()], [self.SID])
        out = app_state.read(self.SID, tail=5)
        self.assertEqual([(m["role"], m["text"]) for m in out["messages"]],
                         [("user", "запусти тесты"), ("tool", "$ make test"), ("codex", "Все прошло")])

    def test_old_thread_outside_the_list_is_still_readable(self):
        old = "01a20d90-2222-7593-b017-582ceb5058cb"
        path = self.rollout(old, [self.done("UserMessage", "старый вопрос"), self.done("AgentMessage", "старый ответ")],
                            day="2025/01/02")
        os.utime(path, (1, 1))
        self.rollout(self.SID, [self.done("UserMessage", "новый"), self.done("AgentMessage", "да")])
        with patch.object(app_state, "SESSION_LIMIT", 1):
            self.assertEqual([s["id"] for s in app_state.codex_sessions()], [self.SID])
            with patch.object(app_state, "codex_sessions", side_effect=AssertionError("full scan")):
                out = app_state.read(old, tail=1)
        self.assertEqual((out["agent"], out["title"], out["total"]), ("codex", "старый вопрос", 2))
        self.assertEqual([(m["at"], m["text"]) for m in out["messages"]], [(1, "старый ответ")])

    def test_claude_id_is_read_from_claude_sessions_first(self):
        import claude_search
        sid = "11111111-2222-4333-8444-555555555555"
        idx = {sid: {"path": "/c/x.jsonl", "ai": "Claude", "first": None, "last": None,
                     "msgs": [["user", "2026-11-20T10:00:00Z", "привет"]]}}
        with patch.object(claude_search, "refresh", return_value=idx), \
             patch.object(claude_search, "home_of", return_value="/w/app"), \
             patch.object(app_state, "codex_read", side_effect=AssertionError("codex first")):
            self.assertEqual(app_state.read(sid)["total"], 1)
        # v4 id, которого нет среди сессий Claude Code, все равно ищется среди тредов Codex
        other = "01a20d90-3333-4593-b017-582ceb5058cb"
        self.rollout(other, [self.done("UserMessage", "вопрос"), self.done("AgentMessage", "ответ")])
        with patch.object(claude_search, "refresh", return_value=idx):
            self.assertEqual(app_state.read(other)["agent"], "codex")
            self.assertIn("error", app_state.read("01a20d90-4444-4593-b017-582ceb5058cb"))


class Lang(unittest.TestCase):
    def test_set_and_auto(self):
        with tempfile.TemporaryDirectory() as d:
            conf = os.path.join(d, "config")
            with open(conf, "w") as f:
                f.write("projects=~/dev\n")
            with patch.object(app_state.mnrhlib, "CONFIG", conf), \
                    patch.object(app_state.mnrhlib, "system_english", return_value=True), \
                    patch("sys.stdout"):
                self.assertEqual(app_state.lang_setting(), "auto")
                self.assertEqual(app_state.set_lang("ru"), 0)
                self.assertEqual(app_state.lang_setting(), "ru")
                self.assertEqual(app_state.mnrhlib.lang(), "ru")
                self.assertEqual(app_state.set_lang("auto"), 0)
                self.assertEqual(app_state.lang_setting(), "auto")
                self.assertEqual(app_state.mnrhlib.lang(), "en")
                self.assertEqual(app_state.set_lang("de"), 2)
            with open(conf) as f:
                self.assertEqual(f.read(), "projects=~/dev\n")



class Project(unittest.TestCase):
    def test_project_reads_git_and_backlog(self):
        import subprocess
        with tempfile.TemporaryDirectory() as d:
            repo = os.path.join(d, "demo")
            os.makedirs(repo)
            run = lambda *a: subprocess.run(["git", "-C", repo, *a], check=True, capture_output=True)
            run("init", "-q", "-b", "main")
            run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "first")
            open(os.path.join(repo, "new.txt"), "w").close()
            import mnrh_todo
            with patch.object(mnrh_todo, "TODO_DIR", os.path.join(d, "todo")):
                mnrh_todo.add(repo, "write the screen")
                out = app_state.project(repo)
        self.assertEqual(out["git"]["branch"], "main")
        self.assertEqual(out["git"]["dirty"], 1)
        self.assertEqual(out["git"]["commits"][0]["subject"], "first")
        self.assertEqual(out["todos"], [{"n": 1, "text": "write the screen", "done": False}])
        self.assertEqual(out["parallel"], [])
        self.assertFalse(out["tools"]["gradle"])


if __name__ == "__main__":
    unittest.main()
