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
if ! xcode-select -p >/dev/null 2>&1; then
  step "Installing Apple's command line tools (a system dialog will open)"
  xcode-select --install >/dev/null 2>&1 || true
  echo "When that install finishes, run this command again."
  exit 1
fi

# The newest release tag, or main if there isn't one yet.
REF="${BANEYSPACES_REF:-$(git ls-remote --tags --refs --sort=-v:refname "$REPO_URL" 'v*' 2>/dev/null | head -1 | sed 's#.*refs/tags/##')}"
REF="${REF:-main}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
step "Downloading BaneySpaces ($REF)"
git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$WORK/baneyspaces"
step "Building (about a minute the first time)"
"$WORK/baneyspaces/scripts/bundle.sh" --install 2>&1 | sed "s/^/${dim}    /;s/\$/${reset}/" | tail -4
echo
printf '%sBaneySpaces is installed.%s It is in your menu bar now.\n' "$bold" "$reset"
echo "The setup window walks you through the rest:"
echo "  1. Turn on BaneySpaces in System Settings > Privacy & Security > Accessibility."
echo "  2. Pick your keys. Then press ⌘1 to ⌘9 to switch workspaces, add ⇧ to move a window."
