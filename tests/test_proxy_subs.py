import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "libexec/agentmeister/lib"))
import claude_open
import proxy
import codex_harness
import open_flow
import restart_job


class Folder(unittest.TestCase):
    """Настройка proxy во временной папке: основная подписка и subs.json."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        tmp = self.tmp.name
        self.patch = patch.multiple(proxy, CONF_DIR=tmp, CONFIG=f"{tmp}/config.yaml",
                                    SUB_URL=f"{tmp}/subscription.url", SUB_FILE=f"{tmp}/subscription.txt",
                                    STATE=f"{tmp}/state", LOCK=f"{tmp}/lock", HOLDERS=f"{tmp}/state/holders", LAST=f"{tmp}/state/last",
                                    EXIT=f"{tmp}/state/exit.json", PAGE=f"{tmp}/state/exit.html")
        self.patch.start()
        self.listen = patch.object(proxy, "listening", return_value=False)
        self.listen.start()

    def tearDown(self):
        self.listen.stop()
        self.patch.stop()
        self.tmp.cleanup()

    def main(self, country="", only=""):
        proxy.write_config("https://main.example.test/sub", 17890, country, only)

    def extra(self, name, port, country="", only=""):
        data = proxy.read_subs()
        data[name] = {"port": port, "country": country, "only": only}
        proxy.save_subs(proxy.place_main_port(data))
        proxy.rerender()

    def config(self):
        return Path(proxy.CONFIG).read_text()


class Config(Folder):
    def test_one_subscription_keeps_the_old_config(self):
        self.main("KZ", "KZ")
        text = self.config()
        self.assertIn("use: [vps]", text)
        self.assertNotIn("listeners:", text)
        self.assertFalse(os.path.exists(proxy.subs_meta()))
        self.assertEqual(proxy.main_only(), "KZ")
        self.assertEqual(proxy.all_ports(), {None: 17890})

    def test_extra_subscription_gets_a_group_and_a_port(self):
        self.main()
        self.extra("home", 17895, "SE", "^se")
        text = self.config()
        self.assertIn("use: [vps, home]", text)
        self.assertIn("path: ./subs/home.txt\n    filter: \"^se\"", text)
        self.assertIn("proxy: VPS-home", text)
        self.assertIn("proxy: VPS-main", text)
        ports = proxy.all_ports()
        self.assertEqual(ports[None], 17890)
        self.assertEqual(ports["home"], 17895)
        self.assertNotIn(ports[proxy.MAIN], (17890, 17895))

    def test_cascade_keeps_the_country_of_the_main_subscription(self):
        self.main("KZ")
        self.extra("kz2", 17895, "KZ")
        self.extra("se", 17896, "SE")
        self.extra("any", 17897)
        self.assertIn("use: [vps, kz2]\n", self.config())
        self.assertEqual(proxy.cascade_subs(), ["main", "kz2"])
        self.assertEqual(proxy.sub_providers(None), ["vps", "kz2"])
        self.assertEqual(proxy.sub_providers("se"), ["se"])
        self.assertIn("proxy: VPS-se", self.config())

    def test_resolve_sub(self):
        self.main()
        # без дополнительных подписок main и есть каскад
        self.assertIsNone(proxy.resolve_sub("main"))
        self.extra("home", 17895)
        self.assertIsNone(proxy.resolve_sub(None))
        self.assertEqual(proxy.resolve_sub("main"), "main")
        self.assertEqual(proxy.resolve_sub("home"), "home")
        with self.assertRaises(proxy.ProxyError):
            proxy.resolve_sub("work")

    def test_setup_keeps_extra_subscriptions(self):
        self.main()
        self.extra("home", 17895)
        self.main("KZ")
        self.assertIn("home", proxy.extra_subs())
        self.assertIn("proxy: VPS-home", self.config())

    def test_bad_names_in_subs_json_are_ignored(self):
        self.main()
        proxy.write_private(proxy.subs_meta(), json.dumps(
            {"../x": {"port": 1}, "vps": {"port": 2}, "ok": {"port": 17895}, "bad": {"port": "1"}}).encode())
        self.assertEqual(list(proxy.extra_subs()), ["ok"])

    @unittest.skipUnless(shutil.which("mihomo"), "requires mihomo")
    def test_mihomo_accepts_the_config(self):
        self.main("KZ", "KZ")
        self.extra("home", 17895, "KZ")
        self.extra("se", 17896, "SE")
        line = "vless://11111111-1111-1111-1111-111111111111@a.example.com:443?security=tls&type=tcp#a\n"
        Path(proxy.SUB_FILE).write_text(line)
        os.makedirs(f"{self.tmp.name}/subs", exist_ok=True)
        for name in ("home", "se"):
            Path(proxy.sub_files(name)[1]).write_text(line)
        r = subprocess.run(["mihomo", "-t", "-d", self.tmp.name, "-f", proxy.CONFIG],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class Sessions(Folder):
    def test_holders_remember_the_subscription(self):
        os.makedirs(proxy.HOLDERS)
        for pid, text in ((os.getpid(), "home"), (os.getppid(), "")):
            Path(proxy.HOLDERS, str(pid)).write_text(text)
        self.assertEqual(proxy.held_subs(), {"home", None})

    def test_env_names_the_subscription(self):
        self.main()
        self.extra("home", 17895)
        env = proxy.proxy_env(17895, sub="home")
        self.assertEqual(env["MNRH_PROXY"], "17895")
        self.assertEqual(env["MNRH_PROXY_SUB"], "home")
        with patch.dict(os.environ, {"MNRH_PROXY_SUB": "home"}):
            self.assertNotIn("MNRH_PROXY_SUB", proxy.proxy_env(17890))

    def test_remember_accepts_a_known_subscription(self):
        self.main()
        self.extra("home", 17895)
        self.assertEqual(proxy.remember("vps:home"), 0)
        self.assertEqual(proxy.last(), "vps:home")
        self.assertEqual(proxy.remember("vps:work"), 2)

    def test_remove_refuses_while_sessions_use_it(self):
        self.main()
        self.extra("home", 17895)
        with patch.object(proxy, "held_subs", return_value={"home"}), \
                patch.object(proxy, "in_session", return_value=False):
            self.assertEqual(proxy.remove_sub("home"), 1)
        self.assertIn("home", proxy.extra_subs())
        with patch.object(proxy, "held_subs", return_value=set()), \
                patch.object(proxy, "in_session", return_value=False), \
                patch.object(proxy, "read_pid", return_value=None):
            self.assertEqual(proxy.remove_sub("home"), 0)
        self.assertEqual(proxy.extra_subs(), {})
        self.assertFalse(os.path.exists(proxy.subs_meta()))
        self.assertNotIn("listeners:", self.config())


class AppState(Folder):
    def test_app_state_lists_subscriptions_and_the_default(self):
        import app_state
        self.main("KZ")
        self.extra("home", 17895, "KZ")
        self.extra("se", 17896, "SE")
        os.makedirs(proxy.STATE)
        Path(proxy.exit_file("se")).write_text(json.dumps({"loc": "se"}))
        proxy.remember("vps:se")
        with patch.object(proxy, "read_pid", return_value=None):
            out = app_state.proxy_state()
        self.assertEqual(out["defaultRoute"], "proxy")
        self.assertEqual(out["defaultSubscription"], "se")
        self.assertEqual([(s["name"], s["inCascade"]) for s in out["subscriptions"]],
                         [("main", True), ("home", True), ("se", False)])
        self.assertEqual(out["subscriptions"][2]["exit"], "SE")

    def test_one_subscription_is_listed_without_a_default(self):
        import app_state
        self.main()
        with patch.object(proxy, "read_pid", return_value=None):
            out = app_state.proxy_state()
        self.assertEqual([s["name"] for s in out["subscriptions"]], ["main"])
        self.assertIsNone(out["defaultSubscription"])


class Launch(unittest.TestCase):
    def test_menu_offers_each_subscription(self):
        keys = [k for k, _, _ in open_flow.network_options("claude", ["main", "home"], ["main"])]
        self.assertEqual(keys, ["direct", "vps", "vps:main", "vps:home"])
        keys = [k for k, _, _ in open_flow.network_options("claude", ["main"], ["main"])]
        self.assertEqual(keys, ["direct", "vps"])

    def test_command_passes_the_subscription(self):
        state = {"dir": "/tmp", "mode": "normal", "net": "vps:home", "sid": "new"}
        self.assertEqual(open_flow.command(state), ["/tmp", "-n", "--proxy=home", "--new"])

    def test_codex_takes_x_with_a_known_name(self):
        with patch.object(proxy, "configured", return_value=True), \
                patch.object(proxy, "sub_names", return_value=["main", "home"]):
            self.assertEqual(codex_harness.via_args(["-x", "home", "proj"]), ["--via=home", "proj"])
            self.assertEqual(codex_harness.via_args(["-x", "proj"]), ["-x", "proj"])
            self.assertEqual(codex_harness.via_args(["--proxy=home"]), ["--via=home"])
            args, _ = codex_harness.launch_args(["proj", "-x", "home"])
        self.assertEqual(args.net, "vps:home")

    def test_host_open_keeps_the_subscription(self):
        cmd = claude_open.host_open_command(["proj", "--proxy=home", "--", "hi"])
        self.assertIn("--proxy=home", cmd)
        self.assertNotIn("-x", cmd)
        with self.assertRaises(ValueError):
            claude_open.host_open_command(["proj", "--proxy=../x"])


class RestartJob(unittest.TestCase):
    SID = "11111111-1111-4111-8111-111111111111"

    def test_job_keeps_the_subscription(self):
        with tempfile.TemporaryDirectory() as cwd:
            job = restart_job.claude_job(cwd, "restart", self.SID, proxy="home")
            run = restart_job.steps(job)[-1][0]
            self.assertEqual(run[run.index("run"):run.index("--") + 1], ["run", "--claude", "--via", "home", "--"])
            codex = restart_job.steps(restart_job.codex_job(cwd, self.SID, proxy="home"))[0][0]
            self.assertEqual(codex[-2:], ["--via", "home"])
            plain = restart_job.steps(restart_job.claude_job(cwd, "restart", self.SID, proxy=True))[-1][0]
            self.assertNotIn("--via", plain)

    def test_bad_subscription_name_is_rejected(self):
        with tempfile.TemporaryDirectory() as cwd:
            for bad in ("../x", "Home", "a b", "-x"):
                with self.subTest(bad=bad), self.assertRaises(restart_job.JobError):
                    restart_job.claude_job(cwd, "restart", self.SID, proxy=bad)


if __name__ == "__main__":
    unittest.main()
