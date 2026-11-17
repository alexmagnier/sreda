#!/bin/bash
# Build, install to /Applications/Остров.app, set up LaunchAgent and Claude Code hook.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="local.claude-kit.island"
DEST="/Applications/Остров.app"          # /Applications: Spotlight ranks it as an app, Launchpad shows it
BACKUP="$HOME/Library/Caches/island-build/backup"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# 1. Signing: ad-hoc by default. A self-signed identity can't be created unattended — codesign needs a
#    keychain "Allow" dialog (tried 2026-11-16). For permissions that survive rebuilds, create a
#    code-signing certificate once in Keychain Access and run: ISLAND_SIGN_IDENTITY="<name>" scripts/install.sh

# 2. Build
"$ROOT/scripts/build.sh"
APP="$HOME/Library/Caches/island-build/Остров.app"

# 3. Install (backup previous)
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
UID_=$(id -u)
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
# Backups live in the cache, not next to the app (a second «Остров» in Spotlight confuses).
mkdir -p "$BACKUP"
if [ -d "$DEST" ]; then
    rm -rf "$BACKUP/Остров.app"; mv "$DEST" "$BACKUP/Остров.app"
fi
cp -R "$APP" "$DEST"
/usr/bin/mdimport "$DEST" 2>/dev/null || true      # index right away for Spotlight

# 4. LaunchAgent
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/Island</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PL
launchctl bootstrap "gui/$UID_" "$PLIST"

# 5. Hook
mkdir -p "$HOME/.claude-island"
cp "$ROOT/hook/island-hook.py" "$HOME/.claude-island/hook.py"
chmod 700 "$HOME/.claude-island/hook.py"
/usr/bin/python3 "$ROOT/scripts/install_hook.py"
echo "Installed: $DEST"
