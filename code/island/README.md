# «Остров» — островок над нотчем

Нативное приложение macOS 26 (SwiftPM, без Xcode — только Command Line Tools, Swift 6.2+).
Статусы агентов Claude Code, окна по рабочим столам, нагрузка Mac, выгрузка модели LM Studio.

## Устройство

- `Sources/Island/Model/` — контракт (`Models.swift`) и `AppState.swift`. Это единственное место
  с таймерами: свёрнуто — память раз в 3 с и события; развёрнуто — 3 с / 5 с / 60 с; при
  сворачивании всё останавливается.
- `Services/`:
  - `SystemStats`, `ProcessSampler`;
  - `WindowService` — окна и что внутри. Всё приватное API собрано в `Private/SkyLight.swift`
    через `dlsym` и отключается, если символа нет;
  - `SessionStore` — сессии Claude Code из `~/.claude/sessions/<pid>.json` и состояние
    «ждёт тебя» от хука;
  - `LMStudioClient` (`/api/v0/models`);
  - `Permissions`.
- `App/PanelController.swift` — окно: пилюля на AppKit `NSGlassEffectView`, панель на SwiftUI
  только пока развёрнута. Островок прячется при зеркалировании экрана, в полноэкранных
  приложениях и по «Скрыть на час / до утра».
- `App/StatusItemController.swift` — значок в строке меню: показать, вернуть, скрыть, выключить.
- `hook/island-hook.py` — хук Claude Code: пишет только «ждёт»/«ошибка» в `~/.claude/island/waiting/`.
  Промпты и данные инструментов не сохраняет. Тесты — `python3 -I hook/test_island_hook.py`.
- `scripts/build.sh` — сборка в `~/Library/Caches/island-build`; `install.sh` — `/Applications/Остров.app`,
  LaunchAgent `local.claude-kit.island`, хук через `install_hook.py` (копия `settings.json.bak-island-*`,
  меняются только свои записи); `uninstall.sh`; `islandctl.swift` (`toggle`/`dump` без кликов).

## Окна

- `CGWindowListCopyWindowInfo` отдаёт и служебные окна, поэтому фильтров три: только приложения
  с иконкой в Dock; окна, которые лежат на каком-либо рабочем столе; проверка через
  Универсальный доступ (subrole `AXStandardWindow`/`AXDialog`).
- Окна других рабочих столов ищутся перебором id элементов (`_AXUIElementCreateWithRemoteToken`)
  в фоне, с бюджетом времени и кэшем.
- VS Code: папка и файл разбираются из заголовка окна. Safari и Chromium: вкладки — кнопки
  `AXTabButton`, адрес — поле тулбара, переключение вкладки — `AXPress`.
- Проверка без экрана: `ISLAND_RENDER_REAL=1 <бинарь> --render out.png` рисует вкладку «Окна» с
  реальными окнами и печатает строки `ROW …`. `<бинарь> --render out.png` без переменной рисует
  все вкладки на демо-данных.

Разрешение одно — Универсальный доступ. С ad-hoc подписью macOS сбрасывает его после каждой
пересборки (см. `03_ГРАБЛИ.md`, «Островок»).
