#!/bin/zsh
# install.sh — (re)build the claude-local config dirs from this repo. Safe to re-run any time.
#   ./install.sh               install / repair
#   ./install.sh --uninstall   remove the harness (LM Studio and models are kept)
#
# Two config dirs, never shared, so history/resume can't carry client data into an online session:
#   ~/.claude-local      offline sessions (client files) + pinned Claude Code binary
#   ~/.claude-local-net  sessions with internet (--web, claude-lab)
# Each holds only symlinks to this repo + Claude Code's own runtime state. Policy is passed at
# launch (--settings), so nothing here is a hand-edited copy.

setopt ERR_EXIT NO_UNSET PIPE_FAIL
REPO="${0:A:h}"
CONFS=("$HOME/.claude-local" "$HOME/.claude-local-net")
BIN_DIR="$HOME/.local/bin"
ZSHRC="$HOME/.zshrc"
MARK_BEGIN="# >>> claude-local >>>"
MARK_END="# <<< claude-local <<<"

# Add or remove ONLY our exact 3-line PATH block in ~/.zshrc, with a dated backup first.
# A symlinked ~/.zshrc (dotfiles repo) is edited through the link, never replaced by a plain file.
zshrc_block() {   # add | remove
  /usr/bin/python3 -I - "$1" "$ZSHRC" "$MARK_BEGIN" "$MARK_END" <<'PY'
import os, shutil, sys, time
action, path, begin, end = sys.argv[1:]
block = [begin, 'export PATH="$HOME/.local/bin:$PATH"', end]
real = os.path.realpath(path)
lines = open(real, encoding="utf-8").read().split("\n") if os.path.exists(real) else []
idx = [i for i in range(len(lines) - 2) if lines[i:i + 3] == block]
if action == "add" and idx:
    sys.exit(0)
if action == "remove" and not idx:
    if any(l.strip() == begin for l in lines):
        print(f"⚠ в {path} найдена метка claude-local, но блок изменён вручную — не трогаю, удали сам", file=sys.stderr)
    sys.exit(0)
if os.path.exists(real):
    shutil.copy2(real, real + ".bak-claude-local-" + time.strftime("%Y%m%d-%H%M%S"))
if action == "add":
    if lines and lines[-1] != "":
        lines.append("")
    lines += [""] + block + [""]
else:
    i = idx[0]
    del lines[i:i + 3]
open(real, "w", encoding="utf-8").write("\n".join(lines))
PY
}

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$BIN_DIR/claude-local" "$BIN_DIR/claude-lab" "$BIN_DIR/local-vscode"
  rm -rf "/Applications/Локальный Claude.app" "/Applications/Лаборатория Claude.app"
  # VS Code instances: their workspace storage may hold client file names/unsaved buffers — set aside, not deleted
  vs="$HOME/Library/Application Support/claude-local-vscode"
  [[ -d "$vs" ]] && mv "$vs" "$vs.removed-$(date +%Y%m%d-%H%M%S)"
  zshrc_block remove
  ts=$(date +%Y%m%d-%H%M%S)
  for c in $CONFS; do [[ -d "$c" ]] && mv "$c" "$c.removed-$ts"; done
  print "Харнесс удалён. История сессий отложена в ~/.claude-local*.removed-$ts (удали вручную,"
  print "там клиентские данные). LM Studio и модели не тронуты (удалить: приложение LM Studio и папка ~/.lmstudio)."
  exit 0
fi

chmod +x "$REPO/bin/claude-local" "$REPO/bin/local-vscode" "$REPO/bin/statusline.sh" "$REPO/mcp/web-tools.mjs" 2>/dev/null || true
ln -sfn claude-local "$REPO/bin/claude-local-vscode"      # VS Code wrappers (name selects the mode)
ln -sfn claude-local "$REPO/bin/claude-lab-vscode"
chmod +x "$REPO/tests/"*.sh 2>/dev/null || true
mkdir -p "$BIN_DIR"

# Absolute paths inside the JSON configs: this repo (status line, web MCP server) and node.
# node must live outside $HOME (Homebrew): the online sandbox closes the home folder, so ~/.nvm node would not start.
NODE=""; for n in /opt/homebrew/bin/node /usr/local/bin/node; do [[ -x "$n" ]] && { NODE=$n; break; }; done
[[ -n "$NODE" ]] || print -u2 "⚠ node не найден в /opt/homebrew/bin или /usr/local/bin — веб-поиск Лаборатории не заработает. Установи: brew install node"
/usr/bin/python3 -I - "$REPO" "${NODE:-/opt/homebrew/bin/node}" <<'PY'
import json, os, re, shlex, sys
repo, node = sys.argv[1], sys.argv[2]
q = lambda v: json.dumps(v, ensure_ascii=False)
def fix(m):
    full = os.path.join(repo, m.group(1))
    return q(shlex.quote(full) if m.group(1).startswith("bin/") else full)   # statusLine runs via a shell
for name in ("policy-offline.json", "policy-net.json", "mcp-net.json"):
    p = os.path.join(repo, "config", name)
    s = open(p, encoding="utf-8").read()
    s2 = re.sub(r'"[^"]*/(bin/statusline\.sh|mcp/web-tools\.mjs)\'?"', fix, s)
    s2 = re.sub(r'"command": "[^"]*/node"', lambda m: '"command": ' + q(node), s2)
    json.loads(s2)                                   # never write a broken config
    if s2 != s:
        open(p, "w", encoding="utf-8").write(s2)
PY

for CONF in $CONFS; do
  mkdir -p "$CONF/skills" "$CONF/secrets"; chmod 700 "$CONF/secrets"
  chmod 700 "$CONF"
  # old layout (before 2026-11-16 18:50) kept policy as symlinks — remove them
  rm -f "$CONF"/settings-offline.json(N) "$CONF"/settings-web.json(N) "$CONF"/mcp-*.json(N)
  [[ -L "$CONF/settings.json" ]] && rm -f "$CONF/settings.json"

  ln -sfn "$REPO/config/CLAUDE.md" "$CONF/CLAUDE.md"

  # skills → symlinks rebuilt from skills.list
  find "$CONF/skills" -maxdepth 1 -type l -delete
  while IFS= read -r line; do
    [[ -z "${line// }" || "$line" == \#* ]] && continue
    name="${line%% *}"
    src="$HOME/.claude/skills/$name"
    [[ "$line" == *" "* ]] && src="${line#* }"
    if [[ -f "$src/SKILL.md" ]]; then ln -sfn "$src" "$CONF/skills/$name"
    else print -u2 "⚠ скилл не найден, пропущен: $name ($src)"; fi
  done < "$REPO/config/$([[ $CONF == *-net ]] && print skills-net.list || print skills.list)"

  # Claude Code's own state files (it writes to them; we only seed)
  [[ -f "$CONF/.claude.json" ]] || print '{ "hasCompletedOnboarding": true }' > "$CONF/.claude.json"
  [[ -f "$CONF/settings.json" ]] || print '{}' > "$CONF/settings.json"
done

# pinned Claude Code binary (from the VS Code extension) — only if none pinned yet
[[ -x "$HOME/.claude-local/bin/claude" ]] || "$REPO/bin/claude-local" --pin-binary

# commands on PATH
ln -sfn "$REPO/bin/claude-local" "$BIN_DIR/claude-local"
ln -sfn "$REPO/bin/claude-local" "$BIN_DIR/claude-lab"
ln -sfn "$REPO/bin/local-vscode" "$BIN_DIR/local-vscode"
mkdir -p "$HOME/Лаборатория"
# launcher apps in /Applications (Spotlight: «Локальный Claude», «Лаборатория Claude»)
"$REPO/apps/install-apps.sh" || print -u2 "⚠ программы-ярлыки не собраны (apps/install-apps.sh)"
zshrc_block add

print "✔ claude-local установлен"
print "  Скиллов: $(find "$HOME/.claude-local/skills" -maxdepth 1 -type l | wc -l | tr -d ' ')"
print "  Чат в VS Code: ⌘+пробел → «Локальный Claude» (без интернета) или «Лаборатория Claude»"
print "  Терминал: открой новый и набери claude-local --status"
