#!/usr/bin/env bash
# Removes what install.sh added and leaves ~/.config/hypr/hyprland.lua as it was. `--dry-run`
# prints what would happen. Omarchy's own bindings come back on the next Hyprland reload, because
# the include that unbound them is gone. `--purge` also removes the binary, the engine and the
# state (state.json, the action log, backups).
set -euo pipefail
DRY=0; PURGE=0; BIN_DIR="$HOME/.local/bin"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1;; --purge) PURGE=1;; --bin) BIN_DIR="$2"; shift;;
    -h|--help) sed -n '2,7p' "$0"; exit 0;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac; shift
done
CONF="$HOME/.config/hypr"; MAIN="$CONF/hyprland.lua"; DEST="$CONF/baneyspaces"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/baneyspaces"; SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/baneyspaces"
BEGIN="-- >>> baneyspaces (managed by baneyspaces install.sh) >>>"; END="-- <<< baneyspaces <<<"
say() { printf '%s%s\n' "$([ "$DRY" = 1 ] && echo '[dry-run] ')" "$*"; }
do_() { if [ "$DRY" = 1 ]; then say "$*"; else eval "$@"; fi; }

if [ -f "$MAIN" ] && grep -qF -- "$BEGIN" "$MAIN"; then
  say "remove the baneyspaces block from $MAIN"
  if [ "$DRY" = 0 ]; then
    tmp="$(mktemp)"
    # Drop the block and the blank line install.sh put before it.
    awk -v b="$BEGIN" -v e="$END" '
      { lines[NR] = $0 }
      END {
        skip = 0
        for (i = 1; i <= NR; i++) {
          if (lines[i] == b) { skip = 1; if (i > 1 && lines[i-1] == "" && out > 0 && buf[out] == "") out--; continue }
          if (skip) { if (lines[i] == e) skip = 0; continue }
          buf[++out] = lines[i]
        }
        for (i = 1; i <= out; i++) print buf[i]
      }' "$MAIN" > "$tmp"
    cat "$tmp" > "$MAIN"; rm -f "$tmp"
  fi
else
  say "no baneyspaces block in $MAIN"
fi
say "remove $DEST"
do_ "rm -rf '$DEST'"
if [ "$PURGE" = 1 ]; then
  say "remove $BIN_DIR/baneyspaces, $SHARE and $STATE"
  do_ "rm -f '$BIN_DIR/baneyspaces'; rm -rf '$SHARE' '$STATE'"
else
  say "kept $STATE (backups, state.json, the action log) and the binary; --purge removes them"
fi
say "done. Run: hyprctl reload && hyprctl configerrors   (Omarchy's bindings return)"
