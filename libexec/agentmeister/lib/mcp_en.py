"""Английские описания MCP-инструментов agentmeister для lang=en. Модель читает их в каждой сессии, поэтому
при английском интерфейсе они не должны тянуть ее на русский. Ключ — имя инструмента, внутри описание
и описания параметров. Инструмент без перевода остается как есть."""
import copy

EN = {
    "restart": ("Restart this Claude Code. The process closes and a couple of seconds later opens again with this same "
                "session in the same terminal tab. claude update runs before the start, so this is also how to install "
                "an update. Call it only when the user asks to restart or update. After the call do nothing else, the "
                "process will exit.",
                {"update": "run claude update before starting"}),
    "forget": ("Forget this session. Claude Code closes, the current conversation is deleted from disk without a trace "
               "(along with the prompt history), and a new clean Claude opens in the same folder and tab. Like /clear, "
               "except the old one isn't kept. Call it only when the user asks to forget or delete this session. After "
               "the call do nothing else.", {}),
    "fresh": ("Start a new session. Claude Code closes and a new Claude with an empty context and no title opens in the "
              "same folder and tab. The current session stays on disk and in /resume, as after /clear, but its title "
              "doesn't carry over. Call it only when the user asks for a new session. After the call do nothing else.", {}),
    "slim": ("Compact this session. Claude Code closes, screenshots and long tool outputs are removed from the older part "
             "of the session (before the last two /compact), and the session opens again in the same tab. What the model "
             "receives doesn't change, the original is kept for 14 days. If there's nothing to compact, nothing closes. "
             "Call it only when the user asks to compact the session. If the result says Claude will close, do nothing else.",
             {"dry_run": "only count how much would be freed"}),
    "open_claude": ("Open a new Claude Code in an iTerm2 tab or a Terminal window through agentmeister. First call it "
                    "without project to get the list of projects and modes, show it to the user and ask what to pick "
                    "(if they already named a project, go ahead). Then call it with project (folder name or its "
                    "beginning, \"~\" for the home folder) and mode. With Remote Control on, the session "
                    "link (claude.ai/code) comes back in the result, give it to the user. The result says where it "
                    "opened and whether Claude started.",
                    {"project": "project folder name or its beginning; \"~\" is the home folder",
                     "placement": "tab opens a tab in the current iTerm2 window. By default iTerm2 gets a tab and "
                                  "Terminal a window. window asks for a window explicitly.",
                     "mode": "caffeinate keeps the Mac awake while the session runs; normal is a plain session. "
                             "The default comes from agentmeister defaults",
                     "prompt": "first prompt for the new Claude (optional)",
                     "continue": "continue the last session in this project (claude --continue)",
                     "trust": "mark the folder as trusted if Claude Code doesn't trust it yet. Set it only after the "
                              "user explicitly agreed to trust this folder",
                     "remote_control": "turn on Remote Control (/rc) so the session can be driven from a phone or a "
                                       "browser. The default comes from agentmeister defaults"}),
    "session_search": ("Search all past Claude Code sessions on this Mac (all projects): user prompts, your replies, "
                       "commands you ran, their errors (output with a non-zero exit code and the like; plain output "
                       "isn't searched) and /compact summaries. To find how the same error was fixed before, search its "
                       "text with roles=[\"error\"]. Use it when the user refers to earlier work (\"how did we…\", "
                       "\"last time\", \"in the backend session\") or when the answer was probably found before. All "
                       "words must appear in one message; case and word form don't matter (signing finds signed), a "
                       "word stem of 3+ letters (fastl) also finds longer words. Stop words (how, we, the) are ignored. "
                       "A quoted phrase or hyphenated words are matched in order. Better matches come first. The current "
                       "session isn't searched. Open what you find with session_read.",
                       {"query": "words separated by spaces, a phrase in quotes",
                        "project": "only this project: folder name or its beginning, \"~\" for the home folder",
                        "days": "only sessions with activity in the last N days",
                        "roles": "where to search: user for prompts, claude for replies, tool for commands, error for "
                                 "command errors, summary for summaries; everywhere by default",
                        "limit": "how many sessions to show, 8 by default"}),
    "session_read": ("Read part of a past Claude Code session, the messages around a number from session_search. "
                     "Without at and query, the start of the session; at=-10 gives the last messages. Long messages "
                     "are cut, full=true shows them whole.",
                     {"id": "session id or its beginning (8 characters from session_search)",
                      "at": "message number (#N from session_search); negative counts from the end",
                      "query": "jump to the first message in this session with these words",
                      "before": "how many messages before, 2 by default",
                      "after": "how many messages after, 8 by default",
                      "full": "don't cut long messages"}),
    "usage_report": ("Claude Code usage on this Mac over a period: per project and model the number of sessions, active "
                     "time, model requests and tokens (input, output, cache reads and writes), plus the heaviest "
                     "sessions with titles. Only reads transcripts. Use it when asked how many tokens or how much time "
                     "went where, which project or model uses the most, or why a session grew so large.",
                     {"days": "how many recent days including today; 7 by default, 0 for all time",
                      "project": "only this project: folder name or its beginning, \"~\" for the home folder",
                      "top": "how many heaviest sessions to show, 5 by default"}),
    "mac_status": ("State of this Mac for development: what uses memory (split by apps, Gradle and Kotlin daemons, "
                   "simulators and the emulator), Gradle versions and the size of caches and build/ in projects, "
                   "running iOS simulators, who listens on ports, and on request what can be cleaned on disk (disk, "
                   "slow, up to a couple of minutes). Call it when a build is slow or runs out of memory, the Mac is "
                   "slow, a port is taken, or disk space runs out. Arrows \"-> mnrh …\" in the output are commands for "
                   "the user; free_memory frees memory, suggest other cleanups to the user yourself.",
                   {"parts": "what to show; ram, gradle, sim and ports by default"}),
    "free_memory": ("Free memory: stop idle Gradle and Kotlin daemons and shut down iOS simulators (their data is "
                    "kept), optionally the Android emulator too (its state goes to Quick Boot). Doesn't quit apps. "
                    "Daemons busy with a build are skipped unless force. Shows how much memory came back. Call it only "
                    "with the user's consent, whatever is stopped will have to start again.",
                    {"what": "what to stop; daemons and simulators by default, emulator in addition",
                     "force": "also stop daemons that are building right now"}),
    "deps_outdated": ("Which Gradle dependencies are outdated: reads the project's gradle/libs.versions.toml (Android, "
                      "KMP, Ktor), checks versions against Google Maven, Maven Central and the Gradle Plugin Portal, and "
                      "the Gradle wrapper version. Shows what got newer and by how much (major, minor, patch), which "
                      "libraries share a version and what has to be updated together (Kotlin and KSP, AGP and Gradle, "
                      "Compose Multiplatform and Kotlin). Without project, the current session's project, and if it has "
                      "no catalog, all projects. Changes nothing.",
                      {"project": "project folder name or path; current by default",
                       "prerelease": "also show alpha/beta/rc"}),
    "release_notes_context": ("Material for release notes (\"What's new\"): the app version, commits since the last "
                              "release (last tag, fastlane run or previous notes, whichever is newer), Claude sessions "
                              "for that period, store languages and limits. Then write the text in each language, show "
                              "it to the user and save it with release_notes_write once they agree.",
                              {"project": "project folder name or path; current by default",
                               "since": "tag or commit to count from; found automatically by default"}),
    "release_notes_write": ("Save release notes the user agreed to: fastlane/release_notes/<version>.<language>.txt "
                            "and, if the project has fastlane/metadata, changelogs/<versionCode>.txt and "
                            "release_notes.txt. Returns the command to pass the text to fastlane.",
                            {"notes": "{\"en-US\": \"text\", \"ru-RU\": \"текст\"}",
                             "version_code": "versionCode for metadata/android/…/changelogs"}),
    "parallel_task": ("Run a task in parallel: create a git worktree on a new branch (from the project's current "
                      "commit) and open a second Claude Code there in a new iTerm2 tab (a new window in Terminal) with "
                      "this task and Remote Control. The second Claude commits its result to its branch; parallel_finish "
                      "later merges or drops it. Call it when the user asks to do something in parallel, in the "
                      "background or on a separate branch.",
                      {"task": "task for the second Claude that makes sense without this session's context",
                       "project": "project; current by default",
                       "branch": "branch name; parallel/<from the task> by default",
                       "permission_mode": "permission mode of the second Claude; default is the normal one (it asks, "
                                          "the question arrives as a notification). auto or acceptEdits only if the "
                                          "user said so",
                       "remote_control": "Remote Control; the default comes from agentmeister defaults",
                       "fork": "open the second Claude with this same conversation (a session fork) so it knows the "
                               "whole context; this session doesn't change. Default no, a new session with only the "
                               "task. Set it if the user asks to take the context along"}),
    "parallel_list": ("The project's parallel tasks: branches, how many commits, whether there are uncommitted "
                      "changes, whether Claude is running there.", {}),
    "parallel_finish": ("Finish a parallel task. merge merges its branch into the branch it came from (no push); drop "
                        "throws away the branch and worktree; pr pushes the branch, opens a PR into the source branch, "
                        "waits for CI, merges it and removes the worktree (no_merge only opens the PR). pr can wait for "
                        "CI a long time. Only with the user's consent.",
                        {"no_merge": "for pr: only push and open the PR, don't merge",
                         "force": "for drop: drop even with uncommitted files or unmerged commits. Only if the user "
                                  "said so"}),
    "window_screenshot": ("Screenshot of an app window on this Mac: Chrome, Safari, Android Studio, Xcode, Figma, the "
                          "simulator, VS Code and so on. To see how a page, preview or screen looks right now. Without "
                          "app, the list of open windows (titles, tokens in them hidden). app is the app name or part of "
                          "the title, title narrows by window title. The screenshot comes back as an image. Capture only "
                          "what the user asks for: the screen may show other people's chats and passwords.",
                          {"app": "app: Chrome, Safari, Simulator, Android Studio…",
                           "title": "part of the window title"}),
    "ask_project": ("Ask about another project. A separate read-only Claude (Read, Grep, Glob) runs in its folder and "
                    "returns a short answer with paths and code snippets, so this session's context isn't filled with "
                    "someone else's files. For example: the response format of an endpoint in the backend, how auth "
                    "works in another app, which fields a model has in another repository. Takes up to a couple of "
                    "minutes and uses quota; not needed for your own project, read the files yourself.",
                    {"project": "project folder name or path",
                     "question": "question that makes sense without this session's context",
                     "model": "sonnet (default), opus or haiku"}),
}


def english(tools):
    out = []
    for tool in tools:
        text = EN.get(tool.get("name"))
        if not text:
            out.append(tool)
            continue
        tool = copy.deepcopy(tool)
        tool["description"] = text[0]
        props = (tool.get("inputSchema") or {}).get("properties") or {}
        for key, desc in text[1].items():
            if key in props:
                props[key]["description"] = desc
        out.append(tool)
    return out
