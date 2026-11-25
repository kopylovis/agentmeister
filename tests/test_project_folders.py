import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "libexec/agentmeister/lib"))
import mnrhlib


class ProjectFolders(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        for folder, name in (("A", "backend"), ("B", "backend"), ("B", "web")):
            (base / folder / name / ".git").mkdir(parents=True)
        self.a, self.b = str(base / "A"), str(base / "B")

    def test_folders_parse_like_path(self):
        with patch.dict(os.environ, {"MNRH_PROJECTS": f"{self.a}::{self.b}:{self.a}"}):
            self.assertEqual(mnrhlib.projects_dirs(), [self.a, self.b])
            self.assertEqual(mnrhlib.projects_dir(), self.a)

    def test_same_name_in_two_folders_keeps_both(self):
        with patch.object(mnrhlib, "DEVS", [self.a, self.b]):
            folders = mnrhlib.project_folders()
            self.assertEqual([mnrhlib.project_label(p, folders) for p in folders], ["backend · A", "backend · B", "web"])
            path, error = mnrhlib.find_project("backend")
            self.assertIsNone(path)
            self.assertIn("укажи путь", error)
            self.assertEqual(mnrhlib.find_project("web")[0], os.path.join(self.b, "web"))
            self.assertEqual(mnrhlib.project_name(os.path.join(self.b, "web")), "web")

    def test_cli_refuses_a_project_as_a_folder_of_projects(self):
        env = dict(os.environ, XDG_CONFIG_HOME=self.tmp.name, PYTHONDONTWRITEBYTECODE="1")
        env.pop("MNRH_PROJECTS", None)
        cli = [sys.executable, str(ROOT / "libexec/agentmeister/lib/app_state.py"), "projects-dir"]
        r = subprocess.run(cli + ["add", os.path.join(self.a, "backend")], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        r = subprocess.run(cli + ["add", self.b], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        config = Path(self.tmp.name, "mnrh", "config").read_text()
        self.assertIn(":" + mnrhlib.tilde(self.b), config)


if __name__ == "__main__":
    unittest.main()
