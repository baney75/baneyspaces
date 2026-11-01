#!/usr/bin/env bash
# Registers the BaneySpaces shell plugin (dock, Alt+Tab switcher, launcher, overview, settings) with the
# Omarchy shell. install.sh runs it; run it alone to refresh the plugin. `--dry-run` prints and changes nothing.
#
#   shell-install.sh [--dry-run] [--via-omarchy]
#
# What it does: copies the plugin to ~/.config/omarchy/plugins/io.github.baney75.baneyspaces/ (the shell
# reloads plugin code when files there change), and adds {"id": "<plugin>"} to "plugins" in
# ~/.config/omarchy/shell.json (a third-party plugin is enabled when its id is in that file; the shell
# hot-reloads it). shell.json is backed up first. It never restarts the shell. `--via-omarchy` uses
# `omarchy plugin enable` instead of editing the file, which needs the shell running in this session.
# The key bindings (Super+Space, Alt+Tab, ...) come from baneyspaces.lua, installed by install.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0; VIA=0
while [ $# -gt 0 ]; do case "$1" in --dry-run) DRY=1;; --via-omarchy) VIA=1;; -h|--help) sed -n '2,12p' "$0"; exit 0;; *) echo "unknown option $1" >&2; exit 2;; esac; shift; done

ID="io.github.baney75.baneyspaces"
SRC="$HERE/plugins/$ID"
DEST="$HOME/.config/omarchy/plugins/$ID"
SJ="$HOME/.config/omarchy/shell.json"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/baneyspaces"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/baneyspaces/config.toml"
OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
say() { printf '%s%s\n' "$([ "$DRY" = 1 ] && echo '[dry-run] ')" "$*"; }
do_() { if [ "$DRY" = 1 ]; then say "$*"; else eval "$@"; fi; }

[ -f "$SRC/manifest.json" ] || { echo "missing $SRC/manifest.json" >&2; exit 1; }
if [ "$VIA" = 0 ]; then command -v jq >/dev/null || { echo "jq is needed to edit shell.json (or use --via-omarchy)" >&2; exit 1; }; fi

say "plugin -> $DEST"
do_ "mkdir -p '$(dirname "$DEST")' && rm -rf '$DEST' && cp -r '$SRC' '$DEST'"

if [ "$VIA" = 1 ]; then
  say "omarchy plugin enable $ID   (needs the shell running in this session)"
  do_ "omarchy-shell shell rescanPlugins >/dev/null && omarchy plugin enable '$ID'"
else
  STAMP="$(date +%Y%m%d-%H%M%S)"; BK="$STATE/backup/$STAMP"
  if [ -f "$SJ" ] && jq -e --arg id "$ID" '(.plugins // []) | map(.id) | index($id) != null' "$SJ" >/dev/null 2>&1; then
    say "$ID is already in $SJ"
  else
    HAD=0
    if [ -f "$SJ" ]; then
      HAD=1
      say "backup of $SJ -> $BK/shell.json"
      do_ "mkdir -p '$BK' && cp -p '$SJ' '$BK/shell.json'"
      BASE="$SJ"
    else
      # shell.json is authoritative once it exists: start from Omarchy's defaults, never from an empty file.
      say "no $SJ yet: starting from Omarchy's defaults"
      BASE="$OMARCHY_PATH/config/omarchy/shell.json"; [ -f "$BASE" ] || BASE=""
    fi
    say "add {\"id\": \"$ID\"} to \"plugins\" in $SJ"
    if [ "$DRY" = 0 ]; then
      mkdir -p "$(dirname "$SJ")"
      tmp="$(mktemp)"
      if [ -n "$BASE" ]; then jq --arg id "$ID" '.plugins = ((.plugins // []) + [{"id": $id}])' "$BASE" > "$tmp"
      else jq -n --arg id "$ID" '{version: 1, plugins: [{id: $id}]}' > "$tmp"; fi
      cat "$tmp" > "$SJ"; rm -f "$tmp"
      mkdir -p "$STATE"; sha256sum "$SJ" | cut -d' ' -f1 > "$STATE/shell-json.sha"
      # There was no shell.json before this run: say so, so that uninstall removes the file instead of leaving a copy of
      # Omarchy's defaults that later Omarchy updates would no longer reach.
      if [ "$HAD" = 1 ]; then echo "$BK/shell.json" > "$STATE/shell-json.backup"; else echo "absent" > "$STATE/shell-json.backup"; fi
    fi
  fi
fi

if [ ! -e "$CONF" ]; then
  say "example settings -> $CONF (every line commented; the defaults apply)"
  do_ "mkdir -p '$(dirname "$CONF")' && cp '$HERE/config.example.toml' '$CONF'"
else
  say "$CONF exists; left alone"
fi
say "done. The shell picks the plugin up by itself (it watches ~/.config/omarchy/plugins and shell.json); if it does not: omarchy-shell shell rescanPlugins"
