#!/usr/bin/env bash
set -eu

usage='agentmeister --harness claude install'
case "$#:${1:-}" in
  0:) ;;
  1:-h|1:--help) echo "$usage    установить Claude Code с claude.ai"; exit 0 ;;
  *) echo "$usage не принимает аргументов" >&2; exit 2 ;;
esac

native="$HOME/.local/bin/claude"
configured="${MNRH_CLAUDE_BIN:-claude}"
if command -v "$configured" >/dev/null 2>&1; then
  exec "$configured" --version
fi
if [ "$configured" != claude ] && [ "$configured" != "$native" ]; then
  echo "Проверь MNRH_CLAUDE_BIN. Команда $configured не найдена." >&2
  exit 1
fi

if [ ! -x "$native" ]; then
  installer=$(mktemp "${TMPDIR:-/tmp}/agentmeister-install.XXXXXXXX")
  trap 'rm -f "$installer"' EXIT
  curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    https://claude.ai/install.sh > "$installer"
  /bin/bash "$installer"
fi
"$native" --version
if ! command -v "$configured" >/dev/null 2>&1; then
  echo "Добавь $HOME/.local/bin в PATH для запуска claude из терминала."
fi
