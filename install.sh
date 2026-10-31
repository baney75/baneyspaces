#!/bin/bash
# Installs BaneySpaces on macOS:
#   curl -fsSL https://raw.githubusercontent.com/baney75/baneyspaces/main/install.sh | bash
# A stable release carries the finished app (a few MB). This downloads it, checks that it is
# signed with BaneySpaces' release key (it refuses anything else), and puts it in the folder the
# current copy is in (~/Applications on a first install). No developer tools are needed.
# It builds from source instead, with Apple's free command line tools, when the release has no
# ready-made app (the Nightly build, an old release), when BANEYSPACES_FROM_SOURCE=1, or when the
# copy already installed was built on this Mac and the tools are here: that keeps its signature,
# so macOS keeps the Accessibility permission. Without the tools that copy is replaced by the
# ready-made app and macOS asks for the permission once more. A source build has no "unidentified
# developer" warning either.
# Set BANEYSPACES_REF to install a specific tag (or, building from source, a branch).
# BANEYSPACES_COMMIT (the updater sets it) pins the exact commit; a different build is refused.
# BANEYSPACES_INSTALL_DIR (the updater sets it) is the folder to install into.
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

# Where an installed copy would be replaced (the same choice install-app.sh makes).
if [ -n "${BANEYSPACES_DEST_DIR:-}" ]; then CANDIDATES=("$BANEYSPACES_DEST_DIR")
elif [ -n "${BANEYSPACES_INSTALL_DIR:-}" ]; then CANDIDATES=("$BANEYSPACES_INSTALL_DIR")
else CANDIDATES=("$HOME/Applications" /Applications); fi
EXISTING=""
for dir in "${CANDIDATES[@]}"; do
  if [ -d "$dir/BaneySpaces.app" ]; then EXISTING="$dir/BaneySpaces.app"; break; fi
done
have_tools() { xcode-select -p >/dev/null 2>&1 && xcrun --find swift >/dev/null 2>&1; }

# macOS ties the Accessibility permission to the app's signature. A copy built on this Mac has its
# own signature, and the ready-made app has another, so replacing one with the other would make
# macOS ask again. With the command line tools here, keep building from source (same signer);
# without them, install the ready-made app and say that macOS will ask once more.
FROM_SOURCE="${BANEYSPACES_FROM_SOURCE:-}"
if [ "$FROM_SOURCE" != 1 ] && [ -n "$EXISTING" ] && ! codesign -v -R "=$REQUIREMENT" "$EXISTING" >/dev/null 2>&1; then
  if have_tools; then
    step "Your BaneySpaces was built on this Mac, so it is updated the same way (macOS keeps its Accessibility permission)"
    FROM_SOURCE=1
  else
    step "Your BaneySpaces was built on this Mac and this one is ready-made, so macOS will ask for the Accessibility permission once more"
  fi
fi

# The prebuilt app: the release's BaneySpaces.zip, straight from GitHub's download address (no API,
# no JSON to read, which stock macOS has no good tool for).
ZIP="${BANEYSPACES_ZIP:-}"
TAG="${BANEYSPACES_REF:-}"
SHA_URL=""
# BANEYSPACES_RELEASES_BASE is for tests: a stand-in for GitHub's releases address.
BASE="${BANEYSPACES_RELEASES_BASE:-https://github.com/baney75/baneyspaces/releases}"
# Prints the HTTP status; a connection that fails prints 000.
fetch() { curl -sSL -w '%{http_code}' -o "$2" "$1" 2>/dev/null || true; }

# Which release is the latest stable: GitHub's /releases/latest answers with a redirect to
# /releases/tag/<tag>. The tag is read from that redirect alone, before anything is downloaded, so
# the zip, its checksum and the version check all name the same release.
LATEST_TAG=""
LATEST_STATE=""   # ok, none (no releases yet) or error
if [ -z "$TAG" ] && [ -z "$ZIP" ]; then
  for attempt in 1 2; do
    reply=$(curl -sSI -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE/latest" 2>/dev/null || true)
    code=${reply%% *}; target=${reply#* }
    if [ "$code" = 404 ]; then LATEST_STATE=none; break; fi
    if [[ "$code" =~ ^30[0-9]$ ]]; then
      found=$(printf '%s' "$target" | sed -n 's#.*/releases/tag/\([A-Za-z0-9._-]*\)$#\1#p')
      if [ -n "$found" ]; then LATEST_TAG=$found; LATEST_STATE=ok; break; fi
      case "$target" in */releases|*/releases/) LATEST_STATE=none; break ;; esac
    fi
    [ "$attempt" = 2 ] || sleep 2
  done
  [ -n "$LATEST_STATE" ] || LATEST_STATE=error
fi

if [ -z "$ZIP" ] && [ "$FROM_SOURCE" != 1 ] && [[ "$TAG" =~ ^[A-Za-z0-9._-]*$ ]]; then
  if [ -z "$TAG" ]; then
    case "$LATEST_STATE" in
      ok) TAG="$LATEST_TAG" ;;
      none) echo "  There are no releases yet; building it." ;;
      *) fail "couldn't tell which release is the latest. Try again, or build it on this Mac with BANEYSPACES_FROM_SOURCE=1." ;;
    esac
  fi
  if [ -n "$TAG" ]; then
    step "Downloading BaneySpaces ($TAG)"
    ZIP_URL="$BASE/download/$TAG/BaneySpaces.zip"
    reply=$(fetch "$ZIP_URL" "$WORK/BaneySpaces.zip")
    [ "$reply" = 200 ] || [ "$reply" = 404 ] || { sleep 2; reply=$(fetch "$ZIP_URL" "$WORK/BaneySpaces.zip"); }
    case "$reply" in
      200) ZIP="$WORK/BaneySpaces.zip"; SHA_URL="$BASE/download/$TAG/BaneySpaces.zip.sha256" ;;
      404) echo "  There is no ready-made app for this release; building it." ;;
      *) fail "the download didn't work (HTTP $reply). Try again, or build it on this Mac with BANEYSPACES_FROM_SOURCE=1." ;;
    esac
  fi
fi

if [ -n "$ZIP" ] && [ "$FROM_SOURCE" != 1 ]; then
  [ -f "$ZIP" ] || fail "$ZIP doesn't exist."
  # The checksum file is optional: a release without one is checked by its signature alone.
  if [ -n "$SHA_URL" ]; then
    reply=$(fetch "$SHA_URL" "$WORK/BaneySpaces.zip.sha256")
    case "$reply" in
      200) [ "$(awk '{print $1}' "$WORK/BaneySpaces.zip.sha256")" = "$(shasum -a 256 "$ZIP" | awk '{print $1}')" ] \
             || fail "the download doesn't match its checksum, so it was not installed." ;;
      404) ;;
      *) fail "couldn't fetch the checksum (HTTP $reply). Try again, or build it on this Mac with BANEYSPACES_FROM_SOURCE=1." ;;
    esac
  fi
  mkdir "$WORK/app"
  ditto -x -k "$ZIP" "$WORK/app" || fail "the download isn't a usable zip."
  APP="$WORK/app/BaneySpaces.app"
  [ -d "$APP" ] || fail "the download doesn't contain BaneySpaces.app."
  step "Checking the signature"
  codesign --verify --strict --deep "$APP" 2>/dev/null \
    || fail "the download's signature is broken, so it was not installed."
  codesign -v -R "=$REQUIREMENT" "$APP" 2>/dev/null \
    || fail "the download isn't signed with BaneySpaces' release key, so it was not installed."
  if [ -n "${BANEYSPACES_COMMIT:-}" ]; then
    # An update pins the exact commit whose notes were shown; a tag that moved since is refused.
    if [ "$(plutil -extract BaneySpacesCommit raw -o - "$APP/Contents/Info.plist" 2>/dev/null)" != "$BANEYSPACES_COMMIT" ]; then
      fail "${TAG:-the release} moved to a newer build after you looked at it. Check for updates again to see what changed."
    fi
  elif [[ "$TAG" =~ ^v[0-9] ]]; then
    # Otherwise the app must be the version the tag names.
    if [ "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null)" != "${TAG#v}" ]; then
      fail "the download isn't version ${TAG#v}, so it was not installed."
    fi
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
if ! have_tools; then
  # An update runs in the background with nobody to click Install, so it only says what to do.
  if [ -n "${BANEYSPACES_COMMIT:-}" ]; then
    fail "this update is built on your Mac and needs Apple's command line tools (Nightly builds always do; Stable releases install ready-made). Run xcode-select --install in Terminal, then update again."
  fi
  step "BaneySpaces needs Apple's free command line tools first"
  xcode-select --install >/dev/null 2>&1 || true
  echo "  A macOS window just opened. Click Install and agree to the license."
  echo "  It downloads about 1 GB and usually takes 5 to 15 minutes."
  echo "  When it says the software was installed, paste the same command again."
  exit 1
fi

# The latest release's tag (looked up above), else the newest v* tag, else main if there isn't one yet.
REF="${BANEYSPACES_REF:-$LATEST_TAG}"
[ -n "$REF" ] || REF=$(git ls-remote --tags --refs --sort=-v:refname "$REPO_URL" 'v*' 2>/dev/null | head -1 | sed 's#.*refs/tags/##' || true)
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
SRC="$WORK/baneyspaces"
if [ -f "$SRC/scripts/install-app.sh" ]; then
  # Build, then place the app with that build's own install step, which knows where to put it.
  if ! { "$SRC/scripts/bundle.sh" && bash "$SRC/build/BaneySpaces.app/Contents/Resources/install-app.sh" "$SRC/build/BaneySpaces.app" </dev/null; } >"$LOG" 2>&1; then
    echo
    grep -E "error:|Error|failed|still running" "$LOG" | head -20 || tail -20 "$LOG"
    fail "the build stopped. The full log is at $LOG"
  fi
elif ! "$SRC/scripts/bundle.sh" --install >"$LOG" 2>&1; then
  # An older revision has no separate install step.
  echo
  grep -E "error:|Error|failed|still running" "$LOG" | head -20 || tail -20 "$LOG"
  fail "the build stopped. The full log is at $LOG"
fi
grep -E "^(built|installed) " "$LOG" | sed "s/^/${dim}    /;s/\$/${reset}/"
echo
printf '%sBaneySpaces is installed.%s It is in your menu bar now.\n' "$bold" "$reset"
echo "A setup window is open. Click Allow BaneySpaces, turn on the switch macOS shows you,"
echo "and come back. Then press ⌘1 to ⌘9 to switch workspaces; add ⇧ to move a window."
