#!/usr/bin/env bash
set -uo pipefail

# как mnrhlib.app_dir: старое имя mnrh, пока папку не перенесли (agentmeister migrate)
CFG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
if [ -d "$CFG_HOME/mnrh" ] && [ ! -d "$CFG_HOME/agentmeister" ]; then CONF="$CFG_HOME/mnrh/config"; else CONF="$CFG_HOME/agentmeister/config"; fi
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

# язык вывода как mnrhlib.lang(): AGENTMEISTER_LANG, потом lang= в config, потом первый язык macOS
ui_lang() {
  local v=""
  case "${AGENTMEISTER_LANG:-}" in [Rr][Uu]) echo ru; return 0 ;; [Ee][Nn]) echo en; return 0 ;; esac
  if [ -f "$CONF" ]; then
    v=$(sed -n '/^[[:space:]]*lang[[:space:]]*=/{s/^[^=]*=[[:space:]]*//;s/[[:space:]]*$//;p;}' "$CONF" | tail -1)
  fi
  case "$v" in [Rr][Uu]) echo ru; return 0 ;; [Ee][Nn]) echo en; return 0 ;; esac
  v=$(defaults read -g AppleLanguages 2>/dev/null | sed -n 's/^[^A-Za-z]*\([A-Za-z][A-Za-z]\).*/\1/p' | head -1)
  case "$v" in [Rr][Uu]) echo ru ;; *) echo en ;; esac
}
UI_LANG=""
is_en() {
  [ -n "$UI_LANG" ] || UI_LANG=$(ui_lang)
  [ "$UI_LANG" = en ]
}
# msg <русский> <английский>: строка на языке интерфейса
msg() {
  if is_en; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}

# папки, в которых лежат проекты: projects=<путь>[:<путь>...] в config или AGENTMEISTER_PROJECTS (MNRH_PROJECTS), по одной в строке
projects_dirs() {
  local d="${AGENTMEISTER_PROJECTS:-${MNRH_PROJECTS:-}}" p seen=":"
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
  if is_en; then
    cat <<'EOF'
Start
  agentmeister                     menu (AGENTMEISTER_NO_MENU=1 goes straight to the project picker)
  agentmeister open                pick a project in the projects folder
  agentmeister <name>              open a project right away (the start of the name is enough) or a folder by path
  agentmeister --harness codex     run Codex or set it up with setup
  agentmeister --harness claude status   Claude Code version and open sessions
  agentmeister --harness codex statusline   Codex limits and context through promptsill
  agentmeister --harness codex restart [ID]   reopen a Codex session
  agentmeister root                in the home folder
  agentmeister ... -k | -n         caffeinate or a normal session, without asking
  agentmeister ... -x | -d         through the proxy or direct, without asking
  agentmeister ... -x <sub>        only through this proxy subscription (agentmeister proxy list)
  agentmeister ... --new           new session, don't offer saved ones
  agentmeister ... -i              nothing written to disk: no transcript, no prompt history
  agentmeister ... -- <args>       arguments for claude: agentmeister kcalm -- --continue
  agentmeister sessions            saved sessions: resume, move, delete (sessions -h)
  agentmeister ps                  running sessions: who is waiting for a reply, jump to the tab
  agentmeister restore             reopen sessions that were open before a reboot or crash
  agentmeister usage               tokens and active time by project (--days N, --project P)
  agentmeister headsup             Heads up notes from Claude Code, closed ones too (headsup -h)

From inside Claude Code (same as /restart, /forget, /fresh, /slim)
  agentmeister restart             close and reopen this session, updating Claude Code
  agentmeister agent-update claude|codex  update the agent the same way it was installed
  agentmeister forget              delete this session without a trace and open a clean one
  agentmeister fresh               new untitled session, this one stays in /resume
  agentmeister slim                compact this session and open it again

Modes (on, off)
  agentmeister humanize            writing rules without AI tells; check <file>, rules
  agentmeister translate           translate prompts to English; key, provider, check, log
  agentmeister guard               ask before reading keys and before dangerous commands; test, log
  agentmeister buildlog            digest of long build output for Claude Code and Codex; test <file>
  agentmeister notify              notifications when Claude is waiting; after <sec>, test, telegram
  agentmeister lid                 stay awake with the lid closed; setup, release, remove

Session proxy
  agentmeister proxy               status; setup, test, update, restart, remove (proxy -h)
  agentmeister host-run <name>     allowlisted command outside the proxy sandbox (host-run -h)

Project tools (Claude also calls them on its own)
  agentmeister codex-context       read Codex sessions, instructions and memory (codex-context -h)
  agentmeister brief               where we left off: git, last session, backlog (/where)
  agentmeister todo                project backlog across sessions (/todo, todo -h)
  agentmeister parallel "<…>"      task in its own branch and worktree, in a second window (/parallel)
  agentmeister ask <proj> <…>      ask a separate Claude about another project (/ask)
  agentmeister release-notes       material for "What's New" in a release (/release-notes)
  agentmeister shot                screenshot of an app window (/shot)
  agentmeister deps                outdated Gradle dependencies in gradle/libs.versions.toml

Install
  agentmeister --harness codex install    install Codex CLI with Homebrew
  agentmeister --harness claude install   install Claude Code from claude.ai
  agentmeister setup               commands, hooks, MCP server, zsh hook, proxy, promptsill (setup -h)
  agentmeister doctor              check the install
  agentmeister app-state           state for the Agentmeister desktop app as JSON
  agentmeister lang [ru|en|auto]   interface language, auto follows the macOS language
  agentmeister defaults            mode and Remote Control for new sessions, update on /restart, /ask model
  agentmeister migrate             move ~/.config/mnrh and other mnrh folders to agentmeister folders
  agentmeister projects-dir [add|remove] <folder>|default  folders that hold your projects (~/Developer by default)
  agentmeister alias               short name am; on, off
  agentmeister --version           version

caffeinate (the default) keeps the Mac awake while a session runs:
handy for long tasks and Remote Control from your phone. The screen can still turn off.
With the lid closed on battery the Mac still sleeps, caffeinate doesn't change that.
agentmeister lid setup lets it stay awake with the lid closed too (asks for your sudo password).
Project folders: ~/Developer, agentmeister projects-dir add <folder>, a projects=<path>[:<path>] line in ~/.config/agentmeister/config or AGENTMEISTER_PROJECTS.
EOF
    return
  fi
  cat <<'EOF'
Запуск
  agentmeister                     меню (AGENTMEISTER_NO_MENU=1 сразу к выбору проекта)
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
  agentmeister headsup             заметки Heads up от Claude Code, и закрытые тоже (headsup -h)

Изнутри Claude Code (они же /restart, /forget, /fresh, /slim)
  agentmeister restart             закрыть и открыть эту же сессию, с обновлением Claude Code
  agentmeister agent-update claude|codex  обновить агента тем способом, каким он установлен
  agentmeister forget              удалить эту сессию без следа и открыть чистую
  agentmeister fresh               новая сессия без названия, эта остается в /resume
  agentmeister slim                сжать эту сессию и открыть снова

Режимы (on, off)
  agentmeister humanize            правила письма без признаков нейросети; check <файл>, rules
  agentmeister translate           перевод промптов на английский; key, provider, check, log
  agentmeister guard               вопрос перед чтением ключей и опасными командами; test, log
  agentmeister buildlog            выжимка длинного вывода сборок для Claude Code и Codex; test <файл>
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
  agentmeister defaults            режим и Remote Control новых сессий, обновление при /restart, модель /ask
  agentmeister migrate             перенести ~/.config/mnrh и другие папки mnrh в папки agentmeister
  agentmeister projects-dir [add|remove] <папка>|default  папки, в которых лежат проекты (по умолчанию ~/Developer)
  agentmeister alias               короткое имя am; on, off
  agentmeister --version           версия

caffeinate (по умолчанию) не даёт Mac уснуть, пока идёт сессия:
удобно для долгих задач и Remote Control с телефона. Экран при этом гаснуть может.
С закрытой крышкой на батарее Mac все равно уснет, caffeinate этого не отменяет.
agentmeister lid setup разрешит не засыпать и с закрытой крышкой (спросит пароль sudo).
Папки с проектами: ~/Developer, agentmeister projects-dir add <папка>, строка projects=<путь>[:<путь>] в ~/.config/agentmeister/config или AGENTMEISTER_PROJECTS.
EOF
}

case "${1:-}" in
  open) shift ;;
  proxy) shift; exec /usr/bin/python3 "$(dirname "$MENU")/proxy.py" "$@" ;;
  host-run) shift; exec /usr/bin/python3 "$LIB/host_run.py" "$@" ;;
  sessions) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_sessions.py" "$@" ;;
  usage) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_usage.py" "$@" ;;
  headsup) shift; exec /usr/bin/python3 "$LIB/headsup.py" "$@" ;;
  codex-context) shift; exec /usr/bin/python3 "$LIB/codex_context.py" "$@" ;;
  brief) exec /usr/bin/python3 "$(dirname "$MENU")/claude_brief.py" "$@" ;;
  ps) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_live.py" ps "$@" ;;
  app-state) shift; exec /usr/bin/python3 "$LIB/app_state.py" "$@" ;;
  agent-update) shift; exec /usr/bin/python3 "$LIB/agent_update.py" "$@" ;;
  lang) shift; exec /usr/bin/python3 "$LIB/app_state.py" lang "$@" ;;
  defaults) shift; exec /usr/bin/python3 "$LIB/session_defaults.py" "$@" ;;
  migrate) shift; exec /usr/bin/python3 "$LIB/migrate_dirs.py" "$@" ;;
  projects-dir) shift; exec /usr/bin/python3 "$LIB/app_state.py" projects-dir "$@" ;;
  restore) exec /usr/bin/python3 "$(dirname "$MENU")/claude_live.py" "$@" ;;
  doctor) shift; exec /usr/bin/python3 "$(dirname "$MENU")/doctor.py" "$@" ;;
  lid) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_lid.py" "$@" ;;
  alias) shift; exec /usr/bin/python3 "$(dirname "$MENU")/alias.py" "$@" ;;
  parallel) exec /usr/bin/python3 "$(dirname "$MENU")/claude_parallel.py" "$@" ;;
  ask) exec /usr/bin/python3 "$(dirname "$MENU")/claude_ask.py" "$@" ;;
  release-notes) exec /usr/bin/python3 "$(dirname "$MENU")/release_notes.py" "$@" ;;
  statusline) shift; exec /usr/bin/python3 "$(dirname "$MENU")/claude_status.py" "$@" ;;
  translate-hook) grep -qsx "translate=on" "$CONF" || exit 0; exec /usr/bin/python3 "$(dirname "$MENU")/translate.py" "$@" ;;
  translate) exec /usr/bin/python3 "$(dirname "$MENU")/translate.py" "$@" ;;
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
      [ -n "${1#*=}" ] || { msg "agentmeister: после $1 нужно имя подписки, список: agentmeister proxy list" \
        "agentmeister: $1 needs a subscription name, list: agentmeister proxy list" >&2; exit 2; }
      net="vps:${1#*=}" ;;
    -d|--direct) net=direct ;;
    --new) new=1 ;;
    -i|--incognito) new=1; export CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 ;;
    --) shift; passthrough=("$@"); break ;;
    -*) msg "agentmeister: неизвестный флаг $1" "agentmeister: unknown flag $1" >&2; exit 2 ;;
    *) [ -z "$target" ] && target="$1" || { msg "agentmeister: лишний аргумент $1" "agentmeister: extra argument $1" >&2; exit 2; } ;;
  esac
  shift
done

if [ ! -t 0 ] || [ ! -t 1 ]; then
  msg "agentmeister: нужен терминал — Claude Code интерактивный." "agentmeister: needs a terminal, Claude Code is interactive." >&2
  exit 2
fi

# setup на этом Mac не делали или после обновления в нем появился новый шаг: предложить настроить
/usr/bin/python3 "$LIB/setup_steps.py" check

DEV=$(projects_dir)
# папку проектов спрашивает mnrh init, если стоит полный mnrh; без него остаются ~ и пути
if [ ! -f "$CONF" ] && [ -z "${AGENTMEISTER_PROJECTS:-${MNRH_PROJECTS:-}}" ] && [ ! -d "$DEV" ] && command -v mnrh >/dev/null; then
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
    local list
    list=$(for f in "${found[@]}"; do printf '%s ' "${f/#$HOME/~}"; done)
    msg "agentmeister: «${q}» есть в нескольких папках проектов: $list, укажи путь" \
      "agentmeister: \"${q}\" is in several project folders: $list, give the path" >&2
    return 1
  fi
  for d in ${dirs[@]+"${dirs[@]}"}; do
    case "$(basename "$d")" in "$q"*) found+=("$d") ;; esac
  done
  if [ "${#found[@]}" -eq 1 ]; then echo "${found[0]}"; return 0; fi
  if [ "${#found[@]}" -gt 1 ]; then
    local list
    list=$(for f in "${found[@]}"; do printf '%s ' "$(basename "$f")"; done)
    msg "agentmeister: «${q}» подходит к нескольким: $list" "agentmeister: \"${q}\" matches several: $list" >&2
  else
    local roots
    roots=$(projects_dirs | sed "s|^$HOME|~|" | paste -sd ',' - | sed 's/,/, /g')
    msg "agentmeister: проекта «${q}» нет в $roots" "agentmeister: no project \"${q}\" in $roots" >&2
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
  /usr/bin/python3 "$PROXY" configured || { msg "agentmeister: прокси не настроен или нет mihomo: agentmeister proxy setup" \
    "agentmeister: the proxy isn't set up or mihomo is missing: agentmeister proxy setup" >&2; exit 1; }
  pre=(/usr/bin/python3 "$PROXY" run --claude ${via:+--via "$via"} --)
else
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
  unset MNRH_PROXY MNRH_PROXY_SUB PROMPTSILL_PROXY_LABEL PROMPTSILL_PROXY_DETAIL PROMPTSILL_PROXY_URL PROMPTSILL_PROXY_FILE
fi

cd "$dir" || exit 1
if is_en; then via_note=" · via proxy" private_note=' · not saved'; else via_note=" · через proxy" private_note=' · без записи'; fi
echo "-> ${dir/#$HOME/~} · $mode$([ "${net%%:*}" = vps ] && echo "$via_note${via:+ $via}")$([ "${CLAUDE_CODE_SKIP_PROMPT_HISTORY:-}" = 1 ] && echo "$private_note")"
# после agentmeister lid setup сторож держит Mac и с закрытой крышкой; без правила шаг молча пропускается
if [ "$mode" = caffeinate ]; then
  /usr/bin/python3 "$LIB/claude_lid.py" keep >/dev/null 2>&1
  exec ${pre[@]+"${pre[@]}"} caffeinate -is "$CLAUDE_BIN" "${passthrough[@]+"${passthrough[@]}"}"
else
  exec ${pre[@]+"${pre[@]}"} "$CLAUDE_BIN" "${passthrough[@]+"${passthrough[@]}"}"
fi
