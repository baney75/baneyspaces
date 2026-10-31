#!/bin/bash
# Builds, signs and uploads the prebuilt app for a stable release. Run it on the owner's Mac
# (the signing key never leaves it) after pushing the tag:
#   git tag v0.2.2 && git push origin v0.2.2     # the Release workflow writes the notes
#   make release                                 # uploads BaneySpaces.zip, .sha256 and .dmg, then publishes
# The Release workflow creates the release as a draft. This uploads the files, checks them again as
# uploaded, and only then publishes it, so nobody is offered a release without its app.
# --dry-run does everything except the tag check, the upload and the publish, so it can run on a branch.
set -euo pipefail
cd "$(dirname "$0")/.."
DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: scripts/release.sh [--dry-run]" >&2; exit 1 ;;
esac
VERSION=$(cat VERSION)
TAG="v$VERSION"
REQ=$(cat scripts/release-requirement.txt)
bold=$(tput bold 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
step() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
fail() { echo "release.sh: $*" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || fail "the working tree isn't clean. Commit or stash first, so the app matches a commit."
if [ "$DRY" = 0 ]; then
  TAG_COMMIT=$(git rev-parse --verify --quiet "refs/tags/$TAG^{commit}") || fail "tag $TAG doesn't exist. Tag the release commit first."
  [ "$TAG_COMMIT" = "$(git rev-parse HEAD)" ] || fail "HEAD isn't the commit of $TAG. Check out the tag, or move VERSION to match."
  gh release view "$TAG" >/dev/null 2>&1 || fail "GitHub has no release $TAG yet. Push the tag and let the Release workflow finish."
  # A real release is universal and uses the stable identity, whatever this shell has set.
  unset BANEYSPACES_ARM64_ONLY BANEYSPACES_ADHOC
fi

step "Building $TAG"
scripts/bundle.sh
codesign -v -R "=$REQ" build/BaneySpaces.app 2>/dev/null \
  || fail "bundle.sh didn't sign with the release identity (it fell back to ad-hoc or used another key). Nothing was packaged."
if [ "$DRY" = 0 ]; then
  ARCHS=$(lipo -archs build/BaneySpaces.app/Contents/MacOS/BaneySpaces)
  [ "$ARCHS" = "x86_64 arm64" ] || [ "$ARCHS" = "arm64 x86_64" ] || fail "the app isn't universal ($ARCHS)."
fi

step "Packaging"
scripts/package.sh
# The files are checked as a person would get them, before anything is uploaded.
step "Checking the zip, the disk image and the checksum"
scripts/verify-release.sh build

if [ "$DRY" = 1 ]; then
  echo "dry run: $TAG not uploaded. The files are in build/."
  exit 0
fi
# The release is a draft until the files are up and checked again; the updater never offers a draft.
step "Uploading to $TAG"
gh release upload "$TAG" build/BaneySpaces.zip build/BaneySpaces.zip.sha256 build/BaneySpaces.dmg --clobber
step "Checking what was uploaded"
BACK=$(mktemp -d)
trap 'rm -rf "$BACK"' EXIT
gh release download "$TAG" --dir "$BACK" --pattern 'BaneySpaces.zip' --pattern 'BaneySpaces.zip.sha256' --pattern 'BaneySpaces.dmg'
for f in BaneySpaces.zip BaneySpaces.zip.sha256 BaneySpaces.dmg; do
  cmp -s "build/$f" "$BACK/$f" || fail "the uploaded $f differs from the one built. $TAG stays unpublished."
done
scripts/verify-release.sh "$BACK"
step "Publishing $TAG"
gh release edit "$TAG" --draft=false --latest
echo "published $TAG with BaneySpaces.zip, BaneySpaces.zip.sha256 and BaneySpaces.dmg"
