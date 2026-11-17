#!/bin/bash
# Builds «Остров.app» OUTSIDE the source folder (it may be synced): ~/Library/Caches/island-build/Остров.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$HOME/Library/Caches/island-build"
APP="$CACHE/Остров.app"   # Russian bundle name: Spotlight finds the APP by «Остров», not mail about islands
rm -rf "$CACHE/Island.app"
cd "$ROOT"

swift build -c release --scratch-path "$CACHE"
BIN="$(swift build -c release --scratch-path "$CACHE" --show-bin-path)/Island"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Island"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

find "$APP" -name '*.cstemp' -delete 2>/dev/null || true        # leftovers of an interrupted codesign
if [ -n "${ISLAND_SIGN_IDENTITY:-}" ] \
   && perl -e 'alarm 30; exec @ARGV' codesign --force --sign "$ISLAND_SIGN_IDENTITY" --identifier local.claude-kit.island "$APP"; then
    echo "Signed with: $ISLAND_SIGN_IDENTITY"
else
    find "$APP" -name '*.cstemp' -delete 2>/dev/null || true
    codesign --force --sign - --identifier local.claude-kit.island "$APP"
    echo "NOTE: signed ad-hoc — macOS permissions (Accessibility/Screen Recording) must be re-granted after a rebuild."
fi
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|Authority" || true
codesign --verify --verbose "$APP"

rm -rf "$ROOT/.build"          # keep the synced folder free of build churn
echo "Built: $APP"
