#!/bin/bash
# Builds the agent-desktop CLI from the pinned source into bench/../.tools (git-ignored), never
# through npm and never onto PATH. Prints the binary's path on its last line.
#
#   bench/build-agent-desktop.sh          build if missing or built from another pin
#   bench/build-agent-desktop.sh --force  build again
#
# Steps: fetch the tarball (cached in .tools/cache), check its sha256 and the commit id stored in
# it against bench/PIN, unpack to .tools/agent-desktop-src, then
# `cargo build --locked --release -p agent-desktop` with the upstream Cargo.lock.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=PIN
. "$HERE/PIN"
TOOLS="$ROOT/.tools"
BIN="$TOOLS/agent-desktop-src/target/release/agent-desktop"
STAMP="$ENGINE_COMMIT $ENGINE_SHA256"

if [ "${1:-}" != "--force" ] && [ -x "$BIN" ] && [ "$(cat "$TOOLS/STAMP" 2>/dev/null)" = "$STAMP" ]; then
  echo "agent-desktop: up to date (${ENGINE_COMMIT:0:7})" >&2
  echo "$BIN"; exit 0
fi
command -v cargo >/dev/null || { echo "agent-desktop: cargo isn't installed (rustup.rs)" >&2; exit 1; }

mkdir -p "$TOOLS/cache"
TAR="$TOOLS/cache/agent-desktop-$ENGINE_COMMIT.tar.gz"
if [ ! -f "$TAR" ]; then
  echo "agent-desktop: fetching $ENGINE_COMMIT" >&2
  curl -fsSL -o "$TAR.part" "https://codeload.github.com/$ENGINE_REPO/tar.gz/$ENGINE_COMMIT"
  mv "$TAR.part" "$TAR"
fi
GOT=$(shasum -a 256 "$TAR" | cut -d' ' -f1)
if [ "$GOT" != "$ENGINE_SHA256" ]; then
  rm -f "$TAR"
  echo "agent-desktop: the tarball's sha256 is $GOT, but bench/PIN says $ENGINE_SHA256. Refusing to build it." >&2
  exit 1
fi
IN_TAR=$(gzip -dc "$TAR" 2>/dev/null | head -c 4096 | git get-tar-commit-id || true)
[ "$IN_TAR" = "$ENGINE_COMMIT" ] || { echo "agent-desktop: the tarball is commit $IN_TAR, not $ENGINE_COMMIT" >&2; exit 1; }

rm -rf "$TOOLS/agent-desktop-src" && mkdir -p "$TOOLS/agent-desktop-src"
tar xzf "$TAR" -C "$TOOLS/agent-desktop-src" --strip-components=1
cd "$TOOLS/agent-desktop-src"
cargo build --locked --release -p agent-desktop >&2
[ -x "$BIN" ] || { echo "agent-desktop: the build produced no $BIN" >&2; exit 1; }
echo "$STAMP" > "$TOOLS/STAMP"
echo "$BIN"
