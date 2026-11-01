#!/bin/bash
# Self-test for soak-check.sh: runs it in a scratch repo against stand-ins for swift, launchctl, ps
# and the app, so it runs on any Mac or Linux box without BaneySpaces installed.
#   scripts/soak-check-test.sh        prints PASS or FAIL per case and exits 1 if any failed
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d)
SLEEPER=""
trap '[ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null; rm -rf "$T"' EXIT
FAILS=0

# A stand-in for a running BaneySpaces: any live process will do for kill -0.
sleep 600 & SLEEPER=$!

REPO="$T/repo"
mkdir -p "$REPO/scripts" "$T/stubs" "$T/bin"
cp "$HERE/soak-check.sh" "$REPO/scripts/"
echo 9.9.9 > "$REPO/VERSION"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm candidate
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

cat > "$T/stubs/swift" <<EOF
#!/bin/bash
case "\$1" in
  test) exit \${STUB_TEST_EXIT:-0} ;;
  build) [ "\${2:-}" = --show-bin-path ] && echo "$T/bin"; exit 0 ;;
esac
EOF
cat > "$T/stubs/launchctl" <<'EOF'
#!/bin/bash
exit ${STUB_LAUNCHCTL_EXIT:-0}
EOF
cat > "$T/stubs/ps" <<EOF
#!/bin/bash
case "\$2" in
  comm=) echo "$T/app/BaneySpaces.app/Contents/MacOS/BaneySpaces" ;;
  etime=) echo "\${STUB_ETIME:-1-02:03:04}" ;;
esac
EOF
cat > "$T/bin/BaneySpaces" <<'EOF'
#!/bin/bash
[ "$1" = --render ] || exit 64
if [ "${BANEYSPACES_RENDER_SAMPLE:-}" = reported ] && [ "${STUB_REPORTED_FAIL:-0}" = 1 ]; then exit 1; fi
printf 'png' > "$2/overview.png"
EOF
chmod +x "$T/stubs/"* "$T/bin/BaneySpaces"

# A fresh home with a healthy, armed install of the candidate. Each case changes one thing.
setup_home() {
  H="$T/home"; rm -rf "$H" "$T/app" "$REPO/build"
  local s="$H/Library/Application Support/BaneySpaces"
  mkdir -p "$s" "$H/Library/LaunchAgents" "$H/Library/Logs/DiagnosticReports" "$T/app/BaneySpaces.app/Contents/MacOS"
  printf '<plist><dict><key>BaneySpacesCommit</key><string>%s</string></dict></plist>\n' "${1:-$HEAD_SHA}" > "$T/app/BaneySpaces.app/Contents/Info.plist"
  printf '%s\nmission-control=1\n' "$SLEEPER" > "$s/mc-heartbeat"
  touch "$s/mc-watchdog.sh" "$s/mc-restore.sh" "$H/Library/LaunchAgents/com.baney.baneyspaces.mc-watchdog.plist"
  printf '{\n  "crashes" : [\n\n  ],\n  "running" : [\n    {\n      "pid" : %s,\n      "started" : 1793500000\n    }\n  ]\n}\n' "$SLEEPER" > "$s/crash-ledger.json"
  # A crash from long before the soak window must not count.
  touch -t 202001010000 "$H/Library/Logs/DiagnosticReports/BaneySpaces-2020-01-01-000000.ips"
}

run() { HOME="$T/home" PATH="$T/stubs:$PATH" "$REPO/scripts/soak-check.sh" --iterations 2 "$@" >"$T/out" 2>&1; echo $? > "$T/code"; }

# expect <name> <exit code> <text the output must contain>
expect() {
  if [ "$(cat "$T/code")" = "$2" ] && grep -qF -- "$3" "$T/out"; then
    echo "PASS  $1"
  else
    echo "FAIL  $1: wanted exit $2 and \"$3\", got exit $(cat "$T/code")"; sed 's/^/      /' "$T/out"
    FAILS=$((FAILS + 1))
  fi
}

setup_home; run --hours 24
expect "a healthy soak passes" 0 "SOAK PASSED"
if grep -q "SOAK PASSED" "$REPO"/build/soak/v9.9.9-*-live.txt 2>/dev/null; then echo "PASS  the receipt is written"; else echo "FAIL  no receipt"; FAILS=$((FAILS + 1)); fi

setup_home; STUB_ETIME=05:00:00 run --hours 24
expect "a run younger than the soak fails" 1 "FAIL  uptime"

setup_home; touch "$T/home/Library/Logs/DiagnosticReports/BaneySpaces-2026-11-01-120000.ips"; run
expect "a recent crash report fails" 1 "FAIL  crash reports"

setup_home 0000000000000000000000000000000000000000; run
expect "another build running fails" 1 "FAIL  running build"

setup_home; STUB_LAUNCHCTL_EXIT=1 run
expect "an unloaded watchdog fails" 1 "launchd hasn't loaded"

setup_home; rm "$T/home/Library/Application Support/BaneySpaces/mc-heartbeat"; run
expect "no heartbeat fails" 1 "FAIL  running build"

setup_home; sed -i.bak "s/\"pid\" : $SLEEPER/\"pid\" : 999999/" "$T/home/Library/Application Support/BaneySpaces/crash-ledger.json"; run
expect "a run that died fails" 1 "1 runs that died"

setup_home; printf '{\n  "crashes" : [\n    1793500000\n  ],\n  "running" : [\n\n  ]\n}\n' > "$T/home/Library/Application Support/BaneySpaces/crash-ledger.json"; run
expect "a counted crash fails" 1 "1 crashes and 0 runs"

setup_home; STUB_REPORTED_FAIL=1 run
expect "a failing reported render fails" 1 "FAIL  render reported"

setup_home; STUB_TEST_EXIT=1 run
expect "failing CrashLoopGuardTests fail" 1 "FAIL  CrashLoopGuardTests"

rm -rf "${T:?}/home"; mkdir -p "$T/home"; run --ci
expect "--ci skips the live soak and passes" 0 "SKIP  live soak"

run --hours many
expect "a bad --hours is refused" 2 "usage:"

[ "$FAILS" = 0 ] && { echo "soak-check-test: all passed"; exit 0; }
echo "soak-check-test: $FAILS failed" >&2
exit 1
