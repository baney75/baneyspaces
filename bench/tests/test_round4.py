import json
import os
import re
import tempfile
import threading
import unittest

import support
import harness
from support import FakeDriver, fake_exec, node
from benchlib import cleanup, fixtures, host, runner, tasks
from benchlib.drivers import Opener, Result
from benchlib.execs import Exec, PgidRegistry
from test_runner import FakeMonitor, FakeOpener, OK, TASK, ctx, tree

TASKS = tasks.load_tasks(os.path.join(support.BENCH, "tasks"))
STATE = {"agentWorkspace": 9, "workspaces": {"9": []}}


class FakeClock:
    def __init__(self):
        self.t = 100.0

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s


class DelayedMonitor:
    """Events carry the time they were FIRST SEEN (stamp) but are only delivered later (arrive), like the sampler's
    debounced unplaced_window. changes() returns what has arrived by the fake clock's now."""
    def __init__(self, clock, events=()):
        self.clock, self.events = clock, list(events)      # (stamp, arrive, fields, windows)
        self.losses = []

    def changes(self, t0, t1, settle=0.0):
        return [{"t": st - t0, "fields": f, "windows": w} for st, arr, f, w in self.events
                if arr <= self.clock.now() and t0 <= st < t1 + settle]

    def input(self, *a, **k):
        return 0, 0, {}

    def lost_between(self, *a, **k):
        return []

    def healthy(self):
        return True, ""

    def user_pids_now(self):
        return frozenset()


WIN = [{"id": 9, "pid": 5, "owner": "TextEdit"}]


class Drains(unittest.TestCase):
    """first-F3, second-S8"""

    def run_with(self, events_fn, doing=None, **kw):
        clk = FakeClock()
        mon = DelayedMonitor(clk, events_fn(clk))
        with tempfile.TemporaryDirectory() as d:
            def doing_(t, w, ti):
                clk.t += 0.5
                return {"ok": True, "log": []}
            c = ctx(d, doing or doing_, monitor=mon, clock=clk.now, sleep=clk.sleep, drain_s=1.5, **kw)
            try:
                return runner.run_task(TASK, c)
            finally:
                c.server_obj.stop()

    def test_a_window_shown_a_third_of_a_second_after_the_last_action_is_counted_in_the_task(self):
        # the sampler first sees it at t1+0.3 and reports it at t1+1.3; t1 is the task's end
        def events(clk):
            return [(100.0 + 0.8 + 0.8 + 0.3, 100.0 + 0.8 + 0.8 + 1.3, ["unplaced_window"], WIN)]
        rec = self.run_with(events)
        self.assertEqual(len(rec["changes"]), 1, rec)
        self.assertEqual(rec.get("teardown_changes", []), [])

    def test_a_window_a_teardown_action_raises_is_counted_in_teardown(self):
        def events(clk):
            return [(100.0 + 0.8 + 0.8 + 0.5 + 1.5 + 0.2, 100.0 + 0.8 + 0.8 + 0.5 + 1.5 + 1.2, ["unplaced_window"], WIN)]
        rec = self.run_with(events)
        self.assertEqual(len(rec["teardown_changes"]), 1, rec)

    def test_a_leak_on_an_early_return_path_is_not_lost(self):
        t = dict(TASK, setup=dict(TASK["setup"], profile="user-data-dir"))
        clk = FakeClock()
        mon = DelayedMonitor(clk, [(100.1, 101.1, ["unplaced_window"], WIN)])
        op = FakeOpener([5])
        op.verified = False
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, OK, monitor=mon, clock=clk.now, sleep=clk.sleep, drain_s=1.5, opener=op)
            rec = runner.run_task(t, c)
            c.server_obj.stop()
        self.assertEqual(rec["status"], "infra_error")
        self.assertEqual(len(rec["setup_changes"]), 1)

    def test_every_query_is_preceded_by_a_drain(self):
        src = open(os.path.join(support.BENCH, "benchlib", "runner.py")).read()
        self.assertIn("ctx.sleep(ctx.drain_s)", src)
        self.assertEqual(src.count("drained("), src.count("drained(") )     # early returns all go through drained()
        self.assertNotIn("ctx.settle_s", src)


class MicroUsesTheRunnersSetup(unittest.TestCase):
    """first-F1, sol-F1"""

    def micro_ctx(self, d, monitor, doing, opener=None, tool="agent-desktop"):
        op = opener or FakeOpener([5, 6])
        ref = FakeDriver({(5, None): tree("micro.txt", ""), (6, None): tree("Calculator", "0")})
        return runner.Context(tool=tool, workdir=d, server=type("S", (), {"base": "b", "port": 1, "reset": lambda s: None})(),
                              monitor=monitor, opener=op, referee_driver=ref, exec_fn=fake_exec([]), doing=doing,
                              state_fn=lambda: STATE, availability_fn=lambda t, s, tool=None: None,
                              running_fn=lambda a: False, sleep=lambda s: None, watch_dirs=(), drain_s=0)

    def test_a_window_that_leaked_during_setup_invalidates_the_measurement_and_no_action_is_sent(self):
        called = []

        class Leaky(FakeMonitor):
            def changes(self, t0, t1, settle=0.0):
                self.calls.append((t0, t1, settle))
                return [{"t": 1, "fields": ["unplaced_window"], "windows": [{"id": 77, "pid": 5, "owner": "Calculator"}]}] if len(self.calls) == 1 else []
        with tempfile.TemporaryDirectory() as d:
            c = self.micro_ctx(d, Leaky(), lambda *a: called.append(1))
            got = harness.run_micro_level("agent-desktop", c)
        self.assertEqual(got["status"], "invalid")
        self.assertEqual(called, [])
        self.assertTrue(got["setup_leak"])
        self.assertTrue(got["setup_changes"])

    def test_a_micro_window_that_is_not_on_the_agent_workspace_is_n_a(self):
        called = []
        with tempfile.TemporaryDirectory() as d:
            c = self.micro_ctx(d, FakeMonitor(), lambda *a: called.append(1), opener=FakeOpener([5, 6], listing=[5]))
            got = harness.run_micro_level("agent-desktop", c)
        self.assertEqual(got["status"], "n/a")
        self.assertIn("not on the agent workspace", got["why"])
        self.assertEqual(called, [])

    def test_a_clean_run_returns_the_measurement_and_records_all_three_windows_of_changes(self):
        ok = lambda t, w, ti: {"ok": True, "log": [], "micro": {"status": "ok", "latency": {"snapshot": {"n": 20}}, "errors": [], "problems": []}}
        with tempfile.TemporaryDirectory() as d:
            c = self.micro_ctx(d, FakeMonitor(setup=0, changes=0, teardown=0), ok)
            got = harness.run_micro_level("agent-desktop", c)
        self.assertEqual(got["status"], "ok")
        for k in ("setup_changes", "changes", "teardown_changes"):
            self.assertIn(k, got)

    def test_screen_changes_during_the_measured_actions_make_it_invalid(self):
        ok = lambda t, w, ti: {"ok": True, "log": [], "micro": {"status": "ok", "latency": {}, "errors": [], "problems": []}}
        with tempfile.TemporaryDirectory() as d:
            c = self.micro_ctx(d, FakeMonitor(changes=2), ok)
            got = harness.run_micro_level("agent-desktop", c)
        self.assertEqual(got["status"], "invalid")

    def test_the_micro_pseudo_task_uses_the_same_gates_as_a_task(self):
        t = host.micro_task("baneyspaces")
        self.assertEqual(t["setup"]["requires"]["exclusive"], ["TextEdit"])
        self.assertEqual(t["setup"]["requires"]["not_running"], ["Calculator"])
        self.assertIn("com.apple.calculator", t["setup"]["restore_defaults"])
        self.assertIn("Access", "Access")


class Teardown(unittest.TestCase):
    def test_a_close_that_fails_on_a_timeout_is_not_reported_as_closed(self):
        """second-S6"""
        class Flaky(FakeDriver):
            def snapshot(self, wid, surface=None):
                return Result(False, None, {"code": "timeout", "message": "t", "suggestion": "", "retry": None}, 5)
        closed, left = cleanup.close_windows(Flaky({}), [7], lambda: {7: ("TextEdit", "t")}, rounds=1)
        self.assertEqual(closed, [])
        self.assertIn("cannot tell", left[7])
        closed, left = cleanup.close_windows(Flaky({}), [7], lambda: {})
        self.assertIn("cannot tell", left[7])

    def test_only_not_found_counts_as_gone(self):
        for code, gone in (("window_not_found", True), ("app_not_found", True), ("timeout", False), ("no_envelope", False),
                           ("permission_denied", False)):
            self.assertEqual(cleanup.is_gone(Result(False, None, {"code": code}, 1)), gone, code)
        self.assertFalse(cleanup.is_gone(Result(True, {}, None, 1)))

    def test_the_missing_window_task_is_not_run_against_a_window_that_could_not_be_closed(self):
        """second-S4"""
        t = dict(TASK, setup=dict(TASK["setup"], close_before_run=["doc"]))
        called = []
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, lambda *a: called.append(1), closes=False)
            rec = runner.run_task(t, c)
            c.server_obj.stop()
        self.assertEqual(rec["status"], "infra_error")
        self.assertIn("could not close", rec["why"])
        self.assertEqual(called, [])
        self.assertEqual(rec["teardown_pending"]["windows"], [5])      # still tracked, so teardown reports it


class DefaultsRestore(unittest.TestCase):
    """second-S9"""

    def run_calc(self, export):
        t = dict(TASK, setup=dict(TASK["setup"], restore_defaults=["com.apple.calculator"]))
        seen = []

        def ex(argv, timeout=60, env=None, stdin=None, cwd=None):
            seen.append((argv, stdin))
            if argv[:2] == ["defaults", "export"]:
                return export
            return 0, "", "", 1
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, OK)
            c.exec = ex
            runner.run_task(t, c)
            c.server_obj.stop()
        return seen

    def test_the_domain_is_exported_before_and_imported_after(self):
        seen = self.run_calc((0, "<plist>BASIC</plist>", "", 1))
        verbs = [a[0][:2] for a in seen]
        self.assertLess(verbs.index(["defaults", "export"]), verbs.index(["defaults", "import"]))
        imp = next(a for a in seen if a[0][:2] == ["defaults", "import"])
        self.assertEqual(imp[1], "<plist>BASIC</plist>")

    def test_a_domain_that_did_not_exist_is_deleted_afterwards(self):
        seen = self.run_calc((1, "", "Domain com.apple.calculator does not exist", 1))
        self.assertTrue(any(a[0][:2] == ["defaults", "delete"] for a in seen))

    def test_every_calculator_task_restores_the_view(self):
        for t in TASKS:
            if t["app"] == "Calculator":
                self.assertEqual(t["setup"]["restore_defaults"], ["com.apple.calculator"], t["id"])


class Opening(unittest.TestCase):
    def opener(self, windows_seq, open_out):
        calls = {"n": 0}

        def run(argv, timeout=60, **kw):
            if argv[2:] == ["status"]:
                i = min(calls["n"], len(windows_seq) - 1)
                calls["n"] += 1
                body = "agent workspace: 9\n" + "".join(f"  {w}\t{a}\t{t}\n" for w, a, t in windows_seq[i])
                return 0, body, "", 1
            return 0, open_out, "", 1
        return Opener(run)

    def test_a_new_window_of_another_app_is_not_taken_for_ours(self):
        """first-F5"""
        o = self.opener([[], [(50, "Preview", "x.pdf")]] + [[(50, "Preview", "x.pdf")]] * 60, "app: TextEdit\nworkspace: 9\n")
        self.assertIsNone(o.open("TextEdit", ["/x"])[0])

    def test_the_window_of_the_app_we_opened_is_picked(self):
        o = self.opener([[], [(50, "Preview", "x.pdf"), (51, "TextEdit", "a.txt")]] * 5, "app: TextEdit\nworkspace: 9\n")
        self.assertEqual(o.open("TextEdit", ["/x"])[0], 51)

    def test_two_candidate_windows_are_not_guessed_between(self):
        o = self.opener([[], [(51, "TextEdit", "a"), (52, "TextEdit", "b")]] * 5, "app: TextEdit\nworkspace: 9\n")
        self.assertIsNone(o.open("TextEdit", ["/x"])[0])


class Placement(unittest.TestCase):
    def test_system_settings_is_once_per_user_so_its_tasks_are_sandbox(self):
        """second-S2"""
        self.assertIn("System Settings", tasks.ONCE_PER_USER)
        for t in TASKS:
            if t["app"] == "System Settings":
                self.assertEqual(t["place"], "sandbox", t["id"])
        bad = {"id": "x", "app": "System Settings", "category": "settings", "goal": "g", "check": {"kind": "nothing"},
               "setup": {"requires": {"exclusive": ["System Settings"]}, "open": [{"app": "System Settings", "as": "w"}]},
               "steps": [{"do": "wait"}]}
        self.assertRaises(tasks.TaskError, tasks.validate, bad)

    def test_the_host_open_list_mirrors_what_baneyspaces_ships(self):
        src = os.path.join(support.BENCH, "..", "Sources", "BaneySpacesCore", "Hands", "Policies.swift")
        if not os.path.exists(src):
            self.skipTest("BaneySpaces sources are not next to the bench")
        m = re.search(r"separateInstance: Set<String> = \[(.*?)\]", open(src).read())
        bundles = set(re.findall(r'"([^"]+)"', m.group(1)))
        self.assertEqual(bundles, set(host.AGENT_OPEN_HOST_APPS.values()))

    def test_a_host_task_on_an_app_agent_open_refuses_is_unavailable(self):
        finder = next(t for t in TASKS if t["app"] == "Finder")
        why = host.availability(finder, STATE, "baneyspaces", installed_fn=lambda a: True, running_fn=lambda a: False)
        self.assertIn("needs sandbox", why)
        self.assertIn("Finder", why)

    def test_fixtures_live_in_the_handoff_folder(self):
        src = open(os.path.join(support.BENCH, "harness.py")).read()
        self.assertIn("tempfile.mkdtemp(prefix=\"bench-run-\", dir=host.HANDOFF)", src)
        self.assertTrue(host.HANDOFF.endswith("BaneySpaces/hands/handoff"))


class Registry(unittest.TestCase):
    """first-F2: the sampler learns which process groups are the column's own"""

    def test_a_running_command_is_in_the_registry_file_and_leaves_it_after(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "allow.json")
            reg = PgidRegistry(path)
            ex = Exec(registry=reg)
            seen = {}

            def peek():
                import time
                for _ in range(60):
                    data = json.load(open(path))
                    if data["pgids"]:
                        seen.update(data)
                        return
                    time.sleep(0.02)
            th = threading.Thread(target=peek)
            th.start()
            ex(["/bin/sleep", "0.6"])
            th.join()
            self.assertTrue(seen["pgids"])
            self.assertEqual(json.load(open(path))["pgids"], [])
            self.assertEqual(json.load(open(path))["pids"], [os.getpid()])

    def test_the_sampler_treats_any_other_poster_as_real_input(self):
        src = open(os.path.join(support.BENCH, "lib", "sampler.swift")).read()
        self.assertIn("pid == 0 || !ownPoster(pid)", src)


if __name__ == "__main__":
    unittest.main()
