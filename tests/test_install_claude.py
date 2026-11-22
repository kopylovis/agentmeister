import os
from pathlib import Path
import subprocess
import tempfile
import unittest


CLI = Path(__file__).resolve().parents[1] / "bin" / "agentmeister"


class InstallClaude(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.env = dict(os.environ, HOME=temp.name, PATH=f"{temp.name}:/usr/bin:/bin",
                        TMPDIR=temp.name, MNRH_CLAUDE_BIN="claude")
        self.curl = self.home / "curl"
        self.curl.write_text('#!/bin/sh\ncat "$HOME/payload"\nexit "${CURL_STATUS:-0}"\n')
        self.curl.chmod(0o755)
        (self.home / "payload").write_text("""\
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/claude" <<'CLI'
#!/bin/sh
test "$1" = --version && echo fixture-version
CLI
chmod +x "$HOME/.local/bin/claude"
""")

    def install(self, *args):
        return subprocess.run([CLI, "--harness", "claude", "install", *args], env=self.env,
                              capture_output=True, text=True)

    def test_install_and_repeat_outside_path(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fixture-version", result.stdout)
        self.assertIn("PATH", result.stdout)
        self.assertIn("Скачиваю установщик", result.stderr)
        self.assertIn("устанавливает Claude Code", result.stderr)
        self.env["CURL_STATUS"] = "22"
        self.assertEqual(self.install().returncode, 0)

    def test_failed_download_never_executes_partial_script(self):
        self.env["CURL_STATUS"] = "22"
        self.assertEqual(self.install().returncode, 22)
        self.assertFalse((self.home / ".local").exists())
        self.assertEqual(list(self.home.glob("agentmeister-install.*")), [])

    def test_installer_must_produce_working_cli(self):
        (self.home / "payload").write_text("exit 0\n")
        self.assertNotEqual(self.install().returncode, 0)
