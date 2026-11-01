#!/bin/bash
# Builds AXe, the tool BaneySpaces' device hands use to read an iOS Simulator's UI tree and tap it
# without a pointer, from the commit pinned in tools/axe.PIN, into BaneySpaces' own tools folder:
#   ~/Library/Application Support/BaneySpaces/tools/axe/bin/axe
# Never the release binary. Steps: fetch the AXe tarball, check its sha256 and embedded commit id,
# build the IDB frameworks with AXe's own script (it clones the pinned fork commit), then
# `swift build -c release`. Needs Xcode and xcodegen (the build is the long part).
#
#   scripts/build-axe.sh          build if the pin changed
#   scripts/build-axe.sh --force  build again
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../tools/axe.PIN
. tools/axe.PIN
TOOLS="${BANEYSPACES_TOOLS:-$HOME/Library/Application Support/BaneySpaces/tools}/axe"
STAMP="$AXE_COMMIT $AXE_SHA256 $AXE_IDB_COMMIT $(xcodebuild -version 2>/dev/null | tr "\n" " ")"
if [ "${1:-}" != "--force" ] && [ -x "$TOOLS/bin/axe" ] && [ "$(cat "$TOOLS/STAMP" 2>/dev/null)" = "$STAMP" ]; then
  echo "axe: up to date ($AXE_TAG)"; exit 0
fi
command -v xcodegen >/dev/null || { echo "axe: xcodegen isn't installed (brew install xcodegen); AXe needs it to generate the IDB projects" >&2; exit 1; }
mkdir -p "$TOOLS/.cache"
fetch() { # fetch <repo> <commit> <sha256> <name>
  local tar="$TOOLS/.cache/$4-$2.tar.gz"
  [ -f "$tar" ] || { curl -fsSL -o "$tar.part" "https://codeload.github.com/$1/tar.gz/$2" && mv "$tar.part" "$tar"; }
  local got; got=$(shasum -a 256 "$tar" | cut -d' ' -f1)
  [ "$got" = "$3" ] || { rm -f "$tar"; echo "axe: $4's tarball has sha256 $got, tools/axe.PIN says $3. Refusing it." >&2; exit 1; }
  local id; id=$(gzip -dc "$tar" 2>/dev/null | head -c 4096 | git get-tar-commit-id || true)
  [ "$id" = "$2" ] || { echo "axe: $4's tarball is commit $id, not $2" >&2; exit 1; }
  echo "$tar"
}
AXE_TAR=$(fetch "$AXE_REPO" "$AXE_COMMIT" "$AXE_SHA256" axe)
rm -rf "$TOOLS/src" && mkdir -p "$TOOLS/src"
tar xzf "$AXE_TAR" -C "$TOOLS/src" --strip-components=1
# AXe's own script clones its IDB fork and checks out this commit; git's object ids are the check.
# The pin must say the same commit AXe's script does.
grep -q "DEFAULT_IDB_GIT_REF=\"$AXE_IDB_COMMIT\"" "$TOOLS/src/scripts/build.sh" || { echo "axe: its build script pins another IDB fork commit than tools/axe.PIN" >&2; exit 1; }
echo "axe: building (this takes a while)"
(cd "$TOOLS/src" && AXE_CODESIGN_IDENTITY="${AXE_CODESIGN_IDENTITY:--}" ./scripts/build.sh dev && swift build -c release --product axe)
mkdir -p "$TOOLS/bin"
BIN=$(cd "$TOOLS/src" && swift build -c release --show-bin-path)
cp -R "$BIN/axe" "$TOOLS/bin/axe"
for f in "$BIN"/*.bundle; do [ -e "$f" ] && cp -R "$f" "$TOOLS/bin/"; done
[ -d "$TOOLS/src/build_products/Frameworks" ] && cp -R "$TOOLS/src/build_products/Frameworks" "$TOOLS/bin/" || true
echo "$STAMP" > "$TOOLS/STAMP"
"$TOOLS/bin/axe" --version
