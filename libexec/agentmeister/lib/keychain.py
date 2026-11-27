"""Секреты каналов уведомлений в Связке ключей macOS: сервис agentmeister.notify, аккаунт по имени канала."""
import subprocess
import sys

SERVICE = "agentmeister.notify"


def find(account, service=SERVICE):
    try:
        r = subprocess.run(["security", "find-generic-password", "-s", service, "-a", account, "-w"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def save(account, value, label, service=SERVICE):
    try:
        r = subprocess.run(["security", "add-generic-password", "-U", "-s", service, "-a", account, "-l", label,
                            "-w", value], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0


def delete(account, service=SERVICE):
    try:
        subprocess.run(["security", "delete-generic-password", "-s", service, "-a", account],
                       capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        pass


def read_secret(prompt):
    """Из терминала спрашивает без эха. Приложение и скрипты передают секрет через stdin, не аргументом:
    аргументы видны в ps."""
    if sys.stdin.isatty():
        from menu import secret
        return secret(prompt).strip()
    return sys.stdin.read().strip()
