# agentmeister Constitution

## Core Principles

### I. Stdlib Python on System Interpreter

CLI code runs on `/usr/bin/python3` and uses only the Python standard library. The entry point
`bin/agentmeister` stays a thin bash dispatcher; logic lives in `libexec/agentmeister/lib`.
New third-party Python packages MUST NOT be added. Rationale: the tool is installed by Homebrew
and bundled inside the app, and it has to work on a clean Mac without pip.

### II. Bilingual Output

Every user-facing string (help, prompts, errors, reports, MCP tool results) MUST exist in Russian
and English and follow the `lang` setting (`ru`, `en`, `auto`). Russian is the reference text and
tests check it with `AGENTMEISTER_LANG=ru`. A feature that prints only one language is incomplete.

### III. Test Every Behavior Change

Each behavior change MUST come with a `unittest` test in `tests/` that fails without the change.
`make test` MUST pass before a PR is merged. Tests MUST NOT touch the real `~/.claude`,
`~/.codex`, Keychain, network or running sessions; they use fixtures and temporary directories.

### IV. Never Lose User State

agentmeister edits files it does not own: Claude Code and Codex settings, session transcripts,
hooks, the proxy config. Such edits MUST be atomic (write to a temp file, then rename), keep
unknown keys intact, and be reversible by the matching `off` or `remove` command. Deleting a
session or file MUST be an explicit user action, never a side effect.

### V. Small Changes, One PR Each

Every finished change goes to its own branch and its own PR into `main`. Commit titles use the
form `<area>: <description>`. Commits are authored by the repository owner only, with no agent
co-author trailers.

## Platform and Stack

- macOS only. The CLI targets the Python and bash that ship with macOS; the desktop app in `app/`
  is Swift for macOS 26 and has its own tests under `app/Tests`.
- Sessions may run inside the proxy sandbox (`sandbox-exec`). Code that needs direct network or
  its own macOS sandbox MUST go through `agentmeister host-run` and never bypass the sandbox.
- `VERSION` is the single source of the version; `agentmeister --version` MUST match it.

## Development Workflow

- A feature starts with `/speckit-specify` when it touches more than one command or file area;
  small fixes go straight to code.
- README.md and README.ru.md MUST be updated in the same PR when a command, flag or menu item
  changes.
- Merge with `gh pr merge --merge --delete-branch`, following the merge commits already in `main`.

## Governance

This constitution overrides habits and defaults of agents working in the repository. Amendments
are made by editing this file in a PR that states the reason. Versioning follows semver: MAJOR
for removed or redefined principles, MINOR for new principles or sections, PATCH for wording.
Every `/speckit-plan` run checks the plan against these principles and records any justified
exception in its Complexity Tracking table.

**Version**: 1.0.0 | **Ratified**: 2026-11-28 | **Last Amended**: 2026-11-28
