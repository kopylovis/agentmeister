"""Данные демо для скриншотов README: выдуманные проекты, сессии, подписки proxy и текст во вкладках.
Пишет docs/screenshots/demo/*.json и *.txt на английском и docs/screenshots/demo/ru/ на русском. Приложение читает
их в отладочной сборке с --demo, русские с --demo-lang ru (Demo.swift)."""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import tempfile
import time

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "demo")
H = "/Users/demo"
D = H + "/Developer"
NOW = time.time()

E = "\x1b["
R, B, DIM = E + "0m", E + "1m", E + "2m"
LANG = "en"
W = 104  # столько колонок у терминала во вкладке демо: длиннее терминал перенес бы строку, короче линия не дойдет до края


def t(en, ru):
    """Текст демо на языке LANG: README на английском и README.ru.md снимаются каждый на своем."""
    return ru if LANG == "ru" else en


def bg(rgb):
    return E + "48;2;%d;%d;%dm" % rgb


# Цвета Claude Code в темной и светлой теме терминала. Вкладка в светлом окне печатает вариант *-light.txt
PALETTES = {
    "dark": {"OR": "173", "GR": "114", "RD": "174", "CY": "117", "GY": "245", "WH": "252", "OK": "114",
             "user": (55, 55, 55), "del": (72, 9, 2), "add": (15, 50, 4), "rule": "240"},
    "light": {"OR": "166", "GR": "28", "RD": "124", "CY": "25", "GY": "243", "WH": "235", "OK": "28",
              "user": (236, 236, 236), "del": (255, 218, 222), "add": (214, 242, 218), "rule": "250"},
}


def use(theme):
    """Цвета для текста вкладок в теме theme: глобальные OR, GR и т. п. берут функции ниже."""
    global OR, GR, RD, CY, GY, WH, OK, USER, DEL, ADD, RULE, DOT, TOOL
    p = PALETTES[theme]
    OR, GR, RD, CY, GY, WH, OK, RULE = (E + "38;5;" + p[k] + "m" for k in ("OR", "GR", "RD", "CY", "GY", "WH", "OK", "rule"))
    USER, DEL, ADD = bg(p["user"]), bg(p["del"]), bg(p["add"])
    # у ответа точка цвета текста, у вызова инструмента зеленая, как у Claude Code после удачного вызова
    DOT, TOOL = "⏺", OK + "⏺" + R


def stamp(t, fmt="%Y-%m-%d %H:%M:%S"):
    """Время строки журнала в демо, местное, как пишут сами журналы."""
    return time.strftime(fmt, time.localtime(t))


def title(text):
    return f"\x1b]0;{text}\x07"


def tool(name, arg, out):
    return f"{TOOL} {B}{name}{R}({arg})\n  {GY}⎿  {out}{R}\n\n"


def ask(text):
    """Запрос пользователя в переписке: "❯ текст" на подложке во всю ширину. По этой строке приложение
    находит запросы и показывает закрепленную полосу над терминалом."""
    return f"{USER}{GY}❯{R}{USER} {WH}{text}{' ' * (W - 2 - len(text))}{R}\n\n"


def diff(rows):
    """Строки правки: номер, знак и код на красной или зеленой подложке во всю ширину."""
    out = ""
    for n, sign, code in rows:
        line = f"{n:>4} {sign} {code}"
        out += f"   {DEL if sign == '-' else ADD}{line}{' ' * (W - 3 - len(line))}{R}\n"
    return out + "\n"


def box(hint):
    """Поле ввода Claude Code: линии сверху и снизу, между ними "❯" и подсказка."""
    line = f"{RULE}{'─' * W}{R}\n"
    return line + f"{GY}❯{R} {GY}{hint}{R}\n" + line


def load_promptsill():
    """Настоящий promptsill: строка состояния на скриншотах та же, что в Claude Code. Путь можно задать в
    PROMPTSILL_SRC, иначе берется соседний репозиторий ~/Developer/promptsill или promptsill из PATH."""
    path = next(p for p in (os.environ.get("PROMPTSILL_SRC"), os.path.expanduser("~/Developer/promptsill/promptsill"),
                            shutil.which("promptsill")) if p and os.path.isfile(p))
    loader = importlib.machinery.SourceFileLoader("promptsill", path)
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader("promptsill", loader))
    loader.exec_module(module)
    return module


PS = load_promptsill()
PS_NOW = 1_791_381_600


def sill(project, branch, model, ctx, five_hour, week, proxy, detail="vless 203.0.113.24", changed=0, ahead=0,
         tokens=None):
    """Две строки promptsill для вкладки, как это делает docs/preview.py в репозитории promptsill: данные Claude Code
    выдуманы, сеть, git, память и бейджи подменены, чтобы снимок не зависел от этого мака."""
    root = f"{D}/{project}"
    demo = {"project": {"root": root, "kinds": [], "ports": [], "node_dir": None,
                        "repo": f"https://github.com/example/{project}"},
            "git": {"branch": branch, "ahead": ahead, "behind": 0, "upstream": True, "changed": changed},
            "listeners": [], "node": None, "disk": 210 * PS.GB, "power": {}, "size": 0, "proxy": True,
            "machine": {"total": 32 * PS.GB, "used": 17.8 * PS.GB, "swap": 0, "gradle": 0, "kotlin": 0,
                        "daemon_mem": 0, "sims": 0, "emulator": False},
            "sessions": [{"sessionId": "demo", "status": "busy"}]}
    data = {"session_id": "demo", "model": {"display_name": model}, "effort": {"level": "high"},
            "workspace": {"current_dir": root},
            "context_window": {"used_percentage": ctx, "total_input_tokens": tokens or ctx * 2000,
                               "context_window_size": 200000},
            "rate_limits": {"five_hour": {"used_percentage": five_hour, "resets_at": PS_NOW + 3 * 3600 + 1200},
                            "seven_day": {"used_percentage": week, "resets_at": PS_NOW + 4 * 86400}},
            "prompt_cache": {"caching_observed": True, "warm": True, "ttl": "5m", "expires_at": PS_NOW + 212,
                             "requests": 14}}
    PS.OPTS.update({"lang": LANG, "ascii": False, "color": True, "links": False})
    PS.cached = lambda name, ttl, fn, background=False: demo[name.split("-")[0]]
    PS.git_op = lambda git_dir: None
    PS.badges = lambda d, cwd, now=None: []
    PS.transcript_activity = lambda path: {}
    PS.peek = lambda name, ttl: None
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump({"label": proxy, "detail": detail, "closed": False}, f)
    keep = {k: os.environ.pop(k, None) for k in ("HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy",
                                                 "PROMPTSILL_PROXY_LABEL", "PROMPTSILL_PROXY_DETAIL",
                                                 "PROMPTSILL_PROXY_URL", "PROMPTSILL_PROXY_FILE")}
    os.environ.update(HTTPS_PROXY="http://127.0.0.1:17892", PROMPTSILL_PROXY_FILE=f.name)
    real = PS.time.time
    PS.time.time = lambda: PS_NOW
    try:
        lines = [PS.fit(PS.claude_line(data, PS_NOW), W), PS.fit(PS.work_line(data), W)]
    finally:
        PS.time.time = real
        os.remove(f.name)
        for k in ("HTTPS_PROXY", "PROMPTSILL_PROXY_FILE"):
            os.environ.pop(k, None)
        os.environ.update({k: v for k, v in keep.items() if v is not None})
    # Claude Code сдвигает строку состояния на две колонки от края
    return "".join("  " + line + "\n" for line in lines if line)


def status(*parts, proxy):
    """Нижняя строка Codex: его собственный footer, promptsill в Codex не рисует."""
    return "  " + f" {GY}·{R} ".join([f"{CY}{parts[0]}{R}"] + [f"{GY}{p}{R}" for p in parts[1:]]) + f" {GY}·{R} {GR}{proxy}{R}\n"


def screens():
    return {
        "claude.txt":
            title(t("Webhook retries", "Повторы вебхуков")) + f"{OR}✻{R} {B}Claude Code{R} {GY}v2.3.1 · Opus 5.5 · ~/Developer/ledger-api{R}\n\n"
            + ask(t("Add retry with backoff to the payment webhook handler and cover it with tests",
                    "Добавь повторы с паузой в обработчик платежных вебхуков и покрой их тестами"))
            + f"{DOT} " + t("I'll check how webhook delivery works now, then wrap the provider call.",
                           "Посмотрю, как сейчас доставляются вебхуки, и оберну вызов провайдера.") + "\n\n"
            + tool("Read", "src/webhooks/payments.ts", "Read 142 lines")
            + tool("Grep", '"deliverWebhook", path: "src"', "Found 3 files")
            + f"{TOOL} {B}Update{R}(src/webhooks/payments.ts)\n"
              f"  {GY}⎿  Updated src/webhooks/payments.ts with 21 additions and 6 removals{R}\n"
            + diff([(48, "-", "  const res = await provider.send(event)"),
                    (48, "+", "  const res = await withRetry(() => provider.send(event), {"),
                    (49, "+", "    tries: 5, baseMs: 500, maxMs: 8000,"),
                    (50, "+", "    retryOn: (e) => e.status >= 500 || e.code === 'ETIMEDOUT',"),
                    (51, "+", "  })")])
            + tool("Write", "test/webhooks/retry.test.ts", "Wrote 64 lines to test/webhooks/retry.test.ts")
            + tool("Bash", "npm test -- webhooks", f"{GR}PASS{R}{GY} payments.test.ts (12)  {GR}PASS{R}{GY} retry.test.ts (5)")
            + f"{DOT} " + t("Delivery now retries 5xx answers and timeouts after 0.5, 1, 2 and 4 seconds,\n"
                            "  five tries in total. A 4xx answer fails at once, so a bad signature doesn't\n"
                            "  hammer the provider. All 17 webhook tests pass.",
                            "Теперь доставка повторяет ответы 5xx и таймауты через 0,5, 1, 2 и 4 секунды,\n"
                            "  всего пять попыток. Ответ 4xx сразу считается ошибкой, и плохая подпись не\n"
                            "  заваливает провайдера запросами. Все 17 тестов вебхуков проходят.") + "\n\n"
            + ask(t("Also log each retry with the attempt number", "Еще пиши в лог каждую попытку с ее номером"))
            + tool("Update", "src/webhooks/retry.ts", "Updated src/webhooks/retry.ts with 4 additions")
            + f"{DOT} " + t("Each retry now logs the event id, the attempt number and the delay before the next try.",
                           "Каждая попытка теперь пишет в лог id события, номер попытки и паузу до следующей.") + "\n\n"
            + box('Try "open a PR for this"')
            + sill("ledger-api", "webhook-retries", "Opus 5.5", 31, 18, 42, "main KZ", changed=3),
        "claude2.txt":
            title(t("Billing dark mode", "Темная тема")) + f"{OR}✻{R} {B}Claude Code{R} {GY}v2.3.1 · Opus 5.5 · ~/Developer/atlas-web{R}\n\n"
            + ask(t("The billing page ignores dark mode, fix it without touching brand colors",
                    "Страница оплаты не видит темную тему, поправь, не трогая фирменные цвета"))
            + tool("Read", "app/billing/page.tsx", "Read 211 lines")
            + tool("Update", "app/billing/invoice-table.tsx", "Updated with 9 additions and 9 removals")
            + tool("Bash", "pnpm test billing", f"{GR}✓{R}{GY} 23 passed")
            + f"{DOT} " + t("The invoice table hard-coded #fff and #111. It now uses the surface and text\n"
                            "  tokens and follows the system theme. Brand colors are untouched.",
                            "В таблице счетов были зашиты #fff и #111. Теперь она берет токены фона и текста\n"
                            "  и следует теме системы. Фирменные цвета не тронуты.") + "\n\n"
            + box("")
            + sill("atlas-web", "billing-dark", "Opus 5.5", 12, 18, 42, "backup KZ", detail="hysteria2 198.51.100.7", ahead=1),
        "codex.txt":
            title(t("Launch list snapshots", "Снимки запусков")) + f"{B}>_ OpenAI Codex{R} {GY}(v0.98.0) · gpt-5.5 · ~/Developer/orbit-ios{R}\n\n"
            f"{CY}›{R} " + t("Add snapshot tests for the launch list in light and dark mode",
                             "Добавь снимочные тесты списка запусков в светлой и темной теме") + "\n\n"
            f"{GY}•{R} Explored\n  {GY}└ Read LaunchListView.swift, LaunchRow.swift{R}\n\n"
            f"{GY}•{R} Edited Tests/LaunchListSnapshotTests.swift {GR}(+58 -0){R}\n\n"
            f"{GY}•{R} Ran xcodebuild test -scheme Orbit -only-testing:OrbitTests/LaunchListSnapshotTests\n"
            f"  {GY}└{R} {GR}Test Suite 'LaunchListSnapshotTests' passed (4 tests, 3.2 s){R}\n\n"
            f"{GY}•{R} " + t("Four snapshots cover the list in light and dark mode, with and without a delay.",
                             "Четыре снимка покрывают список в светлой и темной теме, с задержкой и без.") + "\n\n"
            + status("orbit-ios", "gpt-5.5", "41% context left", proxy="proxy work SE"),
        "terminal.txt":
            f"{GR}demo@mac{R} {CY}~/Developer/infra{R} {GY}main{R}\n$ git push\n"
            "Enumerating objects: 9, done.\nWriting objects: 100% (5/5), 812 bytes | 812.00 KiB/s, done.\n"
            "To github.com:example/infra.git\n   4f1c2a9..b81d07e  main -> main\n\n"
            f"{GR}demo@mac{R} {CY}~/Developer/infra{R} {GY}main{R}\n$ ssh db-1.internal\n"
            f"{RD}ssh: connect to host db-1.internal port 22: Operation not permitted{R}\n\n"
            f"{GR}demo@mac{R} {CY}~/Developer/infra{R} {GY}main{R}\n$ ",
    }


def session(i, project, title, branch, ago, size, agent="claude", running=False):
    return {"id": f"0c1d2e3f-4a5b-4c6d-8e7f-{i:012d}", "cwd": f"{D}/{project}", "title": title, "branch": branch,
            "mtime": NOW - ago, "size": size, "running": running, "cwdExists": True, "agent": agent}


def build(out):
    os.makedirs(out, exist_ok=True)
    subs = [{"name": "main", "port": 17892, "country": "KZ", "exit": "KZ", "inCascade": True, "blocked": False},
            {"name": "backup", "port": 17891, "country": "KZ", "exit": "KZ", "inCascade": True, "blocked": False},
            {"name": "work", "port": 17893, "country": "SE", "exit": "SE", "inCascade": False, "blocked": False}]
    proxy = {"configured": True, "running": True, "port": 17890, "current": "main", "blocked": False, "exit": "KZ",
             "protocol": "vless", "ip": "203.0.113.24", "node": "kz-almaty-1", "defaultRoute": "proxy", "sessions": 3,
             "defaultSubscription": None, "subscriptions": subs}
    modes = {"humanize": True, "translate": True, "guard": True, "buildlog": True, "notify": True, "lid": False, "alias": True}
    state = {
        "version": "1.23.0", "lang": LANG, "langSetting": LANG, "projectsDir": D, "projectsDirs": [D],
        "sessionDefaults": {"mode": "caffeinate", "remoteControl": True, "restartUpdate": True, "askModel": "sonnet"},
        "generatedAt": NOW, "errors": {},
        "projects": [{"name": n, "path": f"{D}/{n}"} for n in ("atlas-web", "infra", "ledger-api", "orbit-ios")],
        "sessions": [
            session(1, "ledger-api", t("Retry with backoff for payment webhooks", "Повторы с паузой для платежных вебхуков"), "webhook-retries", 120, 2_400_000, running=True),
            session(2, "ledger-api", t("Idempotency keys on POST /transfers", "Ключи идемпотентности для POST /transfers"), "main", 3 * 3600, 5_100_000),
            session(3, "atlas-web", t("Dark mode for the billing page", "Темная тема для страницы оплаты"), "billing-dark", 600, 1_300_000, running=True),
            session(4, "atlas-web", t("Fix the flaky checkout e2e test", "Починить нестабильный e2e-тест оплаты"), "main", 26 * 3600, 3_800_000),
            session(5, "infra", t("Postgres 17 upgrade plan", "План перехода на Postgres 17"), "main", 2 * 86400, 900_000),
            session(6, "orbit-ios", t("Widget for upcoming launches", "Виджет ближайших запусков"), "widget", 5 * 86400, 7_200_000)],
        "codexSessions": [dict(session(7, "orbit-ios", t("Snapshot tests for the launch list", "Снимочные тесты списка запусков"), "snapshots", 300, 1_100_000,
                                       agent="codex", running=True), created=NOW - 3000)],
        "live": [], "proxy": proxy, "modes": modes,
        "hostRun": {"running": True, "commands": 4, "log": H + "/.local/state/mnrh/host-run/host-run.log"},
        "signedIn": {"claude": True, "codex": True}, "retentionDays": 30, "models": {"claude": "opus", "codex": "gpt-5.5"}}
    settings = {
        "errors": {},
        "notify": {"on": True, "after": 30, "sound": True, "away": 300,
                   "telegram": {"connected": True, "bot": "demo_agents_bot", "when": "away", "away": 300, "approve": True},
                   "phone": {"mode": "off", "configured": True},
                   "tossling": {"mode": "off", "configured": True, "server": "https://tossling.example.com", "source": "cli",
                                "topic": "agentmeister", "body": "full", "docs": "https://tossling.github.io/docs/install/"},
                   "ntfy": {"mode": "always", "configured": True, "server": "https://ntfy.sh",
                            "topic": "agentmeister-q7Lm2vXc9RkTa0pWbE4n", "body": "title", "token": False, "public": True,
                            "subscribe": "https://ntfy.sh/agentmeister-q7Lm2vXc9RkTa0pWbE4n"},
                   "bark": {"mode": "away", "configured": True, "server": "https://api.day.app", "body": "full",
                            "encrypted": True, "public": True,
                            "error": {"at": int(NOW - 40 * 60), "text": "HTTP 400, the server doesn't know this device key. "
                                                                         "Copy the key again in the Bark app"}},
                   "gotify": {"mode": "away", "configured": True, "server": "https://gotify.example.com", "body": "full",
                              "priority": {"urgent": 8, "normal": 4}},
                   "webhook": {"mode": "always", "configured": True, "host": "ha.example.com", "body": "full", "auth": True},
                   "pushover": {"mode": "off", "configured": False, "body": "title"},
                   "apprise": {"mode": "off", "configured": False, "installed": False, "config": None, "body": "title",
                               "tag": None}},
        "guard": {"on": True, "log": [stamp(NOW - 26 * 3600, "%d.%m %H:%M") + "  ask   force-push     git push --force origin main",
                                      stamp(NOW - 3 * 3600, "%d.%m %H:%M") + "  hold  rm-root        rm -rf ../build-cache"],
                  "lastHit": int(NOW - 3 * 3600), "logPath": H + "/Library/Logs/mnrh-guard.log", "secrets": ["*.tfvars", "~/.kube/config"], "rules": [
            {"id": "rm-root", "text": "rm -rf вне проекта", "textEn": "rm -rf outside the project", "on": True},
            {"id": "force-push", "text": "git push --force в main", "textEn": "git push --force to main", "on": True},
            {"id": "curl-sh", "text": "curl | sh", "textEn": "curl | sh", "on": True}]},
        "hostRun": {"running": True, "pid": 4211, "version": "3", "commands": [
            {"name": "orbit-ios-build", "cwd": D + "/orbit-ios", "run": ["xcodebuild", "-scheme", "Orbit", "build"], "args": False},
            {"name": "ledger-api-deploy", "cwd": D + "/ledger-api", "run": ["fly", "deploy"], "args": True}]},
        "modesInfo": {"buildlogDays": 7, "buildlogLines": 40, "humanizeTypography": False, "buildlogDir": H + "/.cache/mnrh/buildlog", "lidReady": False,
                      "translateKey": "file", "translateModel": "gemini-3.1-flash-lite",
                      "translateProvider": "google", "translateFallback": "openrouter",
                      "translateLog": [stamp(NOW - 50 * 60) + " 3f9c2a1e 240 зн 5910 мс Google AI Studio не ответил вовремя, перевел OpenRouter",
                                       stamp(NOW - 31 * 60) + " 3f9c2a1e 182 зн 640 мс переведен",
                                       stamp(NOW - 12 * 60) + " 3f9c2a1e 96 зн пропущен, похоже на секрет (ключ API)",
                                       stamp(NOW - 4 * 60) + " 3f9c2a1e 131 зн 1380 мс переведен"],
                      "translateMedianMs": 1380,
                      "translateLogPath": H + "/Library/Logs/mnrh-translate.log"},
        "proxy": dict(proxy, country="KZ"), "modes": modes,
        "claude": {"installed": True, "path": "/opt/homebrew/bin/claude", "version": "2.3.1", "installedVia": "brew",
                   "model": "opus", "signedIn": True, "email": "dev@example.com", "plan": "Max"},
        "codex": {"installed": True, "path": "/opt/homebrew/bin/codex", "version": "0.98.0", "installedVia": "brew",
                  "model": "gpt-5.5", "signedIn": True, "email": None, "plan": "Pro"}}
    tabs = [
        {"project": "ledger-api", "path": D + "/ledger-api", "agent": "claude", "screen": "claude.txt", "selected": True},
        {"project": "orbit-ios", "path": D + "/orbit-ios", "agent": "codex", "subscription": "work", "screen": "codex.txt"},
        {"project": "atlas-web", "path": D + "/atlas-web", "agent": "claude", "subscription": "backup", "screen": "claude2.txt"},
        {"project": "infra", "path": D + "/infra", "terminal": True, "screen": "terminal.txt"}]
    commits = [("b81d07e", 40 * 60, "webhooks: retry 5xx and timeouts with backoff"),
               ("4f1c2a9", 5 * 3600, "transfers: idempotency keys on POST /transfers"),
               ("9e03b1d", 26 * 3600, "ledger: double-entry check runs in one transaction"),
               ("71ac5f2", 2 * 86400, "api: 429 with Retry-After for bursts")]
    project = {
        "path": D + "/ledger-api", "name": "ledger-api", "errors": {},
        "git": {"branch": "webhook-retries", "dirty": 3,
                "commits": [{"sha": sha, "time": int(NOW - ago), "subject": text} for sha, ago, text in commits]},
        "last": {"id": "0c1d2e3f-4a5b-4c6d-8e7f-000000000001", "title": t("Retry with backoff for payment webhooks", "Повторы с паузой для платежных вебхуков"),
                 "last": NOW - 120, "size": 2_400_000,
                 "summary": t("Webhook delivery retries 5xx and timeouts, 17 tests pass.",
                             "Доставка вебхуков повторяет 5xx и таймауты, 17 тестов проходят.")},
        "todos": [{"n": 1, "text": t("Alert when a webhook gives up after five tries", "Предупреждать, когда вебхук сдается после пяти попыток"), "done": False},
                  {"n": 2, "text": t("Document the idempotency key header", "Описать заголовок ключа идемпотентности"), "done": False},
                  {"n": 3, "text": t("Move ledger checks to the nightly job", "Перенести проверки ledger в ночную задачу"), "done": True}],
        "parallel": [{"branch": "rate-limit-headers", "task": t("Return Retry-After on 429", "Отдавать Retry-After при 429"), "ahead": "2",
                      "dirty": 0, "running": True, "path": D + "/ledger-api/.worktrees/rate-limit-headers"}],
        "tools": {"releaseSince": "v2.4.0", "gradle": False}}
    notes = [(NOW - 25 * 60, "ledger-api", "Heads up", 1,
              t("The retry loop resends webhooks with the same idempotency key, so a partner that ignores the key "
                "will book the payment twice.",
                "Цикл повторов шлет вебхук с тем же ключом идемпотентности, и партнер, который ключ не проверяет, "
                "проведет платеж дважды.")),
             (NOW - 3 * 3600, "atlas-web", "You should know", 1,
              t("Dark mode reads the theme from a cookie that the CDN caches for an hour, so some users will see "
                "the old theme after switching.",
                "Темная тема читается из cookie, которую CDN кэширует на час, и часть пользователей после "
                "переключения увидит старую тему.")),
             (NOW - 26 * 3600, "infra", "Heads up", 2,
              t("The Postgres 17 plan drops the old replica before the new one has caught up, so reads go to the "
                "primary for a while.",
                "План Postgres 17 удаляет старую реплику раньше, чем новая ее догонит, и какое-то время чтение "
                "идет в основную базу.")),
             (None, None, None, 1, t("The force push guard is off for this project, so a rebase can overwrite main.",
                                    "Защита от force push в этом проекте выключена, rebase может переписать main."))]
    headsup = {"path": H + "/.local/state/mnrh/headsup.jsonl", "plugin": True, "max": 500, "entries": [
        {"ts": ts, "headline": text, "project": proj, "cwd": f"{D}/{proj}" if proj else None, "session": None,
         "tag": tag, "times": times} for ts, proj, tag, times, text in notes]}
    for name, data in (("app-state.json", state), ("app-state-settings.json", settings), ("tabs.json", tabs),
                       ("app-state-project.json", project), ("app-state-headsup.json", headsup)):
        with open(os.path.join(out, name), "w") as f:
            json.dump(data, f, indent=1, ensure_ascii=False)
    for theme in PALETTES:
        use(theme)
        for name, text in screens().items():
            if theme == "light":
                name = name.replace(".txt", "-light.txt")
            with open(os.path.join(out, name), "w") as f:
                # у агента курсор стоит в поле ввода, а не под строкой состояния: прячем курсор терминала
                f.write(text if name.startswith("terminal") else text + E + "?25l")



def main():
    global LANG
    for LANG, out in (("en", OUT), ("ru", os.path.join(OUT, "ru"))):
        build(out)


if __name__ == "__main__":
    main()
