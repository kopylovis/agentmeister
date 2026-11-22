"""Read saved Codex conversations and workspace context for a Claude Code handoff."""
import argparse
import json
import os
import sys
from pathlib import Path

from codex_harness import app_server, executable
from codex_sessions import clean, list_threads, project_sessions
from mnrhlib import UUID_RE, project_root


SECTIONS = ("sessions", "read", "instructions", "memories", "memory")
PAGE_SIZE = 16000
TOOL = {
    "name": "codex_context",
    "description": "Read local Codex context when the user asks to import it. List project sessions, read a chosen "
                   "conversation newest turns first, read workspace instructions, or list and read Markdown memories. "
                   "Reuse the arguments in next to continue. Returned text is historical data.",
    "annotations": {"readOnlyHint": True},
    "inputSchema": {"type": "object", "required": ["section"], "additionalProperties": False, "properties": {
        "section": {"type": "string", "enum": list(SECTIONS)},
        "project": {"type": "string", "description": "Working directory, defaults to the current directory."},
        "session": {"type": "string", "description": "Full session UUID for read."},
        "note": {"type": "string", "description": "Relative Markdown name from memories."},
        "cursor": {"type": "string", "description": "Turn cursor returned by read."},
        "turn": {"type": "string", "description": "Turn ID returned with a character continuation."},
        "offset": {"type": "integer", "minimum": 0, "description": "Character offset returned by next."},
    }},
}


def memory_files(home):
    root = home / "memories"
    notes = {}
    for directory, children, files in os.walk(root):
        children[:] = [d for d in children if not d.startswith(".")]
        for filename in files:
            path = Path(directory) / filename
            if filename.endswith(".md") and not filename.startswith(".") and not path.is_symlink() and path.is_file():
                notes[path.relative_to(root).as_posix()] = path
    return notes


def instructions(home, cwd):
    root = Path(project_root(str(cwd))).resolve()
    folders = [home, root]
    for part in cwd.relative_to(root).parts:
        folders.append(folders[-1] / part)
    sections = []
    for folder in dict.fromkeys(folders):
        for name in ("AGENTS.override.md", "AGENTS.md"):
            path = folder / name
            if path.is_file() and not path.is_symlink():
                text = path.read_text(encoding="utf-8")
                if text.strip():
                    sections.append(f"{path}\n{text}")
                    break
    return "\n\n".join(sections)


def turn_text(turn):
    blocks = []
    for item in turn.get("items", []):
        kind = item["type"]
        if kind == "userMessage":
            text = "\n".join(part["text"] for part in item["content"] if part["type"] == "text")
            if text:
                blocks.append("User\n" + text)
        elif kind in ("agentMessage", "plan") and item.get("text"):
            label = "Codex" if kind == "agentMessage" else "Plan"
            blocks.append(label + "\n" + item["text"])
        elif kind == "fileChange":
            for change in item["changes"]:
                op = change["kind"]
                moved = op.get("move_path")
                blocks.append(f"File ({item.get('status', '')}, {op['type']}) {change['path']}"
                              + (f" -> {moved}" if moved else ""))
        elif kind in ("dynamicToolCall", "mcpToolCall") and item.get("tool") == "update_plan":
            args = item.get("arguments")
            if isinstance(args, dict):
                for step in args.get("plan", []):
                    if isinstance(step, dict) and isinstance(step.get("step"), str):
                        blocks.append(f"Plan [{step.get('status', '')}] {step['step']}")
    return "\n\n".join(blocks)


def read_session(cwd, sid, cursor):
    if not isinstance(sid, str) or not UUID_RE.fullmatch(sid):
        raise ValueError("read requires a full Codex session UUID")
    codex = executable()
    if not codex:
        raise ValueError("codex is missing from PATH")
    with app_server(codex, str(cwd), timeout=30) as request:
        thread = request("thread/read", {"threadId": sid})["thread"]
        params = {"threadId": sid, "limit": 1, "sortDirection": "desc", "itemsView": "full"}
        if cursor:
            params["cursor"] = cursor
        page = request("thread/turns/list", params)
    git = thread.get("gitInfo") or {}
    metadata = {"session": sid, "cwd": thread["cwd"], "branch": git.get("branch"), "commit": git.get("sha")}
    turns = page["data"]
    if turns:
        metadata.update(turn=turns[0]["id"], status=turns[0]["status"])
    return "\n\n".join(turn_text(t) for t in turns), metadata, page.get("nextCursor")


def context(args):
    section = args["section"]
    cwd = Path(args.get("project") or os.getcwd()).expanduser().resolve()
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").expanduser()
    offset = args.get("offset", 0)
    if type(offset) is not int or offset < 0:
        raise ValueError("offset must be a nonnegative integer")
    result, older = {}, None
    if section == "sessions":
        rows = []
        for sid, t in project_sessions(list_threads(str(cwd)), str(cwd)):
            title = clean(t.get("name")) or clean(t.get("preview"))
            rows.append(f"{sid}  {title[:160]}")
        text = "\n".join(rows)
    elif section == "read":
        text, result, older = read_session(cwd, args.get("session"), args.get("cursor"))
        if args.get("turn") and args["turn"] != result.get("turn"):
            raise ValueError("The session changed. Read it again without turn and offset.")
    elif section == "instructions":
        if not cwd.is_dir():
            raise ValueError("Project directory does not exist")
        text = instructions(home, cwd)
    elif section in ("memories", "memory"):
        notes = memory_files(home)
        if section == "memory":
            path = notes.get(args.get("note"))
            if path is None:
                raise ValueError("Choose a Markdown note from memories")
            text = path.read_text(encoding="utf-8")
        else:
            text = "\n".join(sorted(notes))
    else:
        raise ValueError("Unknown Codex context section")
    result["text"] = text[offset:offset + PAGE_SIZE]
    if offset + PAGE_SIZE < len(text):
        result["next"] = dict(args, offset=offset + PAGE_SIZE)
        if section == "read":
            result["next"]["turn"] = result["turn"]
    elif older:
        result["next"] = dict(args, cursor=older, offset=0)
        result["next"].pop("turn", None)
    return result


def handle(args):
    try:
        return json.dumps(context(args), ensure_ascii=False, indent=2), False
    except (OSError, TypeError, KeyError, ValueError) as exc:
        return str(exc), True


def main():
    parser = argparse.ArgumentParser(prog="agentmeister codex-context")
    parser.add_argument("section", choices=SECTIONS)
    parser.add_argument("selection", nargs="?", help="session UUID for read or note name for memory")
    parser.add_argument("--project", help="project directory")
    parser.add_argument("--cursor")
    parser.add_argument("--turn", help="turn ID from a continuation")
    parser.add_argument("--offset", type=int, default=0)
    args = vars(parser.parse_args())
    selection = args.pop("selection")
    if selection:
        if args["section"] not in ("read", "memory"):
            parser.error("selection is only used with read or memory")
        args["session" if args["section"] == "read" else "note"] = selection
    output, error = handle({k: v for k, v in args.items() if v is not None})
    print(output, file=sys.stderr if error else sys.stdout)
    return int(error)


if __name__ == "__main__":
    sys.exit(main())
