import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest

import support

GUARD = os.path.join(support.BENCH, "agent-desktop-guard")

FAKE_REAL = r'''#!/usr/bin/env python3
import json, sys
a = sys.argv[1:]
if a[0] == "snapshot":
    print(json.dumps({"ok": True, "data": {"snapshot_id": "sABC123", "tree": {"role": "window"}}}))
elif a[0] == "list-windows":
    print(json.dumps({"ok": True, "data": [{"id": "w-10", "title": "mine"}, {"id": "w-99", "title": "Donovan's private note"}]}))
else:
    print(json.dumps({"ok": True, "data": {"ran": a}}))
'''


class Guard(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.real = os.path.join(self.d, "real")
        open(self.real, "w").write(FAKE_REAL)
        os.chmod(self.real, 0o755)
        self.gf = os.path.join(self.d, "guard.json")
        json.dump({"windows": ["w-10"], "snapshots": []}, open(self.gf, "w"))

    def run_guard(self, *args):
        env = dict(os.environ, BENCH_AD_BIN=self.real, BENCH_GUARD_FILE=self.gf)
        p = subprocess.run([sys.executable, GUARD, *args], capture_output=True, text=True, env=env, timeout=30)
        try:
            out = json.loads(p.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            out = None
        return p.returncode, out

    def refused(self, *args):
        rc, out = self.run_guard(*args)
        self.assertEqual(rc, 2, (args, out))
        self.assertEqual(out["error"]["code"], "guard_refused")
        self.assertTrue(out["error"]["suggestion"])
        return out

    def test_the_wrapper_is_executable(self):
        self.assertTrue(os.stat(GUARD).st_mode & stat.S_IXUSR)

    def test_a_snapshot_of_the_tasks_window_goes_through_and_its_refs_become_usable(self):
        rc, out = self.run_guard("snapshot", "--window-id", "w-10", "-i")
        self.assertEqual((rc, out["ok"]), (0, True))
        rc, out = self.run_guard("click", "@sABC123:e4")
        self.assertEqual((rc, out["data"]["ran"]), (0, ["click", "@sABC123:e4"]))

    def test_window_ids_may_be_given_bare(self):
        self.assertEqual(self.run_guard("snapshot", "--window-id", "10")[0], 0)

    def test_another_window_is_refused_for_every_form_of_the_flag(self):
        """second-S3: Donovan's Notes window"""
        self.refused("snapshot", "--window-id", "w-99")
        self.refused("snapshot", "--window-id=w-99")
        self.refused("press", "--window-id", "w-99", "cmd+a")

    def test_app_wide_and_headed_commands_are_refused(self):
        self.refused("snapshot", "--app", "Notes")
        self.refused("find", "--app=Notes", "--role", "button")
        self.refused("snapshot", "--window-id", "w-10", "--headed")
        self.refused("click", "--headed", "@sABC123:e1")

    def test_a_ref_that_does_not_come_from_an_allowed_snapshot_is_refused(self):
        self.refused("click", "@sOTHER99:e1")
        self.refused("type", "@sOTHER99:e1", "x")
        self.refused("snapshot", "--window-id", "w-10", "--root", "@sOTHER99:e2")

    def test_verbs_that_reach_beyond_the_window_are_refused(self):
        for verb in ("launch", "close-app", "clipboard-get", "clipboard-set", "batch", "focus-window", "mouse-click",
                     "list-notifications", "key-down", "move-window", "session"):
            self.refused(verb, "x")
        self.refused()

    def test_snapshot_find_and_press_must_name_a_window(self):
        self.refused("snapshot")
        self.refused("find", "--role", "button")
        self.refused("press", "cmd+a")

    def test_desktop_wide_surfaces_are_refused(self):
        for s in ("desktop", "dock", "spotlight", "focused", "notification-center"):
            self.refused("snapshot", "--window-id", "w-10", "--surface", s)
        self.assertEqual(self.run_guard("snapshot", "--window-id", "w-10", "--surface", "menubar")[0], 0)

    def test_list_windows_only_shows_the_tasks_windows(self):
        rc, out = self.run_guard("list-windows")
        self.assertEqual([w["id"] for w in out["data"]], ["w-10"])

    def test_without_a_task_file_it_refuses_everything(self):
        os.remove(self.gf)
        self.refused("snapshot", "--window-id", "w-10")


if __name__ == "__main__":
    unittest.main()
