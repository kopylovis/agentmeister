import os
from pathlib import Path
import subprocess
import tempfile
import unittest


CLI = Path(__file__).resolve().parents[1] / "bin" / "agentmeister"


class InstallCodex(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.env = dict(os.environ, HOME=temp.name, PATH=f"{temp.name}:/usr/bin:/bin")

    def command(self, name, script):
        path = self.home / name
        path.write_text("#!/bin/sh\n" + script)
        path.chmod(0o755)

    def install(self, *args):
        return subprocess.run([CLI, "--harness", "codex", "install", *args], env=self.env,
                              capture_output=True, text=True)

    def test_install_and_repeat(self):
        self.command("brew", """test "$*" = 'install --cask codex' || exit 2
echo '#!/bin/sh' > "$HOME/codex"
echo 'test "$1" = --version && echo codex-fixture' >> "$HOME/codex"
chmod +x "$HOME/codex"
""")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("codex-fixture", result.stdout)
        self.command("brew", "exit 7")
        self.assertEqual(self.install().returncode, 0)

    def test_failure_and_help(self):
        self.assertEqual(self.install("--help").returncode, 0)
        self.assertEqual(self.install("--unknown").returncode, 2)
        self.assertNotEqual(self.install().returncode, 0)
        self.command("brew", "exit 7")
        self.assertEqual(self.install().returncode, 7)
        self.command("brew", "exit 0")
        self.assertNotEqual(self.install().returncode, 0)
