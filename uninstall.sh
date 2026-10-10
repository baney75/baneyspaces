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
for _ in $(seq 1 50); do pgrep -f "BaneySpaces.app/Contents/MacOS/BaneySpaces" >/dev/null || break; sleep 0.2; done

step "Removing the app"
# Open at Login belongs to the app itself, so it goes away with it.
rm -rf "$APP"

step "Removing settings and the local signing key"
if [ -f "$DATA/Signing/baneyspaces-signing.keychain-db" ]; then
  security delete-keychain "$DATA/Signing/baneyspaces-signing.keychain-db" 2>/dev/null || true
fi
rm -rf "$DATA"
defaults delete com.baney.baneyspaces >/dev/null 2>&1 || true

echo
printf '%sBaneySpaces is removed.%s\n' "$bold" "$reset"
echo "You can also remove it from System Settings > Privacy & Security > Accessibility."
echo "If you freed ⌘⇧3, ⌘⇧4 or ⌘⇧5 in setup, turn the screenshot shortcuts back on in"
echo "System Settings > Keyboard > Keyboard Shortcuts > Screenshots."
