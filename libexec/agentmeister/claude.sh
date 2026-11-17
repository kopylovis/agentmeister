#!/usr/bin/env bash
set -uo pipefail

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/mnrh/config"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

projects_dir() {
  local d="${MNRH_PROJECTS:-}"
  [ -z "$d" ] && [ -f "$CONF" ] && d=$(sed -n 's/^projects=//p' "$CONF" | head -1)
  d="${d:-$HOME/Developer}"
  d="${d/#\~/$HOME}"
  echo "$d"
}
CLAUDE_BIN="${MNRH_CLAUDE_BIN:-claude}"
MENU="$LIB/menu.py"

help() {
  cat <<'EOF'
Запуск
  agentmeister                     меню (MNRH_NO_MENU=1 сразу к выбору проекта)
  agentmeister open                выбрать проект в папке проектов
  agentmeister <имя>               сразу в проекте (начала имени хватит) или в папке по пути
  agentmeister --harness codex     запустить Codex или настроить его через setup
  agentmeister root                в домашней папке
  agentmeister ... -k | -n         caffeinate или обычная сессия, без вопроса
  agentmeister ... -x | -d         через свой VPS или напрямую, без вопроса
  agentmeister ... --new           новая сессия, не предлагать сохраненные
  agentmeister ... -i              без записи на диск: ни переписки, ни истории промптов
  agentmeister ... -- <аргументы>  аргументы для claude: agentmeister kcalm -- --continue
  agentmeister sessions            сохраненные сессии: продолжить, перенести, удалить (sessions -h)
  agentmeister ps                  запущенные сессии: кто ждет ответа, перейти во вкладку
  agentmeister restore             вернуть сессии, открытые до перезагрузки или сбоя
  agentmeister usage               токены и активное время по проектам (--days N, --project P)

Изнутри Claude Code (они же /restart, /forget, /fresh, /slim)
  agentmeister restart             закрыть и открыть эту же сессию, с claude update
  agentmeister forget              удалить эту сессию без следа и открыть чистую
  agentmeister fresh               новая сессия без названия, эта остается в /resume
  agentmeister slim                сжать эту сессию и открыть снова

Режимы (on, off)
  agentmeister humanize            правила письма без признаков нейросети; check <файл>, rules
  agentmeister guard               вопрос перед чтением ключей и опасными командами; test, log
  agentmeister buildlog            выжимка длинного вывода сборок для Claude; test <файл>
  agentmeister notify              уведомления, когда Claude ждет; after <сек>, test, telegram
  agentmeister lid                 не засыпать с закрытой крышкой; setup, release, remove

Прокси через свой VPS
  agentmeister proxy               состояние; setup, test, update, restart, remove (proxy -h)

Инструменты проекта (Claude зовет их и сам)
  agentmeister brief               где мы остановились: git, прошлая сессия, бэклог (/where)
  agentmeister todo                бэклог проекта между сессиями (/todo, todo -h)
  agentmeister parallel "<…>"      задача в своей ветке и worktree, во втором окне (/parallel)
  agentmeister ask <пр> <…>        спросить отдельный Claude про другой проект (/ask)
  agentmeister release-notes       материал для "Что нового" к релизу (/release-notes)
  agentmeister shot                снимок окна приложения (/shot)
  agentmeister deps                устаревшие зависимости Gradle в gradle/libs.versions.toml

Установка
  agentmeister setup               команды, хуки, MCP-сервер, хук zsh, прокси, promptsill (setup -h)
  agentmeister doctor              проверить установку
  agentmeister alias               короткое имя am; on, off
  agentmeister --version           версия

caffeinate (по умолчанию) не даёт Mac уснуть, пока идёт сессия:
удобно для долгих задач и Remote Control с телефона. Экран при этом гаснуть может.
С закрытой крышкой на батарее Mac все равно уснет, caffeinate этого не отменяет.
agentmeister lid setup разрешит не засыпать и с закрытой крышкой (спросит пароль sudo).
Папка проектов: ~/Developer, строка projects=<путь> в ~/.config/mnrh/config или MNRH_PROJECTS=<путь>.
EOF
}

case "${1:-}" in
  open) shift ;;
  proxy) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_proxy.py" "$@" ;;
  sessions) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_sessions.py" "$@" ;;
  usage) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_usage.py" "$@" ;;
  brief) exec /usr/bin/python3 "$(dirname "$MENU")/claude_brief.py" "$@" ;;
  ps) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_live.py" ps "$@" ;;
  restore) exec /usr/bin/python3 "$(dirname "$MENU")/claude_live.py" "$@" ;;
  doctor) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_doctor.py" "$@" ;;
  lid) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_lid.py" "$@" ;;
  alias) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_alias.py" "$@" ;;
  parallel) exec /usr/bin/python3 "$(dirname "$MENU")/claude_parallel.py" "$@" ;;
  ask) exec /usr/bin/python3 "$(dirname "$MENU")/claude_ask.py" "$@" ;;
  release-notes) exec /usr/bin/python3 "$(dirname "$MENU")/release_notes.py" "$@" ;;
  statusline) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_status.py" "$@" ;;
  humanize|humanize-hook) exec /usr/bin/python3 "$(dirname "$MENU")/claude_humanize.py" "$@" ;;
  buildlog|buildlog-hook) exec /usr/bin/python3 "$(dirname "$MENU")/claude_buildlog.py" "$@" ;;
  guard|guard-hook) exec /usr/bin/python3 "$(dirname "$MENU")/claude_guard.py" "$@" ;;
  approve-hook) grep -qsx "telegram_approve=on" "$CONF" || exit 0; exec /usr/bin/python3 "$(dirname "$MENU")/telegram_approve.py" "$@" ;;
  notify|notify-hook|focus) exec /usr/bin/python3 "$(dirname "$MENU")/claude_notify.py" "$@" ;;
  restart|forget|fresh|slim|mcp|setup|notice|session-end) exec /usr/bin/python3 "$(dirname "$MENU")/claude_restart.py" "$@" ;;
esac

target="" mode="" net="" new=0 passthrough=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) help; exit 0 ;;
    -n|--normal) mode=normal ;;
    -k|--caffeinate) mode=caffeinate ;;
    -x|--proxy) net=vps ;;
    -d|--direct) net=direct ;;
    --new) new=1 ;;
    -i|--incognito) new=1; export CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 ;;
    --) shift; passthrough=("$@"); break ;;
    -*) echo "claudemeister: неизвестный флаг $1" >&2; exit 2 ;;
    *) [ -z "$target" ] && target="$1" || { echo "claudemeister: лишний аргумент $1" >&2; exit 2; } ;;
  esac
  shift
done

if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "claudemeister: нужен терминал — Claude Code интерактивный." >&2
  exit 2
fi

# setup на этом Mac не делали или после обновления в нем появился новый шаг: предложить настроить
/usr/bin/python3 "$LIB/claude_setup.py" check

DEV=$(projects_dir)
# папку проектов спрашивает mnrh init, если стоит полный mnrh; без него остаются ~ и пути
if [ ! -f "$CONF" ] && [ -z "${MNRH_PROJECTS:-}" ] && [ ! -d "$DEV" ] && command -v mnrh >/dev/null; then
  mnrh init --projects-only || exit 1
  DEV=$(projects_dir)
fi

dirs=()
for d in "$DEV"/*/; do
  [ -d "$d" ] && dirs+=("${d%/}")
done

match() {
  local q="$1" d found=()
  for d in ${dirs[@]+"${dirs[@]}"}; do
    case "$(basename "$d")" in "$q") echo "$d"; return 0 ;; esac
  done
  for d in ${dirs[@]+"${dirs[@]}"}; do
    case "$(basename "$d")" in "$q"*) found+=("$d") ;; esac
  done
  if [ "${#found[@]}" -eq 1 ]; then echo "${found[0]}"; return 0; fi
  if [ "${#found[@]}" -gt 1 ]; then
    echo "claudemeister: «${q}» подходит к нескольким: $(for f in "${found[@]}"; do printf '%s ' "$(basename "$f")"; done)" >&2
  else
    echo "claudemeister: проекта «${q}» нет в ${DEV/#$HOME/~}" >&2
  fi
  return 1
}

dir=""
if [ -z "$target" ]; then
  :
elif [ "$target" = "root" ] || [ "$target" = "~" ]; then
  dir="$HOME"
elif case "$target" in */*) true ;; *) false ;; esac && [ -d "$target" ]; then
  dir=$(cd "$target" && pwd)
else
  dir=$(match "$target") || exit 1
fi

for a in ${passthrough[@]+"${passthrough[@]}"}; do
  case "$a" in
    -c|--continue|-r|--resume|--resume=*|--session-id|--session-id=*|-p|--print|--teleport|--teleport=*|--from-pr|--from-pr=*) new=1 ;;
  esac
done

# недостающее (проект, сессия, режим, сеть) спрашивает один процесс на одном экране: между вопросами не мигает
PROXY="$LIB/claude_proxy.py"
ask=()
[ -n "$dir" ] && ask+=(--dir "$dir")
[ "$new" -eq 1 ] && ask+=(--no-session)
[ -n "$mode" ] && ask+=(--mode "$mode")
[ -n "$net" ] && ask+=(--net "$net")
if [ -z "$dir" ] || [ "$new" -eq 0 ] || [ -z "$mode" ] || { [ -z "$net" ] && /usr/bin/python3 "$PROXY" configured; }; then
  out=$(/usr/bin/python3 "$LIB/open_flow.py" ${ask[@]+"${ask[@]}"}) || exit $?
  { read -r dir; read -r sid; read -r mode; read -r net; } <<<"$out"
  [ -n "$sid" ] && [ "$sid" != new ] && passthrough=(--resume "$sid" ${passthrough[@]+"${passthrough[@]}"})
fi
[ -n "$mode" ] || mode=caffeinate
[ -n "$net" ] || net=direct
pre=()
if [ "$net" = vps ]; then
  /usr/bin/python3 "$PROXY" configured || { echo "claudemeister: прокси не настроен или нет mihomo: claudemeister proxy setup" >&2; exit 1; }
  pre=(/usr/bin/python3 "$PROXY" run --)
fi

cd "$dir" || exit 1
echo "-> ${dir/#$HOME/~} · $mode$([ "$net" = vps ] && echo ' · через VPS')$([ "${CLAUDE_CODE_SKIP_PROMPT_HISTORY:-}" = 1 ] && echo ' · без записи')"
# после claudemeister lid setup сторож держит Mac и с закрытой крышкой; без правила шаг молча пропускается
if [ "$mode" = caffeinate ]; then
  /usr/bin/python3 "$LIB/claude_lid.py" keep >/dev/null 2>&1
  exec ${pre[@]+"${pre[@]}"} caffeinate -is "$CLAUDE_BIN" "${passthrough[@]+"${passthrough[@]}"}"
else
  exec ${pre[@]+"${pre[@]}"} "$CLAUDE_BIN" "${passthrough[@]+"${passthrough[@]}"}"
fi
