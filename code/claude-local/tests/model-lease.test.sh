#!/bin/zsh
# Model switching safety (review 2026-11-16 night, critic «wrapper»): one model fits in memory, so
#  - a running session of one profile must block unloading its model by the other profile;
#  - VS Code utilities/probes never wait for a model load;
#  - a launch killed mid-load finishes that load, and the retry does not start a second one.
# Uses a fake LM Studio (tests/fake-lmstudio) — no real model, nothing on screen.
REPO="${0:A:h:h}"; CL="$REPO/bin/claude-local"; fail=0
ok()  { print -- "✅ $1"; }
bad() { print -- "❌ $1"; fail+=1; }
T=$(mktemp -d /private/tmp/lease-test.XXXXXX); mkdir -p "$T/state" "$T/locks" "$T/work"
export FAKE_LMS_STATE="$T/state" CLAUDE_LOCAL_LMS="$REPO/tests/fake-lmstudio/lms" CLAUDE_LOCAL_PORT=18234 \
       CLAUDE_LOCAL_LOCK_DIR="$T/locks" CLAUDE_LOCAL_NO_WARM=1
/usr/bin/python3 -I "$REPO/tests/fake-lmstudio/server.py" 18234 & srv=$!; sleep 1
zmodload zsh/system

# lab model loaded and a lab session running (holds the lab lease)
print -r -- '[{"type":"llm","identifier":"qwen-lab","modelKey":"huihui-qwen3.8-27b-abliterated-cc","contextLength":65536}]' > "$T/state/loaded"
: >> "$T/locks/lease-lab"
( zsystem flock -r -f h "$T/locks/lease-lab"; sleep 6 ) & holder=$!; sleep 0.5
r=$("$CL" --preload 2>&1); rc=$?
[[ $rc -ne 0 && "$r" == *"Лаборатор"* ]] && ok "рабочая модель не выгружает занятую Лабораторию" || bad "занятая модель выгружена: rc=$rc ${r:0:150}"
grep -q "unload" "$T/state/log" 2>/dev/null && bad "был вызван unload при занятой модели" || ok "unload не вызывался"
wait $holder
r=$("$CL" --preload 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "load-done qwen3.8-27b-mlx" "$T/state/log" && ok "после закрытия Лаборатории рабочая модель загрузилась" || bad "переключение не сработало: ${r:0:150}"

# utilities and probes do not wait for a model load (model lock held for 8 s)
: >> "$T/locks/model.lock"
( zsystem flock -f h "$T/locks/model.lock"; sleep 8 ) & holder=$!; sleep 0.5
BUND="$T/x/native-binary/claude"; t0=$SECONDS
( cd "$T/work" && CLAUDE_LOCAL_DRYRUN=1 "$REPO/bin/claude-local-vscode" "$BUND" --setting-sources user workspace-trust --json >/dev/null 2>&1 )
( cd "$T/work" && CLAUDE_CODE_CONFIG_PROBE=1 CLAUDE_LOCAL_DRYRUN=1 "$REPO/bin/claude-local-vscode" "$BUND" --output-format stream-json >/dev/null 2>&1 )
(( SECONDS - t0 < 5 )) && ok "служебные запросы VS Code не ждут загрузку модели ($((SECONDS - t0)) с)" || bad "служебные запросы ждали модель $((SECONDS - t0)) с"
wait $holder

# killed mid-load: the load completes, the retry finds the model ready (one load only)
rm -f "$T/state/loaded" "$T/state/log"
FAKE_LOAD_SECS=5 "$CL" --lab --preload >/dev/null 2>&1 & p=$!; sleep 1.5
kill -TERM $p; wait $p; rc=$?
FAKE_LOAD_SECS=5 "$CL" --lab --preload >/dev/null 2>&1; rc2=$?
n=$(grep -c " lms load " "$T/state/log")
[[ $n -eq 1 && $rc2 -eq 0 ]] && ok "прерванная загрузка доведена до конца, повтор не грузит второй раз" || bad "загрузок: $n (ожидалась 1), rc1=$rc rc2=$rc2"

kill $srv 2>/dev/null; /bin/rm -rf "$T"
print "=== lease tests: $fail ❌"; exit $fail
