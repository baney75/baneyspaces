"""Level 3, driver level: per-action latency, called directly on the bench's own windows.

Four rows, 20 repetitions each for every tool: snapshot, click, type, read-back. read-back is a fresh
observation of the window with the typed value found in it, the same kind of operation everywhere (Sky
has no separate `get`).

Method, stated in the result: a CLI tool is timed as one spawned process per action, minus the median
wall time of a no-op spawn of the same binary (so process start-up is not charged to the tool); the Sky
primitives are timed in-process around each call. The numbers are comparable in kind, not exactly, so
micro is reported across tools but is never a cross-tool ratchet gate (BaneySpaces is compared only with
its own earlier numbers).
"""
import statistics

from .scoring import percentile

ACTIONS = ("snapshot", "click", "type", "read-back")
REPS = 20
METHOD_CLI = "one spawned process per action, minus the median no-op spawn of the same binary"
METHOD_SKY = "in-process timing around each @oai/sky call"


def summarize_latency(samples):
    """samples: {action: [ms,...]} -> {action: {n, median_ms, p90_ms}}"""
    out = {}
    for action in ACTIONS:
        ms = samples.get(action, [])
        out[action] = {"n": len(ms), "median_ms": round(statistics.median(ms), 1) if ms else None,
                       "p90_ms": round(percentile(ms, 90), 1) if ms else None}
    return out


def noop_spawn_ms(exec_fn, argv, reps=REPS):
    """Median wall time of a command that does no work on any app."""
    times = [exec_fn(argv, timeout=15)[3] for _ in range(reps)]
    return statistics.median(times)


def run_micro(driver, text_wid, calc_wid, noop_ms, reps=REPS):
    """-> (latency summary, errors). text_wid and calc_wid are windows this run opened."""
    from .script import find_all, ref_of
    samples = {a: [] for a in ACTIONS}
    errors = []

    def net(res):
        return max(0.0, res.ms - noop_ms)

    for i in range(reps):
        res = driver.snapshot(text_wid)
        samples["snapshot"].append(net(res))
        if not res.ok:
            errors.append(f"snapshot: {res.code}")
            continue
        text = [n for n in find_all((res.data or {}).get("tree") or {}, {"role": "textfield"}) if ref_of(n)]
        if not text:
            errors.append("no text view")
            continue
        value = f"bench {i}"
        r = driver.run("type", ref=ref_of(text[0]), text=value)
        samples["type"].append(net(r))
        if not r.ok:
            errors.append(f"type: {r.code}")
        r = driver.snapshot(text_wid)
        samples["read-back"].append(net(r))
        seen = [n.get("value", "") for n in find_all((r.data or {}).get("tree") or {}, {"role": "textfield"})] if r.ok else []
        if not any(value in str(v) for v in seen):
            errors.append("read-back did not show the typed value")
    for _ in range(reps):
        res = driver.snapshot(calc_wid)
        if not res.ok:
            errors.append(f"calc snapshot: {res.code}")
            break
        clear = [n for n in find_all((res.data or {}).get("tree") or {}, {"role": "button", "text": "clear"}) if ref_of(n)]
        if not clear:
            errors.append("no clear button in Calculator")
            break
        r = driver.run("click", ref=ref_of(clear[0]))
        samples["click"].append(net(r))
        if not r.ok:
            errors.append(f"click: {r.code}")
    return summarize_latency(samples), errors


def invalid(latency, errors, reps=REPS):
    """-> list of reasons a micro measurement cannot be a result: any failed action or failed read-back
    validation, or fewer than `reps` samples for an action."""
    problems = list(errors)
    for action in ACTIONS:
        n = (latency.get(action) or {}).get("n", 0)
        if n < reps:
            problems.append(f"{action}: {n} of {reps} samples")
    return problems
