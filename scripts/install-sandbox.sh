#!/bin/bash
# Installs what the sandbox needs on this Mac: Tart and Softnet at the versions in sandbox/PIN, and the
# root-owned setuid Softnet that Tart starts for --net-softnet. Idempotent: run it again any time; it
# changes only what differs. It never touches /Applications or the installed BaneySpaces, and it is not
# part of `make install`.
#
#   scripts/install-sandbox.sh [--dry-run] [--pull]
#
#   --dry-run  print what it would do (every sudo command included) and change nothing
#   --pull     also pull the pinned base image (about 26 GB; headless, safe any time)
#
# Needs: Apple silicon, macOS 26 or newer (Softnet 0.25), Homebrew, and sudo for the one setuid copy.
# Everything it installs is checked against a sha256 pinned here and in sandbox/PIN.
set -euo pipefail

TART_VERSION=2.41.1
SOFTNET_VERSION=0.25.0
SOFTNET_TARBALL_SHA256=5a2e8ef779f0a2169b88d273ee806c0d64321ec7714c0dc99bf217523ae9b008
SOFTNET_BINARY_SHA256=5c838134bb91af720d3575a9918e0bebe48a40bf37deaf0a5ec2219ba94b8534
TART_FORMULA_SHA256=117016ba2df4cde92468ecf59bf278416ff850058bc03ad388c676336418a264
SOFTNET_FORMULA_SHA256=e754c5494df67cb62087ebfd4b7358357955aaaf10e559f4df72c6e28f8e33c5
IMAGE=ghcr.io/cirruslabs/macos-tahoe-base@sha256:4aaa751fa7538902d73c767f27a066fc87e83f183069da4e4b5022863abd4c77
LIB=/usr/local/lib/baneyspaces/bin

DRY=0; PULL=0
for a in "$@"; do
  case $a in
    --dry-run) DRY=1 ;;
    --pull) PULL=1 ;;
    *) echo "usage: $0 [--dry-run] [--pull]" >&2; exit 2 ;;
  esac
done

say() { printf '== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
run() { if (( DRY )); then printf '+ %s\n' "$*"; else "$@"; fi; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FORMULAE=$HERE/sandbox/Formula

[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || die "Apple silicon Mac only (Tart runs macOS VMs there)"
(( $(sw_vers -productVersion | cut -d. -f1) >= 26 )) || die "macOS 26 or newer: Softnet $SOFTNET_VERSION needs it"
BREW=$(command -v brew || true); [[ -n $BREW ]] || die "Homebrew is not installed"
export HOMEBREW_NO_AUTO_UPDATE=1

# 1. The formulae in this repo are the ones the pins name.
[[ $(sha "$FORMULAE/tart.rb") == "$TART_FORMULA_SHA256" ]] || die "sandbox/Formula/tart.rb does not match its pinned sha256"
[[ $(sha "$FORMULAE/softnet.rb") == "$SOFTNET_FORMULA_SHA256" ]] || die "sandbox/Formula/softnet.rb does not match its pinned sha256"

# 2. Tart and Softnet through Homebrew, from a local tap holding exactly those two formulae.
say "Homebrew tap baneyspaces/pins"
TAP=$("$BREW" --repository)/Library/Taps/baneyspaces/homebrew-pins
[[ -d $TAP ]] || run "$BREW" tap-new --no-git baneyspaces/pins
run mkdir -p "$TAP/Formula"
for f in tart softnet; do
  if [[ ! -f $TAP/Formula/$f.rb ]] || ! cmp -s "$FORMULAE/$f.rb" "$TAP/Formula/$f.rb"; then run cp "$FORMULAE/$f.rb" "$TAP/Formula/$f.rb"; fi
done
run "$BREW" trust --formula baneyspaces/pins/tart baneyspaces/pins/softnet
have=$("$BREW" list --versions tart 2>/dev/null | awk '{print $2}' || true)
if [[ $have == "$TART_VERSION" ]]; then
  say "Tart $TART_VERSION already installed"
else
  say "Tart $TART_VERSION (the tarball's sha256 is checked by Homebrew against the formula)"
  run "$BREW" install baneyspaces/pins/tart
fi
if (( ! DRY )); then
  codesign --verify --deep --strict "$("$BREW" --prefix tart)/libexec/tart.app" || die "tart.app failed codesign verification"
fi

# 3. The setuid Softnet. Source: Homebrew's copy if its hash matches, else the pinned release tarball.
say "Softnet $SOFTNET_VERSION (setuid root, in $LIB)"
SRC=""
if cand=$("$BREW" --prefix softnet 2>/dev/null)/bin/softnet && [[ -f $cand && $(sha "$cand") == "$SOFTNET_BINARY_SHA256" ]]; then
  SRC=$cand
else
  work=$(mktemp -d "${TMPDIR:-/tmp}/bsx-softnet.XXXXXX"); trap 'rm -rf "$work"' EXIT
  mkdir "$work/dl" "$work/x"
  curl -fsSL -o "$work/dl/softnet.tar.gz" "https://github.com/openai/softnet/releases/download/$SOFTNET_VERSION/softnet.tar.gz"
  [[ $(sha "$work/dl/softnet.tar.gz") == "$SOFTNET_TARBALL_SHA256" ]] || die "softnet tarball checksum mismatch"
  tar -xzf "$work/dl/softnet.tar.gz" -C "$work/x"
  [[ $(sha "$work/x/softnet") == "$SOFTNET_BINARY_SHA256" ]] || die "softnet binary checksum mismatch"
  SRC=$work/x/softnet
fi
DEST=$LIB/softnet
if [[ -f $DEST && $(sha "$DEST") == "$SOFTNET_BINARY_SHA256" && $(stat -f '%Su:%Sg %Mp%Lp' "$DEST") == "root:wheel 4755" ]]; then
  say "Softnet already installed and correct: $DEST"
else
  run sudo mkdir -p "$LIB"
  run sudo chown root:wheel /usr/local/lib/baneyspaces "$LIB"
  run sudo chmod 755 /usr/local/lib/baneyspaces "$LIB"
  run sudo install -m 4755 -o root -g wheel "$SRC" "$DEST"
  if (( ! DRY )); then
    [[ $(sha "$DEST") == "$SOFTNET_BINARY_SHA256" && $(stat -f '%Su:%Sg %Mp%Lp' "$DEST") == "root:wheel 4755" ]] || die "$DEST is not as pinned after install"
  fi
fi

# 4. The image, only on request.
if (( PULL )); then
  digest=${IMAGE#*@}
  if "$BREW" --prefix >/dev/null && "$(command -v tart || echo "$("$BREW" --prefix)/bin/tart")" list --source oci --quiet 2>/dev/null | grep -q "$digest"; then
    say "Image already pulled"
  else
    say "Pulling $IMAGE"
    run "$(command -v tart || echo "$("$BREW" --prefix)/bin/tart")" pull "$IMAGE"
  fi
fi
say "Sandbox dependencies are in place (see sandbox/PIN). Check: swift scripts/sandbox-probe.swift"
