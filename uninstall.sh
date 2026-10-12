#!/bin/bash
# Removes BaneySpaces from this Mac:
#   curl -fsSL https://raw.githubusercontent.com/baney75/baneyspaces/main/uninstall.sh | bash
# Quitting first brings every hidden window and app back on screen.
set -euo pipefail
bold=$(tput bold 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
step() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
APP="$HOME/Applications/BaneySpaces.app"
DATA="$HOME/Library/Application Support/BaneySpaces"

step "Quitting BaneySpaces (it puts every window back first)"
osascript -e 'tell application id "com.baney.baneyspaces" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 75); do pgrep -f "BaneySpaces.app/Contents/MacOS/BaneySpaces" >/dev/null || break; sleep 0.2; done
# Its saved window positions are deleted below, so it must be gone first or a hidden window
# could lose its place.
if pgrep -f "BaneySpaces.app/Contents/MacOS/BaneySpaces" >/dev/null; then
  echo "BaneySpaces is still running. Quit it from its menu bar icon, then run this again." >&2
  exit 1
fi

# Screenshot shortcuts that setup's Free Them switched off go back on.
if [ -x "$APP/Contents/MacOS/BaneySpaces" ]; then
  step "Turning macOS's screenshot and Spotlight shortcuts back on (if BaneySpaces turned them off)"
  "$APP/Contents/MacOS/BaneySpaces" --restore-shortcuts >/dev/null 2>&1 || true
  # Quitting already brings the macOS Dock back; this covers a crash that didn't.
  "$APP/Contents/MacOS/BaneySpaces" --restore-dock >/dev/null 2>&1 || true
fi

# Without the app (already in the Trash), still undo the Workspace Dock's Dock setting.
if [ "$(defaults read com.apple.dock autohide-delay 2>/dev/null)" = "1000" ]; then
  step "Bringing the macOS Dock back"
  defaults delete com.apple.dock autohide-delay
  killall Dock 2>/dev/null || true
fi

step "Removing the app"
# Open at Login belongs to the app itself, so it goes away with it.
rm -rf "$APP"

step "Removing settings and the local signing key"
if [ -f "$DATA/Signing/baneyspaces-signing.keychain-db" ]; then
  security delete-keychain "$DATA/Signing/baneyspaces-signing.keychain-db" 2>/dev/null || true
fi
rm -rf "$DATA"
defaults delete com.baney.baneyspaces >/dev/null 2>&1 || true

step "Removing its Accessibility permission"
# A fresh install gets a new signature; an old entry left here would show "on" but not work.
tccutil reset Accessibility com.baney.baneyspaces >/dev/null 2>&1 || true

echo
printf '%sBaneySpaces is removed.%s\n' "$bold" "$reset"
echo "Its permission, settings and login item are gone too."
