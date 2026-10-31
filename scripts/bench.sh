#!/bin/bash
# Times workspace switches on this Mac and fails if they got slower. It switches to the workspace
# you're on (nothing on screen changes) 10 times through BaneySpaces' URL command and reads the
# times from timing.log. Run it with BaneySpaces installed and running.
#   scripts/bench.sh           fail if the median switch takes over 40 ms
#   BUDGET_MS=25 scripts/bench.sh
# It also reports the switches you really made (the last 500 in timing.log, each between two
# workspaces) phase by phase, and fails if their p90 is over REAL_P90_MS (250 ms, 228 on 2026-10-30).
set -euo pipefail
BUDGET_MS="${BUDGET_MS:-40}"
REAL_P90_MS="${REAL_P90_MS:-250}"
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
parked = [int(m.group(1)) for line in lines if (m := re.search(r"parked=(\d+)", line))]
if len(done) < 8: sys.exit(f"only {len(done)} switches were logged")
median = statistics.median(done)
print(f"median {median:.0f} ms, slowest {max(done)} ms over {len(done)} switches (budget {budget} ms)")
if parked: print(f"with parking: median {statistics.median(parked):.0f} ms, slowest {max(parked)} ms")
sys.exit(0 if median <= budget else 1)
' "$BUDGET_MS" "$start" "$LOG"
python3 -c '
import re, statistics, sys
budget = int(sys.argv[1])
phases = ["start", "snap", "scanned", "home", "alongside", "unhidden", "concealed", "shown", "focused", "done"]
rows = []
for line in open(sys.argv[2]):
    kv = dict(re.findall(r"(\w+)=(\S+)", line))
    # A switch to the workspace you are on moves nothing (this script makes those); lines from
    # before from= was logged are counted as real.
    if "done" not in kv or kv.get("from") == kv.get("ws"): continue
    rows.append({"start": 0, **{k: int(v) for k, v in kv.items() if v.isdigit()}})
if len(rows) < 20: sys.exit(f"only {len(rows)} real switches logged; use BaneySpaces a while first")
def pct(v, p): v = sorted(v); return v[min(len(v) - 1, int(len(v) * p))]
done = [r["done"] for r in rows]
p50, p90 = statistics.median(done), pct(done, 0.9)
print(f"real use: median {p50:.0f} ms, p90 {p90} ms, slowest {max(done)} ms over {len(rows)} switches (p90 budget {budget} ms)")
# Each step runs from the phase before it that the line has: older lines have fewer phases.
steps = {}
for r in rows:
    have = [p for p in phases if p in r]
    for a, b in zip(have, have[1:]): steps.setdefault(f"{a}->{b}", []).append(r[b] - r[a])
order = sorted(steps, key=lambda k: (phases.index(k.split("->")[1]), phases.index(k.split("->")[0])))
print("  per step, median/p90 ms: " + ", ".join(f"{k} {statistics.median(steps[k]):.0f}/{pct(steps[k], 0.9)}" for k in order if len(steps[k]) >= 10))
sys.exit(0 if p90 <= budget else 1)
' "$REAL_P90_MS" "$LOG"
