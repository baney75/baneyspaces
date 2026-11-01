#!/bin/bash
# Soak gate before promoting a BaneySpaces build to GitHub Latest / stable.
# Usage:
#   scripts/soak-check.sh [--hours N] [--render-iters K] [--ci] [--cmd-tab]
# Optional env: BANEYSPACES_APP, BANEYSPACES_EXPECT_COMMIT, BANEYSPACES_SOAK_STARTED (unix seconds).
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
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! [[ "$HOURS" =~ ^[0-9]+$ ]] || [ "$HOURS" -lt 1 ]; then
  echo "hours must be an integer >= 1 (got: $HOURS)" >&2; exit 2
fi
if ! [[ "$RENDER_ITERS" =~ ^[0-9]+$ ]] || [ "$RENDER_ITERS" -lt 1 ]; then
  echo "render-iters must be an integer >= 1 (got: $RENDER_ITERS)" >&2; exit 2
fi

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
EXPECT_COMMIT="${BANEYSPACES_EXPECT_COMMIT:-}"
if [ ! -x "$BIN" ]; then fail "BaneySpaces binary missing at $BIN"; else pass "app present: $APP"; fi

VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)
COMMIT=$(/usr/libexec/PlistBuddy -c 'Print :BaneySpacesCommit' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)
HASH=$(shasum -a 256 "$BIN" 2>/dev/null | awk '{print $1}')
echo "candidate version=$VER commit=$COMMIT sha256=$HASH" | tee -a "$RECEIPT"
if [ -n "$EXPECT_COMMIT" ]; then
  case "$COMMIT" in
    "$EXPECT_COMMIT"|$EXPECT_COMMIT*) pass "commit matches BANEYSPACES_EXPECT_COMMIT=$EXPECT_COMMIT" ;;
    *) fail "commit $COMMIT does not match BANEYSPACES_EXPECT_COMMIT=$EXPECT_COMMIT" ;;
  esac
fi

PID=$(pgrep -x BaneySpaces | head -1 || true)
if [ -z "$PID" ]; then
  fail "BaneySpaces not running (start the build under soak first)"
else
  EXE_PATH=$(lsof -p "$PID" 2>/dev/null | awk '$4=="txt" {print $9; exit}')
  REAL_BIN=$(realpath "$BIN" 2>/dev/null || echo "$BIN")
  REAL_EXE=$(realpath "$EXE_PATH" 2>/dev/null || echo "$EXE_PATH")
  if [ -n "$EXE_PATH" ] && [ "$REAL_EXE" = "$REAL_BIN" ]; then
    pass "running pid $PID is candidate binary"
  elif [ -n "$EXE_PATH" ]; then
    fail "running pid $PID exe=$EXE_PATH is not candidate $BIN"
  else
    pass "running pid $PID (could not resolve exe path; recorded candidate hash above)"
  fi
  echo "running_pid=$PID" >>"$RECEIPT"
fi

if [ -f "$SUPPORT/crash-ledger.json" ]; then
  NOW=$(date +%s)
  NEED=$((HOURS * 3600))
  if [ -n "${BANEYSPACES_SOAK_STARTED:-}" ]; then
    STARTED=$BANEYSPACES_SOAK_STARTED
  else
    STARTED=$(python3 -c 'import json,pathlib; p=pathlib.Path.home()/"Library/Application Support/BaneySpaces/crash-ledger.json"; d=json.loads(p.read_text()); runs=d.get("running") or [];
print(int(min(r.get("started",0) for r in runs)) if runs else 0)')
  fi
  if [ -z "$STARTED" ] || [ "$STARTED" = "0" ]; then
    fail "could not read soak start from crash ledger running[].started (or set BANEYSPACES_SOAK_STARTED)"
  else
    ELAPSED=$((NOW - STARTED))
    echo "soak_started=$STARTED elapsed_s=$ELAPSED need_s=$NEED" | tee -a "$RECEIPT"
    if [ "$ELAPSED" -ge "$NEED" ]; then
      pass "elapsed soak ${ELAPSED}s >= ${NEED}s (${HOURS}h)"
    else
      fail "elapsed soak ${ELAPSED}s < ${NEED}s (${HOURS}h) — leave the candidate running"
    fi
  fi
  CRASH_N=$(python3 -c 'import json,pathlib,time,sys; hours=float(sys.argv[1]); p=pathlib.Path.home()/"Library/Application Support/BaneySpaces/crash-ledger.json"; d=json.loads(p.read_text()); now=time.time(); print(sum(1 for c in (d.get("crashes") or []) if now-float(c)<hours*3600))' "$HOURS")
  if [ "$CRASH_N" = "0" ]; then
    pass "crash ledger abnormal exits in window: 0"
  else
    fail "crash ledger abnormal exits in window: $CRASH_N"
  fi
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

i=1
while [ "$i" -le "$RENDER_ITERS" ]; do
  TMP=$(mktemp -d /tmp/bs-soak-render.XXXX)
  if "$BIN" --render "$TMP" >/dev/null 2>&1; then pass "--render default iter $i"; else fail "--render default iter $i"; fi
  if BANEYSPACES_RENDER_SAMPLE=reported "$BIN" --render "$TMP" >/dev/null 2>&1; then pass "--render reported iter $i"; else fail "--render reported iter $i"; fi
  rm -rf "$TMP"
  i=$((i + 1))
done

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
