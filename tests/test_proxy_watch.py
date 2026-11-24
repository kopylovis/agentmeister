import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "libexec", "agentmeister", "lib"))
import claude_proxy as p  # noqa: E402

SERVER = "kz-server"


class WatchStep(unittest.TestCase):
    def test_healthy_does_nothing(self):
        self.assertEqual(p.watch_step({}, 100, "en0", "en0", SERVER), [])

    def test_no_network_waits(self):
        state = {"reject_since": 50}
        self.assertEqual(p.watch_step(state, 100, None, "en0", None), [])
        self.assertIsNone(state["reject_since"])

    def test_interface_change_repins(self):
        self.assertEqual(p.watch_step({}, 100, "en7", "en0", SERVER), ["repin", "healthcheck"])
        # VPN забрал маршрут по умолчанию: интерфейс из конфига надо убрать
        self.assertEqual(p.watch_step({}, 100, "utun4", "en0", SERVER), ["repin", "healthcheck"])
        self.assertEqual(p.watch_step({}, 100, "utun4", None, SERVER), [])

    def test_reject_checks_then_restarts_once(self):
        state = {}
        self.assertEqual(p.watch_step(state, 100, "en0", "en0", "REJECT"), ["healthcheck"])
        self.assertEqual(p.watch_step(state, 110, "en0", "en0", "REJECT"), [])
        self.assertEqual(p.watch_step(state, 100 + p.RESTART_AFTER, "en0", "en0", "REJECT"), ["restart"])
        # сервер и правда лежит: следующий перезапуск не раньше чем через RESTART_GAP
        t = 100 + p.RESTART_AFTER
        self.assertEqual(p.watch_step(state, t + 10, "en0", "en0", "REJECT"), ["healthcheck"])
        self.assertEqual(p.watch_step(state, t + 10 + p.RESTART_AFTER, "en0", "en0", "REJECT"), [])
        self.assertEqual(p.watch_step(state, t + p.RESTART_GAP + 20, "en0", "en0", "REJECT"), ["restart"])

    def test_recovery_resets(self):
        state = {}
        p.watch_step(state, 100, "en0", "en0", "REJECT")
        self.assertEqual(p.watch_step(state, 110, "en0", "en0", SERVER), [])
        self.assertIsNone(state["reject_since"])


class CountryOnRestart(unittest.TestCase):
    """Сервер недоступен, сторож перезапускает mihomo, а выход проверить нельзя: mihomo должен остаться."""

    def start(self, strict):
        tmp = tempfile.mkdtemp()
        calls = {"n": 0}

        def listening(_port):
            calls["n"] += 1
            return calls["n"] > 1  # первый раз порт свободен, потом mihomo на нем

        proc = MagicMock()
        proc.pid = 4242
        proc.poll.return_value = None
        files = {name: os.path.join(tmp, name.lower()) for name in ("PIDFILE", "LOG", "EXIT", "PAGE")}
        stop = MagicMock()
        with patch.multiple(p, STATE=tmp, **files), patch.object(p, "read_pid", return_value=None), \
                patch.object(p, "listening", side_effect=listening), patch.object(p, "port", return_value=17890), \
                patch.object(p, "pin_config"), patch.object(p, "refresh_subscription"), \
                patch.object(p, "pin_hosts"), patch.object(p, "mihomo_bin", return_value="/bin/mihomo"), \
                patch.object(p.subprocess, "Popen", return_value=proc), \
                patch.object(p.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "204", "")), \
                patch.object(p, "trace", return_value=None), patch.object(p, "active_node", return_value=(None, None)), \
                patch.object(p, "setting", return_value="KZ"), patch.object(p, "stop", stop), \
                patch.object(p, "in_session", return_value=False):
            try:
                return p.start(strict=strict), stop
            except p.ProxyError as e:
                return e, stop

    def test_session_launch_still_refuses_the_wrong_country(self):
        result, stop = self.start(strict=True)
        self.assertIsInstance(result, p.ProxyError)
        stop.assert_called_once()

    def test_restart_keeps_mihomo_running(self):
        result, stop = self.start(strict=False)
        self.assertIn("KZ", result)
        stop.assert_not_called()

    def test_restart_mihomo_is_not_strict(self):
        with patch.object(p, "stop"), patch.object(p, "start", return_value="выход через ?") as start:
            self.assertEqual(p.restart_mihomo(), "выход через ?")
        start.assert_called_once_with(strict=False)


class Revive(unittest.TestCase):
    def test_watcher_exits_after_the_last_session(self):
        with patch.object(p, "holders", return_value=[]), patch.object(p, "start") as start:
            self.assertFalse(p.revive({}, 100))
        start.assert_not_called()

    def test_mihomo_is_started_again_while_sessions_hold_it(self):
        state = {}
        with patch.object(p, "holders", return_value=[123]), patch.object(p, "read_pid", return_value=None), \
                patch.object(p, "watch_log"), patch.object(p, "start", side_effect=p.ProxyError("нет")) as start:
            self.assertTrue(p.revive(state, 100))
            self.assertTrue(p.revive(state, 110))  # не чаще REVIVE_GAP
            self.assertTrue(p.revive(state, 100 + p.REVIVE_GAP))
        self.assertEqual(start.call_count, 2)
        start.assert_called_with(strict=False)


class WatcherPid(unittest.TestCase):
    def alive(self, pid_text):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "watch.pid")
            with open(path, "w") as f:
                f.write(pid_text)
            with patch.object(p, "WATCH_PID", path):
                return p.watcher_alive()

    def ps(self, command):
        return patch.object(p.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, command, ""))

    def test_a_stale_pid_of_another_process_is_not_the_watcher(self):
        with self.ps("/Applications/Safari.app/Contents/MacOS/Safari\n"):
            self.assertFalse(self.alive(str(os.getpid())))
        with self.ps("/usr/bin/python3 /opt/other/claude_proxy.py run\n"):
            self.assertFalse(self.alive(str(os.getpid())))
        self.assertFalse(self.alive("garbage"))
        self.assertFalse(self.alive("0"))

    def test_the_real_watcher_is_recognized(self):
        command = f"/usr/bin/python3 {p.__file__} watch\n"
        with self.ps(command):
            self.assertTrue(self.alive(str(os.getpid())))
        with patch.object(p.subprocess, "run", side_effect=PermissionError):
            self.assertTrue(self.alive(str(os.getpid())))  # ps не дали: как раньше, верим живому pid


if __name__ == "__main__":
    unittest.main()
