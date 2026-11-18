---
name: agentmeister
description: Use Agentmeister for humanize, the project backlog, release notes, project handoffs, or restarting Codex.
---

<!-- Managed by agentmeister. -->

Use the user's wording or the request after `$agentmeister` to choose the command. If they only invoked the skill, list the commands below.

- For `restart`, run `agentmeister --harness codex restart --after-exit` and relay its output. Add `--update` when the user asks to update Codex. The user enters `/quit` to close the current CLI.
- For `fresh` and `forget`, point to the native `/new` and `/delete` commands in the Codex input field. Codex handles the session switch and deletion confirmation.
- For `slim`, point to `/compact` to summarize the active context. Codex keeps the saved transcript.
- For `humanize`, run `agentmeister humanize` for status, `agentmeister humanize rules` for the writing rules, or `agentmeister humanize check <file>` to check a draft. A check can also read text on stdin. Exit code 1 means it found matches. Use `agentmeister humanize on` or `off` when the user asks to change the shared setting. For an explicit request to humanize the current draft, apply the rules to the draft without changing the setting.
- For `todo`, use `todo_list`, `todo_add`, and `todo_done` in the Agentmeister MCP server. List by default. Add or finish items when asked. The shell equivalent is `agentmeister todo`.
- For `where`, use Git and `todo_list` to summarize the current branch, uncommitted changes, recent commits, and the open project backlog.
- For `release-notes`, call `release_notes_context` with the project or starting tag if given. Draft user-facing release notes in the project's languages. Use `release_notes_write` once the user asks to save the draft. The shell command `agentmeister release-notes` can gather context if MCP is unavailable.
