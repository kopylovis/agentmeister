# Research: English output for the remaining commands

## How to switch language

- Decision: `mnrhlib.tr(ru, en)` at each print site.
- Rationale: every module translated in the cli-en series (#522 to #527) uses it; tests patch
  `mnrhlib.lang`.
- Alternatives considered: gettext catalogs, rejected because the project has no catalogs and Principle I
  keeps the code simple stdlib.

## Help text kept in a module docstring (migrate)

- Decision: keep the Russian docstring as the code comment and print help from two string constants
  chosen by `tr`.
- Rationale: the docstring is printed as help today; translating it in place would lose the Russian text.

## Name of the macOS permission in English

- Decision: "Screen & System Audio Recording", the label in System Settings → Privacy & Security on macOS 15
  and later; Russian stays "Запись экрана".
- Rationale: the message has to match what the person sees in Settings. `mnrhlib.settings_path` already
  maps Settings names by system language and is reused if it has the key.

## Agent-facing text

- Decision: unchanged (clarification 1). Strings passed to `claude -p` or into the new session's first
  prompt stay Russian.
