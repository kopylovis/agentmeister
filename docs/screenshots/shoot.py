"""Снимки экрана для README из демо: python3 docs/screenshots/shoot.py [--theme dark|light|both]
[--lang en|ru|both] [--out папка] [сцена ...]. Без сцен снимаются README_SCENES, без --theme и --lang обе темы
и оба языка. Русские снимки ложатся в подпапку ru.
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
          "settings-modes": ("settings", 9), "settings-notify": ("settings", 9), "settings-general": ("settings", 9), "settings-buildlog": ("settings", 9), "settings-lid": ("settings", 9), "settings-humanize": ("settings", 9), "settings-guard": ("settings", 9),
          "settings-notify-phone": ("settings", 10), "settings-notify-add": ("settings", 10), "rail": ("main", 8), "about": ("settings", 8), "headsup": ("settings", 9),
          "inspector-scroll": ("main", 7)}
# сцены, которые показывает README
README_SCENES = ["main", "new-session", "project", "settings"]
THEMES = ["dark", "light"]
# язык снимка: английские для README.md в docs/screenshots, русские для README.ru.md в docs/screenshots/ru
LOCALES = {"en": "en_US", "ru": "ru_RU"}
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


def shoot(scene, theme, out_dir, lang="en"):
    kind, wait = SCENES[scene]
    # язык интерфейса и формат чисел из lang, какой бы язык ни стоял в системе. Тема и цвета терминала заданы
    # аргументами, а не настройками демо: снимок не зависит от того, что осталось от прошлых запусков
    args = [APP, "--demo", os.path.join(HERE, "demo"), "--scene", scene, "--demo-lang", lang,
            "-AppleLanguages", f"({lang})", "-AppleLocale", LOCALES[lang], "-appearance", theme,
            "-terminal.colors", "window"]
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
        for attempt in range(6):
            subprocess.run(["screencapture", "-x", "-l", str(target["id"]), out], check=True)
            subprocess.run(["sips", "-Z", "2200", out], capture_output=True)
            # меньше цветных кнопок, чем должно быть: окно снялось неактивным, macOS не всегда отдает фокус, пока
            # человек работает в другом приложении. Под листом кнопка закрытия серая всегда. Пробуем еще раз
            colors = subprocess.run(lights + ["colors"], capture_output=True, text=True).stdout.strip()
            if colors == "3" or (kind == "sheet" and colors == "2"):
                break
            subprocess.run(["osascript", "-l", "JavaScript", "-e", ACTIVATE_JS, str(proc.pid)], capture_output=True)
            time.sleep(2)
        # у неактивного окна не только серые кнопки, но и тень меньше и выделение бледнее. Такой снимок не
        # перекрашиваем, а снимаем сцену заново
        active = colors == "3" or (kind == "sheet" and colors == "2")
        print(out if active else f"{out}: окно неактивно")
        return active
    finally:
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=10)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--theme", choices=THEMES + ["both"], default="both")
    parser.add_argument("--lang", choices=list(LOCALES) + ["both"], default="both")
    parser.add_argument("--out", help="папка для снимков, по умолчанию docs/screenshots и docs/screenshots/ru")
    parser.add_argument("scenes", nargs="*", metavar="scene", help=", ".join(SCENES))
    opts = parser.parse_args()
    unknown = [name for name in opts.scenes if name not in SCENES]
    if unknown:
        parser.error(f"нет таких сцен: {', '.join(unknown)}")
    failed = []
    for lang in LOCALES if opts.lang == "both" else [opts.lang]:
        out = os.path.join(opts.out or HERE, "ru") if lang == "ru" else opts.out or HERE
        os.makedirs(out, exist_ok=True)
        for name in opts.scenes or README_SCENES:
            for theme in THEMES if opts.theme == "both" else [opts.theme]:
                # до трех запусков сцены, пока окно не снимется активным
                if not any(shoot(name, theme, out, lang) for _ in range(3)):
                    failed.append(os.path.join(out, f"{name}-{theme}.png"))
    if failed:
        sys.exit("сняты неактивными, переснять, когда мак свободен: " + ", ".join(failed))
