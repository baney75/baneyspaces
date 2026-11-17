#!/usr/bin/env bash
# Fetch agent-desktop at the pinned commit and build its CLI (Linux adapter, AT-SPI) with --locked.
# Output: platforms/linux/engine/agent-desktop (and the clipboard-owner helper beside it).
# Usage: build-engine.sh [--profile release|ci]   (default release)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile=release
[ "${1:-}" = "--profile" ] && profile="${2:?profile}"
# shellcheck disable=SC1091
. "$here/engine.pin"
src="$here/third_party/agent-desktop"
out="$here/engine"
if [ ! -d "$src/.git" ]; then
  mkdir -p "$here/third_party"
  git clone -q "$repo" "$src"
fi
if [ "$(git -C "$src" rev-parse HEAD)" != "$commit" ]; then
  git -C "$src" fetch -q origin
  git -C "$src" checkout -q --detach "$commit"
fi
[ "$(git -C "$src" rev-parse HEAD)" = "$commit" ] || { echo "engine: HEAD is not the pinned $commit" >&2; exit 1; }
[ -z "$(git -C "$src" status --porcelain)" ] || { echo "engine: pinned checkout is dirty" >&2; exit 1; }
(cd "$src" && cargo build --locked --profile "$profile" -p agent-desktop -p agent-desktop-linux)
mkdir -p "$out"
cp -f "$src/target/$profile/agent-desktop" "$out/agent-desktop"
[ -f "$src/target/$profile/agent-desktop-linux-clipboard-owner" ] && cp -f "$src/target/$profile/agent-desktop-linux-clipboard-owner" "$out/"
echo "$commit" > "$out/COMMIT"
cp -f "$src/LICENSE" "$out/LICENSE"
[ -f "$src/NOTICE" ] && cp -f "$src/NOTICE" "$out/NOTICE" || true
echo "engine built: $out/agent-desktop ($commit)"
