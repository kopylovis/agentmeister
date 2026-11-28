# Implementation Plan: English output for the remaining commands

**Branch**: `speckit/init`, then one `cli-en/<command>` branch per PR | **Date**: 2026-11-28 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/001-english-remaining-commands/spec.md`

## Summary

Wrap every user-facing string of parallel, ask, release-notes, shot and migrate in `mnrhlib.tr(ru, en)`,
the same helper the cli-en series used. Russian text stays byte for byte. Agent-facing prompts stay
Russian (clarification 1). Each command ships as its own PR with tests that patch `mnrhlib.lang` to "en"
and assert there is no Cyrillic in what the person sees.

## Technical Context

**Language/Version**: Python 3 from `/usr/bin/python3`, stdlib only; bash dispatcher in `libexec/agentmeister/cli.sh`

**Primary Dependencies**: none new; `mnrhlib.tr` and `mnrhlib.lang`

**Storage**: N/A

**Testing**: `unittest` in `tests/`, run by `make test` with `AGENTMEISTER_LANG=ru`

**Target Platform**: macOS

**Project Type**: CLI plus MCP server (`mcp_server.py`)

**Performance Goals**: N/A, `lang()` reads the config once per call; no measurable change

**Constraints**: Russian output unchanged (FR-003); prompts for other Claude sessions unchanged

**Scale/Scope**: about 210 Cyrillic lines across five modules
(claude_parallel 127, release_notes 42, claude_ask 21, window_shot 19, migrate_dirs partly done)

## Constitution Check

| Principle | Status |
|-----------|--------|
| I. Stdlib Python | Pass, no new imports beyond mnrhlib |
| II. Bilingual Output | This feature closes the remaining gaps |
| III. Test Every Behavior Change | Each PR adds tests with lang patched to en; Russian tests untouched |
| IV. Never Lose User State | Pass, output only; migrate logic is not changed |
| V. Small Changes, One PR Each | One PR per command, as clarified |

Re-check after design: no violations, Complexity Tracking stays empty.

## Project Structure

### Documentation (this feature)

```text
specs/001-english-remaining-commands/
├── spec.md
├── plan.md
├── research.md
├── contracts/cli-output.md
├── checklists/requirements.md
└── tasks.md
```

data-model.md and quickstart.md are skipped: the feature has no data, and the contract file says how to
check it by hand.

### Source Code (repository root)

```text
libexec/agentmeister/lib/
├── claude_ask.py        # ask: help, errors, MCP ask_project result labels
├── claude_parallel.py   # parallel: help, list, merge, drop, pr, MCP parallel_* results
├── release_notes.py     # release-notes: help, context labels, write errors
├── window_shot.py       # shot: help, window list, permission errors, MCP window_screenshot
└── migrate_dirs.py      # migrate: docstring help and remaining messages
tests/
├── test_ask.py          # new
├── test_window_shot.py  # new
├── test_release_notes.py# new
├── test_parallel.py     # extended
└── test_migrate_dirs.py # extended
README.md                # drop the Russian-only note (last PR)
```

## Complexity Tracking

Empty, no violations.
