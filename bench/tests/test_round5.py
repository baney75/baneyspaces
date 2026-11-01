import os
import sys
import tempfile
import threading
import time
import unittest

import support
import ratchet
from support import fake_exec
from benchlib import compare, monitor, report, runner, scoring
from benchlib.execs import Aborted, Exec
from test_ratchet import BASE, baseline_of, result
from test_runner import FakeMonitor, FakeOpener, OK, TASK, ctx

PLIST = "<plist>scientific</plist>"
CALC = dict(TASK, setup=dict(TASK["setup"], restore_defaults=["com.apple.calculator"]))


def defaults_exec(export=(0, PLIST, ""), imp=(0, "", ""), after=None, log=None):
    """A fake for `defaults`: export answers `export` the first time and `after` (default: the same) once imported."""
    state = {"imported": False}
    log = log if log is not None else []

    def ex(argv, timeout=60, env=None, stdin=None, cwd=None):
        log.append((list(argv), stdin))
        if argv[:2] == ["defaults", "export"]:
            return (*((after or export) if state["imported"] else export), 1)
        if argv[:2] == ["defaults", "import"]:
            state["imported"] = True
            return (*imp, 1)
        return 0, "", "", 1
    ex.log = log
    return ex


class CalculatorDefaults(unittest.TestCase):
    """sol-F3, sonnet-F2, second-S2, second-S3"""

    def run_calc(self, ex, opener=None, recovery=None, aborted=lambda: False, task=CALC, **kw):
        op = opener or FakeOpener([5])
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, OK, opener=op, aborted_fn=aborted, **kw)
            c.exec = ex
            c.recovery_dir = recovery
            try:
                return runner.run_task(task, c), c, op
            finally:
                c.server_obj.stop()

    def test_a_failed_export_is_not_taken_for_an_absent_domain_and_nothing_is_touched(self):
        for export in ((124, "", "timeout after 15s"), (1, "", "cfprefsd unavailable"), (0, "", ""), (2, "partial", "boom")):
            ex = defaults_exec(export=export)
            rec, c, op = self.run_calc(ex)
            self.assertEqual(rec["status"], "infra_error", export)
            self.assertIn("could not back up", rec["why"])
            self.assertEqual(op.opened, [], export)                                    # nothing was opened
            self.assertFalse(any(a[0][:2] in (["defaults", "delete"], ["defaults", "import"]) for a in ex.log), export)

    def test_only_a_confirmed_absent_domain_is_deleted_afterwards(self):
        ex = defaults_exec(export=(1, "", "Domain com.apple.calculator does not exist"), after=(1, "", "Domain com.apple.calculator does not exist"))
        rec, c, op = self.run_calc(ex)
        self.assertTrue(any(a[0][:2] == ["defaults", "delete"] for a in ex.log))
        self.assertEqual(rec["status"], "pass")

    def test_the_backup_is_written_to_a_recovery_file_and_removed_after_a_verified_restore(self):
        with tempfile.TemporaryDirectory() as rd:
            seen = {}
            ex = defaults_exec()
            orig = ex

            def watching(argv, **k):
                p = os.path.join(rd, "t1", "com.apple.calculator.plist")
                if argv[:2] == ["defaults", "import"]:
                    seen["during"] = os.path.exists(p) and open(p).read()
                return orig(argv, **k)
            watching.log = orig.log
            rec, c, op = self.run_calc(watching, recovery=rd)
            self.assertEqual(seen["during"], PLIST)
            self.assertFalse(os.path.exists(os.path.join(rd, "t1", "com.apple.calculator.plist")))
            self.assertNotIn("teardown_pending", rec)

    def test_a_restore_that_fails_or_does_not_match_keeps_the_backup_and_says_where(self):
        for kw in (dict(imp=(1, "", "boom")), dict(after=(0, "<plist>other</plist>", ""))):
            with tempfile.TemporaryDirectory() as rd:
                rec, c, op = self.run_calc(defaults_exec(**kw), recovery=rd)
                self.assertEqual(rec["teardown_pending"]["defaults"], ["com.apple.calculator"], kw)
                self.assertEqual(rec["teardown_pending"]["recovery"], os.path.join(rd, "t1"))
                self.assertTrue(os.path.exists(os.path.join(rd, "t1", "com.apple.calculator.plist")), kw)

    def test_preferences_are_restored_only_after_the_instance_has_exited(self):
        """sonnet-F2: quitting returns before the process is gone; its exit would overwrite the import"""
        op = FakeOpener([5])
        op.pids = {5: 777}
        order = []
        alive = {"v": True}

        def alive_fn(pid):
            order.append(("alive?", alive["v"]))
            return alive["v"]
        base = defaults_exec()

        def ex(argv, **k):
            if argv[:2] == ["kill", "-TERM"]:
                order.append("kill")
                alive["v"] = False
            if argv[:2] == ["defaults", "import"]:
                order.append("import")
            return base(argv, **k)
        ex.log = base.log
        rec, c, _ = self.run_calc(ex, opener=op, alive_fn=alive_fn)
        self.assertLess(order.index("kill"), order.index("import"))
        self.assertIn(("alive?", False), order)
        self.assertNotIn("teardown_pending", rec)

    def test_an_instance_that_will_not_exit_keeps_the_preferences_pending(self):
        op = FakeOpener([5])
        op.pids = {5: 777}
        with tempfile.TemporaryDirectory() as rd:
            ex = defaults_exec()
            rec, c, _ = self.run_calc(ex, opener=op, alive_fn=lambda pid: True, recovery=rd)
        self.assertEqual(rec["teardown_pending"]["defaults"], ["com.apple.calculator"])
        self.assertFalse(any(a[0][:2] == ["defaults", "import"] for a in ex.log))
        self.assertIn("backup kept", rec["teardown_pending"]["error"])

    def test_after_an_abort_the_instance_is_ended_quietly_and_the_preferences_are_put_back(self):
        """second-S3: Donovan coming back is exactly when an abort happens; the quiet path ignores the abort"""
        t = dict(CALC, setup=dict(CALC["setup"], requires={"not_running": ["TextEdit"]}))
        op = FakeOpener([5])
        op.pids = {5: 777}
        alive = {"v": True}
        quiet = defaults_exec()
        killed = []

        def qex(argv, **k):
            if argv[:2] == ["kill", "-TERM"]:
                killed.append(argv)
                alive["v"] = False
            return quiet(argv, **k)
        qex.log = quiet.log
        from benchlib.execs import Aborted as _A

        def loud(argv, **k):                       # the run's Exec after an abort refuses everything
            raise _A("aborted")
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, OK, opener=op, aborted_fn=lambda: True, running_fn=lambda a: False)
            c.exec, c.quiet_exec, c.alive_fn = loud, qex, lambda pid: alive["v"]
            c.ref.pid_windows_result = (True, [])
            rec = runner.run_task(t, c)
            c.server_obj.stop()
        self.assertEqual(killed, [["kill", "-TERM", "777"]])
        self.assertTrue(any(a[0][:2] == ["defaults", "import"] for a in quiet.log))
        self.assertNotIn("defaults", rec.get("teardown_pending", {}))


class ExecShutdown(unittest.TestCase):
    """sonnet-F1"""

    def test_an_exception_while_waiting_kills_the_child(self):
        calls = {"n": 0}

        class Boom(threading.Event):
            def is_set(self):
                calls["n"] += 1
                if calls["n"] == 1:
                    return False                     # Exec.__call__'s own check at the start
                raise KeyboardInterrupt               # the next one is inside the wait loop
        ex = Exec(abort=Boom())
        procs = []
        orig = ex._kill
        ex._kill = lambda p: (procs.append(p), orig(p))
        t0 = time.monotonic()
        with self.assertRaises(KeyboardInterrupt):
            ex(["/bin/sleep", "30"], timeout=60)
        self.assertLess(time.monotonic() - t0, 5)
        self.assertTrue(procs)
        self.assertIsNotNone(procs[0].wait(5))        # the child is dead, not left running

    def test_kill_all_ends_every_running_command(self):
        ex = Exec()
        out = {}

        def run():
            out["r"] = ex(["/bin/sleep", "30"], timeout=60)
        th = threading.Thread(target=run)
        th.start()
        for _ in range(100):
            if ex._live_procs:
                break
            time.sleep(0.02)
        self.assertEqual(ex.kill_all(), 1)
        th.join(5)
        self.assertFalse(th.is_alive())
        self.assertNotEqual(out["r"][0], 0)
        self.assertEqual(ex._live_procs, set())

    def test_the_run_installs_signal_handlers_that_stop_the_children(self):
        src = open(os.path.join(support.BENCH, "harness.py")).read()
        self.assertIn("signal.signal(s, on_signal)", src)
        self.assertIn("exec_fn.kill_all()", src)
        self.assertIn('kind="signal"', src)


class HarnessLeakIsNotTheToolsFailure(unittest.TestCase):
    """first-F2: the ratchet ignores infra_error, setup leaks included"""

    def test_an_infra_error_with_a_setup_leak_is_neither_a_regression_nor_a_score(self):
        base = result("baneyspaces", "scripted", BASE, dur=2.0)
        now = result("baneyspaces", "scripted", {**BASE, "a": "infra_error"}, dur=2.0)
        now["tasks"][0]["setup_leak"] = [{"fields": ["unplaced_window"]}]
        self.assertEqual(compare.vs_baseline(now["tasks"], ratchet.task_map(base)), [])
        s = scoring.summarize(now["tasks"])
        self.assertEqual(s["tasks_infra_error"], 1)
        self.assertEqual(s["tasks_run"], 3)

    def test_the_runner_never_returns_fail_for_a_setup_leak(self):
        src = open(os.path.join(support.BENCH, "benchlib", "runner.py")).read()
        self.assertNotIn('status="fail", why="setup leaked', src)


class SamplerWait(unittest.TestCase):
    def test_wait_sampled_returns_when_the_sampler_stamp_passes_the_target(self):
        m = monitor.Monitor(["x"])
        m.last_sample_t = 100.0
        self.assertTrue(m.wait_sampled(99.0, timeout=0.05))
        self.assertFalse(m.wait_sampled(101.0, timeout=0.05))
        threading.Timer(0.05, lambda: setattr(m, "last_sample_t", 102.0)).start()
        self.assertTrue(m.wait_sampled(101.5, timeout=2))

    def test_a_lost_monitor_stops_the_wait(self):
        m = monitor.Monitor(["x"])
        m.losses.append({"t": 1, "why": "x"})
        t0 = time.monotonic()
        self.assertFalse(m.wait_sampled(1e12, timeout=5))
        self.assertLess(time.monotonic() - t0, 1)


class ResultsDirectory(unittest.TestCase):
    def test_write_latest_creates_a_missing_directory(self):
        with tempfile.TemporaryDirectory() as d:
            path = report.write_latest(os.path.join(d, "never", "made"))
            self.assertTrue(os.path.exists(path))


if __name__ == "__main__":
    unittest.main()
