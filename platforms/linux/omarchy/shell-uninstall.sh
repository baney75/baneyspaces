#!/usr/bin/env bash
# Removes the BaneySpaces shell plugin and its shell.json entry. If shell.json is exactly as shell-install.sh
# left it, the backup comes back byte for byte; otherwise only the entry is removed. config.toml stays.
#   shell-uninstall.sh [--dry-run] [--via-omarchy]
set -euo pipefail
DRY=0; VIA=0
while [ $# -gt 0 ]; do case "$1" in --dry-run) DRY=1;; --via-omarchy) VIA=1;; -h|--help) sed -n '2,5p' "$0"; exit 0;; *) echo "unknown option $1" >&2; exit 2;; esac; shift; done
ID="io.github.baney75.baneyspaces"
DEST="$HOME/.config/omarchy/plugins/$ID"; SJ="$HOME/.config/omarchy/shell.json"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/baneyspaces"
say() { printf '%s%s\n' "$([ "$DRY" = 1 ] && echo '[dry-run] ')" "$*"; }
do_() { if [ "$DRY" = 1 ]; then say "$*"; else eval "$@"; fi; }
if [ "$VIA" = 1 ]; then
  say "omarchy plugin disable $ID"; do_ "omarchy plugin disable '$ID' || true"
elif [ -f "$SJ" ] && command -v jq >/dev/null && jq -e --arg id "$ID" '(.plugins // []) | map(.id) | index($id) != null' "$SJ" >/dev/null 2>&1; then
  BK="$(cat "$STATE/shell-json.backup" 2>/dev/null || true)"
  UNCHANGED=0; [ "$(sha256sum "$SJ" | cut -d' ' -f1)" = "$(cat "$STATE/shell-json.sha" 2>/dev/null)" ] && UNCHANGED=1
  if [ "$BK" = "absent" ] && [ "$UNCHANGED" = 1 ]; then
    say "remove $SJ (there was none before the install; Omarchy's defaults apply again)"; do_ "rm -f '$SJ'"
  elif [ -n "$BK" ] && [ -f "$BK" ] && [ "$UNCHANGED" = 1 ]; then
    say "restore $SJ from $BK (unchanged since install)"; do_ "cat '$BK' > '$SJ'"
  else
    say "remove the $ID entry from $SJ"
    do_ "tmp=\$(mktemp) && jq --arg id '$ID' '.plugins |= map(select(.id != \$id))' '$SJ' > \"\$tmp\" && cat \"\$tmp\" > '$SJ' && rm -f \"\$tmp\""
  fi
else
  say "no $ID entry in $SJ"
fi
say "remove $DEST"; do_ "rm -rf '$DEST'"
do_ "rm -f '$STATE/shell-json.sha' '$STATE/shell-json.backup'"
