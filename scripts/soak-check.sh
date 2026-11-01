#!/bin/bash
# Soak gate before promoting a BaneySpaces build to GitHub Latest / stable.
# Usage:
#   scripts/soak-check.sh --arm
#   scripts/soak-check.sh [--hours N] [--render-iters K] [--ci] [--cmd-tab]
# --arm writes Application Support/BaneySpaces/soak-gate.json for the running candidate.
# Optional env: BANEYSPACES_APP, BANEYSPACES_EXPECT_COMMIT.
# Exit 0 only when every required check prints PASS. Writes a receipt under build/soak/.
set -euo pipefail
HOURS=24
RENDER_ITERS=2
CI=0
CMDTAB=0
ARM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) HOURS=${2:?}; shift 2 ;;
    --render-iters) RENDER_ITERS=${2:?}; shift 2 ;;
    --ci) CI=1; shift ;;
    --cmd-tab) CMDTAB=1; shift ;;
    --arm) ARM=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
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
GATE="$SUPPORT/soak-gate.json"
if [ ! -x "$BIN" ]; then echo "BaneySpaces binary missing at $BIN" >&2; exit 1; fi

VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)
COMMIT=$(/usr/libexec/PlistBuddy -c 'Print :BaneySpacesCommit' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)
HASH=$(shasum -a 256 "$BIN" 2>/dev/null | awk '{print $1}')
PID=$(pgrep -x BaneySpaces | head -1 || true)
REAL_BIN=$(realpath "$BIN" 2>/dev/null || echo "$BIN")

if [ "$ARM" = 1 ]; then
  if [ -z "$PID" ]; then echo "cannot --arm: BaneySpaces not running" >&2; exit 1; fi
  EXE_PATH=$(lsof -p "$PID" 2>/dev/null | awk '$4=="txt" {print $9; exit}')
  REAL_EXE=$(realpath "$EXE_PATH" 2>/dev/null || echo "")
  if [ -z "$REAL_EXE" ] || [ "$REAL_EXE" != "$REAL_BIN" ]; then
    echo "cannot --arm: running exe ($EXE_PATH) is not candidate $BIN" >&2; exit 1
  fi
  mkdir -p "$SUPPORT"
  python3 -c 'import json,pathlib,time,sys; pathlib.Path(sys.argv[1]).write_text(json.dumps({"started":int(time.time()),"commit":sys.argv[2],"pid":int(sys.argv[3]),"sha256":sys.argv[4],"path":sys.argv[5]}, indent=2)+"\n")' \
    "$GATE" "$COMMIT" "$PID" "$HASH" "$REAL_BIN"
  echo "armed $GATE commit=$COMMIT pid=$PID sha256=$HASH"
  exit 0
fi

echo "candidate version=$VER commit=$COMMIT sha256=$HASH" | tee -a "$RECEIPT"
if [ -n "$EXPECT_COMMIT" ]; then
  case "$COMMIT" in
    "$EXPECT_COMMIT"|$EXPECT_COMMIT*) pass "commit matches BANEYSPACES_EXPECT_COMMIT=$EXPECT_COMMIT" ;;
    *) fail "commit $COMMIT does not match BANEYSPACES_EXPECT_COMMIT=$EXPECT_COMMIT" ;;
  esac
else
  pass "app present: $APP"
fi

if [ -z "$PID" ]; then
  fail "BaneySpaces not running (start the build under soak first)"
else
  EXE_PATH=$(lsof -p "$PID" 2>/dev/null | awk '$4=="txt" {print $9; exit}')
  REAL_EXE=$(realpath "$EXE_PATH" 2>/dev/null || echo "")
  if [ -z "$EXE_PATH" ] || [ -z "$REAL_EXE" ]; then
    fail "could not resolve running executable for pid $PID (fail closed)"
  elif [ "$REAL_EXE" = "$REAL_BIN" ]; then
    pass "running pid $PID is candidate binary"
  else
    fail "running pid $PID exe=$EXE_PATH is not candidate $BIN"
  fi
  echo "running_pid=$PID" >>"$RECEIPT"
fi

if [ ! -f "$GATE" ]; then
  fail "soak-gate.json missing — run: scripts/soak-check.sh --arm at the start of the soak"
else
  NOW=$(date +%s)
  NEED=$((HOURS * 3600))
  STARTED=$(python3 -c 'import json,pathlib,sys; print(int(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("started",0)))' "$GATE")
  GATE_PID=$(python3 -c 'import json,pathlib,sys; print(int(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("pid",0)))' "$GATE")
  GATE_COMMIT=$(python3 -c 'import json,pathlib,sys; print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("commit",""))' "$GATE")
  GATE_SHA=$(python3 -c 'import json,pathlib,sys; print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("sha256",""))' "$GATE")
  echo "soak_gate started=$STARTED pid=$GATE_PID commit=$GATE_COMMIT sha=$GATE_SHA" | tee -a "$RECEIPT"
  if [ -n "$PID" ] && [ "$GATE_PID" != "$PID" ]; then
    fail "soak-gate pid $GATE_PID != running pid $PID — re-arm after restart"
  fi
  if [ "$GATE_SHA" != "$HASH" ]; then
    fail "soak-gate sha256 $GATE_SHA != candidate $HASH — re-arm on this binary"
  fi
  if [ -z "$STARTED" ] || [ "$STARTED" = "0" ]; then
    fail "soak-gate.json missing started"
  else
    ELAPSED=$((NOW - STARTED))
    echo "soak_started=$STARTED elapsed_s=$ELAPSED need_s=$NEED" | tee -a "$RECEIPT"
    if [ "$ELAPSED" -ge "$NEED" ]; then
      pass "elapsed soak ${ELAPSED}s >= ${NEED}s (${HOURS}h) for armed candidate"
    else
      fail "elapsed soak ${ELAPSED}s < ${NEED}s (${HOURS}h) — leave the armed candidate running"
    fi
  fi
fi

SINCE=$(date -v-"${HOURS}"H "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -d "$HOURS hours ago" "+%Y-%m-%d %H:%M:%S")
# Prefer soak-gate started for DiagnosticReports lookback when newer than HOURS window start.
if [ -f "$GATE" ]; then
  GATE_STARTED=$(python3 -c 'import json,pathlib,sys; print(int(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("started",0)))' "$GATE")
  if [ "$GATE_STARTED" -gt 0 ]; then
    SINCE=$(date -r "$GATE_STARTED" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -d "@$GATE_STARTED" "+%Y-%m-%d %H:%M:%S")
  fi
fi
CRASHES=$(find "$HOME/Library/Logs/DiagnosticReports" -name "BaneySpaces*" -newermt "$SINCE" 2>/dev/null | wc -l | tr -d " ")
if [ "${CRASHES:-0}" = "0" ]; then
  pass "DiagnosticReports BaneySpaces crashes since soak start: 0"
else
  fail "DiagnosticReports BaneySpaces crashes since soak start: $CRASHES"
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
