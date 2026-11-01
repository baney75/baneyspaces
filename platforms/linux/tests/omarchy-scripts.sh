#!/usr/bin/env bash
# Tests install.sh / uninstall.sh against a throwaway HOME. They never see your real ~/.config.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; OM="$HERE/../omarchy"
T="$(mktemp -d /tmp/bs-omarchy.XXXXXX)"; trap 'rm -rf "$T"' EXIT
# Nothing here may reach a real daemon: its socket lives under XDG_RUNTIME_DIR and the script finds
# the binary on PATH, so both point into the temp dir.
export HOME="$T/home" XDG_RUNTIME_DIR="$T/run" PATH="$T/bin:/usr/bin:/bin"; unset XDG_STATE_HOME XDG_DATA_HOME; mkdir -p "$T/run" "$T/bin"; mkdir -p "$HOME/.config/hypr" "$T/src/target/debug" "$T/src/platforms/linux/engine"
printf '#!/bin/sh\necho "$@" >> "$HOME/stub.calls"\n' > "$T/src/target/debug/baneyspaces"; chmod +x "$T/src/target/debug/baneyspaces"
printf '#!/bin/sh\n' > "$T/src/platforms/linux/engine/agent-desktop"; chmod +x "$T/src/platforms/linux/engine/agent-desktop"
cat > "$HOME/.config/hypr/hyprland.lua" <<'LUA'
dofile((os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua")
require("default.hypr.omarchy")
require("hypr.bindings")
-- my own line
LUA
cp "$HOME/.config/hypr/hyprland.lua" "$T/orig.lua"; ORIG="$(cat "$HOME/.config/hypr/hyprland.lua")"; N=0; F=0
ok() { N=$((N+1)); echo "  ok   $1"; }; no() { N=$((N+1)); F=$((F+1)); echo "  FAIL $1"; }
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi; }
M="$HOME/.config/hypr/hyprland.lua"

# No binary to bind the keys to: nothing at all is changed.
"$OM/install.sh" --no-binary --src "$T/src" >"$T/nobin.out" 2>&1; RC=$?
chk "install without a binary refuses" test "$RC" -ne 0
chk "and leaves hyprland.lua exactly as it was" test "$(cat "$M")" = "$ORIG"
chk "and says why" grep -q 'no baneyspaces binary' "$T/nobin.out"
chk "and copies no include" test ! -e "$HOME/.config/hypr/baneyspaces"
"$OM/install.sh" --dry-run --src "$T/src" >"$T/dry.out" 2>&1
chk "dry-run exits 0 and says it is a dry run" grep -q '^\[dry-run\]' "$T/dry.out"
chk "dry-run changes nothing" test "$(cat "$M")" = "$ORIG"
chk "dry-run creates no files" test ! -e "$HOME/.config/hypr/baneyspaces" -a ! -e "$HOME/.local"
"$OM/uninstall.sh" --dry-run >"$T/udry.out" 2>&1; chk "uninstall dry-run changes nothing" test "$(cat "$M")" = "$ORIG"
chk "uninstall dry-run says it would stop the daemon" grep -q 'dry-run.*stop the baneyspaces daemon' "$T/udry.out"

"$OM/install.sh" --src "$T/src" >"$T/in.out" 2>&1 || { cat "$T/in.out"; no "install ran"; }
chk "the block is appended" grep -qF -- '>>> baneyspaces' "$M"
chk "your own lines are intact" grep -q 'my own line' "$M"
chk "the include is copied" test -f "$HOME/.config/hypr/baneyspaces/baneyspaces.lua"
chk "the autostart is copied and runs the daemon by absolute path" grep -qF "exec_cmd(\"$HOME/.local/bin/baneyspaces daemon\")" "$HOME/.config/hypr/baneyspaces/baneyspaces-autostart.lua"
chk "every bound key (29) and the recovery chord (2 commands) runs the binary by absolute path" test "$(grep -cF "exec_cmd(\"$HOME/.local/bin/baneyspaces " "$HOME/.config/hypr/baneyspaces/baneyspaces.lua")" = 31
chk "no bare baneyspaces command is left in the include" test "$(grep -c 'exec_cmd("baneyspaces ' "$HOME/.config/hypr/baneyspaces/baneyspaces.lua")" = 0
chk "--no-binary works once the binary is installed" "$OM/install.sh" --no-binary --src "$T/src"
chk "the binary is installed" test -x "$HOME/.local/bin/baneyspaces"
chk "the engine is installed" test -x "$HOME/.local/share/baneyspaces/engine/agent-desktop"
chk "a backup of hyprland.lua was taken" sh -c "cmp -s '$M' /dev/null || ls '$HOME'/.local/state/baneyspaces/backup/*/hyprland.lua"
chk "the backup is the original" sh -c "cmp -s '$T/orig.lua' '$HOME'/.local/state/baneyspaces/backup/*/hyprland.lua"
chk "the script never touched bindings.lua" test ! -e "$HOME/.config/hypr/bindings.lua"
"$OM/install.sh" --src "$T/src" >/dev/null 2>&1
chk "a second install adds no second block" test "$(grep -cF -- '>>> baneyspaces' "$M")" = 1

"$OM/uninstall.sh" >/dev/null 2>&1
chk 'uninstall stops the daemon (it ran baneyspaces stop)' grep -qx 'stop' "$HOME/stub.calls"
chk "uninstall restores hyprland.lua byte for byte" cmp -s "$T/orig.lua" "$M"
chk "uninstall removes the include" test ! -e "$HOME/.config/hypr/baneyspaces"
chk "uninstall keeps the state (backups, log) by default" test -d "$HOME/.local/state/baneyspaces"
# A hyprland.lua that does not end in a newline comes back exactly as it was.
printf 'require("hypr.bindings")\n-- my own line, no newline at the end' > "$M"; cp "$M" "$T/orig2.lua"
"$OM/install.sh" --src "$T/src" >/dev/null 2>&1
chk "install on a file with no trailing newline adds the block" grep -qF -- '>>> baneyspaces' "$M"
"$OM/uninstall.sh" >/dev/null 2>&1
chk "uninstall restores a file with no trailing newline byte for byte" cmp -s "$T/orig2.lua" "$M"
printf 'a\n\n' > "$M"; cp "$M" "$T/orig3.lua"; "$OM/install.sh" --src "$T/src" >/dev/null 2>&1; "$OM/uninstall.sh" >/dev/null 2>&1
chk "and a file that ends in a blank line" cmp -s "$T/orig3.lua" "$M"
"$OM/uninstall.sh" --purge >/dev/null 2>&1
chk "--purge removes the binary and the state" sh -c "[ ! -e '$HOME/.local/bin/baneyspaces' ] && [ ! -e '$HOME/.local/state/baneyspaces' ]"
echo "passed $((N-F)), failed $F"; [ "$F" = 0 ] && echo "PASS: omarchy-scripts.sh ($N checks)" || { echo "FAIL: omarchy-scripts.sh"; exit 1; }
