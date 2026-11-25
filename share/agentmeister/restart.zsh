# Хук перезапуска: /restart, /forget, /fresh, /slim кладут задание в ~/.cache/mnrh/restart/<tty>, а этот хук
# перед следующим приглашением снова открывает Claude в этой вкладке. Задание — JSON с данными, его пишет и
# сессия из песочницы, поэтому как команду shell его не выполняем: restart_job.py проверяет поля и сам строит
# argv. 2 — версия хука: с ним agentmeister пишет задания в JSON, со старым (1) в эту вкладку не пишет.
export MNRH_RESTART_HOOK=2
# терминал вкладки для /slim, /forget и /fresh: в песочнице proxy-сессии ps его не узнает
export MNRH_TTY=$TTY
typeset -g _mnrh_restart_job=${${(%):-%x}:a:h:h:h}/libexec/agentmeister/lib/restart_job.py

_mnrh_restart() {
  local f=$HOME/.cache/mnrh/restart/${TTY:t} out
  local -a job
  while [[ -e $f || -L $f ]]; do
    out=$(/usr/bin/python3 -I -B $_mnrh_restart_job take $f) || return 0
    job=( "${(@0)out}" )
    (( $#job == 3 )) || return 0
    cd -- $job[1] || return 0
    print -s -- $job[2]
    /usr/bin/python3 -I -B $_mnrh_restart_job run $job[3]
  done
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _mnrh_restart
