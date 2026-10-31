#!/bin/bash
# Prints the name of a local code-signing identity, creating it on first use, and the keychain that
# holds it. macOS ties the Accessibility permission to the app's signature. An ad-hoc signature
# changes on every build, so macOS forgot the permission after each update; a stable local
# certificate keeps it. The key lives in its own keychain under Application Support. It never
# touches the login keychain and is not trusted for anything else.
#   scripts/signing-identity.sh   ->  "BaneySpaces Local Signing<TAB>/path/to/baneyspaces-signing.keychain-db"
# Passwords go through files and stdin, never command-line arguments, so `ps` can't show them.
set -euo pipefail
NAME="BaneySpaces Local Signing"
DIR="$HOME/Library/Application Support/BaneySpaces/Signing"
KC="$DIR/baneyspaces-signing.keychain-db"
PASS_FILE="$DIR/keychain-password"

# `security -i` reads commands from stdin. The password is base64, so it needs no further quoting.
keychain() { printf '%s\n' "$1" | security -i >/dev/null; }
unlock() { keychain "unlock-keychain -p $(cat "$PASS_FILE") \"$KC\""; }

healthy() {
  [ -f "$KC" ] && [ -s "$PASS_FILE" ] && unlock 2>/dev/null \
    && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"
}

# Uninstalling on the Mac that signs releases keeps the key beside the app's data instead of
# deleting it (uninstall.sh). Bring it back before anything decides the key is gone: a new key
# wouldn't match the requirement every release is checked against. The folder is "BaneySpaces
# Release Signing", or the newest "BaneySpaces Release Signing <date>" when that name was taken.
KEPT="$HOME/Library/BaneySpaces Release Signing"
restore_kept() {
  local src="" d
  if [ -f "$KEPT/baneyspaces-signing.keychain-db" ]; then
    src=$KEPT
  else
    for d in "$KEPT "*; do   # the dates sort oldest first, so the last one is the newest
      if [ -f "$d/baneyspaces-signing.keychain-db" ]; then src=$d; fi
    done
  fi
  [ -n "$src" ] || return 0
  rmdir "$DIR" 2>/dev/null || true   # an empty folder is in the way of moving the whole one
  if [ ! -e "$DIR" ]; then
    mkdir -p "$(dirname "$DIR")"
    mv "$src" "$DIR"
  else
    # Something is already there: move the contents over, dotfiles included.
    local f
    for f in "$src"/* "$src"/.[!.]*; do
      [ -e "$f" ] || continue
      mv "$f" "$DIR"/
    done
    rmdir "$src" 2>/dev/null || true
  fi
  chmod 700 "$DIR"
  echo "note: restored the BaneySpaces release signing key from $src" >&2
}
if [ ! -f "$KC" ] && [ ! -s "$PASS_FILE" ]; then restore_kept; fi
# For the test: stop after the restore, before anything touches a keychain.
[ -z "${BANEYSPACES_SIGNING_RESTORE_ONLY:-}" ] || exit 0

# A new certificate means macOS no longer recognizes the app and its Accessibility switch stops
# working, so an existing identity is only replaced when it is really gone. A failed unlock gets a
# second try first: `security` can fail once right after login or while the keychain is busy.
if ! healthy && [ -f "$KC" ] && [ -s "$PASS_FILE" ]; then
  sleep 1
  healthy || true
fi

if ! healthy; then
  if [ -f "$KC" ] || [ -s "$PASS_FILE" ]; then
    echo "note: the BaneySpaces signing key was unusable and has been replaced. macOS will treat the" >&2
    echo "      new build as a different app: open setup and click Fix Permission to allow it again." >&2
  fi
  # Missing, half-made, or the password no longer matches: start over.
  security delete-keychain "$KC" 2>/dev/null || rm -f "$KC"
  mkdir -p "$DIR" && chmod 700 "$DIR"
  umask 077
  head -c 24 /dev/urandom | base64 | tr -d '/+=' > "$PASS_FILE"
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 7300 \
    -config "$TMP/cfg" >/dev/null 2>&1
  head -c 12 /dev/urandom | base64 | tr -d '/+=' > "$TMP/p12pass"
  openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
    -passout "file:$TMP/p12pass" >/dev/null 2>&1 \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
    -passout "file:$TMP/p12pass" >/dev/null 2>&1
  PW=$(cat "$PASS_FILE")
  keychain "create-keychain -p $PW \"$KC\""
  security set-keychain-settings -l -t 300 "$KC"   # locks itself 5 minutes after a build
  unlock
  keychain "import \"$TMP/id.p12\" -k \"$KC\" -P $(cat "$TMP/p12pass") -T /usr/bin/codesign"
  keychain "set-key-partition-list -S apple-tool:,apple: -s -k $PW \"$KC\""
  unset PW
  healthy || { echo "could not create the BaneySpaces signing identity" >&2; exit 1; }
fi
security set-keychain-settings -l -t 300 "$KC"   # also tightens keychains made before this setting
printf '%s\t%s\n' "$NAME" "$KC"
