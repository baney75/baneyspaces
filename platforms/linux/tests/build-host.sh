#!/usr/bin/env bash
# Prints the path of a headless host compositor for the nested Hyprland test, building it if needed.
#
# Hyprland cannot run on its own without a GPU seat, and a nested Hyprland inside the real session
# would put a window on the real display. So nested.sh runs it as a client of a *headless* cage
# (WLR_BACKENDS=headless). Stock cage 0.3.1 offers xdg_wm_base v5 and Hyprland needs v6, so this
# builds cage 0.3.1 with that one number changed. Cached in ~/.cache/baneyspaces/cage-host.
# Set BS_HOST to use a compositor you already have.
set -euo pipefail
if [ -n "${BS_HOST:-}" ]; then echo "$BS_HOST"; exit 0; fi
dir="${XDG_CACHE_HOME:-$HOME/.cache}/baneyspaces/cage-host"
out="$dir/cage"
if [ -x "$out" ]; then echo "$out"; exit 0; fi
mkdir -p "$dir"; cd "$dir"
[ -d cage ] || git clone -q --branch v0.3.1 https://github.com/cage-kiosk/cage.git >&2
cd cage
sed -i 's/wlr_xdg_shell_create(server.wl_display, 5)/wlr_xdg_shell_create(server.wl_display, 6)/' cage.c
grep -q 'wl_display, 6)' cage.c || { echo "cage.c changed: patch the xdg_shell version to 6 by hand" >&2; exit 1; }
if ! command -v meson >/dev/null; then
  python3 -m venv "$dir/venv" >&2 && "$dir/venv/bin/pip" -q install meson >&2
  export PATH="$dir/venv/bin:$PATH"
fi
meson setup build >&2 && ninja -C build >&2
cp build/cage "$out"
echo "$out"
