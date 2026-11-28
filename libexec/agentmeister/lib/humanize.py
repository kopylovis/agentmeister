import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import CACHE, CLAUDE_HOME, HOME, UUID_RE, badge, lang, read_config, tilde, tr, write_config
import claude_settings

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__)))))
RULES = os.path.join(ROOT, "share", "agentmeister", "humanize.md")
# Строгая типографика (прямые кавычки, без е с точками, без двоеточий) подключается отдельно: humanize_typography=on
TYPOGRAPHY = os.path.join(ROOT, "share", "agentmeister", "humanize-typography.md")
STATE = os.path.join(CACHE, "humanize")
LOG = os.path.join(HOME, "Library", "Logs", "mnrh-humanize.log")
SETTINGS = claude_settings.PATH
SLASH_FILE = os.path.join(CLAUDE_HOME, "commands", "humanize.md")
HOOK_CMD = "humanize-hook"
HOOK_ROWS = claude_settings.rows(HOOK_CMD)

REMINDER = ("agentmeister humanization включена, правила письма из начала сессии действуют для всего, что ты пишешь людям. "
            "Ответ первым, без вступлений и итогов-пересказов, отдавай только то, что просили. Конкретные факты "
            "вместо значимости, восторгов и штампов. Без канцелярита, \"является\", \"позволяет\", модальной ваты, "
            "усилителей, \"по сути\" и объявленной честности. Длина предложений разная, без обрывков подряд. "
            "Без \"не только... но и\", троек, \"от... до...\", хвостов \"..., подчеркивая\". Длинное тире только "
            "где его требует грамматика (в английском никогда), пункты списка \"термин — пояснение\" запрещены. "
            "Без жирного, нумерованных жирных и курсивных подзаголовков, \"---\", списков \"Заголовок: текст\" и эмодзи. "
            "Текст, который пользователь отправит людям, пиши как сообщение в мессенджере (правило 4.7). "
            "Перед отправкой перечитай по разделу 7.")
TYPOGRAPHY_REMINDER = " Кавычки только прямые \"\", елочки нельзя. Букву е с точками не пиши, только е. Двоеточий избегай."
OFF_NOTE = "agentmeister humanization выключена, правила письма из этой сессии больше не обязательны, пиши как обычно."

S = r"(?:^|(?<=[.!?…]\s)|(?<=\n))"
MARKERS = [
    ("значимость", r"\b(?:игра\w*|сыгра\w*)\s+(?:важн|ключев|значительн|решающ|центральн|огромн|заметн)\w*\s+рол"),
    ("значимость", r"\b(?:служ|выступа|являет|станов|стал)\w*\s+(?:символ|напоминани)"),
    ("значимость", r"\bсимволизиру|\bподч[её]ркива\w*\s+(?:важност|значимост|значени)|\b(?:ключев|поворотн)\w*\s+момент"
                   r"|\bнеизгладим|\b(?:устойчив|длительн)\w*\s+влияни|\bнепоколебим"),
    ("значимость", r"\b(?:play(?:s|ed|ing)?)\s+an?\s+(?:pivotal|crucial|vital|key|significant|important|central)\s+role"
                   r"|\bserves?\s+as\s+an?\s+(?:testament|reminder|symbol)|\ba\s+testament\s+to|\bpivotal\s+moment"
                   r"|\benduring\s+legacy|\bindelible|\bunderscor(?:e|es|ed|ing)\b"),
    ("хвост-деепричастие", r",\s+(?:подч[её]ркивая|демонстрируя|отражая|способствуя|содействуя|обеспечивая|выделяя"
                           r"|символизируя|усиливая|воплощая|знаменуя|укрепляя)\b"),
    ("хвост-деепричастие", r",\s+(?:highlighting|underscoring|showcasing|reflecting|emphasizing|demonstrating"
                           r"|contributing\s+to|ensuring|fostering|symbolizing|solidifying|cementing)\b"),
    ("реклама", r"\bбогат\w*\s+(?:культурн|истори|наслед|традиц)|\bзахватывающ|\bживописн|\bпотрясающ|\bв\s+самом\s+сердце"
                r"|\bможет\s+похвастаться|\bпродолжает\s+(?:очаровывать|процветать|вдохновлять|радовать)|\bвеков\w*\s+наслед"
                r"|\bдостойн\w*\s+(?:посещения|внимания)|\bбесшовн|\bне\s+имеющ\w*\s+аналогов"),
    ("реклама", r"\b(?:vibrant|breathtaking|stunning|nestled|captivating|renowned|seamless(?:ly)?|cutting-edge"
                r"|game[- ]changer)\b|\bin\s+the\s+heart\s+of\b|\bboasts?\b|\brich\s+(?:cultural|history|heritage|tapestry)"
                r"|\bunlock\w*\s+the\s+(?:power|potential)"),
    ("освещение в СМИ", r"\b(?:освещал\w*|писали|упоминал\w*)\s+(?:в|во)\s+(?:нескольких|ряде|ведущих|многочисленных|различных)"
                        r"|\bнезависим\w*\s+освещени|\bfeatured\s+in\s+(?:several|numerous|multiple)"),
    # "нужно учесть часовой пояс" это просьба, а не дидактика: у "следует / необходимо / нужно" ловим только "..., что"
    ("дидактика", r"\b(?:важно|стоит|критически\s+важно|крайне\s+важно)\s+"
                  r"(?:отметить|учесть|учитывать|помнить|запомнить|подчеркнуть|упомянуть|понимать)\b"
                  r"|\b(?:следует|необходимо|нужно)\s+(?:отметить|подчеркнуть|упомянуть)\b"
                  r"|\b(?:следует|необходимо|нужно)\s+(?:учесть|учитывать|помнить|запомнить|понимать),?\s+(?:что|:)"
                  r"|\bобратите\s+внимание"
                  r"|\b(?:значения|результаты|показатели)\s+могут\s+(?:варьироваться|различаться)|\bчтобы\s+избежать\s+путаницы"
                  r"|\bкрайне\s+важно"),
    ("дидактика", r"\bit'?s\s+(?:important|worth|crucial|essential|vital)\s+(?:to\s+(?:note|remember|mention|keep)|noting)"
                  r"|\bkeep\s+in\s+mind\b|\bmay\s+vary\b"),
    ("итог-пересказ", S + r"\s*(?:в\s+заключение|подводя\s+итоги?|вкратце|в\s+целом|итак|резюмируя|таким\s+образом)\b"),
    ("итог-пересказ", S + r"\s*(?:in\s+conclusion|in\s+summary|to\s+sum\s+up|overall,|ultimately,|in\s+essence)"),
    ("итог-пересказ", r"(?m)^\s*(?:#+\s*|\*\*)?(?:заключение|выводы|итоги|подводя\s+итоги|conclusion|summary|key\s+takeaways)"
                      r"\s*(?:\*\*)?:?\s*$"),
    ("проблемы-перспективы", r"\bнесмотря\s+на\s+(?:эти|все|свои|многочисленн|определённ|определенн)"
                             r"|\bсталкива\w*\s+с\s+(?:рядом|определённ\w*|определенн\w*|многочисленн\w*|некоторыми)\s+(?:проблем|трудност|вызов)"
                             r"|\bперспектив\w*\s+на\s+будущее|\bоткрыва\w*\s+новые\s+(?:возможности|горизонты)|\bпрокладыва\w*\s+путь"),
    ("проблемы-перспективы", r"\bfaces?\s+(?:several|numerous|many|a\s+number\s+of)\s+challenges|\bfuture\s+outlook"
                             r"|\bpaves?\s+the\s+way|\bcontinues?\s+to\s+(?:thrive|flourish)"),
    ("чат-бот", r"(?:^|\n)\s*(?:конечно|безусловно|разумеется|отличный\s+вопрос|хороший\s+вопрос|давайте\s+разбер\w*)\b[,!.:]?"),
    ("чат-бот", r"(?:^|\n)\s*(?:certainly|of\s+course|absolutely|sure)[!,.]|\bgreat\s+question\b|\blet'?s\s+dive\s+in\b"),
    ("чат-бот", r"\bнадеюсь,\s+(?:это|эта|мой|я)\s+(?:помог|был|было|информац)|\b(?:дайте|сообщите)\s+(?:мне\s+)?знать"
                r"|\bсообщите\s+мне\b|\bесли\s+(?:у\s+вас\s+)?(?:возникнут|появятся|будут|остались)\s+(?:ещё\s+|еще\s+)?вопросы"
                r"|\bвы\s+(?:абсолютно|совершенно)\s+правы|\bне\s+стесняйтесь|\bболее\s+подробн\w*\s+анализ"),
    ("чат-бот", r"\bi\s+hope\s+this\s+helps|\blet\s+me\s+know\s+if|\bfeel\s+free\s+to|\byou'?re\s+absolutely\s+right"
                r"|\bhappy\s+to\s+help\b"),
    ("дисклеймер", r"\bна\s+момент\s+(?:моего\s+)?(?:обучения|последнего\s+обновления)|\bмо(?:ё|е|его|им)\s+последн\w*\s+обновлени"
                   r"|\bкак\s+(?:языковая\s+модель|ии\b|искусственный\s+интеллект)|\b(?:информаци|сведени|данн)\w*\s+(?:ограничен|скудн|немного)"
                   r"|\bне\s+(?:широко\s+)?задокументирован\w*(?:\s+широко)?|\bв\s+(?:предоставленных|доступных|имеющихся)\s+"
                   r"(?:источниках|результатах)|\bна\s+основе\s+(?:имеющейся|доступной)\s+информации|\bниже\s+представлен"),
    ("дисклеймер", r"\bas\s+of\s+my\s+(?:last|latest|knowledge)|\bas\s+an\s+ai\b|\bbased\s+on\s+(?:the\s+)?available\s+information"
                   r"|\blimited\s+information\s+(?:is\s+)?available|\bhere'?s\s+a\s+(?:comprehensive|detailed)\s+overview"),
    ("обтекаемо", r"\b(?:эксперты|специалисты|аналитики|критики|исследователи)\s+(?:считают|отмечают|утверждают|полагают|сходятся)"
                  r"|\bпо\s+(?:словам|мнению)\s+экспертов|\bотраслев\w*\s+(?:отч[её]т|исследовани)|\bнекоторые\s+(?:критики|эксперты)"
                  r"|\bшироко\s+признан|\bописыва\w*\s+как\b"),
    ("обтекаемо", r"\bexperts\s+(?:say|believe|agree|note)|\bindustry\s+reports|\bsome\s+critics|\bwidely\s+(?:regarded|considered)"
                  r"|\bis\s+described\s+as"),
    ("не только… но и", r"\bне\s+только\b[^.!?\n]{0,150}\bно\s+и\b|\b(?:это|речь\s+ид[её]т|дело)\s+не\s+(?:просто|только)\b"
                        r"|\bне\s+просто\b[^.!?\n]{0,60}[,—–-]\s*(?:а|это)\b"),
    ("не только… но и", r"\bnot\s+only\b[^.!?\n]{0,150}\bbut\s+also\b|\bit'?s\s+not\s+(?:just|only|merely)\b[^.!?\n]{0,80}\bit'?s\b"
                        r"|\bit'?s\s+not\s+about\b[^.!?\n]{0,80}\bit'?s\s+about"),
    ("письмо-шаблон", r"застанет\s+вас\s+в\s+добром\s+здравии|\bя\s+пишу,\s+чтобы|\bhope\s+this\s+(?:e-?mail|message)\s+finds\s+you"
                      r"|\bi\s+am\s+writing\s+to\b"),
    ("канцелярит", r"\bосуществл\w*|\bв\s+рамках\s+данн|\bданн(?:ый|ая|ое|ого|ому|ой|ую|ом)\b|\bв\s+целях\b|\bна\s+сегодняшний\s+день"
                   r"|\bявля\w*\s+неотъемлем|\bв\s+настоящий\s+момент\s+времени"),
    ("слова нейросети", r"\b(?:delv(?:e|es|ed|ing)|tapestry|multifaceted|holistic|synergy|utiliz(?:e|es|ed|ing)|leverag(?:e|es|ed|ing)"
                        r"|facilitat(?:e|es|ed|ing)|embark(?:s|ed|ing)?|realm|meticulous(?:ly)?|intricate)\b"
                        r"|\bnavigat\w*\s+the\s+complexit|\bthe\s+\w+\s+landscape\b"),
    ("UTM-метка", r"utm_source=(?:openai|chatgpt)"),
    ("заглушка", r"\[(?:имя|название|укажите|опишите|вставьте|ваш|ваше|name|insert|your|describe|placeholder)[^\]\n]{0,60}\]"),
    ("жирный заголовок пункта", r"(?m)^\s*(?:[-*•]|\d+[.)])\s+\*\*[^*\n]+\*\*|^\s*\*\*\d+[.)]|\*\*[^*\n]{1,60}:\*\*"),
    ("курсивный подзаголовок", r"(?m)^\s*(?:\*(?!\*)[^*\n]{2,60}\*|_[^_\n]{2,60}_)(?=[\s:(]|$)"),
    ("разделитель ---", r"(?m)^\s*(?:-{3,}|\*{3,}|_{3,})\s*$"),
    ("термин — пояснение в списке", r"(?m)^\s*(?:[-*•]|\d+[.)])\s+[^\n—]{0,60}\s—\s"),
    ("эмодзи", "[\U0001F300-\U0001FAFF☀-⛿✅✔✨❌⭐➡]"),
    # одиночный "!" не маркер: по Graphite AI Tells люди ставят его в 100 с лишним раз чаще моделей
    ("пафос", r"!{2,}|(?:^|\n)\s*(?:и\s+вот\s+главное|самое\s+интересное|вот\s+в\s+ч[её]м\s+фишка)\b"),
]
MARKERS += [
    ("вступление-штамп", S + r"\s*(?:в\s+современном\s+мире|в\s+наши\s+дни|в\s+эпоху\s+цифров|не\s+секрет,\s+что|ни\s+для\s+кого\s+не\s+секрет"
                         r"|как\s+известно|трудно\s+переоценить|представьте\s+(?:себе|мир)|давайте\s+(?:подумаем|рассмотрим)"
                         r"|разобь[еe]м\s+задачу|для\s+начала\s+рассмотрим|нельзя\s+не\s+отметить|хочется\s+отметить)"),
    ("вступление-штамп", r"\bin\s+today'?s\s+(?:fast-paced|digital|ever)|\bin\s+an\s+era\s+where|\bimagine\s+a\s+world"
                         r"|\blet'?s\s+(?:break\s+(?:this|it)\s+down|unpack|explore)|\bstep\s+by\s+step\b|\bever-evolving"),
    ("штамп", r"\bшироки\w*\s+спектр|\bкомплексн\w*\s+(?:подход|решени)|\bиндивидуальн\w*\s+подход|\bкоманд\w*\s+профессионалов"
              r"|\bна\s+новый\s+уровень|\bраскры\w*\s+потенциал|\bкраеугольн|\bиз\s+коробки|\bвстречайте\b|\bмощн\w*\s+инструмент"
              r"|\bнезабываем|\bзаставляет\s+задуматься|\bстал\w*\s+символом|\bстал\w*\s+настоящ\w*\s+открыти|\bзаслуживает\s+внимания"
              r"|\bчто\s+делает\s+(?:его|ее|их|это)\b|\b(?:важн|значим|смел)\w*\s+шаг"),
    ("штамп", r"\bit\s+just\s+works|\bzero[- ]config|\bbatteries\s+included|\bout[-\s‐‑–]+of[-\s‐‑–]+the[-\s‐‑–]+box\b|\bmeet\s+[A-Z]\w+,"
              r"|\bthought\s+leader|\bactionable|\bimpactful|\blearnings\b|\btreasure\s+trove|\bstate-of-the-art|\bgroundbreaking"),
    ("пустой прогноз", r"\bвремя\s+покажет|\bбудущее\s+за\b|\bодно\s+можно\s+сказать\s+точно|\bимеет\s+все\s+шансы"
                       r"|\bonly\s+time\s+will\s+tell|\bthe\s+future\s+looks\s+bright|\bone\s+thing\s+is\s+certain|\bis\s+poised\s+to"),
    ("показная честность", r"\bбуду\s+чест|\bскажу\s+прямо|\bдавайте\s+начистоту|\bне\s+буду\s+скрывать|\bчестн\w*\s+оговорк"
                           r"|(?:^|\n)\s*честно\?|\bбез\s+прикрас|\bi'?ll\s+be\s+honest|\bto\s+be\s+(?:fully\s+)?transparent"
                           r"|\bhonest\s+caveat|\bi\s+want\s+to\s+be\s+upfront"),
    ("постановка", r"\bно\s+есть\s+нюанс|(?:^|\n)\s*(?:итог|результат)\?|\bспойлер:|\bсюжетный\s+поворот|\bзадумайтесь\s+об\s+этом"
                   r"|\bоб\s+этом\s+почему-то\s+молчат|\bвот\s+здесь\s+начинается|\bсамое\s+интересное"
                   r"|\bhere'?s\s+the\s+(?:thing|catch|kicker|twist)|\bthe\s+catch\?|\bplot\s+twist|\blet\s+that\s+sink\s+in"
                   r"|\bread\s+that\s+again|\bfull\s+stop\b|\bmake\s+no\s+mistake|\bsmoking\s+gun"),
    ("псевдоглубина", r"\bпо\s+(?:своей\s+)?сути\b|\bсуть\s+в\s+том|\bглавный\s+вопрос\s+в\s+том|\bправда\s+в\s+том|\bесли\s+копнуть"
                      r"|\bat\s+its\s+core\b|\bthe\s+real\s+question\b|\bwhat\s+really\s+matters"),
    ("спор с никем", S + r"\s*чтобы\s+было\s+понятно,|\bя\s+не\s+говорю,\s+что|\bне\s+поймите\s+неправильно|\bнаивн\w*\s+подход"
                     r"|\bto\s+be\s+clear,|\bdon'?t\s+get\s+me\s+wrong|\bone\s+might\s+be\s+tempted"),
    ("служба поддержки", r"\bприношу\s+извинения|\bблагодар\w*\s+за\s+уделенное|\bуверяю\s+вас|\bпонимаю\s+ваше\s+беспокойство"
                         r"|\bв\s+дальнейшем\s+я\s+буду|\bбуду\s+признател|\bс\s+радостью\s+помогу|\bконструктивн\w*\s+диалог"
                         r"|\bapologi[sz]e\s+for\s+any\s+inconvenience|\bthank\s+you\s+for\s+your\s+time|\bi\s+assure\s+you"
                         r"|\bi\s+understand\s+your\s+concern|\bgoing\s+forward,|\bi'?m\s+happy\s+to\b|\blook\s+forward\s+to\s+collaborating"),
    ("псевдотерапия", r"\bи\s+это\s+нормально|\bвы\s+не\s+одиноки|\bпозвольте\s+себе|\bэто\s+не\s+слабость|\byou'?re\s+not\s+alone"
                      r"|\bit'?s\s+completely\s+understandable"),
    ("обертка ответа", r"(?:^|\n)\s*(?:вот\s+(?:обновленн\w*\s+|новый\s+)?(?:вариант|версия|черновик)\w*|ниже\s+несколько\s+вариантов"
                       r"|хотите,\s+я\b|могу\s+также\s+подготовить|here'?s\s+the\s+updated|here\s+is\s+a\s+draft|below\s+are)"),
    ("след чат-инструмента", r"cite(?:turn|\[)|turn\d+(?:search|image|file)\d+|contentReference\[|oaicite|oai_citation|【\d+[:†]"
                             r"|\[cite:\s*\d+\]|start_span|sandbox:/mnt/data|\[attached_file:|grok_card|</?think>|:::writing\{"
                             r"|utm_source=(?:claude|perplexity|copilot)|referrer=grok"),
    ("канцелярит", r"\b(?:провод(?:ит|ят|ить|ил|ила|или|им|ите|ится|ятся)|провед[её]\w*|провел\w*)\s+работ[уыа]?\b|\bоказ\w*\s+(?:помощь|влияние|содействие)|\bприн\w*\s+участие|\bпроизв\w*\s+(?:оценк|расч[её]т|настройк)"
                   r"|\bимеет\s+место|\bпосредством\b|\bв\s+свете\b|\bв\s+плане\s+\w+ени|\bбыло\s+принято\s+решение"
                   r"|\bпредставляет\s+собой|\bвыступа\w*\s+в\s+(?:качестве|роли)"),
    ("связка-пышный глагол", r"\b(?:serves|functions|acts)\s+as\b|(?:^|[.!?]\s+)это\s+(?:позволяет|помогает|дает|создает)"),
    ("модальная вата", r"\bпотенциально\s+может|\bможет\s+привести\s+к|\bспособ\w*\s+обеспечить|\bпризван\w*\s+(?:решить|обеспечить)"
                       r"|\bcould\s+potentially|\bmay\s+eventually|\bmight\s+arguably|\bremains\s+to\s+be\s+seen"),
    ("усилитель", r"\bпо-настоящему|\bпоистине|\bневероятн|\b(?:genuinely|truly|remarkably|arguably|fundamentally)\b"),
    ("слова нейросети", r"\b(?:garner\w*|bolster\w*|interplay|robust|comprehensive|streamlin\w*|paradigm|spearhead\w*"
                        r"|myriad|plethora|commendable|noteworthy|invaluable|quintessential|burgeoning|nascent|load-bearing"
                        r"|align(?:s|ed)?\s+with|valuable\s+insights|shed\w*\s+light)\b"),
    ("переход-шаблон", S + r"\s*(?:кроме\s+того|более\s+того|помимо\s+этого|к\s+тому\s+же|moreover|furthermore|additionally|that\s+being\s+said"
                       r"|notably|interestingly|importantly)\b"),
    ("история правки в тексте", r"\b(?:was\s+added\s+to\s+replace|previously\s+used)|\bбыл\w*\s+добавлен\w*,?\s+чтобы\s+заменить"),
    ("символы вместо слов", r"\s(?:→|->|=>|≈|⇒|←|↔)\s|≠"),
]
# Пополнение 2026-11: Graphite "AI Tells", хайлайтер Simon Willison, новые разделы WP:AISIGNS
MARKERS += [
    ("обещание без цены", r"\bне\s+жертвуя\b|\bбез\s+ущерба\s+для\b|\bбез\s+потери\s+(?:качества|скорости|производительности"
                          r"|надежности|гибкости)|\bwithout\s+(?:sacrificing|compromising)\b"
                          r"|\bwithout\s+losing\s+(?:quality|speed|performance|reliability|flexibility)"),
    ("не только… но и", r"\bless\s+like\b[^.!?\n]{0,60}\bmore\s+like\b|\brather\s+than\s+merely\b"
                        r"|\bменьше\s+похож\w*\s+на\b[^.!?\n]{0,60}\bбольше\b"),
    ("дидактика", r"\bmatters\s+(?:because|more\s+than)\b|\bэто\s+важно,\s+потому\s+что"
                  r"|\bshould\s+be\s+(?:treated|understood|read)\s+as\b[^.!?\n]{0,80}\brather\s+than"
                  r"|\bdoes\s+not\s+(?:by\s+itself\s+)?establish\b|\bshould\s+not\s+be\s+confused\s+with"
                  r"|\bне\s+следует\s+путать\s+с\b|\bследует\s+рассматривать\s+как\b[^.!?\n]{0,80}\bа\s+не\b"),
    ("переход-шаблон", S + r"\s*(?:looking\s+ahead|what\s+comes\s+next|заглядывая\s+вперед)\b|(?:^|\n)\s*что\s+дальше\?"),
    ("постановка", r"\bworth\s+naming\b|\bsit\s+with\s+(?:that|this|it)\b|\b(?:that|this)(?:'s|\s+is)\s+the\s+(?:whole|entire)"
                   r"\s+point|\bdon'?t\s+take\s+my\s+word\s+for\s+it|\bfits\s+in\s+your\s+head|\bis\s+real,\s+and\b"
                   r"|\bв\s+этом\s+(?:и\s+)?весь\s+смысл|\bпобудьте\s+с\s+этим"),
    ("показная честность", S + r"\s*(?:honestly|frankly|look),"),
    ("опора на самоописание", r"\b(?:identifies|lists)\s+(?:him|her|them|it|itself|himself|herself)\s+as\b|\bзначится\s+как\b"),
    ("инструкция в чистовике", r"\b(?:verify|check|confirm|double-check)\b[^.\n]{0,60}\bbefore\s+(?:publishing|submitting|sending)"
                               r"|\b(?:проверьте|уточните|сверьте)\b[^.\n]{0,60}\bперед\s+(?:публикацией|отправкой)"),
    ("след чат-инструмента", r"</?mark>|attributableIndex"),
    ("заглушка", r"\b(?:INSERT|PASTE)_[A-Z0-9_]+|\bexample\.com/(?:source|article|news)\d*|\b20\d\d-XX-XX\b"),
    # "harness" у разработчиков еще и термин (test harness, Claude Code harness): ловим только "harness the power"
    # двоеточие-анонс в лог-проверках срабатывает чаще всего: "Цена одна: ...", "Откат простой: ...", "The fix is simple: ..."
    ("анонс через двоеточие", S + r"\s*[^.!?:\n]{0,40}?\b(?:одн[аио]|один|прост(?:ой|ая|ое)|так(?:ой|ая|ое|ие)"
                              r"|два|две|три)\s*:(?=[ \t]+\S)"
                              r"|\bthe\s+(?:fix|answer|reason|rule|problem|idea|catch|trick|difference|plan)\s+is\s+"
                              r"(?:simple|this|twofold|straightforward)\s*:(?=[ \t]+\S)"
                              r"|\b(?:short\s+version|bottom\s+line|the\s+upshot|net\s+effect)\s*:(?=[ \t]+\S)"),
    ("слова нейросети", r"\bharness(?:es|ed|ing)?\s+(?:the\s+|its\s+|their\s+)?(?:full\s+)?(?:power|potential|strength|capabilit)"),
]
# Пополнение 2026-11-24: WP:AISIGNS и WP:AITALKSIGNS, дополнение Graphite по Opus 5.5, Pangram, blader/humanizer,
# avoid-ai-writing, RuSlop из humanizer-ru, avoid-ai-writing-russian, unslop-ui
MARKERS += [
    ("значимость", r"\bmaintains?\s+an?\s+(?:active\s+|strong\s+)?(?:digital|social\s+media|online)\s+presence"
                   r"|\b(?:shaped|contributed\s+to|prompted)\s+(?:the\s+)?(?:wider\s+|broader\s+|public\s+|ongoing\s+)?"
                   r"(?:conversations?|discussions?|debates?|reflection)\s+(?:about|on|around)\b"
                   r"|\bforms?\s+part\s+of\s+(?:the|a)\s+(?:wider|broader)\b|\badds?\s+(?:another|a\s+new|an\s+extra)\s+layer\s+of\s+"
                   r"(?:complexity|depth|meaning|nuance|intrigue)"),
    ("опора на самоописание", r"\b(?:biography|profile)\s+(?:records|lists|notes)\s+(?:that|him|her|them)\b"),
    ("дидактика", r"\bshould\s+be\s+distinguished\s+from\b|\bjust\s+as\s+important\b|\bmatters\s+most\b"
                  r"|" + S + r"\s*(?:this\s+matters|это\s+важно)[.!]|\bстоит\s+напомнить,?\s+что\b|" + S + r"\s*напомним,\s+что\b"),
    ("не только… но и", r"\bis\s+more\s+than\s+(?:a|an|just)\s+[^.!?\n]{1,40}?[,;]\s*it(?:'s|\s+is)\b|\bбольше,?\s+чем\s+просто\b"),
    ("постановка", r"\bthe\s+(?:hard|tricky|interesting|fun)\s+part\s+(?:is|was)\b|\bthe\s+part\s+worth\s+\w+ing\b"
                   r"|\bhere'?s\s+(?:the\s+interesting\s+part|what'?s\s+interesting)|\bсекрет\s+прост|\bмало\s+кто\s+знает"
                   r"|\bнастоящая\s+история\s+(?:была|в\s+том|оказалась)"),
    ("усилитель", r"\bperhaps\s+the\s+most\b|\bпожалуй,?\s+(?:самы[йе]|самая|самое)\b"),
    ("спор с никем", r"\b(?:кто-то|скептики)\s+(?:возразит|возразят|скажет|скажут)\b|\bsome\s+might\s+argue\b"),
    ("пустой прогноз", r"\bвопрос\s+оста[её]тся\s+открытым|\bперспективы\s+выглядят\s+многообещающ|\bвпереди\s+(?:ещ[её]\s+)?много\s+интересного"
                       r"|\bбудущее\s+уже\s+(?:здесь|наступило)"),
    ("служба поддержки", r"\bрады\s+(?:сообщить|представить|объявить)\b|\bс\s+гордостью\s+(?:представляем|сообщаем)"
                         r"|\bнадеемся\s+на\s+(?:ваше\s+)?понимание|\bблагодарим\s+за\s+(?:понимание|внимание)|\bспасибо,\s+что\s+вы\s+с\s+нами"
                         r"|\bхочу\s+уточнить,\s+что|\bi\s+would\s+like\s+to\s+clarify\b|\bi\s+understand\s+the\s+importance\s+of"
                         r"|\bmaintaining\s+the\s+integrity\s+of|\bwe'?re\s+excited\s+to\s+announce"),
    ("чат-бот", r"\bесли\s+(?:хотите|хочешь),\s+(?:я\s+)?могу\b"),
    ("калька", r"\bна\s+ежедневной\s+основе|\bпогруз\w*\s+в\s+мир\b"),
    ("пересказ интерфейса", r"\bclick\s+the\s+button\s+below\b|\bthis\s+chart\s+shows\b|\beach\s+bar\s+represents\b"
                            r"|\bнажмите\s+(?:на\s+)?кнопку\s+ниже\b|\bна\s+этом\s+графике\s+показан"),
    ("заглушка", r"\bevidence\s+to\s+be\s+supplied:|(?:^|\n)[ \t]*\*?\((?:~\s*|около\s+|примерно\s+)?\d+\s*(?:знак|символ|слов|words?\b"
                 r"|characters?\b)[^)\n]{0,60}\)\*?[ \t]*(?=\n|$)"),
    ("след чат-инструмента", r"\[cite_start\]|grounding-api-redirect|ppl-ai-file-upload|\[web:\d+\]|<grok-card"
                             r"|grok_render_citation_card|\[citation:\d+\]|\[\^\d+\^\]|<cite\s+index=|\b(?:writing|écriture)\{varian"),
    ("псевдографика", r"[─-╿]"),
]
# URL с такими частями оставляем в тексте: это следы чат-инструментов, а не обычные ссылки
TOOL_URL = re.compile(r"utm_source|grounding-api-redirect|ppl-ai-file-upload")
COMPILED = [(name, re.compile(rx, re.I)) for name, rx in MARKERS]
# невидимые и редкие символы; редкие пробелы и минус (U+202F, U+2002-U+200A, U+205F, U+2212, U+2012, U+2015) по замеру
# avoid-ai-writing-russian есть в 16-26% ответов o3 и в 2% текстов людей
INVISIBLE = re.compile("[\u200b-\u200d\u2060\u00ad\u2010\u2011\u200e\u200f\u202a-\u202e\u2066-\u2069"
                       "\u202f\u2002-\u200a\u205f\u2212\u2012\u2015\u061c\u180e"
                       "\ue200-\ue204\uea01\uea02\U000e0000-\U000e007f]|(?<!^)\ufeff")
NBSP_LIMIT = 3  # обычный неразрывный пробел люди ставят часто: отмечаем, только когда их много
MERISM = re.compile(r"\bот\s+([^\d.!?,;:\n]{2,40}?)\s+до\s+([^\d.!?,;:\n]{2,40}?)(?=[,.;!?\n]|$)", re.I)
# по логу проверок почти все "от… до…" были настоящими диапазонами: время и количество словами ("от нескольких
# часов до суток"), путь ("от Mac до сервера"), имена и идентификаторы латиницей, "от начала до конца"
MERISM_RANGE = re.compile(r"[A-Za-z\"]|\b(?:одн\w{1,3}|дв(?:а|е|ух)|тр(?:и|ех|ёх)|четыр\w*|пят[иь]\w*|шест[иь]\w*|сем[иь]"
                          r"|восьм\w*|девят\w*|десят\w*|нескольк\w*|пар[ыу]|сотн\w*|тысяч\w*|секунд\w*|минут\w*|час(?:а|ов)?"
                          r"|дн(?:я|ей)|сут(?:ок|ки)|недел\w*|месяц\w*|лет|года?|начала|конца|старта)\b", re.I)
# служебные слова в начале фраз повторяются и у людей ("The… The… The…", "На… На… На…")
FUNCTION_STARTS = {"the", "a", "an", "in", "on", "at", "to", "for", "it", "this", "и", "в", "во", "на", "с", "по", "у", "к",
                   "о", "из", "за", "а", "но", "это"}


def missing_hooks():
    try:
        return [r[0] for r in claude_settings.missing(claude_settings.load(), HOOK_ROWS)]
    except ValueError:
        return [r[0] for r in HOOK_ROWS]


def install_hooks():
    """Подключает хуки humanize и /humanize, если их нет; остальное в settings.json не трогает."""
    try:
        data = claude_settings.load()
        added = claude_settings.add_missing_hooks(data, HOOK_ROWS)
    except ValueError as e:
        print(tr(f"✗ {tilde(SETTINGS)} не читается как JSON ({e}), хуки не подключил",
                 f"✗ {tilde(SETTINGS)} is not valid JSON ({e}), hooks not added"))
        return False
    if added:
        claude_settings.save_atomic(data)
        print(tr(f"✓ подключил хуки {', '.join(added)} в {tilde(SETTINGS)}",
                 f"✓ added hooks {', '.join(added)} to {tilde(SETTINGS)}"))
    if not os.path.exists(SLASH_FILE):
        from slash import EXTRA_SLASH
        os.makedirs(os.path.dirname(SLASH_FILE), exist_ok=True)
        with open(SLASH_FILE, "w") as f:
            f.write(EXTRA_SLASH["humanize"])
        print(f"✓ /humanize → {tilde(SLASH_FILE)}")
    return True


def enabled():
    return read_config().get("humanize", "off") == "on"


def sync_badge(on):
    """Метка humanize во второй строке promptsill, пока режим включен."""
    badge("mnrh-humanize", {"text": "humanize", "color": "green"} if on else None)


def typography():
    """Строгая типографика из humanize-typography.md: humanize_typography=on в config, по умолчанию выключена.
    MNRH_HUMANIZE_TYPOGRAPHY=on|off перекрывает config (для проверок в Makefile)."""
    forced = os.environ.get("MNRH_HUMANIZE_TYPOGRAPHY")
    if forced in ("on", "off"):
        return forced == "on"
    return read_config().get("humanize_typography", "off") == "on"


def reminder():
    if not typography():
        return REMINDER
    head, sep, tail = REMINDER.partition(" Текст, который")
    return head + TYPOGRAPHY_REMINDER + sep + tail


def rules_text():
    try:
        with open(RULES) as f:
            text = f.read()
    except OSError:
        return ""
    if typography():
        try:
            with open(TYPOGRAPHY) as f:
                text = text.rstrip("\n") + "\n" + f.read()
        except OSError:
            pass
    return text


def log(line):
    try:
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + line + "\n")
    except OSError:
        pass


def mark(sid, name, value=None):
    if not sid or not UUID_RE.match(sid):
        return None
    path = os.path.join(STATE, f"{sid}.{name}")
    if value is None:
        return path
    try:
        if value is False:
            os.remove(path)
        else:
            os.makedirs(STATE, exist_ok=True)
            with open(path, "w") as f:
                f.write(value)
    except OSError:
        pass
    return path


def read_mark(sid, name):
    path = mark(sid, name)
    try:
        with open(path) as f:
            return f.read()
    except (OSError, TypeError):
        return None


def prose(text):
    """Текст без кода, цитат и строк вывода: их правила не касаются."""
    text = re.sub(r"(?ms)^\s*(```|~~~).*?^\s*\1[^\n]*$", "", text)
    text = re.sub(r"`[^`\n]*`", "", text)
    text = re.sub(r"(?m)^\s*>.*$", "", text)
    text = re.sub(r"(?m)^.*🤖 Generated with \[?Claude Code.*$", "", text)  # подпись PR, которую требует Claude Code
    text = re.sub(r"«[^»\n]{0,160}»|“[^”\n]{0,160}”|„[^“”\n]{0,160}[“”]|\"[^\"\n]{0,160}\"", '""', text)
    return re.sub(r"https?://\S+", lambda m: m.group(0) if TOOL_URL.search(m.group(0)) else "", text)


def is_english(paragraph):
    latin = len(re.findall(r"[A-Za-z]", paragraph))
    cyr = len(re.findall(r"[А-Яа-яЁё]", paragraph))
    return latin > 3 * max(cyr, 1)


def check(text):
    """[(номер строки, правило, фрагмент)] по явным маркерам."""
    clean = prose(text)
    hits = []
    raw = re.sub(r"`[^`\n]*`", "", re.sub(r"(?ms)^\s*(```|~~~).*?^\s*\1[^\n]*$", "", text))
    strict = typography()
    rules = ((("елочки и лапки", r"[«»„“”]"), ("буква е с точками", r"[ёЁ]"), ("типографский апостроф", r"[’‘]"))
             if strict else ()) + (("невидимые и редкие символы", INVISIBLE.pattern),)
    for name, rx in rules:
        found = [m.start() for m in re.finditer(rx, raw)]
        if found:
            hits.append((raw.count("\n", 0, found[0]) + 1, name, f"{len(found)} шт."))
    nbsp = [m.start() for m in re.finditer("\u00a0", raw)]
    if len(nbsp) >= NBSP_LIMIT:
        hits.append((raw.count("\n", 0, nbsp[0]) + 1, "неразрывные пробелы", f"{len(nbsp)} шт., человек столько не ставит"))
    colons = [m.start() for m in re.finditer(r"[^\s:/\d]:(?=[ \t]+\S)", clean)]
    if strict and len(colons) > 1:
        hits.append((clean.count("\n", 0, colons[0]) + 1, "двоеточия", f"{len(colons)} посреди фраз"))

    def line_of(pos):
        return clean.count("\n", 0, pos) + 1

    for name, rx in COMPILED:
        for m in rx.finditer(clean):
            frag = m.group(0).strip()
            lead = len(m.group(0)) - len(m.group(0).lstrip())
            hits.append((line_of(m.start() + lead), name, frag or m.group(0)))
    for m in MERISM.finditer(clean):
        if MERISM_RANGE.search(m.group(1)) or MERISM_RANGE.search(m.group(2)):
            continue
        hits.append((line_of(m.start()), "от… до…", m.group(0)))
    pos = 0
    for para in re.split(r"\n\s*\n", clean):
        start = clean.find(para, pos)
        pos = start + len(para)
        n = para.count("—")
        if n and is_english(para):
            hits.append((line_of(start), "тире в английском", f"{n} шт."))
        elif n > 1:
            hits.append((line_of(start), "много тире", f"{n} в абзаце"))
        for hm in re.finditer(r"(?m)^\s*(?:#{1,6}\s+|\*\*)([^\n*#]+?)(?:\*\*)?\s*$", para):
            words = re.findall(r"[A-Za-zА-Яа-яЁё][\wЁё'-]*", hm.group(1))
            if len(words) >= 3 and all(w[0].isupper() for w in words) and not hm.group(1).isupper():
                hits.append((line_of(start + hm.start()), "Заглавные Буквы", hm.group(1).strip()))
    starts = [m.group(1).lower() for m in re.finditer(r"(?:^|[.!?]\s+)([A-Za-zА-Яа-яЁё][\wЁё-]*)", clean)]
    for i in range(len(starts) - 2):
        if starts[i] == starts[i + 1] == starts[i + 2] and len(starts[i]) > 1 and starts[i] not in FUNCTION_STARTS:
            hits.append((1, "одинаковое начало трех фраз", starts[i]))
            break
    bold = len(re.findall(r"\*\*[^*\n]+\*\*", clean))
    if bold > 2:
        hits.append((1, "много жирного", f"{bold} выделений"))
    return sorted(set(hits))


def last_reply(path):
    """Текст последнего ответа Claude в транскрипте: всё после последнего сообщения пользователя."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - (8 << 20)))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return ""
    parts = []
    for raw in reversed(lines):
        try:
            e = json.loads(raw)
        except ValueError:
            continue
        msg = e.get("message") or {}
        content = msg.get("content")
        if e.get("type") == "user" and not e.get("isMeta"):
            if isinstance(content, str) or (isinstance(content, list) and
                                            any(c.get("type") == "text" for c in content if isinstance(c, dict))):
                break
        if e.get("type") == "assistant" and isinstance(content, list) and not e.get("isSidechain"):
            parts += [c.get("text", "") for c in reversed(content) if isinstance(c, dict) and c.get("type") == "text"]
    return "\n\n".join(reversed(parts))


def emit(event, context):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": context}},
                     ensure_ascii=False))


def hook(codex=False):
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0
    sid, event = payload.get("session_id"), payload.get("hook_event_name")
    on = enabled()
    if event == "SessionStart":
        sync_badge(on)
        mark(sid, "primed", False)
        if on and rules_text():
            emit(event, rules_text())
            mark(sid, "primed", "1")
    elif event == "UserPromptSubmit":
        primed = read_mark(sid, "primed") is not None
        hits = read_mark(sid, "hits")
        mark(sid, "hits", False)
        if on:
            text = reminder() if primed else rules_text()
            if hits and primed:
                text += f"\nВ прошлом ответе проверка нашла: {hits}. Не повторяй этого."
            if text:
                emit(event, text)
                mark(sid, "primed", "1")
        elif primed:
            emit(event, OFF_NOTE)
            mark(sid, "primed", False)
    elif event == "Stop" and on:
        reply = payload.get("last_assistant_message")
        if not reply and not codex and payload.get("transcript_path"):
            reply = last_reply(payload["transcript_path"])
        found = check(reply or "")
        if found:
            short = "; ".join(f"{name} («{frag[:40]}»)" for _, name, frag in found[:6])
            mark(sid, "hits", short)
            log(f"{sid[:8] if sid else '?'} {len(found)}: {short}")
    return 0


def current_sid():
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if sid:
        return sid
    pid = os.environ.get("CLAUDE_PID")
    try:
        with open(os.path.join(CLAUDE_HOME, "sessions", f"{pid}.json")) as f:
            return json.load(f).get("sessionId")
    except (OSError, ValueError, TypeError):
        return None


def set_state(value, inside):
    write_config(humanize=value)
    sync_badge(value == "on")
    sid = current_sid() if inside else None
    if value == "on":
        install_hooks()
        print(tr("agentmeister humanization включена.", "agentmeister humanization is on."))
        if inside and rules_text():
            print(tr("Правила ниже действуют в этой сессии с этого ответа:\n",
                     "The rules below apply in this session from this reply on:\n"))
            print(rules_text())
            mark(sid, "primed", "1")
        else:
            print(tr("В сессиях Claude Code и Codex с подключенными хуками правила придут со следующим сообщением.",
                     "Claude Code and Codex sessions with the hooks get the rules with the next message."))
    else:
        print(tr("agentmeister humanization выключена. Правила письма больше не обязательны.",
                 "agentmeister humanization is off. The writing rules no longer apply."))
        mark(sid, "primed", False)


def usage():
    if lang() == "en":
        print("agentmeister humanize                  status")
        print("agentmeister humanize on | off         turn the mode on or off for Claude Code and Codex")
        print("agentmeister humanize switch [on|off]  the same for /humanize in Claude Code")
        print("agentmeister humanize rules            show the writing rules")
        print("agentmeister humanize typography on|off  strict typography: straight quotes, no dotted e, no colons")
        print("agentmeister humanize check <file>     find obvious AI tells in a text (- reads stdin)")
        print("agentmeister humanize log              show reply check results")
        print()
        print("The rules come from the Wikipedia essay \"Signs of AI writing\" (WP:AISIGNS). The SessionStart hook passes")
        print("them at session start and after context compaction, UserPromptSubmit reminds of them with each message,")
        print("Stop checks the reply and tells the agent what it found in the next message.")
        print("For Codex, add the hooks with agentmeister --harness codex setup and approve them in /hooks.")
        return
    print("agentmeister humanize                  состояние")
    print("agentmeister humanize on | off         переключить режим для Claude Code и Codex")
    print("agentmeister humanize switch [on|off]  то же для /humanize в Claude Code")
    print("agentmeister humanize rules            показать правила письма")
    print("agentmeister humanize typography on|off  строгая типографика: прямые кавычки, без е с точками, без двоеточий")
    print("agentmeister humanize check <файл>     найти явные признаки нейросети в тексте (- читает stdin)")
    print("agentmeister humanize log              показать результаты проверки ответов")
    print()
    print("Правила взяты из эссе Википедии \"Признаки сгенерированности текста\" (ВП:ПРГЕН). Хук SessionStart передает")
    print("их в начале сессии и после сжатия контекста, UserPromptSubmit напоминает о них к каждому сообщению,")
    print("Stop проверяет ответ и сообщает агенту о найденном в следующем сообщении.")
    print("Для Codex подключи хуки через agentmeister --harness codex setup и подтверди их в /hooks.")


def status():
    from codex_harness import HOOK_EVENTS, configured_humanize_hooks

    print(tr(f"agentmeister humanization {'включена' if enabled() else 'выключена'}. Правила в {tilde(RULES)}",
             f"agentmeister humanization is {'on' if enabled() else 'off'}. Rules in {tilde(RULES)}"))
    missing = missing_hooks()
    if missing:
        print(tr(f"Для Claude Code не хватает хуков {', '.join(missing)}. Подключи через agentmeister humanize on.",
                 f"Claude Code is missing hooks {', '.join(missing)}. Add them with agentmeister humanize on."))
    count = configured_humanize_hooks()
    if count == len(HOOK_EVENTS):
        print(tr(f"В Codex настроено {count}/{len(HOOK_EVENTS)} хуков. Статус доверия виден в /hooks.",
                 f"Codex has {count}/{len(HOOK_EVENTS)} hooks set up. Trust status is in /hooks."))
    else:
        print(tr("Проверь установку хуков Codex через agentmeister --harness codex setup.",
                 "Check the Codex hooks with agentmeister --harness codex setup."))
    print(tr(f"Переключение через agentmeister humanize on|off. Лог проверок в {tilde(LOG)}",
             f"Switch with agentmeister humanize on|off. Check log in {tilde(LOG)}"))


def main():
    args = sys.argv[1:]
    if args[:1] == ["humanize-hook"]:
        try:
            return hook(codex=args[1:] == ["--codex"])
        except Exception as e:
            log(f"error {e!r}")
            return 0
    rest = args[1:]
    if not rest:
        status()
        return 0
    cmd = rest[0]
    if cmd in ("-h", "--help"):
        usage()
        return 0
    if cmd in ("on", "off"):
        set_state(cmd, inside=bool(os.environ.get("CLAUDECODE")))
        return 0
    if cmd == "switch":
        want = rest[1] if len(rest) > 1 else ("off" if enabled() else "on")
        if want in ("status", "?"):
            status()
            return 0
        if want not in ("on", "off"):
            print(tr(f"Не понял «{want}»: on, off или пусто, чтобы переключить.",
                     f"Unknown \"{want}\": use on, off or nothing to toggle."), file=sys.stderr)
            return 2
        set_state(want, inside=bool(os.environ.get("CLAUDECODE")))
        return 0
    if cmd == "typography" and len(rest) in (1, 2):
        if len(rest) == 2:
            if rest[1] not in ("on", "off"):
                print("agentmeister humanize typography on|off", file=sys.stderr)
                return 2
            write_config(humanize_typography=None if rest[1] == "off" else "on")
        print(tr("Строгая типографика (прямые кавычки, без е с точками, без двоеточий): ",
                 "Strict typography (straight quotes, no dotted e, no colons): ") + ("on" if typography() else "off"))
        return 0
    if cmd == "rules":
        print(rules_text(), end="")
        return 0
    if cmd == "check" and len(rest) == 2:
        try:
            text = sys.stdin.read() if rest[1] == "-" else open(rest[1], encoding="utf-8").read()
        except OSError as e:
            print(tr(f"Не прочитал {rest[1]}: {e.strerror}", f"Couldn't read {rest[1]}: {e.strerror}"), file=sys.stderr)
            return 2
        found = check(text)
        for line, name, frag in found:
            print(f"{line:>4}  {name}: {frag}")
        print(tr("Явных признаков не нашёл.", "No obvious tells found.") if not found
              else tr(f"Найдено: {len(found)}.", f"Found: {len(found)}."))
        return 1 if found else 0
    if cmd == "log":
        try:
            with open(LOG) as f:
                print("".join(f.readlines()[-30:]), end="")
        except OSError:
            print(tr("Лог пуст.", "The log is empty."))
        return 0
    usage()
    return 2


if __name__ == "__main__":
    sys.exit(main())
