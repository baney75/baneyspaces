#!/usr/bin/env bash
# Runs the root install.sh on Linux end to end against a throwaway HOME: a fresh install that builds and installs
# every part through `polycarp update`, a second run that finds it all current, a run with no Node and no Hyprland,
# checkouts it must refuse, and its helper functions. Your real home is never used: every run gets `env -i` with
# HOME, XDG_RUNTIME_DIR, CARGO_HOME and the browser helper's socket folder inside the temp folder, so no real daemon,
# browser helper, Hyprland session or agent config is reached. `hyprctl` is a stand-in that only records its arguments.
#
# The commit it installs is this checkout's HEAD plus changes to tracked and staged files (`git stash create`, which
# leaves the stash list alone); untracked files are not in it. A small `git` wrapper first on PATH serves clones and
# fetches of the Polycarp repo from that commit, so origin still reads as GitHub, as on a real install. Everything else
# (crates, npm packages, the hands engine, the extension's siblings) comes from the network.
#
# Needs git, cargo, a C compiler, and Node 20 or later for the browser half (skipped with a note without it).
# The builds take a few GB: on a RAM-backed /tmp, set TMPDIR=/var/tmp. KEEP=1 keeps the temp folder.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
REPO=https://github.com/baney75/polycarp.git
REAL_HOME=$HOME
T="$(mktemp -d "${TMPDIR:-/tmp}/pc-install.XXXXXX")"
cleanup() { if [ -n "${KEEP:-}" ]; then echo "kept $T"; else chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"; fi; }
trap cleanup EXIT
H="$T/home"
mkdir -p "$H" "$T/bin" "$T/bin-bare" "$T/run" "$T/sock" "$T/cargo"
chmod 700 "$T/run" "$T/sock"
N=0; F=0
ok() { N=$((N+1)); echo "  ok   $1"; }; no() { N=$((N+1)); F=$((F+1)); echo "  FAIL $1"; }
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi; }
[ "$H" != "$REAL_HOME" ] || { echo "the throwaway HOME is the real one; stopping" >&2; exit 1; }

# What a real install in your home would change. Anything this test builds or writes names its temp folder (a Rust
# binary keeps its source paths), so a real file that mentions it was reached. A file that changed without naming it
# was changed by something else on this machine, such as a deploy of main, and is only listed.
watched=("$REAL_HOME/.local/bin/polycarp" "$REAL_HOME/.local/bin/baneyspaces" "$REAL_HOME/.local/bin/polycarp-browser"
         "$REAL_HOME/.config/hypr/hyprland.lua" "$REAL_HOME/.config/hypr/baneyspaces/baneyspaces-autostart.lua"
         "$REAL_HOME/.config/polycarp/source.toml"
         "$REAL_HOME/.local/share/polycarp/browser/source/dist-chrome/manifest.json")
fingerprint() { local f; for f in "${watched[@]}"; do stat -c '%n %i %s %Y' "$f" 2>/dev/null || echo "$f absent"; done; }
untouched() {
  local f
  for f in "${watched[@]}"; do
    [ -e "$f" ] || continue
    if grep -aqF "$T" "$f" || readlink -f "$f" | grep -qF "$T"; then echo "  $f names $T"; return 1; fi
  done
}
before=$(fingerprint)

# The commit under test, as origin/main of a local stand-in for GitHub.
REV=$(git -C "$ROOT" stash create 2>/dev/null || true)
[ -n "$REV" ] || REV=$(git -C "$ROOT" rev-parse HEAD)
git init -q --bare -b main "$T/origin.git"
# The CI checkout is shallow; this lets it push.
git -C "$T/origin.git" config receive.shallowUpdate true
git -C "$ROOT" push -q "$T/origin.git" "$REV:refs/heads/main" || { echo "could not push $REV to the stand-in origin" >&2; exit 1; }

REAL_GIT=$(command -v git)
for dir in "$T/bin" "$T/bin-bare"; do
  cat > "$dir/git" <<EOF
#!/bin/bash
# Clones and fetches of $REPO come from $T/origin.git. \`remote get-url\` is left alone, so it still says GitHub.
sub=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case \$a in -C|-c) skip=1 ;; -*) ;; *) sub=\$a; break ;; esac
done
case \$sub in
  clone|fetch|pull|ls-remote) exec "$REAL_GIT" -c "url.file://$T/origin.git.insteadOf=$REPO" "\$@" ;;
esac
exec "$REAL_GIT" "\$@"
EOF
  printf '#!/bin/sh\necho "$*" >> "%s/hyprctl.calls"\n' "$T" > "$dir/hyprctl"
  chmod +x "$dir/git" "$dir/hyprctl"
done
# The system folders with Node left out, for the run without it (a distribution's node lives in /usr/bin).
mkdir -p "$T/sys"
for p in /usr/bin/* /bin/*; do
  case ${p##*/} in node|nodejs|npm|npx|corepack) continue ;; esac
  [ -e "$T/sys/${p##*/}" ] || [ -L "$T/sys/${p##*/}" ] || ln -s "$p" "$T/sys/${p##*/}"
done
# Node goes in by link only, so nothing else in its folder (codex sits next to it under mise) is on PATH.
node_ok=0
for tool in node npm npx; do p=$(command -v "$tool" 2>/dev/null) && ln -s "$p" "$T/bin/$tool"; done
v=$("$T/bin/node" --version 2>/dev/null || true); major=${v#v}; major=${major%%.*}
case $major in ''|*[!0-9]*) ;; *) [ "$major" -ge 20 ] && [ -x "$T/bin/npm" ] && node_ok=1 ;; esac
[ "$node_ok" = 1 ] || echo "  note: no Node 20 or later here (${v:-none}), so the browser half is not checked"
CARGO_DIR=$(dirname "$(command -v cargo)")
RUSTUP=${RUSTUP_HOME:-$REAL_HOME/.rustup}

# install.sh with only what a fresh login would have. Extra NAME=value pairs go first.
install_sh() {
  local path=$1; shift
  ( cd "$H" && env -i HOME="$H" PATH="$path" USER="$(id -un)" LOGNAME="$(id -un)" LANG=C.UTF-8 TERM=dumb \
      RUSTUP_HOME="$RUSTUP" CARGO_HOME="$T/cargo" XDG_RUNTIME_DIR="$T/run" \
      POLYCARP_SOCKET_DIR="$T/sock" TABKYRA_SOCKET_DIR="$T/sock" POLYCARP_NO_SYSTEM_SPOTS=1 \
      "$@" bash "$ROOT/install.sh" )
}
in_env() {
  ( cd "$H" && env -i HOME="$H" PATH="$T/bin:$CARGO_DIR:/usr/bin:/bin" USER="$(id -un)" LANG=C.UTF-8 \
      XDG_RUNTIME_DIR="$T/run" POLYCARP_SOCKET_DIR="$T/sock" TABKYRA_SOCKET_DIR="$T/sock" POLYCARP_NO_SYSTEM_SPOTS=1 "$@" )
}
FULL="$T/bin:$CARGO_DIR:/usr/bin:/bin"
case $CARGO_DIR in /usr/bin|/bin) BARE="$T/bin-bare:$T/sys" ;; *) BARE="$T/bin-bare:$CARGO_DIR:$T/sys" ;; esac
LOG="$H/.local/state/polycarp/install.log"
show_failure() { echo "---- output"; cat "$1"; echo "---- last lines of the log"; tail -40 "$LOG" 2>/dev/null; }

echo "The helper functions"
fn() { POLYCARP_INSTALL_FUNCTIONS_ONLY=1 bash -c '. "$1"; shift; "$@"' _ "$ROOT/install.sh" "$@"; }
for url in https://github.com/baney75/polycarp https://github.com/baney75/polycarp.git https://github.com/baney75/polycarp/ \
           https://GitHub.com/Baney75/Polycarp.git git@github.com:baney75/polycarp.git ssh://git@github.com/baney75/polycarp.git; do
  chk "accepts $url" fn is_polycarp_origin "$url"
done
for url in "" https://github.com/someone/polycarp.git https://github.com/baney75/polycarp-fork.git "file://$T/origin.git"; do
  chk "refuses '${url}'" sh -c '! "$@"' _ fn is_polycarp_origin "$url"
done
printf 'NAME="Omarchy"\nID=omarchy\nID_LIKE=arch\n' > "$T/omarchy"
printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\n' > "$T/ubuntu"
printf 'ID="pop"\nID_LIKE="ubuntu debian"\n' > "$T/pop"
printf 'ID=fedora\n' > "$T/fedora"
printf 'ID=nixos\n' > "$T/nixos"
chk "Omarchy gets pacman" test "$(fn fix_line "$T/omarchy" "nodejs npm" "nodejs npm" "nodejs npm")" = "sudo pacman -S nodejs npm"
chk "Ubuntu gets apt" test "$(fn fix_line "$T/ubuntu" base-devel build-essential gcc)" = "sudo apt install build-essential"
chk "Pop!_OS gets apt" test "$(fn fix_line "$T/pop" git git git)" = "sudo apt install git"
chk "Fedora gets dnf" test "$(fn fix_line "$T/fedora" "nodejs npm" "nodejs npm" "nodejs npm")" = "sudo dnf install nodejs npm"
chk "an unknown distribution gets no command" test -z "$(fn fix_line "$T/nixos" git git git)"
chk "a missing os-release gets no command" test -z "$(fn fix_line "$T/none" git git git)"

echo "Checkouts it refuses, before building anything"
mkdir -p "$T/other/cli"; "$REAL_GIT" -C "$T/other" init -q
"$REAL_GIT" -C "$T/other" remote add origin https://github.com/someone/polycarp.git
install_sh "$FULL" POLYCARP_SOURCE="$T/other" >"$T/other.out" 2>&1; rc=$?
chk "a checkout of another repo is refused" test "$rc" -ne 0
chk "and it says why" grep -q 'not the Polycarp repo' "$T/other.out"
chk "and builds nothing there" test ! -e "$T/other/cli/target"
mkdir -p "$T/plain"; : > "$T/plain/file"
install_sh "$FULL" POLYCARP_SOURCE="$T/plain" >"$T/plain.out" 2>&1; rc=$?
chk "a folder that isn't a checkout is refused" sh -c "[ $rc -ne 0 ] && grep -q \"isn't a git checkout\" '$T/plain.out'"
chk "and nothing is installed" test ! -e "$H/.local/bin/polycarp"

echo "A fresh install, every part (this builds everything; several minutes)"
mkdir -p "$H/.config/hypr"
cat > "$H/.config/hypr/hyprland.lua" <<'LUA'
dofile((os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua")
require("hypr.bindings")
LUA
# A browser opened once, so setup has a profile to register the helper with (without one it fails, softly).
mkdir -p "$H/.config/chromium/Default"
start=$SECONDS
install_sh "$FULL" >"$T/first.out" 2>&1; rc=$?
echo "  (took $((SECONDS - start))s)"
chk "install.sh exits 0" test "$rc" = 0
[ "$rc" = 0 ] || show_failure "$T/first.out"
chk "it says Polycarp is installed" grep -q 'Polycarp is installed\.' "$T/first.out"
SRC="$H/.local/share/polycarp/src"
chk "it cloned the source into ~/.local/share/polycarp/src" test -d "$SRC/.git"
chk "whose origin is the GitHub repo" test "$("$REAL_GIT" -C "$SRC" remote get-url origin)" = "$REPO"
chk "it ran polycarp update to the end" grep -q '^polycarp update: done\.' "$LOG"
chk "update remembered the checkout" grep -qF "$SRC" "$H/.config/polycarp/source.toml"
chk "the polycarp command is installed" test -x "$H/.local/bin/polycarp"
chk "the spaces daemon is installed" test -x "$H/.local/bin/baneyspaces"
chk "the hands engine is installed" test -x "$H/.local/share/baneyspaces/engine/agent-desktop"
chk "the Hyprland include is in hyprland.lua" grep -qF -- '>>> baneyspaces' "$H/.config/hypr/hyprland.lua"
chk "the include files are copied" test -f "$H/.config/hypr/baneyspaces/baneyspaces.lua"
chk "the installed command's last steps reloaded Hyprland (the stand-in)" grep -qx reload "$T/hyprctl.calls"
if [ "$node_ok" = 1 ]; then
  chk "the extension is installed outside the cache" test -s "$H/.local/share/polycarp/browser/source/dist-chrome/manifest.json"
  chk "polycarp-browser is linked in ~/.local/bin" test -x "$H/.local/bin/polycarp-browser"
  chk "it says where to load the extension from" grep -qF "$H/.local/share/polycarp/browser/source/dist-chrome" "$T/first.out"
  chk "the helper is registered with the browser" sh -c "ls '$H'/.config/chromium/NativeMessagingHosts/*.json"
fi
chk "it prints polycarp version, at the commit under test" grep -q "${REV:0:7}" "$T/first.out"
chk "it lists what is left to do" grep -q 'Left for you:' "$T/first.out"
chk "it keeps a log" test -s "$LOG"
in_env "$H/.local/bin/polycarp" version --check >"$T/check.out" 2>&1; rc=$?
# 75 is "a part gave no answer in time", which version --check uses for a slow helper or a browser that is asked but
# does not answer. It is never a mismatch or a missing part, so it passes here; 1 (a mismatch) and others do not.
chk "polycarp version --check passes (exit $rc; 0, or 75 for no answer in time)" sh -c "[ $rc = 0 ] || [ $rc = 75 ]"
[ "$rc" = 0 ] || [ "$rc" = 75 ] || cat "$T/check.out"

echo "A second run, with nothing new"
: > "$T/hyprctl.calls"
start=$SECONDS
install_sh "$FULL" >"$T/second.out" 2>&1; rc=$?
echo "  (took $((SECONDS - start))s)"
chk "install.sh exits 0" test "$rc" = 0
[ "$rc" = 0 ] || show_failure "$T/second.out"
chk "it says Polycarp is up to date" grep -q 'Polycarp is up to date\.' "$T/second.out"
chk "update stopped before building anything" sh -c "grep -q '^up to date: ' '$LOG' && ! grep -q '^polycarp update: done' '$LOG'"
chk "and reloaded nothing" test ! -s "$T/hyprctl.calls"

echo "No Node and no Hyprland"
mv "$H/.config/hypr/hyprland.lua" "$T/hyprland.lua.kept"
if PATH="$BARE" command -v node >/dev/null; then
  echo "  note: $BARE still has a node ($(PATH="$BARE" command -v node)), so this part is skipped"
else
  install_sh "$BARE" >"$T/bare.out" 2>&1; rc=$?
  chk "install.sh exits 0" test "$rc" = 0
  [ "$rc" = 0 ] || show_failure "$T/bare.out"
  chk "it says the browser parts are skipped" grep -q "Node and npm aren't installed, so the browser helper and the extension are skipped" "$T/bare.out"
  chk "it says the spaces daemon is Hyprland only" grep -q 'spaces daemon is skipped: it runs on Hyprland only' "$T/bare.out"
  chk "it says how to get Node" grep -qE 'Install Node (and npm|20 or later).*then run polycarp update' "$T/bare.out"
fi
mv "$T/hyprland.lua.kept" "$H/.config/hypr/hyprland.lua"

chk "nothing in your real home was written by this test" untouched
if [ "$(fingerprint)" != "$before" ]; then
  echo "  note: these changed during the run, not by this test (none names $T):"
  diff <(echo "$before") <(fingerprint) | sed -n 's/^> /    /p'
fi
echo "passed $((N-F)), failed $F"
[ "$F" = 0 ] && echo "PASS: one-command-install.sh ($N checks)" || { echo "FAIL: one-command-install.sh"; exit 1; }
