import contextlib
import io
import os
import unittest

import support  # noqa: F401
import harness


class Plan(unittest.TestCase):
    def test_all_covers_every_applicable_pair(self):
        plan = harness.plan_for("all", "all")
        self.assertIn(("scripted", "baneyspaces"), plan)
        self.assertIn(("scripted", "agent-desktop-headed"), plan)
        self.assertIn(("agent", "chatgpt"), plan)
        self.assertIn(("micro", "chatgpt"), plan)
        self.assertNotIn(("scripted", "chatgpt"), plan)

    def test_one_tool(self):
        self.assertEqual({t for _, t in harness.plan_for("chatgpt", "all")}, {"chatgpt"})
        self.assertEqual(harness.plan_for("baneyspaces", "micro"), [("micro", "baneyspaces")])


class DryRun(unittest.TestCase):
    def run_dry(self, *argv, env=None):
        buf = io.StringIO()
        old = dict(os.environ)
        os.environ.update(env or {})
        try:
            with contextlib.redirect_stdout(buf):
                rc = harness.main(["--dry-run", *argv])
        finally:
            os.environ.clear()
            os.environ.update(old)
        return rc, buf.getvalue()

    def test_lists_thirty_tasks(self):
        rc, out = self.run_dry("--tool", "baneyspaces", "--level", "scripted", env={"BENCH_BANEYSPACES": "/bin/echo", "BENCH_AGENT_DESKTOP": "/bin/echo"})
        self.assertEqual(rc, 0)
        self.assertIn("30 tasks", out)
        self.assertEqual(sum(1 for line in out.splitlines() if line.startswith("  ") and line.split()[0] in
                             {"textedit-type", "calculator-add", "refuse-stale-ref", "safari-form"}), 4)

    def test_a_missing_runner_is_reported_and_fails(self):
        rc, out = self.run_dry("--tool", "agent-desktop", "--level", "scripted", env={"BENCH_AGENT_DESKTOP": "/nonexistent"})
        self.assertEqual(rc, 1)
        self.assertIn("MISSING", out)

    def test_sandbox_tasks_are_labelled(self):
        rc, out = self.run_dry("--tool", "baneyspaces", "--level", "scripted", env={"BENCH_BANEYSPACES": "/bin/echo", "BENCH_AGENT_DESKTOP": "/bin/echo"})
        self.assertEqual(sum(1 for line in out.splitlines() if "[sandbox]" in line), 5)

    def test_expected_failures_are_listed_not_skipped(self):
        rc, out = self.run_dry("--tool", "baneyspaces", "--level", "scripted", env={"BENCH_BANEYSPACES": "/bin/echo", "BENCH_AGENT_DESKTOP": "/bin/echo"})
        self.assertIn("baneyspaces:expected-fail", out)

    def test_only_filters_and_rejects_unknown(self):
        rc, out = self.run_dry("--tool", "baneyspaces", "--level", "scripted", "--only", "textedit-type",
                               env={"BENCH_BANEYSPACES": "/bin/echo", "BENCH_AGENT_DESKTOP": "/bin/echo"})
        self.assertIn("1 tasks", out)
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            self.assertEqual(harness.main(["--dry-run", "--only", "nope"]), 2)


class FakeCtx:
    pass


def mk_tasks(n=3):
    return [{"id": f"t{i}", "category": "x", "app": "A"} for i in range(n)]


def state(idle=700, sess=(True, {}), tap=True):
    import threading
    box = {"idle": idle, "sess": sess}
    st = harness.RunState(threading.Event(), lambda: box["idle"], lambda: box["sess"], tap)
    st.box = box
    return st


class RunGroup(unittest.TestCase):
    def run_it(self, st, tools=("baneyspaces", "agent-desktop"), task_fn=None, n=3):
        order = []

        def fake(t, ctx):
            order.append((t["id"], ctx.tool))
            if task_fn:
                r = task_fn(t, ctx)
                if r is not None:
                    return r
            return {"id": t["id"], "status": "pass"}
        ctxs = {}
        for tool in tools:
            c = FakeCtx()
            c.tool = tool
            ctxs[tool] = c
        recs, dead = harness.run_group(mk_tasks(n), ctxs, st, run_task_fn=fake)
        return recs, dead, order

    def test_everything_runs_while_the_mac_stays_idle_and_tools_take_turns(self):
        recs, dead, order = self.run_it(state())
        self.assertEqual(len(order), 6)
        self.assertEqual([o[1] for o in order[:4]], ["baneyspaces", "agent-desktop", "agent-desktop", "baneyspaces"])
        self.assertEqual(dead, {})

    def test_tools_that_post_input_always_go_last(self):
        self.assertEqual(harness.tool_order(["chatgpt", "baneyspaces", "agent-desktop-headed", "agent-desktop"], 0),
                         ["baneyspaces", "agent-desktop", "chatgpt", "agent-desktop-headed"])

    def test_the_full_ten_minutes_of_real_idle_are_required_before_every_task(self):
        """sol-F5, second-S8: 5 to 599 s no longer passes."""
        for idle in (4.9, 5.0, 120, 599):
            recs, _, order = self.run_it(state(idle=idle))
            self.assertEqual(order, [], idle)
            self.assertEqual({r["status"] for rs in recs.values() for r in rs}, {"not_run"})
        recs, _, order = self.run_it(state(idle=600))
        self.assertEqual(len(order), 6)

    def test_idle_dropping_mid_run_stops_before_the_next_task(self):
        st = state()

        def drop(t, ctx):
            st.box["idle"] = 3.0
        recs, _, order = self.run_it(st, task_fn=drop)
        self.assertEqual(len(order), 1)
        self.assertTrue(st.stop)
        self.assertIn("real input", st.stop_reason)

    def test_a_locked_screen_or_sleeping_display_stops_the_run(self):
        st = state()

        def lock(t, ctx):
            st.box["sess"] = (False, {"locked": True})
        _, _, order = self.run_it(st, task_fn=lock)
        self.assertEqual(len(order), 1)
        self.assertIn("locked", st.stop_reason)

    def test_real_input_during_a_task_stops_everything_even_for_a_tool_that_posts_input(self):
        def real(t, ctx):
            st.reason.update(kind="input", idle=0.0)
            st.abort.set()
        st = state()
        recs, dead, order = self.run_it(st, tools=("baneyspaces", "chatgpt"), task_fn=real)
        self.assertEqual(len(order), 1)
        self.assertTrue(st.stop)

    def test_a_tool_that_posts_input_is_not_stopped_by_its_own_input(self):
        """first-F3: synthetic events are filtered by the tap, so they never reach the abort."""
        recs, dead, order = self.run_it(state(), tools=("agent-desktop-headed", "baneyspaces"))
        self.assertEqual([r["status"] for r in recs["agent-desktop-headed"]], ["pass"] * 3)

    def test_without_the_tap_tools_that_post_input_are_skipped_as_unavailable(self):
        recs, _, order = self.run_it(state(tap=False), tools=("baneyspaces", "agent-desktop-headed"))
        self.assertEqual({r["status"] for r in recs["agent-desktop-headed"]}, {"unavailable"})
        self.assertEqual([r["status"] for r in recs["baneyspaces"]], ["pass"] * 3)
        self.assertNotIn("agent-desktop-headed", [o[1] for o in order])

    def test_a_lost_monitor_stops_everything(self):
        def lost(t, ctx):
            st.reason.update(kind="lost", why="no beat for 300 ms")
            st.abort.set()
        st = state()
        _, _, order = self.run_it(st, tools=("chatgpt",), task_fn=lost)
        self.assertEqual(len(order), 1)
        self.assertIn("monitor was lost", st.stop_reason)

    def test_any_exception_in_a_task_is_recorded_and_the_run_goes_on(self):
        def boom(t, ctx):
            if t["id"] == "t1":
                raise KeyError("bad task file")
        recs, dead, order = self.run_it(state(), tools=("baneyspaces",), task_fn=boom)
        self.assertEqual([r["status"] for r in recs["baneyspaces"]], ["pass", "infra_error", "pass"])
        self.assertIn("KeyError", recs["baneyspaces"][1]["why"])

    def test_a_fatal_infra_error_stops_that_column_only(self):
        def fatal(t, ctx):
            if ctx.tool == "chatgpt":
                return {"id": t["id"], "status": "infra_error", "why": "cua_repl did not start", "fatal_infra": True}
        recs, dead, _ = self.run_it(state(), tools=("baneyspaces", "chatgpt"), task_fn=fatal)
        self.assertEqual([r["status"] for r in recs["chatgpt"]], ["infra_error", "not_run", "not_run"])
        self.assertEqual([r["status"] for r in recs["baneyspaces"]], ["pass"] * 3)
        self.assertIn("cua_repl", dead["chatgpt"])


class NoBypass(unittest.TestCase):
    def test_no_flag_or_variable_lowers_the_idle_requirement(self):
        import re
        for name in ("harness.py", "run.sh", "README.md"):
            text = open(os.path.join(support.BENCH, name)).read()
            self.assertNotIn("--idle-required", text)
            self.assertNotIn("--tolerate-own-input", text)
        self.assertNotIn("BENCH_IDLE_REQUIRED", open(os.path.join(support.BENCH, "run.sh")).read())
        self.assertEqual(harness.host.IDLE_REQUIRED_S, 600)
        self.assertEqual(harness.monitor.HID_ABORT_IDLE_S, 5.0)
        self.assertNotIn("-u", harness.host.CAFFEINATE)      # -u declares user activity and would reset the idle clock
        self.assertEqual(harness.host.CAFFEINATE, ["caffeinate", "-dims"])


class Awake(unittest.TestCase):
    def test_hold_awake_is_capped_by_a_budget(self):
        """first-F6"""
        got = {}
        harness.host.hold_awake(900, popen=lambda argv, **kw: got.update(argv=argv) or "proc")
        self.assertEqual(got["argv"], ["caffeinate", "-dims", "-t", "900"])
        self.assertNotIn("-u", got["argv"])

    def test_the_level_budget_is_bounded_and_scales_with_the_work(self):
        self.assertLessEqual(harness.level_budget_s("agent", 30, 3), 6 * 3600)
        self.assertGreater(harness.level_budget_s("agent", 30, 2), harness.level_budget_s("scripted", 30, 2))
        self.assertGreater(harness.level_budget_s("scripted", 30, 1), 900)

    def test_the_run_stops_when_the_budget_ends(self):
        import threading
        st = harness.RunState(threading.Event(), lambda: 9999)
        self.assertIsNone(st.gate())
        st.deadline = harness.time.monotonic() - 1
        self.assertIn("time budget", st.gate())

    def test_caffeinate_is_released_between_levels(self):
        src = open(os.path.join(support.BENCH, "harness.py")).read()
        self.assertIn("awake = host.hold_awake(budget)", src)
        self.assertIn("awake.terminate()", src)

    def test_session_gate_messages(self):
        from benchlib import host
        self.assertTrue(host.session_gate(True, {})[0])
        ok, msg = host.session_gate(False, {"locked": True, "asleep": True})
        self.assertFalse(ok)
        self.assertIn("locked", msg)
        self.assertIn("asleep", msg)
        self.assertIn("not run", msg)

    def test_plist_value_treats_a_missing_key_as_absent(self):
        """second-S10"""
        calls = []

        def ex(argv, timeout=10):
            calls.append(argv)
            return 1, "", "No value at that key path or invalid key path: BSGitCommit", 3
        self.assertIsNone(harness.plist_value(ex, "/Applications/X.app", "BSGitCommit"))
        self.assertEqual(calls[0][:3], ["plutil", "-extract", "BSGitCommit"])
        self.assertEqual(harness.plist_value(lambda a, timeout=10: (0, "abc123\n", "", 1), "/A.app", "K"), "abc123")


class Gate(unittest.TestCase):
    def test_a_real_run_with_an_active_user_does_nothing(self):
        from benchlib import host
        old = host.hid_idle_seconds
        host.hid_idle_seconds = lambda *a, **k: 3.0
        os.environ["BENCH_BANEYSPACES"] = "/bin/echo"
        os.environ["BENCH_AGENT_DESKTOP"] = "/bin/echo"
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                rc = harness.main(["--tool", "baneyspaces", "--level", "scripted"])
        finally:
            host.hid_idle_seconds = old
            del os.environ["BENCH_BANEYSPACES"], os.environ["BENCH_AGENT_DESKTOP"]
        self.assertEqual(rc, harness.EXIT_USER_ACTIVE)
        self.assertIn("not run: user active", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
