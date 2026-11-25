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
            self.assertEqual(agent_update.installed_via("codex", npm), "other")

    def test_shim_in_front_is_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            shim_dir = Path(tmp) / "local"
            shim_dir.mkdir()
            shim = shim_dir / "codex"
            shim.write_text("#!/usr/bin/env python3\n")
            shim.chmod(0o755)
            real = self.link(tmp, "Caskroom/codex/0.1.0/codex")
            path = os.pathsep.join([str(shim_dir), str(Path(real).parent)])
            with patch.dict(os.environ, {"PATH": path}):
                self.assertEqual(agent_update.binary_path("codex"), real)
            with patch.dict(os.environ, {"PATH": str(shim_dir)}):
                self.assertEqual(agent_update.binary_path("codex"), str(shim))  # другого нет, берем обертку

    def test_missing_agent(self):
        with patch.object(agent_update, "binary_path", return_value=None):
            self.assertIsNone(agent_update.update_argv("codex"))


if __name__ == "__main__":
    unittest.main()
