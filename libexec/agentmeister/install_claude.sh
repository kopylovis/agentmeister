#!/usr/bin/env bash
set -eu

# язык вывода как mnrhlib.lang() и cli.sh: AGENTMEISTER_LANG, потом lang= в config, потом первый язык macOS
ui_lang() {
  local v="" cfg="${XDG_CONFIG_HOME:-$HOME/.config}" conf
  case "${AGENTMEISTER_LANG:-}" in [Rr][Uu]) echo ru; return 0 ;; [Ee][Nn]) echo en; return 0 ;; esac
  if [ -d "$cfg/mnrh" ] && [ ! -d "$cfg/agentmeister" ]; then conf="$cfg/mnrh/config"; else conf="$cfg/agentmeister/config"; fi
  if [ -f "$conf" ]; then
    v=$(sed -n '/^[[:space:]]*lang[[:space:]]*=/{s/^[^=]*=[[:space:]]*//;s/[[:space:]]*$//;p;}' "$conf" | tail -1)
  fi
  case "$v" in [Rr][Uu]) echo ru; return 0 ;; [Ee][Nn]) echo en; return 0 ;; esac
  v=$(defaults read -g AppleLanguages 2>/dev/null | sed -n 's/^[^A-Za-z]*\([A-Za-z][A-Za-z]\).*/\1/p' | head -1)
  case "$v" in [Rr][Uu]) echo ru ;; *) echo en ;; esac
}
UI_LANG=$(ui_lang)
# msg <русский> <английский>: строка на языке интерфейса
msg() {
  if [ "$UI_LANG" = en ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}

usage='agentmeister --harness claude install'
case "$#:${1:-}" in
  0:) ;;
  1:-h|1:--help) msg "$usage    установить Claude Code с claude.ai" "$usage    install Claude Code from claude.ai"; exit 0 ;;
  *) msg "$usage не принимает аргументов" "$usage takes no arguments" >&2; exit 2 ;;
esac

native="$HOME/.local/bin/claude"
configured="${MNRH_CLAUDE_BIN:-claude}"
if command -v "$configured" >/dev/null 2>&1; then
  exec "$configured" --version
fi
if [ "$configured" != claude ] && [ "$configured" != "$native" ]; then
  msg "Проверь MNRH_CLAUDE_BIN. Команда $configured не найдена." "Check MNRH_CLAUDE_BIN. Command $configured not found." >&2
  exit 1
fi

if [ ! -x "$native" ]; then
  installer=$(mktemp "${TMPDIR:-/tmp}/agentmeister-install.XXXXXXXX")
  trap 'rm -f "$installer"' EXIT
  msg "Скачиваю установщик Claude Code с claude.ai..." "Downloading the Claude Code installer from claude.ai..." >&2
  curl -q --fail --progress-bar --show-error --location --proto '=https' --proto-redir '=https' \
    https://claude.ai/install.sh > "$installer"
  msg "Установщик Anthropic скачивает и устанавливает Claude Code..." \
    "The Anthropic installer is downloading and installing Claude Code..." >&2
  /bin/bash "$installer"
fi
"$native" --version
if ! command -v "$configured" >/dev/null 2>&1; then
  msg "Добавь $HOME/.local/bin в PATH для запуска claude из терминала." "Add $HOME/.local/bin to PATH to run claude from the terminal."
fi
