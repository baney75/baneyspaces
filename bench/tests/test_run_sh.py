import os
import subprocess
import tempfile
import unittest

import support

RUN = os.path.join(support.BENCH, "run.sh")


def fake_ioreg(bindir, seconds):
    path = os.path.join(bindir, "ioreg")
    with open(path, "w") as fh:
        fh.write(f'#!/bin/sh\necho \'    | |   "HIDIdleTime" = {int(seconds * 1e9)}\'\nfor i in 1 2 3; do echo more; done\n')
    os.chmod(path, 0o755)


class IdleGate(unittest.TestCase):
    def run_it(self, seconds, *args):
        with tempfile.TemporaryDirectory() as d:
            fake_ioreg(d, seconds)
            env = dict(os.environ, PATH=d + os.pathsep + os.environ["PATH"], BENCH_BANEYSPACES="/bin/echo")
            return subprocess.run([RUN, *args], capture_output=True, text=True, env=env, timeout=60)

    def test_active_user_exits_3_with_the_message_and_does_nothing(self):
        r = self.run_it(4.2, "--tool", "baneyspaces", "--level", "scripted")
        self.assertEqual(r.returncode, 3)
        self.assertIn("not run: user active", r.stdout)
        self.assertIn("4 s", r.stdout)

    def test_just_under_ten_minutes_is_still_active(self):
        self.assertEqual(self.run_it(599, "--tool", "baneyspaces").returncode, 3)

    def test_dry_run_needs_no_idle_machine(self):
        r = self.run_it(1, "--dry-run", "--tool", "baneyspaces", "--level", "scripted")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("30 tasks", r.stdout)


if __name__ == "__main__":
    unittest.main()
