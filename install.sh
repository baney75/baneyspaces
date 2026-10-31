#!/bin/bash
# Installs BaneySpaces on macOS:
#   curl -fsSL https://raw.githubusercontent.com/baney75/baneyspaces/main/install.sh | bash
# A stable release carries the finished app (a few MB). This downloads it, checks that it is
# signed with BaneySpaces' release key (it refuses anything else), and puts it in ~/Applications.
# No developer tools are needed. A release without the app (the Nightly build, an old release),
# or BANEYSPACES_FROM_SOURCE=1, builds from source instead with Apple's free command line tools;
# because that app is built on this Mac there is no "unidentified developer" warning, and a
# stable local signature lets macOS keep the Accessibility permission across updates.
# Set BANEYSPACES_REF to install a specific tag (or, building from source, a branch).
# BANEYSPACES_COMMIT (the updater sets it) pins the exact commit; a different build is refused.
# BANEYSPACES_ZIP=/path/to/BaneySpaces.zip uses that file instead of downloading (for tests; pair
# it with BANEYSPACES_DEST_DIR so nothing outside that folder changes).
set -euo pipefail
REPO_URL="${BANEYSPACES_REPO:-https://github.com/baney75/baneyspaces.git}"
bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
step() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
fail() { printf 'BaneySpaces install failed: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "BaneySpaces is a Mac app (this is $(uname -s))."
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 13 ] || fail "BaneySpaces needs macOS 13 Ventura or later (this Mac has $(sw_vers -productVersion))."
# The designated requirement every release is signed to (scripts/release-requirement.txt, which a
# test keeps identical to this). It pins the app's identifier and the release certificate.
REQUIREMENT='identifier "com.baney.baneyspaces" and certificate leaf = H"d1cfbd7446f84f6c625b9db83c5bf96da33b157e"'
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The prebuilt app: the release's BaneySpaces.zip. Stock macOS has no python3 (only a stub that asks
# for the command line tools), so the release's JSON is read with plutil.
ZIP="${BANEYSPACES_ZIP:-}"
TAG="${BANEYSPACES_REF:-}"
if [ -z "$ZIP" ] && [ "${BANEYSPACES_FROM_SOURCE:-}" != 1 ] && [[ "$TAG" =~ ^[A-Za-z0-9._-]*$ ]]; then
  API="https://api.github.com/repos/baney75/baneyspaces/releases/latest"
  [ -z "$TAG" ] || API="https://api.github.com/repos/baney75/baneyspaces/releases/tags/$TAG"
  ZIP_URL=""
  if curl -fsSL -H 'Accept: application/vnd.github+json' "$API" -o "$WORK/release.json" 2>/dev/null; then
    TAG=$(plutil -extract tag_name raw -o - "$WORK/release.json" 2>/dev/null || echo "${TAG:-the latest release}")
    i=0
    while name=$(plutil -extract "assets.$i.name" raw -o - "$WORK/release.json" 2>/dev/null); do
      if [ "$name" = BaneySpaces.zip ]; then
        ZIP_URL=$(plutil -extract "assets.$i.browser_download_url" raw -o - "$WORK/release.json" 2>/dev/null || true)
        break
      fi
      i=$((i + 1))
    done
  fi
  if [ -n "$ZIP_URL" ]; then
    step "Downloading BaneySpaces ($TAG)"
    curl -fsSL "$ZIP_URL" -o "$WORK/BaneySpaces.zip" \
      || fail "the download stopped. Try again, or build it on this Mac with BANEYSPACES_FROM_SOURCE=1."
    ZIP="$WORK/BaneySpaces.zip"
  fi
fi

if [ -n "$ZIP" ]; then
  [ -f "$ZIP" ] || fail "$ZIP doesn't exist."
  mkdir "$WORK/app"
  ditto -x -k "$ZIP" "$WORK/app" || fail "the download isn't a usable zip."
  APP="$WORK/app/BaneySpaces.app"
  [ -d "$APP" ] || fail "the download doesn't contain BaneySpaces.app."
  step "Checking the signature"
  codesign --verify --strict --deep "$APP" 2>/dev/null \
    || fail "the download's signature is broken, so it was not installed."
  codesign -v -R "=$REQUIREMENT" "$APP" 2>/dev/null \
    || fail "the download isn't signed with BaneySpaces' release key, so it was not installed."
  # An update pins the exact commit whose notes were shown; a tag that moved since is refused.
  if [ -n "${BANEYSPACES_COMMIT:-}" ] && [ "$(plutil -extract BaneySpacesCommit raw -o - "$APP/Contents/Info.plist" 2>/dev/null)" != "$BANEYSPACES_COMMIT" ]; then
    fail "${TAG:-the release} moved to a newer build after you looked at it. Check for updates again to see what changed."
  fi
  step "Installing"
  LOG="${TMPDIR:-/tmp}/baneyspaces-install.log"
  if ! bash "$APP/Contents/Resources/install-app.sh" "$APP" >"$LOG" 2>&1 </dev/null; then
    echo
    grep -E "error:|Error|failed|still running" "$LOG" | head -20 || tail -20 "$LOG"
    fail "the install stopped. The full log is at $LOG"
  fi
  grep -E "^(built|installed) " "$LOG" | sed "s/^/${dim}    /;s/\$/${reset}/" || true
  echo
  printf '%sBaneySpaces is installed.%s It is in your menu bar now.\n' "$bold" "$reset"
  echo "A setup window is open. Click Allow BaneySpaces, turn on the switch macOS shows you,"
  echo "and come back. Then press ⌘1 to ⌘9 to switch workspaces; add ⇧ to move a window."
  exit 0
fi

# No prebuilt app for this release (or BANEYSPACES_FROM_SOURCE=1): build it here.
# The build needs Apple's free command line tools (Swift and git). Check before anything else.
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
  step "BaneySpaces needs Apple's free command line tools first"
  xcode-select --install >/dev/null 2>&1 || true
  echo "  A macOS window just opened. Click Install and agree to the license."
  echo "  It downloads about 1 GB and usually takes 5 to 15 minutes."
  echo "  When it says the software was installed, paste the same command again."
  exit 1
fi

# The newest release tag, or main if there isn't one yet.
REF="${BANEYSPACES_REF:-$(git ls-remote --tags --refs --sort=-v:refname "$REPO_URL" 'v*' 2>/dev/null | head -1 | sed 's#.*refs/tags/##')}"
REF="${REF:-main}"

step "Downloading BaneySpaces ($REF)"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$WORK/baneyspaces"
# An update pins the exact commit whose notes were shown; a tag that moved since is refused.
if [ -n "${BANEYSPACES_COMMIT:-}" ] && [ "$(git -C "$WORK/baneyspaces" rev-parse HEAD)" != "$BANEYSPACES_COMMIT" ]; then
  fail "$REF moved to a newer build after you looked at it. Check for updates again to see what changed."
fi
step "Building (about a minute the first time)"
# The whole build log is kept, so a failure shows its real cause instead of the last few lines.
LOG="${TMPDIR:-/tmp}/baneyspaces-install.log"
if ! "$WORK/baneyspaces/scripts/bundle.sh" --install >"$LOG" 2>&1; then
  echo
  grep -E "error:|Error|failed|still running" "$LOG" | head -20 || tail -20 "$LOG"
  fail "the build stopped. The full log is at $LOG"
fi
grep -E "^(built|installed) " "$LOG" | sed "s/^/${dim}    /;s/\$/${reset}/"
echo
printf '%sBaneySpaces is installed.%s It is in your menu bar now.\n' "$bold" "$reset"
echo "A setup window is open. Click Allow BaneySpaces, turn on the switch macOS shows you,"
echo "and come back. Then press ⌘1 to ⌘9 to switch workspaces; add ⇧ to move a window."
