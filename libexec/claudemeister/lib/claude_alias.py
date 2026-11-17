"""agentmeister alias: короткое имя am для agentmeister.

am ставится символьной ссылкой в ту же папку, где лежит agentmeister из PATH (так делают make install и формула
Homebrew), а если туда нельзя писать, в ~/.local/bin. Чужой am не трогается: ни в PATH, ни в папке назначения.
Убирается только свой am, то есть ссылка, которая ведет на этот же agentmeister.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import BAD, HOME, OK, ROOT, WARN, tilde  # noqa: E402

NAME = "am"
TARGET = os.path.join(ROOT, "bin", "agentmeister")


def ours(path):
    """Ведет ли path на этот agentmeister."""
    try:
        return os.path.realpath(path) == os.path.realpath(TARGET)
    except OSError:
        return False


def found():
    """am, который найдет shell, или None."""
    return shutil.which(NAME)


def enabled():
    hit = found()
    return bool(hit) and ours(hit)


def folder():
    """Куда ставить am: рядом с agentmeister из PATH, если туда можно писать, иначе ~/.local/bin."""
    main = shutil.which("agentmeister")
    if main and ours(main) and os.access(os.path.dirname(main), os.W_OK):
        return os.path.dirname(main)
    return os.path.join(HOME, ".local", "bin")


def on_path(path):
    return os.path.realpath(path) in {os.path.realpath(p) for p in os.environ.get("PATH", "").split(os.pathsep) if p}


def status():
    hit = found()
    if hit and ours(hit):
        print(f"{OK} am есть: {tilde(hit)} -> agentmeister")
    elif hit:
        print(f"{WARN} am занят другой программой: {tilde(hit)}, agentmeister его не трогает")
    else:
        print(f"{WARN} am нет; agentmeister alias on поставит его в {tilde(folder())}")
    return 0


def turn_on():
    hit = found()
    if hit and ours(hit):
        print(f"{OK} am уже есть: {tilde(hit)}")
        return 0
    if hit:
        print(f"{BAD} am уже занят: {tilde(hit)}. Это другая программа, ставить поверх не буду", file=sys.stderr)
        return 1
    where = folder()
    link = os.path.join(where, NAME)
    if os.path.lexists(link) and not ours(link):
        print(f"{BAD} {tilde(link)} уже есть и ведет не на agentmeister, не трогаю", file=sys.stderr)
        return 1
    try:
        os.makedirs(where, exist_ok=True)
        if os.path.lexists(link):
            os.remove(link)
        os.symlink(TARGET, link)
    except OSError as e:
        print(f"{BAD} не получилось создать {tilde(link)}: {e}", file=sys.stderr)
        return 1
    print(f"{OK} am -> agentmeister: {tilde(link)}")
    if not on_path(where):
        print(f"{WARN} {tilde(where)} нет в PATH, добавьте в ~/.zshrc: export PATH=\"{tilde(where)}:$PATH\"")
    return 0


def turn_off():
    hit = found()
    if not hit:
        print(f"{OK} am и так нет")
        return 0
    if not ours(hit):
        print(f"{BAD} {tilde(hit)} не от agentmeister, не трогаю", file=sys.stderr)
        return 1
    if "/Cellar/" in os.path.realpath(TARGET) and "/Cellar/" not in hit:
        # формула Homebrew ставит am сама; удаленный вернется при следующем brew upgrade
        print(f"{WARN} am поставлен Homebrew и вернется при brew upgrade")
    try:
        os.remove(hit)
    except OSError as e:
        print(f"{BAD} не получилось удалить {tilde(hit)}: {e}", file=sys.stderr)
        return 1
    print(f"{OK} am убран: {tilde(hit)}")
    return 0


USAGE = """agentmeister alias       есть ли короткое имя am
agentmeister alias on    поставить am рядом с agentmeister (чужой am не трогает)
agentmeister alias off   убрать am, если он ведет на agentmeister"""


def main(argv):
    cmd = argv[0] if argv else "status"
    if cmd in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    if cmd == "status":
        return status()
    if cmd == "on":
        return turn_on()
    if cmd == "off":
        return turn_off()
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
