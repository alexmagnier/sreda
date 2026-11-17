#!/bin/zsh
# check-hashes.sh — verify every model weight file against the SHA-256 published on Hugging Face.
# Needs internet once (to read the published hashes). Prints OK / MISMATCH per file; exit 1 on any mismatch.
setopt ERR_EXIT NO_UNSET PIPE_FAIL

REPO_DIR="${0:A:h:h}"
source "$REPO_DIR/config/models.env"
# LM Studio may keep models elsewhere (Settings → models folder = "downloadsFolder")
CUSTOM=$(/usr/bin/python3 -I -c 'import json,os;print(json.load(open(os.path.expanduser("~/.lmstudio/settings.json"))).get("downloadsFolder") or "")' 2>/dev/null || true)
MODELS_DIRS=("$HOME/.lmstudio/models" "$HOME/.lmstudio/originals"); [[ -n "$CUSTOM" ]] && MODELS_DIRS+=("$CUSTOM")
REPOS=(); [[ -n "${WORK_REPO:-}" ]] && REPOS+=("$WORK_REPO"); [[ -n "${LAB_REPO:-}" ]] && REPOS+=("$LAB_REPO")   # empty = role not installed
fail=0
for repo in $REPOS; do
  dir=""; for d in $MODELS_DIRS; do [[ -d "$d/$repo" ]] && dir="$d/$repo"; done
  [[ -n "$dir" ]] || { print "FAIL $repo — папка не найдена ни в одном из: $MODELS_DIRS"; fail=1; continue; }
  checked=0
  expected=$(curl -fsS "https://huggingface.co/api/models/$repo/tree/main?recursive=true" \
    | /usr/bin/python3 -I -c 'import sys,json
for f in json.load(sys.stdin):
    if f.get("type")=="file" and f.get("lfs"): print(f["lfs"]["oid"], f["path"])')
  while read -r sha rel; do
    local_file="$dir/$rel"
    [[ -f "$local_file" ]] || continue          # only files we actually downloaded
    actual=$(/usr/bin/shasum -a 256 "$local_file" | /usr/bin/awk '{print $1}') || actual=""
    checked=$((checked + 1))
    if [[ "$actual" == "$sha" ]]; then print "OK        $repo/$rel"
    else print "MISMATCH  $repo/$rel  ожидалось $sha, получено $actual"; fail=1; fi
  done <<< "$expected"
  (( checked > 0 )) || { print "FAIL $repo — ни один файл весов не совпал по имени с Hugging Face"; fail=1; }
done
exit $fail
