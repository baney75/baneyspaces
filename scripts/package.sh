#!/bin/bash
# Packages build/BaneySpaces.app for a release:
#   build/BaneySpaces.zip         what install.sh and the updater download
#   build/BaneySpaces.zip.sha256  its checksum
#   build/BaneySpaces.dmg         the disk image for people who download in a browser
# It refuses any app that isn't signed with the release identity (scripts/release-requirement.txt),
# so an ad-hoc or wrong-key build can never be packaged.
# The disk image is made without Finder: dmgbuild (pip, in a venv under build/.venv) writes it.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/BaneySpaces.app
REQ=$(cat scripts/release-requirement.txt)
fail() { echo "package.sh: $*" >&2; exit 1; }

[ -d "$APP" ] || fail "$APP doesn't exist. Run scripts/bundle.sh first."
codesign -v -R "=$REQ" "$APP" 2>/dev/null \
  || fail "$APP isn't signed with the BaneySpaces release identity (ad-hoc or another key), so it won't be packaged. Run scripts/bundle.sh on the owner's Mac with the stable identity."

rm -f build/BaneySpaces.zip build/BaneySpaces.zip.sha256 build/BaneySpaces.dmg
ditto -c -k --keepParent "$APP" build/BaneySpaces.zip
(cd build && shasum -a 256 BaneySpaces.zip > BaneySpaces.zip.sha256)

# Disk image: the app on the left, an Applications link on the right, over a drawn background.
if [ ! -x build/.venv/bin/dmgbuild ]; then
  python3 -m venv build/.venv
  build/.venv/bin/pip install --quiet --disable-pip-version-check dmgbuild
fi
rm -rf build/dmg && mkdir -p build/dmg
swift scripts/make-dmg-background.swift build/dmg
tiffutil -cathidpicheck build/dmg/background.png build/dmg/background@2x.png -out build/dmg/background.tiff
build/.venv/bin/dmgbuild -s scripts/dmg-settings.py \
  -D app="$APP" -D background=build/dmg/background.tiff \
  BaneySpaces build/BaneySpaces.dmg >/dev/null
rm -rf build/dmg
echo "packaged build/BaneySpaces.zip ($(du -h build/BaneySpaces.zip | cut -f1)) and build/BaneySpaces.dmg ($(du -h build/BaneySpaces.dmg | cut -f1))"
