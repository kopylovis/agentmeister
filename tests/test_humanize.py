import os
import sys
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "libexec", "agentmeister", "lib"))
import claude_humanize as h  # noqa: E402


def rules(text):
    return {name for _, name, _ in h.check(text)}


class NewMarkers(unittest.TestCase):
    def test_flags(self):
        cases = {
            "It speeds up builds without sacrificing safety.": "обещание без цены",
            "Сборка ускорилась без ущерба для надежности.": "обещание без цены",
            "It feels less like a tool and more like a partner.": "не только… но и",
            "This matters because users wait.": "дидактика",
            "It should not be confused with Java.": "дидактика",
            "Looking ahead, we plan more.": "переход-шаблон",
            "Honestly, it works.": "показная честность",
            "That is worth naming.": "постановка",
            "His website identifies him as a retired officer.": "опора на самоописание",
            "Verify the numbers before publishing.": "инструкция в чистовике",
            "Проверьте даты перед публикацией.": "инструкция в чистовике",
            "See INSERT_SOURCE_URL_30 here.": "заглушка",
            "Released on 2026-XX-XX.": "заглушка",
            "A <mark>quote</mark> from the page.": "след чат-инструмента",
            "X ≠ Y in prose.": "символы вместо слов",
            "Ура!!": "пафос",
            "Цена−скидка.": "невидимые и редкие символы",
            "Узкий пробел.": "невидимые и редкие символы",
            "а б в г": "неразрывные пробелы",
        }
        for text, rule in cases.items():
            self.assertIn(rule, rules(text), text)

    def test_no_false_alarms(self):
        for text in ("Отлично! Работает.", "Migrated without losing data.", "Порт 8444, а не 8443.",
                     "Один неразрывный пробел.", "Look at the logs first.", "Код `INSERT_ME` в бэктиках."):
            self.assertEqual(rules(text), set(), text)


class LogFixes(unittest.TestCase):
    """Ложные срабатывания из ~/Library/Logs/mnrh-humanize.log и то, что маркеры после правки ловят по-прежнему."""

    def test_still_flags(self):
        cases = {
            "Подходит всем, от новичков до профессионалов.": "от… до…",
            "Мы проводим работу по улучшению.": "канцелярит",
            "Была проведена работа над ошибками.": "канцелярит",
            "We harness the power of models.": "слова нейросети",
            "Важно учитывать контекст.": "дидактика",
            "Следует отметить рост.": "дидактика",
            "Нужно учитывать, что кэш общий.": "дидактика",
            "Чтобы было понятно, это не баг.": "спор с никем",
            "Может упасть. Может зависнуть. Может пропасть.": "одинаковое начало трех фраз",
            "Ура 🤖 тут.": "эмодзи",
            "Цена одна: svg больше не открывается.": "анонс через двоеточие",
            "Если согласен, порядок такой: сначала веб.": "анонс через двоеточие",
            "The fix is simple: drop the cache.": "анонс через двоеточие",
            "Short version: it works.": "анонс через двоеточие",
        }
        for text, rule in cases.items():
            self.assertIn(rule, rules(text), text)

    def test_no_false_alarms(self):
        for text in ("Сборка идет от нескольких часов до суток.", "Пакет идет от Mac до сервера.",
                     "Хуки от SessionStart до SubagentStop.", "От начала до готового файла прошло шесть минут.",
                     "Проводник работает быстро.", "Run it in the Codex harness.", "Нужно учесть часовой пояс.",
                     "Переименую файл, чтобы было понятно, что он делает.", "The cat sat. The dog ran. The end came.",
                     "На столе ключ. На полке книга. На полу кот.", "Команда такая:\n\n```\nmake test\n```",
                     "Тестов два, оба проходят.",
                     "Готово.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"):
            self.assertEqual(rules(text), set(), text)


class SourceMarkers202611(unittest.TestCase):
    """Маркеры из WP:AISIGNS, Graphite по Opus 5.5, Pangram и наборов правил на GitHub, ноябрь 2026."""

    def test_flags(self):
        cases = {
            "She maintains an active digital presence.": "значимость",
            "The book has shaped discussions about memory.": "значимость",
            "It forms part of the wider history of the town.": "значимость",
            "The twist adds another layer of complexity.": "значимость",
            "His parliamentary biography records that he served.": "опора на самоописание",
            "Rust should be distinguished from C++.": "дидактика",
            "Tests ran. This matters.": "дидактика",
            "Стоит напомнить, что кэш общий.": "дидактика",
            "Напомним, что порт закрыт.": "дидактика",
            "A cache is more than a store, it's a contract.": "не только… но и",
            "Это больше, чем просто скрипт.": "не только… но и",
            "The hard part is the cache.": "постановка",
            "Here's the interesting part.": "постановка",
            "Секрет прост, нужен кэш.": "постановка",
            "It is perhaps the most useful flag.": "усилитель",
            "Пожалуй, самый быстрый способ.": "усилитель",
            "Кто-то возразит, что это медленно.": "спор с никем",
            "Вопрос остается открытым.": "пустой прогноз",
            "Рады сообщить о релизе.": "служба поддержки",
            "I would like to clarify that the edit was mine.": "служба поддержки",
            "Если хотите, могу сократить.": "чат-бот",
            "Пишем отчеты на ежедневной основе.": "калька",
            "Click the button below to get started.": "пересказ интерфейса",
            "Нажмите кнопку ниже, чтобы начать.": "пересказ интерфейса",
            "Evidence to be supplied: diffs.": "заглушка",
            "Текст поста.\n(около 120 слов)": "заглушка",
            "See [cite_start]this.": "след чат-инструмента",
            "Docs [web:1] say so.": "след чат-инструмента",
            "writing{variant=\"standard\" id=\"1\"}": "след чат-инструмента",
            "https://vertexaisearch.cloud.google.com/grounding-api-redirect/abc": "след чат-инструмента",
            "Схема ├── src": "псевдографика",
            "It works out-of-the-box.": "штамп",
            "Тег\U000e0041 внутри.": "невидимые и редкие символы",
        }
        for text, rule in cases.items():
            self.assertIn(rule, rules(text), text)

    def test_no_false_alarms(self):
        for text in ("Это не столько инструмент, сколько привычка.", "Порт остается открытым.",
                     "Run tests in the harness.", "Если хочешь, проверю место на диске.", "This matters for the cache size.",
                     "Speed is important, and so is memory.", "Схема в блоке:\n\n```\n├── src\n```",
                     "Сборка заняла 120 секунд.", "The part of the code that matters is small.",
                     "See https://example.org/docs for details.", "Больше чем в два раза."):
            self.assertEqual(rules(text), set(), text)


if __name__ == "__main__":
    unittest.main()
