import glob
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import find_project, read_config, run, tilde, tr
import claude_search

LIMITS = {"play": 500, "appstore": 4000, "testflight": 4000, "rustore": 5000, "firebase": 16000}
NOTES_DIR = os.path.join("fastlane", "release_notes")


def app_version(root):
    for name in ("gradle/libs.versions.toml",):
        try:
            text = open(os.path.join(root, name), encoding="utf-8").read()
        except OSError:
            continue
        m = re.search(r'^\s*(?:app-?version|appVersion|versionName|app-version-name)\s*=\s*"([^"]+)"', text, re.M | re.I)
        if m:
            return m.group(1), name
    for f in glob.glob(os.path.join(glob.escape(root), "*", "build.gradle.kts")) + \
            glob.glob(os.path.join(glob.escape(root), "build.gradle.kts")):
        m = re.search(r'versionName\s*=\s*"([^"]+)"', open(f, encoding="utf-8", errors="replace").read())
        if m:
            return m.group(1), os.path.relpath(f, root)
    for f in glob.glob(os.path.join(glob.escape(root), "**", "*.xcconfig"), recursive=True)[:20]:
        m = re.search(r"MARKETING_VERSION\s*=\s*([\d.]+)", open(f, encoding="utf-8", errors="replace").read())
        if m:
            return m.group(1), os.path.relpath(f, root)
    return None, None


def since_point(root, since=None):
    if since:
        return since, tr(f"задано: {since}", f"given {since}")
    tag = run(["git", "-C", root, "describe", "--tags", "--abbrev=0"]).strip()
    tag_ts = int(run(["git", "-C", root, "log", "-1", "--format=%ct", tag]).strip() or 0) if tag else 0
    report = os.path.join(root, "fastlane", "report.xml")
    rep_ts = int(os.path.getmtime(report)) if os.path.exists(report) else 0
    notes = sorted(glob.glob(os.path.join(glob.escape(root), NOTES_DIR, "*.txt")), key=os.path.getmtime)
    notes_ts = int(os.path.getmtime(notes[-1])) if notes else 0
    best = max((tag_ts, tr(f"тег {tag}", f"tag {tag}"), tag),
               (rep_ts, tr("последний запуск fastlane", "last fastlane run"), None),
               (notes_ts, tr("прошлые заметки к релизу", "previous release notes"), None))
    if not best[0]:
        return None, tr("ни тега, ни запусков fastlane: берутся последние 30 коммитов",
                        "no tag and no fastlane runs: taking the last 30 commits")
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(best[0]))
    return best[2] or f"@{best[0]}", f"{best[1]} ({when})"


def commits(root, since):
    fmt = "--format=%h %ad %s%n%b%x1e"
    if since and since.startswith("@"):
        args = ["log", f"--since={since[1:]}", "--date=short", fmt]
    elif since:
        args = ["log", f"{since}..HEAD", "--date=short", fmt]
    else:
        args = ["log", "-30", "--date=short", fmt]
    out = run(["git", "-C", root] + args, timeout=20)
    items = []
    for chunk in out.split("\x1e"):
        chunk = chunk.strip()
        if not chunk:
            continue
        head, _, body = chunk.partition("\n")
        body = " ".join(l.strip() for l in body.splitlines() if l.strip() and not l.lower().startswith(("co-authored", "signed-off")))
        items.append(head + ((tr(" — ", ": ") + body[:300]) if body else ""))
    return items


def sessions_since(root, ts):
    from session_store import encode
    pdir = os.path.join(claude_search.PROJECTS, encode(root))
    out = []
    for path in glob.glob(os.path.join(glob.escape(pdir), "*.jsonl")):
        sid = os.path.basename(path)[:-6]
        if not claude_search.UUID.match(sid) or os.path.getmtime(path) < ts:
            continue
        data = claude_search.update(sid, path)
        if not data:
            continue
        summaries = [m for m in data["msgs"] if m[0] == "summary" and (m[1] or "") >= time.strftime(
            "%Y-%m-%dT%H:%M:%S", time.gmtime(ts))]
        name = claude_search.title(sid, data)
        out.append(tr(f"«{name}» ({sid[:8]}), сводок после /compact за период: {len(summaries)}",
                      f"\"{name}\" ({sid[:8]}), /compact summaries in this period: {len(summaries)}"))
    return out


def locales(root):
    found = set()
    for d in glob.glob(os.path.join(glob.escape(root), "fastlane", "metadata", "android", "*")) + \
            glob.glob(os.path.join(glob.escape(root), "fastlane", "metadata", "*")):
        name = os.path.basename(d)
        if re.match(r"^[a-z]{2}(-[A-Z]{2})?$", name):
            found.add(name)
    return sorted(found) or default_locales()


def default_locales():
    """Языки, когда в fastlane/metadata их не видно: release_locales=en-US,de-DE в config, по умолчанию en-US."""
    raw = read_config().get("release_locales", "")
    picked = [x.strip() for x in raw.split(",") if re.match(r"^[a-z]{2}(-[A-Z]{2})?$", x.strip())]
    return picked or ["en-US"]


def context(project=None, since=None, cwd=None):
    root, err = find_project(project, cwd)
    if err:
        return err, True
    version, vsrc = app_version(root)
    point, why = since_point(root, since)
    log = commits(root, point)
    ts = int(point[1:]) if point and point.startswith("@") else \
        int(run(["git", "-C", root, "log", "-1", "--format=%ct", point]).strip() or 0) if point else 0
    name = os.path.basename(root)
    langs = ', '.join(locales(root))
    lines = [tr(f"Проект {name} ({tilde(root)}), версия {version or '?'}",
                f"Project {name} ({tilde(root)}), version {version or '?'}")
             + (tr(f" (из {vsrc})", f" (from {vsrc})") if vsrc else ""),
             tr(f"С какого момента: {why}. Коммитов: {len(log)}.", f"Since: {why}. Commits: {len(log)}.")]
    lines += ["", tr("Коммиты (новые сверху):", "Commits (newest first):")] + [f"  {c}" for c in log[:120]]
    if len(log) > 120:
        lines.append(tr(f"  … и ещё {len(log) - 120}", f"  … and {len(log) - 120} more"))
    sess = sessions_since(root, ts) if ts else []
    if sess:
        lines += ["", tr("Сессии Claude за этот период (подробности — session_search/session_read):",
                         "Claude sessions in this period (details: session_search/session_read):")] + \
            [f"  {s}" for s in sess]
    lines += ["", tr(f"Языки: {langs}. Ограничения «Что нового»: Google Play 500 символов, "
                     "App Store и TestFlight 4000, RuStore 5000, Firebase App Distribution 16000.",
                     f"Languages: {langs}. \"What's new\" limits: Google Play 500 characters, "
                     "App Store and TestFlight 4000, RuStore 5000, Firebase App Distribution 16000."),
              tr("Fastfile этого проекта берёт текст из notes: или RELEASE_NOTES; release_notes_write кладёт файлы в "
                 f"{NOTES_DIR}/ и, если есть fastlane/metadata, — в changelogs/release_notes.txt.",
                 "This project's Fastfile takes the text from notes: or RELEASE_NOTES; release_notes_write puts the files in "
                 f"{NOTES_DIR}/ and, if there is fastlane/metadata, in changelogs/release_notes.txt."),
              tr("Пиши для пользователей, а не для разработчиков: что стало лучше и что исправлено, без названий "
                 "классов, библиотек и номеров коммитов. Внутренние изменения (рефакторинг, CI, зависимости) "
                 "не упоминай или одной общей фразой.",
                 "Write for users, not developers: what got better and what was fixed, without class names, "
                 "library names or commit hashes. Leave out internal changes (refactoring, CI, dependencies) "
                 "or cover them in one general sentence.")]
    return "\n".join(lines), False


LOCALE = re.compile(r"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,4})?$")
VERSION = re.compile(r"^[\w.+-]{1,40}$")

def write(project=None, version=None, notes=None, version_code=None, cwd=None):
    root, err = find_project(project, cwd)
    if err:
        return err, True
    if not isinstance(notes, dict) or not notes:
        return tr("Нужен notes: {\"ru-RU\": \"…\", \"en-US\": \"…\"}",
                  "notes is required: {\"ru-RU\": \"…\", \"en-US\": \"…\"}"), True
    # из этих значений собираются пути; без проверки "../../x" записал бы файл вне fastlane/
    bad = [loc for loc, text in notes.items() if not LOCALE.match(str(loc)) or not isinstance(text, str)]
    if bad:
        listed = ', '.join(map(str, bad))
        return tr(f"В notes ключи вида ru-RU или en-US, значения строками; не подходят: {listed}",
                  f"notes keys look like ru-RU or en-US, values are strings; these don't fit: {listed}"), True
    version = version or app_version(root)[0] or time.strftime("%Y%m%d")
    if not VERSION.match(str(version)):
        return tr(f"Версия {version!r} не похожа на номер версии: нужны цифры, буквы, точки, +, - или _",
                  f"Version {version!r} doesn't look like a version number: use digits, letters, dots, +, - or _"), True
    if version_code is not None and not re.match(r"^\d{1,10}$", str(version_code)):
        return tr(f"version_code {version_code!r} не число", f"version_code {version_code!r} is not a number"), True
    version = str(version)
    too_long = [tr(f"{loc}: {len(t)} символов", f"{loc}: {len(t)} characters")
                for loc, t in notes.items() if len(t) > LIMITS["play"]]
    out_dir = os.path.join(root, NOTES_DIR)
    os.makedirs(out_dir, exist_ok=True)
    written = []
    for loc, text in notes.items():
        text = text.strip() + "\n"
        path = os.path.join(out_dir, f"{version}.{loc}.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        written.append(os.path.relpath(path, root))
        meta_android = os.path.join(root, "fastlane", "metadata", "android", loc)
        if version_code and os.path.isdir(meta_android):
            p = os.path.join(meta_android, "changelogs", f"{version_code}.txt")
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as f:
                f.write(text[:LIMITS["play"]])
            written.append(os.path.relpath(p, root))
        meta_ios = os.path.join(root, "fastlane", "metadata", loc)
        if os.path.isdir(meta_ios):
            p = os.path.join(meta_ios, "release_notes.txt")
            with open(p, "w", encoding="utf-8") as f:
                f.write(text)
            written.append(os.path.relpath(p, root))
    first = next(iter(notes))
    rel = os.path.join(NOTES_DIR, f"{version}.{first}.txt")
    lines = [tr("Записал:", "Wrote:")] + [f"  {w}" for w in written]
    if too_long:
        lines.append(tr("! Длиннее 500 символов, в Google Play не влезет: ",
                        "! Longer than 500 characters, won't fit in Google Play: ") + ", ".join(too_long))
    lines.append(tr(f'Передать в fastlane: RELEASE_NOTES="$(cat {rel})" bundle exec fastlane <лейн>',
                    f'Pass to fastlane: RELEASE_NOTES="$(cat {rel})" bundle exec fastlane <lane>'))
    return "\n".join(lines), False


CONTEXT_TOOL = {
    "name": "release_notes_context",
    "description": ("Материал для заметок к релизу («Что нового»): версия приложения, коммиты с прошлого релиза "
                    "(последний тег, запуск fastlane или прошлые заметки — что новее), сессии Claude за этот период, "
                    "языки и лимиты магазинов. Дальше напиши текст на каждом языке, покажи пользователю и после "
                    "его согласия сохрани через release_notes_write."),
    "annotations": {"readOnlyHint": True},
    "inputSchema": {"type": "object", "properties": {
        "project": {"type": "string", "description": "имя папки проекта или путь; по умолчанию текущий"},
        "since": {"type": "string", "description": "тег или коммит, с которого считать; по умолчанию сам"}}},
}
WRITE_TOOL = {
    "name": "release_notes_write",
    "description": ("Сохранить согласованные с пользователем заметки к релизу: fastlane/release_notes/<версия>.<язык>.txt "
                    "и, если в проекте есть fastlane/metadata, — changelogs/<versionCode>.txt и release_notes.txt. "
                    "Возвращает команду, как передать текст в fastlane."),
    "inputSchema": {"type": "object", "properties": {
        "notes": {"type": "object", "description": "{\"ru-RU\": \"текст\", \"en-US\": \"text\"}",
                  "additionalProperties": {"type": "string"}},
        "project": {"type": "string"}, "version": {"type": "string"},
        "version_code": {"type": "string", "description": "versionCode для metadata/android/…/changelogs"}},
        "required": ["notes"]},
}
TOOLS = [CONTEXT_TOOL, WRITE_TOOL]


def handle(name, a, cwd=None):
    if name == "release_notes_context":
        return context(a.get("project"), a.get("since"), cwd)
    return write(a.get("project"), a.get("version"), a.get("notes"), a.get("version_code"), cwd)


def main():
    args = sys.argv[2:] if sys.argv[1:2] == ["release-notes"] else sys.argv[1:]
    if args[:1] in (["-h"], ["--help"]):
        print(tr("agentmeister release-notes [проект] [--since <тег|коммит>]",
                 "agentmeister release-notes [project] [--since <tag|commit>]"))
        print(tr("    материал для «Что нового»: версия, коммиты с прошлого релиза, сессии Claude, языки и лимиты",
                 "    material for \"What's new\": version, commits since the last release, Claude sessions, languages and limits"))
        print()
        print(tr("Сами заметки пишет Claude: /release-notes в Claude Code. Сохраняются в fastlane/release_notes/.",
                 "Claude writes the notes: /release-notes in Claude Code. They are saved to fastlane/release_notes/."))
        return 0
    since = None
    if "--since" in args:
        i = args.index("--since")
        since = args[i + 1] if i + 1 < len(args) else None
        args = args[:i] + args[i + 2:]
    text, bad = context(args[0] if args else None, since)
    print(text)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
