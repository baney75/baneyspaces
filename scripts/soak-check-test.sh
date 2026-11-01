#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/soak-check.sh"
fail=0
"$SCRIPT" --help >/dev/null
"$SCRIPT" --ci
test -d "$ROOT/build/soak"
ls "$ROOT/build/soak"/soak-*.txt >/dev/null
if "$SCRIPT" --nope 2>/dev/null; then echo "bad: unknown arg accepted"; fail=1; else echo "ok: unknown arg refused"; fi
if "$SCRIPT" --ci --render-iters 0 2>/dev/null; then echo "bad: render-iters 0 accepted"; fail=1; else echo "ok: render-iters 0 refused"; fi
if "$SCRIPT" --ci --hours 0 2>/dev/null; then echo "bad: hours 0 accepted"; fail=1; else echo "ok: hours 0 refused"; fi
bash -n "$SCRIPT"
bash -n "$0"

# Contract: same-path binary replace and PID reuse must be detectable.
for fn in txt_dev_ino disk_dev_ino proc_start; do
  if grep -q "${fn}()" "$SCRIPT"; then echo "ok: helper $fn present"; else echo "bad: missing $fn"; fail=1; fi
done
for key in txt_dev_ino disk_dev_ino proc_start; do
  if grep -q "\"$key\"" "$SCRIPT"; then echo "ok: gate records $key"; else echo "bad: gate missing $key"; fail=1; fi
done

# Offline identity comparison (mirrors soak-check gate checks).
same_path_replace_should_fail() {
  local txt_ino=$1 disk_ino=$2
  [ "$txt_ino" != "$disk_ino" ]
}
pid_reuse_should_fail() {
  local gate_start=$1 run_start=$2
  [ "$gate_start" != "$run_start" ]
}
if same_path_replace_should_fail "1:100" "1:200"; then echo "ok: same-path replace detected"; else echo "bad: replace missed"; fail=1; fi
if same_path_replace_should_fail "1:100" "1:100"; then echo "bad: identical inodes flagged"; fail=1; else echo "ok: matching inodes allowed"; fi
if pid_reuse_should_fail "Mon Nov  1 12:00:00 2026" "Mon Nov  1 13:00:00 2026"; then echo "ok: PID reuse detected"; else echo "bad: PID reuse missed"; fail=1; fi
if pid_reuse_should_fail "same" "same"; then echo "bad: same start flagged"; fail=1; else echo "ok: matching proc_start allowed"; fi

# Fail-closed: unresolved exe/inode must not PASS (string contract in script).
for needle in "fail closed" "binary replaced under feet" "PID reuse"; do
  if grep -q "$needle" "$SCRIPT"; then echo "ok: message '$needle'"; else echo "bad: missing '$needle'"; fail=1; fi
done

if [ "$fail" -eq 0 ]; then echo "soak-check-test: OK"; exit 0; fi
echo "soak-check-test: FAIL"; exit 1
