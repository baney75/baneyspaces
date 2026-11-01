#!/bin/bash
# Self-test for soak-check.sh (runs on Linux CI without a Mac app).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/soak-check.sh"
fail=0

"$SCRIPT" --help >/dev/null
"$SCRIPT" --ci
test -d "$ROOT/build/soak"
ls "$ROOT/build/soak"/soak-*.txt >/dev/null

if "$SCRIPT" --nope 2>/dev/null; then echo "bad: unknown arg accepted"; fail=1; else echo "ok: unknown arg refused"; fi

bash -n "$SCRIPT"
bash -n "$0"

if [ "$fail" -eq 0 ]; then echo "soak-check-test: OK"; exit 0; fi
echo "soak-check-test: FAIL"; exit 1
