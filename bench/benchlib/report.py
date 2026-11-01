"""Result files and bench/results/latest.md.

A result file is named <date>-<HHMMSS>-<tool>[-scripted|-micro].json and carries a run id; nothing is
overwritten. Only FULL runs (every task attempted, none skipped by --only, none cut short) feed
latest.md and the ratchet; partial runs are kept and listed.
"""
import glob
import json
import os
import re

from . import compare, scoring

LEVEL_SUFFIX = {"agent": "", "scripted": "-scripted", "micro": "-micro"}
LEVEL_TITLE = {
    "agent": "End to end: each tool's own agent does the task (claude -p for BaneySpaces and agent-desktop, codex exec for ChatGPT)",
    "scripted": "Scripted: the same task steps through each tool's command line",
    "micro": "Driver level: per-action latency, called directly (reported, not gated across tools)",
}
STATUS_MARK = {"pass": "pass", "refused_ok": "refused ok", "fail": "FAIL", "infra_error": "infra error",
               "monitor_lost": "monitor lost", "unavailable": "n/a", "not_run": "not run"}
FILE_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})(?:-(\d{6})(?:-(\d+))?)?-(baneyspaces|agent-desktop-headed|agent-desktop|chatgpt)(-scripted|-micro)?\.json$")


def result_name(tool, level, date, hms):
    return f"{date}-{hms}-{tool}{LEVEL_SUFFIX[level]}.json"


def write_result(directory, result):
    """Write a new file, never over an existing one."""
    os.makedirs(directory, exist_ok=True)
    hms = result.get("hms") or "000000"
    base = result_name(result["tool"], result["level"], result["date"], hms)
    path, n = os.path.join(directory, base), 1
    while True:
        try:
            with open(path, "x", encoding="utf-8") as fh:
                json.dump(result, fh, indent=2, sort_keys=True)
                fh.write("\n")
            return path
        except FileExistsError:
            n += 1
            path = os.path.join(directory, base.replace(f"-{hms}-", f"-{hms}-{n}-", 1))


def sort_key(name):
    """(date, time, collision number) parsed from the file name, so '-2' files sort after their original."""
    m = FILE_RE.match(name)
    date, hms, n = m.group(1), m.group(2) or "000000", m.group(3)
    return (date, hms, int(n) if n else 0)


def all_results(directory):
    """[(path, result)] sorted oldest to newest by (date, time, collision number), never by raw file name."""
    names = [os.path.basename(p) for p in glob.glob(os.path.join(directory, "*.json"))]
    out = []
    for name in sorted((n for n in names if FILE_RE.match(n)), key=lambda n: (sort_key(n), n)):
        with open(os.path.join(directory, name), encoding="utf-8") as fh:
            out.append((os.path.join(directory, name), json.load(fh)))
    return out


def level_of(result):
    return result["level"]


def newest(directory, full_only=True):
    """{(tool, level): result} - the newest FULL run per tool and level."""
    best = {}
    for _, r in all_results(directory):
        if full_only and not r.get("full", False):
            continue
        best[(r["tool"], r["level"])] = r
    return best


def _task_matrix(by_tool):
    ids = []
    for r in by_tool.values():
        for t in r.get("tasks", []):
            if t["id"] not in ids:
                ids.append(t["id"])
    tools = list(by_tool)
    lines = ["| task | " + " | ".join(tools) + " |", "|---|" + "---|" * len(tools)]
    for tid in ids:
        row = [f"`{tid}`"]
        for tool in tools:
            rec = next((t for t in by_tool[tool].get("tasks", []) if t["id"] == tid), None)
            if rec is None:
                row.append("-")
                continue
            mark = STATUS_MARK.get(rec["status"], rec["status"])
            if rec["status"] == "fail" and rec.get("expected_fail"):
                mark = f"fail (expected, phase {rec['expected_fail'].get('phase', '?')})"
            if rec["status"] in ("unavailable", "infra_error", "monitor_lost") and rec.get("why"):
                mark += f": {rec['why'][:60]}"
            n = scoring.disturbances(rec)
            if n:
                mark += f", {n} change(s)"
            row.append(mark)
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


def _versions(best, fallback=None):
    v = next((r["versions"] for r in best.values() if r.get("versions")), None) or fallback
    if not v:
        return "_unknown_"
    return "\n".join([
        f"- bench commit `{v['bench_commit']}`, macOS {v['macos']}",
        f"- BaneySpaces: installed app {v['baneyspaces']['app']}, app commit `{v['baneyspaces']['app_commit']}`",
        f"- agent-desktop: {v['agent-desktop']['version']}, built from pinned commit `{v['agent-desktop']['pinned_commit']}`",
        f"- ChatGPT computer use: ChatGPT.app {v['chatgpt']['app']}, {v['chatgpt']['codex']}, @oai/sky {v['chatgpt']['sky']}, "
        f"cua_repl definition `{v['chatgpt'].get('plugin', '?')}`",
        f"- agent for the BaneySpaces and agent-desktop end-to-end columns: {v['claude']}, model `{v['claude_model']}`",
    ])


def compare_order(tools):
    order = ["baneyspaces", "agent-desktop", "agent-desktop-headed", "chatgpt"]
    return sorted(tools, key=order.index)


def write_latest(directory, versions=None, today=None):
    best = newest(directory)
    out = ["# Head-to-head: BaneySpaces vs agent-desktop vs ChatGPT computer use", ""]
    dates = sorted({r["date"] for r in best.values()})
    out.append(f"Full runs from: {', '.join(dates) if dates else 'none yet: no column has been measured'}"
               f"{' (versions below read on ' + today + ')' if today and not dates else ''}. "
               "Generated by `bench/harness.py`; every number comes from a file in this directory. "
               "Partial runs (`--only`, aborted, cut short) are kept but never shown here or gated.")
    out += ["", "## Versions", "", _versions(best, versions), ""]
    for level in ("agent", "scripted", "micro"):
        tools = [t for (t, lv) in best if lv == level]
        if not tools:
            out += [f"## {LEVEL_TITLE[level]}", "", "Not run yet.", ""]
            continue
        by_tool = {t: best[(t, level)] for t in compare_order(tools)}
        out += [f"## {LEVEL_TITLE[level]}", ""]
        for t, r in by_tool.items():
            out.append(f"- run `{r.get('run_id')}` for {t}")
        out.append("")
        if level == "micro":
            out += [_micro_table(by_tool), ""]
        else:
            out += [scoring.table(by_tool, scoring.SUMMARY_COLUMNS), "", "<details><summary>Per task</summary>", "",
                    _task_matrix(by_tool), "", "</details>", ""]
            out += _gate_lines(best, level)
    partial = [(p, r) for p, r in all_results(directory) if not r.get("full", False)]
    if partial:
        out += ["## Partial runs (not gated)", ""]
        out += [f"- `{os.path.basename(p)}`: {r.get('aborted') or ('--only ' + ','.join(r['only']) if r.get('only') else 'incomplete')}"
                for p, r in partial]
        out.append("")
    out += ["## Not in this table", "",
            "- Cua's driver is removed from the fleet. A Cua column is only meaningful inside the sandbox (phase 2) and is pending.",
            "- Tasks marked `place: sandbox` (Notes, Safari, Firefox) are `n/a` until the sandbox exists; they run for every tool in the same place or not at all. ChatGPT computer use and agent-desktop `--headed` run only inside the sandbox (#111), so those columns are `n/a: sandbox_only` for every task until then. System Settings, Finder, browsers and Electron apps are sandbox-only on the host too (`agent open` answers needs_sandbox).",
            "- A column marked `n/a` or `not run` was not measured (reason in its JSON file); it is not a pass.",
            "- `infra error` and `monitor lost` tasks are excluded from every score and never charged to a tool.",
            "- `expected` failures are features the design schedules for later phases; they count as failures here.",
            ""]
    path = os.path.join(directory, "latest.md")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out))
    return path


def _micro_table(by_tool):
    tools = list(by_tool)
    lines = ["| action (median / p90 ms) | " + " | ".join(tools) + " |", "|---|" + "---|" * len(tools)]
    for action in compare.LATENCY_ACTIONS:
        row = [action]
        for t in tools:
            m = by_tool[t].get("micro") or {}
            lat = (m.get("latency") or {}).get(action)
            row.append("n/a" if not lat or lat["median_ms"] is None else f"{lat['median_ms']} / {lat['p90_ms']}")
        lines.append("| " + " | ".join(row) + " |")
    notes = [f"- {t}: {(m.get('micro') or {}).get('method', '')}" for t, m in by_tool.items()]
    notes += [f"- {t}: n/a, {m['micro'].get('why')}" for t, m in by_tool.items() if (m.get("micro") or {}).get("status") == "n/a"]
    return "\n".join(lines + [""] + notes)


def _gate_lines(best, level):
    mine = best.get(("baneyspaces", level))
    if mine is None:
        return []
    out = ["Gate (BaneySpaces >= every other tool on success; <= on screen changes, median and p90; over tasks both completed):", ""]
    problems = []
    for (tool, lv), r in best.items():
        if lv != level or tool == "baneyspaces":
            continue
        if mine.get("tasks") and r.get("tasks"):
            problems += compare.vs_other(mine, tool, r)
    out += [f"- {p}" for p in problems] or ["- holds against every tool measured"]
    return out + [""]
