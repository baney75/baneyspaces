#!/bin/bash
# Removes BaneySpaces from this Mac and puts back everything it changed:
#   curl -fsSL https://raw.githubusercontent.com/baney75/baneyspaces/main/uninstall.sh | bash
# Settings > General > Uninstall BaneySpaces runs this same script.
# Quitting first brings every hidden window and app back on screen.
#
# BANEYSPACES_APP: the app to remove (default ~/Applications/BaneySpaces.app).
# BANEYSPACES_UNINSTALL_TEST=1: for the test only. Commands that touch the real Mac's
# settings, permissions or processes are printed instead of run; files under $HOME still go.
set -euo pipefail
bold=$(tput bold 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
step() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
APP="${BANEYSPACES_APP:-$HOME/Applications/BaneySpaces.app}"
DATA="$HOME/Library/Application Support/BaneySpaces"
ID=com.baney.baneyspaces
TEST="${BANEYSPACES_UNINSTALL_TEST:-}"
# The real Mac's settings, permissions and processes: printed instead of run in the test.
# (To the script's own output, past any redirect on the command.)
exec 3>&1
sys() { if [ -n "$TEST" ]; then echo "would run: $*" >&3; else "$@"; fi; }
running() { [ -z "$TEST" ] && pgrep -f "BaneySpaces.app/Contents/MacOS/BaneySpaces" >/dev/null; }

step "Quitting BaneySpaces (it puts every window back first)"
sys osascript -e "tell application id \"$ID\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 75); do running || break; sleep 0.2; done
# Its saved window positions are deleted below, so it must be gone first or a hidden window
# could lose its place.
if running; then
  echo "BaneySpaces is still running. Quit it from its menu bar icon, then run this again." >&2
  exit 1
fi

if [ -x "$APP/Contents/MacOS/BaneySpaces" ]; then
  # Screenshot and Spotlight shortcuts that setup's Free Them or the launcher switched off go back on.
  step "Turning macOS's screenshot and Spotlight shortcuts back on (if BaneySpaces turned them off)"
  sys "$APP/Contents/MacOS/BaneySpaces" --restore-shortcuts >/dev/null 2>&1 || true
  # Quitting already brings the macOS Dock back; this covers a crash that didn't.
  sys "$APP/Contents/MacOS/BaneySpaces" --restore-dock >/dev/null 2>&1 || true
  step "Removing it from Login Items"
  sys "$APP/Contents/MacOS/BaneySpaces" --unregister-login >/dev/null 2>&1 || true
fi

# Without the app (already in the Trash), still undo the Workspace Dock's Dock setting.
if [ -z "$TEST" ] && [ "$(defaults read com.apple.dock autohide-delay 2>/dev/null)" = "1000" ]; then
  step "Bringing the macOS Dock back"
  defaults delete com.apple.dock autohide-delay
  killall Dock 2>/dev/null || true
fi

# The agent hooks the Deck added. Only BaneySpaces' own entries go; every other hook and
# setting stays as it is. With the app gone, the same rule runs here in JavaScript.
CLAUDE="$HOME/.claude/settings.json"
if [ -f "$CLAUDE" ] && grep -Eq "(ghostdeck|baneyspaces)'?\"? +hook +(claude|grok)" "$CLAUDE"; then
  step "Removing its hooks from Claude Code's settings (your own hooks stay)"
  if [ -x "$APP/Contents/Resources/bin/baneyspaces" ]; then
    "$APP/Contents/Resources/bin/baneyspaces" hooks uninstall >/dev/null 2>&1 || true
  fi
  if grep -Eq "(ghostdeck|baneyspaces)'?\"? +hook +(claude|grok)" "$CLAUDE"; then
    osascript -l JavaScript - "$CLAUDE" >/dev/null <<'JS' || echo "  Couldn't edit $CLAUDE; remove the entries that run 'baneyspaces hook' by hand." >&2
ObjC.import('Foundation')
function run(argv) {
  // Through a symlink (settings kept in a dotfiles repo) to the file itself, written in place so
  // its permissions stay.
  const path = $(argv[0]).stringByResolvingSymlinksInPath.js
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js
  const settings = JSON.parse(text)
  const ours = h => /(ghostdeck|baneyspaces)'?"?\s+hook\s+(claude|grok)/.test((h && h.command) || '')
  const hooks = settings.hooks || {}
  for (const event of Object.keys(hooks)) {
    if (!Array.isArray(hooks[event])) continue
    const kept = []
    for (const g of hooks[event]) {
      if (!g || !Array.isArray(g.hooks)) { kept.push(g); continue }
      const rest = g.hooks.filter(h => !ours(h))
      if (rest.length === 0 && g.hooks.length > 0) continue
      g.hooks = rest
      kept.push(g)
    }
    if (kept.length) hooks[event] = kept; else delete hooks[event]
  }
  if (settings.hooks && Object.keys(hooks).length === 0) delete settings.hooks
  if (!$(JSON.stringify(settings, null, 2) + '\n').writeToFileAtomicallyEncodingError(path, false, $.NSUTF8StringEncoding, null)) throw new Error('write failed')
}
JS
  fi
  if [ -f "$CLAUDE.baneyspaces-backup" ]; then
    echo "  Your settings from before BaneySpaces are still at $CLAUDE.baneyspaces-backup"
  fi
fi
rm -f "$HOME/.grok/hooks/baneyspaces.json"

step "Removing the baneyspaces command and its agent skill"
for link in "$HOME/.local/bin/baneyspaces" "$HOME/.local/bin/ghostdeck"; do
  # Only the links BaneySpaces made: into a BaneySpaces.app, or left pointing at nothing.
  if [ -L "$link" ]; then
    case "$(readlink "$link")" in *BaneySpaces.app/*) rm -f "$link" ;; esac
  fi
done
rm -rf "$HOME/.claude/skills/baneyspaces"

step "Removing the app"
rm -rf "$APP"

step "Removing settings and the local signing key"
if [ -f "$DATA/Signing/baneyspaces-signing.keychain-db" ]; then
  sys security delete-keychain "$DATA/Signing/baneyspaces-signing.keychain-db" 2>/dev/null || true
fi
rm -rf "$DATA" "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" \
  "$HOME/Library/Saved Application State/$ID.savedState"
sys defaults delete "$ID" >/dev/null 2>&1 || true

step "Removing its Accessibility permission"
# A fresh install gets a new signature; an old entry left here would show "on" but not work.
sys tccutil reset Accessibility "$ID" >/dev/null 2>&1 || true

echo
printf '%sBaneySpaces is removed.%s\n' "$bold" "$reset"
echo "Your windows, Dock, shortcuts and agent settings are back as they were."
echo "Its permission, settings, login item and command are gone too."
