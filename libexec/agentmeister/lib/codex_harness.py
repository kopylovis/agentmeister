import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
from contextlib import contextmanager
from pathlib import Path

import open_flow
from menu import Quit, Screen
from mnrhlib import CM, HOME, RESTART_QUEUE, ROOT, UUID_RE, find_project, hook_command, is_hook, promptsill_path, tr, write_json


HOOK_EVENTS = ("SessionStart", "UserPromptSubmit", "Stop")
NOTIFY_EVENTS = ("UserPromptSubmit", "PermissionRequest", "Stop")
HOOK_COMMANDS = {"humanize-hook": HOOK_EVENTS, "notify-hook": NOTIFY_EVENTS}
HOOK_LABELS = {
    "approve-hook": "Agentmeister approvals",
    "buildlog-hook": "Agentmeister build digest",
    "guard-hook": "Agentmeister guard",
    "humanize-hook": "Agentmeister humanize",
    "notice": "Agentmeister session start",
    "notify-hook": "Agentmeister notifications",
    "session-end": "Agentmeister session cleanup",
}
MCP = "claudemeister"
MCP_ARGS = ["--harness", "codex", "mcp"]
SKILL_OWNER = "<!-- Managed by agentmeister. -->"
RESTART_PRESETS = (
    {"label": "Restart Codex", "input": "$agentmeister restart"},
    {"label": "Update and restart Codex", "input": "$agentmeister restart --update"},
)


def executable():
    return shutil.which("codex")


@contextmanager
def app_server(codex, cwd, experimental=False):
    with subprocess.Popen([codex, "app-server", "--listen", "stdio://"], cwd=cwd,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          encoding="utf-8") as server:
        deadline = threading.Timer(5, server.kill)
        deadline.start()
        request_id = 0

        def send(message):
            server.stdin.write(json.dumps(message) + "\n")
            server.stdin.flush()

        def request(method, params):
            nonlocal request_id
            request_id += 1
            send({"id": request_id, "method": method, "params": params})
            for line in server.stdout:
                reply = json.loads(line)
                if reply.get("id") == request_id:
                    if "error" in reply:
                        raise ValueError(reply["error"].get("message", method))
                    return reply["result"]
            raise OSError("Codex App Server closed the connection")

        try:
            params = {"clientInfo": {"name": "agentmeister", "version": "1"}}
            if experimental:
                params["capabilities"] = {"experimentalApi": True}
            request("initialize", params)
            send({"method": "initialized"})
            yield request
        finally:
            deadline.cancel()
            if server.poll() is None:
                server.kill()


def launch_args(argv):
    before, after = argv, []
    if "--" in argv:
        sep = argv.index("--")
        before, after = argv[:sep], argv[sep + 1:]
    parser = argparse.ArgumentParser(prog="agentmeister --harness codex",
                                     description=tr("Запуск и настройка Codex", "Launch and set up Codex"),
                                     epilog=tr("Для перезапуска сессии используй restart [ID].",
                                               "Use restart [ID] to reopen a session."))
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
        passthrough = open_flow.codex_resume_args(state["sid"], cwd)
    cmd = [codex] + passthrough
    if mode == "caffeinate":
        cmd = ["caffeinate", "-is"] + cmd
    if net == "vps":
        if not claude_proxy.configured():
            raise ValueError(tr("Прокси не настроен. Запусти agentmeister proxy setup.",
                                "Set up the proxy with agentmeister proxy setup."))
        cmd = [sys.executable, str(Path(__file__).with_name("claude_proxy.py")), "run", "--"] + cmd
    if cwd:
        os.chdir(cwd)
    env = dict(os.environ)
    if net == "direct":
        for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                     "http_proxy", "https_proxy", "all_proxy", "no_proxy", "MNRH_PROXY",
                     "PROMPTSILL_PROXY_LABEL", "PROMPTSILL_PROXY_DETAIL", "PROMPTSILL_PROXY_URL"):
            env.pop(name, None)
    os.execvpe(cmd[0], cmd, env)


def restart(codex, argv):
    parser = argparse.ArgumentParser(prog="agentmeister --harness codex restart",
                                     description=tr("Заново открыть сессию Codex", "Reopen a Codex session"))
    parser.add_argument("session", nargs="?")
    parser.add_argument("--after-exit", action="store_true")
    parser.add_argument("--update", action="store_true")
    parser.add_argument("-x", "--proxy", action="store_true")
    options = parser.parse_args(argv)
    current = os.environ.get("CODEX_THREAD_ID")
    session = options.session or current
    if session and not UUID_RE.fullmatch(session):
        raise ValueError(tr("Нужен UUID сессии Codex.", "Expected a Codex session UUID."))
    cwd = os.getcwd()
    proxy = options.proxy or bool(os.environ.get("MNRH_PROXY"))

    if options.after_exit:
        from claude_notify import codex_terminal

        if not current or session != current:
            raise ValueError(tr("Для перезапуска нужен ID текущей сессии Codex.",
                                "Restart after exit needs the current Codex session."))
        program = shutil.which("agentmeister") or os.path.join(ROOT, "bin", "agentmeister")
        command = [program, "--harness", "codex", "restart", session]
        if options.update:
            command.append("--update")
        if proxy:
            command.append("--proxy")
        line = f"cd {shlex.quote(cwd)} && {shlex.join(command)}"
        tty = codex_terminal(session) if os.environ.get("MNRH_RESTART_HOOK") == "1" else None
        if not tty:
            print(tr("После /quit выполни в терминале", "After /quit, run in the terminal"))
            print(line)
            return 0
        queue = Path(RESTART_QUEUE)
        queue.mkdir(parents=True, mode=0o700, exist_ok=True)
        job_path = queue / Path(tty).name
        try:
            with job_path.open("x") as job:
                job.write(line + "\n")
        except FileExistsError:
            if job_path.is_symlink() or job_path.read_text(encoding="utf-8") != line + "\n":
                raise ValueError(tr("Для этой вкладки уже запланирован другой запуск.",
                                    "Another launch is already queued for this tab."))
            os.utime(job_path, follow_symlinks=False)
        print(tr("Введи /quit в течение двух минут. Codex снова откроет эту сессию в той же вкладке.",
                 "Run /quit within two minutes. Codex will reopen this session in the same tab."))
        return 0

    if options.update:
        subprocess.run([codex, "update"], check=True)
    flags = ["-x", "--"] if proxy else ["--"]
    resume = ["resume", "-C", cwd, session or "--last"]
    args, passthrough = launch_args(flags + resume)
    return launch(codex, args, passthrough)


def hooks_path():
    home = Path(os.environ.get("CODEX_HOME") or Path(HOME) / ".codex").expanduser()
    return home / "hooks.json"


def configured_humanize_hooks():
    return configured_hooks("humanize-hook")


def configured_hooks(name):
    try:
        hooks = json.loads(hooks_path().read_text(encoding="utf-8")).get("hooks", {})
        return sum(any(handler.get("type") == "command" and is_hook(handler.get("command"), name)
                       for group in hooks.get(event, []) if not group.get("matcher")
                       for handler in group["hooks"]) for event in HOOK_COMMANDS[name])
    except FileNotFoundError:
        return 0
    except (OSError, ValueError, AttributeError, KeyError, TypeError):
        return None


def label_hooks(hooks):
    changed = False
    for groups in hooks.values():
        for group in groups if isinstance(groups, list) else ():
            handlers = group.get("hooks") if isinstance(group, dict) else None
            for handler in handlers if isinstance(handlers, list) else ():
                if not isinstance(handler, dict) or handler.get("type") != "command":
                    continue
                command = handler.get("command")
                if not isinstance(command, str) or handler.get("statusMessage"):
                    continue
                try:
                    args = shlex.split(command)
                except ValueError:
                    continue
                if len(args) < 2:
                    continue
                binary = os.path.basename(args[0])
                name = args[1] if binary in ("agentmeister", "claudemeister") else None
                if binary == "mnrh" and args[1:2] == ["claude"] and len(args) > 2:
                    name = args[2]
                if name in HOOK_LABELS:
                    handler["statusMessage"] = HOOK_LABELS[name]
                    changed = True
    return changed


def configure_hooks(remove):
    path = hooks_path()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        data = {}
    if not isinstance(data, dict) or not isinstance(data.get("hooks", {}), dict):
        raise ValueError(f"{path} has an invalid hooks structure")
    hooks = data.setdefault("hooks", {})
    changed = False
    for event in dict.fromkeys(HOOK_EVENTS + NOTIFY_EVENTS):
        commands = [name for name, events in HOOK_COMMANDS.items() if event in events]
        groups = hooks.get(event, [])
        if not isinstance(groups, list) or any(not isinstance(g, dict) or not isinstance(g.get("hooks"), list)
                                               for g in groups):
            raise ValueError(f"{path} has invalid {event} hooks")
        existing = set()
        for group in groups[:]:
            for handler in group["hooks"][:]:
                cmd = handler.get("command", "") if isinstance(handler, dict) else ""
                name = next((n for n in commands if isinstance(cmd, str) and is_hook(cmd, n)), None)
                if name is None:
                    continue
                if remove and cmd.split()[-1:] == ["--codex"]:
                    group["hooks"].remove(handler)
                    if not group["hooks"]:
                        groups.remove(group)
                    changed = True
                elif not group.get("matcher"):
                    existing.add(name)
        if not remove:
            for name in commands:
                if name in existing:
                    continue
                handler = {"type": "command", "command": hook_command(f"{name} --codex")}
                if name == "humanize-hook" and event != "Stop":
                    handler["additionalContextLimit"] = 0
                if name == "notify-hook" and event != "UserPromptSubmit":
                    handler.update({"async": True, "timeout": 60})
                groups.append({"hooks": [handler]})
                changed = True
        if groups:
            hooks[event] = groups
        elif event in hooks:
            del hooks[event]
    if not remove:
        changed = label_hooks(hooks) or changed
    if changed:
        path.parent.mkdir(parents=True, exist_ok=True)
        write_json(str(path), data, mode=0o600, newline=True, indent=2, ensure_ascii=False)


def configure_footer():
    path = promptsill_path()
    if not path:
        print(tr("Строку состояния Codex настраивает promptsill. Установка через brew install kopylovis/tap/promptsill.",
                 "Install promptsill with brew install kopylovis/tap/promptsill to set up the Codex footer."))
        return
    try:
        result = subprocess.run([path, "codex", "install"], capture_output=True, text=True, timeout=8)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"promptsill: {error}", file=sys.stderr)
        return
    if result.returncode == 0:
        print(result.stdout.strip())
    elif result.returncode == 2:
        print(tr("Для строки состояния Codex обнови promptsill до версии 0.8.0 или новее.",
                 "Update promptsill to 0.8.0 or later to set up the Codex footer."), file=sys.stderr)
    else:
        print(result.stderr.strip() or "promptsill codex install failed", file=sys.stderr)


def configure_skill(remove):
    path = Path(HOME) / ".agents" / "skills" / "agentmeister" / "SKILL.md"
    if path.parent.is_symlink() or path.is_symlink():
        return
    try:
        current = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        current = None
    if current is not None and SKILL_OWNER not in current.splitlines():
        if not remove:
            print(tr("Навык agentmeister уже есть. Сохранил существующий файл.",
                     "The existing agentmeister skill was kept."))
        return
    if remove:
        if current is not None:
            path.unlink()
        return

    source = Path(ROOT) / "share" / "agentmeister" / "skills" / "agentmeister" / "SKILL.md"
    text = source.read_text(encoding="utf-8")
    if text != current:
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as out:
            temporary = Path(out.name)
            try:
                out.write(text)
                out.close()
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
    print(tr("Команды для Codex доступны через $agentmeister.", "Use $agentmeister for project commands in Codex."))


def configure_restart_presets(codex, remove):
    available = []
    try:
        with app_server(codex, os.getcwd()) as request:
            result = request("config/read", {"includeLayers": True})
            user = next(layer for layer in result["layers"] if layer["name"]["type"] == "user")
            user_presets = (user["config"].get("tui") or {}).get("presets") or {}
            effective = (result["config"].get("tui") or {}).get("presets") or {}
            if remove:
                changes = {slot: None for slot, value in user_presets.items() if value in RESTART_PRESETS}
            else:
                changes = {}
                free = iter(key for key in "9876543210" if key not in user_presets and key not in effective)
                for preset in RESTART_PRESETS:
                    if preset in effective.values():
                        available.append(preset["label"])
                        continue
                    slot = next(free, None) if preset not in user_presets.values() else None
                    if slot is None:
                        print(tr(f'В /presets недоступен пункт "{preset["label"]}". Используй {preset["input"]}.',
                                 f'{preset["label"]} is unavailable in /presets. Use {preset["input"]}.'))
                        continue
                    changes[slot] = preset
                    available.append(preset["label"])
            if changes:
                params = {"edits": [{"keyPath": f"tui.presets.{slot}", "mergeStrategy": "upsert", "value": value}
                                    for slot, value in changes.items()]}
                if user.get("version"):
                    params["expectedVersion"] = user["version"]
                written = request("config/batchWrite", params)
                if written.get("status") != "ok" or written.get("overriddenMetadata"):
                    raise ValueError("Codex could not save the restart presets")
    except (OSError, ValueError, KeyError, TypeError, StopIteration):
        print(tr("Не удалось изменить команды в /presets.", "Could not update the commands in /presets."),
              file=sys.stderr)
        return
    for label in available:
        print(tr(f'В /presets доступен пункт "{label}".', f'Choose "{label}" in /presets.'))


def setup(codex, argv):
    parser = argparse.ArgumentParser(prog="agentmeister --harness codex setup")
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
    configure_skill(remove)
    configure_restart_presets(codex, remove)
    if not remove:
        from setup_cmd import install_restart_hook
        install_restart_hook()
        print(tr("Хуки humanize и notify, MCP настроены. Подтверди новые хуки в Codex через /hooks.",
                 "Configured humanize and notify hooks and MCP. Trust the new hooks in Codex with /hooks."))
        configure_footer()
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
    restarting = argv[:1] == ["restart"]
    if restarting and any(arg in ("-h", "--help") for arg in argv[1:]):
        return restart(None, argv[1:])
    configuring = argv[:1] == ["setup"]
    if configuring and any(arg in ("-h", "--help") for arg in argv[1:]):
        return setup(None, argv[1:])
    if not configuring and not restarting:
        args, passthrough = launch_args(argv)
    codex = executable()
    if not codex:
        print(tr("Команда codex не найдена в PATH.", "The codex command is missing from PATH."), file=sys.stderr)
        return 1
    try:
        if configuring:
            return setup(codex, argv[1:])
        if restarting:
            return restart(codex, argv[1:])
        return launch(codex, args, passthrough)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(getattr(error, "stderr", "") or str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
