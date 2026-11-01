"""One task end to end: availability, setup, the monitored run, the read-back, teardown.

Time is cut into three half-open windows so no event is counted twice:
  setup [ts0, t0)   task [t0, tt0)   teardown [tt0, end)
The sampler reports a window that appeared without a workspace only after a one-second debounce, stamped with
when it first appeared, and BaneySpaces writes state.json a moment after a window exists. So every query waits
`drain_s` (longer than both) first: before t0, before tt0, before the early-return setup queries and before the
final teardown query. A change is charged to the tool unless its window belongs to a process that was already
running with a window on Donovan's workspaces before ts0 (his own background apps): those are ambient.
"""
import os
import secrets
import shutil
import time

from . import fixtures, host, scoring
from .cleanup import close_windows
from .execs import Aborted
from .monitor import TOOL_OWNERS, WINDOW_FIELDS, attribute
from .referee import Referee
from .tasks import expand

DESKTOP = os.path.expanduser("~/Desktop")
SYSTEM_APPS = {"Finder"}      # always running; never started or quit by a task


class Context:
    """Everything a task run needs; tests build one with fakes."""

    def __init__(self, *, tool, workdir, server, monitor, opener, referee_driver, exec_fn,
                 state_fn=None, doing=None, clock=time.time, sleep=time.sleep, watch_dirs=(DESKTOP,),
                 availability_fn=host.availability, running_fn=host.running, aborted_fn=lambda: False,
                 cleanup_driver=None, nonce_fn=lambda: secrets.token_hex(3), drain_s=1.5,
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
        self.drain_s = drain_s         # the sampler's debounce plus state.json lag, with margin
        self.session_fn = session_fn
        self.created_ever = set()      # every window id the bench has created this run (a leftover is ours, not foreign)


def _save_defaults(ctx, domains):
    """Capture preferences domains before an app we drive can change them. {domain: plist xml or None if absent}."""
    saved = {}
    for dom in domains:
        rc, out, _, _ = ctx.exec(["defaults", "export", dom, "-"], timeout=15)
        saved[dom] = out if rc == 0 and out.strip() else None
    return saved


def _restore_defaults(ctx, saved):
    for dom, xml in saved.items():
        if xml is None:
            ctx.exec(["defaults", "delete", dom], timeout=15)
        else:
            ctx.exec(["defaults", "import", dom, "-"], timeout=15, stdin=xml)


def run_task(task, ctx):
    rec = {"id": task["id"], "category": task["category"], "app": task["app"], "place": task.get("place", "host"),
           "impossible": bool(task.get("impossible"))}
    exp = task.get("expected_fail", {}).get(ctx.tool)
    if exp:
        rec["expected_fail"] = exp
    why = ctx.availability_fn(task, ctx.state_fn(), ctx.tool)
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
    if task["setup"].get("profile") and not ctx.opener.supports_profile():
        rec.update(status="unavailable", why="unavailable: needs `baneyspaces agent open --user-data-dir` (phase 3): a browser or "
                   "Electron app is launched only with a fresh profile, never with Donovan's")
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
    owners = {task["app"]} | apps | TOOL_OWNERS.get(ctx.tool, set())     # this column's own processes only
    allowed = set(task.get("allowed_change_fields", []))
    windows, titles, created, app_of = {}, {}, [], {}
    ambient = []
    saved_defaults = _save_defaults(ctx, setup.get("restore_defaults", []))
    ts0 = ctx.clock()
    ambient_pids = ctx.monitor.user_pids_now() if ctx.monitor else frozenset()
    tt0 = None

    def charge(changes):
        counted, amb = attribute(changes, owners, ambient_pids)
        ambient.extend(amb)
        return counted

    def drained(t_from):
        """Wait out the debounce, then take every change in [t_from, now)."""
        ctx.sleep(ctx.drain_s)
        now = ctx.clock()
        return now, (charge(ctx.monitor.changes(t_from, now, 0)) if ctx.monitor else [])

    try:
        try:
            profile_dir = os.path.join(tdir, "profile") if setup.get("profile") else None
            for o in setup.get("open", []):
                if profile_dir:
                    wid, _, verified = ctx.opener.open_isolated(o["app"], o.get("targets", []), profile_dir)
                    if wid is not None:
                        created.append(wid)         # tracked first, so teardown closes it even if it is not isolated
                        app_of[wid] = o["app"]
                    if wid is not None and not verified:
                        tt0, rec["setup_changes"] = drained(ts0)
                        rec.update(status="infra_error", why=f"setup: {o['app']} did not start with the fresh --user-data-dir; not using it")
                        return rec
                else:
                    wid, _ = ctx.opener.open(o["app"], o.get("targets", []))
                if wid is None:
                    tt0, rec["setup_changes"] = drained(ts0)
                    rec.update(status="infra_error", why=f"setup: could not open {o['app']} on the agent workspace")
                    return rec
                if wid not in created:
                    created.append(wid)
                app_of[wid] = o["app"]
                windows[o["as"]] = wid
                titles[o["as"]] = o.get("title", "")
            ctx.sleep(setup.get("settle_s", 0.8))

            # Ownership: every window we made is on the agent workspace, and the apps we started own no other window
            # (a restored session would be Donovan's documents inside the run).
            listing = ctx.opener.windows()
            lost_track = [w for w in created if w not in listing]
            foreign = [w for w, (a, _t) in listing.items()
                       if a in set(app_of.values()) and w not in created and w not in ctx.created_ever]
            if lost_track or foreign:
                tt0, rec["setup_changes"] = drained(ts0)
                rec.update(status="infra_error",
                           why=(f"setup: window {lost_track[0]} is not on the agent workspace" if lost_track else
                                f"setup: {listing[foreign[0]][0]} owns window {foreign[0]} that the bench did not create "
                                "(a restored or foreign window); not running"))
                return rec

            if setup.get("hide") and setup["hide"] in started_by_us:
                ctx.exec(["osascript", "-e", 'tell application "System Events" to set visible of process '
                          f'"{setup["hide"]}" to false'], timeout=15)
                ctx.sleep(0.4)
            for alias in setup.get("close_before_run", []):    # a window that existed and is gone: the "missing window" case
                closed, left = close_windows(ctx.cleanup_driver, [windows[alias]], ctx.opener.windows, should_stop=ctx.aborted_fn)
                if windows[alias] in left:
                    tt0, rec["setup_changes"] = drained(ts0)
                    rec.update(status="infra_error", why=f"setup: could not close window {windows[alias]} for the missing-window "
                               f"task ({left[windows[alias]]}); the tool is not run against a window that still exists")
                    return rec
                created = [w for w in created if w != windows[alias]]
            before = {d: host.list_dir(d) for d in ctx.watch_dirs}

            t0, rec["setup_changes"] = drained(ts0)
            leaks = [c for c in rec["setup_changes"] if set(c["fields"]) & set(WINDOW_FIELDS)]
            if leaks:
                tt0 = ctx.clock()
                rec.update(status="fail", why="setup leaked a window onto one of Donovan's workspaces; the tool was not run",
                           setup_leak=leaks)
                return rec
            outcome = ctx.doing(t, windows, titles)
            t1 = ctx.clock()
            ctx.sleep(ctx.drain_s)          # a dialog the last action raised 0.3 s later is reported ~1.3 s later
            tt0 = ctx.clock()

            rec["duration_s"] = round(t1 - t0, 3)
            rec["tool_ms"] = outcome.get("tool_ms")
            rec["steps"] = outcome.get("log", [])
            for k in ("model_turns", "cost_usd", "agent_text", "tool_calls", "tool_errors", "guard_refusals", "micro"):
                if outcome.get(k) is not None:
                    rec[k] = outcome[k]
            rec["answer"] = (outcome.get("answer") or "")[:300]
            changes = charge(ctx.monitor.changes(t0, tt0, 0)) if ctx.monitor else []
            intended = [c for c in changes if allowed and set(c["fields"]) <= allowed]
            rec["changes"] = [c for c in changes if c not in intended]
            if intended:
                rec["intended_changes"] = intended
            real, posted, by_pid = ctx.monitor.input(t0, tt0) if ctx.monitor else (0, 0, {})
            rec["hid_events"], rec["posted_input_events"] = real, posted
            if by_pid:
                rec["posted_input_by_pid"] = by_pid
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
            side = {"changes": len(rec["changes"]), "hid": real, "posted": posted, "collateral": len(rec["collateral"])}
            rec["status"] = scoring.classify(t, check_ok, outcome, outcome.get("refusal"), side)
            if not outcome["ok"] and not t.get("impossible"):
                rec["why"] = outcome.get("why", "")
            return rec
        except Aborted as e:
            tt0 = tt0 if tt0 is not None else ctx.clock()
            lost = ctx.monitor.losses[-1]["why"] if ctx.monitor and ctx.monitor.losses else None
            rec.update(status="monitor_lost" if lost else "not_run", why=f"stopped: {lost or e}")
            return rec
        except Exception as e:  # noqa: BLE001  whatever broke, the finally block's accounting must reach the result file
            tt0 = tt0 if tt0 is not None else ctx.clock()
            rec.update(status="infra_error", why=f"{type(e).__name__}: {e}"[:300])
            return rec
    finally:
        tt0 = tt0 if tt0 is not None else ctx.clock()
        pending = {"windows": [], "apps": [], "defaults": []}
        notes = []
        try:
            if ctx.aborted_fn():
                pending = {"windows": list(created), "apps": list(started_by_us), "defaults": list(saved_defaults)}
            else:
                left = {}
                if created:
                    _, left = close_windows(ctx.cleanup_driver, created, ctx.opener.windows, should_stop=ctx.aborted_fn)
                    if left:
                        rec["teardown_left"] = {str(k): v for k, v in left.items()}
                        pending["windows"] = [k for k, v in left.items() if v.startswith(("interrupted", "cannot tell", "still open"))]
                for app in started_by_us:
                    if ctx.aborted_fn():
                        pending["apps"].append(app)
                        continue
                    # An app is quit only if it is ours and NOTHING of it is left outside the verified scope: a window
                    # that stayed open, moved off the agent workspace, or one the bench did not create would die with it.
                    try:
                        now_windows = ctx.opener.windows()
                    except Exception:  # noqa: BLE001
                        now_windows = None
                    still = [w for w, (a, _t) in (now_windows or {}).items() if a == app]
                    kept = [w for w, why in left.items() if app_of.get(w) == app]
                    if now_windows is None or still or kept:
                        pending["apps"].append(app)
                        notes.append(f"{app} not quit: " + ("its windows could not be listed" if now_windows is None else
                                                          f"windows {sorted(set(still) | set(kept))} are still open"))
                    elif ctx.running_fn(app):
                        ctx.exec(["osascript", "-e", f'tell application "{app}" to quit'], timeout=15)
                if saved_defaults:
                    _restore_defaults(ctx, saved_defaults)
        except Aborted:
            pending = {"windows": list(created), "apps": list(started_by_us), "defaults": list(saved_defaults)}
        except Exception as e:  # noqa: BLE001  a broken cleanup tool must not hide the record or skip the accounting below
            pending = {"windows": list(created), "apps": list(started_by_us), "defaults": list(saved_defaults)}
            notes.append(f"{type(e).__name__}: {e}"[:200])
        if any(pending.values()) or notes:
            rec["teardown_pending"] = {k: v for k, v in pending.items() if v}
            rec["teardown_pending"]["note"] = "teardown did not finish; these were left for manual recovery"
            if notes:
                rec["teardown_pending"]["error"] = "; ".join(notes)
        # a dialog or window raised by teardown itself is reported a second later: wait it out, then take the window
        ctx.sleep(ctx.drain_s)
        if ctx.monitor:
            rec["teardown_changes"] = charge(ctx.monitor.changes(tt0, ctx.clock(), 0))
        if ambient:
            rec["ambient_changes"] = ambient
        ctx.created_ever.update(created)
        shutil.rmtree(tdir, ignore_errors=True)
