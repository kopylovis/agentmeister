# Tasks: English output for the remaining commands

**Input**: [plan.md](plan.md), [spec.md](spec.md), [contracts/cli-output.md](contracts/cli-output.md)

Format `- [ ] T### [P] [US#] description`. [P] means the task touches its own file and can run in
parallel. Each phase from 2 on is one PR on its own `cli-en/<command>` branch (clarification 2). Inside a
phase, tests are written first and must fail before the code change (Principle III).

## Phase 1: Setup (PR speckit/init)

- [x] T001 Commit `.specify/`, the speckit skills in `.claude/skills/` (force-added, the global gitignore
      hides `.claude/`) and `specs/001-english-remaining-commands/`

## Phase 2: ask (PR cli-en/ask)

- [ ] T002 [US1] Test in `tests/test_ask.py`: with lang en, `claude_ask` help has no Cyrillic; with lang ru
      it equals the current text
- [ ] T003 [US2] Test in `tests/test_ask.py`: errors for a missing project and an empty question are English,
      in the CLI and in the ask_project MCP result (FR-005)
- [ ] T004 [US1] [US2] Wrap help and error strings in `libexec/agentmeister/lib/claude_ask.py` with `tr`;
      the prompt sent to the second Claude stays as is
- [ ] T005 Run `make test`

## Phase 3: shot (PR cli-en/shot)

- [ ] T006 [P] [US1] [US2] Tests in `tests/test_window_shot.py` for help, the window list header and the
      Screen Recording error under lang en, CLI and window_screenshot MCP result (FR-005)
- [ ] T007 [US1] [US2] Wrap strings in `libexec/agentmeister/lib/window_shot.py`, use the English macOS name of
      the permission
- [ ] T008 Run `make test`

## Phase 4: release-notes (PR cli-en/release-notes)

- [ ] T009 [P] [US1] [US2] Tests in `tests/test_release_notes.py` for help, context labels and write errors,
      CLI and release_notes_context MCP result (FR-005)
- [ ] T010 [US1] [US2] Wrap strings in `libexec/agentmeister/lib/release_notes.py`; commit titles and session
      text pass through untouched
- [ ] T011 Run `make test`

## Phase 5: migrate (PR cli-en/migrate)

- [ ] T012 [P] [US1] [US2] Extend `tests/test_migrate_dirs.py` with lang en checks of help and refusals
- [ ] T013 [US1] [US2] Print help from two constants in `libexec/agentmeister/lib/migrate_dirs.py`, wrap the
      remaining messages
- [ ] T014 Run `make test`

## Phase 6: parallel (PR cli-en/parallel)

- [ ] T015 [P] [US1] [US2] Extend `tests/test_parallel.py` with lang en checks of help, list, drop without
      --force, merge and pr errors, and the MCP parallel_* results
- [ ] T016 [US1] [US2] Wrap user-facing strings in `libexec/agentmeister/lib/claude_parallel.py`; the task
      prompt for the new session stays as is
- [ ] T017 Run `make test`

## Phase 7: Polish (goes with the parallel PR)

- [ ] T018 [US3] Drop the Russian-only note from `README.md`
- [ ] T019 Run the manual check from `contracts/cli-output.md`, every count is 0 (SC-001)

## Dependencies

Phase 1 first. Phases 2 to 6 are independent of each other; T018 and T019 go last because SC-001 needs
all five commands done.
