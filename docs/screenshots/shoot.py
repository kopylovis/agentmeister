"""Снимки экрана для README из демо: python3 docs/screenshots/shoot.py [сцена ...].
Сначала собрать приложение (swift build в app/ или host-run agentmeister-app-build) и данные (make_demo.py,
draw_icons.py). Скрипт запускает отладочную сборку с --demo для каждой сцены, снимает ее окно по pid процесса
(настоящее приложение рядом не мешает) и кладет PNG в docs/screenshots."""
import json
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
APP = os.path.join(ROOT, "app", ".build", "out", "Products", "Debug", "Agentmeister")
# сцена: (что снимать, через сколько секунд)
SCENES = {"main": ("main", 7), "new-session": ("sheet", 8), "project": ("main", 8), "settings": ("settings", 9),
          "settings-modes": ("settings", 9), "rail": ("main", 8), "about": ("settings", 8), "headsup": ("settings", 9)}
LIST_JS = r'''
ObjC.import('CoreGraphics');
function run(argv) {
  var ref = $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, $.kCGNullWindowID);
  var list = ObjC.deepUnwrap(ObjC.castRefToObject(ref)) || [], out = [];
  for (var i = 0; i < list.length; i++) {
    var w = list[i];
    if (String(w.kCGWindowOwnerPID) !== argv[0] || !w.kCGWindowBounds) continue;
    out.push({id: w.kCGWindowNumber, layer: w.kCGWindowLayer, title: w.kCGWindowName || "",
              w: w.kCGWindowBounds.Width, h: w.kCGWindowBounds.Height});
  }
  return JSON.stringify(out);
}
'''


ACTIVATE_JS = "ObjC.import('AppKit'); function run(argv) { $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(argv[0])).activateWithOptions(1 << 1); }"


def windows(pid):
    r = subprocess.run(["osascript", "-l", "JavaScript", "-e", LIST_JS, str(pid)], capture_output=True, text=True)
    return [w for w in json.loads(r.stdout or "[]") if w["layer"] == 0 and w["w"] > 200]


def shoot(scene):
    kind, wait = SCENES[scene]
    # английский интерфейс и формат чисел, какой бы язык ни стоял в системе
    proc = subprocess.Popen([APP, "--demo", os.path.join(HERE, "demo"), "--scene", scene,
                             "-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(wait)
        # неактивное окно снялось бы с серыми кнопками и меньшей тенью
        subprocess.run(["osascript", "-l", "JavaScript", "-e", ACTIVATE_JS, str(proc.pid)], capture_output=True)
        time.sleep(1)
        ws = windows(proc.pid)
        main = next((w for w in ws if w["title"] == "Agentmeister Demo"), None)
        if kind == "main":
            target = main
        elif kind == "sheet":
            # лист у окна свой, без заголовка и меньше главного
            target = next((w for w in ws if w is not main and w["title"] == ""), None)
        else:
            target = next((w for w in ws if w is not main), None)
        if not target:
            sys.exit(f"{scene}: окно не нашлось среди {ws}")
        out = os.path.join(HERE, f"{scene}.png")
        lights = ["osascript", "-l", "JavaScript", os.path.join(HERE, "lights.js"), out]
        for attempt in range(4):
            subprocess.run(["screencapture", "-x", "-l", str(target["id"]), out], check=True)
            subprocess.run(["sips", "-Z", "2200", out], capture_output=True)
            # три серые кнопки: окно снялось неактивным, macOS не всегда отдает фокус, пока человек работает
            # в другом приложении. Пробуем еще раз
            if subprocess.run(lights + ["check"], capture_output=True, text=True).stdout.strip() != "3":
                break
            subprocess.run(["osascript", "-l", "JavaScript", "-e", ACTIVATE_JS, str(proc.pid)], capture_output=True)
            time.sleep(2)
        # что осталось серым (кнопка закрытия под листом, неактивное окно), перекрашивается по образцу lights.png
        print(scene, subprocess.run(lights + ["fix"], capture_output=True, text=True).stdout.strip())
        print(out)
    finally:
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=10)


if __name__ == "__main__":
    for name in sys.argv[1:] or list(SCENES):
        shoot(name)
