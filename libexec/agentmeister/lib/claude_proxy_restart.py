"""Restart interactive Claude inside its original proxy sandbox and terminal."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from claude_proc import CLAUDE_BIN, RestartError, resume_flags, session_file, split_caffeinate
from mnrhlib import UUID_RE, write_json


CHANNEL = "AGENTMEISTER_CLAUDE_RESTART_DIR"


def supervised_command(cmd):
    prefix = []
    utility = cmd
    if cmd and os.path.basename(cmd[0]) == "caffeinate":
        flags, utility = split_caffeinate(cmd[1:])
        prefix = [cmd[0], *flags]
    if not utility or os.path.basename(utility[0]) != os.path.basename(CLAUDE_BIN):
        return cmd
    if utility[1:2] == ["update"] or any(arg in ("-p", "--print") for arg in utility[1:]):
        return cmd
    return [*prefix, sys.executable, os.path.abspath(__file__), *utility]


def session_pid(directory):
    try:
        pid = int((Path(directory) / "pid").read_text())
    except (OSError, ValueError) as exc:
        raise RestartError("не удалось подтвердить процесс этой прокси-сессии") from exc
    if pid <= 1 or os.environ.get("CLAUDE_PID") not in (None, "", str(pid)):
        raise RestartError("процесс не принадлежит этой прокси-сессии")
    return pid


def schedule(directory, pid, sid, update, delay):
    directory = Path(directory)
    from claude_restart import background

    def stop():
        time.sleep(delay)
        with open(session_file(pid)) as f:
            info = json.load(f)
            if info.get("sessionId") != sid:
                return
        write_json(str(directory / "restart"), {"session": sid, "update": update, "cwd": info.get("cwd")}, mode=0o600)
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            (directory / "restart").unlink(missing_ok=True)
            raise

    background(stop)


def supervise(cmd):
    original = cmd
    cwd = os.getcwd()
    child = None
    stopping = False

    def forward(sig, frame):
        nonlocal stopping
        stopping = True
        if child and child.poll() is None:
            child.send_signal(sig)

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGHUP, forward)
    while not stopping:
        with tempfile.TemporaryDirectory(prefix="am-claude-") as directory:
            root = Path(directory)
            child = subprocess.Popen(cmd, cwd=cwd, env=dict(os.environ, **{CHANNEL: directory}))
            (root / "pid").write_text(str(child.pid))
            if stopping:
                child.terminate()
            code = child.wait()
            request = root / "restart"
            if stopping or not request.is_file():
                return code if code >= 0 else 128 - code
            data = json.loads(request.read_text())
        sid = data["session"]
        if not isinstance(sid, str) or not UUID_RE.fullmatch(sid):
            raise ValueError("invalid Claude session ID")
        cwd = data.get("cwd") or cwd
        if stopping:
            break
        if data.get("update") is True:
            import agent_update
            command = agent_update.update_argv("claude", shutil.which(original[0]) or original[0]) or [original[0], "update"]
            child = subprocess.Popen(command, cwd=cwd)
            if stopping:
                child.terminate()
            child.wait()
        cmd = [original[0], "--resume", sid, *resume_flags(original[1:])]
    return 0


if __name__ == "__main__":
    sys.exit(supervise(sys.argv[1:]))
