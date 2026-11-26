"""Данные демо для скриншотов README: выдуманные проекты, сессии, подписки proxy и текст во вкладках.
Пишет docs/screenshots/demo/*.json и *.txt. Приложение читает их в отладочной сборке с --demo (Demo.swift)."""
import json
import os
import time

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "demo")
H = "/Users/demo"
D = H + "/Developer"
NOW = time.time()

E = "\x1b["
R, B, DIM = E + "0m", E + "1m", E + "2m"
OR, GR, RD, CY, GY, WH = (E + "38;5;" + c + "m" for c in ("173", "114", "174", "117", "245", "252"))
DOT = OR + "⏺" + R
W = 84  # ширина текста во вкладке: длиннее терминал перенес бы строку


def tool(name, arg, out):
    return f"{DOT} {B}{name}{R}({arg})\n  {GY}⎿  {out}{R}\n\n"


def box(hint):
    return (f"{GY}╭{'─' * (W - 2)}╮{R}\n{GY}│{R} {GY}>{R} {DIM}{hint}{R}{' ' * (W - 6 - len(hint))}{GY}│{R}\n"
            f"{GY}╰{'─' * (W - 2)}╯{R}\n")


def status(*parts, proxy):
    return "  " + f" {GY}·{R} ".join([f"{CY}{parts[0]}{R}"] + [f"{GY}{p}{R}" for p in parts[1:]]) + f" {GY}·{R} {GR}{proxy}{R}\n"


SCREENS = {
    "claude.txt":
        f"{OR}✻{R} {B}Claude Code{R} {GY}v2.3.1 · Opus 5.5 · ~/Developer/ledger-api{R}\n\n"
        f"{GY}>{R} {WH}Add retry with backoff to the payment webhook handler and cover it with tests{R}\n\n"
        f"{DOT} I'll check how webhook delivery works now, then wrap the provider call.\n\n"
        + tool("Read", "src/webhooks/payments.ts", "Read 142 lines")
        + tool("Grep", '"deliverWebhook", path: "src"', "Found 3 files")
        + f"{DOT} {B}Update{R}(src/webhooks/payments.ts)\n"
          f"  {GY}⎿  Updated src/webhooks/payments.ts with 21 additions and 6 removals{R}\n"
          f"     {GY}48{R} {RD}-  const res = await provider.send(event){R}\n"
          f"     {GY}48{R} {GR}+  const res = await withRetry(() => provider.send(event), {{{R}\n"
          f"     {GY}49{R} {GR}+    tries: 5, baseMs: 500, maxMs: 8000,{R}\n"
          f"     {GY}50{R} {GR}+    retryOn: (e) => e.status >= 500 || e.code === 'ETIMEDOUT',{R}\n"
          f"     {GY}51{R} {GR}+  }}){R}\n\n"
        + tool("Write", "test/webhooks/retry.test.ts", "Wrote 64 lines to test/webhooks/retry.test.ts")
        + tool("Bash", "npm test -- webhooks", f"{GR}PASS{R}{GY} payments.test.ts (12)  {GR}PASS{R}{GY} retry.test.ts (5)")
        + f"{DOT} Delivery now retries 5xx answers and timeouts after 0.5, 1, 2 and 4 seconds,\n"
          f"  five tries in total. A 4xx answer fails at once, so a bad signature doesn't\n"
          f"  hammer the provider. All 17 webhook tests pass.\n\n"
        + box('Try "open a PR for this"')
        + status("ledger-api", "webhook-retries", "Opus 5.5", "ctx 31%", "5h 18%", proxy="proxy main KZ"),
    "claude2.txt":
        f"{OR}✻{R} {B}Claude Code{R} {GY}v2.3.1 · Opus 5.5 · ~/Developer/atlas-web{R}\n\n"
        f"{GY}>{R} {WH}The billing page ignores dark mode, fix it without touching brand colors{R}\n\n"
        + tool("Read", "app/billing/page.tsx", "Read 211 lines")
        + tool("Update", "app/billing/invoice-table.tsx", "Updated with 9 additions and 9 removals")
        + tool("Bash", "pnpm test billing", f"{GR}✓{R}{GY} 23 passed")
        + f"{DOT} The invoice table hard-coded #fff and #111. It now uses the surface and text\n"
          f"  tokens and follows the system theme. Brand colors are untouched.\n\n"
        + box("")
        + status("atlas-web", "billing-dark", "Opus 5.5", "ctx 12%", proxy="proxy backup KZ"),
    "codex.txt":
        f"{B}>_ OpenAI Codex{R} {GY}(v0.98.0) · gpt-5.5 · ~/Developer/orbit-ios{R}\n\n"
        f"{CY}›{R} Add snapshot tests for the launch list in light and dark mode\n\n"
        f"{GY}•{R} Explored\n  {GY}└ Read LaunchListView.swift, LaunchRow.swift{R}\n\n"
        f"{GY}•{R} Edited Tests/LaunchListSnapshotTests.swift {GR}(+58 -0){R}\n\n"
        f"{GY}•{R} Ran xcodebuild test -scheme Orbit -only-testing:OrbitTests/LaunchListSnapshotTests\n"
        f"  {GY}└{R} {GR}Test Suite 'LaunchListSnapshotTests' passed (4 tests, 3.2 s){R}\n\n"
        f"{GY}•{R} Four snapshots cover the list in light and dark mode, with and without a delay.\n\n"
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


def main():
    os.makedirs(OUT, exist_ok=True)
    subs = [{"name": "main", "port": 17892, "country": "KZ", "exit": "KZ", "inCascade": True, "blocked": False},
            {"name": "backup", "port": 17891, "country": "KZ", "exit": "KZ", "inCascade": True, "blocked": False},
            {"name": "work", "port": 17893, "country": "SE", "exit": "SE", "inCascade": False, "blocked": False}]
    proxy = {"configured": True, "running": True, "port": 17890, "current": "main", "blocked": False, "exit": "KZ",
             "protocol": "vless", "ip": "203.0.113.24", "node": "kz-almaty-1", "defaultRoute": "proxy", "sessions": 3,
             "defaultSubscription": None, "subscriptions": subs}
    modes = {"humanize": True, "guard": True, "buildlog": True, "notify": True, "lid": False, "alias": True}
    state = {
        "version": "1.23.0", "lang": "en", "langSetting": "en", "projectsDir": D, "projectsDirs": [D],
        "generatedAt": NOW, "errors": {},
        "projects": [{"name": n, "path": f"{D}/{n}"} for n in ("atlas-web", "infra", "ledger-api", "orbit-ios")],
        "sessions": [
            session(1, "ledger-api", "Retry with backoff for payment webhooks", "webhook-retries", 120, 2_400_000, running=True),
            session(2, "ledger-api", "Idempotency keys on POST /transfers", "main", 3 * 3600, 5_100_000),
            session(3, "atlas-web", "Dark mode for the billing page", "billing-dark", 600, 1_300_000, running=True),
            session(4, "atlas-web", "Fix the flaky checkout e2e test", "main", 26 * 3600, 3_800_000),
            session(5, "infra", "Postgres 17 upgrade plan", "main", 2 * 86400, 900_000),
            session(6, "orbit-ios", "Widget for upcoming launches", "widget", 5 * 86400, 7_200_000)],
        "codexSessions": [dict(session(7, "orbit-ios", "Snapshot tests for the launch list", "snapshots", 300, 1_100_000,
                                       agent="codex", running=True), created=NOW - 3000)],
        "live": [], "proxy": proxy, "modes": modes,
        "hostRun": {"running": True, "commands": 4, "log": H + "/.local/state/mnrh/host-run/host-run.log"},
        "signedIn": {"claude": True, "codex": True}, "retentionDays": 30, "models": {"claude": "opus", "codex": "gpt-5.5"}}
    settings = {
        "errors": {},
        "notify": {"on": True, "after": 30, "sound": True,
                   "telegram": {"connected": True, "bot": "demo_agents_bot", "when": "away", "away": 5, "approve": True},
                   "phone": {"mode": "off", "configured": False}},
        "guard": {"on": True, "log": [], "logPath": H + "/.local/state/mnrh/guard.log", "rules": [
            {"id": "rm-root", "text": "rm -rf вне проекта", "textEn": "rm -rf outside the project", "on": True},
            {"id": "force-push", "text": "git push --force в main", "textEn": "git push --force to main", "on": True},
            {"id": "curl-sh", "text": "curl | sh", "textEn": "curl | sh", "on": True}]},
        "hostRun": {"running": True, "pid": 4211, "version": "3", "commands": [
            {"name": "orbit-ios-build", "cwd": D + "/orbit-ios", "run": ["xcodebuild", "-scheme", "Orbit", "build"], "args": False},
            {"name": "ledger-api-deploy", "cwd": D + "/ledger-api", "run": ["fly", "deploy"], "args": True}]},
        "modesInfo": {"buildlogDays": 7, "buildlogLines": 40, "buildlogDir": H + "/.cache/mnrh/buildlog", "lidReady": False},
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
        "last": {"id": "0c1d2e3f-4a5b-4c6d-8e7f-000000000001", "title": "Retry with backoff for payment webhooks",
                 "last": NOW - 120, "size": 2_400_000,
                 "summary": "Webhook delivery retries 5xx and timeouts, 17 tests pass."},
        "todos": [{"n": 1, "text": "Alert when a webhook gives up after five tries", "done": False},
                  {"n": 2, "text": "Document the idempotency key header", "done": False},
                  {"n": 3, "text": "Move ledger checks to the nightly job", "done": True}],
        "parallel": [{"branch": "rate-limit-headers", "task": "Return Retry-After on 429", "ahead": "2",
                      "dirty": 0, "running": True, "path": D + "/ledger-api/.worktrees/rate-limit-headers"}],
        "tools": {"releaseSince": "v2.4.0", "gradle": False}}
    for name, data in (("app-state.json", state), ("app-state-settings.json", settings), ("tabs.json", tabs),
                       ("app-state-project.json", project)):
        with open(os.path.join(OUT, name), "w") as f:
            json.dump(data, f, indent=1, ensure_ascii=False)
    for name, text in SCREENS.items():
        with open(os.path.join(OUT, name), "w") as f:
            f.write(text)


if __name__ == "__main__":
    main()
