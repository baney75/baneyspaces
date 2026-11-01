#!/usr/bin/env python3
"""The ratchet: fail when BaneySpaces regresses.

  ratchet.py                  compare the newest FULL BaneySpaces runs with bench/baseline/*.json and with the
                              newest full run of every other tool at the same level
  ratchet.py --require        also fail when there is no BaneySpaces result to compare
  ratchet.py --update         write the newest full BaneySpaces runs as the baseline (see below)

There is no seeded baseline. bench/baseline/ starts empty and a file appears only when `--update` is run
on a measured, full, un-aborted run. `--update` refuses a partial run (--only, aborted, tasks not run)
and refuses a run that regresses against the existing baseline; it keeps the old entry for any task the
new run did not complete (unavailable, infra error), so a smaller run can never shrink the ratchet.

Checked per level (scripted, agent):
  - against the baseline, over the tasks both completed: success rate, screen changes in the task,
    tasks with a screen change in the task, median and p90 (25% + 0.25 s of timing slack), good refusals,
    collateral, and no task that passed before may fail now
  - against every other tool, over the tasks both completed: BaneySpaces >= on success, <= on screen
    changes, tasks with a change, median and p90
Micro latency is compared only with BaneySpaces' own earlier numbers (the tools are timed differently, so
it is never a cross-tool gate).
Exit 0 holds, 1 regression, 2 nothing to compare under --require.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from benchlib import compare, report, scoring  # noqa: E402

LEVELS = ("scripted", "agent", "micro")


def baseline_path(directory, level):
    return os.path.join(directory, f"baneyspaces-{level}.json")


def load_baseline(directory, level):
    p = baseline_path(directory, level)
    if not os.path.exists(p):
        return None
    with open(p, encoding="utf-8") as fh:
        return json.load(fh)


def task_map(result):
    return {t["id"]: {"status": t["status"], "duration_s": t.get("duration_s"),
                      "changes": len(t.get("changes", [])), "collateral": len(t.get("collateral", []))}
            for t in result["tasks"] if t["status"] in scoring.SCORED}


def check(results_dir, baseline_dir, others=True):
    """-> (problems, notes)"""
    best = report.newest(results_dir)
    problems, notes = [], []
    for level in LEVELS:
        mine = best.get(("baneyspaces", level))
        if mine is None:
            notes.append(f"{level}: no full BaneySpaces run yet")
            continue
        base = load_baseline(baseline_dir, level)
        if base is None:
            notes.append(f"{level}: no baseline yet (create it with --update after a measured full run)")
        elif level == "micro":
            problems += [f"{level} vs baseline: {p}" for p in compare.latency_vs_baseline(mine.get("micro"), base)]
        else:
            if not compare.common_ids(mine["tasks"], base.get("tasks", {})):
                notes.append(f"{level}: no task in common with the baseline")
            problems += [f"{level} vs baseline: {p}" for p in compare.vs_baseline(mine["tasks"], base.get("tasks", {}))]
        if level == "micro" or not others:
            continue
        for (tool, lv), other in best.items():
            if lv == level and tool != "baneyspaces" and mine.get("tasks") and other.get("tasks"):
                problems += [f"{level} vs {tool}: {p}" for p in compare.vs_other(mine, tool, other)]
    return problems, notes


def update(results_dir, baseline_dir):
    best = report.newest(results_dir)
    problems, _ = check(results_dir, baseline_dir, others=False)
    if problems:
        print("refusing to update: the newest results regress\n  " + "\n  ".join(problems))
        return 1
    os.makedirs(baseline_dir, exist_ok=True)
    wrote, refused = 0, []
    for level in LEVELS:
        mine = best.get(("baneyspaces", level))
        if mine is None:
            continue
        if not mine.get("full") or mine.get("aborted") or mine.get("only"):
            refused.append(f"{level}: not a full run ({mine.get('aborted') or 'partial'})")
            continue
        old = load_baseline(baseline_dir, level)
        if level == "micro":
            data = {"kind": "measured", "run_id": mine.get("run_id"), "date": mine["date"],
                    "latency": (mine.get("micro") or {}).get("latency")}
        else:
            tasks = dict((old or {}).get("tasks", {}))     # keep what this run could not complete
            tasks.update(task_map(mine))
            data = {"kind": "measured", "run_id": mine.get("run_id"), "date": mine["date"], "tasks": tasks}
        with open(baseline_path(baseline_dir, level), "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
            fh.write("\n")
        wrote += 1
    for r in refused:
        print("not updated:", r)
    print(f"baseline updated for {wrote} level(s)")
    return 1 if refused and not wrote else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results-dir", default=os.path.join(HERE, "results"))
    ap.add_argument("--baseline-dir", default=os.path.join(HERE, "baseline"))
    ap.add_argument("--require", action="store_true")
    ap.add_argument("--update", action="store_true")
    args = ap.parse_args(argv)
    if args.update:
        return update(args.results_dir, args.baseline_dir)
    problems, notes = check(args.results_dir, args.baseline_dir)
    for n in notes:
        print("note:", n)
    if problems:
        print("RATCHET FAILED")
        for p in problems:
            print("  -", p)
        return 1
    have = any(report.newest(args.results_dir).get(("baneyspaces", lv)) for lv in LEVELS)
    if not have and args.require:
        print("no full BaneySpaces run to compare")
        return 2
    print("ratchet holds" if have else "ratchet: nothing to compare yet (no full BaneySpaces run)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
