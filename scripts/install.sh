#!/bin/bash
# Build Release, put it in /Applications under a searchable name and start it.
# The file name carries the words people search with: "tv remote", "mac", "пульт", "apple tv"
# (Spotlight matches the file name, not localized names, so the words go into the name itself).
# Usage: DEVELOPMENT_TEAM=<your team ID> scripts/install.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="TV Remote for Mac – Пульт Apple TV"
BUNDLE_ID="com.lemelson.tvremote"
OLD_BUNDLE_ID="com.itsytv.app"   # copies installed before the rename
DEST="/Applications/$APP_NAME.app"
TEAM="${DEVELOPMENT_TEAM:-86PAVRA5YA}"
BUILT="build/Build/Products/Release/TV Remote for Mac.app"

xcodegen generate
xcodebuild -project itsytv.xcodeproj -scheme itsytv -configuration Release \
  -derivedDataPath build DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Development" build -quiet
codesign --verify --deep --strict "$BUILT"

# Quit the running copy, whatever it is called.
for id in "$BUNDLE_ID" "$OLD_BUNDLE_ID"; do
  osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
done
for _ in 1 2 3 4 5; do pgrep -x "TV Remote for Mac" >/dev/null || pgrep -x Itsytv >/dev/null || break; sleep 1; done
pkill -x "TV Remote for Mac" 2>/dev/null || true
pkill -x Itsytv 2>/dev/null || true

# Move older copies of this app (any name, old or new bundle ID) to the Trash, then install.
for old in /Applications/*.app; do
  id="$(defaults read "$old/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
  [ "$id" = "$BUNDLE_ID" ] || [ "$id" = "$OLD_BUNDLE_ID" ] || continue
  mv "$old" "$HOME/.Trash/$(basename "$old" .app) $(date +%Y%m%d-%H%M%S).app"
done
ditto "$BUILT" "$DEST"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
mdimport "$DEST" || true
open "$DEST"
echo "Installed and started: $DEST ($(defaults read "$DEST/Contents/Info" CFBundleShortVersionString))"
