#!/bin/bash
# Writes the notes for a GitHub release to stdout, from CHANGELOG.md and git history.
#   scripts/release-notes.sh v0.2.2   that version's CHANGELOG section
#   scripts/release-notes.sh nightly  what's coming (CHANGELOG's Unreleased section) and every
#                                     commit since the last release
# The last line is a marker the app reads to tell builds apart; GitHub doesn't show it.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:?usage: release-notes.sh vX.Y.Z | nightly}"

# The lines under "## <heading>" up to the next "## ".
section() {
  awk -v want="$1" '
    /^## / { if (found) exit; if (index($0, "## " want) == 1) { found = 1; next } }
    found { print }
  ' CHANGELOG.md | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}

if [ "$TARGET" = nightly ]; then
  LAST=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
  printf 'Built from `main` at %s. Nightly builds get changes first and can have rough edges; switch back to Stable from the menu bar at any time.\n\n' "$(git rev-parse --short HEAD)"
  COMING=$(section Unreleased)
  if [ -n "$COMING" ]; then
    printf '### Coming in the next release\n\n%s\n\n' "$COMING"
  fi
  printf '### Changes since %s\n\n' "${LAST:-the first commit}"
  git log --no-merges --format='- %s (%h)' ${LAST:+"$LAST"..HEAD} | head -60
  echo
else
  VERSION="${TARGET#v}"
  NOTES=$(section "$VERSION ")
  if [ -z "$NOTES" ]; then
    NOTES=$(section "$VERSION")
  fi
  [ -n "$NOTES" ] || { echo "CHANGELOG.md has no section for $VERSION" >&2; exit 1; }
  printf '%s\n' "$NOTES"
fi
printf '\n<!-- baneyspaces commit=%s date=%s -->\n' "$(git rev-parse HEAD)" "$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ)"
