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


def quote(text):
    """Строка для командной строки security -i: в двойных кавычках, обратная косая и кавычка экранированы."""
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def save(account, value, label, service=SERVICE):
    """Записать секрет. Сама команда с секретом идет в security -i через stdin: в аргументах процесса он был бы
    виден любой программе пользователя через ps, пока security работает. security -i отвечает 0 и на ошибку,
    поэтому записанное сверяется чтением."""
    value = value.strip()
    if not value or any(c in value for c in "\r\n\0"):
        return False
    line = " ".join(["add-generic-password", "-U", "-s", quote(service), "-a", quote(account), "-l", quote(label),
                     "-w", quote(value)])
    try:
        subprocess.run(["security", "-i"], input=line + "\n", capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return find(account, service) == value


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
