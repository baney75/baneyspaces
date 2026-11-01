import os
import tempfile
import threading
import time
import unittest

import support
from support import FakeDriver, fake_exec, node
from benchlib import fixtures, runner
from benchlib.execs import Aborted, Exec


class FakeMonitor:
    """changes(t0, t1, settle) answers by call order: the early gate, then the late pass (setup, task, teardown)."""
    SEQ = ("gate", "setup", "task", "teardown")

    def __init__(self, changes=0, hid=0, setup=0, teardown=0, lost=None, healthy=True, posted=0, windows=None, ambient_pids=()):
        self.c, self.h, self.s, self.td, self._lost, self._healthy, self.posted = changes, hid, setup, teardown, lost or [], healthy, posted
        self.calls = []
        self.losses = []
        self.windows = windows
        self.ambient_pids = frozenset(ambient_pids)

    def user_pids_now(self):
        return self.ambient_pids

    def kind_of(self, n):
        return self.SEQ[min(n, len(self.SEQ) - 1)]

    def changes(self, t0, t1, settle=0.0):
        self.calls.append((t0, t1, settle))
        kind = self.kind_of(len(self.calls) - 1)
        n = {"gate": self.s, "setup": self.s, "task": self.c, "teardown": self.td}[kind]
        out = [{"t": 0.1, "fields": ["front"]}] * n
        if self.windows and kind == "task":
            out = out + [{"t": 0.2, "fields": ["user_window"], "windows": self.windows}]
        return out

    def input(self, t0, t1, settle=0.0):
        return self.h, self.posted, ({"4242": self.posted} if self.posted else {})

    def lost_between(self, t0, t1, settle=0.0):
        return self._lost

    def healthy(self):
        return self._healthy, "" if self._healthy else "sampler exited"


class FakeOpener:
    def __init__(self, ids, listing=None):
        self.ids = list(ids)
        self.opened = []
        self.listing = listing
        self.apps = {}
        self.given = []
        self.closed = set()
        self.on_open = None

    profile_ok = True
    verified = True
    pids = {}

    def pid_of(self, wid):
        return self.pids.get(wid)

    def open(self, app, targets=()):
        self.opened.append((app, list(targets)))
        if self.on_open:
            self.on_open()
        wid = self.ids.pop(0) if self.ids else None
        if wid is not None:
            self.given.append(wid)
            self.apps[wid] = app
        return wid, 5

    def supports_profile(self):
        return self.profile_ok

    def open_isolated(self, app, targets, profile_dir):
        self.opened.append((app, list(targets), profile_dir))
        if self.on_open:
            self.on_open()
        wid = self.ids.pop(0) if self.ids else None
        if wid is not None:
            self.given.append(wid)
            self.apps[wid] = app
        return wid, 5, self.verified

    def windows(self):
        ids = self.listing if self.listing is not None else [w for w in self.given if w not in self.closed]
        return {w: (self.apps.get(w, "TextEdit"), "t") for w in ids}


def tree(title, text):
    return node("window", title, children=[node("textfield", value=text, ref="@s:e1"), node("button", "Close", ref="@s:e2")])


TASK = {"id": "t1", "app": "TextEdit", "category": "textedit", "goal": "g",
        "setup": {"files": {"a.txt": "hi"}, "open": [{"app": "TextEdit", "as": "doc", "targets": ["{tmp}/a.txt"]}], "settle_s": 0},
        "steps": [{"do": "type", "window": "doc", "target": {"role": "textfield"}, "text": "x"}],
        "check": {"kind": "ax", "window": "doc", "target": {"role": "textfield"}, "equals": "x"}}
OK = lambda t, w, ti: {"ok": True, "log": [], "tool_ms": 12}


def ctx(tmp, doing, created_ever=(), **kw):
    kw.setdefault("drain_s", 0)
    server = fixtures.FixtureServer().start()
    ref = FakeDriver({(5, None): kw.pop("ref_tree", None) or tree("a.txt", "x")})
    closes = kw.pop("closes", True)
    args = dict(tool="baneyspaces", workdir=tmp, server=server, monitor=FakeMonitor(), opener=FakeOpener([5]),
                referee_driver=ref, exec_fn=fake_exec([]), doing=doing, sleep=lambda s: None, watch_dirs=(),
                availability_fn=lambda t, s, tool=None: None, running_fn=lambda a: False)
    args.update(kw)
    c = runner.Context(**args)
    c.ref, c.server_obj = ref, server
    c.created_ever = set(created_ever)
    if closes:
        orig = ref.run
        opener = args["opener"]

        def run(verb, timeout=60, **kw2):
            res = orig(verb, timeout, **kw2)
            if verb == "click" and kw2.get("ref") == "@s:e2":       # the window's own Close button
                ref.trees.clear()
                opener.closed.add(5)
            return res
        ref.run = run
    return c


class RunTask(unittest.TestCase):
    def run_it(self, task=TASK, doing=OK, **kw):
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, doing, **kw)
            try:
                return runner.run_task(task, c), c
            finally:
                c.server_obj.stop()

    def test_a_pass_records_time_changes_and_the_readback(self):
        rec, c = self.run_it(monitor=FakeMonitor(changes=2, setup=1, hid=1))
        self.assertEqual(rec["status"], "pass")
        self.assertEqual((len(rec["setup_changes"]), len(rec["changes"])), (1, 2))
        self.assertEqual(rec["hid_events"], 1)
        self.assertTrue(rec["check"]["ok"])

    def test_nonce_and_tmp_placeholders_expand(self):
        seen = {}
        t = dict(TASK, setup=dict(TASK["setup"], files={"doc-{nonce}.txt": "x {nonce}"},
                                  open=[{"app": "TextEdit", "as": "doc", "targets": ["{tmp}/doc-{nonce}.txt"]}]))

        def doing(task, w, ti):
            seen["t"] = task["setup"]["open"][0]["targets"][0]
            return {"ok": True, "log": []}
        self.run_it(task=t, doing=doing, nonce_fn=lambda: "abc123")
        self.assertTrue(seen["t"].endswith("/t1/doc-abc123.txt"))

    def test_a_failed_readback_fails_the_task(self):
        rec, _ = self.run_it(ref_tree=tree("a.txt", "WRONG"))
        self.assertEqual(rec["status"], "fail")

    def test_unavailable_never_opens_anything(self):
        called = []
        rec, c = self.run_it(doing=lambda *a: called.append(1), availability_fn=lambda t, s, tool=None: "unavailable: nope")
        self.assertEqual((rec["status"], called, c.opener.opened), ("unavailable", [], []))

    def test_the_keys_of_a_files_spec_are_expanded_and_the_fixture_is_where_the_task_opens_it(self):
        """sol-F1, second-S1: a {nonce} in a file name must give a file at the expanded open target."""
        t = dict(TASK, setup=dict(TASK["setup"], files={"f-{nonce}.txt": "x"},
                                  open=[{"app": "TextEdit", "as": "doc", "targets": ["{tmp}/f-{nonce}.txt"]}]))
        seen = {}

        def doing(task, w, ti):
            seen["exists"] = os.path.exists(task["setup"]["open"][0]["targets"][0])
            return {"ok": True, "log": []}
        self.run_it(task=t, doing=doing, nonce_fn=lambda: "c0ffee")
        self.assertTrue(seen["exists"])

    def test_a_fixture_missing_at_the_opened_path_is_an_infra_error_not_a_window_with_no_document(self):
        t = dict(TASK, setup=dict(TASK["setup"], files={"other.txt": "x"},
                                  open=[{"app": "TextEdit", "as": "doc", "targets": ["{tmp}/nope.txt"]}]))
        rec, c = self.run_it(task=t)
        self.assertEqual(rec["status"], "infra_error")
        self.assertIn("fixture", rec["why"])
        self.assertEqual(c.opener.opened, [])

    def test_setup_task_and_teardown_windows_do_not_overlap(self):
        """second-S7: half-open windows cut from the full log after teardown"""
        rec, c = self.run_it(monitor=FakeMonitor())
        gate, setup, task, teardown = c.monitor.calls
        self.assertEqual([x[2] for x in c.monitor.calls], [0, 0, 0, 0])
        self.assertEqual(setup[1], task[0])          # setup ends where the task starts
        self.assertEqual(task[1], teardown[0])       # the task ends where teardown starts
        self.assertEqual(gate[0], setup[0])

    def test_a_late_event_is_charged_once(self):
        rec, c = self.run_it(monitor=FakeMonitor(setup=0, changes=1))
        self.assertEqual((len(rec["setup_changes"]), len(rec["changes"])), (0, 1))

    def test_a_window_from_one_of_donovans_background_apps_is_ambient_not_scored(self):
        """second-S9"""
        mon = FakeMonitor(windows=[{"id": 9, "pid": 4, "owner": "Mail"}], ambient_pids={4})
        rec, _ = self.run_it(monitor=mon)
        self.assertEqual(rec["ambient_changes"][0]["windows"][0]["owner"], "Mail")
        self.assertEqual(rec["changes"], [])
        mon2 = FakeMonitor(windows=[{"id": 9, "pid": 4, "owner": "TextEdit"}])
        rec2, _ = self.run_it(monitor=mon2)
        self.assertEqual(len(rec2["changes"]), 1)           # the task's own app: charged

    def test_the_intended_change_of_a_task_is_not_charged(self):
        """first-F9: the stale-ref task closes its own window on purpose."""
        t = dict(TASK, allowed_change_fields=["front"])
        rec, _ = self.run_it(task=t, monitor=FakeMonitor(changes=2))
        self.assertEqual(rec["changes"], [])
        self.assertEqual(len(rec["intended_changes"]), 2)

    def test_a_shell_shortcut_fails_the_task(self):
        rec, _ = self.run_it(doing=lambda *a: {"ok": True, "log": [], "shortcut": "a shell command"})
        self.assertEqual(rec["status"], "fail")
        self.assertIn("shell", rec["why"])

    def test_a_harness_side_selector_miss_on_a_refusal_step_is_infra_not_a_refusal(self):
        t = dict(TASK, id="refuse-x", category="refusal", impossible=True, check={"kind": "nothing"})
        rec, _ = self.run_it(task=t, doing=lambda *a: {"ok": False, "log": [], "harness_error": True, "why": "not a tool refusal"})
        self.assertEqual(rec["status"], "infra_error")

    def test_a_locked_screen_means_not_run(self):
        rec, c = self.run_it(session_fn=lambda: (False, {"locked": True}))
        self.assertEqual(rec["status"], "not_run")
        self.assertIn("locked", rec["why"])
        self.assertEqual(c.opener.opened, [])

    def test_a_dead_monitor_means_the_task_does_not_start(self):
        rec, c = self.run_it(monitor=FakeMonitor(healthy=False))
        self.assertEqual(rec["status"], "monitor_lost")
        self.assertEqual(c.opener.opened, [])

    def test_a_monitor_lost_during_the_task_is_never_a_pass(self):
        rec, _ = self.run_it(monitor=FakeMonitor(lost=[{"t": 1, "why": "no beat for 400 ms"}]))
        self.assertEqual(rec["status"], "monitor_lost")
        self.assertIn("no beat", rec["why"])

    def test_setup_that_cannot_open_is_infra_not_a_tool_failure_and_keeps_its_disturbance(self):
        rec, _ = self.run_it(opener=FakeOpener([]), monitor=FakeMonitor(setup=1))
        self.assertEqual(rec["status"], "infra_error")
        self.assertEqual(len(rec["setup_changes"]), 1)

    def test_an_agent_side_infra_failure_is_excluded_and_can_stop_the_column(self):
        rec, _ = self.run_it(doing=lambda *a: {"ok": False, "log": [], "infra": "cua_repl did not start", "fatal_infra": True})
        self.assertEqual((rec["status"], rec["fatal_infra"]), ("infra_error", True))

    def test_expected_failure_is_attached(self):
        t = dict(TASK, expected_fail={"baneyspaces": {"phase": 2, "why": "w"}})
        rec, _ = self.run_it(task=t, ref_tree=tree("a.txt", "WRONG"))
        self.assertEqual((rec["expected_fail"]["phase"], rec["status"]), (2, "fail"))

    def test_refusal_task(self):
        t = dict(TASK, id="refuse-x", category="refusal", impossible=True, check={"kind": "nothing"})
        refused = lambda *a: {"ok": True, "log": [], "tool_errors": 1, "refusal": {"code": "not_supported", "suggestion": "use the keyboard"}}
        self.assertEqual(self.run_it(task=t, doing=refused)[0]["status"], "refused_ok")
        self.assertEqual(self.run_it(task=t, doing=lambda *a: {"ok": True, "log": [], "refusal": None})[0]["status"], "fail")

    def test_a_refusal_that_moved_the_screen_is_a_failure(self):
        t = dict(TASK, id="refuse-x", category="refusal", impossible=True, check={"kind": "nothing"})
        refused = lambda *a: {"ok": True, "log": [], "tool_errors": 1, "refusal": {"code": "x", "suggestion": "s"}}
        self.assertEqual(self.run_it(task=t, doing=refused, monitor=FakeMonitor(changes=1))[0]["status"], "fail")
        self.assertEqual(self.run_it(task=t, doing=refused, monitor=FakeMonitor(posted=0, hid=1))[0]["status"], "fail")

    def test_a_refusal_with_no_tool_call_at_all_is_not_credited(self):
        """second-S5: a no-op agent that just writes REFUSED."""
        t = dict(TASK, id="refuse-x", category="refusal", impossible=True, check={"kind": "nothing"})
        prose = lambda *a: {"ok": True, "log": [], "refusal": {"code": "agent_refused", "suggestion": "list windows first"}}
        self.assertEqual(self.run_it(task=t, doing=prose)[0]["status"], "fail")

    def test_a_read_task_needs_the_answer_and_a_computer_use_call(self):
        """sol-F4: a normally completed no-op agent must not pass."""
        t = dict(TASK, requires_tool_call=True, check={"kind": "answer", "contains": "{nonce}"})
        said = lambda a, calls: (lambda *x: {"ok": True, "log": [], "answer": a, "tool_calls": calls})
        nonce = dict(nonce_fn=lambda: "ff00aa")
        self.assertEqual(self.run_it(task=t, doing=said("DONE the code is ff00aa", 3), **nonce)[0]["status"], "pass")
        self.assertEqual(self.run_it(task=t, doing=said("DONE the code is ff00aa", 0), **nonce)[0]["status"], "fail")   # guessed / no call
        self.assertEqual(self.run_it(task=t, doing=said("DONE nothing to report", 3), **nonce)[0]["status"], "fail")
        self.assertEqual(self.run_it(task=t, doing=said("", 0), **nonce)[0]["status"], "fail")                          # the no-op agent

    def test_only_the_windows_it_opened_are_closed(self):
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, OK)
            runner.run_task(TASK, c)
            c.server_obj.stop()
            clicks = [call for call in c.ref.calls if call[0] == "click"]
            self.assertTrue(clicks)
            self.assertTrue(all(call[1].get("ref") == "@s:e2" for call in clicks))

    def test_a_window_the_bench_made_that_is_not_on_the_agent_workspace_stops_the_task_before_the_tool_runs(self):
        called = []
        rec, c = self.run_it(opener=FakeOpener([5], listing=[]), doing=lambda *a: called.append(1))
        self.assertEqual(rec["status"], "infra_error")
        self.assertIn("not on the agent workspace", rec["why"])
        self.assertEqual(called, [])

    def test_an_app_that_owns_a_window_the_bench_did_not_create_is_an_infra_error(self):
        """second-S7: a restored session is Donovan's documents inside the run"""
        op = FakeOpener([5], listing=[5, 77])
        op.apps = {77: "TextEdit"}
        called = []
        rec, c = self.run_it(opener=op, doing=lambda *a: called.append(1))
        self.assertEqual(rec["status"], "infra_error")
        self.assertIn("did not create", rec["why"])
        self.assertEqual(called, [])

    def test_a_leftover_window_of_an_earlier_task_is_the_benches_own_not_foreign(self):
        op = FakeOpener([5], listing=[5, 41])
        op.apps = {41: "TextEdit"}
        rec, c = self.run_it(opener=op, created_ever={41})
        self.assertEqual(rec["status"], "pass")

    def test_the_app_is_not_quit_by_name_while_any_of_its_windows_is_still_open(self):
        """sol-F2 (no pid known, app guaranteed ours by not_running)"""
        state = {"up": False}

        def doing(task, w, ti):
            state["up"] = True
            return {"ok": True, "log": []}
        t = dict(TASK, setup=dict(TASK["setup"], requires={"not_running": ["TextEdit"]}))
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, doing, running_fn=lambda a: state["up"], closes=False)
            c.exec = fake_exec([])
            rec = runner.run_task(t, c)
            c.server_obj.stop()
        self.assertFalse(any('to quit' in " ".join(a) for a in c.exec.seen))
        self.assertEqual(rec["teardown_pending"]["apps"], ["TextEdit"])
        self.assertIn("not quit", rec["teardown_pending"]["error"])

    def test_teardown_is_skipped_after_an_abort_and_the_record_survives_an_aborted_task(self):
        """second-S6: an Aborted raised inside the task keeps teardown_pending and the setup disturbance."""
        def aborted(*a):
            raise Aborted("stopped: input was seen on this Mac")
        with tempfile.TemporaryDirectory() as d:
            flag = {"abort": False}
            c = ctx(d, aborted, aborted_fn=lambda: flag["abort"], monitor=FakeMonitor(setup=1))
            orig = c.doing

            def doing(*a):
                flag["abort"] = True
                return orig(*a)
            c.doing = doing
            rec = runner.run_task(TASK, c)
            c.server_obj.stop()
        self.assertEqual(rec["status"], "not_run")
        self.assertEqual(rec["teardown_pending"]["windows"], [5])
        self.assertEqual(len(rec["setup_changes"]), 1)
        self.assertEqual([x for x in c.ref.calls if x[0] == "click"], [])

    def test_teardown_is_skipped_after_an_abort_and_says_which_windows_it_left(self):
        rec, c = self.run_it(aborted_fn=lambda: True)
        self.assertEqual(rec["teardown_pending"]["windows"], [5])
        self.assertEqual([x for x in c.ref.calls if x[0] == "click"], [])

    def test_an_exception_in_the_task_is_an_infra_error_with_its_accounting_kept(self):
        """second-S5: windows left and the setup disturbance must survive an exception in the body."""
        def boom(*a):
            raise RuntimeError("tool crashed")
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, boom, monitor=FakeMonitor(setup=1), closes=False)
            rec = runner.run_task(TASK, c)
            c.server_obj.stop()
        self.assertEqual(rec["status"], "infra_error")
        self.assertIn("RuntimeError", rec["why"])
        self.assertEqual(len(rec["setup_changes"]), 1)
        self.assertEqual(rec["teardown_left"], {"5": "still open after three close attempts"})
        self.assertEqual(rec["teardown_pending"]["windows"], [5])
        self.assertIn("teardown_changes", rec)
        self.assertFalse(os.path.exists(os.path.join(d, "t1")))

    def test_windows_are_closed_even_when_the_task_raises(self):
        def boom(*a):
            raise RuntimeError("tool crashed")
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, boom)
            rec = runner.run_task(TASK, c)
            c.server_obj.stop()
        self.assertTrue(any(call[0] == "click" for call in c.ref.calls))
        self.assertNotIn("teardown_pending", rec)

    def test_new_entries_on_the_desktop_are_collateral(self):
        with tempfile.TemporaryDirectory() as desk:
            def doing(t, w, ti):
                open(os.path.join(desk, "untitled folder"), "w").close()
                return {"ok": True, "log": []}
            rec, _ = self.run_it(doing=doing, watch_dirs=(desk,))
        self.assertEqual(len(rec["collateral"]), 1)

    def test_an_app_that_was_running_before_is_not_quit_by_name(self):
        t = dict(TASK, setup=dict(TASK["setup"], requires={"not_running": ["Calculator"]}, quit_after=["Calculator"]))
        for was_running, expect in ((False, True), (True, False)):
            state = {"calc": was_running}

            def running(app):
                return True if app == "TextEdit" else state["calc"]

            def doing(task, w, ti):
                state["calc"] = True
                return {"ok": True, "log": []}
            with tempfile.TemporaryDirectory() as d:
                c = ctx(d, doing, running_fn=running)
                c.exec = fake_exec([(lambda a: a[0] == "osascript" and "quit" in " ".join(a), (0, "", ""))])
                state_after = {}

                orig = c.exec

                def ex(argv, **kw):
                    if argv[0] == "osascript" and "quit" in " ".join(argv):
                        state["calc"] = False
                    return orig(argv, **kw)
                ex.seen = orig.seen
                c.exec = ex
                runner.run_task(t, c)
                c.server_obj.stop()
                quit_ = any('tell application "Calculator" to quit' in " ".join(a) for a in orig.seen)
            self.assertEqual(quit_, expect, was_running)

    def pid_task(self, **kw):
        op = FakeOpener([5])
        op.pids = {5: 777}
        alive = {"v": True}
        seen = []

        def qex(argv, timeout=60, env=None, stdin=None, cwd=None):
            seen.append(argv)
            if argv[:2] == ["kill", "-TERM"] and kw.get("dies", True):
                alive["v"] = False
            return 0, "", "", 1
        return op, alive, seen, qex

    def run_pid(self, ref_windows=(True, []), dies=True, running_other=True):
        op, alive, seen, qex = self.pid_task(dies=dies)
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, OK, opener=op, running_fn=lambda a: running_other)      # another copy of the app IS running
            c.quiet_exec = qex
            c.alive_fn = lambda pid: alive["v"]
            c.ref.pid_windows_result = ref_windows
            rec = runner.run_task(TASK, c)
            c.server_obj.stop()
        return rec, seen, c

    def test_only_the_instance_the_task_started_is_quit_even_when_another_copy_runs(self):
        """first-F3: exclusive task, TextEdit already running without a window on his workspaces"""
        rec, seen, c = self.run_pid()
        self.assertIn(["kill", "-TERM", "777"], seen)
        self.assertEqual([a for a in seen if a[0] == "kill"], [["kill", "-TERM", "777"]])
        self.assertFalse(any(a[0] == "osascript" for a in c.exec.seen if hasattr(c.exec, "seen")))
        self.assertNotIn("teardown_pending", rec)

    def test_an_instance_with_a_window_outside_the_tracked_set_is_not_quit(self):
        """sol-F2: a window on another workspace would die with it"""
        rec, seen, c = self.run_pid(ref_windows=(True, ["w-99"]))
        self.assertEqual([a for a in seen if a[0] == "kill"], [])
        self.assertEqual(rec["teardown_pending"]["pids"], [777])
        self.assertIn("still open", rec["teardown_pending"]["error"])

    def test_an_instance_whose_windows_cannot_be_enumerated_is_not_quit(self):
        rec, seen, c = self.run_pid(ref_windows=(False, []))
        self.assertEqual([a for a in seen if a[0] == "kill"], [])
        self.assertIn("could not be enumerated", rec["teardown_pending"]["error"])

    def test_an_instance_that_does_not_exit_is_listed_not_forgotten(self):
        rec, seen, c = self.run_pid(dies=False)
        self.assertEqual(rec["teardown_pending"]["pids"], [777])
        self.assertIn("did not exit", rec["teardown_pending"]["error"])

    def test_finder_is_never_quit(self):
        t = dict(TASK, setup=dict(TASK["setup"], open=[{"app": "Finder", "as": "doc", "targets": ["{tmp}/a.txt"]}]))
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, OK, running_fn=lambda a: False)
            c.exec = fake_exec([])
            runner.run_task(t, c)
            c.server_obj.stop()
        self.assertFalse(any("Finder" in " ".join(a) for a in c.exec.seen))

    def test_hide_runs_only_for_an_app_the_task_started(self):
        t = dict(TASK, setup=dict(TASK["setup"], hide="Calculator", quit_after=["Calculator"], requires={"not_running": ["Calculator"]}))
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, OK)
            c.exec = fake_exec([])
            runner.run_task(t, c)
            c.server_obj.stop()
            self.assertTrue(any("set visible of process" in " ".join(a) for a in c.exec.seen))
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, OK, running_fn=lambda a: True)
            c.exec = fake_exec([])
            runner.run_task(t, c)
            c.server_obj.stop()
            self.assertFalse(any("set visible of process" in " ".join(a) for a in c.exec.seen))


class SetupLeaksAndProfiles(unittest.TestCase):
    def run_it(self, task=TASK, doing=OK, **kw):
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, doing, **kw)
            try:
                return runner.run_task(task, c), c
            finally:
                c.server_obj.stop()

    def test_a_refusal_that_posted_input_is_a_failure(self):
        """sol-F2: posted > 0, real == 0, no screen change"""
        t = dict(TASK, id="refuse-x", category="refusal", impossible=True, check={"kind": "nothing"})
        refused = lambda *a: {"ok": True, "log": [], "tool_errors": 1, "refusal": {"code": "x", "suggestion": "s"}}
        rec, _ = self.run_it(task=t, doing=refused, monitor=FakeMonitor(posted=3))
        self.assertEqual(rec["status"], "fail")
        self.assertEqual(rec["posted_input_by_pid"], {"4242": 3})
        self.assertEqual(self.run_it(task=t, doing=refused, monitor=FakeMonitor(posted=0))[0]["status"], "refused_ok")

    def test_the_run_waits_out_the_debounce_before_t0(self):
        """first-F4"""
        slept = []
        rec, c = self.run_it(sleep=lambda s: slept.append(s), drain_s=1.5)
        self.assertIn(1.5, slept)

    def test_a_window_leaked_during_setup_is_an_infra_error_never_a_fail_and_the_tool_is_never_run(self):
        """first-F4: the 2026-10-31 incident. The event was first seen before t0 but only reported after it."""
        class Late:
            """changes() answers from a list of events stamped with their FIRST-SEEN time."""
            def __init__(self):
                self.events = [{"t": 3.0, "fields": ["unplaced_window"], "windows": [{"id": 9, "pid": 4, "owner": "TextEdit"}]}]
                self.losses = []
                self.calls = []

            def changes(self, t0, t1, settle=0.0):
                self.calls.append((t0, t1))
                return [e for e in self.events if t0 <= e["t"] < t1 + settle]

            def input(self, *a, **k):
                return 0, 0, {}

            def lost_between(self, *a, **k):
                return []

            def healthy(self):
                return True, ""

            def user_pids_now(self):
                return frozenset()
        clock = iter([1.0, 5.0, 5.0, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8])
        called = []
        rec, c = self.run_it(monitor=Late(), clock=lambda: next(clock), doing=lambda *a: called.append(1))
        self.assertEqual(rec["status"], "infra_error")       # shared harness code did it: never charged to the tool
        self.assertIn("leaked", rec["why"])
        self.assertEqual(called, [])
        self.assertEqual(rec["setup_leak"][0]["fields"], ["unplaced_window"])

    def test_a_leak_from_a_background_app_during_setup_is_ambient_and_does_not_fail_the_task(self):
        class Bg(FakeMonitor):
            def changes(self, t0, t1, settle=0.0):
                self.calls.append((t0, t1, settle))
                if len(self.calls) in (1, 2):         # the gate and the late setup window
                    return [{"t": 1, "fields": ["user_window"], "windows": [{"id": 1, "pid": 2, "owner": "Mail"}]}]
                return []
        rec, _ = self.run_it(monitor=Bg(ambient_pids={2}))
        self.assertEqual(rec["status"], "pass")
        self.assertEqual(rec["ambient_changes"][0]["windows"][0]["owner"], "Mail")

    def test_a_window_from_an_app_the_tool_made_open_is_never_ambient(self):
        """second-S1: Safari launched by a double-click is not Donovan's background app"""
        class Made(FakeMonitor):
            def changes(self, t0, t1, settle=0.0):
                self.calls.append((t0, t1, settle))
                if len(self.calls) == 3:              # the late task window
                    return [{"t": 1, "fields": ["user_window"], "windows": [{"id": 1, "pid": 99, "owner": "Safari"}]}]
                return []
        rec, _ = self.run_it(monitor=Made(ambient_pids={2}))
        self.assertEqual(len(rec["changes"]), 1)
        self.assertNotIn("ambient_changes", rec)

    def test_a_profile_task_is_unavailable_until_agent_open_takes_a_user_data_dir(self):
        t = dict(TASK, setup=dict(TASK["setup"], profile="user-data-dir"))
        op = FakeOpener([5])
        op.profile_ok = False
        rec, c = self.run_it(task=t, opener=op)
        self.assertEqual(rec["status"], "unavailable")
        self.assertIn("--user-data-dir", rec["why"])
        self.assertEqual(op.opened, [])

    def test_a_profile_task_launches_with_a_fresh_dir_under_the_bench_temp_dir(self):
        t = dict(TASK, setup=dict(TASK["setup"], profile="user-data-dir"))
        op = FakeOpener([5])
        rec, c = self.run_it(task=t, opener=op)
        app, targets, profile = op.opened[0]
        self.assertTrue(profile.endswith("/t1/profile"))
        self.assertEqual(rec["status"], "pass")

    def test_a_launch_whose_process_does_not_carry_the_profile_is_dropped_and_its_window_closed(self):
        t = dict(TASK, setup=dict(TASK["setup"], profile="user-data-dir"))
        op = FakeOpener([5])
        op.verified = False
        called = []
        rec, c = self.run_it(task=t, opener=op, doing=lambda *a: called.append(1))
        self.assertEqual(rec["status"], "infra_error")
        self.assertIn("--user-data-dir", rec["why"])
        self.assertEqual(called, [])
        self.assertTrue(any(call[0] == "click" for call in c.ref.calls))     # the unverified window is closed

    def test_a_teardown_that_raises_is_recorded_and_the_accounting_and_cleanup_still_happen(self):
        """second-S6"""
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, OK)

            class Broken:
                def snapshot(self, *a, **k):
                    raise FileNotFoundError("agent-desktop is gone")
                run = snapshot
            c.cleanup_driver = Broken()
            rec = runner.run_task(TASK, c)
            c.server_obj.stop()
            self.assertEqual(rec["teardown_pending"]["windows"], [5])
            self.assertIn("FileNotFoundError", rec["teardown_pending"]["error"])
            self.assertIn("teardown_changes", rec)
            self.assertFalse(os.path.exists(os.path.join(d, "t1")))

    def test_the_closed_window_of_the_missing_window_task_is_not_closed_twice(self):
        t = dict(TASK, setup=dict(TASK["setup"], close_before_run=["doc"]))
        with tempfile.TemporaryDirectory() as d:
            c = ctx(d, OK)
            orig = c.ref.run

            def run(verb, timeout=60, **kw):
                c.ref.trees.clear()               # the window is gone once Close is pressed
                return orig(verb, timeout, **kw)
            c.ref.run = run
            rec = runner.run_task(t, c)
            c.server_obj.stop()
        self.assertEqual(len([x for x in c.ref.calls if x[0] == "click"]), 1)
        self.assertNotIn("teardown_pending", rec)


class Exec_(unittest.TestCase):
    def test_runs_and_times(self):
        rc, out, err, ms = Exec()(["/bin/echo", "hi"])
        self.assertEqual((rc, out.strip()), (0, "hi"))

    def test_timeout(self):
        self.assertEqual(Exec()(["/bin/sleep", "5"], timeout=0.3)[0], 124)

    def test_cwd_is_the_process_cwd(self):
        with tempfile.TemporaryDirectory() as d:
            out = Exec()(["/bin/pwd"], cwd=d)[1].strip()
        self.assertEqual(os.path.realpath(out), os.path.realpath(d))

    def test_abort_kills_the_child_and_raises(self):
        ev = threading.Event()
        ex = Exec(abort=ev)
        threading.Timer(0.3, ev.set).start()
        t0 = time.monotonic()
        with self.assertRaises(Aborted):
            ex(["/bin/sleep", "10"], timeout=20)
        self.assertLess(time.monotonic() - t0, 3)
        with self.assertRaises(Aborted):
            ex(["/bin/echo", "never"])


class Server(unittest.TestCase):
    def test_form_page_and_submissions(self):
        import urllib.request
        s = fixtures.FixtureServer().start()
        try:
            self.assertIn('name="email"', urllib.request.urlopen(s.base + "/form").read().decode())
            urllib.request.urlopen(urllib.request.Request(s.base + "/submit", data=b"name=Ada&email=a%40b.c", method="POST")).read()
            self.assertEqual(s.submissions, [{"name": "Ada", "email": "a@b.c"}])
            self.assertTrue(s.base.startswith("http://127.0.0.1:"))
        finally:
            s.stop()

    def test_fixtures_write(self):
        with tempfile.TemporaryDirectory() as d:
            fixtures.write_files(d, {"a/b.txt": "x", "long.txt": {"lines": 3}, "p.pdf": {"pdf_pages": 2}, "r.rtf": {"rtf": True}, "dd": {"dir": True}})
            self.assertEqual(open(os.path.join(d, "a/b.txt")).read(), "x")
            pdf = open(os.path.join(d, "p.pdf"), "rb").read()
            self.assertTrue(pdf.startswith(b"%PDF-1.4") and pdf.rstrip().endswith(b"%%EOF"))
            self.assertTrue(os.path.isdir(os.path.join(d, "dd")))


if __name__ == "__main__":
    unittest.main()
