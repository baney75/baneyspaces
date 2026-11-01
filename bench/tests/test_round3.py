import json
import os
import subprocess
import tempfile
import unittest

import support
import harness
import ratchet
from benchlib import micro, report, scoring
from test_ratchet import BASE, baseline_of, result


class ResultOrdering(unittest.TestCase):
    def test_a_collision_file_sorts_after_its_original_not_by_raw_name(self):
        """first-F6, sol-F5: '-2-baneyspaces' < '-baneyspaces' as text"""
        with tempfile.TemporaryDirectory() as d:
            a = report.write_result(d, result("baneyspaces", "scripted", BASE, hms="100000"))
            b = report.write_result(d, dict(result("baneyspaces", "scripted", {"a": "fail", "b": "pass", "refuse-x": "refused_ok", "c": "fail"}, hms="100000"), run_id="newer"))
            self.assertIn("-100000-2-baneyspaces", b)
            self.assertEqual(report.newest(d)[("baneyspaces", "scripted")]["run_id"], "newer")
            names = [os.path.basename(p) for p, _ in report.all_results(d)]
            self.assertEqual(names, [os.path.basename(a), os.path.basename(b)])

    def test_a_date_override_cannot_put_a_newer_run_first(self):
        with tempfile.TemporaryDirectory() as d:
            report.write_result(d, result("baneyspaces", "scripted", BASE, date="2026-11-02", hms="090000"))
            report.write_result(d, dict(result("baneyspaces", "scripted", BASE, date="2026-11-01", hms="230000"), run_id="older"))
            self.assertEqual(report.newest(d)[("baneyspaces", "scripted")]["date"], "2026-11-02")


class RunShIdle(unittest.TestCase):
    def test_two_hid_idle_lines_are_not_concatenated(self):
        """first-F5: 30 s and 30 s used to read as 3030"""
        run = os.path.join(support.BENCH, "run.sh")
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "ioreg")
            open(p, "w").write('#!/bin/sh\necho \'  "HIDIdleTime" = 30000000000\'\necho \'  "HIDIdleTime" = 30000000000\'\n')
            os.chmod(p, 0o755)
            env = dict(os.environ, PATH=d + os.pathsep + os.environ["PATH"], BENCH_BANEYSPACES="/bin/echo", BENCH_AGENT_DESKTOP="/bin/echo")
            r = subprocess.run([run, "--tool", "baneyspaces"], capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(r.returncode, 3)
        self.assertIn("HIDIdleTime 30 s", r.stdout)


class MicroValidity(unittest.TestCase):
    def lat(self, n=20):
        return {a: {"n": n, "median_ms": 5.0, "p90_ms": 6.0} for a in micro.ACTIONS}

    def test_a_clean_full_measurement_is_valid(self):
        self.assertEqual(micro.invalid(self.lat(), []), [])

    def test_failed_actions_or_missing_samples_make_it_invalid(self):
        """sol-F4"""
        self.assertTrue(micro.invalid(self.lat(), ["read-back did not show the typed value"]))
        self.assertTrue(micro.invalid(self.lat(0), []))
        partial = self.lat()
        partial["click"]["n"] = 7
        self.assertIn("click: 7 of 20 samples", micro.invalid(partial, []))

    def test_an_invalid_micro_run_cannot_update_the_baseline(self):
        with tempfile.TemporaryDirectory() as d:
            res, base = os.path.join(d, "r"), os.path.join(d, "b")
            os.makedirs(res)
            report.write_result(res, {"tool": "baneyspaces", "level": "micro", "date": "2026-11-01", "hms": "100000", "full": True,
                                      "micro": {"status": "invalid", "latency": self.lat(0)}})
            ratchet.main(["--results-dir", res, "--baseline-dir", base, "--update"])
            self.assertFalse(os.path.exists(os.path.join(base, "baneyspaces-micro.json")))


class RunThatMeasuredNothing(unittest.TestCase):
    def test_full_needs_a_scored_task(self):
        """second-S5"""
        none = [{"id": "a", "status": "unavailable"}, {"id": "b", "status": "infra_error"}]
        self.assertFalse(harness.run_is_full(none, None, ""))
        self.assertTrue(harness.run_is_full([{"id": "a", "status": "pass"}, {"id": "b", "status": "unavailable"}], None, ""))
        self.assertFalse(harness.run_is_full([{"id": "a", "status": "pass"}], ["a"], ""))
        self.assertFalse(harness.run_is_full([{"id": "a", "status": "pass"}, {"id": "b", "status": "not_run"}], None, ""))

    def test_a_run_that_lost_most_of_the_baseline_to_excluded_statuses_is_a_ratchet_problem(self):
        with tempfile.TemporaryDirectory() as d:
            res, base = os.path.join(d, "r"), os.path.join(d, "b")
            os.makedirs(base)
            json.dump(baseline_of(result("baneyspaces", "scripted", BASE, dur=2.0)), open(os.path.join(base, "baneyspaces-scripted.json"), "w"))
            thin = {"a": "pass", "b": "unavailable", "refuse-x": "unavailable", "c": "unavailable"}
            report.write_result(res, result("baneyspaces", "scripted", thin, dur=2.0))
            self.assertEqual(ratchet.main(["--results-dir", res, "--baseline-dir", base]), 1)

    def test_update_refuses_a_run_that_scored_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            res, base = os.path.join(d, "r"), os.path.join(d, "b")
            report.write_result(res, result("baneyspaces", "scripted", {"a": "unavailable", "b": "infra_error"}))
            ratchet.main(["--results-dir", res, "--baseline-dir", base, "--update"])
            self.assertFalse(os.path.exists(os.path.join(base, "baneyspaces-scripted.json")))


class RefereeIsRequired(unittest.TestCase):
    def test_a_missing_agent_desktop_stops_a_baneyspaces_run_too(self):
        """second-S6: it is the referee and the cleanup driver for every column"""
        import contextlib
        import io
        old = dict(os.environ)
        os.environ.update(BENCH_BANEYSPACES="/bin/echo", BENCH_AGENT_DESKTOP="/nonexistent/agent-desktop")
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                rc = harness.main(["--dry-run", "--tool", "baneyspaces", "--level", "scripted"])
        finally:
            os.environ.clear()
            os.environ.update(old)
        self.assertEqual(rc, 1)
        self.assertIn("referee (agent-desktop)", buf.getvalue())
        self.assertIn("MISSING", buf.getvalue())


class SamplerBans(unittest.TestCase):
    def test_nothing_posts_events_or_reaches_chatgpt_from_the_sampler_or_ratchet(self):
        src = open(os.path.join(support.BENCH, "lib", "sampler.swift")).read()
        self.assertNotIn("CGEventPost", src)
        self.assertNotIn("postToPid", src)


if __name__ == "__main__":
    unittest.main()
