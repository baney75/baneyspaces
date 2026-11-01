"""One task end to end: availability, setup, the monitored run, the read-back, teardown.

Time is cut into three half-open windows so no event is counted twice:
  setup [ts0, t0)   task [t0, tt0)   teardown [tt0, end+settle)
A window change is charged to the tool only when its owner app is one the task opened or one of the
tool's own processes; Donovan's background apps are recorded as ambient and never scored.
"""
import os
import secrets
import shutil
import time

from . import fixtures, host, scoring
from .cleanup import close_windows
from .execs import Aborted
from .monitor import SETTLE_S, attribute
from .referee import Referee
from .tasks import expand

DESKTOP = os.path.expanduser("~/Desktop")
SYSTEM_APPS = {"Finder"}      # always running; never started or quit by a task


class Context:
    """Everything a task run needs; tests build one with fakes."""

    def __init__(self, *, tool, workdir, server, monitor, opener, referee_driver, exec_fn,
                 state_fn=None, doing=None, clock=time.time, sleep=time.sleep, watch_dirs=(DESKTOP,),
                 availability_fn=host.availability, running_fn=host.running, aborted_fn=lambda: False,
                 cleanup_driver=None, nonce_fn=lambda: secrets.token_hex(3), settle_s=1.2,
                 session_fn=lambda: (True, {})):
        self.tool, self.workdir, self.server, self.monitor = tool, workdir, server, monitor
        self.opener, self.referee_driver, self.exec = opener, referee_driver, exec_fn
        self.cleanup_driver = cleanup_driver or referee_driver
        self.state_fn = state_fn or (lambda: None)
        self.doing = doing   # callable(task, windows, titles) -> outcome dict
        self.clock, self.sleep = clock, sleep
        self.watch_dirs = watch_dirs
        self.availability_fn, self.running_fn, self.aborted_fn = availability_fn, running_fn, aborted_fn
        self.nonce_fn = nonce_fn
        self.settle_s = settle_s       # window events are debounced a second by the sampler
        self.session_fn = session_fn


def run_task(task, ctx):
    rec = {"id": task["id"], "category": task["category"], "app": task["app"], "place": task.get("place", "host"),
           "impossible": bool(task.get("impossible"))}
    exp = task.get("expected_fail", {}).get(ctx.tool)
    if exp:
        rec["expected_fail"] = exp
    why = ctx.availability_fn(task, ctx.state_fn())
    if why:
        rec.update(status="unavailable", why=why)
        return rec
    healthy, mwhy = ctx.monitor.healthy() if ctx.monitor else (True, "")
    if not healthy:
        rec.update(status="monitor_lost", why=f"not started: {mwhy}")
        return rec
    ok, sess = ctx.session_fn()
    if not ok:
        rec.update(status="not_run", why=host.session_gate(ok, sess)[1][:200])
        return rec

    tdir = os.path.join(ctx.workdir, task["id"])
    os.makedirs(tdir, exist_ok=True)
    env = {"tmp": tdir, "base": ctx.server.base, "port": ctx.server.port, "fixtures": tdir, "nonce": ctx.nonce_fn()}
    t = expand(task, env)
    setup = t["setup"]
    fixtures.write_files(tdir, setup.get("files", {}))
    ctx.server.reset()
    missing = [x for o in setup.get("open", []) for x in o.get("targets", [])
               if x.startswith(tdir) and not os.path.exists(x)]
    if missing:
        rec.update(status="infra_error", why="setup: the fixture is not at the path the task opens: " + missing[0])
        shutil.rmtree(tdir, ignore_errors=True)
        return rec

    apps = {o["app"] for o in setup.get("open", [])} | set(setup.get("quit_after", []))
    was_running = {a: ctx.running_fn(a) for a in apps if a not in SYSTEM_APPS}
    started_by_us = sorted(a for a, up in was_running.items() if not up)
    owners = {task["app"]} | apps
    allowed = set(task.get("allowed_change_fields", []))
    windows, titles, created = {}, {}, []
    ambient = []

    def charge(changes):
        counted, amb = attribute(changes, owners)
        ambient.extend(amb)
        return counted

    ts0, tt0 = ctx.clock(), None
    try:
        try:
            for o in setup.get("open", []):
                wid, _ = ctx.opener.open(o["app"], o.get("targets", []))
                if wid is None:
                    tt0 = ctx.clock()
                    rec["setup_changes"] = charge(ctx.monitor.changes(ts0, tt0, 0)) if ctx.monitor else []
                    rec.update(status="infra_error", why=f"setup: could not open {o['app']} on the agent workspace")
                    return rec
                created.append(wid)
                windows[o["as"]] = wid
                titles[o["as"]] = o.get("title", "")
            ctx.sleep(setup.get("settle_s", 0.8))
            if setup.get("hide") and setup["hide"] in started_by_us:
                ctx.exec(["osascript", "-e", 'tell application "System Events" to set visible of process '
                          f'"{setup["hide"]}" to false'], timeout=15)
                ctx.sleep(0.4)
            before = {d: host.list_dir(d) for d in ctx.watch_dirs}

            t0 = ctx.clock()
            rec["setup_changes"] = charge(ctx.monitor.changes(ts0, t0, 0)) if ctx.monitor else []
            outcome = ctx.doing(t, windows, titles)
            t1 = ctx.clock()
            ctx.sleep(ctx.settle_s)
            tt0 = ctx.clock()

            rec["duration_s"] = round(t1 - t0, 3)
            rec["tool_ms"] = outcome.get("tool_ms")
            rec["steps"] = outcome.get("log", [])
            for k in ("model_turns", "cost_usd", "agent_text", "tool_calls", "tool_errors"):
                if outcome.get(k) is not None:
                    rec[k] = outcome[k]
            rec["answer"] = (outcome.get("answer") or "")[:300]
            changes = charge(ctx.monitor.changes(t0, tt0, 0)) if ctx.monitor else []
            intended = [c for c in changes if allowed and set(c["fields"]) <= allowed]
            rec["changes"] = [c for c in changes if c not in intended]
            if intended:
                rec["intended_changes"] = intended
            real, posted = ctx.monitor.input(t0, tt0) if ctx.monitor else (0, 0)
            rec["hid_events"], rec["posted_input_events"] = real, posted
            rec["collateral"] = [f"{d}/{n}" for d in ctx.watch_dirs for n in host.collateral(before[d], host.list_dir(d))]
            rec["refusal"] = outcome.get("refusal")

            lost = ctx.monitor.lost_between(t0, tt0) if ctx.monitor else []
            if lost:
                rec.update(status="monitor_lost", why=lost[0]["why"])
                return rec
            if outcome.get("infra") or outcome.get("harness_error"):
                rec.update(status="infra_error", why=outcome.get("infra") or outcome.get("why", "harness error"))
                if outcome.get("fatal_infra"):
                    rec["fatal_infra"] = True
                return rec
            if outcome.get("shortcut"):
                rec.update(status="fail", why="used a shell or another tool instead of computer use: " + str(outcome["shortcut"])[:120])
                return rec

            referee = Referee(ctx.referee_driver.snapshot, windows, ctx.server, answer=outcome.get("answer", ""))
            check_ok, detail = referee.evaluate(t["check"])
            if (t.get("requires_tool_call") or t.get("impossible")) and not outcome.get("tool_calls") and not outcome.get("tool_errors"):
                check_ok, detail = False, "no computer-use call was made; " + detail
            rec["check"] = {"ok": check_ok, "detail": detail}
            side = {"changes": len(rec["changes"]), "hid": real, "collateral": len(rec["collateral"])}
            rec["status"] = scoring.classify(t, check_ok, outcome, outcome.get("refusal"), side)
            if not outcome["ok"] and not t.get("impossible"):
                rec["why"] = outcome.get("why", "")
            return rec
        except Aborted as e:
            tt0 = tt0 if tt0 is not None else ctx.clock()
            lost = ctx.monitor.losses[-1]["why"] if ctx.monitor and ctx.monitor.losses else None
            rec.update(status="monitor_lost" if lost else "not_run", why=f"stopped: {lost or e}")
            return rec
    finally:
        tt0 = tt0 if tt0 is not None else ctx.clock()
        pending_windows, pending_apps = [], []
        try:
            if ctx.aborted_fn():
                pending_windows, pending_apps = list(created), list(started_by_us)
            else:
                if created:
                    _, left = close_windows(ctx.cleanup_driver, created, ctx.opener.windows, should_stop=ctx.aborted_fn)
                    if left:
                        rec["teardown_left"] = {str(k): v for k, v in left.items()}
                        pending_windows = [k for k, v in left.items() if v.startswith("interrupted")]
                for app in started_by_us:     # only an app this task started, and only if it is up now
                    if ctx.aborted_fn():
                        pending_apps.append(app)
                    elif ctx.running_fn(app):
                        ctx.exec(["osascript", "-e", f'tell application "{app}" to quit'], timeout=15)
        except Aborted:
            pending_windows, pending_apps = list(created), list(started_by_us)
        if pending_windows or pending_apps:
            rec["teardown_pending"] = {"windows": pending_windows, "apps": pending_apps,
                                       "note": "the run was aborted before teardown finished; these were left on the agent workspace"}
        if ctx.monitor:
            rec["teardown_changes"] = charge(ctx.monitor.changes(tt0, ctx.clock(), SETTLE_S))
        if ambient:
            rec["ambient_changes"] = ambient
        shutil.rmtree(tdir, ignore_errors=True)
