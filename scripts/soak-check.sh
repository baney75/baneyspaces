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

# Running text-segment identity (dev:inode). Prefer lsof -F so a same-path
# binary replace does not look like the still-mapped image.
txt_dev_ino() {
  local pid=$1 out=""
  out=$(lsof -a -p "$pid" -d txt -F Di 2>/dev/null | awk '
    /^D/ { d=substr($0,2) }
    /^i/ { i=substr($0,2); if (d!="") { print d ":" i; exit } }
  ')
  if [ -n "$out" ]; then echo "$out"; return 0; fi
  # Fallback: Linux /proc maps (parish1 tests); not used on soak hosts.
  if [ -r "/proc/$pid/exe" ]; then
    stat -c '%d:%i' "/proc/$pid/exe" 2>/dev/null && return 0
  fi
  return 1
}

disk_dev_ino() {
  local path=$1
  if stat -f '%d:%i' "$path" >/dev/null 2>&1; then
    stat -f '%d:%i' "$path"
  else
    stat -c '%d:%i' "$path"
  fi
}

proc_start() {
  # Absolute start string; empty if unknown. Detects PID reuse across boots.
  ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//'
}

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
DISK_INO=$(disk_dev_ino "$BIN" 2>/dev/null || echo "")

if [ "$ARM" = 1 ]; then
  if [ -z "$PID" ]; then echo "cannot --arm: BaneySpaces not running" >&2; exit 1; fi
  EXE_PATH=$(lsof -p "$PID" 2>/dev/null | awk '$4=="txt" {print $9; exit}')
  REAL_EXE=$(realpath "$EXE_PATH" 2>/dev/null || echo "")
  if [ -z "$REAL_EXE" ] || [ "$REAL_EXE" != "$REAL_BIN" ]; then
    echo "cannot --arm: running exe ($EXE_PATH) is not candidate $BIN" >&2; exit 1
  fi
  TXT_INO=$(txt_dev_ino "$PID" || true)
  if [ -z "$TXT_INO" ] || [ -z "$DISK_INO" ]; then
    echo "cannot --arm: unresolved text/disk inode (fail closed)" >&2; exit 1
  fi
  if [ "$TXT_INO" != "$DISK_INO" ]; then
    echo "cannot --arm: running text inode $TXT_INO != disk $DISK_INO (binary replaced under running process?)" >&2; exit 1
  fi
  PSTART=$(proc_start "$PID")
  if [ -z "$PSTART" ]; then
    echo "cannot --arm: unresolved process start time" >&2; exit 1
  fi
  mkdir -p "$SUPPORT"
  python3 -c 'import json,pathlib,time,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
  "started": int(time.time()),
  "commit": sys.argv[2],
  "pid": int(sys.argv[3]),
  "sha256": sys.argv[4],
  "path": sys.argv[5],
  "txt_dev_ino": sys.argv[6],
  "disk_dev_ino": sys.argv[7],
  "proc_start": sys.argv[8],
}, indent=2) + "\n")' \
    "$GATE" "$COMMIT" "$PID" "$HASH" "$REAL_BIN" "$TXT_INO" "$DISK_INO" "$PSTART"
  echo "armed $GATE commit=$COMMIT pid=$PID sha256=$HASH txt=$TXT_INO start=$PSTART"
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

TXT_INO=""
PSTART=""
if [ -z "$PID" ]; then
  fail "BaneySpaces not running (start the build under soak first)"
else
  EXE_PATH=$(lsof -p "$PID" 2>/dev/null | awk '$4=="txt" {print $9; exit}')
  REAL_EXE=$(realpath "$EXE_PATH" 2>/dev/null || echo "")
  TXT_INO=$(txt_dev_ino "$PID" || true)
  PSTART=$(proc_start "$PID")
  if [ -z "$EXE_PATH" ] || [ -z "$REAL_EXE" ]; then
    fail "could not resolve running executable for pid $PID (fail closed)"
  elif [ -z "$TXT_INO" ]; then
    fail "could not resolve running text inode for pid $PID (fail closed)"
  elif [ -z "$DISK_INO" ]; then
    fail "could not resolve disk inode for candidate (fail closed)"
  elif [ "$REAL_EXE" != "$REAL_BIN" ]; then
    fail "running pid $PID exe=$EXE_PATH is not candidate $BIN"
  elif [ "$TXT_INO" != "$DISK_INO" ]; then
    fail "running text inode $TXT_INO != disk $DISK_INO — binary replaced under feet"
  else
    pass "running pid $PID is candidate binary (txt=disk $TXT_INO)"
  fi
  echo "running_pid=$PID txt=$TXT_INO disk=$DISK_INO start=$PSTART" >>"$RECEIPT"
fi

if [ ! -f "$GATE" ]; then
  fail "soak-gate.json missing — run: scripts/soak-check.sh --arm at the start of the soak"
else
  NOW=$(date +%s)
  NEED=$((HOURS * 3600))
  STARTED=$(python3 -c 'import json,pathlib,sys; print(int(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("started") or 0))' "$GATE")
  GATE_PID=$(python3 -c 'import json,pathlib,sys; print(int(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("pid") or 0))' "$GATE")
  GATE_COMMIT=$(python3 -c 'import json,pathlib,sys; print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("commit") or "")' "$GATE")
  GATE_SHA=$(python3 -c 'import json,pathlib,sys; print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("sha256") or "")' "$GATE")
  GATE_TXT=$(python3 -c 'import json,pathlib,sys; print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("txt_dev_ino") or "")' "$GATE")
  GATE_DISK=$(python3 -c 'import json,pathlib,sys; print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("disk_dev_ino") or "")' "$GATE")
  GATE_PSTART=$(python3 -c 'import json,pathlib,sys; print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("proc_start") or "")' "$GATE")
  echo "soak_gate started=$STARTED pid=$GATE_PID commit=$GATE_COMMIT sha=$GATE_SHA txt=$GATE_TXT start=$GATE_PSTART" | tee -a "$RECEIPT"
  if [ -n "$PID" ] && [ "$GATE_PID" != "$PID" ]; then
    fail "soak-gate pid $GATE_PID != running pid $PID — re-arm after restart"
  fi
  if [ -n "$PID" ] && [ -n "$GATE_PSTART" ] && [ "$GATE_PSTART" != "$PSTART" ]; then
    fail "soak-gate proc_start '$GATE_PSTART' != running '$PSTART' — PID reuse; re-arm"
  fi
  if [ -n "$TXT_INO" ] && [ -n "$GATE_TXT" ] && [ "$GATE_TXT" != "$TXT_INO" ]; then
    fail "soak-gate txt inode $GATE_TXT != running $TXT_INO — re-arm on this process"
  fi
  if [ -n "$DISK_INO" ] && [ -n "$GATE_DISK" ] && [ "$GATE_DISK" != "$DISK_INO" ]; then
    fail "soak-gate disk inode $GATE_DISK != candidate $DISK_INO — binary changed; re-arm"
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
if [ -f "$GATE" ] && [ "${STARTED:-0}" -gt 0 ]; then
  SINCE=$(date -r "$STARTED" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -d "@$STARTED" "+%Y-%m-%d %H:%M:%S")
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
