#!/bin/bash
# Builds BaneySpaces.app (universal: Apple silicon and Intel) into ./build.
#   scripts/bundle.sh            release build
#   scripts/bundle.sh --install  also copy to ~/Applications and start it
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
APP=build/BaneySpaces.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCHS=(--arch arm64)
if xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 && [ "${BANEYSPACES_ARM64_ONLY:-}" != 1 ]; then ARCHS+=(--arch x86_64); fi
swift build -c release "${ARCHS[@]}"
BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)/BaneySpaces
cp "$BIN" "$APP/Contents/MacOS/BaneySpaces"

swift scripts/make-icon.swift build/BaneySpaces.iconset
iconutil -c icns build/BaneySpaces.iconset -o "$APP/Contents/Resources/BaneySpaces.icns"

sed "s/@VERSION@/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
# A stable local identity keeps the Accessibility permission across rebuilds; ad-hoc is the fallback.
if [ "${BANEYSPACES_ADHOC:-}" != 1 ] && IDENT=$(scripts/signing-identity.sh 2>/dev/null); then
  codesign --force --sign "${IDENT%%$'\t'*}" --keychain "${IDENT#*$'\t'}" --identifier com.baney.baneyspaces "$APP"
else
  ADHOC_NOTE="note: signed ad-hoc, so macOS will ask for Accessibility again after each update"
  echo "$ADHOC_NOTE" >&2
  codesign --force --sign - --identifier com.baney.baneyspaces "$APP"
fi
codesign --verify "$APP"
echo "built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/BaneySpaces"))"

if [ "${1:-}" = "--install" ]; then
  DEST="$HOME/Applications/BaneySpaces.app"
  # Quit by bundle ID so BaneySpaces brings every hidden window back before it exits.
  osascript -e 'tell application id "com.baney.baneyspaces" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -f "$DEST/Contents/MacOS/BaneySpaces" >/dev/null || break; sleep 0.2; done
  if pgrep -f "$DEST/Contents/MacOS/BaneySpaces" >/dev/null; then
    echo "BaneySpaces is still running; quit it from the menu bar and run this again." >&2
    exit 1
  fi
  # Two workspace managers on the same keys fight, so AeroSpace steps aside: it quits, it stops
  # opening at login, and its config stops re-adding it. The app itself stays installed.
  if [ -f "$HOME/.aerospace.toml" ] && grep -q '^start-at-login *= *true' "$HOME/.aerospace.toml"; then
    sed -i '' 's/^start-at-login *= *true/start-at-login = false/' "$HOME/.aerospace.toml"
  fi
  if pgrep -xq AeroSpace; then
    osascript -e 'tell application id "bobko.aerospace" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do pgrep -xq AeroSpace || break; sleep 0.2; done
    if pgrep -xq AeroSpace; then
      echo "AeroSpace is still running; quit it from its menu bar icon and run this again." >&2
      exit 1
    fi
  fi
  osascript -e 'tell application "System Events" to delete login item "AeroSpace"' >/dev/null 2>&1 || true
  if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q AeroSpace; then
    echo "warning: AeroSpace is still a login item; remove it in System Settings › General › Login Items." >&2
  fi
  rm -rf "$DEST"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
  open "$DEST"
  echo "installed $DEST"
fi
[ -z "${ADHOC_NOTE:-}" ] || echo "$ADHOC_NOTE"
