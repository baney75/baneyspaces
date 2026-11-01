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
# Production helpers + validation (not duplicated mirror logic)
if ! "$SCRIPT" --self-test; then echo "bad: --self-test failed"; fail=1; fi
# Contract strings for fail-closed paths
for needle in "fail closed" "binary replaced under feet" "PID reuse" "missing identity fields"; do
  if grep -q "$needle" "$SCRIPT"; then echo "ok: message '$needle'"; else echo "bad: missing '$needle'"; fail=1; fi
done
if [ "$fail" -eq 0 ]; then echo "soak-check-test: OK"; exit 0; fi
echo "soak-check-test: FAIL"; exit 1
