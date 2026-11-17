#!/bin/zsh
# interactive.sh — drive a REAL interactive claude-local session in tmux (what the user actually uses):
# first-run dialogs, no login screen, status line, an answer from the local model, zero external
# traffic. Usage: tests/interactive.sh [--lab]
setopt NO_UNSET PIPE_FAIL
REPO="${0:A:h:h}"
PROFILE=(); [[ "${1:-}" == --lab ]] && PROFILE=(--lab --offline)
TMUX_BIN=/opt/homebrew/bin/tmux
S="cl-interactive-$$"
WS=$(mktemp -d /private/tmp/claude-local-int.XXXXXX)
print -r -- "Кодовое слово проекта: ЛАЗУРЬ." > "$WS/note.txt"
NET="$WS/nettop.csv"
fail=0
pane() { $TMUX_BIN capture-pane -p -t "$S" 2>/dev/null; }                 # visible screen only
hist() { $TMUX_BIN capture-pane -p -t "$S" -S -400 2>/dev/null; }          # with scrollback
wait_for() {   # $1 regex, $2 seconds; answers the folder-trust dialog if it shows up
  local i
  for (( i = 0; i < $2; i++ )); do
    if pane | grep -qiE "trust (the files|this folder)"; then print "❌ показан диалог доверия (лаунчер должен был отметить папку)"; fail=1; $TMUX_BIN send-keys -t "$S" Down Enter; fi
    pane | grep -qE "$1" && return 0
    sleep 1
  done
  return 1
}

nettop -P -t external -L 0 -s 1 -J bytes_in,bytes_out -x > "$NET" 2>/dev/null &
NP=$!
$TMUX_BIN new-session -d -s "$S" -x 220 -y 50 \
  "cd '$WS' && env -u ELECTRON_RUN_AS_NODE -u CLAUDECODE PATH=$HOME/.local/bin:\$PATH $REPO/bin/claude-local ${PROFILE[*]}; echo CLAUDE-EXITED-rc=\$?; sleep 600"
CPID=$($TMUX_BIN list-panes -t "$S" -F '#{pane_pid}')

if wait_for "ЛОКАЛЬНО|❯|>" 180; then print "✅ интерактивная сессия запустилась"; else print "❌ сессия не запустилась"; fail=1; fi
if pane | grep -qiE "log ?in|sign in|войдите|select login|anthropic console"; then print "❌ показан экран входа в аккаунт"; fail=1
else print "✅ экрана входа в облачный аккаунт нет"; fi
wait_for "ЛОКАЛЬНО · БЕЗ ИНТЕРНЕТА" 20 >/dev/null
if pane | grep -q "ЛОКАЛЬНО · БЕЗ ИНТЕРНЕТА"; then print "✅ строка статуса показывает «🔒 ЛОКАЛЬНО · БЕЗ ИНТЕРНЕТА»"; else print "❌ режим не виден в строке статуса"; fail=1; fi

$TMUX_BIN send-keys -t "$S" -l "Прочитай файл note.txt и назови кодовое слово одним словом."
sleep 0.5; $TMUX_BIN send-keys -t "$S" Enter
( for k in {1..20}; do sleep 15; print "=== +$((k*15))s"; hist | tail -25; done ) > "$WS/snapshots.txt" 2>&1 &
SNAP=$!
if wait_for "ЛАЗУРЬ([^.:]|$)" 300 || hist | grep -c "ЛАЗУРЬ" | grep -q "^[2-9]"; then print "✅ локальная модель ответила (ЛАЗУРЬ)"; else print "❌ ответа нет за 5 минут"; fail=1; fi

# collect the process tree before closing
tree=" $CPID "
for _ in 1 2 3; do for p in ${=tree}; do for k in $(pgrep -P $p 2>/dev/null); do [[ "$tree" == *" $k "* ]] || tree+="$k "; done; done; done
kill $SNAP 2>/dev/null; hist > "$WS/pane.txt"; hist | grep -q CLAUDE-EXITED && print "⚠ Claude Code завершился: $(hist | grep -o "CLAUDE-EXITED-rc=[0-9]*")"
$TMUX_BIN send-keys -t "$S" C-c; sleep 0.5; $TMUX_BIN send-keys -t "$S" C-c; sleep 2
$TMUX_BIN kill-session -t "$S" 2>/dev/null
sleep 2; kill $NP 2>/dev/null; wait $NP 2>/dev/null

ext=$(/usr/bin/python3 -I - "$NET" ${=tree} <<'PY'
import sys, csv
net, *pids = sys.argv[1:]; pids = set(pids); last = {}
for row in csv.reader(open(net, errors="ignore")):
    if len(row) >= 3 and "." in row[0]:
        name, _, pid = row[0].rpartition(".")
        if pid in pids:
            try: last[row[0]] = int(row[1] or 0) + int(row[2] or 0)
            except ValueError: pass
print(sum(last.values()), " ".join(f"{k}={v}" for k, v in last.items() if v))
PY
)
if [[ "${ext%% *}" == 0 ]]; then print "✅ 0 байт во внешнюю сеть (процессов: $(print ${=tree} | wc -w | tr -d ' '))"; else print "❌ внешний трафик: $ext"; fail=1; fi
print "Экран сессии сохранён: $WS/pane.txt"
exit $fail
