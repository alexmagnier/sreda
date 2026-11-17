#!/bin/bash
# Remove LaunchAgent, app and hook entries. Keeps ~/.claude-island unless --purge.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="local.claude-kit.island"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "/Applications/Остров.app"
/usr/bin/python3 "$ROOT/scripts/install_hook.py" --uninstall
if [ "${1:-}" = "--purge" ]; then rm -rf "$HOME/.claude-island"; echo "Purged ~/.claude-island"; fi
echo "Island uninstalled."
