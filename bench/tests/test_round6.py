import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest

import support
import harness
from support import FakeDriver, fake_exec, node
from benchlib import cleanup, runner
from benchlib.drivers import AgentDesktopDriver, Result
from benchlib.execs import Exec, PgidRegistry, RegistrationFailed
from test_round4 import DelayedMonitor, FakeClock, LEAK, WIN
from test_round5 import CALC, PLIST, defaults_exec
from test_runner import FakeMonitor, FakeOpener, OK, TASK, ctx, tree

GUARD = os.path.join(support.BENCH, "agent-desktop-guard")


class RegisterBeforeTheChildCanPost(unittest.TestCase):
    """sol-F1, first-F1, sonnet-F3, second-S4"""

    def test_the_command_does_not_run_until_the_sampler_has_acknowledged_its_group(self):
        with tempfile.TemporaryDirectory() as d:
            marker = os.path.join(d, "ran")
            seen = {}

            def waiter(version, timeout):
                time.sleep(0.2)                        # the child is already spawned, and must still be waiting
                seen["ran_at_ack"] = os.path.exists(marker)
                return True
            reg = PgidRegistry(os.path.join(d, "a.json"), waiter=waiter)
            rc, out, err, ms = Exec(registry=reg)(["/bin/sh", "-c", f"touch {marker}; echo done"])
            self.assertEqual((rc, out.strip()), (0, "done"))
            self.assertFalse(seen["ran_at_ack"])
            self.assertTrue(os.path.exists(marker))

    def test_the_group_is_in_the_allow_file_when_the_gate_opens(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "a.json")
            at_ack = {}
            reg = PgidRegistry(path, waiter=lambda v, t: at_ack.update(data=json.load(open(path))) or True)
            Exec(registry=reg)(["/bin/echo", "x"])
            self.assertEqual(len(at_ack["data"]["pgids"]), 1)
            self.assertEqual(at_ack["data"]["version"], 2)               # the version the waiter was asked about

    def test_a_missed_acknowledgement_never_starts_the_command_and_aborts_the_run(self):
        with tempfile.TemporaryDirectory() as d:
            marker = os.path.join(d, "ran")
            failures = []
            reg = PgidRegistry(os.path.join(d, "a.json"), waiter=lambda v, t: False, ack_timeout=0.05, on_failure=failures.append)
            with self.assertRaises(RegistrationFailed):
                Exec(registry=reg)(["/bin/sh", "-c", f"touch {marker}"])
            time.sleep(0.3)
            self.assertFalse(os.path.exists(marker))        # never continued unregistered
            self.assertEqual(len(failures), 1)

    def test_a_registration_failure_stops_the_whole_run_with_a_clear_reason(self):
        st = harness.RunState(threading.Event(), lambda: 9999)

        def failed(version):
            st.reason.update(kind="registry", version=version)
            st.abort.set()
        reg = PgidRegistry(None, waiter=lambda v, t: False, on_failure=failed)

        def run_task_fn(t, c):
            Exec(registry=reg)(["/bin/echo", "x"])
        c = type("C", (), {"tool": "baneyspaces"})()
        recs, _ = harness.run_group([{"id": "a", "category": "x", "app": "A"}, {"id": "b", "category": "x", "app": "A"}],
                                    {"baneyspaces": c}, st, run_task_fn=run_task_fn)
        self.assertEqual([r["status"] for r in recs["baneyspaces"]], ["infra_error", "not_run"])
        self.assertTrue(st.stop)
        self.assertIn("did not acknowledge", st.stop_reason)

    def test_timing_and_the_timeout_start_at_the_release_not_at_the_spawn(self):
        with tempfile.TemporaryDirectory() as d:
            reg = PgidRegistry(os.path.join(d, "a.json"), waiter=lambda v, t: time.sleep(0.4) or True)
            rc, out, err, ms = Exec(registry=reg)(["/bin/echo", "x"], timeout=0.3)
            self.assertEqual(rc, 0)                 # the 0.4 s wait did not eat the 0.3 s budget
            self.assertLess(ms, 250)                # and is not in the measured time

    def test_a_missing_binary_still_raises_file_not_found_and_stdin_still_works(self):
        with tempfile.TemporaryDirectory() as d:
            reg = PgidRegistry(os.path.join(d, "a.json"))
            ex = Exec(registry=reg)
            with self.assertRaises(FileNotFoundError):
                ex(["/nonexistent/tool"])
            self.assertEqual(ex(["/bin/sh", "-c", "cat; exit 3"], stdin="hello")[:2], (3, "hello"))

    def test_the_child_keeps_its_pid_and_is_its_own_group_leader(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "a.json")
            seen = {}
            reg = PgidRegistry(path, waiter=lambda v, t: seen.update(g=json.load(open(path))["pgids"][0]) or True)
            rc, out, _e, _m = Exec(registry=reg)(["/bin/sh", "-c", "echo $$ $(ps -o pgid= -p $$)"])
            pid, pgid = out.split()
            self.assertEqual((int(pid), int(pgid)), (seen["g"], seen["g"]))

    def test_the_sampler_reloads_by_version_and_recognises_dead_posters(self):
        """first-F2, sol-F4, sonnet-F3"""
        src = open(os.path.join(support.BENCH, "lib", "sampler.swift")).read()
        self.assertIn("v != allowVersion", src)                      # version, not mtime
        self.assertNotIn("allowStamp", src)
        self.assertIn("allowPgids.contains(pid)", src)               # a retired leader that exited: pid == pgid
        self.assertIn("pidGroup", src)                               # pid -> group learned while alive
        self.assertIn("graceUntil", src)
        self.assertIn("postedGraceS = 2.0", src)
        from benchlib import execs
        self.assertEqual(execs.GRACE_S, 2.0)

    def test_user_windows_are_stamped_with_when_they_were_first_seen(self):
        """second-S1"""
        src = open(os.path.join(support.BENCH, "lib", "sampler.swift")).read()
        self.assertIn("seenAt", src)
        self.assertIn('"fields": ["user_window"]', src)
        self.assertIn("min(seenAt[id] ?? now, now)", src)


class CalculatorRestoreFailureStopsCalculatorTasks(unittest.TestCase):
    """sol-F3"""

    def test_after_a_failed_restore_no_later_task_changes_the_domain_and_the_command_is_given(self):
        blocked = {}
        log = []
        after_first = None
        for n, imp in enumerate(((1, "", "boom"), (0, "", ""))):
            ex = defaults_exec(imp=imp, log=log)
            with tempfile.TemporaryDirectory() as d, tempfile.TemporaryDirectory() as rd:
                op = FakeOpener([5])
                c = ctx(d, OK, opener=op)
                c.exec, c.recovery_dir, c.blocked_domains = ex, rd, blocked
                rec = runner.run_task(CALC, c)
                c.server_obj.stop()
                if n == 0:
                    after_first = len(log)
                    self.assertEqual(rec["teardown_pending"]["defaults"], ["com.apple.calculator"])
                    self.assertIn("com.apple.calculator", blocked)
                    self.assertTrue(os.path.exists(os.path.join(rec["teardown_pending"]["recovery"], "com.apple.calculator.plist")))
                else:
                    self.assertEqual(rec["status"], "infra_error")
                    self.assertIn("stop for the rest of the run", rec["why"])
                    self.assertIn("defaults import com.apple.calculator", rec["why"])
                    self.assertEqual(op.opened, [])
        self.assertEqual(len(log), after_first)              # the second task touched `defaults` not at all

    def test_every_invocation_gets_its_own_backup_directory(self):
        dirs = []
        with tempfile.TemporaryDirectory() as rd:
            for _ in range(2):
                with tempfile.TemporaryDirectory() as d:
                    c = ctx(d, OK, imp=None) if False else ctx(d, OK)
                    c.exec, c.recovery_dir = defaults_exec(imp=(1, "", "boom")), rd
                    rec = runner.run_task(CALC, c)
                    c.server_obj.stop()
                    dirs.append(rec["teardown_pending"]["recovery"])
            self.assertNotEqual(dirs[0], dirs[1])
            self.assertTrue(all(os.path.exists(os.path.join(x, "com.apple.calculator.plist")) for x in dirs))

    def test_the_harness_prints_the_recovery_command_and_shares_the_blocked_domains(self):
        src = open(os.path.join(support.BENCH, "harness.py")).read()
        self.assertIn("RECOVERY NEEDED", src)
        self.assertIn("c.blocked_domains = blocked_domains", src)


class StatusPrecedence(unittest.TestCase):
    """sonnet-F1"""

    def run_with(self, doing, lost_after=None, leak=None):
        clk = FakeClock()
        events = [leak] if leak else []
        mon = DelayedMonitor(clk, events)
        if lost_after is not None:
            mon.lost_between = lambda t0, t1, settle=0.0: [{"t": 1, "why": "no beat for 400 ms"}]
        with tempfile.TemporaryDirectory() as d:
            op = FakeOpener([5])
            op.on_open = lambda: clk.sleep(0.3)
            c = ctx(d, doing, monitor=mon, clock=clk.now, sleep=clk.sleep, drain_s=1.5, opener=op)
            try:
                return runner.run_task(TASK, c)
            finally:
                c.server_obj.stop()

    def test_a_monitor_lost_in_the_late_pass_wins_over_an_earlier_status_and_both_are_kept(self):
        for doing, earlier in ((lambda *a: {"ok": True, "log": [], "shortcut": "a shell command"}, "fail"),
                               (lambda *a: {"ok": False, "log": [], "infra": "cua_repl did not start"}, "infra_error"),
                               (OK, "pass")):
            rec = self.run_with(doing, lost_after=1)
            self.assertEqual(rec["status"], "monitor_lost", earlier)
            if earlier != "pass":
                self.assertEqual(rec["earlier_status"], earlier)

    def test_a_setup_leak_found_only_late_downgrades_a_scored_shortcut_fail_too(self):
        rec = self.run_with(lambda *a: {"ok": True, "log": [], "shortcut": "a shell command"}, leak=LEAK(100.2, 101.9))
        self.assertEqual(rec["status"], "infra_error")
        self.assertEqual(rec["earlier_status"], "fail")
        self.assertTrue(rec["setup_leak"])


class GateReadsTheWholeDrain(unittest.TestCase):
    """second-S1"""

    def test_a_window_stamped_inside_the_drain_and_reported_before_it_ends_stops_the_tool(self):
        clk = FakeClock()
        mon = DelayedMonitor(clk, [(100.5, 101.0, ["user_window"], WIN)])     # inside [q, q+drain), reported by q_end
        called = []
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, lambda *a: called.append(1), monitor=mon, clock=clk.now, sleep=clk.sleep, drain_s=1.5)
            rec = runner.run_task(TASK, c)
            c.server_obj.stop()
        self.assertEqual(called, [])
        self.assertEqual(rec["status"], "infra_error")
        self.assertTrue(rec["setup_leak"])

    def test_the_tool_starts_where_the_gate_stopped_reading(self):
        clk = FakeClock()
        mon = DelayedMonitor(clk, [])
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, OK, monitor=mon, clock=clk.now, sleep=clk.sleep, drain_s=1.5)
            runner.run_task(TASK, c)
            c.server_obj.stop()
        gate, setup = mon.queries[0], mon.queries[1]
        self.assertEqual(gate[1], setup[1])          # the gate's upper bound is the late pass's t0


class InstancesByPid(unittest.TestCase):
    """sol-F2, second-S2, second-S3"""

    TWO = dict(TASK, setup=dict(TASK["setup"], open=[{"app": "TextEdit", "as": "left", "targets": ["{tmp}/a.txt"]},
                                                      {"app": "TextEdit", "as": "right", "targets": ["{tmp}/a.txt"]}]))

    def run_two(self, per_pid_windows, alive=None, enum=None):
        op = FakeOpener([5, 6])
        op.pids = {5: 777, 6: 778}
        killed = []
        alive = alive if alive is not None else {777: True, 778: True}

        def qex(argv, **k):
            if argv[:2] == ["kill", "-TERM"]:
                killed.append(int(argv[2]))
                alive[int(argv[2])] = False
            return 0, "", "", 1
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, OK, opener=op, closes=False)
            ref = c.ref
            orig = ref.run

            def run(verb, timeout=60, **k):
                if verb == "click":
                    ref.trees.clear()
                    op.closed |= {5, 6}
                return orig(verb, timeout, **k)
            ref.run = run
            ref.trees[(6, None)] = tree("a.txt", "x")
            ref.pid_windows = lambda app, pid: per_pid_windows(pid)
            c.quiet_exec, c.alive_fn = qex, lambda pid: alive.get(pid, False)
            rec = runner.run_task(self.TWO, c)
            c.server_obj.stop()
        return rec, killed

    def test_both_instances_are_quit_independently(self):
        rec, killed = self.run_two(lambda pid: (True, []))
        self.assertEqual(sorted(killed), [777, 778])
        self.assertNotIn("teardown_pending", rec)

    def test_one_instance_with_a_foreign_window_is_held_and_the_other_is_still_quit(self):
        rec, killed = self.run_two(lambda pid: (True, ["w-9"]) if pid == 777 else (True, []))
        self.assertEqual(killed, [778])
        self.assertEqual(rec["teardown_pending"]["pids"], [777])

    def test_an_instance_that_already_exited_is_neither_enumerated_nor_killed_and_the_rest_go_on(self):
        """Calculator quits with its last window"""
        asked = []

        def enum(pid):
            asked.append(pid)
            return (True, [])
        rec, killed = self.run_two(enum, alive={777: False, 778: True})
        self.assertEqual(asked, [778])
        self.assertEqual(killed, [778])
        self.assertNotIn("teardown_pending", rec)

    def test_a_calculator_that_quit_with_its_window_still_gets_its_preferences_restored(self):
        op = FakeOpener([5])
        op.pids = {5: 777}
        ex = defaults_exec()
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, OK, opener=op)
            c.exec = ex
            c.alive_fn = lambda pid: False                      # the instance went with its last window
            c.ref.pid_windows = lambda app, pid: (_ for _ in ()).throw(AssertionError("must not enumerate a dead pid"))
            t = dict(CALC, setup=dict(CALC["setup"], quit_after=["TextEdit"]))
            rec = runner.run_task(t, c)
            c.server_obj.stop()
        self.assertTrue(any(a[0][:2] == ["defaults", "import"] for a in ex.log))
        self.assertNotIn("teardown_pending", rec)

    def test_list_windows_for_an_app_that_is_not_running_is_an_empty_list_not_cannot_tell(self):
        d = AgentDesktopDriver(None, "/ad")
        d.run = lambda verb, **k: Result(False, None, {"code": "app_not_found", "message": "m", "suggestion": ""}, 1)
        self.assertEqual(d.pid_windows("Calculator", 5), (True, []))
        d.run = lambda verb, **k: Result(False, None, {"code": "timeout", "message": "m", "suggestion": ""}, 1)
        self.assertEqual(d.pid_windows("Calculator", 5), (False, []))
        d.run = lambda verb, **k: Result(True, [{"id": "w-1", "pid": 5}, {"id": "w-2", "pid": 6}], None, 1)
        self.assertEqual(d.pid_windows("Calculator", 5), (True, ["w-1"]))
        self.assertEqual(d.build("list-windows", app="Calculator"), ["/ad", "list-windows", "--app", "Calculator"])


class GuardParsesTheArgv(unittest.TestCase):
    """sonnet-F2"""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.gf = os.path.join(self.d, "g.json")
        json.dump({"windows": ["w-10"], "snapshots": ["sABC"]}, open(self.gf, "w"))
        real = os.path.join(self.d, "real")
        open(real, "w").write('#!/bin/sh\necho \'{"ok": true, "data": {}}\'\n')
        os.chmod(real, 0o755)
        self.env = dict(os.environ, BENCH_AD_BIN=real, BENCH_GUARD_FILE=self.gf)

    def rc(self, *args):
        return subprocess.run([sys.executable, GUARD, *args], capture_output=True, text=True, env=self.env, timeout=30).returncode

    def test_wait_needs_a_real_element_flag_or_a_number(self):
        self.assertEqual(self.rc("wait", "--timeout", "5"), 2)                      # neither
        self.assertEqual(self.rc("wait", "--predicate", "--element"), 2)            # the text is a flag's VALUE, not the flag
        self.assertEqual(self.rc("wait", "--", "--element"), 2)                     # the text is a positional
        self.assertEqual(self.rc("wait", "--value", "--element", "--timeout", "5"), 2)
        self.assertEqual(self.rc("wait", "--element", "@sABC:e2", "--timeout", "5"), 0)
        self.assertEqual(self.rc("wait", "300"), 0)


class StillSayWhatIsDeferred(unittest.TestCase):
    def test_the_followup_list_is_in_the_readme(self):
        text = open(os.path.join(support.BENCH, "README.md")).read()
        for needle in ("Known follow-ups", "RLock", "latest.md", "supervised first run"):
            self.assertIn(needle, text)


if __name__ == "__main__":
    unittest.main()
