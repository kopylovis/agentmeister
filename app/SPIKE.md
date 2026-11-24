# Спайк SwiftTerm

Окно SwiftUI с вкладками на [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). В каждой вкладке
`agentmeister <проект> -n -x` запускает агента так же, как во вкладке iTerm2, вместе с mihomo и sandbox-exec.
Задача спайка в том, чтобы понять, выдержит ли SwiftTerm Claude Code и Codex в ежедневной работе, прежде чем
строить на нем приложение.

## Запуск

Собирать и запускать из обычного терминала. В proxy-сессии SwiftPM падает с
`sandbox_apply: Operation not permitted`, у него своя песочница macOS.

```sh
cd ~/Developer/agentmeister/app
swift run AgentmeisterSpike                  # agentmeister через proxy
swift run AgentmeisterSpike kcalm            # другой проект
swift run AgentmeisterSpike --direct         # напрямую
swift run AgentmeisterSpike --codex          # Codex
swift run AgentmeisterSpike -- --resume      # аргументы после -- уходят агенту
```

⌘T открывает еще одну вкладку с тем же запуском, ⌘W закрывает, ⌘1…⌘9 переключают, ⌘⇧R запускает заново
вкладку, где процесс завершился.

Вкладка получает `TERM=xterm-256color`, `COLORTERM=truecolor` и `TERM_PROGRAM=Agentmeister`. Переменные proxy,
iTerm2 и Claude Code из окружения, откуда запустили спайк, убираются. `MNRH_ICONS=images` включает картинки
OSC 1337 в меню agentmeister, потому что `menu.py` пока узнает только iTerm2 и WezTerm.

## Что проверить

Отметь, что работает, и запиши, что нет.

- [ ] Меню agentmeister рисуется, стрелки и Enter работают, иконки видны картинками, а не emoji.
- [ ] Claude Code открывается, ввод не теряет символы, кириллица и emoji не ломают ширину строк.
- [ ] Shift+Enter переносит строку, вставка длинного текста и картинки (Ctrl+V) доходит до агента.
- [ ] Длинный ответ и вывод сборки прокручиваются без рывков, процессор не уходит в 100%.
- [ ] Строка promptsill цветная, ⌘-клик по "прокси KZ" и ветке открывает ссылку.
- [ ] Заголовок вкладки меняется вместе с заголовком, который ставит агент.
- [ ] Изменение размера окна не ломает экран Claude Code.
- [ ] Codex (`--codex`) рисуется так же хорошо.
- [ ] Неделя работы в спайке без желания вернуться в iTerm2.

## Чего в спайке нет

`/restart` не сможет найти вкладку, он знает только Terminal и iTerm2. Уведомления по клику не переводят во
вкладку спайка. Нет боковой панели, настроек, стекла и тем. Все это задачи приложения, если спайк пройдет.
