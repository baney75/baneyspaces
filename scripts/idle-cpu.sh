#!/bin/bash
# How much CPU BaneySpaces uses while you aren't touching it, and what the apps it reads spend
# answering its scripts. Samples once a second for SECONDS_TO_SAMPLE (60) seconds and fails if
# BaneySpaces' median is over BUDGET_PCT (1). Run it with BaneySpaces installed and running and
# nobody using the Mac: typing, switching or an agent at work all count.
#   scripts/idle-cpu.sh
#   SECONDS_TO_SAMPLE=120 BUDGET_PCT=0.5 scripts/idle-cpu.sh
set -euo pipefail
N="${SECONDS_TO_SAMPLE:-60}"
BUDGET="${BUDGET_PCT:-1}"
PID=$(pgrep -f "BaneySpaces.app/Contents/MacOS/BaneySpaces" | head -1) || { echo "BaneySpaces isn't running." >&2; exit 2; }
# Ghostty and the browser answer every script BaneySpaces sends, so their CPU is part of the bill.
OTHERS=$(pgrep -x ghostty Helium "Google Chrome" 2>/dev/null | tr '\n' ' ' || true)
# top's first sample has no interval behind it, so it's dropped.
top -l $((N + 1)) -s 1 -stats pid,cpu -pid "$PID" $(for p in $OTHERS; do printf -- '-pid %s ' "$p"; done) 2>/dev/null \
  | awk '/^PID/ { s++ ; next } s > 1 && $1 ~ /^[0-9]+$/ { print $1, $2 }' \
  | python3 -c '
import statistics, sys
pid, budget = sys.argv[1], float(sys.argv[2])
by = {}
for line in sys.stdin:
    p, c = line.split()
    by.setdefault(p, []).append(float(c))
mine = by.pop(pid, [])
if not mine: sys.exit("no samples for BaneySpaces")
med = statistics.median(mine)
print(f"BaneySpaces: median {med:.1f}% CPU, mean {statistics.mean(mine):.1f}%, over {len(mine)} s (budget {budget}%)")
for p, v in by.items(): print(f"  pid {p}: mean {statistics.mean(v):.1f}%")
sys.exit(0 if med <= budget else 1)
' "$PID" "$BUDGET"
