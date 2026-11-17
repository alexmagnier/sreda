# claude-local — Claude Code на локальной модели (LM Studio, 127.0.0.1:1234)

Установка и проверка — `01_ПЛАН-УСТАНОВКИ.md` в корне пакета. Здесь — устройство для того,
кто будет это чинить.

## Состав

- `bin/claude-local` — лаунчер (он же `claude-lab` через симлинк). Fail-closed: нет сервера или
  модели — Claude Code не стартует. Оба режима под `sandbox-exec`:
  - **offline** (`config/offline.sb`): сеть только `127.0.0.1:1234`; запрет AppleEvents,
    LaunchServices, буфера обмена; запись — только рабочая папка и состояние сессии;
  - **net** (`--web`, `claude-lab`): профиль генерирует `tools/guard.py sandbox-net` при каждом запуске.
    Домашняя папка закрыта, кроме рабочей и нужного сессии. Клиентские папки и секреты закрыты
    даже внутри рабочей. Веб-инструменты — свой MCP-сервер `mcp/web-tools.mjs` без зависимостей.
- `bin/local-vscode work|lab` — отдельный экземпляр VS Code (`~/Library/Application Support/claude-local-vscode/<work|lab>`)
  с одним расширением Claude Code той же версии, что закреплённый бинарь, и
  `claudeCode.claudeProcessWrapper` → `bin/claude-local-vscode` / `bin/claude-lab-vscode` (симлинки
  на лаунчер; имя выбирает режим). Обёртка выбрасывает встроенный бинарь расширения, режет
  `--model/--fallback-model/--setting-sources/--strict-mcp-config/--debug-file` и дописывает свои
  флаги после аргументов SDK.
- `tools/guard.py` — вся логика безопасности: список клиентских папок (без учёта регистра и
  NFC/NFD), проверка рабочей папки, сборка политики `.policy.json` и профиля песочницы.
- `config/` — `models.env` (модели и контекст: **только здесь**), `client-folders.list`,
  `broad-roots.list`, `skills.list`, `skills-net.list`, `CLAUDE.md` (правила для локальной
  модели), `policy-*.json` (запрещённые инструменты и пути), `offline.sb`, `mcp-*.json`, `net-allow.list`.
- `apps/` — ярлыки «Локальный Claude» и «Лаборатория Claude» (AppleScript, `install-apps.sh`).
- `install.sh` — идемпотентная установка или ремонт; `--uninstall`.

Конфиг-папки: `~/.claude-local` (офлайн и закреплённый бинарь `bin/claude`) и `~/.claude-local-net`.
Истории двух режимов никогда не пересекаются: офлайн-история — это клиентские данные.

## Тесты

| Команда | Модель | Что доказывает |
|---|---|---|
| `tests/guard.test.sh` | нет | песочницы, клиентские папки, обходы через регистр/NFD/firmlink/симлинки, файлы «отложенного исполнения» (.git/config, хуки, .vscode), обёртка VS Code |
| `tests/verify.sh --quick` | нет | нет облачного входа, fail-closed, профиль песочницы, сервер только на 127.0.0.1 |
| `tests/verify.sh [--lab]` | да | офлайн-сессия с Tool Use и **0 байт наружу** от всего дерева процессов; веб-режим не читает клиентскую папку |
| `tests/vscode-sdk-drive.py` | да | запуск ровно так, как это делает расширение VS Code (после каждого обновления расширения) |
| `tests/model-lease.test.sh` | фейковый LM Studio | переключение моделей не обрывает чат в соседнем окне |
| `tests/web-tools.test.mjs` | нет | веб-инструменты: защита от обращений в локальную сеть, разбор HTML |
| `tests/check-hashes.sh` | нет | SHA-256 весов = Hugging Face |
| `tests/bench.py`, `tests/eval/` | да | скорость; экзамен на 15 синтетических задачах |

Тесты используют собственные папки-приманки и никогда не трогают реальные клиентские папки.
