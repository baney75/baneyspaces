#!/bin/bash
# Removes BaneySpaces from this Mac and puts back everything it changed:
#   curl -fsSL https://raw.githubusercontent.com/baney75/baneyspaces/main/uninstall.sh | bash
# Settings > General > Uninstall BaneySpaces runs this same script.
# Quitting first brings every hidden window and app back on screen.
#
# Exits 0 when everything is removed and put back, 2 when everything is removed but something
# couldn't be put back (it says what, and keeps what's needed to finish by hand), 1 when it
# stopped before removing anything.
#
# BANEYSPACES_APP: the app to remove (default ~/Applications/BaneySpaces.app).
# BANEYSPACES_UNINSTALL_TEST=1: for the test only. Commands that touch the real Mac's
# settings, permissions or processes are printed instead of run; files under $HOME still go.
set -euo pipefail
bold=$(tput bold 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
step() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
APP="${BANEYSPACES_APP:-$HOME/Applications/BaneySpaces.app}"
APP="${APP%/}"
DATA="$HOME/Library/Application Support/BaneySpaces"
ID=com.baney.baneyspaces
TEST="${BANEYSPACES_UNINSTALL_TEST:-}"
# The real Mac's settings, permissions and processes: printed instead of run in the test.
# (To the script's own output, past any redirect on the command.)
exec 3>&1
sys() { if [ -n "$TEST" ]; then echo "would run: $*" >&3; else "$@"; fi; }
# What couldn't be put back, for the end.
problems=()
problem() { problems+=("$*"); }
running() {
  [ -z "$TEST" ] || return 1
  pgrep -f "BaneySpaces.app/Contents/MacOS/BaneySpaces" >/dev/null || pgrep -f "$APP/Contents/MacOS/" >/dev/null
}
# Its own settings. The test reads them from a plist file instead (BANEYSPACES_UNINSTALL_PREFS).
pref() {
  if [ -n "$TEST" ]; then [ -n "${BANEYSPACES_UNINSTALL_PREFS:-}" ] && defaults read "$BANEYSPACES_UNINSTALL_PREFS" "$1" 2>/dev/null || true
  else defaults read "$ID" "$1" 2>/dev/null || true; fi
}

step "Quitting BaneySpaces (it puts every window back first)"
sys osascript -e "tell application id \"$ID\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 75); do running || break; sleep 0.2; done
# Its saved window positions are deleted below, so it must be gone first or a hidden window
# could lose its place.
if running; then
  echo "BaneySpaces is still running. Quit it from its menu bar icon, then run this again." >&2
  exit 1
fi
# From here on a failed step doesn't stop the rest: it's listed at the end, and the exit is 2.
set +e
trap 'problem "A step failed (line $LINENO of the uninstaller); the output above says which."' ERR
# Its record of shortcuts it turned off: a list with an id in it, or Spotlight's flag.
shortcuts_off() { pref freedShortcuts | grep -q '[0-9]' || [ "$(pref freedSpotlight)" = 1 ]; }

# The app knows how to undo its own changes to macOS. Already in the Trash still counts.
BIN=""
# The places it's installed; the test stays inside its made-up home.
# Each once: by default $APP is the first of these.
INSTALLED=("$APP")
for app in "$HOME/Applications/BaneySpaces.app" "/Applications/BaneySpaces.app"; do
  [ "$app" = "$APP" ] && continue
  [ "$app" = "/Applications/BaneySpaces.app" ] && [ -n "$TEST" ] && continue
  INSTALLED+=("$app")
done
for app in "${INSTALLED[@]}" "$HOME/.Trash/BaneySpaces"*.app; do
  if [ -x "$app/Contents/MacOS/BaneySpaces" ]; then BIN="$app/Contents/MacOS/BaneySpaces"; break; fi
done

if [ -n "$BIN" ]; then
  # Screenshot and Spotlight shortcuts that setup's Free Them or the launcher switched off go back on.
  step "Turning macOS's screenshot and Spotlight shortcuts back on (if BaneySpaces turned them off)"
  sys "$BIN" --restore-shortcuts >/dev/null 2>&1 || problem "macOS's screenshot or Spotlight shortcuts may still be off: turn them on in System Settings › Keyboard › Keyboard Shortcuts."
  # Quitting already brings the macOS Dock back; this covers a crash that didn't.
  sys "$BIN" --restore-dock >/dev/null 2>&1 || true
  step "Removing it from Login Items"
  sys "$BIN" --unregister-login >/dev/null 2>&1 \
    || problem "BaneySpaces may still be in Login Items: remove it in System Settings › General › Login Items."
elif shortcuts_off; then
  # Without the app the shortcuts can't be written back the way it turned them off, so its
  # record of them stays for the next install to finish the job.
  problem "macOS's screenshot or Spotlight shortcuts are still off (the app was already gone): turn them on in System Settings › Keyboard › Keyboard Shortcuts."
fi

# The Workspace Dock's own Dock settings, if the app wasn't there to put them back. Each goes
# back only if it's still at BaneySpaces' value; a setting changed since is the person's.
if [ -z "$TEST" ] && [ "$(defaults read com.apple.dock autohide-delay 2>/dev/null)" = "1000" ]; then
  step "Bringing the macOS Dock back"
  saved=$(pref systemDockSaved)
  delay=$(printf '%s\n' "$saved" | sed -n 's/.*"autohide-delay" = "\{0,1\}\([0-9.]*\)"\{0,1\};.*/\1/p')
  if [ -n "$delay" ]; then defaults write com.apple.dock autohide-delay -float "$delay"; else defaults delete com.apple.dock autohide-delay; fi
  if [ "$(defaults read com.apple.dock autohide 2>/dev/null)" = "1" ]; then
    hide=$(printf '%s\n' "$saved" | sed -n 's/.*[^-]autohide = "\{0,1\}\([01]\)"\{0,1\};.*/\1/p')
    if [ -n "$hide" ]; then defaults write com.apple.dock autohide -bool "$([ "$hide" = 1 ] && echo true || echo false)"
    else defaults delete com.apple.dock autohide 2>/dev/null || true; fi
  fi
  killall Dock 2>/dev/null || true
fi

# Mission Control for a window dragged to the top, if the app wasn't there to put it back. Only
# a setting still off as BaneySpaces left it goes back to its saved value. Fill-the-screen, which
# builds before 2026-10-28 turned off too, comes back on as the app does it, unless the app
# already gave it back or it was off before BaneySpaces.
# The test reads this Mac's settings as BANEYSPACES_UNINSTALL_MACOS says, not for real.
# BANEYSPACES_UNINSTALL_MACOS_<key> sets one setting; BANEYSPACES_UNINSTALL_MACOS, every other.
macos_pref() {
  if [ -n "$TEST" ]; then v="BANEYSPACES_UNINSTALL_MACOS_$2"; echo "${!v-${BANEYSPACES_UNINSTALL_MACOS:-}}"
  else defaults read "$1" "$2" 2>/dev/null || true; fi
}
top_drag_back() {  # domain key process what
  [ "$(macos_pref "$1" "$2")" = "0" ] || return 0
  step "Putting back $4 for a window dragged to the top"
  was=$(printf '%s\n' "$saved" | sed -n "s|.*\"$1/$2\" = \([01]\);.*|\1|p")
  if [ -n "$was" ]; then sys defaults write "$1" "$2" -bool "$([ "$was" = 1 ] && echo true || echo false)"
  else sys defaults delete "$1" "$2" 2>/dev/null || true; fi
  sys killall "$3" 2>/dev/null || true
}
saved=$(pref systemTopDragSaved)
if [ -n "$saved" ]; then
  top_drag_back com.apple.dock enterMissionControlByTopWindowDrag Dock "Mission Control"
fi
# Still owed when the record is there, or when the app's last try didn't read back.
fill_was=$(printf '%s\n' "$saved" | sed -n 's|.*"com.apple.WindowManager/EnableTopTilingByEdgeDrag" = \([01]\);.*|\1|p')
if { [ -n "$saved" ] || [ "$(pref systemTopDragFillPending)" = 1 ]; } && [ "$(pref systemTopDragFillGivenBack)" != 1 ] \
  && [ "$fill_was" != 0 ] && [ "$(macos_pref com.apple.WindowManager EnableTopTilingByEdgeDrag)" = "0" ]; then
  step "Turning fill-the-screen back on for a window dragged to the top"
  sys defaults write com.apple.WindowManager EnableTopTilingByEdgeDrag -bool true
  sys killall WindowManager 2>/dev/null || true
fi

# AeroSpace: the installer stopped it opening at login so the two don't fight over the same keys.
if [ -f "$DATA/aerospace-start-at-login" ] && [ -f "$HOME/.aerospace.toml" ]; then
  step "Letting AeroSpace open at login again, as it did before"
  sed -i '' 's/^start-at-login *= *false/start-at-login = true/' "$HOME/.aerospace.toml" 2>/dev/null \
    || problem "AeroSpace still won't open at login: set start-at-login = true in ~/.aerospace.toml."
fi
if [ -s "$DATA/aerospace-login-item" ]; then
  item=$(cat "$DATA/aerospace-login-item")
  # Only where it was. Moved or deleted since, it can't be put back, so the person is told.
  if [ -e "$item" ]; then
    sys osascript -e 'on run argv' -e 'tell application "System Events" to make login item at end with properties {path:(item 1 of argv), hidden:false}' -e 'end run' "$item" >/dev/null 2>&1 \
      || problem "AeroSpace isn't back in Login Items: add $item in System Settings › General › Login Items."
  else
    problem "AeroSpace was at $item and isn't any more, so it isn't back in Login Items: add it there yourself if you still use it."
  fi
fi

# The agent hooks the Deck added. Only BaneySpaces' own entries go; every other hook and
# setting stays as it is. With the app gone, the same rule runs here in JavaScript.
CLAUDE="$HOME/.claude/settings.json"
# As the file has it: a double quote around the path is written \" in JSON.
ours="(ghostdeck|baneyspaces)(\\\\?['\"])? +hook +(claude|grok)"
if [ -f "$CLAUDE" ] && grep -Eq "$ours" "$CLAUDE"; then
  step "Removing its hooks from Claude Code's settings (your own hooks stay)"
  had_backup=""; [ -f "$CLAUDE.baneyspaces-backup" ] && had_backup=1
  CLI=""; [ -n "$BIN" ] && CLI="$(dirname "$(dirname "$BIN")")/Resources/bin/baneyspaces"
  # The real CLI edits the real home, so the test uses the JavaScript below.
  if [ -z "$TEST" ] && [ -n "$CLI" ] && [ -x "$CLI" ]; then "$CLI" hooks uninstall >/dev/null 2>&1 || true; fi
  if grep -Eq "$ours" "$CLAUDE"; then
    osascript -l JavaScript - "$CLAUDE" >/dev/null 2>&1 <<'JS' || true
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
  if grep -Eq "$ours" "$CLAUDE"; then
    problem "Claude Code's settings ($CLAUDE) still have hooks that run 'baneyspaces hook': remove those entries by hand."
  fi
  if [ -n "$had_backup" ]; then
    echo "  Your settings from before BaneySpaces are still at $CLAUDE.baneyspaces-backup"
  fi
fi
rm -f "$HOME/.grok/hooks/baneyspaces.json"

step "Removing the baneyspaces command and its agent skill"
for link in "$HOME/.local/bin/baneyspaces" "$HOME/.local/bin/ghostdeck"; do
  # Only the links BaneySpaces made: ones into a BaneySpaces.app, even if it's gone already.
  if [ -L "$link" ]; then
    case "$(readlink "$link")" in *BaneySpaces.app/*) rm -f "$link" ;; esac
  fi
done
rm -rf "$HOME/.claude/skills/baneyspaces"

step "Removing settings and the local signing key"
# On the owner's Mac this keychain holds the key every release is signed with (the pinned
# requirement below names its certificate). That one is moved aside, never deleted. Only the
# certificate's public fingerprint is read; the private key is never touched or printed.
RELEASE_REQUIREMENT='identifier "com.baney.baneyspaces" and certificate leaf = H"d1cfbd7446f84f6c625b9db83c5bf96da33b157e"'
SIGNING_KC="$DATA/Signing/baneyspaces-signing.keychain-db"
KEEP_SIGNING=""
if [ -f "$SIGNING_KC" ]; then
  release_leaf=${RELEASE_REQUIREMENT##*H\"}; release_leaf=$(printf '%s' "${release_leaf%\"}" | tr 'A-F' 'a-f')
  local_leaf=$(security find-certificate -c "BaneySpaces Local Signing" -Z "$SIGNING_KC" 2>/dev/null \
    | sed -n 's/^SHA-1 hash: *//p' | head -1 | tr 'A-F' 'a-f')
  if [ -n "$local_leaf" ] && [ "$local_leaf" = "$release_leaf" ]; then KEEP_SIGNING=1; fi
fi
if [ -n "$KEEP_SIGNING" ]; then
  KEPT="$HOME/Library/BaneySpaces Release Signing"
  [ ! -e "$KEPT" ] || KEPT="$KEPT $(date +%Y%m%d-%H%M%S)"
  if mv "$DATA/Signing" "$KEPT"; then
    echo "Kept the signing key because it signs BaneySpaces releases: moved to $KEPT"
    echo "To sign releases again, put it back at $DATA/Signing."
  else
    problem "The signing key signs BaneySpaces releases and couldn't be moved aside, so it stays in $DATA/Signing."
  fi
elif [ -f "$SIGNING_KC" ]; then
  sys security delete-keychain "$SIGNING_KC" 2>/dev/null || true
fi
if [ -d "$DATA/Signing" ] && [ -n "$KEEP_SIGNING" ]; then
  find "$DATA" -mindepth 1 -maxdepth 1 ! -name Signing -exec rm -rf {} +
else
  rm -rf "$DATA"
fi
rm -rf "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" \
  "$HOME/Library/Saved Application State/$ID.savedState"
# Its record of shortcuts it turned off stays while they're still off, so a reinstall can finish.
if ! shortcuts_off; then
  sys defaults delete "$ID" >/dev/null 2>&1 || true
fi

step "Removing its Accessibility permission"
# A fresh install gets a new signature; an old entry left here would show "on" but not work.
sys tccutil reset Accessibility "$ID" >/dev/null 2>&1 \
  || problem "BaneySpaces may still be listed in System Settings › Privacy & Security › Accessibility: remove it there."

step "Removing the app"
# Last, so a failure here leaves nothing else half done. Open at Login goes with it.
for app in "${INSTALLED[@]}"; do
  rm -rf "$app" 2>/dev/null || true
  if [ -e "$app" ]; then problem "Couldn't remove $app: move it to the Trash yourself."; fi
done

echo
if [ ${#problems[@]} -eq 0 ]; then
  printf '%sBaneySpaces is removed.%s\n' "$bold" "$reset"
  echo "Your windows, Dock, shortcuts and agent settings are back as they were."
  echo "Its permission, settings, login item and command are gone too."
  exit 0
fi
printf '%sBaneySpaces is removed, but some things need a hand:%s\n' "$bold" "$reset"
for p in "${problems[@]}"; do echo "  - $p"; done
exit 2
