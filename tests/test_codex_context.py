import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "libexec/agentmeister/lib"))
import codex_context as c

SID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"


class Context(unittest.TestCase):
    def test_project_instructions_and_selected_memory(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp).resolve()
            home, project = base / "codex", base / "repo"
            memory = home / "memories"
            (memory / "notes").mkdir(parents=True)
            (memory / ".git").mkdir()
            (memory / ".git/hidden.md").write_text("hidden")
            (memory / "notes/feature.md").write_text("remember this")
            (memory / "linked.md").symlink_to(base / "private.txt")
            (base / "private.txt").write_text("private")
            (project / "module").mkdir(parents=True)
            subprocess.run(["git", "init", "-q", str(project)], check=True)
            (home / "AGENTS.md").write_text("global rule")
            (project / "AGENTS.md").write_text("root rule")
            (project / "module/AGENTS.md").write_text("ordinary rule")
            (project / "module/AGENTS.override.md").write_text("override rule")
            with patch.dict(os.environ, CODEX_HOME=str(home)):
                result = c.context({"section": "instructions", "project": str(project / "module")})["text"]
                self.assertLess(result.index("global rule"), result.index("root rule"))
                self.assertLess(result.index("root rule"), result.index("override rule"))
                self.assertNotIn("ordinary rule", result)
                self.assertEqual(c.context({"section": "memories"})["text"], "notes/feature.md")
                self.assertEqual(c.context({"section": "memory", "note": "notes/feature.md"})["text"], "remember this")
                for path in ("../private.txt", "linked.md", ".git/hidden.md", str(base / "private.txt")):
                    self.assertTrue(c.handle({"section": "memory", "note": path})[1])

    def test_read_pages_keep_text_and_skip_internal_items(self):
        items = [
            {"type": "userMessage", "content": [{"type": "text", "text": "Question"}, {"type": "image"}]},
            {"type": "plan", "text": "Review design"},
            {"type": "reasoning", "content": ["private"]},
            {"type": "commandExecution", "aggregatedOutput": "private"},
            {"type": "fileChange", "status": "completed", "changes": [
                {"kind": {"type": "update", "move_path": "b.py"}, "path": "a.py", "diff": "private"}]},
            {"type": "agentMessage", "text": "Answer"},
        ]
        with patch.object(c, "executable", return_value="codex"), patch.object(c, "app_server") as server:
            rpc = server.return_value.__enter__.return_value

            def request(method, args):
                if method == "thread/read":
                    return {"thread": {"cwd": "/project", "gitInfo": {"branch": "feature", "sha": "abc"}}}
                self.assertEqual(method, "thread/turns/list")
                if args.get("cursor") == "older":
                    return {"data": [], "nextCursor": None}
                return {"data": [{"id": "turn", "status": "completed", "items": items}], "nextCursor": "older"}

            rpc.side_effect = request
            with patch.object(c, "PAGE_SIZE", 20):
                page = c.context({"section": "read", "session": SID})
                self.assertEqual(page["branch"], "feature")
                text = page["text"]
                while page["next"].get("offset"):
                    page = c.context(page["next"])
                    text += page["text"]
                self.assertEqual(page["next"]["cursor"], "older")
                self.assertNotIn("next", c.context(page["next"]))
                self.assertNotIn("private", text)
                for snippet in ("Question", "Review design", "a.py", "b.py", "Answer"):
                    self.assertIn(snippet, text)

    def test_protocol_and_cli_read_the_same_note(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / "memories"
            folder.mkdir()
            (folder / "MEMORY.md").write_text("project decision")
            env = dict(os.environ, CODEX_HOME=tmp)
            cli = str(ROOT / "bin/agentmeister")
            args = {"section": "memory", "note": "MEMORY.md"}
            msg = {"id": 1, "method": "tools/call", "params": {"name": "codex_context", "arguments": args}}
            rpc = subprocess.run([cli, "mcp"], env=env, text=True, input=json.dumps(msg) + "\n",
                                 capture_output=True, check=True)
            result = json.loads(rpc.stdout)["result"]
            self.assertFalse(result["isError"])
            shell = subprocess.check_output([cli, "codex-context", "memory", "MEMORY.md"], env=env, text=True)
            self.assertEqual(json.loads(shell), json.loads(result["content"][0]["text"]))
            self.assertEqual(json.loads(shell)["text"], "project decision")
