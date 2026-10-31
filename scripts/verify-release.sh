#!/bin/bash
# Checks the release files in a folder (default build/) before they are uploaded, and again once
# they are uploaded: it fails closed on anything off.
#   scripts/verify-release.sh [folder]
# The zip and the app inside the disk image must each pass `codesign --verify --strict --deep`,
# satisfy the pinned release requirement and carry this checkout's VERSION; the zip must match its
# .sha256 file; and the disk image must offer an Applications link beside the app.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=$(cd "${1:-build}" && pwd)
VERSION=$(cat VERSION)
REQ=$(cat scripts/release-requirement.txt)
fail() { echo "verify-release.sh: $*" >&2; exit 1; }
for f in BaneySpaces.zip BaneySpaces.zip.sha256 BaneySpaces.dmg; do [ -f "$DIR/$f" ] || fail "$DIR/$f is missing."; done

TMP=$(mktemp -d)
MNT="$TMP/mnt"
cleanup() { hdiutil detach -quiet "$MNT" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

check_app() {
  local app=$1 what=$2
  [ -d "$app" ] || fail "$what has no BaneySpaces.app."
  codesign --verify --strict --deep "$app" 2>/dev/null || fail "$what: the signature is broken."
  codesign -v -R "=$REQ" "$app" 2>/dev/null || fail "$what isn't signed with the release identity."
  [ "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" = "$VERSION" ] \
    || fail "$what isn't version $VERSION."
  [ -f "$app/Contents/Resources/install-app.sh" ] || fail "$what has no install-app.sh inside."
}

[ "$(awk '{print $1}' "$DIR/BaneySpaces.zip.sha256")" = "$(shasum -a 256 "$DIR/BaneySpaces.zip" | awk '{print $1}')" ] \
  || fail "BaneySpaces.zip doesn't match BaneySpaces.zip.sha256."
mkdir "$TMP/zip"
ditto -x -k "$DIR/BaneySpaces.zip" "$TMP/zip"
check_app "$TMP/zip/BaneySpaces.app" "BaneySpaces.zip"
mkdir "$MNT"
hdiutil attach -nobrowse -readonly -quiet -mountpoint "$MNT" "$DIR/BaneySpaces.dmg" >/dev/null 2>&1 || fail "BaneySpaces.dmg won't mount."
check_app "$MNT/BaneySpaces.app" "BaneySpaces.dmg"
[ "$(readlink "$MNT/Applications")" = /Applications ] || fail "BaneySpaces.dmg has no Applications link."
# Both files must hold the same build.
[ "$(plutil -extract BaneySpacesCommit raw -o - "$MNT/BaneySpaces.app/Contents/Info.plist")" = \
  "$(plutil -extract BaneySpacesCommit raw -o - "$TMP/zip/BaneySpaces.app/Contents/Info.plist")" ] \
  || fail "the zip and the disk image hold different builds."
echo "verified $DIR: signature, release key, version $VERSION, checksum"
