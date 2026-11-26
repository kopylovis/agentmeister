#!/usr/bin/env bash
set -uo pipefail

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/mnrh/config"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

# папки, в которых лежат проекты: projects=<путь>[:<путь>...] в config или MNRH_PROJECTS, по одной в строке
projects_dirs() {
  local d="${MNRH_PROJECTS:-}" p seen=":"
  [ -z "$d" ] && [ -f "$CONF" ] && d=$(sed -n 's/^projects=//p' "$CONF" | head -1)
  d="${d:-$HOME/Developer}"
  local IFS=':'
  for p in $d; do
    # как mnrhlib.projects_dirs: пробелы по краям и / в конце не в счет, повтор той же папки пропускается
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    p="${p/#\~/$HOME}"
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    [ -n "$p" ] || continue
    p=$(cd "$p" 2>/dev/null && pwd -P || echo "$p")
    case "$seen" in *":$p:"*) continue ;; esac
    seen="$seen$p:"
    echo "$p"
  done
}
projects_dir() {
  projects_dirs | head -1
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
  agentmeister --harness claude status   версия и открытые сессии Claude Code
  agentmeister --harness codex statusline   лимиты и контекст Codex через promptsill
  agentmeister --harness codex restart [ID]   снова открыть сессию Codex
  agentmeister root                в домашней папке
  agentmeister ... -k | -n         caffeinate или обычная сессия, без вопроса
  agentmeister ... -x | -d         через proxy или напрямую, без вопроса
  agentmeister ... -x <подписка>   только через эту подписку proxy (agentmeister proxy list)
  agentmeister ... --new           новая сессия, не предлагать сохраненные
  agentmeister ... -i              без записи на диск: ни переписки, ни истории промптов
  agentmeister ... -- <аргументы>  аргументы для claude: agentmeister kcalm -- --continue
  agentmeister sessions            сохраненные сессии: продолжить, перенести, удалить (sessions -h)
  agentmeister ps                  запущенные сессии: кто ждет ответа, перейти во вкладку
  agentmeister restore             вернуть сессии, открытые до перезагрузки или сбоя
  agentmeister usage               токены и активное время по проектам (--days N, --project P)

Изнутри Claude Code (они же /restart, /forget, /fresh, /slim)
  agentmeister restart             закрыть и открыть эту же сессию, с обновлением Claude Code
  agentmeister agent-update claude|codex  обновить агента тем способом, каким он установлен
  agentmeister forget              удалить эту сессию без следа и открыть чистую
  agentmeister fresh               новая сессия без названия, эта остается в /resume
  agentmeister slim                сжать эту сессию и открыть снова

Режимы (on, off)
  agentmeister humanize            правила письма без признаков нейросети; check <файл>, rules
  agentmeister guard               вопрос перед чтением ключей и опасными командами; test, log
  agentmeister buildlog            выжимка длинного вывода сборок для Claude; test <файл>
  agentmeister notify              уведомления, когда Claude ждет; after <сек>, test, telegram
  agentmeister lid                 не засыпать с закрытой крышкой; setup, release, remove

Прокси для сессий
  agentmeister proxy               состояние; setup, test, update, restart, remove (proxy -h)
  agentmeister host-run <имя>      команда из белого списка вне песочницы proxy (host-run -h)

Инструменты проекта (Claude зовет их и сам)
  agentmeister codex-context       читать сессии, инструкции и память Codex (codex-context -h)
  agentmeister brief               где мы остановились: git, прошлая сессия, бэклог (/where)
  agentmeister todo                бэклог проекта между сессиями (/todo, todo -h)
  agentmeister parallel "<…>"      задача в своей ветке и worktree, во втором окне (/parallel)
  agentmeister ask <пр> <…>        спросить отдельный Claude про другой проект (/ask)
  agentmeister release-notes       материал для "Что нового" к релизу (/release-notes)
  agentmeister shot                снимок окна приложения (/shot)
  agentmeister deps                устаревшие зависимости Gradle в gradle/libs.versions.toml

Установка
  agentmeister --harness codex install    установить Codex CLI через Homebrew
  agentmeister --harness claude install   установить Claude Code с claude.ai
  agentmeister setup               команды, хуки, MCP-сервер, хук zsh, прокси, promptsill (setup -h)
  agentmeister doctor              проверить установку
  agentmeister app-state           состояние для десктопного Agentmeister в JSON
  agentmeister lang [ru|en|auto]   язык интерфейса, auto берет язык macOS
  agentmeister projects-dir [add|remove] <папка>|default  папки, в которых лежат проекты (по умолчанию ~/Developer)
  agentmeister alias               короткое имя am; on, off
  agentmeister --version           версия

caffeinate (по умолчанию) не даёт Mac уснуть, пока идёт сессия:
удобно для долгих задач и Remote Control с телефона. Экран при этом гаснуть может.
С закрытой крышкой на батарее Mac все равно уснет, caffeinate этого не отменяет.
agentmeister lid setup разрешит не засыпать и с закрытой крышкой (спросит пароль sudo).
Папки с проектами: ~/Developer, agentmeister projects-dir add <папка>, строка projects=<путь>[:<путь>] в ~/.config/mnrh/config или MNRH_PROJECTS.
EOF
}

case "${1:-}" in
  open) shift ;;
  proxy) shift; exec /usr/bin/python3 "$(dirname "$MENU")/proxy.py" "$@" ;;
  host-run) shift; exec /usr/bin/python3 "$LIB/host_run.py" "$@" ;;
  sessions) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_sessions.py" "$@" ;;
  usage) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_usage.py" "$@" ;;
  codex-context) shift; exec /usr/bin/python3 "$LIB/codex_context.py" "$@" ;;
  brief) exec /usr/bin/python3 "$(dirname "$MENU")/claude_brief.py" "$@" ;;
  ps) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_live.py" ps "$@" ;;
  app-state) shift; exec /usr/bin/python3 "$LIB/app_state.py" "$@" ;;
  agent-update) shift; exec /usr/bin/python3 "$LIB/agent_update.py" "$@" ;;
  lang) shift; exec /usr/bin/python3 "$LIB/app_state.py" lang "$@" ;;
  projects-dir) shift; exec /usr/bin/python3 "$LIB/app_state.py" projects-dir "$@" ;;
  restore) exec /usr/bin/python3 "$(dirname "$MENU")/claude_live.py" "$@" ;;
  doctor) shift; exec /usr/bin/python3 "$(dirname "$MENU")/doctor.py" "$@" ;;
  lid) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_lid.py" "$@" ;;
  alias) shift; exec /usr/bin/python3 "$(dirname "$MENU")/alias.py" "$@" ;;
  parallel) exec /usr/bin/python3 "$(dirname "$MENU")/claude_parallel.py" "$@" ;;
  ask) exec /usr/bin/python3 "$(dirname "$MENU")/claude_ask.py" "$@" ;;
  release-notes) exec /usr/bin/python3 "$(dirname "$MENU")/release_notes.py" "$@" ;;
  statusline) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_status.py" "$@" ;;
  humanize|humanize-hook) exec /usr/bin/python3 "$(dirname "$MENU")/humanize.py" "$@" ;;
  buildlog|buildlog-hook) exec /usr/bin/python3 "$(dirname "$MENU")/claude_buildlog.py" "$@" ;;
  guard|guard-hook) exec /usr/bin/python3 "$(dirname "$MENU")/claude_guard.py" "$@" ;;
  approve-hook) grep -qsx "telegram_approve=on" "$CONF" || exit 0; exec /usr/bin/python3 "$(dirname "$MENU")/telegram_approve.py" "$@" ;;
  notify|notify-hook|focus) exec /usr/bin/python3 "$(dirname "$MENU")/notify.py" "$@" ;;
  restart|forget|fresh|slim|mcp|setup|notice|session-end) exec /usr/bin/python3 "$(dirname "$MENU")/claude_restart.py" "$@" ;;
esac

# подписка proxy для -x <имя>: main или та, что добавлена через agentmeister proxy add
proxy_sub() {
  case "$1" in ''|*[!a-z0-9-]*|[!a-z]*) return 1 ;; esac
  # тот же список, что у proxy list: subs.json, а не файлы ссылок
  /usr/bin/python3 "$LIB/proxy.py" names 2>/dev/null | grep -qx -- "$1"
}

target="" mode="" net="" new=0 passthrough=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) help; exit 0 ;;
    -n|--normal) mode=normal ;;
    -k|--caffeinate) mode=caffeinate ;;
    -x|--proxy) net=vps
      # -x home: только через подписку home. Имя проекта, совпавшее с подпиской, пиши до -x или путем
      if [ $# -gt 1 ] && proxy_sub "$2"; then net="vps:$2"; shift; fi ;;
    -x=*|--proxy=*)
      [ -n "${1#*=}" ] || { echo "agentmeister: после $1 нужно имя подписки, список: agentmeister proxy list" >&2; exit 2; }
      net="vps:${1#*=}" ;;
    -d|--direct) net=direct ;;
    --new) new=1 ;;
    -i|--incognito) new=1; export CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 ;;
    --) shift; passthrough=("$@"); break ;;
    -*) echo "agentmeister: неизвестный флаг $1" >&2; exit 2 ;;
    *) [ -z "$target" ] && target="$1" || { echo "agentmeister: лишний аргумент $1" >&2; exit 2; } ;;
  esac
  shift
done

if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "agentmeister: нужен терминал — Claude Code интерактивный." >&2
  exit 2
fi

# setup на этом Mac не делали или после обновления в нем появился новый шаг: предложить настроить
/usr/bin/python3 "$LIB/setup_steps.py" check

DEV=$(projects_dir)
# папку проектов спрашивает mnrh init, если стоит полный mnrh; без него остаются ~ и пути
if [ ! -f "$CONF" ] && [ -z "${MNRH_PROJECTS:-}" ] && [ ! -d "$DEV" ] && command -v mnrh >/dev/null; then
  mnrh init --projects-only || exit 1
  DEV=$(projects_dir)
fi

dirs=()
while IFS= read -r root; do
  for d in "$root"/*/; do
    [ -d "$d" ] && dirs+=("${d%/}")
  done
done < <(projects_dirs)

match() {
  local q="$1" d found=()
  # точное имя; одноименные проекты в разных папках проектов дают выбор по пути
  for d in ${dirs[@]+"${dirs[@]}"}; do
    case "$(basename "$d")" in "$q") found+=("$d") ;; esac
  done
  if [ "${#found[@]}" -eq 1 ]; then echo "${found[0]}"; return 0; fi
  if [ "${#found[@]}" -gt 1 ]; then
    echo "agentmeister: «${q}» есть в нескольких папках проектов: $(for f in "${found[@]}"; do printf '%s ' "${f/#$HOME/~}"; done), укажи путь" >&2
    return 1
  fi
  for d in ${dirs[@]+"${dirs[@]}"}; do
    case "$(basename "$d")" in "$q"*) found+=("$d") ;; esac
  done
  if [ "${#found[@]}" -eq 1 ]; then echo "${found[0]}"; return 0; fi
  if [ "${#found[@]}" -gt 1 ]; then
    echo "agentmeister: «${q}» подходит к нескольким: $(for f in "${found[@]}"; do printf '%s ' "$(basename "$f")"; done)" >&2
  else
    echo "agentmeister: проекта «${q}» нет в $(projects_dirs | sed "s|^$HOME|~|" | paste -sd ',' - | sed 's/,/, /g')" >&2
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
PROXY="$LIB/proxy.py"
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
via=""
case "$net" in vps:*) via="${net#vps:}" ;; esac
if [ "${net%%:*}" = vps ]; then
  /usr/bin/python3 "$PROXY" configured || { echo "agentmeister: прокси не настроен или нет mihomo: agentmeister proxy setup" >&2; exit 1; }
  pre=(/usr/bin/python3 "$PROXY" run --claude ${via:+--via "$via"} --)
else
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
  unset MNRH_PROXY MNRH_PROXY_SUB PROMPTSILL_PROXY_LABEL PROMPTSILL_PROXY_DETAIL PROMPTSILL_PROXY_URL PROMPTSILL_PROXY_FILE
fi

cd "$dir" || exit 1
echo "-> ${dir/#$HOME/~} · $mode$([ "${net%%:*}" = vps ] && echo " · через proxy${via:+ $via}")$([ "${CLAUDE_CODE_SKIP_PROMPT_HISTORY:-}" = 1 ] && echo ' · без записи')"
# после agentmeister lid setup сторож держит Mac и с закрытой крышкой; без правила шаг молча пропускается
if [ "$mode" = caffeinate ]; then
  /usr/bin/python3 "$LIB/claude_lid.py" keep >/dev/null 2>&1
  exec ${pre[@]+"${pre[@]}"} caffeinate -is "$CLAUDE_BIN" "${passthrough[@]+"${passthrough[@]}"}"
else
  exec ${pre[@]+"${pre[@]}"} "$CLAUDE_BIN" "${passthrough[@]+"${passthrough[@]}"}"
fi
