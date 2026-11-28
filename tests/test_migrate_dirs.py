import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "libexec", "agentmeister", "lib")


def run(home, code, **env):
    full = {k: v for k, v in os.environ.items() if not k.startswith(("XDG_", "MNRH_", "AGENTMEISTER_"))}
    full.update(HOME=home, PYTHONDONTWRITEBYTECODE="1", **env)
    r = subprocess.run([sys.executable, "-c", f"import sys; sys.path.insert(0, {LIB!r})\n" + textwrap.dedent(code)],
                       env=full, capture_output=True, text=True)
    return r


class Migrate(unittest.TestCase):
    def home(self):
        home = tempfile.mkdtemp(prefix="cm-migrate-")
        for rel, text in {".config/mnrh/config": "lang=ru\n", ".config/mnrh/proxy/subscription.url": "x",
                          ".cache/mnrh/restart/ttys001": "{}", ".local/state/mnrh/lid.pid": "1",
                          ".local/state/mnrh/host-run/host-run.log": "", ".local/state/agentmeister/stray/x": ""}.items():
            path = os.path.join(home, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(text)
        return home

    def test_old_folders_are_used_until_migrated(self):
        home = self.home()
        r = run(home, "import mnrhlib; print(mnrhlib.CONFIG, mnrhlib.CACHE)")
        self.assertEqual(r.stdout.split(), [f"{home}/.config/mnrh/config", f"{home}/.cache/mnrh"])

    def test_migrate_moves_everything_but_lid_and_flips_paths(self):
        home = self.home()
        r = run(home, """
            import migrate_dirs as m
            m.blockers = lambda: []
            m.shutil.which = lambda name: None
            sys.exit(m.main([]))
        """)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertTrue(os.path.isfile(f"{home}/.config/agentmeister/proxy/subscription.url"))
        self.assertTrue(os.path.isfile(f"{home}/.cache/agentmeister/restart/ttys001"))
        self.assertTrue(os.path.isfile(f"{home}/.local/state/agentmeister/host-run/host-run.log"))
        self.assertTrue(os.path.isdir(f"{home}/.local/state/agentmeister/stray"))
        self.assertTrue(os.path.isfile(f"{home}/.local/state/mnrh/lid.pid"))
        self.assertFalse(os.path.exists(f"{home}/.config/mnrh"))
        r = run(home, "import mnrhlib, proxy; print(mnrhlib.CONFIG, proxy.CONF_DIR)")
        self.assertEqual(r.stdout.split(), [f"{home}/.config/agentmeister/config", f"{home}/.config/agentmeister/proxy"])

    def test_mnrh_keeps_a_link_to_the_config(self):
        home = self.home()
        r = run(home, """
            import migrate_dirs as m
            m.blockers = lambda: []
            m.shutil.which = lambda name: "/usr/local/bin/mnrh"
            sys.exit(m.main([]))
        """)
        self.assertEqual(r.returncode, 0, r.stderr)
        link = f"{home}/.config/mnrh/config"
        self.assertTrue(os.path.islink(link))
        self.assertEqual(os.path.realpath(link), os.path.realpath(f"{home}/.config/agentmeister/config"))
        r = run(home, "import mnrhlib; print(mnrhlib.CONFIG)")
        self.assertEqual(r.stdout.strip(), f"{home}/.config/agentmeister/config")

    def test_refuses_inside_a_proxy_session(self):
        home = self.home()
        r = run(home, "import migrate_dirs as m; sys.exit(m.main([]))", MNRH_PROXY="17890")
        self.assertEqual(r.returncode, 1)
        self.assertTrue(os.path.isdir(f"{home}/.config/mnrh/proxy"))

    def test_help_follows_lang(self):
        home = self.home()
        en = run(home, "import migrate_dirs as m; sys.exit(m.main(['-h']))", AGENTMEISTER_LANG="en")
        self.assertEqual(en.returncode, 0)
        self.assertIsNone(re.search("[А-Яа-яЁё]", en.stdout), en.stdout)
        self.assertIn("agentmeister migrate [--dry-run]", en.stdout)
        self.assertIn("lid.pid", en.stdout)
        ru = run(home, "import migrate_dirs as m; sys.exit(m.main(['--help']))", AGENTMEISTER_LANG="ru")
        self.assertTrue(ru.stdout.startswith("agentmeister migrate: перенести папки со старым именем mnrh"), ru.stdout)
        self.assertTrue(ru.stdout.endswith("\n\nagentmeister migrate [--dry-run]\n"), ru.stdout)

    def test_refusal_in_english(self):
        home = self.home()
        r = run(home, "import migrate_dirs as m; sys.exit(m.main([]))", MNRH_PROXY="17890", AGENTMEISTER_LANG="en")
        self.assertEqual(r.returncode, 1)
        self.assertIn("Not moving:", r.stderr)
        self.assertIsNone(re.search("[А-Яа-яЁё]", r.stdout + r.stderr), r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
