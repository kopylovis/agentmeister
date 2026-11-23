# Старый путь хука перезапуска. Строки в ~/.zshrc, поставленные до переименования, ведут сюда, а
# agentmeister setup переписывает их на share/agentmeister/restart.zsh.
source "${${(%):-%x}:A:h:h}/agentmeister/restart.zsh"
