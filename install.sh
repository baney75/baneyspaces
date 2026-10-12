#!/bin/bash
# Installs BaneySpaces on macOS:
#   curl -fsSL https://raw.githubusercontent.com/baney75/baneyspaces/main/install.sh | bash
# Builds from source with Apple's free command line tools and puts the app in ~/Applications.
# Because it is built on this Mac there is no "unidentified developer" warning, and a stable
# local signature lets macOS keep the Accessibility permission across updates.
# Set BANEYSPACES_REF to install a specific tag or branch.
set -euo pipefail
REPO_URL="${BANEYSPACES_REPO:-https://github.com/baney75/baneyspaces.git}"
bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
step() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
fail() { printf 'BaneySpaces install failed: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "BaneySpaces is a Mac app (this is $(uname -s))."
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 13 ] || fail "BaneySpaces needs macOS 13 Ventura or later (this Mac has $(sw_vers -productVersion))."
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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
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
