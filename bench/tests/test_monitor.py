import json
import os
import sys
import tempfile
import time
import unittest

import support  # noqa: F401
from benchlib import monitor

CHANGE = lambda t, fields: json.dumps({"event": "change", "t": t, "fields": fields, "from": {}, "to": {}})


class Counting(unittest.TestCase):
    def events(self, lines):
        return [monitor.parse_line(x) for x in lines]

    def test_parse_ignores_noise(self):
        self.assertIsNone(monitor.parse_line("garbage"))
        self.assertIsNone(monitor.parse_line("[1]"))
        self.assertIsNone(monitor.parse_line('{"event":"x"}'))

    def test_changes_inside_the_window_count(self):
        ev = self.events([CHANGE(9.0, ["front"]), CHANGE(10.5, ["pointer"]), CHANGE(11.0, ["workspace", "key_window"]),
                          CHANGE(20.0, ["front"])])
        got = monitor.changes_between(ev, 10.0, 12.0)
        self.assertEqual([c["fields"] for c in got], [["pointer"], ["workspace", "key_window"]])

    def test_a_change_just_after_the_window_counts_only_with_a_settle(self):
        ev = self.events([CHANGE(12.2, ["front"]), CHANGE(12.4, ["front"])])
        self.assertEqual(len(monitor.changes_between(ev, 10.0, 12.0, settle=0.25)), 1)
        self.assertEqual(len(monitor.changes_between(ev, 10.0, 12.0)), 0)

    def test_windows_are_half_open_so_an_event_on_the_boundary_is_counted_once(self):
        ev = self.events([CHANGE(12.0, ["front"])])
        self.assertEqual(len(monitor.changes_between(ev, 10.0, 12.0)), 0)
        self.assertEqual(len(monitor.changes_between(ev, 12.0, 14.0)), 1)

    def test_before_start_does_not_count(self):
        ev = self.events([CHANGE(9.99, ["front"])])
        self.assertEqual(monitor.changes_between(ev, 10.0, 12.0), [])

    def test_a_window_appearing_on_a_user_workspace_is_a_screen_change_with_its_id(self):
        ev = self.events([json.dumps({"event": "change", "t": 10.5, "fields": ["user_window"],
                                      "windows": [{"id": 4711, "pid": 9, "owner": "TextEdit"}], "from": {}, "to": {}})])
        got = monitor.changes_between(ev, 10.0, 12.0)
        self.assertEqual((got[0]["fields"], got[0]["windows"][0]["id"]), (["user_window"], 4711))
        from benchlib import scoring
        s = scoring.summarize([{"id": "a", "status": "pass", "duration_s": 1, "changes": got}])
        self.assertEqual((s["screen_changes"], s["tasks_with_changes"]), (1, 1))

    def test_beats_input_and_session_are_not_changes(self):
        ev = self.events([json.dumps({"event": "beat", "t": 10.5, "samples": 20}),
                          json.dumps({"event": "input", "t": 10.6, "real": 0, "posted": {"4242": 3}}),
                          json.dumps({"event": "session", "t": 10.7, "state": {"locked": False}})])
        self.assertEqual(monitor.changes_between(ev, 10.0, 12.0), [])

    def test_real_input_is_told_from_input_posted_by_a_program(self):
        ev = self.events([json.dumps({"event": "input", "t": 10.1, "real": 0, "posted": {"4242": 3, "77": 2}}),
                          json.dumps({"event": "input", "t": 10.2, "real": 1, "posted": {}})])
        self.assertEqual(monitor.input_between(ev, 10.0, 12.0), (1, 5, {"4242": 3, "77": 2}))

    def test_a_window_is_ambient_only_if_its_process_already_had_a_window_on_his_workspaces(self):
        """second-S1"""
        win = lambda owner, pid: {"t": 1, "fields": ["user_window"], "windows": [{"id": 1, "pid": pid, "owner": owner}]}
        before = {100}          # Mail was running with a window on Donovan's workspace at ts0
        charged, ambient = monitor.attribute([win("Mail", 100), win("Safari", 200), win("TextEdit", 100)], {"TextEdit"}, before)
        self.assertEqual([c["windows"][0]["owner"] for c in charged], ["Safari", "TextEdit"])
        self.assertEqual([c["windows"][0]["owner"] for c in ambient], ["Mail"])
        self.assertEqual(monitor.attribute([win("Mail", 100)], set(), frozenset())[1], [])    # nothing known: nothing is ambient
        mixed = {"t": 1, "fields": ["front", "unplaced_window"], "windows": [{"id": 1, "pid": 100, "owner": "Mail"}]}
        charged, ambient = monitor.attribute([mixed], {"TextEdit"}, before)
        self.assertEqual((charged[0]["fields"], ambient[0]["fields"]), (["front"], ["unplaced_window"]))

    def test_another_tools_window_from_a_process_that_was_not_there_before_is_charged(self):
        win = lambda owner, pid: {"t": 1, "fields": ["unplaced_window"], "windows": [{"id": 1, "pid": pid, "owner": owner}]}
        own = monitor.TOOL_OWNERS["baneyspaces"] | {"TextEdit"}
        charged, ambient = monitor.attribute([win("BaneySpaces", 5), win("ChatGPT", 6)], own, {6})
        self.assertEqual([c["windows"][0]["owner"] for c in charged], ["BaneySpaces"])
        self.assertEqual([c["windows"][0]["owner"] for c in ambient], ["ChatGPT"])
        self.assertNotIn("BaneySpaces", monitor.TOOL_OWNERS["chatgpt"])

    def test_the_user_pids_snapshot_comes_from_the_samplers_user_pids_events(self):
        m = monitor.Monitor(["x"])
        m.user_pids = {1, 2}
        self.assertEqual(m.user_pids_now(), frozenset({1, 2}))

    def test_a_pointer_or_workspace_change_is_never_ambient(self):
        c = {"t": 1, "fields": ["pointer"]}
        self.assertEqual(monitor.attribute([c], set())[0], [c])


FAKE = r'''
import json, sys, time
def out(o): print(json.dumps(o), flush=True)
mode = sys.argv[1]
out({"event": "start", "t": time.time(), "state": {}, "interval_ms": 50, "tap": mode in ("input", "tapdead", "hidreal"), "idle": 700})
out({"event": "change", "t": time.time(), "fields": ["front"], "from": {}, "to": {}})
out({"event": "hid", "t": time.time(), "idle": 0.4})
for i in range(6):
    out({"event": "beat", "t": time.time(), "samples": i + 1, "gap_ms": 50})
    time.sleep(0.05)
if mode == "healthy":
    while True:
        out({"event": "beat", "t": time.time(), "samples": 99, "gap_ms": 50}); time.sleep(0.05)
elif mode == "stall":
    time.sleep(10)                     # alive but silent
elif mode == "exit":
    sys.exit(0)
elif mode == "input":
    out({"event": "input", "t": time.time(), "real": 0, "posted": {"4242": 5}})
    out({"event": "input", "t": time.time(), "real": 2, "posted": {}})
    while True:
        out({"event": "beat", "t": time.time(), "samples": 99, "gap_ms": 50}); time.sleep(0.05)
elif mode == "tapdead":
    out({"event": "tap_disabled", "t": time.time()})
    while True:
        out({"event": "beat", "t": time.time(), "samples": 99, "gap_ms": 50}); time.sleep(0.05)
elif mode == "hidreal":
    out({"event": "hid", "t": time.time(), "idle": 0.2, "real": True})
    while True:
        out({"event": "beat", "t": time.time(), "samples": 99, "gap_ms": 50}); time.sleep(0.05)
elif mode == "secure":
    out({"event": "session", "t": time.time(), "state": {"secure_input": True}})
    while True:
        out({"event": "beat", "t": time.time(), "samples": 99, "gap_ms": 50}); time.sleep(0.05)
elif mode == "locked":
    out({"event": "session", "t": time.time(), "state": {"locked": True}})
    while True:
        out({"event": "beat", "t": time.time(), "samples": 99, "gap_ms": 50}); time.sleep(0.05)
elif mode == "gap":
    out({"event": "beat", "t": time.time(), "samples": 7, "gap_ms": 450})
    while True:
        out({"event": "beat", "t": time.time(), "samples": 99, "gap_ms": 50}); time.sleep(0.05)
'''


class Process(unittest.TestCase):
    def start(self, mode, **kw):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "fake.py")
        open(path, "w").write(FAKE)
        m = monitor.Monitor([sys.executable, path, mode], **kw).start()
        self.addCleanup(m.stop)
        return m

    def wait_for(self, cond, secs=3):
        end = time.time() + secs
        while time.time() < end and not cond():
            time.sleep(0.02)
        return cond()

    def test_a_healthy_sampler_collects_events_and_calls_on_hid(self):
        seen, t0 = [], time.time() - 1
        m = self.start("healthy", on_hid=seen.append)
        self.assertTrue(self.wait_for(lambda: seen and m.samples >= 6))
        self.assertEqual(len(m.changes(t0, time.time())), 1)
        self.assertEqual(m.healthy(), (True, ""))
        self.assertEqual((m.health()["interval_ms"], m.health()["losses"]), (50, []))

    def test_a_sampler_that_goes_silent_is_lost_within_a_fraction_of_a_second(self):
        """first-F5, sol-F2: no beat for 200 ms aborts, it does not just look quiet."""
        lost = []
        m = self.start("stall", on_lost=lost.append)
        t0 = time.time()
        self.assertTrue(self.wait_for(lambda: lost))
        self.assertLess(time.time() - t0, 1.5)
        self.assertIn("no beat", lost[0]["why"])
        ok, why = m.healthy()
        self.assertFalse(ok)
        self.assertTrue(m.lost_between(t0 - 1, time.time()))

    def test_a_sampler_that_exits_is_lost(self):
        lost = []
        m = self.start("exit", on_lost=lost.append)
        self.assertTrue(self.wait_for(lambda: lost))
        self.assertFalse(m.healthy()[0])

    def test_a_beat_that_reports_a_long_gap_is_lost(self):
        lost = []
        self.start("gap", on_lost=lost.append)
        self.assertTrue(self.wait_for(lambda: lost))
        self.assertIn("450", lost[0]["why"])

    def test_only_real_input_reaches_on_hid(self):
        """first-F3"""
        seen = []
        m = self.start("input", on_hid=seen.append)
        self.assertTrue(self.wait_for(lambda: seen))
        self.assertEqual(len(seen), 1)                      # the posted event did not call it
        self.assertEqual(m.input(time.time() - 5, time.time() + 1), (2, 5, {"4242": 5}))
        self.assertTrue(m.real_idle() < 2)

    def test_real_idle_counts_from_the_samplers_start_when_nothing_was_pressed(self):
        m = monitor.Monitor(["x"])
        m._start_t, m._start_idle = 100.0, 700.0
        self.assertEqual(m.real_idle(now=130.0), 730.0)
        m._real_last = 125.0
        self.assertEqual(m.real_idle(now=130.0), 5.0)

    def test_a_session_that_locks_calls_on_session(self):
        got = []
        m = self.start("locked", on_session=got.append)
        self.assertTrue(self.wait_for(lambda: got))
        self.assertFalse(m.session_ok()[0])

    def test_a_tap_the_system_disabled_is_a_lost_monitor(self):
        """second-S1"""
        lost = []
        self.start("tapdead", on_lost=lost.append)
        self.assertTrue(self.wait_for(lambda: lost))
        self.assertIn("tap was disabled", lost[0]["why"])

    def test_hid_activity_the_tap_cannot_explain_is_real_input(self):
        """second-S1: typing under secure input never reaches a tap"""
        seen = []
        m = self.start("hidreal", on_hid=seen.append)
        self.assertTrue(self.wait_for(lambda: seen))
        self.assertTrue(m.real_idle() < 2)

    def test_secure_keyboard_input_counts_as_the_user_being_here(self):
        got = []
        m = self.start("secure", on_session=got.append)
        self.assertTrue(self.wait_for(lambda: got))
        self.assertFalse(m.session_ok()[0])
        self.assertIn("secure keyboard input", __import__("benchlib.host", fromlist=["x"]).session_gate(False, {"secure_input": True})[1])

    def test_without_the_tap_every_hid_event_counts_as_real(self):
        m = monitor.Monitor(["x"])
        self.assertFalse(m.tap_ok)

    def test_stopping_the_monitor_is_not_a_loss(self):
        lost = []
        m = self.start("healthy", on_lost=lost.append)
        m.stop()
        time.sleep(0.4)
        self.assertEqual(lost, [])

    def test_a_silent_sampler_at_start_is_an_error(self):
        m = monitor.Monitor([sys.executable, "-c", "import time; time.sleep(5)"])
        with self.assertRaises(RuntimeError):
            m.start(timeout=0.3)


class SamplerSource(unittest.TestCase):
    def test_it_samples_every_50_ms_the_four_things(self):
        src = open(os.path.join(support.BENCH, "lib", "sampler.swift")).read()
        self.assertIn("intervalMs = 50", src)
        for needle in ("frontmostApplication", "state.json", "CGEvent(source: nil)?.location", "CGWindowListCopyWindowInfo",
                       "hidSystemState"):
            self.assertIn(needle, src)
        self.assertIn("user_window", src)
        self.assertIn('emit(["event": "beat"', src)          # a beat on every sample
        self.assertIn("func isChild", src)                   # a sheet belongs to its parent window
        self.assertIn("stateAgent", src)
        self.assertIn("CGEvent.tapCreate", src)                # the listen-only tap
        self.assertIn(".listenOnly", src)
        self.assertIn("eventSourceUnixProcessID", src)         # pid 0 is hardware
        self.assertIn("CGSessionCopyCurrentDictionary", src)
        self.assertIn("kCGWindowOwnerName", src)               # windows carry their owner for attribution
        self.assertIn("now - since >= 1.0", src)               # unplaced_window is debounced a second
        self.assertIn('"t": since, "fields": ["unplaced_window"]', src)    # its own line, stamped with when it FIRST appeared
        self.assertNotIn("stamp = min(stamp, since)", src)                 # never merged into the current sample's fields
        self.assertIn("--allow-file", src)                                 # only the column's own process groups may post
        self.assertIn("ownPoster", src)
        self.assertIn('"user_pids"', src)
        self.assertIn("tapDisabledByTimeout", src)             # a tap the system turns off is reported, not ignored
        self.assertIn("tapDisabledByUserInput", src)
        self.assertIn("IsSecureEventInputEnabled", src)
        self.assertIn('"real": true', src)                     # unexplained HID activity is real
        self.assertIn("unplaced_window", src)
        self.assertNotIn("CGEventPost", src)   # the monitor never sends input


if __name__ == "__main__":
    unittest.main()
