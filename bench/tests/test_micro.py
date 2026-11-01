import os
import unittest

import support
from support import FakeDriver, node
from benchlib import micro
from benchlib.drivers import Result


class Slack(unittest.TestCase):
    def test_a_five_fold_regression_is_caught(self):
        """first-F10: 60 ms to 300 ms passed under the old 250 ms absolute slack."""
        from benchlib import compare
        lat = lambda v: {"latency": {"snapshot": {"median_ms": v}}}
        self.assertEqual(len(compare.latency_vs_baseline(lat(300), lat(60))), 1)
        self.assertEqual(compare.latency_vs_baseline(lat(95), lat(60)), [])       # 60*1.25+25 = 100

    def test_both_cli_tools_use_the_same_kind_of_no_op(self):
        """first-F11"""
        src = open(os.path.join(support.BENCH, "harness.py")).read()
        self.assertIn('noop = [p["baneyspaces"], "--version"]', src)
        self.assertIn('noop = [p["agent_desktop"], "--version"]', src)
        self.assertIn('"noop_command": noop', src)


class Method(unittest.TestCase):
    def test_every_tool_gets_the_same_reps_and_rows(self):
        self.assertEqual(micro.REPS, 20)
        self.assertEqual(micro.ACTIONS, ("snapshot", "click", "type", "read-back"))
        src = open(support.BENCH + "/chatgpt_micro.mjs").read()
        self.assertIn('"20"', src)

    def test_cli_numbers_have_the_no_op_spawn_subtracted(self):
        tree = node("window", "t", children=[node("textfield", value="bench 0", ref="@s:e1")])
        calc = node("window", "c", children=[node("button", "All Clear", ref="@s:e9")])
        d = FakeDriver({(1, None): tree, (2, None): calc})
        d.snapshot = lambda wid, surface=None: Result(True, {"tree": tree if wid == 1 else calc}, None, 150)
        d.run = lambda verb, timeout=60, **kw: Result(True, {}, None, 160)
        lat, errs = micro.run_micro(d, 1, 2, noop_ms=100, reps=3)
        self.assertEqual(lat["snapshot"]["median_ms"], 50.0)
        self.assertEqual(lat["click"]["median_ms"], 60.0)
        self.assertEqual(lat["type"]["n"], 3)

    def test_a_read_back_that_does_not_show_the_value_is_an_error(self):
        tree = node("window", "t", children=[node("textfield", value="old", ref="@s:e1")])
        d = FakeDriver({})
        d.snapshot = lambda wid, surface=None: Result(True, {"tree": tree}, None, 10)
        d.run = lambda verb, timeout=60, **kw: Result(True, {}, None, 10)
        _, errs = micro.run_micro(d, 1, 2, noop_ms=0, reps=1)
        self.assertTrue(any("read-back" in e for e in errs))


if __name__ == "__main__":
    unittest.main()
