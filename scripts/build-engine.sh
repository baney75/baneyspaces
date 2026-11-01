#!/bin/bash
# Builds the hands engine: agent-desktop's C library (the agent-desktop-ffi crate only), from the
# commit pinned in engine/PIN, into engine/lib/libagent_desktop_ffi.dylib (universal unless
# BANEYSPACES_ARM64_ONLY=1). Nothing else of agent-desktop is built, and npm is never run.
#
#   scripts/build-engine.sh          build if engine/lib is missing or older than the pin and patches
#   scripts/build-engine.sh --force  build again
#
# Steps: fetch the tarball (cached in engine/.cache), check its sha256 and the commit id stored in
# it, unpack into engine/.src, apply engine/patches, check the build's advisories
# (scripts/engine-advisories.py), build with the upstream Cargo.lock (--locked), join the two
# architectures with lipo, and check that the header in Sources/CAgentDesktop matches the engine's.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
# shellcheck source=../engine/PIN
. engine/PIN
OUT=engine/lib
STAMP="$ENGINE_COMMIT $ENGINE_SHA256 $(cat engine/patches/*.patch | shasum -a 256 | cut -c1-64) ${BANEYSPACES_ARM64_ONLY:-0}"

if [ "${1:-}" != "--force" ] && [ -f "$OUT/libagent_desktop_ffi.dylib" ] && [ "$(cat "$OUT/STAMP" 2>/dev/null)" = "$STAMP" ]; then
  echo "engine: up to date ($ENGINE_COMMIT)"
  exit 0
fi

command -v cargo >/dev/null || { echo "engine: cargo isn't installed (rustup.rs). Rust is needed once to build the hands engine." >&2; exit 1; }

mkdir -p engine/.cache
TAR="engine/.cache/agent-desktop-$ENGINE_COMMIT.tar.gz"
if [ ! -f "$TAR" ]; then
  echo "engine: fetching agent-desktop $ENGINE_COMMIT"
  curl -fsSL -o "$TAR.part" "https://codeload.github.com/$ENGINE_REPO/tar.gz/$ENGINE_COMMIT"
  mv "$TAR.part" "$TAR"
fi
GOT=$(shasum -a 256 "$TAR" | cut -d' ' -f1)
if [ "$GOT" != "$ENGINE_SHA256" ]; then
  rm -f "$TAR"
  echo "engine: the tarball's sha256 is $GOT, but engine/PIN says $ENGINE_SHA256. Refusing to build it." >&2
  exit 1
fi
# head closes the pipe early, which makes gzip fail under pipefail: only git's answer counts.
COMMIT_IN_TAR=$(gzip -dc "$TAR" 2>/dev/null | head -c 4096 | git get-tar-commit-id || true)
[ "$COMMIT_IN_TAR" = "$ENGINE_COMMIT" ] || { echo "engine: the tarball is commit $COMMIT_IN_TAR, not $ENGINE_COMMIT" >&2; exit 1; }

rm -rf engine/.src && mkdir -p engine/.src
tar xzf "$TAR" -C engine/.src --strip-components=1 \
  --exclude="agent-desktop-$ENGINE_COMMIT/assets" --exclude="agent-desktop-$ENGINE_COMMIT/apps" --exclude="agent-desktop-$ENGINE_COMMIT/npm"
for p in engine/patches/*.patch; do
  patch -p1 -s -d engine/.src < "$p"
done
[ "$(shasum -a 256 engine/.src/LICENSE | cut -d' ' -f1)" = "$ENGINE_LICENSE_SHA256" ] || { echo "engine: upstream LICENSE changed; update LICENSES/ and engine/PIN" >&2; exit 1; }
cmp -s engine/.src/LICENSE LICENSES/agent-desktop-Apache-2.0.txt || { echo "engine: LICENSES/agent-desktop-Apache-2.0.txt differs from upstream's LICENSE" >&2; exit 1; }

TARGETS=(aarch64-apple-darwin)
[ "${BANEYSPACES_ARM64_ONLY:-}" = 1 ] || TARGETS+=(x86_64-apple-darwin)

cd engine/.src
# The toolchain the engine pins (rust-toolchain.toml); its macOS targets are added if missing.
TOOLCHAIN=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' rust-toolchain.toml)
if command -v rustup >/dev/null; then
  for t in "${TARGETS[@]}"; do
    rustup target list --toolchain "$TOOLCHAIN" --installed 2>/dev/null | grep -qx "$t" || rustup target add --toolchain "$TOOLCHAIN" "$t"
  done
fi

python3 -I "$ROOT/scripts/engine-advisories.py" "${TARGETS[0]}"

LIBS=()
for t in "${TARGETS[@]}"; do
  # release-ffi, not release: the crate refuses panic=abort, which would let a panic cross the C boundary.
  # Not cargo's own strip: its output has a LINKEDIT string pool that Xcode's linker rejects
  # ("mis-aligned LINKEDIT string pool"). Apple's strip runs below instead.
  CARGO_PROFILE_RELEASE_FFI_STRIP=none cargo build --locked --profile release-ffi -p agent-desktop-ffi --target "$t"
  LIBS+=("target/$t/release-ffi/libagent_desktop_ffi.dylib")
done
cd "$ROOT"

mkdir -p "$OUT"
lipo -create "${LIBS[@]/#/engine/.src/}" -output "$OUT/libagent_desktop_ffi.dylib"
strip -x "$OUT/libagent_desktop_ffi.dylib"
# A symbol BaneySpaces calls but the library lacks would fail at launch, not at build.
for sym in ad_init ad_adapter_create ad_snapshot_window ad_execute_by_ref_timeout ad_free_string; do
  nm -gU "$OUT/libagent_desktop_ffi.dylib" | grep -q " _$sym\$" || { echo "engine: the library has no $sym" >&2; exit 1; }
done
cmp -s engine/.src/crates/ffi/include/agent_desktop.h Sources/CAgentDesktop/include/agent_desktop.h \
  || { echo "engine: Sources/CAgentDesktop/include/agent_desktop.h differs from the engine's header; copy engine/.src/crates/ffi/include/agent_desktop.h over it" >&2; exit 1; }
echo "$STAMP" > "$OUT/STAMP"
echo "engine: built $OUT/libagent_desktop_ffi.dylib ($(lipo -archs "$OUT/libagent_desktop_ffi.dylib"), agent-desktop ${ENGINE_COMMIT:0:7})"
