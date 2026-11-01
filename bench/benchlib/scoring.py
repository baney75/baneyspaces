"""Scoring: per-tool summary from per-task results, and the comparison table.

Statuses
  pass, fail, refused_ok   scored
  unavailable              the task could not run here (app missing, in use by Donovan, needs the sandbox)
  infra_error              the harness or the account failed (no result, MCP did not start, quota, sign-in,
                           a setup that could not open the app): not the tool's doing, never charged to it
  monitor_lost             the screen-change monitor stalled or died during the task: cannot be trusted
  not_run                  the run stopped first
Only the first three are scored. The others are counted and listed, never turned into a pass or a fail.
Screen changes are reported for everything the tool's run disturbed: during the task, during setup
(including a setup that failed) and during teardown. The ratchet and the cross-tool gate use the IN-TASK
count: setup and teardown run the same harness code for every tool (the shared `agent open`, the shared
cleanup), so they are shown but cannot decide who is best. Window changes owned by apps outside the task
(Donovan's background apps) are ambient: recorded, never scored.
"""
import math
import statistics

SCORED = ("pass", "fail", "refused_ok")
EXCLUDED = ("unavailable", "infra_error", "monitor_lost", "not_run")


def percentile(values, p):
    if not values:
        return None
    vals = sorted(values)
    k = max(0, min(len(vals) - 1, math.ceil(p / 100 * len(vals)) - 1))   # nearest rank
    return vals[k]


def disturbances(t):
    """Every screen change a task caused: while it ran, during setup, during teardown."""
    return len(t.get("changes", [])) + len(t.get("setup_changes", [])) + len(t.get("teardown_changes", []))


def summarize(tasks):
    """tasks: list of task results -> summary dict. Success rate counts only scored tasks."""
    ran = [t for t in tasks if t["status"] in SCORED]
    ok = [t for t in ran if t["status"] in ("pass", "refused_ok")]
    times = [t["duration_s"] for t in ran if t.get("duration_s") is not None]
    impossible = [t for t in ran if t.get("impossible")]
    out = {
        "tasks_total": len(tasks),
        "tasks_run": len(ran),
        "passed": len(ok),
        "success_rate": round(len(ok) / len(ran), 4) if ran else None,
        "screen_changes": sum(disturbances(t) for t in tasks),
        "screen_changes_in_task": sum(len(t.get("changes", [])) for t in ran),
        "tasks_with_changes": sum(1 for t in tasks if disturbances(t)),
        "tasks_with_changes_in_task": sum(1 for t in ran if t.get("changes")),
        "ambient_changes": sum(len(t.get("ambient_changes", [])) for t in tasks),
        "posted_input_events": sum(t.get("posted_input_events", 0) for t in ran),
        "hid_events": sum(t.get("hid_events", 0) for t in ran),
        "collateral": sum(len(t.get("collateral", [])) for t in tasks),
        "median_s": round(statistics.median(times), 3) if times else None,
        "p90_s": round(percentile(times, 90), 3) if times else None,
        "refusals_good": sum(1 for t in impossible if t["status"] == "refused_ok"),
        "refusals_expected": len(impossible),
        "model_turns_median": _median([t["model_turns"] for t in ran if t.get("model_turns") is not None]),
    }
    for s in EXCLUDED:
        out["tasks_" + s] = sum(1 for t in tasks if t["status"] == s)
    return out


def _median(xs):
    return statistics.median(xs) if xs else None


def classify(task, check_ok, outcome, refusal, side=None):
    """-> status. A refusal task passes only on a refusal that carries a suggestion AND left no trace:
    no screen change, no input event, no stray file, and its check (the app state) holds."""
    side = side or {}
    if task.get("impossible"):
        clean = not (side.get("changes") or side.get("hid") or side.get("collateral"))
        good = refusal is not None and bool(refusal.get("suggestion")) and check_ok and clean
        return "refused_ok" if good else "fail"
    return "pass" if (outcome["ok"] and check_ok) else "fail"


def fmt(v, suffix="", none="n/a"):
    if v is None:
        return none
    if isinstance(v, float):
        return f"{v:.2f}{suffix}"
    return f"{v}{suffix}"


def table(results_by_tool, columns):
    """Markdown table: one row per column spec, one column per tool."""
    tools = list(results_by_tool)
    lines = ["| | " + " | ".join(tools) + " |", "|---|" + "---|" * len(tools)]
    for label, getter in columns:
        row = [label]
        for tool in tools:
            r = results_by_tool[tool]
            row.append(getter(r["summary"]) if r else "not run")
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


SUMMARY_COLUMNS = [
    ("scored tasks", lambda s: f"{s['tasks_run']} of {s['tasks_total']}"),
    ("not scored (unavailable / infra / monitor lost / not run)",
     lambda s: f"{s['tasks_unavailable']} / {s['tasks_infra_error']} / {s['tasks_monitor_lost']} / {s['tasks_not_run']}"),
    ("success rate", lambda s: "n/a" if s["success_rate"] is None else f"{s['success_rate'] * 100:.0f}% ({s['passed']}/{s['tasks_run']})"),
    ("screen changes in the task (gated)", lambda s: fmt(s["screen_changes_in_task"])),
    ("tasks with 1+ screen change in the task (gated)", lambda s: fmt(s["tasks_with_changes_in_task"])),
    ("screen changes incl. setup and teardown", lambda s: fmt(s["screen_changes"])),
    ("ambient window changes (not scored)", lambda s: fmt(s["ambient_changes"])),
    ("real input events (Donovan; run stops)", lambda s: fmt(s["hid_events"])),
    ("input posted by programs (informational)", lambda s: fmt(s["posted_input_events"])),
    ("collateral (Desktop)", lambda s: fmt(s["collateral"])),
    ("median s/task", lambda s: fmt(s["median_s"])),
    ("p90 s/task", lambda s: fmt(s["p90_s"])),
    ("refusals with a suggestion and no trace (good)", lambda s: f"{s['refusals_good']}/{s['refusals_expected']}"),
    ("model turns, median", lambda s: fmt(s["model_turns_median"])),
]
