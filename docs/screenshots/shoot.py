"""Снимки экрана для README из демо: python3 docs/screenshots/shoot.py [--theme dark|light|both] [--out папка]
[сцена ...]. Без сцен снимаются README_SCENES, без --theme обе темы.
Сначала собрать приложение (swift build в app/ или host-run agentmeister-app-build) и данные (make_demo.py,
draw_icons.py). Скрипт запускает отладочную сборку с --demo для каждой сцены, снимает ее окно по pid процесса
(настоящее приложение рядом не мешает) и кладет <сцена>-<тема>.png в docs/screenshots или в --out."""
import argparse
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
          "settings-modes": ("settings", 9), "rail": ("main", 8), "about": ("settings", 8), "headsup": ("settings", 9),
          "inspector-scroll": ("main", 7)}
# сцены, которые показывает README
README_SCENES = ["main", "new-session", "project", "settings"]
THEMES = ["dark", "light"]
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


def shoot(scene, theme, out_dir):
    kind, wait = SCENES[scene]
    # английский интерфейс и формат чисел, какой бы язык ни стоял в системе. Тема и цвета терминала заданы
    # аргументами, а не настройками демо: снимок не зависит от того, что осталось от прошлых запусков
    args = [APP, "--demo", os.path.join(HERE, "demo"), "--scene", scene,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appearance", theme, "-terminal.colors", "window"]
    if scene != "rail":
        # раскладка как у нового пользователя: боковая панель открыта, списки проектов и режимов развернуты
        args += ["-layout.sidebarCollapsed", "NO", "-layout.projectsOpen", "YES", "-layout.modesOpen", "YES",
                 "-layout.showInspector", "YES"]
    proc = subprocess.Popen(args,
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
        out = os.path.join(out_dir, f"{scene}-{theme}.png")
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
        # серые кнопки неактивного окна перекрашиваются по образцу lights.png. Кнопку закрытия под листом macOS
        # гасит и в настоящем окне, ее оставляем как есть
        gray = subprocess.run(lights + ["check"], capture_output=True, text=True).stdout.strip()
        if kind != "sheet" or gray == "3":
            print(scene, subprocess.run(lights + ["fix"], capture_output=True, text=True).stdout.strip())
        print(out)
    finally:
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=10)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--theme", choices=THEMES + ["both"], default="both")
    parser.add_argument("--out", default=HERE)
    parser.add_argument("scenes", nargs="*", metavar="scene", help=", ".join(SCENES))
    opts = parser.parse_args()
    unknown = [name for name in opts.scenes if name not in SCENES]
    if unknown:
        parser.error(f"нет таких сцен: {', '.join(unknown)}")
    os.makedirs(opts.out, exist_ok=True)
    for name in opts.scenes or README_SCENES:
        for theme in THEMES if opts.theme == "both" else [opts.theme]:
            shoot(name, theme, opts.out)
