import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from mnrhlib import has_flag, tr
import gradle_deps

args = sys.argv[1:]
if has_flag(args, "-h", "--help"):
    print(tr("agentmeister deps [status]  устаревшие зависимости в gradle/libs.versions.toml: этот проект или все",
             "agentmeister deps [status]  outdated dependencies in gradle/libs.versions.toml: this project or all"))
    print(tr("agentmeister deps <проект>  в одном проекте (имя папки или путь)",
             "agentmeister deps <name>    in one project (folder name or path)"))
    print(tr("agentmeister deps --pre     показывать и alpha, beta, rc",
             "agentmeister deps --pre     also show alpha, beta, rc"))
    print()
    print(tr("Версии сверяются с Google Maven, Maven Central и Gradle Plugin Portal (кеш 6 ч в ~/.cache/agentmeister/maven).",
             "Versions are checked against Google Maven, Maven Central and Gradle Plugin Portal (6 h cache in ~/.cache/agentmeister/maven)."))
    print(tr("Ничего не меняет. То же самое Claude видит через MCP-инструмент deps_outdated.",
             "Changes nothing. Claude sees the same report through the MCP tool deps_outdated."))
    sys.exit(0)
if args[:1] == ["status"]:
    args = args[1:]
names = [a for a in args if not a.startswith("-")]
text, err = gradle_deps.report_text(names[0] if names else None, os.getcwd(), has_flag(args, "--pre"))
print(text)
sys.exit(1 if err else 0)
