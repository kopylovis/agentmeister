import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import open_flow
from menu import Quit, Screen
from mnrhlib import CM, HOME, ROOT, find_project, hook_command, is_hook, promptsill_path, tr, write_json


HOOK_EVENTS = ("SessionStart", "UserPromptSubmit", "Stop")
MCP = "claudemeister"
MCP_ARGS = ["--harness", "codex", "mcp"]


def executable():
    return shutil.which("codex")


def launch_args(argv):
    before, after = argv, []
    if "--" in argv:
        sep = argv.index("--")
        before, after = argv[:sep], argv[sep + 1:]
    parser = argparse.ArgumentParser(prog="claudemeister --harness codex",
                                     description=tr("Запуск и настройка Codex", "Launch and set up Codex"))
    parser.add_argument("project", nargs="?")
    parser.add_argument("-k", "--caffeinate", dest="mode", action="store_const", const="caffeinate")
    parser.add_argument("-n", "--normal", dest="mode", action="store_const", const="normal")
    parser.add_argument("-x", "--proxy", dest="net", action="store_const", const="vps")
    parser.add_argument("-d", "--direct", dest="net", action="store_const", const="direct")
    parser.add_argument("--new", action="store_true")
    return parser.parse_args(before), after


def launch(codex, args, passthrough):
    import claude_proxy

    project = args.project
    cwd = None
    if project and project != "open":
        folder = Path(project).expanduser()
        if ("/" in project or project == ".") and folder.is_dir():
            cwd = str(folder.resolve())
        else:
            cwd, error = find_project(project)
            if error:
                raise ValueError(error)
    elif passthrough:
        cwd = os.getcwd()
    mode, net = args.mode, args.net
    interactive = sys.stdin.isatty() and sys.stdout.isatty()
    if interactive and not passthrough:
        screen = Screen()
        try:
            state = open_flow.flow(screen, cwd, not args.new, mode=mode, net=net, harness="codex")
        except Quit:
            return 130
        finally:
            screen.close()
        if state is None:
            return 130
        cwd, mode, net = state["dir"], state["mode"], state["net"]
        if state["sid"] == "resume":
            passthrough = ["resume"]
    cmd = [codex] + passthrough
    if mode == "caffeinate":
        cmd = ["caffeinate", "-is"] + cmd
    if net == "vps":
        if not claude_proxy.configured():
            raise ValueError(tr("Прокси не настроен. Запусти claudemeister proxy setup.",
                                "Set up the proxy with claudemeister proxy setup."))
        cmd = [sys.executable, str(Path(__file__).with_name("claude_proxy.py")), "run", "--"] + cmd
    if cwd:
        os.chdir(cwd)
    os.execvp(cmd[0], cmd)


def configure_hooks(remove):
    home = Path(os.environ.get("CODEX_HOME") or Path(HOME) / ".codex").expanduser()
    path = home / "hooks.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        data = {}
    if not isinstance(data, dict) or not isinstance(data.get("hooks", {}), dict):
        raise ValueError(f"{path} has an invalid hooks structure")
    hooks = data.setdefault("hooks", {})
    command = hook_command("humanize-hook --codex")
    changed = False
    for event in HOOK_EVENTS:
        groups = hooks.get(event, [])
        if not isinstance(groups, list) or any(not isinstance(g, dict) or not isinstance(g.get("hooks"), list)
                                               for g in groups):
            raise ValueError(f"{path} has invalid {event} hooks")
        existing = False
        for group in groups[:]:
            for handler in group["hooks"][:]:
                cmd = handler.get("command", "") if isinstance(handler, dict) else ""
                if not isinstance(cmd, str) or not is_hook(cmd, "humanize-hook"):
                    continue
                if remove and cmd.split()[-1:] == ["--codex"]:
                    group["hooks"].remove(handler)
                    if not group["hooks"]:
                        groups.remove(group)
                    changed = True
                elif not group.get("matcher"):
                    existing = True
        if not remove and not existing:
            handler = {"type": "command", "command": command}
            if event != "Stop":
                handler["additionalContextLimit"] = 0
            groups.append({"hooks": [handler]})
            changed = True
        if groups:
            hooks[event] = groups
        elif event in hooks:
            del hooks[event]
    if changed:
        path.parent.mkdir(parents=True, exist_ok=True)
        write_json(str(path), data, mode=0o600, newline=True, indent=2, ensure_ascii=False)


def setup(codex, argv):
    parser = argparse.ArgumentParser(prog="claudemeister --harness codex setup")
    parser.add_argument("--remove", action="store_true")
    remove = parser.parse_args(argv).remove
    listed = subprocess.run([codex, "mcp", "list", "--json"], capture_output=True, text=True, check=True)
    servers = json.loads(listed.stdout)
    existing = next((server for server in servers if server.get("name") == MCP), None)
    transport = (existing or {}).get("transport") or {}
    own_command = transport.get("command") in {CM, os.path.join(ROOT, "bin", "claudemeister")}
    ours = own_command and transport.get("args") == MCP_ARGS
    migrate = False
    if own_command and transport.get("args") == ["mcp"] and not remove:
        current = subprocess.run([codex, "mcp", "get", MCP, "--json"], capture_output=True, text=True, check=True)
        entry = json.loads(current.stdout)
        migrate = entry.get("enabled") and all(entry.get(key) is None for key in
                   ("enabled_tools", "disabled_tools", "startup_timeout_sec", "tool_timeout_sec")) and not any(
                       transport.get(key) for key in ("env", "env_vars", "cwd"))
    if existing and not (ours or migrate or remove):
        raise ValueError(tr("В Codex уже есть другая настройка MCP с именем claudemeister.",
                            "Codex already has a different MCP server named claudemeister."))
    configure_hooks(remove)
    if remove and ours:
        subprocess.run([codex, "mcp", "remove", MCP], check=True)
    elif not remove and (not existing or migrate):
        subprocess.run([codex, "mcp", "add", MCP, "--", CM] + MCP_ARGS, check=True)
    if not remove:
        print(tr("Хуки humanize и MCP настроены. Подтверди новые хуки в Codex через /hooks.",
                 "Configured humanize hooks and MCP. Trust the new hooks in Codex with /hooks."))
    return 0


def main(argv):
    if argv == ["mcp"]:
        os.environ["MNRH_MCP_HARNESS"] = "codex"
        from mcp_server import mcp
        mcp()
        return 0
    if argv[:1] == ["statusline"]:
        path = promptsill_path()
        if path:
            os.execv(path, [path, "codex"] + argv[1:])
        print("brew install kopylovis/tap/promptsill", file=sys.stderr)
        return 1
    configuring = argv[:1] == ["setup"]
    if configuring and any(arg in ("-h", "--help") for arg in argv[1:]):
        return setup(None, argv[1:])
    if not configuring:
        args, passthrough = launch_args(argv)
    codex = executable()
    if not codex:
        print(tr("Команда codex не найдена в PATH.", "The codex command is missing from PATH."), file=sys.stderr)
        return 1
    try:
        return setup(codex, argv[1:]) if configuring else launch(codex, args, passthrough)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(getattr(error, "stderr", "") or str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
