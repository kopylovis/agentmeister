import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import PROMPTSILL_HINT, promptsill_path, tr

path = promptsill_path()
if path:
    os.execv(path, [path, *sys.argv[1:]])
if not sys.stdin.isatty():
    print(tr(f"строка состояния теперь отдельная программа promptsill: {PROMPTSILL_HINT}",
             f"the status line is now a separate program, promptsill: {PROMPTSILL_HINT}"))
    sys.exit(0)
print(tr("Строка состояния Claude Code теперь отдельная программа promptsill, agentmeister statusline передаёт ей команды.",
         "The Claude Code status line is now a separate program, promptsill. agentmeister statusline passes commands to it."))
print(tr(f"Поставить: {PROMPTSILL_HINT}, потом agentmeister setup. Подробнее: https://github.com/kopylovis/promptsill",
         f"Install: {PROMPTSILL_HINT}, then agentmeister setup. More: https://github.com/kopylovis/promptsill"))
sys.exit(0 if any(a in ("-h", "--help") for a in sys.argv[1:]) else 1)
