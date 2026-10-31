#!/bin/bash
# Installs a built BaneySpaces.app into ~/Applications and starts it:
#   scripts/install-app.sh path/to/BaneySpaces.app
# bundle.sh --install runs this on what it just built, and install.sh runs the copy inside the
# downloaded app (Contents/Resources/install-app.sh) on the prebuilt release.
#
# BANEYSPACES_DEST_DIR: install into this folder instead of ~/Applications. This is test mode:
# the running copy, AeroSpace, Ghostdeck, Launch Services and ~/.local/bin are left alone and the
# app isn't opened. Only the copy happens.
# BANEYSPACES_NO_LAUNCH=1: install as usual but don't open the app.
set -euo pipefail
[ $# -eq 1 ] && [ -d "$1" ] || { echo "usage: install-app.sh path/to/BaneySpaces.app" >&2; exit 1; }
APP=$(cd "$1" && pwd)
TEST="${BANEYSPACES_DEST_DIR:-}"
DEST_DIR="${BANEYSPACES_DEST_DIR:-$HOME/Applications}"
DEST="$DEST_DIR/BaneySpaces.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ -z "$TEST" ]; then
  # Quit by bundle ID so BaneySpaces brings every hidden window back before it exits.
  osascript -e 'tell application id "com.baney.baneyspaces" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -f "$DEST/Contents/MacOS/BaneySpaces" >/dev/null || break; sleep 0.2; done
  if pgrep -f "$DEST/Contents/MacOS/BaneySpaces" >/dev/null; then
    echo "BaneySpaces is still running; quit it from the menu bar and run this again." >&2
    exit 1
  fi
  # Two workspace managers on the same keys fight, so AeroSpace steps aside: it quits, it stops
  # opening at login, and its config stops re-adding it. The app itself stays installed.
  # Each change is written down first, so uninstall.sh can put it back.
  STATE="$HOME/Library/Application Support/BaneySpaces"
  mkdir -p "$STATE"
  if [ -f "$HOME/.aerospace.toml" ] && grep -q '^start-at-login *= *true' "$HOME/.aerospace.toml"; then
    touch "$STATE/aerospace-start-at-login"
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
  aero=$(osascript -e 'tell application "System Events" to get the path of login item "AeroSpace"' 2>/dev/null || true)
  [ -n "$aero" ] && printf '%s' "$aero" > "$STATE/aerospace-login-item"
  osascript -e 'tell application "System Events" to delete login item "AeroSpace"' >/dev/null 2>&1 || true
  if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q AeroSpace; then
    echo "warning: AeroSpace is still a login item; remove it in System Settings › General › Login Items." >&2
  fi
fi

rm -rf "$DEST"
mkdir -p "$DEST_DIR"
cp -R "$APP" "$DEST"

if [ -n "$TEST" ]; then
  echo "installed $DEST (test mode: nothing else changed)"
  exit 0
fi

"$LSREGISTER" -f "$DEST"
"$LSREGISTER" -u "$APP" 2>/dev/null || true
# The Deck replaces Ghostdeck, its standalone predecessor: two sidebars on the same windows would
# fight. Ghostdeck quits and goes to the Trash (recoverable), and its command name now runs ours.
osascript -e 'tell application id "com.baney.ghostdeck" to quit' >/dev/null 2>&1 || true
if [ -d "$HOME/Applications/Ghostdeck.app" ]; then
  for _ in $(seq 1 25); do pgrep -f "Ghostdeck.app/Contents/MacOS/Ghostdeck" >/dev/null || break; sleep 0.2; done
  mv "$HOME/Applications/Ghostdeck.app" "$HOME/.Trash/Ghostdeck-$(date +%Y%m%d-%H%M%S).app"
  echo "moved Ghostdeck.app to the Trash; the Deck in BaneySpaces replaces it"
fi
mkdir -p "$HOME/.local/bin"
ln -sf "$DEST/Contents/Resources/bin/baneyspaces" "$HOME/.local/bin/baneyspaces"
ln -sf "$DEST/Contents/Resources/bin/baneyspaces" "$HOME/.local/bin/ghostdeck"
[ "${BANEYSPACES_NO_LAUNCH:-}" = 1 ] || open "$DEST"
echo "installed $DEST and ~/.local/bin/baneyspaces"
