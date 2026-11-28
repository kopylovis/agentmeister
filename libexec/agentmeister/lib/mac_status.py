import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import tr

PARTS = {
    "ram": (("Память", "Memory"), ["ram", "status", "-n", "12"], 60),
    "gradle": (("Gradle: версии, кеши, build/ в проектах", "Gradle: versions, caches, build/ in projects"),
               ["gradle", "status"], 120),
    "sim": (("iOS-симуляторы", "iOS simulators"), ["sim", "status"], 60),
    "ports": (("Занятые порты", "Ports in use"), ["ports"], 60),
    "disk": (("Что можно почистить на диске", "What you can clean up on disk"), ["disk", "status"], 300),
}
DEFAULT_PARTS = ["ram", "gradle", "sim", "ports"]
FREE = {"daemons": "--daemons", "simulators": "--sim", "emulator": "--emulator"}


def mnrh(exe, args, timeout):
    try:
        r = subprocess.run([exe] + args, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return tr(f"не уложился в {timeout} с", f"didn't finish in {timeout} s")
    except OSError as e:
        return tr(f"не запустился: {e}", f"didn't start: {e}")
    out = (r.stdout + ("\n" + r.stderr if r.stderr.strip() else "")).strip()
    return out or tr(f"пусто (код {r.returncode})", f"empty (exit code {r.returncode})")


def status(exe, parts):
    parts = [p for p in parts or DEFAULT_PARTS if p in PARTS] or DEFAULT_PARTS
    with ThreadPoolExecutor(len(parts)) as pool:
        outs = list(pool.map(lambda p: mnrh(exe, PARTS[p][1], PARTS[p][2]), parts))
    blocks = [f"## {tr(*PARTS[p][0])} (mnrh {' '.join(PARTS[p][1])})\n{out}" for p, out in zip(parts, outs)]
    return "\n\n".join(blocks), False


def free(exe, what, force):
    what = [w for w in what or [] if w in FREE] or ["daemons", "simulators"]
    args = ["ram", "clean", "-y"] + [FREE[w] for w in what] + (["-f"] if force else [])
    return f"$ mnrh {' '.join(args)}\n" + mnrh(exe, args, 180), False


STATUS_TOOL = {
    "name": "mac_status",
    "description": (
        "Состояние этого Mac для разработки: кто занял память (с разбивкой по приложениям, демонам Gradle и Kotlin, "
        "симуляторам и эмулятору), версии Gradle и размеры кешей и build/ в проектах, запущенные iOS-симуляторы, "
        "кто слушает порты, а по запросу — что можно почистить на диске (disk, это долго, до пары минут). "
        "Вызывай, когда сборка тормозит или падает по памяти, Mac тормозит, порт занят, кончается место. "
        "Стрелки «-> mnrh …» в выводе — команды для пользователя; память освобождает free_memory, "
        "остальные чистки предложи пользователю сам."),
    "annotations": {"readOnlyHint": True},
    "inputSchema": {
        "type": "object",
        "properties": {
            "parts": {"type": "array", "items": {"type": "string", "enum": list(PARTS)},
                      "description": "что показать; по умолчанию ram, gradle, sim, ports"},
        },
    },
}

FREE_TOOL = {
    "name": "free_memory",
    "description": (
        "Освободить память: остановить простаивающие демоны Gradle и Kotlin и выключить iOS-симуляторы "
        "(их данные сохраняются), по желанию ещё Android-эмулятор (состояние уйдёт в Quick Boot). "
        "Приложения не закрывает. Занятые сборкой демоны пропускает, если не force. Показывает, сколько "
        "памяти вернулось. Вызывай только с согласия пользователя: остановленное придётся запускать заново."),
    "annotations": {"destructiveHint": True},
    "inputSchema": {
        "type": "object",
        "properties": {
            "what": {"type": "array", "items": {"type": "string", "enum": list(FREE)},
                     "description": "что остановить; по умолчанию daemons и simulators, emulator — вдобавок к ним"},
            "force": {"type": "boolean", "description": "остановить и демоны, которые прямо сейчас собирают"},
        },
    },
}

TOOLS = [STATUS_TOOL, FREE_TOOL]


def handle(name, a, exe):
    if name == "mac_status":
        return status(exe, a.get("parts"))
    return free(exe, a.get("what"), bool(a.get("force")))
