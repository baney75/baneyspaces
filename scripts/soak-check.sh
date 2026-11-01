#!/bin/bash
# Soak gate before promoting a BaneySpaces build to GitHub Latest / stable.
# Usage:
#   scripts/soak-check.sh [--hours N] [--render-iters K] [--ci] [--cmd-tab]
# Exit 0 only when every required check prints PASS. Writes a receipt under build/soak/.
set -euo pipefail
HOURS=24
RENDER_ITERS=2
CI=0
CMDTAB=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) HOURS=${2:?}; shift 2 ;;
    --render-iters) RENDER_ITERS=${2:?}; shift 2 ;;
    --ci) CI=1; shift ;;
    --cmd-tab) CMDTAB=1; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RECEIPT_DIR="$ROOT/build/soak"
mkdir -p "$RECEIPT_DIR"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RECEIPT="$RECEIPT_DIR/soak-$STAMP.txt"
FAIL=0
pass() { echo "PASS  $*"; echo "PASS  $*" >>"$RECEIPT"; }
fail() { echo "FAIL  $*"; echo "FAIL  $*" >>"$RECEIPT"; FAIL=1; }
skip() { echo "SKIP  $*"; echo "SKIP  $*" >>"$RECEIPT"; }

{
  echo "BaneySpaces soak-check $STAMP"
  echo "hours=$HOURS render_iters=$RENDER_ITERS ci=$CI"
} | tee "$RECEIPT"

if [ "$CI" = 1 ]; then
  if [ -f "$ROOT/Sources/BaneySpacesCore/CrashLoopGuard.swift" ]; then
    pass "CrashLoopGuard.swift present"
  else
    fail "CrashLoopGuard.swift missing"
  fi
  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x "$ROOT/scripts/soak-check.sh"; then pass "shellcheck soak-check.sh"; else fail "shellcheck soak-check.sh"; fi
  else
    skip "shellcheck not installed"
  fi
  if [ "$FAIL" -eq 0 ]; then
    echo "SOAK PASSED (ci mode)" | tee -a "$RECEIPT"
    exit 0
  fi
  echo "SOAK FAILED (ci mode)" | tee -a "$RECEIPT"
  exit 1
fi

APP="${BANEYSPACES_APP:-$HOME/Applications/BaneySpaces.app}"
BIN="$APP/Contents/MacOS/BaneySpaces"
SUPPORT="$HOME/Library/Application Support/BaneySpaces"
if [ ! -x "$BIN" ]; then fail "BaneySpaces binary missing at $BIN"; else pass "app present: $APP"; fi

if pgrep -x BaneySpaces >/dev/null 2>&1; then
  pass "BaneySpaces process running"
else
  fail "BaneySpaces not running (start the build under soak first)"
fi

if [ -f "$SUPPORT/crash-ledger.json" ]; then
  pass "crash ledger present"
else
  fail "crash ledger missing (app never completed a guarded launch)"
fi

SINCE=$(date -v-"${HOURS}"H "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -d "$HOURS hours ago" "+%Y-%m-%d %H:%M:%S")
CRASHES=$(find "$HOME/Library/Logs/DiagnosticReports" -name "BaneySpaces*" -newermt "$SINCE" 2>/dev/null | wc -l | tr -d " ")
if [ "${CRASHES:-0}" = "0" ]; then
  pass "DiagnosticReports BaneySpaces crashes since ${HOURS}h: 0"
else
  fail "DiagnosticReports BaneySpaces crashes since ${HOURS}h: $CRASHES"
fi

if launchctl print "gui/$(id -u)/com.baney.baneyspaces.mc-watchdog" >/dev/null 2>&1; then
  pass "mc-watchdog launch agent loaded"
else
  fail "mc-watchdog launch agent not loaded"
fi

if [ -f "$SUPPORT/mc-watchdog.sh" ] && [ -f "$SUPPORT/mc-restore.sh" ]; then
  pass "mc-watchdog scripts in Application Support"
else
  fail "mc-watchdog scripts missing under Application Support"
fi

if command -v swift >/dev/null 2>&1; then
  if [ ! -f "$ROOT/engine/lib/libagent_desktop_ffi.dylib" ] && [ -x "$ROOT/scripts/build-engine.sh" ]; then
    (cd "$ROOT" && make engine) || fail "make engine"
  fi
  if (cd "$ROOT" && swift test --filter CrashLoopGuardTests) >/tmp/bs-soak-tests.log 2>&1; then
    pass "CrashLoopGuardTests"
  else
    fail "CrashLoopGuardTests (see /tmp/bs-soak-tests.log)"
  fi
else
  skip "swift not available"
fi

if [ -x "$BIN" ]; then
  i=1
  while [ "$i" -le "$RENDER_ITERS" ]; do
    TMP=$(mktemp -d /tmp/bs-soak-render.XXXX)
    if "$BIN" --render "$TMP" >/dev/null 2>&1; then pass "--render default iter $i"; else fail "--render default iter $i"; fi
    if BANEYSPACES_RENDER_SAMPLE=reported "$BIN" --render "$TMP" >/dev/null 2>&1; then pass "--render reported iter $i"; else fail "--render reported iter $i"; fi
    rm -rf "$TMP"
    i=$((i + 1))
  done
fi

if [ "$CMDTAB" = 1 ]; then
  skip "Cmd-Tab smoke: operator must confirm switcher by hand (not automated)"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "SOAK PASSED" | tee -a "$RECEIPT"
  echo "receipt=$RECEIPT"
  exit 0
fi
echo "SOAK FAILED" | tee -a "$RECEIPT"
echo "receipt=$RECEIPT"
exit 1
