import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "libexec/agentmeister/lib"))
import agent_update


class UpdateCommand(unittest.TestCase):
    def link(self, tmp, target):
        target = Path(tmp) / target
        target.parent.mkdir(parents=True)
        target.write_text("#!/bin/sh\n")
        target.chmod(0o755)
        link = Path(tmp) / "bin" / target.name
        link.parent.mkdir(exist_ok=True)
        link.symlink_to(target)
        return str(link)

    def test_homebrew_cask_and_formula_use_brew_upgrade(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(agent_update, "brew", return_value="brew"):
            cask = self.link(tmp, "Caskroom/claude-code/2.1.0/claude")
            self.assertEqual(agent_update.update_argv("claude", cask), ["brew", "upgrade", "--cask", "claude-code"])
            self.assertEqual(agent_update.installed_via("claude", cask), "homebrew")
            formula = self.link(tmp, "Cellar/codex/0.1.0/bin/codex")
            self.assertEqual(agent_update.update_argv("codex", formula), ["brew", "upgrade", "codex"])

    def test_other_installs_update_themselves(self):
        with tempfile.TemporaryDirectory() as tmp:
            installer = self.link(tmp, ".local/share/claude/versions/2.1.0/claude")
            self.assertEqual(agent_update.update_argv("claude", installer), [installer, "update"])
            self.assertEqual(agent_update.installed_via("claude", installer), "installer")
            npm = self.link(tmp, "lib/node_modules/@openai/codex/bin/codex")
            self.assertEqual(agent_update.update_argv("codex", npm), [npm, "update"])
            self.assertEqual(agent_update.installed_via("codex", npm), "npm")

    def test_shim_in_front_is_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            shim_dir = Path(tmp) / "local"
            shim_dir.mkdir()
            shim = shim_dir / "codex"
            shim.write_text("#!/usr/bin/env python3\n# promptsill wrapper\n")
            shim.chmod(0o755)
            real = self.link(tmp, "Caskroom/codex/0.1.0/codex")
            path = os.pathsep.join([str(shim_dir), str(Path(real).parent)])
            with patch.dict(os.environ, {"PATH": path}):
                self.assertEqual(agent_update.binary_path("codex"), real)
            with patch.dict(os.environ, {"PATH": str(shim_dir)}):
                self.assertEqual(agent_update.binary_path("codex"), str(shim))  # другого нет, берем обертку

    def test_check_compares_with_the_source_of_the_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            cask = self.link(tmp, "Caskroom/claude-code/2.1.0/claude")
            urls = []

            def fake(url):
                urls.append(url)
                return {"version": "2.1.10,abc"}

            with patch.object(agent_update, "binary_path", return_value=cask), \
                    patch.object(agent_update, "version", return_value="2.1.9"), \
                    patch.object(agent_update, "fetch_json", side_effect=fake), \
                    patch("sys.stdout") as out:
                agent_update.check("claude")
            result = json.loads("".join(call.args[0] for call in out.write.call_args_list))
            self.assertEqual(urls, ["https://formulae.brew.sh/api/cask/claude-code.json"])
            self.assertEqual((result["current"], result["latest"], result["update"]), ("2.1.9", "2.1.10", True))

    def test_versions_compare_as_numbers(self):
        self.assertGreater(agent_update.parse_version("0.172.0"), agent_update.parse_version("0.99.9"))
        self.assertEqual(agent_update.parse_version("2.1.325 (Claude Code)"), ((2, 1, 325), 1))
        self.assertLess(agent_update.parse_version("0.47.0-alpha.1"), agent_update.parse_version("0.47.0"))
        self.assertEqual(agent_update.parse_version("1.2.3b4"), ((1, 2, 3), 0))
        self.assertIsNone(agent_update.parse_version(""))

    def test_version_manager_from_homebrew_is_not_the_agent(self):
        with tempfile.TemporaryDirectory() as tmp:
            mise = self.link(tmp, "Cellar/mise/2025.1.0/bin/mise")
            self.assertIsNone(agent_update.brew_package(os.path.realpath(mise), "claude"))
            self.assertEqual(agent_update.update_argv("claude", mise), [mise, "update"])
            npm = self.link(tmp, "opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js")
            self.assertEqual(agent_update.installed_via("claude", npm), "npm")

    def test_only_known_wrappers_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            plain = Path(tmp) / "pnpm-claude"
            plain.write_text("#!/bin/sh\nexec node cli.js \"$@\"\n")
            wrapper = Path(tmp) / "codex"
            wrapper.write_text("#!/usr/bin/env python3\nPROFILE = 'Codex with promptsill'\n")
            self.assertFalse(agent_update.is_shim(str(plain)))
            self.assertTrue(agent_update.is_shim(str(wrapper)))

    def test_missing_agent(self):
        with patch.object(agent_update, "binary_path", return_value=None):
            self.assertIsNone(agent_update.update_argv("codex"))


if __name__ == "__main__":
    unittest.main()
