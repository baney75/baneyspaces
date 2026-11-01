"""The agent level, end to end, with fake tools in a fresh temp dir.

The unit tests build their own contexts and never run `_run_levels`, which is where two crash-level bugs hid
(make_doing wrote its MCP config into a column directory that did not exist yet, in a fresh run directory).
This drives the real `_run_levels` -> `run_group` -> `run_task` -> `make_doing` chain with fake `baneyspaces`,
`agent-desktop`, `claude` and system commands on PATH, starting from nothing but an empty temp directory.
"""
import argparse
import json
import os
import stat
import sys
import tempfile
import threading
import unittest

import support
import harness
from benchlib import host, report

FAKE_BS = r'''#!{py}
import json, os, sys
S = os.environ["BENCH_FAKE_STATE"]
def load():
    return json.load(open(S)) if os.path.exists(S) else {{"next": 100, "windows": {{}}}}
def save(d):
    json.dump(d, open(S, "w"))
a = sys.argv[1:]
d = load()
if a[:1] == ["--version"]:
    print("baneyspaces fake")
elif a[:2] == ["agent", "status"]:
    print("agent workspace: 9 (you're on 1)")
    for wid, w in sorted(d["windows"].items(), key=lambda kv: int(kv[0])):
        print("  %s\t%s\t%s" % (wid, w["app"], w["title"]))
    if not d["windows"]:
        print("  no windows there yet")
elif a[:2] == ["agent", "windows"]:
    print(json.dumps({{"ok": True, "data": {{"windows": [{{"id": int(k), "pid": v["pid"], "app": v["app"]}} for k, v in d["windows"].items()]}}}}))
elif a[:2] == ["agent", "open"] and len(a) > 2:
    app = a[2]
    files = [x for x in a[3:] if not x.startswith("-")]
    wid = d["next"]; d["next"] += 1
    title = os.path.basename(files[0]) if files else app
    value = open(files[0]).read() if files and os.path.exists(files[0]) else ""
    d["windows"][str(wid)] = {{"app": app, "title": title, "value": value, "pid": 2000000000 + wid}}
    save(d)
    print(json.dumps({{"ok": True, "data": {{"app": app, "window": wid}}}}))
else:
    print("usage: baneyspaces agent open <app> [file]")
    sys.exit(1)
'''

FAKE_AD = r'''#!{py}
import json, os, sys
S = os.environ["BENCH_FAKE_STATE"]
def load():
    return json.load(open(S)) if os.path.exists(S) else {{"next": 100, "windows": {{}}}}
a = sys.argv[1:]
d = load()
def err(code, msg, sug):
    print(json.dumps({{"ok": False, "error": {{"code": code, "message": msg, "retry": "safe", "suggestion": sug}}}}))
    sys.exit(1)
if a[:1] == ["--version"]:
    print("agent-desktop 1.0.2")
elif a[:1] == ["snapshot"]:
    wid = a[a.index("--window-id") + 1].replace("w-", "")
    surface = a[a.index("--surface") + 1] if "--surface" in a else "window"
    w = d["windows"].get(wid)
    if not w:
        err("WINDOW_NOT_FOUND", "No window with id w-" + wid, "Run list-windows.")
    if surface in ("sheet", "alert"):
        err("SURFACE_NOT_FOUND", "no sheet", "none")
    tree = {{"role": "window", "name": w["title"], "children": [
        {{"role": "textfield", "value": w["value"], "ref_id": "@sw%s:e1" % wid}},
        {{"role": "button", "name": "Close", "ref_id": "@sw%s:e2" % wid}}]}}
    print(json.dumps({{"ok": True, "data": {{"snapshot_id": "sw" + wid, "tree": tree}}}}))
elif a[:1] == ["click"]:
    ref = a[-1]
    wid = ref[3:].split(":")[0]
    if ref.endswith(":e2"):
        import fcntl
        d["windows"].pop(wid, None)
        json.dump(d, open(S, "w"))
    print(json.dumps({{"ok": True, "data": {{}}}}))
elif a[:1] == ["list-windows"]:
    app = a[a.index("--app") + 1]
    print(json.dumps({{"ok": True, "data": [{{"id": "w-" + k, "pid": v["pid"], "app_name": app}} for k, v in d["windows"].items() if v["app"] == app]}}))
else:
    print(json.dumps({{"ok": True, "data": {{}}}}))
'''

FAKE_CLAUDE = r'''#!{py}
import json, os, re, sys
S = os.environ["BENCH_FAKE_STATE"]
a = sys.argv[1:]
if a[:1] == ["--version"]:
    print("claude 0.0 fake"); sys.exit(0)
prompt = a[a.index("-p") + 1]
if "--mcp-config" in a and not os.path.exists(a[a.index("--mcp-config") + 1]):
    print("mcp config missing", file=sys.stderr); sys.exit(2)
m = re.search(r"window id (\d+)", prompt)
if m:
    d = json.load(open(S))
    if m.group(1) in d["windows"]:
        d["windows"][m.group(1)]["value"] = "Hello from the bench"
        json.dump(d, open(S, "w"))
ev = [{{"type": "system", "subtype": "init", "mcp_servers": [{{"name": "baneyspaces", "status": "connected"}}]}},
      {{"type": "assistant", "message": {{"content": [{{"type": "tool_use", "id": "t1", "name": "mcp__baneyspaces__type", "input": {{}}}}]}}}},
      {{"type": "user", "message": {{"content": [{{"type": "tool_result", "tool_use_id": "t1", "content": "{{\"ok\":true}}", "is_error": False}}]}}}},
      {{"type": "result", "is_error": False, "num_turns": 2, "total_cost_usd": 0.01, "result": "DONE typed it"}}]
for e in ev:
    print(json.dumps(e))
'''


def script(path, body):
    with open(path, "w") as fh:
        fh.write(body.format(py=sys.executable) if "{py}" in body else body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)


class FakeMonitor:
    tap_ok = True
    losses = []

    def __init__(self):
        self.unhealthy = False

    def healthy(self):
        return (False, "sampler exited") if self.unhealthy else (True, "")

    def changes(self, *a, **k):
        return []

    def input(self, *a, **k):
        return 0, 0, {}

    def lost_between(self, *a, **k):
        return []

    def user_pids_now(self):
        return frozenset()

    def session_ok(self):
        return True, {}

    def real_idle(self):
        return 9999.0

    def wait_sampled(self, *a, **k):
        return True

    def health(self):
        return {"interval_ms": 50, "samples": 1, "max_gap_ms": 50, "losses": [], "tap_ok": True}


class Awake:
    def terminate(self):
        pass


class AgentLevelEndToEnd(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="e2e-")
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.bin)
        self.handoff = os.path.join(self.root, "handoff")
        os.makedirs(self.handoff)
        self.results = os.path.join(self.root, "results")
        script(os.path.join(self.bin, "baneyspaces"), FAKE_BS)
        script(os.path.join(self.bin, "agent-desktop"), FAKE_AD)
        script(os.path.join(self.bin, "claude"), FAKE_CLAUDE)
        script(os.path.join(self.bin, "codex"), "#!/bin/sh\necho codex fake\n")
        for name in ("osascript", "kill", "defaults"):
            script(os.path.join(self.bin, name), "#!/bin/sh\nexit 0\n")
        script(os.path.join(self.bin, "pgrep"), "#!/bin/sh\nexit 1\n")
        script(os.path.join(self.bin, "plutil"), "#!/bin/sh\nexit 1\n")
        script(os.path.join(self.bin, "sw_vers"), "#!/bin/sh\necho 27.2\n")
        self.saved = (os.environ.get("PATH"), os.environ.get("BENCH_FAKE_STATE"), host.installed, host.read_state, host.hold_awake,
                      host.HANDOFF, harness.TOOLS_DIR)
        os.environ["PATH"] = self.bin + os.pathsep + os.environ["PATH"]
        os.environ["BENCH_FAKE_STATE"] = os.path.join(self.root, "state.json")
        host.installed = lambda app, **k: True
        self.kwdefaults = dict(host.availability.__kwdefaults__)
        host.availability.__kwdefaults__["installed_fn"] = lambda app, **k: True        # bound at definition time
        host.read_state = lambda *a, **k: {"agentWorkspace": 9, "workspaces": {"9": []}}
        host.hold_awake = lambda budget, **k: Awake()
        host.HANDOFF = self.handoff
        harness.TOOLS_DIR = self.root

    def tearDown(self):
        host.availability.__kwdefaults__.update(self.kwdefaults)
        path, st, host.installed, host.read_state, host.hold_awake, host.HANDOFF, harness.TOOLS_DIR = self.saved
        os.environ["PATH"] = path
        os.environ.pop("BENCH_FAKE_STATE", None) if st is None else os.environ.__setitem__("BENCH_FAKE_STATE", st)

    def paths(self):
        b = lambda n: os.path.join(self.bin, n)
        return {"baneyspaces": b("baneyspaces"), "agent_desktop": b("agent-desktop"), "claude": b("claude"), "codex": b("codex"),
                "sampler": "unused", "sampler_src": "unused"}

    def run_levels(self, plan, mon=None, only=("textedit-type",)):
        abort = threading.Event()
        mon = mon or FakeMonitor()
        st = harness.RunState(abort, mon.real_idle, mon.session_ok)
        st.healthy_fn = mon.healthy
        args = argparse.Namespace(only=list(only), results_dir=self.results, date="2026-11-02")
        exec_fn = harness.Exec(abort=abort)
        tasks = harness.load(os.path.join(support.BENCH, "tasks"), list(only))
        code = harness._run_levels(args, self.paths(), tasks, plan, mon, st, abort, exec_fn, {})
        return code, st

    def results_of(self, level):
        return {r["tool"]: r for (t, lv), r in report.all_results_by_key(self.results).items() if lv == level} \
            if hasattr(report, "all_results_by_key") else {
            r["tool"]: r for _, r in report.all_results(self.results) if r["level"] == level}

    def test_a_fresh_run_directory_reaches_the_agent_level_without_crashing(self):
        """second-S1, sol-F1: make_doing used to write into a column directory nobody had created"""
        plan = [("agent", "baneyspaces"), ("agent", "agent-desktop")]
        code, st = self.run_levels(plan)
        self.assertEqual(code, 0, st.stop_reason)
        res = self.results_of("agent")
        self.assertEqual(set(res), {"baneyspaces", "agent-desktop"})
        for tool, r in res.items():
            rec = r["tasks"][0]
            self.assertEqual(rec["status"], "pass", (tool, rec))
            self.assertEqual(rec["tool_calls"], 1)
            self.assertNotIn("teardown_pending", rec)
        self.assertEqual(os.listdir(self.handoff), [])                  # the run directory is removed afterwards

    def test_make_doing_creates_the_directory_it_writes_into(self):
        """the exact shape _run_levels uses: a workdir that does not exist yet"""
        wd = os.path.join(self.root, "never-created", "agent-baneyspaces")
        harness.make_doing("agent", "baneyspaces", self.paths(), harness.Exec(), wd, self.root)
        self.assertTrue(os.path.exists(os.path.join(wd, "mcp-baneyspaces.json")))
        wd2 = os.path.join(self.root, "also-never", "agent-agent-desktop")
        harness.make_doing("agent", "agent-desktop", self.paths(), harness.Exec(), wd2, self.root)
        self.assertTrue(os.path.exists(os.path.join(wd2, "mcp-agent-desktop.json")))

    def test_the_scripted_and_micro_levels_also_run_from_nothing(self):
        plan = [("scripted", "baneyspaces"), ("scripted", "agent-desktop")]
        code, st = self.run_levels(plan)
        self.assertEqual(code, 0, st.stop_reason)
        res = self.results_of("scripted")
        self.assertEqual(set(res), {"baneyspaces", "agent-desktop"})
        for r in res.values():
            self.assertIn(r["tasks"][0]["status"], ("pass", "fail"), r["tasks"][0])     # ran; the fake agent-desktop has no type

    def test_a_monitor_that_dies_during_the_last_tasks_teardown_makes_the_run_aborted(self):
        """sol-F4"""
        mon = FakeMonitor()
        orig = harness.run_group

        def run_group(tasks, ctxs, st, **kw):
            for ctx in ctxs.values():
                real = ctx.doing

                def doing(t, w, ti, real=real):
                    out = real(t, w, ti)
                    mon.unhealthy = True            # the sampler dies right after the work, before teardown ends
                    return out
                ctx.doing = doing
            return orig(tasks, ctxs, st, **kw)
        harness.run_group = run_group
        try:
            code, st = self.run_levels([("agent", "baneyspaces")], mon=mon)
        finally:
            harness.run_group = orig
        self.assertEqual(code, harness.EXIT_USER_ACTIVE)
        res = self.results_of("agent")["baneyspaces"]
        self.assertIsNotNone(res["aborted"])
        self.assertFalse(res["full"])

    def test_an_interrupted_run_exits_with_the_stop_code_even_when_it_stopped_in_micro(self):
        """sonnet-F3: the micro level used to `continue` past the exit-code check"""
        abort = threading.Event()
        mon = FakeMonitor()
        st = harness.RunState(abort, mon.real_idle, mon.session_ok)
        st.healthy_fn = mon.healthy
        st.stop, st.stop_reason = True, "real input seen"
        args = argparse.Namespace(only=None, results_dir=self.results, date="2026-11-02")
        tasks = harness.load(os.path.join(support.BENCH, "tasks"), ["textedit-type"])
        code = harness._run_levels(args, self.paths(), tasks, [("micro", "baneyspaces")], mon, st, abort, harness.Exec(abort=abort), {})
        self.assertEqual(code, harness.EXIT_USER_ACTIVE)


if __name__ == "__main__":
    unittest.main()
