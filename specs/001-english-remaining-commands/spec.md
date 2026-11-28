# Feature Specification: English output for the remaining commands

**Feature Branch**: `speckit/init`

**Created**: 2026-11-28

**Status**: Draft

**Input**: User description: "English for agentmeister -h and agentmeister proxy -h". Both already print
English when lang is en (commits 489f0fa and 1608c38); README.md still says they are Russian only. With
lang=en, five commands still print Russian: parallel, ask, release-notes, shot, migrate. The feature
covers those five and the README note.

## Clarifications

### Session 2026-11-28

- Q: Should agent-facing text around the task of `parallel` and the question of `ask` be translated when
  lang is en? A: No, only text shown to the person changes language.
- Q: How is the work split into PRs? A: One PR per command (parallel, ask, release-notes, shot, migrate),
  the README note goes with the last one; Spec Kit itself goes in a separate PR first.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Help of every command is in English (Priority: P1)

A user with lang=en (or lang=auto on an English macOS) runs `agentmeister <command> -h` for parallel,
ask, release-notes, shot or migrate and reads the usage in English, as with every other command.

**Why this priority**: help is the first thing a new English-speaking user sees, and these five are the
only gaps left after the cli-en series.

**Independent Test**: run each command with `-h` under lang=en and check the output has no Cyrillic.

**Acceptance Scenarios**:

1. **Given** lang=en, **When** the user runs `agentmeister parallel -h`, **Then** every line is English and
   lists the same subcommands and flags as the Russian help.
2. **Given** lang=ru, **When** the user runs the same five help commands, **Then** the output is byte for
   byte the same as before the change.

---

### User Story 2 - Messages while the command runs are in English (Priority: P2)

A user with lang=en runs these commands for real (starts a parallel task, lists and merges it, asks
another project, takes a screenshot, prepares release notes, runs migrate) and gets errors, prompts,
confirmations and reports in English.

**Why this priority**: help alone is not enough, a Russian error in the middle of `parallel merge`
blocks an English-speaking user.

**Independent Test**: drive each command through its error and success paths under lang=en in tests and
check printed text for Cyrillic.

**Acceptance Scenarios**:

1. **Given** lang=en and a branch with uncommitted changes, **When** the user runs
   `agentmeister parallel drop <branch>` without --force, **Then** the refusal explains in English why and
   mentions --force.
2. **Given** lang=en and no Screen Recording permission, **When** the user runs `agentmeister shot Safari`,
   **Then** the message names the permission as it appears in English macOS Settings.

---

### User Story 3 - README no longer claims Russian-only help (Priority: P3)

A reader of README.md does not see the "Russian only for now" note, since it is no longer true.

**Why this priority**: documentation only, no behavior change.

**Independent Test**: the note is gone from README.md, and README.ru.md has no matching note.

**Acceptance Scenarios**:

1. **Given** the change is merged, **When** a reader opens README.md, **Then** the language paragraph says
   the menu and the CLI follow the macOS language without exceptions.

### Edge Cases

- lang=auto on a macOS whose first language is neither Russian nor English: output follows the existing
  lang rule (English), no new rule is introduced.
- Text that goes to another Claude session (the task prompt of `parallel`, the question of `ask`) and the
  JSON of `parallel --prepare` are agent-facing, not user-facing; they stay as they are.
- Paths, flags, branch names and command names inside messages are not translated.
- `release-notes` prints project data (commit titles, session text) as is; only the labels around it
  change language.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: With lang=en, `-h` output of parallel, ask, release-notes, shot and migrate MUST contain no
  Cyrillic characters.
- **FR-002**: With lang=en, every message these five commands print to the user on stdout or stderr MUST be
  English, except project data they echo back.
- **FR-003**: With lang=ru, all output of these commands MUST stay unchanged.
- **FR-004**: English help MUST list the same subcommands, flags and defaults as the Russian help.
- **FR-005**: The MCP tools behind these commands (ask_project, window_screenshot, parallel_task,
  parallel_list, parallel_finish, release_notes_context) MUST return English text when lang is en, as the
  other MCP tools already do.
- **FR-006**: README.md MUST drop the Russian-only note.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A scan of `-h` for every agentmeister command under lang=en finds zero Cyrillic lines
  (today: 31 lines in five commands).
- **SC-002**: `make test` passes, and the existing Russian assertions pass without edits.
- **SC-003**: Each of the five commands has at least one test that checks English output.

## Assumptions

- The English wording follows the style of the already translated commands (short, lowercase descriptions
  in help).
- Agent-facing prompts and JSON stay out of scope (see Edge Cases).
- The Agentmeister desktop app is out of scope; it has its own localization.
