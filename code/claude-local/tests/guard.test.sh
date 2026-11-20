#!/bin/zsh
# Regression tests for tools/guard.py and the launcher guards (adversarial review 2026-11-16:
# C4 resume-by-path, C6 firmlink/case cwd bypass, C7 silent list entries, C1 net-mode kernel sandbox).
# Run: tests/guard.test.sh   (no model needed, ~15 s; needs the pinned binary from install.sh)
# Self-contained: builds a FAKE projects root with a client folder (a canary) under $HOME and tests the
# rules against it — your real client list is not needed and not touched.
setopt NO_UNSET PIPE_FAIL
REPO="${0:A:h:h}"
G="$REPO/tools/guard.py"
PY=/usr/bin/python3
typeset -i fail=0
ok()  { print -- "✅ $1"; }
bad() { print -- "❌ $1"; fail+=1; }
# Any accidental real session must fail before a model is loaded (no LM Studio CLI for the launcher).
export CLAUDE_LOCAL_LMS=/usr/bin/false

# Fixture under $HOME (the home folder is what the sandboxes close; /private/tmp is closed anyway).
F=$(mktemp -d "$HOME/.kit-selftest.XXXXXX")
P="$F/Проекты"                                     # a projects root (broad root)
CLIENT="$P/Клиент-Йота"                            # a client folder; «Й» makes NFC ≠ NFD
CONTENT="$P/контент"                               # an ordinary project with a nested client subfolder
mkdir -p "$CLIENT/подпапка" "$CONTENT/клиенты-NDA" "$P/обычный-проект"
print -r -- "КАНАРЕЙКА-КЛИЕНТ" > "$CLIENT/README.md"
print -r -- "zzqq КАНАРЕЙКА-NDA" > "$CONTENT/клиенты-NDA/договор.txt"
print -r -- "обычный файл" > "$CONTENT/CLAUDE.md"
CL="$F/clients.list"; print -r -- "$CLIENT" > "$CL"; print -r -- "$CONTENT/клиенты-NDA" >> "$CL"
BR="$F/broad.list";   print -r -- "$P" > "$BR"
export CLAUDE_LOCAL_EXTRA_CLIENT_LIST="$CL" CLAUDE_LOCAL_EXTRA_BROAD_ROOTS="$BR"
SKL="$F/skills-src/demo-skill"; mkdir -p "$SKL"; printf -- '---\nname: demo-skill\n---\n' > "$SKL/SKILL.md"
SL="$F/skills.list"; print -r -- "demo-skill $SKL" > "$SL"
trap '/bin/rm -rf "$F"' EXIT

clients=("${(@f)$($PY -I $G clients "$CL" 2>/dev/null)}")
(( ${#clients} == 2 )) && ok "тестовый список клиентских папок разрешён (${#clients} пути)" || bad "список клиентских папок не разрешился: ${#clients}"
$PY -I $G clients "$REPO/config/client-folders.list" >/dev/null 2>"$F/warn" && ok "твой config/client-folders.list читается" \
  || bad "config/client-folders.list не читается: $(head -c 200 "$F/warn")"

expect_inside() { $PY -I $G inside "$1" $clients && ok "внутри клиентской: ${1/$HOME/~}" || bad "НЕ распознано как клиентская: ${1/$HOME/~}"; }
expect_outside() { $PY -I $G inside "$1" $clients && bad "ложно клиентская: ${1/$HOME/~}" || ok "не клиентская: ${1/$HOME/~}"; }
expect_inside  "$CLIENT/подпапка"
expect_inside  "/System/Volumes/Data$CLIENT/подпапка"                           # firmlink path (C6)
expect_inside  "${CLIENT:u}"                                                    # case variant
expect_inside  "$($PY -I -c 'import sys,unicodedata;print(unicodedata.normalize("NFD",sys.argv[1]))' "$CLIENT")"  # NFD
expect_outside "$P/обычный-проект"
expect_outside "$CONTENT"

# C7: entries with brackets / trailing spaces must still resolve or warn loudly
T=$(mktemp -d /private/tmp/guard-test.XXXXXX)
mkdir -p "$T/Клиент [NDA]" "$T/Плейн"
print -r -- "$T/Клиент [NDA]"  > "$T/list"
print -r -- "$T/Плейн   "     >> "$T/list"
print -r -- "$T/нет-такой"    >> "$T/list"
out=$($PY -I $G clients "$T/list" 2> "$T/warn")
[[ "$out" == *"Клиент [NDA]"* && "$out" == *"Плейн"* ]] && ok "скобки и пробелы в конце строки не теряются" || bad "запись из списка потерялась: $out"
grep -q "нет-такой" "$T/warn" && ok "несуществующая запись даёт предупреждение" || bad "несуществующая запись прошла молча"

# C1: net-mode kernel sandbox — client folders and secrets unreadable for Bash, work folder readable
mkdir -p "$T/work" "$T/conf/skills"
print -r -- "WORK-OK" > "$T/work/f.txt"
$PY -I $G sandbox-net "$T/net.sb" "$HOME" "$T/work" "$T/conf" "$REPO" "$HOME/.claude-local/bin/claude" "$CL" "$REPO/config/net-allow.list" "$SL" 2>/dev/null
SBX() { sandbox-exec -f "$T/net.sb" "$@" 2>&1; }
[[ "$(SBX /bin/cat "$T/work/f.txt")" == WORK-OK ]] && ok "веб-песочница: рабочая папка читается" || bad "веб-песочница: рабочая папка не читается"
r=$(SBX /usr/bin/grep -rlc . "$CLIENT" | head -3)
[[ "$r" == *"not permitted"* || -z "$r" ]] && ok "веб-песочница: grep -r по клиентской папке запрещён" || bad "веб-песочница: клиентская папка читается: ${r:0:80}"
r=$(SBX /bin/ls "$HOME/.claude-local/projects")
[[ "$r" == *"not permitted"* ]] && ok "веб-песочница: офлайн-история закрыта" || bad "веб-песочница: офлайн-история видна"
r=$(SBX /bin/ls "$HOME/.ssh")
[[ "$r" == *"not permitted"* ]] && ok "веб-песочница: ~/.ssh закрыт" || bad "веб-песочница: ~/.ssh виден"
r=$(SBX /bin/ls "$HOME/Documents")
[[ "$r" == *"not permitted"* ]] && ok "веб-песочница: остальная домашняя папка закрыта" || bad "веб-песочница: ~/Documents виден"
r=$(SBX /bin/sh -c "echo x >> '$REPO/config/offline.sb'")
[[ "$r" == *"not permitted"* ]] && ok "веб-песочница: код харнесса нельзя изменить" || bad "веб-песочница: offline.sb изменяем!"
r=$(SBX /bin/ls "/System/Volumes/Data$CLIENT")
[[ "$r" == *"not permitted"* ]] && ok "веб-песочница: путь через /System/Volumes/Data тоже закрыт" || bad "веб-песочница: обход через firmlink"
[[ "$(SBX "$HOME/.claude-local/bin/claude" --version)" == *"Claude Code"* ]] && ok "веб-песочница: Claude Code запускается" || bad "веб-песочница: Claude Code не запускается"
# the exact chain from the review: work folder = an ordinary project, glob into its NDA subfolder
C="$CONTENT"
$PY -I $G sandbox-net "$T/net2.sb" "$HOME" "$C" "$T/conf" "$REPO" "$HOME/.claude-local/bin/claude" "$CL" "$REPO/config/net-allow.list" "$SL" 2>/dev/null
n=$(cd "$C" && sandbox-exec -f "$T/net2.sb" /bin/sh -c 'grep -rh КАНАРЕЙКА клиенты* 2>/dev/null | wc -l' | tr -d ' ')
[[ "$n" == 0 ]] && ok "веб-песочница: grep -r по вложенной NDA-папке рабочего проекта ничего не открыл" || bad "веб-песочница: grep открыл $n строк из NDA-папки"
[[ -n "$(cd "$C" && sandbox-exec -f "$T/net2.sb" /bin/ls CLAUDE.md 2>/dev/null)" ]] && ok "веб-песочница: остальной проект доступен" || bad "веб-песочница: проект недоступен целиком"

# N1: a skill symlink planted in the (writable) config dir must not reopen a client folder
ln -s "$CLIENT" "$T/conf/skills/notes"
$PY -I $G sandbox-net "$T/net3.sb" "$HOME" "$T/work" "$T/conf" "$REPO" "$HOME/.claude-local/bin/claude" "$CL" "$REPO/config/net-allow.list" "$SL" 2>/dev/null
r=$(sandbox-exec -f "$T/net3.sb" /bin/ls "$T/conf/skills/notes/" 2>&1)
[[ "$r" == *"not permitted"* ]] && ok "веб-песочница: подброшенный симлинк в skills не открывает клиентскую папку" || bad "веб-песочница: симлинк в skills открыл клиентскую папку"
$PY -I $G sync-skills "$T/conf" "$SL"
[[ ! -e "$T/conf/skills/notes" && -L "$T/conf/skills/demo-skill" ]] && ok "sync-skills убирает подброшенное и восстанавливает список" || bad "sync-skills не почистил skills"
r=$(SBX /bin/sh -c "echo '{}' > '$T/conf/settings.json'")
[[ "$r" == *"not permitted"* ]] && ok "веб-песочница: свои настройки сессия переписать не может" || bad "веб-песочница: settings.json изменяем"
# N2: local services other than LM Studio are closed (example: Syncthing REST API on :8384)
r=$(SBX /usr/bin/curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8384/rest/system/version)
[[ "$r" != 200 && "$r" != 403 && "$r" != 401 ]] && ok "веб-песочница: Syncthing API (localhost:8384) закрыт" "" || bad "веб-песочница: Syncthing API доступен (HTTP $r)"
r=$(SBX /usr/bin/curl -s -m 3 -o /dev/null -w '%{http_code}' "http://[::ffff:127.0.0.1]:8384/rest/system/version")
[[ "$r" != 200 && "$r" != 403 && "$r" != 401 ]] && ok "веб-песочница: Syncthing через [::ffff:127.0.0.1] закрыт" || bad "веб-песочница: Syncthing через mapped IPv6 доступен (HTTP $r)"
[[ "$(SBX /usr/bin/curl -s -m 8 -o /dev/null -w '%{http_code}' https://example.com/)" == 200 ]] && ok "веб-песочница: интернет по IPv4 работает" || bad "веб-песочница: интернет не работает"
[[ "$(SBX /usr/bin/curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:1234/v1/models)" == 200 ]] && ok "веб-песочница: LM Studio API доступен" || bad "веб-песочница: LM Studio API закрыт"
# pasteboard and AppleEvents are closed in online mode too
print -r -- "clip-secret" | pbcopy
r=$(SBX /usr/bin/pbpaste); [[ "$r" != *clip-secret* ]] && ok "веб-песочница: буфер обмена не читается" || bad "веб-песочница: pbpaste прочитал буфер"
DISK=$(diskutil info / | awk -F': *' '/Volume Name/ {print $2}')
r=$(perl -e 'alarm 12; exec @ARGV' sandbox-exec -f "$T/net.sb" /usr/bin/osascript -e 'with timeout of 4 seconds' -e 'tell application "Finder" to get name of startup disk' -e 'end timeout' 2>&1)
[[ -n "$DISK" && "$r" != *"$DISK"* ]] && ok "веб-песочница: AppleEvents закрыты (Finder не ответил)" || bad "веб-песочница: AppleEvents работают"
# latent: macOS per-user temp dir is closed for reading
r=$(SBX /bin/ls "$(getconf DARWIN_USER_TEMP_DIR)")
[[ "$r" == *"not permitted"* ]] && ok "веб-песочница: системная temp-папка пользователя закрыта" || bad "веб-песочница: temp-папка читается"

# C4: net mode must refuse resume-by-path into offline history
r=$(cd "$T/work" && "$REPO/bin/claude-local" --web -r "$HOME/.claude-local/projects/x/y.jsonl" -p hi 2>&1 < /dev/null)
[[ $? -ne 0 && "$r" == *"офлайн"* ]] && ok "веб: --resume по пути к файлу отклонён" || bad "веб: --resume по пути не отклонён: ${r:0:120}"
r=$(cd "$T/work" && "$REPO/bin/claude-local" --web "-r$HOME/.claude-local/projects/x/y.jsonl" -p hi 2>&1 < /dev/null)
[[ $? -ne 0 && "$r" == *"офлайн"* ]] && ok "веб: слитная форма -r/путь тоже отклонена" || bad "веб: -r/путь не отклонён"
# too-broad work folder
r=$(cd "$HOME" && "$REPO/bin/claude-local" --web -p hi 2>&1 < /dev/null)
[[ $? -ne 0 ]] && ok "веб: запуск из домашней папки отклонён" || bad "веб: запуск из ~ разрешён"
for d in /Users "$HOME/Library" "$P" /System/Volumes/Data; do
  r=$(cd "$d" && "$REPO/bin/claude-local" --web -p hi 2>&1 < /dev/null)
  [[ $? -ne 0 && "$r" == *"широкая"* ]] && ok "веб: запуск из ${d/$HOME/~} отклонён" || bad "веб: запуск из ${d/$HOME/~} разрешён"
done
# offline too (2026-11-16 night): with the home folder as the work folder the whole home would be writable
for d in "$HOME" /Users "$HOME/Library" "$HOME/.claude"; do
  r=$(cd "$d" && "$REPO/bin/claude-local" -p hi 2>&1 < /dev/null)
  [[ $? -ne 0 && "$r" == *"широкая"* ]] && ok "офлайн: запуск из ${d/$HOME/~} отклонён" || bad "офлайн: запуск из ${d/$HOME/~} разрешён"
done

# --- VS Code wrapper: the SDK's flags are replaced by ours, the bundled binary is never run ---
BUND="$T/ext/anthropic.claude-code-9.9.9-darwin-arm64/resources/native-binary/claude"
r=$(cd "$T/work" && CLAUDE_LOCAL_DRYRUN=1 "$REPO/bin/claude-local-vscode" "$BUND" --output-format stream-json --verbose \
     --input-format stream-json --model=opus --fallback-model=sonnet --setting-sources=user,project,local \
     --strict-mcp-config --debug-file=/tmp/x.log --permission-mode=default 2>&1 </dev/null)
[[ "$r" == *"MODE=offline KIND=session"* ]] && ok "vscode: чат идёт в офлайн-режиме" || bad "vscode: режим не тот: ${r:0:200}"
[[ "$r" != *"$BUND"* ]] && ok "vscode: встроенный бинарь расширения не запускается" || bad "vscode: бинарь расширения попал в команду"
[[ "$r" == *"--model=qwen-work"* && "$r" != *"--model=opus"* && "$r" != *"fallback-model"* ]] \
  && ok "vscode: модель принудительно локальная" || bad "vscode: модель из расширения прошла"
[[ "$r" != *"user,project,local"* && "$r" != *"debug-file"* && "${(f)r}" == *"--setting-sources"* ]] \
  && ok "vscode: настройки проекта и debug-file из расширения отброшены" || bad "vscode: setting-sources/debug-file расширения прошли"
r=$(cd "$T/work" && CLAUDE_CODE_CONFIG_PROBE=1 CLAUDE_LOCAL_DRYRUN=1 "$REPO/bin/claude-local-vscode" "$BUND" --output-format stream-json 2>&1 </dev/null)
[[ "$r" == *"KIND=probe"* ]] && ok "vscode: служебный запрос не грузит модель" || bad "vscode: probe не распознан"
r=$(cd "$T/work" && CLAUDE_LOCAL_DRYRUN=1 "$REPO/bin/claude-lab-vscode" "$BUND" auth status --json 2>&1 </dev/null)
[[ "$r" == *"MODE=net KIND=utility"* && "$r" != *"--model="* ]] && ok "vscode-лаб: утилиты без флагов сессии" || bad "vscode-лаб: утилита: ${r:0:200}"
r=$(cd "$CLIENT" 2>/dev/null && CLAUDE_LOCAL_DRYRUN=1 "$REPO/bin/claude-lab-vscode" "$BUND" --output-format stream-json 2>&1 </dev/null)
[[ $? -ne 0 && "$r" == *"Локальный Claude"* ]] && ok "vscode-лаб: клиентская папка отклонена" || bad "vscode-лаб: клиентская папка открылась"
r=$(cd "$HOME" && CLAUDE_LOCAL_DRYRUN=1 "$REPO/bin/claude-local-vscode" "$BUND" --output-format stream-json 2>&1 </dev/null)
[[ $? -ne 0 && "$r" == *"Открыть папку"* ]] && ok "vscode: окно без папки (домашняя) отклонено с подсказкой" || bad "vscode: домашняя папка принята"

# --- offline sandbox: what defines a later launch is never writable, even inside a broad work folder ---
H="$T/home"; mkdir -p "$H/repo/bin" "$H/Library/LaunchAgents" "$H/.claude" "$H/.local/bin" "$H/conf/bin" "$H/conf/skills"
SBO() { sandbox-exec -f "$REPO/config/offline.sb" -D WORKDIR="$H" -D CONFDIR="$H/conf" -D REPO="$H/repo" -D HOME="$H" /bin/sh -c "$1" >/dev/null 2>&1; }
SBO "echo x > '$H/note.txt'" && ok "офлайн-песочница: обычная запись в рабочей папке работает" || bad "офлайн-песочница: запись в рабочую папку закрыта (профиль не загрузился?)"
for f in repo/bin/claude-local Library/LaunchAgents/x.plist .claude/settings.json .local/bin/claude-local conf/bin/claude conf/settings.json .zshrc .gitconfig; do
  SBO "echo x > '$H/$f'" && bad "офлайн-песочница: можно переписать ~/$f" || ok "офлайн-песочница: ~/$f не переписать"
done
SBO "ln -s /etc '$H/conf/skills/evil'" && bad "офлайн-песочница: можно подложить скилл" || ok "офлайн-песочница: скилл не подложить"

# --- online sandbox: listed skills are readable (they were silently blocked before 2026-11-16 night) ---
mkdir -p "$T/conf2/skills"; $PY -I $G sync-skills "$T/conf2" "$SL"
python3 -I "$REPO/tools/guard.py" sandbox-net "$T/net4.sb" "$HOME" "$T/work" "$T/conf2" "$REPO" \
  "$HOME/.claude-local/bin/claude" "$CL" "$REPO/config/net-allow.list" "$SL"
sandbox-exec -f "$T/net4.sb" /bin/cat "$T/conf2/skills/demo-skill/SKILL.md" >/dev/null 2>&1 \
  && ok "веб-песочница: подключённый скилл читается" || bad "веб-песочница: подключённый скилл не читается"
sandbox-exec -f "$T/net2.sb" /bin/cat "$HOME/.claude/settings.json" >/dev/null 2>&1 \
  && bad "веб-песочница: ~/.claude/settings.json читается" || ok "веб-песочница: остальное в ~/.claude закрыто"

# --- review 2026-11-16 night (critic «VS Code path»): escapes via files that run LATER, unsandboxed ---
# probe = create and immediately delete; success means the sandbox let it write there
NETW() { sandbox-exec -f "$T/net.sb" /bin/sh -c "echo x > '$1' && /bin/rm -f '$1'" >/dev/null 2>&1; }
NETW "$T/work/plain.txt" && ok "веб-песочница: запись в рабочую папку работает" || bad "веб-песочница: рабочая папка не пишется (профиль сломан?)"
NETW "$T/conf/projects-probe" && bad "веб-песочница: в корень конфига можно писать" || ok "веб-песочница: корень конфига только для чтения"
mkdir -p "$T/conf/projects"; NETW "$T/conf/projects/x.jsonl" && ok "веб-песочница: история сессий пишется" || bad "веб-песочница: history/projects не пишется"
mkdir -p "$T/conf/rules"; NETW "$T/conf/rules/p.md" && bad "веб-песочница: CONF/rules (память на все сессии) пишется" || ok "веб-песочница: CONF/rules закрыт"
for d in /opt/homebrew/bin "/Applications/Локальный Claude.app/Contents/Resources/Scripts" "$HOME/Library/Caches" "$HOME/.cache" "$HOME/.npm" "$REPO/apps" "$REPO/docs" /Users/Shared; do
  [[ -d "$d" ]] || continue
  NETW "$d/.claude-local-probe-$$" && { bad "веб-песочница: можно писать в ${d/#$HOME/~}"; /bin/rm -f "$d/.claude-local-probe-$$"; } \
    || ok "веб-песочница: ${d/#$HOME/~} не пишется"
done
NETR() { sandbox-exec -f "$T/net.sb" /bin/sh -c "$1" >/dev/null 2>&1; }
mkdir -p "$T/work/r/.git"
NETR "echo '[core]' > '$T/work/r/.git/config'" && bad "веб-песочница: .git/config пишется (fsmonitor)" || ok "веб-песочница: .git/config не пишется"
NETR "mkdir -p '$T/work/.vscode'" && bad "веб-песочница: .vscode/ создаётся" || ok "веб-песочница: .vscode/ не создаётся"
NETR "/bin/ls /Volumes/ >/dev/null" && bad "веб-песочница: /Volumes читается" || ok "веб-песочница: внешние диски (/Volumes) закрыты"
mkdir -p "$HOME/Library/Caches/claude-local-locks"; : >> "$HOME/Library/Caches/claude-local-locks/net.lock"
NETR "/bin/cat '$HOME/Library/Caches/claude-local-locks/net.lock'" && bad "веб-песочница: лок лаунчера доступен" || ok "веб-песочница: лок лаунчера недоступен"
SOCK="/private/tmp/clu-$$.sock"
/usr/bin/python3 -I -c "import socket,time;s=socket.socket(socket.AF_UNIX);s.bind('$SOCK');s.listen(1);time.sleep(6)" & lp=$!; sleep 1
/usr/bin/python3 -I -c "import socket;s=socket.socket(socket.AF_UNIX);s.connect('$SOCK')" 2>/dev/null && pos=1 || pos=0
sandbox-exec -f "$T/net.sb" /usr/bin/python3 -I -c "import socket;s=socket.socket(socket.AF_UNIX);s.connect('$SOCK')" >/dev/null 2>&1 \
  && bad "веб-песочница: unix-сокеты открыты (ssh-agent, docker…)" || { (( pos )) && ok "веб-песочница: unix-сокеты закрыты" || bad "unix-сокет: нет положительного контроля"; }
kill $lp 2>/dev/null; /bin/rm -f "$SOCK"
# offline: same later-execution plants
mkdir -p "$H/w/r/.git" "$H/conf/rules" "$H/conf/projects"
SBW() { sandbox-exec -f "$REPO/config/offline.sb" -D WORKDIR="$H/w" -D CONFDIR="$H/conf" -D REPO="$H/repo" -D HOME="$H" /bin/sh -c "$1" >/dev/null 2>&1; }
SBW "echo x > '$H/w/ok.txt'" && ok "офлайн-песочница: запись в рабочую папку (контроль)" || bad "офлайн-песочница: контроль не прошёл"
SBW "git -C '$H/w/r' init -q 2>/dev/null; echo '[core] fsmonitor = /tmp/x' > '$H/w/r/.git/config'" && bad "офлайн-песочница: .git/config пишется (fsmonitor → вынос)" || ok "офлайн-песочница: .git/config не пишется"
SBW "mkdir -p '$H/w/r/.git/hooks' && echo x > '$H/w/r/.git/hooks/post-checkout'" && bad "офлайн-песочница: git-хуки пишутся" || ok "офлайн-песочница: git-хуки не пишутся"
SBW "mkdir -p '$H/w/.vscode' && echo '{}' > '$H/w/.vscode/tasks.json'" && bad "офлайн-песочница: .vscode/tasks.json пишется" || ok "офлайн-песочница: .vscode/ не пишется"
SBW "echo x > '$H/conf/rules/p.md'" && bad "офлайн-песочница: CONF/rules пишется" || ok "офлайн-песочница: CONF/rules закрыт"
SBW "echo x > '$H/conf/projects/s.jsonl'" && ok "офлайн-песочница: история сессий пишется" || bad "офлайн-песочница: projects/ не пишется"
SBW "echo x > '$H/conf/.claude.json.tmp.1'" && ok "офлайн-песочница: .claude.json пишется" || bad "офлайн-песочница: .claude.json не пишется"
# launcher: repo, the projects root and the Chrome bridge refused
r=$(cd "$REPO" && CLAUDE_LOCAL_DRYRUN=1 "$REPO/bin/claude-lab-vscode" "$BUND" --output-format stream-json 2>&1 </dev/null)
[[ $? -ne 0 && "$r" == *"широкая"* ]] && ok "лаунчер: папка самого харнесса отклонена" || bad "лаунчер: харнесс как рабочая папка принят"
r=$(cd "$P" && CLAUDE_LOCAL_DRYRUN=1 "$REPO/bin/claude-local-vscode" "$BUND" --output-format stream-json 2>&1 </dev/null)
[[ $? -ne 0 && "$r" == *"широкая"* ]] && ok "офлайн: корень проектов отклонён целиком" || bad "офлайн: корень проектов принят"
r=$(cd "$P/обычный-проект" && CLAUDE_LOCAL_DRYRUN=1 "$REPO/bin/claude-local-vscode" "$BUND" --output-format stream-json 2>&1 </dev/null)
[[ $? -eq 0 && "$r" == *"MODE=offline"* ]] && ok "офлайн: обычный проект открывается (контроль)" || bad "офлайн: обычный проект отклонён: ${r:0:160}"
r=$(cd "$T/work" && CLAUDE_LOCAL_DRYRUN=1 "$REPO/bin/claude-lab-vscode" "$BUND" --claude-in-chrome-mcp 2>&1 </dev/null)
[[ $? -ne 0 && "$r" == *"Chrome"* ]] && ok "vscode: мост в Chrome отклонён" || bad "vscode: мост в Chrome прошёл"

# launchd: jobs and environment for LATER launches (they would run outside the sandbox). macOS refuses
# sandboxed callers today; this catches a future change. Control for setenv is done outside the sandbox.
U=$(id -u); /bin/rm -f /tmp/kit-launchd-canary
for prof in offline net; do
  if [[ $prof == offline ]]; then RUN=(sandbox-exec -f "$REPO/config/offline.sb" -D WORKDIR="$T/work" -D CONFDIR="$T/conf" -D REPO="$REPO" -D HOME="$HOME")
  else RUN=(sandbox-exec -f "$T/net.sb"); fi
  $RUN /bin/launchctl setenv KIT_SANDBOX_CANARY 1 >/dev/null 2>&1
  [[ -z "$(launchctl getenv KIT_SANDBOX_CANARY)" ]] && ok "$prof-песочница: launchctl setenv не проходит" || bad "$prof-песочница: сессия задаёт окружение будущих запусков"
  launchctl unsetenv KIT_SANDBOX_CANARY 2>/dev/null
  $RUN /bin/launchctl submit -l kit.sandbox.canary -- /usr/bin/touch /tmp/kit-launchd-canary >/dev/null 2>&1; sleep 1.5
  [[ ! -e /tmp/kit-launchd-canary ]] && ok "$prof-песочница: задание launchd не создаётся" || bad "$prof-песочница: launchd запустил команду вне песочницы"
  launchctl remove kit.sandbox.canary 2>/dev/null; /bin/rm -f /tmp/kit-launchd-canary
done
launchctl setenv KIT_SANDBOX_CANARY 1; [[ -n "$(launchctl getenv KIT_SANDBOX_CANARY)" ]] && ok "launchd: контроль — вне песочницы setenv работает" || bad "launchd: контроль не прошёл (проверка выше недостоверна)"
launchctl unsetenv KIT_SANDBOX_CANARY
# test hook: CLAUDE_LOCAL_LMS cannot point to an arbitrary program
r=$(cd "$T/work" && CLAUDE_LOCAL_LMS=/bin/echo "$REPO/bin/claude-local" --status 2>&1 </dev/null)
[[ $? -ne 0 && "$r" == *"только для тестов"* ]] && ok "лаунчер: CLAUDE_LOCAL_LMS вне tests/ отклонён" || bad "лаунчер: CLAUDE_LOCAL_LMS принял /bin/echo: ${r:0:120}"
# pinned binary must carry Anthropic's Developer ID; an ad-hoc signed fake must not pass
cp /usr/bin/true "$T/fake-claude" && codesign --force --sign - "$T/fake-claude" 2>/dev/null
codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW"' "$T/fake-claude" 2>/dev/null \
  && bad "закрепление: самоподписанная подделка проходит проверку" || ok "закрепление: самоподписанная подделка отклоняется"
codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW"' "$HOME/.claude-local/bin/claude" 2>/dev/null \
  && ok "закрепление: закреплённый Claude Code подписан Anthropic" || bad "закрепление: закреплённый бинарь не подписан Anthropic"

# --- cross-session messaging (20.11.2026): the Lab bound an inbox in CONF/tmp/cc-socks and queued a message an
# outside process wrote there → text (e.g. from a session with client files) could reach the internet-enabled Lab.
# Policies refuse inbound peer messages; here the REAL pinned Claude Code runs in each sandbox (dead model URL —
# no model needed), an outside process writes into its inbox, and the message must not get in.
for m in net offline; do
  $PY -I -c 'import json,sys; d=json.load(open(sys.argv[1])); deny=d["permissions"]["deny"]; sys.exit(0 if d.get("crossSessionInbound")=="refuse" and "SendMessage" in deny and "ListAgents" in deny else 1)' "$REPO/config/policy-$m.json" \
    && ok "политика $m: входящие от других сессий отклоняются, SendMessage/ListAgents запрещены" || bad "политика $m: переписка сессий не закрыта"
done
peer_probe() {   # $1 mode (net|offline), $2 CONF dir, $3 work dir, rest: sandbox-exec prefix
  local mode=$1 conf=$2 work=$3; shift 3
  mkdir -p "$conf/tmp" "$conf/debug" "$work"; local log="$conf/debug/peer-probe.txt"; /bin/rm -f "$log"
  $PY -I $G policy "$mode" "$REPO/config/policy-$mode.json" "$conf/.policy.json" "${CL:-$REPO/config/client-folders.list}" 2>/dev/null
  local here=$PWD; cd "$work"
  perl -e 'alarm 25; exec @ARGV' "$@" /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin USER="$USER" CLAUDE_CONFIG_DIR="$conf" \
    TMPDIR="$conf/tmp" CLAUDE_CODE_TMPDIR="$conf/tmp" ANTHROPIC_BASE_URL=http://localhost:1235 ANTHROPIC_AUTH_TOKEN=x \
    ANTHROPIC_MODEL=probe CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_FEATURE_FLAGS=1 DISABLE_AUTOUPDATER=1 \
    "$HOME/.claude-local/bin/claude" -p hi --debug-file "$log" --settings "$conf/.policy.json" --setting-sources user >/dev/null 2>&1 &
  local pid=$! sock="" i
  cd "$here"
  for i in {1..60}; do
    sock=$(grep -ho 'Listening: [^ ]*\.sock' "$log" 2>/dev/null | head -1)
    [[ -n $sock ]] && break
    grep -q 'refusing to bind' "$log" 2>/dev/null && break
    sleep 0.25
  done
  sock=${sock#Listening: }
  if [[ -n $sock ]]; then
    $PY -I -c 'import socket,sys;s=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);s.sendall(b"{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"peer-probe\"}}\n");s.close()' "$sock" 2>/dev/null
    sleep 2
  fi
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  if grep -q 'Routed user message' "$log" 2>/dev/null; then bad "$mode: сообщение от внешнего процесса попало в сессию"
  elif [[ -n $sock ]] && grep -q 'refused inbound peer message' "$log"; then ok "$mode: ящик сессии есть, входящее отклонено"
  elif [[ -z $sock ]] && grep -q 'refusing to bind' "$log" 2>/dev/null; then ok "$mode: ящика нет — песочница не дала его создать"
  else bad "$mode: проверка ящика без результата (${sock:-нет сокета})"; fi
}
if [[ -x "$HOME/.claude-local/bin/claude" ]]; then
  peer_probe net "$T/conf" "$T/work" sandbox-exec -f "$T/net.sb"
  peer_probe offline "$H/peerconf" "$H/peerwork" sandbox-exec -f "$REPO/config/offline.sb" -D WORKDIR="$H/peerwork" -D CONFDIR="$H/peerconf" -D REPO="$REPO" -D HOME="$HOME"
else
  bad "переписка сессий: нет закреплённого Claude Code ($HOME/.claude-local/bin/claude)"
fi

# --- continue a cloud session offline (20.11.2026): one way, cloud history → offline history ---
IC="$T/imp/cloud"; IO="$T/imp/offline"; SID=11111111-2222-4333-8444-555555555555
mkdir -p "$IC/-proj"; printf '{"a":1}\n{"b":2}\n{"partial' > "$IC/-proj/$SID.jsonl"
$PY -I $G import-session "$SID" "$IC" "$IO" 2>/dev/null
[[ "$(cat "$IO/-proj/$SID.jsonl" 2>/dev/null)" == $'{"a":1}\n{"b":2}' ]] && ok "импорт: облачная сессия перенесена, недописанная строка отрезана" || bad "импорт: копия не та"
[[ "$(stat -f %Lp "$IO/-proj/$SID.jsonl" 2>/dev/null)" == 600 ]] && ok "импорт: копия только для владельца (600)" || bad "импорт: права копии не 600"
print -r -- '{"local":1}' >> "$IO/-proj/$SID.jsonl"; $PY -I $G import-session "$SID" "$IC" "$IO" 2>/dev/null
grep -q local "$IO/-proj/$SID.jsonl" && ok "импорт: локальное продолжение не перезаписывается" || bad "импорт: локальная копия перезаписана"
before=$(ls -lRT "$IC" | md5)
for junk in "../x" "$IC/-proj/$SID.jsonl" "abc" "${SID:u}" "$SID/../x" "-$SID"; do $PY -I $G import-session "$junk" "$IC" "$IO" 2>/dev/null; done
[[ "$(ls -lRT "$IC" | md5)" == "$before" ]] && ok "импорт: облачная история не меняется" || bad "импорт: облачная история изменена"
[[ $(find "$IO" -name '*.jsonl' | wc -l | tr -d ' ') == 1 ]] && ok "импорт: пути и мусор вместо номера игнорируются" || bad "импорт: лишние файлы в локальной истории"
SID2=21111111-2222-4333-8444-555555555555; SID3=31111111-2222-4333-8444-555555555555
mkdir -p "$T/imp/elsewhere"; print -r -- '{"x":1}' > "$T/imp/elsewhere/$SID2.jsonl"
ln -s "$T/imp/elsewhere" "$IC/-linked"; ln -s "$T/imp/elsewhere/$SID2.jsonl" "$IC/-proj/$SID3.jsonl"
$PY -I $G import-session "$SID2" "$IC" "$IO" 2>/dev/null; $PY -I $G import-session "$SID3" "$IC" "$IO" 2>/dev/null
[[ -z "$(find "$IO" -name "$SID2.jsonl" -o -name "$SID3.jsonl")" ]] && ok "импорт: ссылки из облачной истории не переносятся" || bad "импорт: перенесена ссылка"
$PY -I $G import-session "$SID" "$IC" "$IC/sub" 2>/dev/null && bad "импорт: назначение внутри источника принято" || ok "импорт: назначение внутри источника отклонено"
# launcher: offline imports, the Lab never does; the source override is a test hook for tests/ only
SID4=41111111-2222-4333-8444-555555555555; FX="$REPO/tests/.import-fixture-$$"; FP="-claude-local-import-selftest"
mkdir -p "$FX/$FP"; print -r -- '{"type":"user","message":{"role":"user","content":"selftest"}}' > "$FX/$FP/$SID4.jsonl"
/bin/rm -rf "${HOME:?}/.claude-local/projects/$FP" "${HOME:?}/.claude-local-net/projects/$FP"
(cd "$T/work" && CLAUDE_LOCAL_DRYRUN=1 CLAUDE_LOCAL_CLOUD_PROJECTS="$FX" "$REPO/bin/claude-local" --web -p hi --resume "$SID4" >/dev/null 2>&1 </dev/null)
[[ ! -e "$HOME/.claude-local-net/projects/$FP" && ! -e "$HOME/.claude-local/projects/$FP" ]] && ok "лаунчер: Лаборатория облачную сессию не переносит" || bad "лаунчер: Лаборатория перенесла облачную сессию"
(cd "$T/work" && CLAUDE_LOCAL_DRYRUN=1 CLAUDE_LOCAL_CLOUD_PROJECTS="$FX" "$REPO/bin/claude-local" -p hi --resume "$SID4" >/dev/null 2>&1 </dev/null)
[[ -f "$HOME/.claude-local/projects/$FP/$SID4.jsonl" ]] && ok "лаунчер: офлайн переносит облачную сессию по --resume" || bad "лаунчер: офлайн не перенёс облачную сессию"
r=$(cd "$T/work" && CLAUDE_LOCAL_DRYRUN=1 CLAUDE_LOCAL_CLOUD_PROJECTS="$T/imp/cloud" "$REPO/bin/claude-local" -p hi --resume "$SID" 2>&1 </dev/null)
[[ $? -ne 0 && "$r" == *"только для тестов"* ]] && ok "лаунчер: CLAUDE_LOCAL_CLOUD_PROJECTS вне tests/ отклонён" || bad "лаунчер: CLAUDE_LOCAL_CLOUD_PROJECTS вне tests/ принят"
# adversarial review 20.11: links/case/hardlinks/newline/clusters must not move data anywhere else
SID5=51111111-2222-4333-8444-555555555555; mkdir -p "$IC/-p5" "$T/imp/victim"; print -r -- '{"v":5}' > "$IC/-p5/$SID5.jsonl"
mkdir -p "$T/imp/o2"; ln -s "$T/imp/victim" "$T/imp/o2/projects"
$PY -I $G import-session "$SID5" "$IC" "$T/imp/o2/projects" 2>/dev/null
[[ -z "$(ls -A "$T/imp/victim")" ]] && ok "импорт: локальная история-ссылка не принимается (ничего не записано по ссылке)" || bad "импорт: записал по ссылке вместо локальной истории"
$PY -I $G import-session "$SID5" "$IC" "${IC:h}/CLOUD/stolen" 2>/dev/null
[[ ! -e "$IC/stolen" ]] && ok "импорт: назначение в облачной истории другим регистром отклонено" || bad "импорт: записал в облачную историю через другой регистр"
mkdir -p "$T/imp/o3/projects"; ln -s "$T/imp/victim" "$T/imp/o3/projects/-p5"
$PY -I $G import-session "$SID5" "$IC" "$T/imp/o3/projects" 2>/dev/null
[[ -z "$(ls -A "$T/imp/victim")" ]] && ok "импорт: подложенная ссылка на папку проекта не используется" || bad "импорт: записал через подложенную ссылку проекта"
SID6=61111111-2222-4333-8444-555555555555; mkdir -p "$IC/-p6"; print -r -- '{"secret":1}' > "$T/imp/elsewhere/secret.txt"
ln "$T/imp/elsewhere/secret.txt" "$IC/-p6/$SID6.jsonl"
$PY -I $G import-session "$SID6" "$IC" "$IO" 2>/dev/null
[[ ! -e "$IO/-p6/$SID6.jsonl" ]] && ok "импорт: жёсткая ссылка не переносится" || bad "импорт: перенесена жёсткая ссылка"
$PY -I $G import-session "$SID5"$'\n' "$IC" "$T/imp/o4" 2>/dev/null
[[ ! -e "$T/imp/o4" ]] && ok "импорт: номер с переводом строки игнорируется" || bad "импорт: принят номер с переводом строки"
mkdir -p "$FX/real"; ln -s "$FX/real" "$REPO/tests/.import-link-$$"; mkdir -p "$T/imp/outside/-x"
r=$(cd "$T/work" && CLAUDE_LOCAL_DRYRUN=1 CLAUDE_LOCAL_CLOUD_PROJECTS="$REPO/tests/.import-link-$$/../../../$(basename "$T")/imp/outside" "$REPO/bin/claude-local" -p hi --resume "$SID" 2>&1 </dev/null)
[[ $? -ne 0 && "$r" == *"только для тестов"* ]] && ok "лаунчер: обход tests/<ссылка>/.. отклонён" || bad "лаунчер: CLAUDE_LOCAL_CLOUD_PROJECTS обошёл проверку"
/bin/rm -f "$REPO/tests/.import-link-$$"
for form in "-pr$HOME/.claude-local/projects/x/$SID.jsonl" "-pr"; do
  extra=(); [[ $form == -pr ]] && extra=("$HOME/.claude-local/projects/x/$SID.jsonl")
  r=$(cd "$T/work" && CLAUDE_LOCAL_DRYRUN=1 "$REPO/bin/claude-local" --web "$form" "${extra[@]}" hi 2>&1 </dev/null)
  [[ $? -ne 0 && "$r" == *"по пути к файлу"* ]] && ok "Лаборатория: ${form:0:3}… по пути к офлайн-истории отклонён" || bad "Лаборатория: ${form:0:3}… по пути прошёл"
done
/bin/rm -rf "${HOME:?}/.claude-local/projects/$FP" "${HOME:?}/.claude-local-net/projects/$FP" "$FX"

/bin/rm -rf "$T"
print "=== guard tests: $fail ❌"
exit $fail
