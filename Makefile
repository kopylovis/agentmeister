PREFIX ?= $(HOME)/.local
BIN := $(PREFIX)/bin

.PHONY: install uninstall test

install:
	@mkdir -p "$(BIN)"
	@if [ "$$(readlink "$(BIN)/agentmeister")" = "$(CURDIR)/bin/agentmeister" ] || \
	    { [ ! -e "$(BIN)/agentmeister" ] && [ ! -L "$(BIN)/agentmeister" ]; }; then \
		ln -sfn "$(CURDIR)/bin/agentmeister" "$(BIN)/agentmeister"; \
	else echo "$(BIN)/agentmeister уже занят другой программой" >&2; exit 1; fi
	@if [ "$$(readlink "$(BIN)/claudemeister")" = "$(CURDIR)/bin/claudemeister" ]; then rm -f "$(BIN)/claudemeister"; fi
	@echo "agentmeister -> $(BIN)/agentmeister"
	@if [ "$$(readlink "$(BIN)/am")" = "$(CURDIR)/bin/agentmeister" ] || \
	    { [ ! -e "$(BIN)/am" ] && [ ! -L "$(BIN)/am" ]; }; then \
		ln -sfn "$(CURDIR)/bin/agentmeister" "$(BIN)/am" && \
		if [ "$$(readlink "$(BIN)/cm")" = "$(CURDIR)/bin/claudemeister" ]; then rm -f "$(BIN)/cm"; fi; \
	else echo "$(BIN)/am уже занят другой программой, короткое имя не поставлено"; fi

uninstall:
	@if [ "$$(readlink "$(BIN)/agentmeister")" = "$(CURDIR)/bin/agentmeister" ]; then rm -f "$(BIN)/agentmeister"; fi
	@if [ "$$(readlink "$(BIN)/claudemeister")" = "$(CURDIR)/bin/claudemeister" ]; then rm -f "$(BIN)/claudemeister"; fi
	@if [ "$$(readlink "$(BIN)/am")" = "$(CURDIR)/bin/agentmeister" ]; then rm -f "$(BIN)/am"; fi
	@if [ "$$(readlink "$(BIN)/cm")" = "$(CURDIR)/bin/claudemeister" ]; then rm -f "$(BIN)/cm"; fi
	@echo "agentmeister удален из $(BIN)"

test:
	@bash -n bin/agentmeister
	@./bin/agentmeister --version | grep -qx "$$(cat VERSION)"
	@./bin/agentmeister --harness codex --help | grep -q 'agentmeister'
	@/usr/bin/python3 -m unittest discover -s tests -q </dev/null 2>&1 | tail -1 | grep -qx OK || /usr/bin/python3 -m unittest discover -s tests </dev/null
	@bash -n libexec/agentmeister/claude.sh
	@for f in libexec/agentmeister/*.py libexec/agentmeister/lib/*.py; do /usr/bin/python3 -m py_compile "$$f" || exit 1; done
	@./bin/agentmeister --version | grep -qx "$$(cat VERSION)"
	@./bin/agentmeister help | grep -q 'agentmeister setup'
	@printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ./bin/agentmeister mcp | grep -q open_claude
	@./bin/agentmeister deps status -h >/dev/null
	@swiftc -typecheck -swift-version 5 share/agentmeister/notify/main.swift
	@./bin/agentmeister notify -h | grep -q telegram
	@./bin/agentmeister deps -h >/dev/null
	@./bin/agentmeister notify -h | grep -q "notify phone"
	@./bin/agentmeister proxy -h | grep -q mihomo
	@./bin/agentmeister -h | grep -q -- '-x | -d'
	@XDG_CONFIG_HOME=/nonexistent-cm ./bin/agentmeister proxy run -- true 2>/dev/null; test $$? -eq 2
	@XDG_CONFIG_HOME=/nonexistent-cm ./bin/agentmeister proxy >/dev/null; test $$? -eq 1
	@! XDG_CONFIG_HOME=/nonexistent-cm ./bin/agentmeister proxy configured
	@./bin/agentmeister proxy setup not-a-url </dev/null >/dev/null; test $$? -ne 0
	@./bin/agentmeister setup --country KZ --bogus 2>&1 >/dev/null | grep -q 'не знаю --bogus'
	@./bin/agentmeister setup --country KAZ 2>/dev/null; test $$? -eq 2
	@./bin/agentmeister setup -h | grep -q -- '--country'
	@./bin/agentmeister doctor -h | grep -q 'проверить установку'
	@./bin/agentmeister ps -h | grep -q restore
	@HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent-cm /usr/bin/python3 libexec/agentmeister/lib/claude_setup.py pending | grep -q '^fresh commands .*proxy promptsill$$'
	@HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent-cm /usr/bin/python3 libexec/agentmeister/lib/claude_setup.py check </dev/null | wc -c | grep -q '^ *0$$'
	@./bin/agentmeister buildlog -h | grep -q PostToolUse
	@echo junk | ./bin/agentmeister buildlog-hook | wc -c | grep -q '^ *0$$'
	@echo '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"x"}}' | ./bin/agentmeister buildlog-hook | wc -c | grep -q '^ *0$$'
	@./bin/agentmeister buildlog test tests/fixtures/gradle-failure.log | grep -q 'BUILD FAILED in'
	@./bin/agentmeister buildlog test tests/fixtures/xcodebuild-build-failure.log | grep -q "cannot find 'ItemRowView'"
	@./bin/agentmeister guard >/dev/null
	@./bin/agentmeister guard -h >/dev/null
	@./bin/agentmeister humanize -h | grep -q ПРГЕН
	@./bin/agentmeister humanize rules | grep -q 'Проверка перед отправкой'
	@printf 'Конечно! Это не только быстро, но и удобно.\n' | ./bin/agentmeister humanize check - | grep -q 'не только'
	@printf 'Сборка шла 4 минуты, теперь 50 секунд.\n' | ./bin/agentmeister humanize check - >/dev/null
	@echo junk | ./bin/agentmeister humanize-hook | wc -c | grep -q '^ *0$$'
	@printf '%s\n' '---' '- `X` — пояснение' | ./bin/agentmeister humanize check - | grep 'разделитель' | grep -q '\-\-\-'
	@printf '%s\n' '- `X` — пояснение' | ./bin/agentmeister humanize check - | grep -q 'термин — пояснение'
	@printf '%s\n' 'Еще «тест» ёж. Итог: да. Причина: нет.' | ./bin/agentmeister humanize check - | grep 'елочки' | grep -q 'шт'
	@printf '%s\n' 'Еще «тест» ёж. Итог: да. Причина: нет.' | ./bin/agentmeister humanize check - | grep 'точками' | grep -q 'шт'
	@printf '%s\n' 'Итог: да. Причина: нет.' | ./bin/agentmeister humanize check - | grep -q 'двоеточия'
	@printf '%s\n' 'В современном мире это потенциально может помочь. Буду честен, время покажет. citeturn0search0' | ./bin/agentmeister humanize check - | grep -c 'вступление-штамп\|модальная вата\|показная честность\|пустой прогноз\|след чат' | grep -q 5
	@./bin/agentmeister humanize rules | grep -q '## 7. Проверка перед отправкой'
	@cd /tmp && $(CURDIR)/bin/agentmeister guard test 'git push -f origin master' | grep -q destructive
	@$(CURDIR)/bin/agentmeister guard test 'git push origin master' | grep -q пропущу
	@$(CURDIR)/bin/agentmeister guard test 'rm -rf build' | grep -q пропущу
	@$(CURDIR)/bin/agentmeister guard test 'rm -rf ~/Documents/old' | grep -q destructive
	@$(CURDIR)/bin/agentmeister guard test 'bundle exec fastlane beta' | grep -q пропущу
	@$(CURDIR)/bin/agentmeister guard test 'cat fastlane/.env.default' | grep -q secrets-read
	@$(CURDIR)/bin/agentmeister guard test 'rm -rf ~/.ssh' | grep -q secrets-delete
	@$(CURDIR)/bin/agentmeister guard test 'security delete-generic-password -s x' | grep -q secrets-delete
	@echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | ./bin/agentmeister guard-hook | wc -c | grep -q '^ *0$$'
	@echo '{"tool_name":"Read","permission_mode":"auto","session_id":"x","tool_input":{"file_path":"/x/.env"}}' | XDG_CONFIG_HOME=/nonexistent-cm ./bin/agentmeister guard-hook | grep -q '"deny"'
	@echo '{}' | ./bin/agentmeister statusline >/dev/null
	@echo '{}' | MNRH_PROMPTSILL=/nonexistent ./bin/agentmeister statusline | grep -q promptsill
	@MNRH_PROMPTSILL=/nonexistent ./bin/agentmeister statusline -h | grep -q 'brew install kopylovis/tap/promptsill'
	@printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ./bin/agentmeister mcp | grep -q '"deps_outdated"'
	@./bin/agentmeister notify >/dev/null
	@echo junk | ./bin/agentmeister notify-hook | wc -c | grep -q '^ *0$$'
	@echo junk | ./bin/agentmeister approve-hook | wc -c | grep -q '^ *0$$'
	@echo '{"session_id":"00000000-0000-0000-0000-000000000000","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}' | XDG_CONFIG_HOME=/nonexistent-cm ./bin/agentmeister approve-hook | wc -c | grep -q '^ *0$$'
	@XDG_CONFIG_HOME=/nonexistent-cm ./bin/agentmeister notify telegram approve | grep -q 'approve on'
	@echo '{"session_id":"00000000-0000-0000-0000-000000000000","hook_event_name":"UserPromptSubmit","user_input":"x"}' | ./bin/agentmeister notify-hook | wc -c | grep -q '^ *0$$'
	@./bin/agentmeister -h >/dev/null
	@./bin/agentmeister sessions -h >/dev/null
	@./bin/agentmeister usage -h | grep -q -- '--days'
	@./bin/agentmeister usage --days x 2>/dev/null; test $$? -eq 2
	@printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ./bin/agentmeister mcp | grep -q '"usage_report"'
	@./bin/agentmeister sessions -l >/dev/null
	@./bin/agentmeister sessions search mnrh-no-such-word-zq >/dev/null
	@./bin/agentmeister sessions choose /nonexistent-cm | grep -qx new
	@./bin/agentmeister sessions -h | grep -q slim
	@./bin/agentmeister slim -h >/dev/null
	@./bin/agentmeister todo -h >/dev/null
	@./bin/agentmeister shot -h >/dev/null
	@./bin/agentmeister brief -h >/dev/null
	@./bin/agentmeister parallel -h >/dev/null
	@./bin/agentmeister ask -h >/dev/null
	@./bin/agentmeister release-notes -h >/dev/null
	@cd /tmp && $(CURDIR)/bin/agentmeister brief >/dev/null
	@printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ./bin/agentmeister mcp | grep '"todo_add"' | grep '"parallel_task"' | grep '"window_screenshot"' | grep '"ask_project"' | grep -q '"release_notes_write"'
	@printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ./bin/agentmeister mcp | grep -q '"slim"'
	@! MNRH_CLAUDE_HOME=/nonexistent-cm ./bin/agentmeister sessions slim no-such-session >/dev/null 2>&1
	@! MNRH_CLAUDE_HOME=/nonexistent-cm ./bin/agentmeister sessions show no-such-session >/dev/null
	@if command -v mnrh >/dev/null; then printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ./bin/agentmeister mcp | grep '"session_search"' | grep '"session_read"' | grep '"mac_status"' | grep -q '"free_memory"'; fi
	@printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./bin/agentmeister mcp | grep -q "\"version\": \"$$(cat VERSION)\""
	@if command -v mnrh >/dev/null; then printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"mac_status","arguments":{"parts":["ports"]}}}' | ./bin/agentmeister mcp | grep -q '"isError": false'; fi
	@./bin/agentmeister restart -h >/dev/null
	@./bin/agentmeister forget -h >/dev/null
	@echo junk | ./bin/agentmeister notice | wc -c | grep -q '^ *0$$'
	@echo junk | ./bin/agentmeister session-end | wc -c | grep -q '^ *0$$'
	@echo '{"session_id":"00000000-0000-0000-0000-000000000000"}' | ./bin/agentmeister notice | wc -c | grep -q '^ *0$$'
	@zsh -n share/agentmeister/restart.zsh
	@zsh -n share/claudemeister/restart.zsh
	@printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ./bin/agentmeister mcp | grep '"restart"' | grep -q '"forget"'
	@test -f share/agentmeister/icon.png
	@./bin/agentmeister </dev/null >/dev/null 2>&1; test $$? -eq 2
	@./bin/agentmeister open </dev/null >/dev/null 2>&1; test $$? -eq 2
	@! printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | PATH=/usr/bin:/bin ./bin/agentmeister mcp | grep -q '"mac_status"'
	@printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./bin/agentmeister mcp | grep -q '"name": "agentmeister"'
	@find libexec -name __pycache__ -type d -exec rm -rf {} +
	@echo "все проверки пройдены"
