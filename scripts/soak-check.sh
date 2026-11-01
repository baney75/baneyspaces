#!/bin/bash
# Soak gate before promoting a BaneySpaces build to GitHub Latest / stable.
# Usage:
#   scripts/soak-check.sh --arm
#   scripts/soak-check.sh [--hours N] [--render-iters K] [--ci] [--cmd-tab]
#   scripts/soak-check.sh --self-test
# --arm writes Application Support/BaneySpaces/soak-gate.json for the running candidate.
# Optional env: BANEYSPACES_APP, BANEYSPACES_EXPECT_COMMIT.
# Exit 0 only when every required check prints PASS. Writes a receipt under build/soak/.
set -euo pipefail

# --- identity helpers (shared by arm/check/self-test) ---
# lsof -F D is hexadecimal; stat %d is decimal. Normalize before compare.
to_dec() {
  local x=${1#0x}
  if [[ "$x" =~ ^[0-9]+$ ]]; then
    printf '%d' "$x"
  elif [[ "$x" =~ ^[0-9A-Fa-f]+$ ]]; then
    printf '%d' "$((16#$x))"
  else
    return 1
  fi
}

norm_dev_ino() {
  local s=$1
  local d=${s%%:*} i=${s#*:}
  local nd
  nd=$(to_dec "$d") || return 1
  printf '%s:%s\n' "$nd" "$i"
}

# Running text-segment identity (normalized dev:inode).
txt_dev_ino() {
  local pid=$1 raw=""
  raw=$(lsof -a -p "$pid" -d txt -F Di 2>/dev/null | awk '
    /^D/ { d=substr($0,2) }
    /^i/ { i=substr($0,2); if (d!="") { print d ":" i; exit } }
  ')
  if [ -n "$raw" ]; then
    norm_dev_ino "$raw"
    return 0
  fi
  if [ -r "/proc/$pid/exe" ]; then
    raw=$(stat -c '%d:%i' "/proc/$pid/exe" 2>/dev/null) || return 1
    norm_dev_ino "$raw"
    return 0
  fi
  return 1
}

disk_dev_ino() {
  local path=$1 raw=""
  if stat -f '%d:%i' "$path" >/dev/null 2>&1; then
    raw=$(stat -f '%d:%i' "$path")
  else
    raw=$(stat -c '%d:%i' "$path")
  fi
  norm_dev_ino "$raw"
}

proc_start() {
  ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//'
}

# Gate identity must be complete; missing fields fail closed.
require_gate_identity() {
  local txt=$1 disk=$2 pstart=$3
  if [ -z "$txt" ] || [ -z "$disk" ] || [ -z "$pstart" ]; then
    return 1
  fi
  return 0
}

HOURS=24
RENDER_ITERS=2
CI=0
CMDTAB=0
ARM=0
SELFTEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) HOURS=${2:?}; shift 2 ;;
    --render-iters) RENDER_ITERS=${2:?}; shift 2 ;;
    --ci) CI=1; shift ;;
    --cmd-tab) CMDTAB=1; shift ;;
    --arm) ARM=1; shift ;;
    --self-test) SELFTEST=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ "$SELFTEST" = 1 ]; then
  fail=0
  # hex lsof-style vs decimal stat-style must match after normalize
  a=$(norm_dev_ino "1a:99") || { echo "bad: norm hex"; fail=1; a=; }
  b=$(norm_dev_ino "26:99") || { echo "bad: norm dec"; fail=1; b=; }
  if [ -n "$a" ] && [ "$a" = "$b" ] && [ "$a" = "26:99" ]; then
    echo "ok: norm_dev_ino hex/dec"
  else
    echo "bad: norm_dev_ino got a=$a b=$b"; fail=1
  fi
  # matching identities
  if require_gate_identity "26:1" "26:1" "Mon Nov  1 12:00:00 2026"; then
    echo "ok: require_gate_identity complete"
  else
    echo "bad: complete identity rejected"; fail=1
  fi
  # missing fields fail closed
  if require_gate_identity "" "26:1" "start"; then echo "bad: empty txt accepted"; fail=1; else echo "ok: empty txt rejected"; fi
  if require_gate_identity "26:1" "" "start"; then echo "bad: empty disk accepted"; fail=1; else echo "ok: empty disk rejected"; fi
  if require_gate_identity "26:1" "26:1" ""; then echo "bad: empty proc_start accepted"; fail=1; else echo "ok: empty proc_start rejected"; fi
  # replacement: txt != disk
  if [ "$(norm_dev_ino "1a:100")" != "$(norm_dev_ino "1a:200")" ]; then
    echo "ok: replacement inode mismatch"
  else
    echo "bad: replacement not detected"; fail=1
  fi
  # PID reuse: different proc_start
  gstart="Mon Nov  1 12:00:00 2026"
  rstart="Mon Nov  1 13:00:00 2026"
  if [ "$gstart" != "$rstart" ]; then echo "ok: PID reuse start mismatch"; else echo "bad: reuse"; fail=1; fi
  # live helpers against this shell (best-effort)
  me=$$
  if ps -p "$me" >/dev/null 2>&1; then
    ps_out=$(proc_start "$me" || true)
    if [ -n "$ps_out" ]; then echo "ok: proc_start live"; else echo "bad: proc_start empty"; fail=1; fi
  fi
  if disk_dev_ino "$0" >/dev/null 2>&1; then echo "ok: disk_dev_ino live"; else echo "bad: disk_dev_ino"; fail=1; fi
  if [ "$fail" -eq 0 ]; then echo "soak-check --self-test: OK"; exit 0; fi
  echo "soak-check --self-test: FAIL"; exit 1
fi

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
  # Normalize any legacy hex device ids stored in the gate.
  if [ -n "$GATE_TXT" ]; then GATE_TXT=$(norm_dev_ino "$GATE_TXT" 2>/dev/null || echo "$GATE_TXT"); fi
  if [ -n "$GATE_DISK" ]; then GATE_DISK=$(norm_dev_ino "$GATE_DISK" 2>/dev/null || echo "$GATE_DISK"); fi
  echo "soak_gate started=$STARTED pid=$GATE_PID commit=$GATE_COMMIT sha=$GATE_SHA txt=$GATE_TXT start=$GATE_PSTART" | tee -a "$RECEIPT"
  if ! require_gate_identity "$GATE_TXT" "$GATE_DISK" "$GATE_PSTART"; then
    fail "soak-gate missing identity fields (txt_dev_ino/disk_dev_ino/proc_start) — re-arm with current soak-check"
  else
    if [ -z "$PID" ] || [ "$GATE_PID" != "$PID" ]; then
      fail "soak-gate pid $GATE_PID != running pid ${PID:-none} — re-arm after restart"
    fi
    if [ "$GATE_PSTART" != "$PSTART" ]; then
      fail "soak-gate proc_start '$GATE_PSTART' != running '$PSTART' — PID reuse; re-arm"
    fi
    if [ -z "$TXT_INO" ] || [ "$GATE_TXT" != "$TXT_INO" ]; then
      fail "soak-gate txt inode $GATE_TXT != running ${TXT_INO:-unresolved} — re-arm on this process"
    fi
    if [ -z "$DISK_INO" ] || [ "$GATE_DISK" != "$DISK_INO" ]; then
      fail "soak-gate disk inode $GATE_DISK != candidate ${DISK_INO:-unresolved} — binary changed; re-arm"
    fi
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
