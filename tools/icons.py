#!/usr/bin/env python3
"""Иконки меню: SVG из описаний ниже и PNG 64x64 через headless Chrome.

Каждая иконка это цветная плитка со скругленными углами и белым значком линиями, сетка 32x32. Меню
раскладывает строки по emoji, а в iTerm2 и WezTerm подменяет emoji на эти картинки (menu.py, icons.json).
Запуск после правки: python3 tools/icons.py [папка], по умолчанию share/claudemeister/icons.
Нужен только тому, кто перерисовывает иконки: готовые PNG лежат в проекте.
"""
import json
import os
import subprocess
import sys
import tempfile

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SIZE = 64

SESSIONS, MODES, PROXY, INSTALL = "#3d7eea", "#7c5ce6", "#23a26d", "#e0802c"
GRAY, RED, TEAL, AMBER, INDIGO, SLATE = "#6b7685", "#d9443c", "#1a9fb0", "#b97a2a", "#4f59c9", "#56657a"

# имя: (emoji, цвет плитки, значок). Значок: SVG внутри плитки, линии белые, толщина 2.2.
ICONS = {
    "open": ("📂", SESSIONS, '<path d="M8 12a2 2 0 0 1 2-2h4l2 2h6a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H10a2 2 0 0 1-2-2z"/>'
                               '<path d="M13.5 17.5h5M16.5 15l2.5 2.5-2.5 2.5"/>'),
    "home": ("🏠", SESSIONS, '<path d="M8 15.5 16 8.5l8 7M10.5 13.5V23h11v-9.5M14 23v-5h4v5"/>'),
    "saved": ("💾", SESSIONS, '<rect x="9" y="13" width="14" height="10" rx="2"/><path d="M11 10h10M13 7.5h6"/>'),
    "running": ("👀", SESSIONS, '<path d="M7 16.5h4l2.5-5.5 4 11 2.5-5.5h5"/>'),
    "restore": ("🔄", SESSIONS, '<path d="M22.6 13.2A7 7 0 1 0 23 17.5"/><path d="M23 8.5v4.8h-4.8"/>'),
    "usage": ("📊", SESSIONS, '<path d="M10.5 23v-6M16 23V10M21.5 23v-9" stroke-width="3"/>'),
    "pen": ("📝", MODES, '<path d="M10 22.5 11 18.5l8.5-8.5 3 3L14 21.5z"/><path d="M17.5 12l3 3"/>'),
    "guard": ("🔒", MODES, '<path d="M16 7.5 23 10.5V15c0 4.4-3 7.5-7 9-4-1.5-7-4.6-7-9v-4.5z"/>'
                           '<path d="M13 15.8l2.2 2.2 4-4.2"/>'),
    "digest": ("🔨", MODES, '<path d="M8.5 9h15l-6 7.5V22l-3 2v-7.5z"/>'),
    "bell": ("🔔", MODES, '<path d="M11 20v-5a5 5 0 0 1 10 0v5l1.5 1.5h-13z"/><path d="M14.3 24.2h3.4"/>'),
    "laptop": ("💻", MODES, '<rect x="10" y="9" width="12" height="9" rx="1.5"/><path d="M7.5 22.5h17l-2-4.5h-13z"/>'),
    "globe": ("🌐", PROXY, '<circle cx="16" cy="16" r="8"/><ellipse cx="16" cy="16" rx="3.5" ry="8"/>'
                           '<path d="M8 16h16"/>'),
    "check": ("🧪", PROXY, '<circle cx="16" cy="16" r="8"/><path d="M12.5 16.2l2.6 2.6 4.6-5"/>'),
    "link": ("🔗", PROXY, '<path d="M14 18l4-4"/><path d="M13.2 14.6l-1.6 1.6a3 3 0 0 0 4.2 4.2l1.6-1.6"/>'
                          '<path d="M18.8 17.4l1.6-1.6a3 3 0 0 0-4.2-4.2l-1.6 1.6"/>'),
    "power": ("🔁", PROXY, '<path d="M16 8v7.5"/><path d="M11.6 11.2a7 7 0 1 0 8.8 0"/>'),
    "download": ("📦", PROXY, '<path d="M16 8v10M12 14l4 4 4-4M9 20.5V23h14v-2.5"/>'),
    "sliders": ("🧰", INSTALL, '<path d="M9 11h14M9 16h14M9 21h14"/>'
                               '<circle cx="13" cy="11" r="2.2" fill="TILE"/><circle cx="19.5" cy="16" r="2.2" fill="TILE"/>'
                               '<circle cx="14.5" cy="21" r="2.2" fill="TILE"/>'),
    "doctor": ("🔍", INSTALL, '<rect x="10" y="9" width="12" height="15" rx="2"/><path d="M13.5 9V7.5h5V9"/>'
                              '<path d="M13 17l2 2 4-4.2"/>'),
    "alias": ("🔤", INSTALL, '<text x="16" y="20.3" text-anchor="middle" font-family="Menlo, monospace" '
                             'font-weight="bold" font-size="11.5" fill="#fff" stroke="none">cm</text>'),
    "help": ("❓", GRAY, '<path d="M12.8 13a3.3 3.3 0 1 1 4.8 2.9c-1 .6-1.6 1.2-1.6 2.5"/>'
                         '<circle cx="16" cy="22.3" r="1.3" fill="#fff" stroke="none"/>'),
    "quit": ("🚪", GRAY, '<path d="M15 9h-5v14h5M18 12l4 4-4 4M22 16h-9"/>'),
    "folder": ("📁", SLATE, '<path d="M8 12a2 2 0 0 1 2-2h4l2 2h6a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H10a2 2 0 0 1-2-2z"/>'),
    "new": ("✨", TEAL, '<path d="M16 10v12M10 16h12"/>'),
    "chat": ("💬", SLATE, '<path d="M9 11a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2h-6l-4 3v-3a2 2 0 0 1-2-2z"/>'),
    "cup": ("☕", AMBER, '<path d="M9 12.5h11v5.5a4 4 0 0 1-4 4h-3a4 4 0 0 1-4-4z"/>'
                        '<path d="M20 14h1.3a2.3 2.3 0 0 1 0 4.6H20M12.5 7.5v2.5M16.5 7.5v2.5"/>'),
    "moon": ("🌙", INDIGO, '<path d="M21.5 18.5a7.5 7.5 0 1 1-8-9.5 6 6 0 0 0 8 9.5z"/>'),
    "direct": ("🔌", GRAY, '<path d="M9 16h13M18 12l4 4-4 4"/>'),
    "move": ("📤", SESSIONS, '<path d="M12.5 13H10v10h12V13h-2.5M16 18.5V8M12.5 11.5 16 8l3.5 3.5"/>'),
    "trash": ("❌", RED, '<path d="M9 11h14M13 11V9h6v2M11 11l1 12h8l1-12M14.5 14.5v5M17.5 14.5v5"/>'),
    "back": ("🔙", GRAY, '<path d="M23 16H10M14 12l-4 4 4 4"/>'),
}


def svg(color, glyph):
    glyph = glyph.replace('"TILE"', f'"{color}"')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 32 32">'
            f'<rect x="1" y="1" width="30" height="30" rx="7.5" fill="{color}"/>'
            f'<g fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">'
            f'{glyph}</g></svg>\n')


def render(src, png):
    """SVG -> PNG того же размера, фон прозрачный."""
    with tempfile.TemporaryDirectory() as profile:
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", f"--user-data-dir={profile}",
                        "--default-background-color=00000000", f"--window-size={SIZE},{SIZE}",
                        f"--screenshot={png}", "file://" + src],
                       check=True, capture_output=True, timeout=60)


def main(out):
    os.makedirs(out, exist_ok=True)
    mapping = {}
    for name, (emoji, color, glyph) in ICONS.items():
        src = os.path.join(out, name + ".svg")
        with open(src, "w") as f:
            f.write(svg(color, glyph))
        render(os.path.abspath(src), os.path.join(out, name + ".png"))
        mapping[emoji] = name
        print(name)
    with open(os.path.join(out, "icons.json"), "w") as f:
        json.dump(mapping, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    return 0


if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "share", "claudemeister", "icons")))
