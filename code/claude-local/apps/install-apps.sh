#!/bin/zsh
# Builds «Локальный Claude.app» and «Лаборатория Claude.app» into /Applications (Spotlight, Launchpad, Dock).
# Each is a tiny AppleScript applet that runs bin/local-vscode work|lab [dropped folder/file].
setopt ERR_EXIT NO_UNSET
here="${0:A:h}"
build() {   # $1 work|lab  $2 name  $3 bundle id
  local src="$here/$1.applescript" dst="/Applications/$2.app" tmp="${TMPDIR:-/tmp}/applet-$1-$$.app"
  rm -rf "$tmp"
  osacompile -o "$tmp" "$src"
  cp "$here/$1.icns" "$tmp/Contents/Resources/applet.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $3" "$tmp/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $3" "$tmp/Contents/Info.plist"
  # accept dropped folders too (default applet types cover files only)
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeOSTypes:1 string fold" "$tmp/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" "$tmp/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string public.folder" "$tmp/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:1 string public.item" "$tmp/Contents/Info.plist" 2>/dev/null || true
  rm -f "$tmp/Contents/Resources/Assets.car"          # otherwise the default applet icon wins
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$tmp/Contents/Info.plist" 2>/dev/null || true
  codesign --force --sign - "$tmp" >/dev/null 2>&1 || true
  rm -rf "$dst"; mv "$tmp" "$dst"
  touch "$dst"; /usr/bin/mdimport "$dst" 2>/dev/null || true
  print "✔ $dst"
}
build work "Локальный Claude"   local.claude-kit.work
build lab  "Лаборатория Claude" local.claude-kit.lab
