import json
import os
import tempfile
import unittest

import support  # noqa: F401
import ratchet
from benchlib import compare, report, scoring


def result(tool, level, statuses, dur=1.0, changes=None, date="2026-11-01", hms="100000", full=True, **kw):
    changes = changes or {}
    tasks = []
    for tid, st in statuses.items():
        tasks.append({"id": tid, "status": st, "duration_s": dur, "impossible": tid.startswith("refuse"),
                      "changes": [{"fields": ["front"]}] * changes.get(tid, 0)})
    r = {"tool": tool, "level": level, "date": date, "hms": hms, "run_id": f"{date}-{hms}-ab", "only": None, "full": full,
         "tasks": tasks, "summary": scoring.summarize(tasks), "versions": None, "aborted": None}
    r.update(kw)
    return r


BASE = {"a": "pass", "b": "pass", "refuse-x": "refused_ok", "c": "fail"}


def baseline_of(res):
    return {"kind": "measured", "tasks": ratchet.task_map(res)}


class Baseline(unittest.TestCase):
    def setUp(self):
        self.base = result("baneyspaces", "scripted", BASE, dur=2.0)
        self.bt = ratchet.task_map(self.base)

    def regress(self, now):
        return compare.vs_baseline(now["tasks"], self.bt)

    def test_same_result_holds(self):
        self.assertEqual(self.regress(self.base), [])

    def test_a_task_that_passed_and_now_fails(self):
        got = self.regress(result("baneyspaces", "scripted", {**BASE, "a": "fail"}, dur=2.0))
        self.assertTrue(any("task a" in p for p in got), got)

    def test_each_column_trips_alone(self):
        for label, now in (
            ("screen changes", result("baneyspaces", "scripted", BASE, dur=2.0, changes={"a": 1})),
            ("median s/task", result("baneyspaces", "scripted", BASE, dur=4.0)),
            ("p90 s/task", result("baneyspaces", "scripted", BASE, dur=4.0)),
            ("good refusals", result("baneyspaces", "scripted", {**BASE, "refuse-x": "fail"}, dur=2.0)),
        ):
            self.assertTrue(any(label in p for p in self.regress(now)), label)

    def test_timing_noise_inside_the_slack_is_not_a_regression(self):
        self.assertEqual(self.regress(result("baneyspaces", "scripted", BASE, dur=2.4)), [])

    def test_a_task_that_improves_is_fine(self):
        self.assertEqual(self.regress(result("baneyspaces", "scripted", {**BASE, "c": "pass"}, dur=1.5)), [])

    def test_tasks_the_run_did_not_complete_cannot_cause_a_regression(self):
        """second-F13: losing refuse-x to 'unavailable' must not read as fewer good refusals."""
        for st in ("unavailable", "infra_error", "monitor_lost", "not_run"):
            now = result("baneyspaces", "scripted", {**BASE, "refuse-x": st}, dur=2.0)
            self.assertEqual(self.regress(now), [], st)

    def test_success_rate_is_over_the_common_tasks_only(self):
        """Losing a failing task to 'unavailable' used to raise the rate and mask a real loss."""
        now = result("baneyspaces", "scripted", {"a": "fail", "b": "pass", "refuse-x": "refused_ok", "c": "unavailable"}, dur=2.0)
        self.assertTrue(any("success rate" in p for p in self.regress(now)))

    def test_nothing_in_common_is_not_a_failure(self):
        self.assertEqual(compare.vs_baseline(result("baneyspaces", "scripted", {"z": "pass"})["tasks"], self.bt), [])


class AgainstOthers(unittest.TestCase):
    def test_baneyspaces_must_win_or_tie_every_column(self):
        mine = result("baneyspaces", "agent", {"a": "pass", "b": "pass"}, dur=2.0)
        self.assertEqual(compare.vs_other(mine, "chatgpt", result("chatgpt", "agent", {"a": "pass", "b": "pass"}, dur=2.0)), [])
        self.assertEqual(len(compare.vs_other(mine, "chatgpt", result("chatgpt", "agent", {"a": "pass", "b": "pass"}, dur=1.0))), 2)
        beaten = compare.vs_other(result("baneyspaces", "agent", {"a": "pass", "b": "fail"}), "agent-desktop",
                                  result("agent-desktop", "agent", {"a": "pass", "b": "pass"}))
        self.assertTrue(any("success rate" in p for p in beaten))
        moves = compare.vs_other(result("baneyspaces", "agent", {"a": "pass"}, changes={"a": 1}), "agent-desktop",
                                 result("agent-desktop", "agent", {"a": "pass"}))
        self.assertTrue(any("screen changes" in p for p in moves))

    def test_only_tasks_both_completed_are_compared(self):
        mine = result("baneyspaces", "agent", {"a": "pass", "b": "infra_error"})
        other = result("chatgpt", "agent", {"a": "pass", "b": "fail"})
        self.assertEqual(compare.vs_other(mine, "chatgpt", other), [])

    def test_no_common_task_is_reported(self):
        self.assertTrue(compare.vs_other(result("baneyspaces", "agent", {"a": "pass"}), "chatgpt", result("chatgpt", "agent", {"b": "pass"})))

    def test_micro_latency_is_only_compared_with_its_own_baseline(self):
        lat = lambda **k: {"latency": {a: {"median_ms": v} for a, v in k.items()}}
        self.assertEqual(compare.latency_vs_baseline(lat(snapshot=70), lat(snapshot=60)), [])
        self.assertEqual(len(compare.latency_vs_baseline(lat(snapshot=600), lat(snapshot=60))), 1)
        self.assertFalse(hasattr(compare, "latency_vs_other"))


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.res = os.path.join(self.tmp.name, "results")
        self.base = os.path.join(self.tmp.name, "baseline")
        os.makedirs(self.res)

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, r):
        return report.write_result(self.res, r)

    def put_baseline(self, r, level="scripted"):
        os.makedirs(self.base, exist_ok=True)
        with open(os.path.join(self.base, f"baneyspaces-{level}.json"), "w") as fh:
            json.dump(baseline_of(r), fh)

    def cli(self, *extra):
        return ratchet.main(["--results-dir", self.res, "--baseline-dir", self.base, *extra])

    def test_nothing_to_compare_passes_unless_required(self):
        self.assertEqual(self.cli(), 0)
        self.assertEqual(self.cli("--require"), 2)

    def test_without_a_baseline_a_run_has_nothing_to_regress_against(self):
        self.put(result("baneyspaces", "scripted", BASE))
        self.assertEqual(self.cli(), 0)

    def test_holding_result_exits_zero(self):
        r = result("baneyspaces", "scripted", BASE, dur=2.0)
        self.put(r)
        self.put_baseline(r)
        self.assertEqual(self.cli(), 0)

    def test_regression_exits_one(self):
        self.put_baseline(result("baneyspaces", "scripted", BASE, dur=2.0))
        self.put(result("baneyspaces", "scripted", {**BASE, "a": "fail"}, dur=2.0))
        self.assertEqual(self.cli(), 1)

    def test_losing_to_another_tool_exits_one(self):
        self.put(result("baneyspaces", "scripted", BASE, dur=2.0))
        self.put(result("agent-desktop", "scripted", {"a": "pass", "b": "pass", "refuse-x": "refused_ok", "c": "pass"}, dur=2.0))
        self.assertEqual(self.cli(), 1)

    def test_a_partial_run_is_never_compared(self):
        """second-F14: a --only run must not stand in for the full one."""
        self.put_baseline(result("baneyspaces", "scripted", BASE, dur=2.0))
        self.put(result("baneyspaces", "scripted", {"a": "fail"}, dur=2.0, full=False, only=["a"], hms="110000"))
        self.assertEqual(self.cli(), 0)

    def test_update_writes_the_first_baseline_from_a_full_run(self):
        self.put(result("baneyspaces", "scripted", BASE, dur=2.0))
        self.assertEqual(self.cli("--update"), 0)
        with open(os.path.join(self.base, "baneyspaces-scripted.json")) as fh:
            b = json.load(fh)
        self.assertEqual(b["kind"], "measured")
        self.assertEqual(b["tasks"]["a"]["status"], "pass")

    def test_update_refuses_a_partial_or_aborted_run(self):
        self.put(result("baneyspaces", "scripted", {"a": "pass"}, full=False, only=["a"]))
        self.assertEqual(self.cli("--update"), 0)      # nothing full to write, nothing written
        self.assertFalse(os.path.exists(os.path.join(self.base, "baneyspaces-scripted.json")))
        self.put(result("baneyspaces", "scripted", BASE, full=False, aborted="stopped: input seen", hms="120000"))
        self.cli("--update")
        self.assertFalse(os.path.exists(os.path.join(self.base, "baneyspaces-scripted.json")))

    def test_update_refuses_a_regression(self):
        self.put_baseline(result("baneyspaces", "scripted", BASE, dur=2.0))
        self.put(result("baneyspaces", "scripted", {**BASE, "a": "fail"}, dur=2.0))
        self.assertEqual(self.cli("--update"), 1)

    def test_update_keeps_what_the_new_run_did_not_complete(self):
        """sol-F6: a run with tasks unavailable must not delete them from the ratchet."""
        self.put_baseline(result("baneyspaces", "scripted", BASE, dur=2.0))
        self.put(result("baneyspaces", "scripted", {**BASE, "b": "unavailable", "c": "pass"}, dur=2.0, hms="130000"))
        self.assertEqual(self.cli("--update"), 0)
        with open(os.path.join(self.base, "baneyspaces-scripted.json")) as fh:
            t = json.load(fh)["tasks"]
        self.assertEqual((t["b"]["status"], t["c"]["status"]), ("pass", "pass"))

    def test_the_first_measured_run_can_replace_nothing_because_nothing_is_seeded(self):
        """first-F3: no guessed floor is committed."""
        bdir = os.path.join(support.BENCH, "baseline")
        files = [f for f in os.listdir(bdir)] if os.path.isdir(bdir) else []
        for f in files:
            with open(os.path.join(bdir, f)) as fh:
                self.assertEqual(json.load(fh).get("kind"), "measured", f)
        self.assertEqual([f for f in files if f.endswith(".json")], [])

    def test_micro_is_never_a_cross_tool_gate(self):
        lat = lambda v: {"status": "ok", "latency": {"snapshot": {"median_ms": v}}}
        self.put({"tool": "baneyspaces", "level": "micro", "date": "2026-11-01", "hms": "100000", "full": True, "micro": lat(900)})
        self.put({"tool": "agent-desktop", "level": "micro", "date": "2026-11-01", "hms": "100000", "full": True, "micro": lat(10)})
        best = report.newest(self.res)
        self.assertIn(("baneyspaces", "micro"), best)        # first-F13: the files were really loaded
        self.assertIn(("agent-desktop", "micro"), best)
        self.assertEqual(self.cli(), 0)

    def test_micro_regression_against_its_own_baseline_fails(self):
        lat = lambda v: {"status": "ok", "latency": {"snapshot": {"median_ms": v}}}
        os.makedirs(self.base, exist_ok=True)
        json.dump({"kind": "measured", "latency": lat(60)["latency"]}, open(os.path.join(self.base, "baneyspaces-micro.json"), "w"))
        self.put({"tool": "baneyspaces", "level": "micro", "date": "2026-11-01", "hms": "100000", "full": True, "micro": lat(300)})
        self.assertEqual(self.cli(), 1)


class SetupAndTeardownDoNotDecideWhoIsBest(unittest.TestCase):
    """first-F7: the shared `agent open` and cleanup run the same harness code for every tool."""

    def test_the_cross_tool_gate_uses_in_task_changes_only(self):
        mine = result("baneyspaces", "agent", {"a": "pass"})
        mine["tasks"][0]["setup_changes"] = [{"fields": ["front"]}, {"fields": ["unplaced_window"]}]
        mine["tasks"][0]["teardown_changes"] = [{"fields": ["key_window"]}]
        other = result("agent-desktop", "agent", {"a": "pass"})
        self.assertEqual(compare.vs_other(mine, "agent-desktop", other), [])
        s = scoring.summarize(mine["tasks"])
        self.assertEqual((s["screen_changes"], s["screen_changes_in_task"]), (3, 0))      # still reported, not gated

    def test_a_change_inside_the_task_still_loses_the_gate(self):
        mine = result("baneyspaces", "agent", {"a": "pass"}, changes={"a": 1})
        self.assertTrue(compare.vs_other(mine, "agent-desktop", result("agent-desktop", "agent", {"a": "pass"})))

    def test_the_baseline_stores_in_task_changes(self):
        r = result("baneyspaces", "scripted", {"a": "pass"}, changes={"a": 2})
        r["tasks"][0]["setup_changes"] = [{"fields": ["front"]}]
        self.assertEqual(ratchet.task_map(r)["a"]["changes"], 2)


class Files(unittest.TestCase):
    def test_a_second_run_the_same_day_never_overwrites(self):
        with tempfile.TemporaryDirectory() as d:
            a = report.write_result(d, result("baneyspaces", "scripted", BASE))
            b = report.write_result(d, result("baneyspaces", "scripted", {"a": "fail"}))
            self.assertNotEqual(a, b)
            self.assertEqual(len(os.listdir(d)), 2)
            for f in os.listdir(d):
                self.assertTrue(report.FILE_RE.match(f), f)

    def test_newest_is_the_latest_full_run_and_ignores_partial(self):
        with tempfile.TemporaryDirectory() as d:
            report.write_result(d, result("baneyspaces", "scripted", BASE, hms="090000"))
            report.write_result(d, result("baneyspaces", "scripted", {"a": "fail"}, hms="100000", full=False, only=["a"]))
            self.assertEqual(report.newest(d)[("baneyspaces", "scripted")]["hms"], "090000")

    def test_result_records_its_run_id(self):
        self.assertTrue(result("baneyspaces", "scripted", BASE)["run_id"])


class Latest(unittest.TestCase):
    def test_latest_md_has_each_level_the_notes_and_partial_runs(self):
        with tempfile.TemporaryDirectory() as d:
            report.write_result(d, result("baneyspaces", "scripted", BASE))
            report.write_result(d, result("agent-desktop", "scripted", BASE, dur=3.0))
            report.write_result(d, result("agent-desktop", "scripted", {"a": "pass"}, full=False, only=["a"], hms="110000"))
            report.write_result(d, {"tool": "chatgpt", "level": "micro", "date": "2026-11-01", "hms": "120000", "full": False, "versions": None,
                                    "micro": {"status": "n/a", "why": "service did not start", "latency": None}, "aborted": "service did not start"})
            md = open(report.write_latest(d)).read()
            for needle in ("## Scripted", "## End to end", "Not run yet", "Cua", "Partial runs (not gated)", "holds against every tool measured",
                           "sandbox", "infra error"):
                self.assertIn(needle, md)


if __name__ == "__main__":
    unittest.main()
