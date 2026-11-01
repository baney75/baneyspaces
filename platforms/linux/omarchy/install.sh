#!/usr/bin/env bash
# Installs BaneySpaces on an Omarchy/Hyprland seat: the binary, the pinned hands engine, the key
# bindings include and the daemon's autostart. Everything it changes is backed up first and
# `uninstall.sh` puts it back. `--dry-run` prints what would happen and changes nothing.
#
#   install.sh [--dry-run] [--no-binary] [--bin DIR] [--src DIR]
#
# It edits one file of yours, ~/.config/hypr/hyprland.lua, by appending a marked block. Your
# bindings.lua is not touched: the include unbinds Omarchy's Super+1-9 (and the other keys listed in
# spec/keys.json) and binds them to `baneyspaces`. Nothing is applied until Hyprland reloads
# (the script never reloads it; run `hyprctl reload` yourself, or log in again).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/../../.." && pwd)"
DRY=0; BINARY=1; BIN_DIR="$HOME/.local/bin"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1;;
    --no-binary) BINARY=0;;
    --bin) BIN_DIR="$2"; shift;;
    --src) SRC="$2"; shift;;
    -h|--help) sed -n '2,12p' "$0"; exit 0;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac; shift
done

CONF="$HOME/.config/hypr"
MAIN="$CONF/hyprland.lua"
DEST="$CONF/baneyspaces"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/baneyspaces"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/baneyspaces"
BEGIN="-- >>> baneyspaces (managed by baneyspaces install.sh) >>>"
END="-- <<< baneyspaces <<<"

say() { printf '%s%s\n' "$([ "$DRY" = 1 ] && echo '[dry-run] ')" "$*"; }
do_() { if [ "$DRY" = 1 ]; then say "$*"; else eval "$@"; fi; }

[ -f "$MAIN" ] || { echo "no $MAIN: is this an Omarchy (Hyprland Lua) seat?" >&2; exit 1; }
for f in baneyspaces.lua baneyspaces-autostart.lua; do [ -f "$HERE/$f" ] || { echo "missing $HERE/$f" >&2; exit 1; }; done
if grep -qF -- "$BEGIN" "$MAIN"; then say "already installed in $MAIN (the block is there); refreshing files only"; ALREADY=1; else ALREADY=0; fi

# The include binds Super+1-9 and more to the binary by absolute path (Hyprland's session PATH may not
# have its directory), and it unbinds Omarchy's own keys. So nothing is changed unless the binary will
# be there: installed by this run, or already installed.
case "$BIN_DIR" in /*) ;; *) BIN_DIR="$(readlink -f "$BIN_DIR")";; esac
BIN_ABS="$BIN_DIR/baneyspaces"
case "$BIN_ABS" in *[\"\\\&\|\'\ ]*) echo "refusing: the binary path $BIN_ABS has a character that cannot go in the include (quote, backslash, ampersand, pipe or space)" >&2; exit 1;; esac
BUILT=""
if [ "$BINARY" = 1 ]; then
  BUILT="$SRC/target/release/baneyspaces"; [ -x "$BUILT" ] || BUILT="$SRC/target/debug/baneyspaces"; [ -x "$BUILT" ] || BUILT=""
fi
if [ -z "$BUILT" ] && [ ! -x "$BIN_ABS" ]; then
  echo "refusing to change hyprland.lua: there is no baneyspaces binary to bind the keys to." >&2
  echo "  Build it (cargo build --release -p baneyspaces-linux) and run this again, or install it at $BIN_ABS (--bin DIR)." >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$STATE/backup/$STAMP"
say "keys replaced: $(grep -c '^hl.unbind' "$HERE/baneyspaces.lua") unbinds, $(grep -c '^hl.bind' "$HERE/baneyspaces.lua") bindings (see $HERE/baneyspaces.lua)"
if [ "$ALREADY" = 0 ]; then
  # Only the first install backs up: a later one would copy a file that already has the block.
  say "backup of $MAIN -> $BACKUP/hyprland.lua"
  do_ "mkdir -p '$BACKUP' && cp -p '$MAIN' '$BACKUP/hyprland.lua'"
  # What the keys did before, for the record: Omarchy's binding table, if Hyprland is reachable.
  if command -v hyprctl >/dev/null && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && [ "$DRY" = 0 ]; then
    hyprctl -j binds > "$BACKUP/binds-before.json" 2>/dev/null || true
  fi
fi

say "include files -> $DEST"
do_ "mkdir -p '$DEST'"
for f in baneyspaces.lua baneyspaces-autostart.lua; do
  say "  $f (commands run $BIN_ABS)"
  if [ "$DRY" = 0 ]; then
    sed "s|exec_cmd(\"baneyspaces |exec_cmd(\"$BIN_ABS |" "$HERE/$f" > "$DEST/$f"
  fi
done

if [ "$ALREADY" = 0 ]; then
  say "append the include block to $MAIN"
  if [ "$DRY" = 0 ]; then
    {
      printf '\n%s\n' "$BEGIN"
      printf '%s\n' 'dofile(os.getenv("HOME") .. "/.config/hypr/baneyspaces/baneyspaces.lua")'
      printf '%s\n' 'dofile(os.getenv("HOME") .. "/.config/hypr/baneyspaces/baneyspaces-autostart.lua")'
      printf '%s\n' "$END"
    } >> "$MAIN"
  fi
fi

if [ "$BINARY" = 1 ]; then
  if [ -n "$BUILT" ]; then
    say "binary -> $BIN_ABS"
    do_ "mkdir -p '$BIN_DIR' && install -m 755 '$BUILT' '$BIN_ABS'"
  fi
  if [ -x "$SRC/platforms/linux/engine/agent-desktop" ]; then
    say "hands engine (agent-desktop $(cat "$SRC/platforms/linux/engine/COMMIT" 2>/dev/null | cut -c1-7)) -> $SHARE/engine"
    do_ "mkdir -p '$SHARE/engine' && cp -r '$SRC/platforms/linux/engine/.' '$SHARE/engine/'"
  else
    say "no hands engine built (platforms/linux/scripts/build-engine.sh); agent hands will report engine_missing"
  fi
fi

say "manifest -> $STATE/install.json"
if [ "$DRY" = 0 ] && [ "$ALREADY" = 0 ]; then
  mkdir -p "$STATE"
  printf '{"installed":"%s","backup":"%s","main":"%s","include":"%s"}\n' "$STAMP" "$BACKUP" "$MAIN" "$DEST" > "$STATE/install.json"
fi
say "done. Hyprland has not been reloaded. Run: hyprctl reload && hyprctl configerrors"
say "the reload starts the daemon (the autostart file hooks config.reloaded); until it is up the workspace keys use Hyprland's own dispatch"
