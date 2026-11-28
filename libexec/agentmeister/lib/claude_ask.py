import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mnrhlib import find_project, tilde, tr

CLAUDE_BIN = os.environ.get("MNRH_CLAUDE_BIN", "claude")
TIMEOUT = 300
DEFAULT_MODEL = "sonnet"


def default_model():
    import session_defaults
    return session_defaults.ask_model()


def ask(project, question, model=None):
    question = " ".join((question or "").split())
    if not project or not question:
        return tr("Нужны проект и вопрос.", "Give a project and a question."), True
    root, err = find_project(project)
    if err:
        return err, True
    prompt = tr(f"Тебя спрашивают из другого проекта, ответ уйдёт в чужую сессию Claude. Работай только на чтение: "
                f"ничего не меняй и не запускай. Найди ответ в коде проекта {root} и ответь кратко и конкретно: "
                f"факты, пути к файлам с номерами строк, нужные куски кода. Если не нашёл — так и скажи.\n\n"
                f"Вопрос: {question}",
                f"You are asked from another project, and the answer goes to another Claude session. Read only: "
                f"change nothing and run nothing. Find the answer in the code of the project {root} and answer briefly "
                f"and to the point: facts, file paths with line numbers, the relevant code. If you didn't find it, "
                f"say so.\n\nQuestion: {question}")
    env = dict(os.environ, MNRH_CHILD="1")
    cmd = [CLAUDE_BIN, "-p", "--no-session-persistence", "--output-format", "json",
           "--model", model or default_model(), "--tools", "Read,Grep,Glob", "--allowedTools", "Read", "Grep", "Glob",
           "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
           "--", prompt]
    try:
        r = subprocess.run(cmd, cwd=root, capture_output=True, text=True, timeout=TIMEOUT, env=env,
                           stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return tr(f"Claude в {os.path.basename(root)} не ответил за {TIMEOUT // 60} мин.",
                  f"Claude in {os.path.basename(root)} didn't answer in {TIMEOUT // 60} min."), True
    except OSError as e:
        return tr(f"Не запустился claude: {e}", f"claude didn't start: {e}"), True
    try:
        data = json.loads(r.stdout)
    except ValueError:
        tail = (r.stderr or r.stdout).strip()[-800:]
        return tr(f"Claude в {os.path.basename(root)} ответил не JSON: {tail}",
                  f"Claude in {os.path.basename(root)} answered with something other than JSON: {tail}"), True
    answer = (data.get("result") or "").strip()
    if data.get("is_error") or not answer:
        why = answer or data.get('subtype') or tr('пустой ответ', 'empty answer')
        return tr(f"Claude в {os.path.basename(root)} не справился: {why}",
                  f"Claude in {os.path.basename(root)} failed: {why}"), True
    u = data.get("usage") or {}
    tokens = sum(u.get(k, 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
    return tr(f"Ответ из {os.path.basename(root)} ({tilde(root)}, {model or default_model()}, ~{tokens // 1000}k токенов):\n\n{answer}",
              f"Answer from {os.path.basename(root)} ({tilde(root)}, {model or default_model()}, ~{tokens // 1000}k tokens):\n\n{answer}"), False


TOOL = {
    "name": "ask_project",
    "description": ("Спросить про другой проект: в его папке запускается отдельный Claude только с чтением (Read, Grep, "
                    "Glob) и возвращает короткий ответ с путями и кусками кода. Контекст этой сессии не засоряется "
                    "чтением чужих файлов. Например: формат ответа эндпоинта в backend, как в другом приложении устроена "
                    "авторизация, какие поля у модели в другом репозитории. Занимает до пары минут и тратит лимит; "
                    "для своего проекта не нужен — читай файлы сам."),
    "inputSchema": {"type": "object", "properties": {
        "project": {"type": "string", "description": "имя папки проекта или путь"},
        "question": {"type": "string", "description": "вопрос, понятный без контекста этой сессии"},
        "model": {"type": "string", "description": "sonnet (по умолчанию), opus или haiku"}},
        "required": ["project", "question"]},
}


def main():
    args = sys.argv[2:] if sys.argv[1:2] == ["ask"] else sys.argv[1:]
    if len(args) < 2 or args[0] in ("-h", "--help"):
        print(tr("agentmeister ask <проект> <вопрос>   спросить отдельный Claude про другой проект (только чтение)",
                 "agentmeister ask <project> <question>   ask a separate Claude about another project (read only)"))
        print(tr("agentmeister ask <проект> <вопрос> --model opus", "agentmeister ask <project> <question> --model opus"))
        print()
        print(tr("В Claude Code: /ask <проект> <вопрос> или инструмент ask_project.",
                 "In Claude Code: /ask <project> <question> or the ask_project tool."))
        return 0 if args[:1] in (["-h"], ["--help"]) else 2
    model = None
    if "--model" in args:
        i = args.index("--model")
        model = args[i + 1] if i + 1 < len(args) else None
        args = args[:i] + args[i + 2:]
    text, bad = ask(args[0], " ".join(args[1:]), model)
    print(text)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
