import os
import tempfile
import threading
import unittest

import support
import harness
from benchlib import agents, host, tasks

TASKS = tasks.load_tasks(os.path.join(support.BENCH, "tasks"))
STATE = {"agentWorkspace": 9, "workspaces": {"9": []}}


class SkyNeverRunsOnTheHost(unittest.TestCase):
    """Decision of 2026-11-01: ChatGPT's computer use runs only inside the sandbox VM, never on Donovan's Mac,
    at every level. No flag or environment variable changes that."""

    def test_every_task_is_unavailable_for_chatgpt_on_the_host(self):
        for t in TASKS:
            why = host.availability(t, STATE, "chatgpt", installed_fn=lambda a: True, running_fn=lambda a: False)
            self.assertIn("needs sandbox", why, t["id"])

    def test_no_environment_variable_or_flag_changes_that(self):
        names = ["BENCH_ALLOW_SKY_HOST", "BENCH_CHATGPT_HOST", "BENCH_SANDBOX", "BENCH_ALLOW_HOST", "BENCH_AGENT_BROWSER_PROFILE", "CODEX_HOME"]
        old = {n: os.environ.get(n) for n in names}
        os.environ.update({n: "1" for n in names})
        old_sb, old_route = host.SANDBOX_AVAILABLE, host.CHATGPT_ROUTE
        try:
            self.assertIn("needs sandbox", host.availability(TASKS[0], STATE, "chatgpt", installed_fn=lambda a: True))
            host.SANDBOX_AVAILABLE = True                 # even a sandbox with no ChatGPT route is not a way in
            for t in TASKS:
                self.assertIn("needs sandbox", host.availability(t, STATE, "chatgpt", installed_fn=lambda a: True,
                                                                  running_fn=lambda a: False), t["id"])
            with self.assertRaises(agents.SandboxOnly):
                agents.codex_command("p", "codex", "/x/.mcp.json", "/cwd")
        finally:
            host.SANDBOX_AVAILABLE, host.CHATGPT_ROUTE = old_sb, old_route
            for n, v in old.items():
                os.environ.pop(n, None) if v is None else os.environ.__setitem__(n, v)

    def test_the_command_cannot_be_built_without_a_sandbox_route(self):
        with self.assertRaises(agents.SandboxOnly):
            agents.codex_command("p", "codex", "/x/.mcp.json", "/cwd", disable=["a"])

    def test_the_agent_doing_for_chatgpt_refuses_to_run(self):
        doing = harness.make_doing("agent", "chatgpt", {"baneyspaces": "b", "agent_desktop": "a", "claude": "c", "codex": "x"}, None, "/w", "/c")
        with self.assertRaises(agents.SandboxOnly):
            doing({}, {}, {})

    def test_no_chatgpt_task_ever_reaches_run_task_work_or_opens_a_window(self):
        calls = []

        class Opener:
            def open(self, *a, **k):
                calls.append("open")
                return 1, 1

            def supports_profile(self):
                return True

        from benchlib.runner import Context, run_task
        from test_runner import FakeMonitor
        from support import FakeDriver, fake_exec
        st = harness.RunState(threading.Event(), lambda: 9999)
        with tempfile.TemporaryDirectory() as d:
            ctx = Context(tool="chatgpt", workdir=d, server=type("S", (), {"base": "b", "port": 1, "reset": lambda s: None})(),
                          monitor=FakeMonitor(), opener=Opener(), referee_driver=FakeDriver({}), exec_fn=fake_exec([]),
                          doing=lambda *a: calls.append("doing"), availability_fn=host.availability, state_fn=lambda: STATE,
                          running_fn=lambda a: False)
            recs, _ = harness.run_group(TASKS, {"chatgpt": ctx}, st, run_task_fn=run_task)
        self.assertEqual(calls, [])
        self.assertEqual({r["status"] for r in recs["chatgpt"]}, {"unavailable"})
        self.assertEqual(len(recs["chatgpt"]), 30)

    def test_micro_for_chatgpt_is_n_a_before_anything_opens(self):
        opened = []
        from benchlib.runner import Context
        from test_runner import FakeMonitor
        from support import FakeDriver, fake_exec

        class Opener:
            def open(self, *a, **k):
                opened.append(a)
                return 1, 1

            def windows(self):
                return {}

        with tempfile.TemporaryDirectory() as d:
            ctx = Context(tool="chatgpt", workdir=d, server=type("S", (), {"base": "b", "port": 1, "reset": lambda s: None})(),
                          monitor=FakeMonitor(), opener=Opener(), referee_driver=FakeDriver({}), exec_fn=fake_exec([]),
                          doing=harness.micro_doing("chatgpt", {"baneyspaces": "b", "agent_desktop": "a"}, None),
                          state_fn=lambda: STATE, running_fn=lambda a: False)
            got = harness.run_micro_level("chatgpt", ctx)
        self.assertEqual(got["status"], "n/a")
        self.assertIn("needs sandbox", got["why"])
        self.assertEqual(opened, [])

    def test_the_headed_column_is_sandbox_only_too(self):
        """first-F7: --headed posts real keys and clicks onto the live session"""
        for t in TASKS:
            why = host.availability(t, STATE, "agent-desktop-headed", installed_fn=lambda a: True, running_fn=lambda a: False)
            self.assertIn("sandbox_only", why, t["id"])
        te = next(t for t in TASKS if t["id"] == "textedit-type")
        self.assertIsNone(host.availability(te, STATE, "agent-desktop", installed_fn=lambda a: True, running_fn=lambda a: False))
        self.assertIsNone(host.availability(te, STATE, "baneyspaces", installed_fn=lambda a: True, running_fn=lambda a: False))

    def test_the_harness_has_no_other_path_to_codex_or_sky(self):
        src = open(os.path.join(support.BENCH, "harness.py")).read()
        self.assertNotIn("codex_command(", src)
        self.assertNotIn("chatgpt_micro.mjs", src)
        mic = open(os.path.join(support.BENCH, "benchlib", "micro.py")).read()
        self.assertNotIn("chatgpt_micro", mic)

    def test_the_column_is_still_listed_and_resolved_by_the_dry_run(self):
        self.assertIn("chatgpt", harness.LEVEL_TOOLS["agent"])
        self.assertIn("chatgpt", harness.LEVEL_TOOLS["micro"])


if __name__ == "__main__":
    unittest.main()
