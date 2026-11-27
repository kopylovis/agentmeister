"""Каналы уведомлений на телефон. Хук notify проходит по ALL и шлет в каждый канал, который подключен и хочет
это сообщение сейчас: режим always или away, когда ты не за Mac (presence.py). Новый канал добавляется классом
с name, label, configured(), mode() и send(msg) и строкой в ALL."""
import json
import os
import time
from typing import NamedTuple

import bark_channel
import gotify_channel
import ntfy_alert
import ntfy_channel
import presence
import telegram
from mnrhlib import CACHE, write_json

MODES = ("off", "away", "always")
# последняя ошибка отправки по каналам: окно настроек показывает ее в строке канала, удачная отправка стирает
STATUS = os.path.join(CACHE, "notify", "channels.json")


class Message(NamedTuple):
    agent: str      # Claude Code или Codex
    head: str       # "Нужно разрешение", "Готово за 2 мин"
    project: str    # имя папки проекта, пусто, если хук не знает cwd
    title: str      # название сессии
    body: str
    urgent: bool    # вопрос или запрос, а не "готово"


class SendError(Exception):
    pass


class Channel:
    name = ""
    label = ""
    # канал сам отвечает на запросы разрешений (кнопки в Telegram): обычное уведомление о таком запросе не нужно
    handles_approvals = False

    def configured(self):
        raise NotImplementedError

    def mode(self):
        raise NotImplementedError

    def send(self, msg):
        raise NotImplementedError


class Telegram(Channel):
    name = "telegram"
    label = "Telegram"
    handles_approvals = True

    def configured(self):
        return telegram.configured()

    def mode(self):
        return telegram.mode() if self.configured() else "off"

    def send(self, msg):
        subtitle = "\n".join(part for part in (msg.project, msg.title) if part)
        try:
            telegram.send(f"{msg.agent}: {msg.head}", subtitle, msg.body)
        except telegram.TelegramError as e:
            raise SendError(str(e)) from None


def ntfy_text(msg, body):
    """Заголовок и текст для ntfy. В режиме title на сервер уходит только "Агент: что случилось" и проект:
    без названия сессии, текста вопроса и команды."""
    title = f"{msg.agent}: {msg.head}"
    if body == "title":
        return title, msg.project or msg.head
    return title, "\n\n".join(p for p in (msg.title, msg.body) if p)


class Tossling(Channel):
    """Пресет ntfy: сервер Tossling, канал agentmeister, сервер и токен у tossling на этом Mac или вручную."""
    name = "tossling"
    label = "Tossling"

    def configured(self):
        return ntfy_alert.configured()

    def mode(self):
        return ntfy_alert.phone_mode() if self.configured() else "off"

    def send(self, msg):
        title, text = ntfy_text(msg, ntfy_alert.body_mode())
        try:
            ntfy_alert.publish(ntfy_alert.AGENTMEISTER_TOPIC, text, title=title, priority=4 if msg.urgent else 3)
        except ntfy_alert.AlertError as e:
            raise SendError(str(e)) from None


class Ntfy(Channel):
    name = "ntfy"
    label = "ntfy"

    def configured(self):
        return ntfy_channel.configured()

    def mode(self):
        return ntfy_channel.mode()

    def send(self, msg):
        title, text = ntfy_text(msg, ntfy_channel.body_mode())
        try:
            ntfy_channel.send(title, text, priority=4 if msg.urgent else 3)
        except ntfy_alert.AlertError as e:
            raise SendError(str(e)) from None


class Bark(Channel):
    name = "bark"
    label = "Bark"

    def configured(self):
        return bark_channel.configured()

    def mode(self):
        return bark_channel.mode()

    def send(self, msg):
        title, text = ntfy_text(msg, bark_channel.body_mode())
        try:
            bark_channel.send(title, text, urgent=msg.urgent)
        except bark_channel.BarkError as e:
            raise SendError(str(e)) from None


class Gotify(Channel):
    name = "gotify"
    label = "Gotify"

    def configured(self):
        return gotify_channel.configured()

    def mode(self):
        return gotify_channel.mode()

    def send(self, msg):
        title, text = ntfy_text(msg, gotify_channel.body_mode())
        try:
            gotify_channel.send(title, text, urgent=msg.urgent)
        except gotify_channel.GotifyError as e:
            raise SendError(str(e)) from None


ALL = (Telegram(), Tossling(), Ntfy(), Bark(), Gotify())


def by_name(name):
    return next((ch for ch in ALL if ch.name == name), None)


def targets(approval_pending=lambda: False):
    """Каналы, в которые это сообщение надо отправить сейчас. Проверка "не за Mac" дергает ioreg, поэтому
    делается один раз и только если какому-то каналу она нужна. approval_pending зовется лишь для каналов,
    которые сами отвечают на запросы разрешений."""
    out, away = [], None
    for ch in ALL:
        mode = ch.mode()
        if mode == "off":
            continue
        if mode == "away":
            if away is None:
                away = presence.away()
            if not away:
                continue
        if ch.handles_approvals and approval_pending():
            continue
        out.append(ch)
    return out


def last_errors():
    try:
        with open(STATUS) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def record(name, error=None):
    """Запомнить итог отправки в канал: текст ошибки или None после удачной."""
    data = last_errors()
    if error is None:
        if name not in data:
            return
        data.pop(name)
    else:
        data[name] = {"at": int(time.time()), "text": str(error)[:300]}
    try:
        os.makedirs(os.path.dirname(STATUS), exist_ok=True)
        write_json(STATUS, data)
    except OSError:
        pass
