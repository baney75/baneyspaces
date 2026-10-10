#!/bin/bash
# Times workspace switches on this Mac and fails if they got slower. It switches to the workspace
# you're on (nothing on screen changes) 10 times through BaneySpaces' URL command and reads the
# times from timing.log. Run it with BaneySpaces installed and running.
#   scripts/bench.sh           fail if the median switch takes over 40 ms
#   BUDGET_MS=25 scripts/bench.sh
set -euo pipefail
BUDGET_MS="${BUDGET_MS:-40}"
DIR="$HOME/Library/Application Support/BaneySpaces"
LOG="$DIR/timing.log"
pgrep -f "BaneySpaces.app/Contents/MacOS/BaneySpaces" >/dev/null || { echo "BaneySpaces isn't running." >&2; exit 2; }
current=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['current'])" "$DIR/state.json")
start=$(date +%s)
for _ in $(seq 1 10); do open -g "baneyspaces://switch/$current"; sleep 0.8; done
sleep 0.5
python3 -c '
import re, statistics, sys
budget, start = int(sys.argv[1]), int(sys.argv[2])
# timing.log keeps its last 500 lines, so pick the lines from this run by timestamp, not position.
lines = [l for l in open(sys.argv[3]) if l.split()[:1] and l.split()[0].isdigit() and int(l.split()[0]) >= start]
done = [int(m.group(1)) for line in lines if (m := re.search(r"done=(\d+)", line))]
if len(done) < 8: sys.exit(f"only {len(done)} switches were logged")
median = statistics.median(done)
print(f"median {median:.0f} ms, slowest {max(done)} ms over {len(done)} switches (budget {budget} ms)")
sys.exit(0 if median <= budget else 1)
' "$BUDGET_MS" "$start" "$LOG"
