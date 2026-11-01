"""The ratchet's comparisons: BaneySpaces against its measured baseline, and against the other tools.

Every comparison is over the tasks BOTH sides completed (a scored status), so a task that was
unavailable, errored or not run on one side can neither hide a regression nor invent one.
"""
from . import scoring

# label -> (summary key, direction); "up" means higher is better
COLUMNS = {
    "success rate": ("success_rate", "up"),
    "screen changes in the task": ("screen_changes_in_task", "down"),
    "tasks with a screen change in the task": ("tasks_with_changes_in_task", "down"),
    "median s/task": ("median_s", "down"),
    "p90 s/task": ("p90_s", "down"),
    "good refusals": ("refusals_good", "up"),
    "collateral": ("collateral", "down"),
}
TIME_COLUMNS = {"median_s", "p90_s"}
TIME_SLACK = 1.25     # a time may be 25% over its baseline (+0.25 s) before it counts as a regression
TIME_SLACK_ABS_S = 0.25
LATENCY_ACTIONS = ("snapshot", "click", "type", "read-back")
LATENCY_SLACK = 1.25        # a median may be 25% over its baseline plus 25 ms before it counts as a regression
LATENCY_SLACK_MS = 25.0


def ran_ids(tasks):
    return {t["id"] for t in tasks if t["status"] in scoring.SCORED}


def restrict(tasks, ids):
    return [t for t in tasks if t["id"] in ids]


def worse(key, direction, now, then):
    if now is None or then is None:
        return False
    if key in TIME_COLUMNS:
        return now > then * TIME_SLACK + TIME_SLACK_ABS_S
    return now < then - 1e-9 if direction == "up" else now > then + 1e-9


def baseline_records(baseline_tasks, mine):
    """Rebuild scoreable records from a baseline's per-task map, borrowing 'impossible' from the current run."""
    imp = {t["id"]: bool(t.get("impossible")) for t in mine}
    out = []
    for tid, b in baseline_tasks.items():
        out.append({"id": tid, "status": b["status"], "duration_s": b.get("duration_s"), "impossible": imp.get(tid, False),
                    "changes": [None] * b.get("changes", 0), "collateral": [None] * b.get("collateral", 0)})
    return out


def common_ids(mine, baseline_tasks):
    base_ran = {tid for tid, b in baseline_tasks.items() if b["status"] in scoring.SCORED}
    return ran_ids(mine) & base_ran


def vs_baseline(mine, baseline_tasks):
    """Regressions of a BaneySpaces result against its baseline, over the tasks both completed."""
    common = common_ids(mine, baseline_tasks)
    out = []
    if not common:
        return out
    now = scoring.summarize(restrict(mine, common))
    then = scoring.summarize(restrict(baseline_records(baseline_tasks, mine), common))
    for label, (key, direction) in COLUMNS.items():
        if worse(key, direction, now.get(key), then.get(key)):
            out.append(f"{label}: {now.get(key)} vs baseline {then.get(key)} (over {len(common)} common tasks)")
    cur = {t["id"]: t["status"] for t in mine}
    for tid in sorted(common):
        was = baseline_tasks[tid]["status"]
        if was in ("pass", "refused_ok") and cur[tid] == "fail":
            out.append(f"task {tid}: was {was}, now fail")
    return out


def vs_other(mine, other_name, other):
    """BaneySpaces must be >= on success, <= on screen changes, median and p90, over the tasks both completed."""
    common = ran_ids(mine["tasks"]) & ran_ids(other["tasks"])
    if not common:
        return [f"{other_name}: no task in common to compare"]
    a = scoring.summarize(restrict(mine["tasks"], common))
    b = scoring.summarize(restrict(other["tasks"], common))
    out = []
    checks = (("success rate", "success_rate", "up"), ("screen changes in the task", "screen_changes_in_task", "down"),
              ("tasks with a screen change in the task", "tasks_with_changes_in_task", "down"),
              ("median s/task", "median_s", "down"), ("p90 s/task", "p90_s", "down"))
    for label, key, direction in checks:
        x, y = a[key], b[key]
        if x is None or y is None:
            continue
        if (direction == "up" and x < y - 1e-9) or (direction == "down" and x > y + 1e-9):
            out.append(f"{label}: baneyspaces {x} vs {other_name} {y} (over {len(common)} common tasks)")
    return out


def latency_vs_baseline(mine, baseline):
    """Micro latency: BaneySpaces against its own earlier numbers only (same method). Never across tools."""
    out = []
    for action in LATENCY_ACTIONS:
        a = ((mine or {}).get("latency") or {}).get(action, {}).get("median_ms")
        b = (baseline.get("latency") or {}).get(action, {}).get("median_ms")
        if a is not None and b is not None and a > b * LATENCY_SLACK + LATENCY_SLACK_MS:
            out.append(f"{action} median: {a} ms vs baseline {b} ms")
    return out
