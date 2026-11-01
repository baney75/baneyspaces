import unittest

import support  # noqa: F401
from benchlib import scoring


def rec(id, status, dur=1.0, changes=0, **kw):
    return {"id": id, "status": status, "duration_s": dur, "changes": [{"fields": ["front"]}] * changes, **kw}


class Summary(unittest.TestCase):
    def test_percentile(self):
        self.assertEqual(scoring.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 90), 9)
        self.assertEqual(scoring.percentile([5], 90), 5)
        self.assertIsNone(scoring.percentile([], 90))

    def test_the_columns(self):
        tasks = [rec("a", "pass", 1.0), rec("b", "pass", 3.0, changes=2), rec("c", "fail", 5.0),
                 rec("d", "refused_ok", 0.5, impossible=True), {"id": "e", "status": "unavailable"}]
        s = scoring.summarize(tasks)
        self.assertEqual((s["tasks_run"], s["passed"], s["tasks_unavailable"]), (4, 3, 1))
        self.assertEqual(s["success_rate"], 0.75)
        self.assertEqual((s["screen_changes"], s["tasks_with_changes"]), (2, 1))
        self.assertEqual(s["median_s"], 2.0)
        self.assertEqual((s["refusals_good"], s["refusals_expected"]), (1, 1))

    def test_infra_errors_and_lost_monitor_are_never_charged_to_the_tool(self):
        tasks = [rec("a", "pass"), rec("b", "infra_error"), rec("c", "monitor_lost"), rec("d", "not_run"), rec("e", "unavailable")]
        s = scoring.summarize(tasks)
        self.assertEqual((s["tasks_run"], s["success_rate"]), (1, 1.0))
        self.assertEqual((s["tasks_infra_error"], s["tasks_monitor_lost"], s["tasks_not_run"], s["tasks_unavailable"]), (1, 1, 1, 1))

    def test_setup_and_teardown_disturbances_count_even_when_the_task_errored(self):
        """sol-F3: a window dropped on Donovan's workspace during setup is charged."""
        tasks = [rec("a", "infra_error", setup_changes=[{"fields": ["unplaced_window"]}]),
                 rec("b", "pass", teardown_changes=[{"fields": ["key_window"]}], changes=1)]
        s = scoring.summarize(tasks)
        self.assertEqual((s["screen_changes"], s["tasks_with_changes"], s["screen_changes_in_task"]), (3, 2, 1))

    def test_no_run_has_no_rate(self):
        self.assertIsNone(scoring.summarize([{"id": "a", "status": "not_run"}])["success_rate"])

    def test_a_refusal_needs_a_suggestion_and_leaves_no_trace(self):
        t = {"impossible": True}
        good = {"code": "x", "suggestion": "do y"}
        self.assertEqual(scoring.classify(t, True, {"ok": True}, good), "refused_ok")
        self.assertEqual(scoring.classify(t, True, {"ok": True}, {"code": "x", "suggestion": ""}), "fail")
        self.assertEqual(scoring.classify(t, False, {"ok": True}, good), "fail")
        self.assertEqual(scoring.classify(t, True, {"ok": False}, None), "fail")

    def test_a_refusal_that_also_changed_the_screen_is_a_failure(self):
        """sol-F5"""
        t = {"impossible": True}
        good = {"code": "x", "suggestion": "do y"}
        for side in ({"changes": 1}, {"hid": 1}, {"collateral": 1}):
            self.assertEqual(scoring.classify(t, True, {"ok": True}, good, side), "fail", side)
        self.assertEqual(scoring.classify(t, True, {"ok": True}, good, {"changes": 0, "hid": 0, "collateral": 0}), "refused_ok")

    def test_a_normal_task_needs_the_steps_and_the_readback(self):
        self.assertEqual(scoring.classify({}, True, {"ok": True}, None), "pass")
        self.assertEqual(scoring.classify({}, False, {"ok": True}, None), "fail")
        self.assertEqual(scoring.classify({}, True, {"ok": False}, None), "fail")

    def test_table_has_a_column_per_tool(self):
        s = scoring.summarize([rec("a", "pass")])
        md = scoring.table({"baneyspaces": {"summary": s}, "chatgpt": None}, scoring.SUMMARY_COLUMNS)
        self.assertIn("| | baneyspaces | chatgpt |", md)
        self.assertIn("not run", md)


if __name__ == "__main__":
    unittest.main()
