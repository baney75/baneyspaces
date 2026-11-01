#!/bin/bash
# The soak gate a build passes before it is published as a stable release. A published release that
# isn't a prerelease is what the Stable channel offers (the updater takes the newest one, not just
# the one marked Latest), so the release stays a draft until this passes and Sol approves.
# See "Stable releases" in AGENTS.md.
#
#   scripts/soak-check.sh [--hours N] [--iterations K]   on rectory1, with the candidate installed and running
#   scripts/soak-check.sh --ci [--iterations K]          on a macOS runner: no installed app to soak
#
# Run it from the candidate's commit (the release tag checked out). Every check prints PASS, FAIL or
# SKIP; it exits 0 only when none failed, and writes a receipt to build/soak/ for the release PR.
#
# Live checks (not with --ci):
#   - the running BaneySpaces is the candidate commit and has run at least N hours (default 24)
#   - no BaneySpaces crash report in DiagnosticReports in those N hours
#   - the crash ledger holds no crash and no run whose process died without a clean quit
#   - the Mission Control watchdog is armed: its launch agent loaded, its scripts in place, and a
#     fresh heartbeat from the running app
# Every run:
#   - CrashLoopGuardTests pass
#   - `BaneySpaces --render` exits 0 and draws, K times (default 5; 20 with --ci) with the default
#     sample and K times with BANEYSPACES_RENDER_SAMPLE=reported, and no crash report appears meanwhile
#   - optional, --cmd-tab: asks whether the ⌘Tab smoke (hold ⌘, Tab through three apps, let go on
#     the third, it comes forward) was done by hand on this build
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

HOURS=24
ITERATIONS=""
CI=0
CMD_TAB=0
APP_BIN=""
usage() { echo "usage: scripts/soak-check.sh [--ci] [--hours N] [--iterations K] [--app path/to/BaneySpaces] [--cmd-tab]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --ci) CI=1 ;;
    --hours) [ $# -ge 2 ] || usage; HOURS=$2; shift ;;
    --iterations) [ $# -ge 2 ] || usage; ITERATIONS=$2; shift ;;
    --app) [ $# -ge 2 ] || usage; APP_BIN=$2; shift ;;
    --cmd-tab) CMD_TAB=1 ;;
    *) usage ;;
  esac
  shift
done
[[ "$HOURS" =~ ^[0-9]+$ ]] || usage
[ -n "$ITERATIONS" ] || { [ "$CI" = 1 ] && ITERATIONS=20 || ITERATIONS=5; }
[[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]] || usage

SUPPORT="$HOME/Library/Application Support/BaneySpaces"
LABEL=com.baney.baneyspaces.mc-watchdog
REPORT_DIRS=("$HOME/Library/Logs/DiagnosticReports" "$HOME/Library/Logs/DiagnosticReports/Retired" "/Library/Logs/DiagnosticReports")
VERSION=$(cat VERSION)
COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
START=$(date +%s)

FAILED=0
LINES=()
result() {
  local line="$1  $2: $3"
  LINES+=("$line")
  echo "$line"
  [ "$1" = FAIL ] && FAILED=$((FAILED + 1))
  return 0
}

# Seconds since the epoch a file was last changed (GNU stat first: BSD stat rejects -c without output).
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# BaneySpaces crash reports changed since $1 (seconds since the epoch), one path per line.
crash_reports_since() {
  local dir f t
  for dir in "${REPORT_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/BaneySpaces*.ips "$dir"/BaneySpaces*.crash; do
      [ -e "$f" ] || continue
      t=$(mtime "$f") || continue
      [ "$t" -ge "$1" ] && echo "$f"
    done
  done
  return 0
}

# ps's elapsed time ([[dd-]hh:]mm:ss) in seconds.
elapsed_seconds() {
  local e=$1 d=0 h=0 m=0 s=0
  case "$e" in *-*) d=${e%%-*}; e=${e#*-} ;; esac
  IFS=: read -r -a parts <<< "$e"
  case ${#parts[@]} in
    3) h=${parts[0]}; m=${parts[1]}; s=${parts[2]} ;;
    2) m=${parts[0]}; s=${parts[1]} ;;
    *) return 1 ;;
  esac
  echo $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

echo "Soak check for BaneySpaces $VERSION ($COMMIT) on $(hostname -s 2>/dev/null || hostname), $([ "$CI" = 1 ] && echo "CI, $ITERATIONS renders each" || echo "live, $HOURS h, $ITERATIONS renders each")"

if [ "$CI" = 1 ]; then
  result SKIP "live soak" "--ci: no installed app here; rectory1's live run is the gate"
else
  # The running app is the one whose process id the heartbeat holds (what the watchdog trusts too).
  PID=$(head -n 1 "$SUPPORT/mc-heartbeat" 2>/dev/null | tr -dc 0-9)
  if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
    result FAIL "running build" "no running BaneySpaces holds the heartbeat ($SUPPORT/mc-heartbeat)"
  else
    EXE=$(ps -o comm= -p "$PID" 2>/dev/null)
    PLIST="$(dirname "$(dirname "$EXE")")/Info.plist"
    RUNNING=$(sed -n 's#.*<key>BaneySpacesCommit</key>[[:space:]]*<string>\([^<]*\)</string>.*#\1#p' "$PLIST" 2>/dev/null | head -n 1)
    [ -n "$RUNNING" ] || RUNNING=$(plutil -extract BaneySpacesCommit raw -o - "$PLIST" 2>/dev/null)
    if [ "$RUNNING" = "$COMMIT" ]; then
      result PASS "running build" "pid $PID is $COMMIT ($EXE)"
    else
      result FAIL "running build" "pid $PID is ${RUNNING:-an unknown commit}, not the candidate $COMMIT ($EXE)"
    fi
    UP=$(elapsed_seconds "$(ps -o etime= -p "$PID" 2>/dev/null | tr -d ' ')") || UP=0
    if [ "$UP" -ge $((HOURS * 3600)) ]; then
      result PASS "uptime" "$((UP / 3600)) h $((UP % 3600 / 60)) min without a restart (needs $HOURS h)"
    else
      result FAIL "uptime" "$((UP / 3600)) h $((UP % 3600 / 60)) min since it started; the soak needs $HOURS h on one run"
    fi
  fi

  REPORTS=$(crash_reports_since $((START - HOURS * 3600)))
  if [ -z "$REPORTS" ]; then
    result PASS "crash reports" "0 in the last $HOURS h"
  else
    result FAIL "crash reports" "$(printf '%s\n' "$REPORTS" | wc -l | tr -d ' ') in the last $HOURS h: $(printf '%s\n' "$REPORTS" | tr '\n' ' ')"
  fi

  # The ledger (pretty-printed JSON, seconds since 1970) keeps the crashes still inside the guard's
  # window and the runs that haven't quit; a run whose process is gone is a crash not yet counted.
  LEDGER="$SUPPORT/crash-ledger.json"
  if [ ! -f "$LEDGER" ]; then
    result FAIL "crash ledger" "$LEDGER is missing: the running build never recorded its launch"
  else
    CRASHES=$(awk '/"crashes"/ { on = 1; if (/\]/) on = 0; next } on && /\]/ { on = 0 } on && /[0-9]/ { n++ } END { print n + 0 }' "$LEDGER")
    DEAD=0
    while read -r p; do
      kill -0 "$p" 2>/dev/null || DEAD=$((DEAD + 1))
    done < <(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$LEDGER")
    if [ "$CRASHES" = 0 ] && [ "$DEAD" = 0 ]; then
      result PASS "crash ledger" "no crashes, no run that died"
    else
      result FAIL "crash ledger" "$CRASHES crashes and $DEAD runs that died without a clean quit ($LEDGER)"
    fi
  fi

  WHY=""
  [ -f "$HOME/Library/LaunchAgents/$LABEL.plist" ] || WHY="no ~/Library/LaunchAgents/$LABEL.plist"
  [ -n "$WHY" ] || launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || WHY="launchd hasn't loaded $LABEL"
  [ -n "$WHY" ] || { [ -f "$SUPPORT/mc-watchdog.sh" ] && [ -f "$SUPPORT/mc-restore.sh" ]; } || WHY="mc-watchdog.sh or mc-restore.sh is missing from $SUPPORT"
  [ -n "$WHY" ] || grep -qx 'mission-control=1' "$SUPPORT/mc-heartbeat" 2>/dev/null || WHY="the heartbeat doesn't say mission-control=1"
  if [ -z "$WHY" ]; then
    BEAT=$(mtime "$SUPPORT/mc-heartbeat") || BEAT=0
    [ $(( $(date +%s) - BEAT )) -le 60 ] || WHY="the heartbeat is $(( $(date +%s) - BEAT )) s old (the watchdog restores after 60)"
  fi
  if [ -z "$WHY" ]; then result PASS "mc-watchdog" "armed: agent loaded, scripts in place, heartbeat fresh"; else result FAIL "mc-watchdog" "not armed: $WHY"; fi
fi

SWIFT_LOG=$(mktemp)
trap 'rm -f "$SWIFT_LOG"' EXIT
if swift test --filter CrashLoopGuardTests >"$SWIFT_LOG" 2>&1; then
  result PASS "CrashLoopGuardTests" "passed"
else
  tail -n 20 "$SWIFT_LOG" >&2
  result FAIL "CrashLoopGuardTests" "failed (last lines above)"
fi

if [ -z "$APP_BIN" ]; then
  if swift build >"$SWIFT_LOG" 2>&1; then
    APP_BIN="$(swift build --show-bin-path)/BaneySpaces"
  else
    tail -n 20 "$SWIFT_LOG" >&2
    result FAIL "render" "swift build failed (last lines above)"
  fi
fi
if [ -n "$APP_BIN" ]; then
  RENDER_START=$(date +%s)
  for sample in default reported; do
    ok=0; why=""
    for i in $(seq 1 "$ITERATIONS"); do
      out=$(mktemp -d)
      if [ "$sample" = reported ]; then
        BANEYSPACES_RENDER_SAMPLE=reported "$APP_BIN" --render "$out" >/dev/null 2>&1; code=$?
      else
        env -u BANEYSPACES_RENDER_SAMPLE "$APP_BIN" --render "$out" >/dev/null 2>&1; code=$?
      fi
      drawn=$(find "$out" -type f -name '*.png' -size +0 | wc -l | tr -d ' ')
      rm -rf "$out"
      if [ "$code" = 0 ] && [ "$drawn" -gt 0 ]; then ok=$((ok + 1)); else why=${why:-"run $i exited $code with $drawn images"}; fi
    done
    if [ "$ok" = "$ITERATIONS" ]; then
      result PASS "render $sample" "$ok of $ITERATIONS exited 0 and drew"
    else
      result FAIL "render $sample" "$ok of $ITERATIONS passed; $why"
    fi
  done
  NEW=$(crash_reports_since "$RENDER_START")
  if [ -z "$NEW" ]; then result PASS "render crashes" "no crash report during the renders"; else result FAIL "render crashes" "$(printf '%s\n' "$NEW" | tr '\n' ' ')"; fi
fi

if [ "$CMD_TAB" = 1 ] && [ -t 0 ]; then
  read -r -p "Did ⌘Tab bring the third app forward on this build, three times out of three? [y/N] " answer
  case "$answer" in [yY]*) result PASS "cmd-tab smoke" "by hand" ;; *) result FAIL "cmd-tab smoke" "not confirmed by hand" ;; esac
else
  result SKIP "cmd-tab smoke" "optional; pass --cmd-tab in a terminal to record it"
fi

mkdir -p build/soak
RECEIPT="build/soak/v$VERSION-${COMMIT:0:7}-$([ "$CI" = 1 ] && echo ci || echo live).txt"
{
  echo "BaneySpaces $VERSION ($COMMIT)"
  echo "host: $(hostname -s 2>/dev/null || hostname)  mode: $([ "$CI" = 1 ] && echo ci || echo "live, $HOURS h")  renders: $ITERATIONS each"
  echo "finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "${LINES[@]}"
  [ "$FAILED" = 0 ] && echo "SOAK PASSED" || echo "SOAK FAILED ($FAILED)"
} > "$RECEIPT"
if [ "$FAILED" = 0 ]; then
  echo "SOAK PASSED. Receipt: $RECEIPT"
  exit 0
fi
echo "SOAK FAILED ($FAILED). Receipt: $RECEIPT. Keep the release a draft." >&2
exit 1
