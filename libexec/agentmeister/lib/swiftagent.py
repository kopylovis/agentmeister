"""Помощник на Swift, который живёт в фоне как LaunchAgent: сборка в .app, автозапуск, состояние.

Здесь на нем приложение уведомлений agentmeister Notify (в mnrh такая же копия собирает mnrh scroll). Исходник —
share/agentmeister/<name>/main.swift. Собирается в ~/Library/Application Support/agentmeister/<display>.app только при изменении исходника: macOS
выдаёт разрешения (Универсальный доступ и т. п.) конкретной сборке, и лишняя пересборка их сбросит.
"""
import contextlib
import fcntl
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

from mac_files import RENAME_EXCL, RENAME_SWAP, rename_with_flags
from mnrhlib import CACHE, HOME, WARN, settings_path, tr

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
STALE_BUILD = 3600  # временная папка .build-* старше часа осталась от убитой сборки


class SwiftAgent:
    def __init__(self, name, display, label, service_args=None, url_schemes=(), title=None, stable_id=False, app_dir=None):
        self.name, self.display, self.base = name, display, label
        self.service_args = service_args
        self.url_schemes = tuple(url_schemes)
        self.title = title or display
        self.stable_id = stable_id
        self.src = os.path.join(ROOT, "share", "agentmeister", name, "main.swift")
        self.app = os.path.join(app_dir or os.path.join(HOME, "Library", "Application Support", "agentmeister"), f"{display}.app")
        self.bin = os.path.join(self.app, "Contents", "MacOS", f"agentmeister-{name}")
        self.stamp = os.path.join(self.app, "Contents", "Resources", "source.sha256")
        self.plist = os.path.join(HOME, "Library", "LaunchAgents", f"{label}.plist")
        self.state_file = os.path.join(CACHE, f"{name}.json")
        self.log = os.path.join(HOME, "Library", "Logs", f"mnrh-{name}.log")
        self.domain = f"gui/{os.getuid()}"
        self.agents_dir = os.path.join(self.app, "Contents", "Library", "LaunchAgents")

    @property
    def label(self):
        if self.service_args is not None:
            try:
                with open(os.path.join(self.app, "Contents", "Info.plist"), "rb") as f:
                    info = plistlib.load(f)
                    return info.get("MnrhServiceLabel") or info.get("CFBundleIdentifier") or self.base
            except (OSError, ValueError):
                pass
        return self.base

    def build_label(self):
        if self.service_args is None:
            return self.base
        h = hashlib.sha256()
        for p in (*self.sources(), self.icon()):
            if p:
                with open(p, "rb") as f:
                    h.update(f.read())
        h.update(json.dumps([self.service_args, self.state_file, self.log]).encode())
        return f"{self.base}.{h.hexdigest()[:8]}"

    def launchctl(self, *a):
        return subprocess.run(["launchctl", *a], capture_output=True, text=True)

    def loaded(self):
        return self.launchctl("print", f"{self.domain}/{self.label}").returncode == 0

    def installed(self):
        if self.service_args is not None:
            return os.path.exists(self.plist) or self.service("--service-status") in ("enabled", "requiresApproval")
        return os.path.exists(self.plist)

    def service_plist(self, label):
        exe = os.path.basename(self.bin)
        return plistlib.dumps({
            "Label": label,
            "BundleProgram": f"Contents/MacOS/{exe}",
            "ProgramArguments": [exe, *self.service_args, "--state", self.state_file],
            "AssociatedBundleIdentifiers": [label],
            "RunAtLoad": True,
            "KeepAlive": True,
            "ProcessType": "Interactive",
            "StandardErrorPath": self.log,
            "StandardOutPath": self.log,
        })

    def service(self, command):
        if not os.access(self.bin, os.X_OK) or not os.path.isdir(self.agents_dir):
            return "notRegistered"
        r = subprocess.run([self.bin, command], capture_output=True, text=True, timeout=30)
        return (r.stdout.strip() or r.stderr.strip() or "error").splitlines()[-1]

    def approve_login_item(self):
        where = settings_path('settings', 'general', 'login')
        print(tr(f"{WARN} macOS ждёт разрешения для фонового объекта: "
                 f"{where} → «{self.display}».",
                 f"{WARN} macOS is waiting for you to allow the background item: "
                 f"{where} → \"{self.display}\"."))
        subprocess.run(["open", "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"])
        if not sys.stdin.isatty():
            return False
        print(tr("Жду до двух минут...", "Waiting up to two minutes..."), end="", flush=True)
        for _ in range(120):
            time.sleep(1)
            if self.service("--service-status") == "enabled":
                print(tr(" есть.", " done."))
                return True
        print(tr("\nНе дождался. Как разрешишь — снова то же on.", "\nTimed out. Once you allow it, run the same on again."))
        return False

    def drop_legacy(self):
        if self.service_args is not None and os.path.exists(self.plist):
            self.launchctl("bootout", f"{self.domain}/{self.base}")
            os.unlink(self.plist)

    def state(self):
        try:
            with open(self.state_file) as f:
                s = json.load(f)
            os.kill(s["pid"], 0)
            return s
        except (OSError, ValueError, KeyError):
            return None

    def sources(self):
        folder = os.path.dirname(self.src)
        return [self.src] + sorted(os.path.join(folder, f) for f in os.listdir(folder)
                                   if f.endswith(".swift") and f != "main.swift")

    def signing_identity(self):
        if not self.stable_id:
            return "-"
        out = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
        m = re.search(r'"(Apple Development: [^"]+)"', out)
        return m.group(1) if m else "-"

    def icon(self):
        for p in (os.path.join(os.path.dirname(self.src), "icon.png"), os.path.join(ROOT, "share", "agentmeister", "icon.png")):
            if os.path.exists(p):
                return p
        return None

    def source_hash(self):
        h = hashlib.sha256()
        for p in (*self.sources(), self.icon()):
            if p:
                with open(p, "rb") as f:
                    h.update(f.read())
        if self.service_args is not None:
            h.update(self.service_plist(self.build_label()))
        h.update(repr((self.url_schemes, self.title, self.stable_id, self.signing_identity())).encode())
        return h.hexdigest()

    def make_icns(self, tmp, resources):
        png = self.icon()
        if not png:
            return False
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
                px = str(size * scale)
                subprocess.run(["sips", "-z", px, px, png, "--out", os.path.join(iconset, name)], capture_output=True)
        out = os.path.join(resources, "AppIcon.icns")
        return subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], capture_output=True).returncode == 0

    def needs_build(self):
        """Хеш исходников, если приложение надо собрать заново, иначе None."""
        want = self.source_hash()
        try:
            if open(self.stamp).read().strip() == want and os.access(self.bin, os.X_OK) and \
                    os.path.basename(self.app) in os.listdir(os.path.dirname(self.app)):
                return None
        except OSError:
            pass
        return want

    @contextlib.contextmanager
    def build_lock(self, wait=True):
        """Замок на сборку: две сборки сразу (два хука, хук и setup) мешают друг другу.
        Отдает True, если замок взят; с wait=False — False, когда его держит другой процесс."""
        parent = os.path.dirname(self.app)
        os.makedirs(parent, exist_ok=True)
        fd = os.open(os.path.join(parent, f".{self.name}.build.lock"), os.O_RDWR | os.O_CREAT, 0o644)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
            except BlockingIOError:
                yield False
                return
            yield True
        finally:
            os.close(fd)

    def building(self):
        """Сейчас собирает другой процесс."""
        with self.build_lock(wait=False) as got:
            return not got

    def clean_stale_builds(self):
        """Убрать папки .build-*, оставшиеся от сборок, которые убили на полпути."""
        parent = os.path.dirname(self.app)
        cutoff = time.time() - STALE_BUILD
        try:
            names = os.listdir(parent)
        except OSError:
            return
        for name in names:
            path = os.path.join(parent, name)
            try:
                if name.startswith(".build-") and not os.path.islink(path) and os.path.isdir(path) \
                        and os.path.getmtime(path) < cutoff:
                    shutil.rmtree(path, ignore_errors=True)
            except OSError:
                pass

    def build(self, wait=True):
        """Собирает, если исходник поменялся. True — собран заново, False — сборка не нужна,
        None — с wait=False другой процесс как раз собирает."""
        if not self.needs_build():
            return False
        with self.build_lock(wait) as got:
            if not got:
                return None
            return self._build_locked()

    def _build_locked(self):
        want = self.needs_build()  # пока ждали замок, мог собрать другой процесс
        if not want:
            return False
        self.clean_stale_builds()
        if not shutil.which("swiftc"):
            sys.exit(tr("Нужен компилятор Swift из Xcode Command Line Tools: xcode-select --install",
                        "You need the Swift compiler from Xcode Command Line Tools: xcode-select --install"))
        print(tr(f"Собираю {self.display}...", f"Building {self.display}..."))
        parent = os.path.dirname(self.app)
        with tempfile.TemporaryDirectory(prefix=".build-", dir=parent) as tmp:
            app = os.path.join(tmp, os.path.basename(self.app))
            contents = os.path.join(app, "Contents")
            binary = os.path.join(contents, "MacOS", os.path.basename(self.bin))
            resources = os.path.join(contents, "Resources")
            os.makedirs(os.path.dirname(binary))
            os.makedirs(resources)
            r = subprocess.run(["swiftc", "-O", "-swift-version", "5", *self.sources(), "-o", binary],
                               capture_output=True, text=True)
            if r.returncode != 0:
                sys.exit(tr("Сборка не удалась:\n", "Build failed:\n") + r.stderr[-2000:])
            has_icon = self.make_icns(tmp, resources)
            if self.icon() and not has_icon:
                sys.exit(tr("Не удалось собрать иконку приложения", "Couldn't build the app icon"))
            label = self.build_label()
            if self.service_args is not None:
                agents = os.path.join(contents, "Library", "LaunchAgents")
                os.makedirs(agents)
                with open(os.path.join(agents, f"{label}.plist"), "wb") as f:
                    f.write(self.service_plist(label))
            bundle_id = self.base if self.stable_id else label
            info = {"CFBundleIdentifier": bundle_id, "CFBundleName": self.title, "MnrhServiceLabel": label,
                    "CFBundleDisplayName": self.title, "CFBundleExecutable": os.path.basename(self.bin),
                    "CFBundlePackageType": "APPL", "CFBundleVersion": str(int(time.time())),
                    "CFBundleShortVersionString": "1." + time.strftime("%Y%m%d"), "LSUIElement": True}
            if has_icon:
                info["CFBundleIconFile"] = "AppIcon"
            if self.url_schemes:
                info["CFBundleURLTypes"] = [{"CFBundleURLName": label, "CFBundleURLSchemes": list(self.url_schemes)}]
            with open(os.path.join(contents, "Info.plist"), "wb") as f:
                plistlib.dump(info, f)
            with open(os.path.join(resources, os.path.basename(self.stamp)), "w") as f:
                f.write(want + "\n")
            r = subprocess.run(["codesign", "--force", "--sign", self.signing_identity(), "--identifier", bundle_id, app],
                               capture_output=True, text=True)
            if r.returncode != 0:
                sys.exit(tr("Не удалось подписать помощника:\n", "Couldn't sign the helper:\n") + r.stderr)
            try:
                rename_with_flags(app, self.app, RENAME_EXCL)
            except FileExistsError:
                rename_with_flags(app, self.app, RENAME_SWAP)
        lsregister = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/"
                      "Support/lsregister")
        if os.path.exists(lsregister):
            subprocess.run([lsregister, "-f", self.app], capture_output=True)
        return True

    def write_plist(self, extra_args):
        os.makedirs(os.path.dirname(self.plist), exist_ok=True)
        os.makedirs(os.path.dirname(self.state_file), exist_ok=True)
        with open(self.plist, "wb") as f:
            plistlib.dump({
                "Label": self.base,
                "ProgramArguments": [self.bin, *extra_args, "--state", self.state_file],
                "RunAtLoad": True,
                "KeepAlive": True,
                "ProcessType": "Interactive",
                "StandardErrorPath": self.log,
                "StandardOutPath": self.log,
            }, f)

    def stop(self):
        if self.service_args is not None:
            self.drop_legacy()
            self.service("--unregister")
        if self.loaded():
            self.launchctl("bootout", f"{self.domain}/{self.label}")
            for _ in range(20):
                if not self.loaded():
                    break
                time.sleep(0.25)

    def start(self):
        """Перезапускает с текущим plist. True, если помощник поднялся и записал состояние."""
        try:
            if os.path.getsize(self.log) > 1048576:
                os.truncate(self.log, 0)
        except OSError:
            pass
        if self.service_args is not None:
            self.drop_legacy()
            was = self.service("--service-status") == "enabled"
            for attempt in range(16):
                status = self.service("--register")
                if status == "requiresApproval":
                    return status
                if status != "enabled":
                    sys.exit(tr(f"macOS не зарегистрировал помощника: {status}", f"macOS didn't register the helper: {status}"))
                if was:
                    self.launchctl("kickstart", "-k", f"{self.domain}/{self.label}")
                if self.wait_state():
                    return True
                self.service("--unregister")
                was = False
                time.sleep(5)
            return False
        self.stop()
        r = self.launchctl("bootstrap", self.domain, self.plist)
        if r.returncode != 0:
            sys.exit(tr(f"launchctl не запустил помощника: {r.stderr.strip()}",
                        f"launchctl didn't start the helper: {r.stderr.strip()}"))
        return self.wait_state()

    def wait_state(self):
        for _ in range(20):
            if self.state():
                return True
            time.sleep(0.25)
        return False

    def restart(self):
        self.launchctl("kickstart", "-k", f"{self.domain}/{self.label}")
        time.sleep(1)
        return self.state()

    def uninstall(self):
        self.stop()
        for p in (self.plist, self.state_file):
            try:
                os.unlink(p)
            except OSError:
                pass
