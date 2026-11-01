#!/bin/bash
# Builds BaneySpaces.app (universal: Apple silicon and Intel) into ./build.
#   scripts/bundle.sh            release build
#   scripts/bundle.sh --install  also copy to ~/Applications and start it
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
APP=build/BaneySpaces.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/skill" "$APP/Contents/Resources/licenses"

# The hands engine (agent-desktop's library), built from the pinned commit; BaneySpaces links it.
scripts/build-engine.sh

ARCHS=(--arch arm64)
if xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 && [ "${BANEYSPACES_ARM64_ONLY:-}" != 1 ]; then ARCHS+=(--arch x86_64); fi
swift build -c release "${ARCHS[@]}"
BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)/BaneySpaces
cp "$BIN" "$APP/Contents/MacOS/BaneySpaces"
# swift build points a dev binary at engine/lib; the bundle finds its library in Contents/Frameworks.
install_name_tool -delete_rpath "$PWD/engine/lib" "$APP/Contents/MacOS/BaneySpaces"
# The Deck's command. It lives in Resources: the file system ignores case, so "baneyspaces" can't sit
# beside "BaneySpaces" in MacOS.
cp "$(dirname "$BIN")/baneyspaces-cli" "$APP/Contents/Resources/bin/baneyspaces"
cp skill/SKILL.md "$APP/Contents/Resources/skill/SKILL.md"
cp engine/lib/libagent_desktop_ffi.dylib "$APP/Contents/Frameworks/libagent_desktop_ffi.dylib"
cp NOTICE "$APP/Contents/Resources/NOTICE"
cp LICENSES/* "$APP/Contents/Resources/licenses/"
# Settings' Uninstall runs the same script as the README.
cp uninstall.sh "$APP/Contents/Resources/uninstall.sh"
# install.sh runs this copy on the prebuilt release, so the installer that fetched the app and the
# steps that put it in place always come from the same signed bundle.
cp scripts/install-app.sh "$APP/Contents/Resources/install-app.sh"

swift scripts/make-icon.swift build/BaneySpaces.iconset
iconutil -c icns build/BaneySpaces.iconset -o "$APP/Contents/Resources/BaneySpaces.icns"

# The commit and its date tell the updater exactly which build this is.
COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
COMMIT_DATE=$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)
sed -e "s/@VERSION@/$VERSION/g" -e "s/@COMMIT@/$COMMIT/g" -e "s/@COMMIT_DATE@/$COMMIT_DATE/g" Resources/Info.plist > "$APP/Contents/Info.plist"
# A stable local identity keeps the Accessibility permission across rebuilds; ad-hoc is the fallback.
if [ "${BANEYSPACES_ADHOC:-}" != 1 ] && IDENT=$(scripts/signing-identity.sh 2>/dev/null); then
  # Inside out: the engine's library, then the command, then the app that holds both.
  codesign --force --sign "${IDENT%%$'\t'*}" --keychain "${IDENT#*$'\t'}" --identifier com.baney.baneyspaces.engine "$APP/Contents/Frameworks/libagent_desktop_ffi.dylib"
  codesign --force --sign "${IDENT%%$'\t'*}" --keychain "${IDENT#*$'\t'}" --identifier com.baney.baneyspaces.cli "$APP/Contents/Resources/bin/baneyspaces"
  codesign --force --sign "${IDENT%%$'\t'*}" --keychain "${IDENT#*$'\t'}" --identifier com.baney.baneyspaces "$APP"
else
  ADHOC_NOTE="note: signed ad-hoc, so macOS will ask for Accessibility again after each update"
  echo "$ADHOC_NOTE" >&2
  codesign --force --sign - --identifier com.baney.baneyspaces.engine "$APP/Contents/Frameworks/libagent_desktop_ffi.dylib"
  codesign --force --sign - --identifier com.baney.baneyspaces.cli "$APP/Contents/Resources/bin/baneyspaces"
  codesign --force --sign - --identifier com.baney.baneyspaces "$APP"
fi
codesign --verify --deep --strict "$APP"
# The app must find its library next to itself, not where it was built.
otool -L "$APP/Contents/MacOS/BaneySpaces" | grep -q '@rpath/libagent_desktop_ffi.dylib' || { echo "bundle: BaneySpaces doesn't link the engine through @rpath" >&2; exit 1; }
otool -l "$APP/Contents/MacOS/BaneySpaces" | grep -A2 LC_RPATH | grep -q '@executable_path/../Frameworks' || { echo "bundle: no @executable_path/../Frameworks rpath" >&2; exit 1; }
[ "$(otool -D "$APP/Contents/Frameworks/libagent_desktop_ffi.dylib" | grep -c '^@rpath/libagent_desktop_ffi.dylib$')" -ge 1 ] || { echo "bundle: the engine's install name isn't @rpath" >&2; exit 1; }
if otool -l "$APP/Contents/MacOS/BaneySpaces" | grep -A2 LC_RPATH | grep -q "$PWD/engine/lib"; then echo "bundle: the app still points at the build folder" >&2; exit 1; fi
echo "built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/BaneySpaces"))"

if [ "${1:-}" = "--install" ]; then
  scripts/install-app.sh "$APP"
fi
[ -z "${ADHOC_NOTE:-}" ] || echo "$ADHOC_NOTE"
