# Contract: user-facing output under lang=en

For each command C in parallel, ask, release-notes, shot, migrate:

1. `AGENTMEISTER_LANG=en agentmeister C -h` prints no Cyrillic and lists the same subcommands and flags as
   `AGENTMEISTER_LANG=ru agentmeister C -h`.
2. `AGENTMEISTER_LANG=ru agentmeister C -h` is identical to the output before the change.
3. Errors and reports printed to stdout or stderr follow the same rule; project data echoed back
   (commit titles, window titles, the user's question) is exempt.
4. MCP tool results of the command follow `lang` the same way.

Manual check:

```sh
for c in parallel ask release-notes shot migrate; do
  AGENTMEISTER_LANG=en agentmeister $c -h | grep -c '[А-Яа-я]'
done   # every count is 0
```
