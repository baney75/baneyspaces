#!/bin/bash
# Times workspace switches on this Mac and fails if they got slower. It switches to the workspace
# you're on (nothing on screen changes) 10 times through BaneySpaces' URL command and reads the
# times from timing.log. Run it with BaneySpaces installed and running.
#   scripts/bench.sh           fail if the median switch takes over 40 ms
#   BUDGET_MS=25 scripts/bench.sh
# It also reports the switches you really made with the running build (each between two
# workspaces, since it started) step by step, and fails if their p90 is over REAL_P90_MS (250 ms;
# 232 on 2026-10-30, before the build that logs from=). With fewer than 20 since it started it
# exits 3: make 20 real switches on the installed build first, or report the budget unchecked.
# Time a switch spends queued behind another isn't counted.
set -euo pipefail
BUDGET_MS="${BUDGET_MS:-40}"
REAL_P90_MS="${REAL_P90_MS:-250}"
DIR="$HOME/Library/Application Support/BaneySpaces"
LOG="$DIR/timing.log"
pgrep -f "BaneySpaces.app/Contents/MacOS/BaneySpaces" >/dev/null || { echo "BaneySpaces isn't running." >&2; exit 2; }
current=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['current'])" "$DIR/state.json")
start=$(date +%s)
noop=0
real=0
# When the running build started: only its switches count toward the real-use budget.
lstart=$(LC_ALL=C ps -o lstart= -p "$(pgrep -f "BaneySpaces.app/Contents/MacOS/BaneySpaces" | head -1)" | tr -s ' ' | sed 's/^ //; s/ $//')
launched=$(LC_ALL=C date -j -f "%a %b %d %T %Y" "$lstart" +%s)
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
' "$BUDGET_MS" "$start" "$LOG" || noop=$?
python3 -c '
import math, re, statistics, sys
budget, launched = int(sys.argv[1]), int(sys.argv[3])
phases = ["start", "snap", "scanned", "fullscreen", "home", "alongside", "unhidden", "concealed", "shown", "focused", "done"]
rows = []
for line in open(sys.argv[2]):
    if not line[:1].isdigit() or int(line.split()[0]) < launched: continue
    kv = {}
    # The first of each mark: a switch out of full screen scans again and marks snap twice.
    for k, v in re.findall(r"(\w+)=(\S+)", line): kv.setdefault(k, v)
    # A switch to the workspace you are on moves nothing (the loop above makes those). A build
    # that does not log from= cannot tell them apart, so its lines do not count.
    if "done" not in kv or "from" not in kv or kv["from"] == kv["ws"]: continue
    rows.append({"start": 0, **{k: int(v) for k, v in kv.items() if v.isdigit()}})
if len(rows) < 20:
    print(f"real use: only {len(rows)} switches since this build started; budget not checked (exit 3)")
    sys.exit(3)
# Nearest rank: the smallest value with at least p of them at or below it.
def pct(v, p): v = sorted(v); return v[max(0, math.ceil(len(v) * p) - 1)]
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
' "$REAL_P90_MS" "$LOG" "$launched" || real=$?
# A failure (over budget, too few no-op switches logged) outranks "real use not checked" (3).
if [ "$noop" -ne 0 ]; then exit "$noop"; fi
exit "$real"
