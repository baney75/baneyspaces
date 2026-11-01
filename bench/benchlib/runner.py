"""One task end to end: availability, setup, the monitored run, the read-back, teardown.

Time is cut into three half-open windows by stamp, so no event is counted twice:
  setup [ts0, t0)   task [t0, tt0)   teardown [tt0, T_end)
The sampler reports a window that appeared without a workspace only after a one-second debounce, stamped with
when it first appeared, and BaneySpaces writes state.json a moment after a window exists. So nothing is assigned
to a window at the moment that window closes. The setup-leak gate waits until the sampler has published a sample
stamped `drain_s` past its query point, and the three windows are RECOMPUTED from the full event log after
teardown, once the sampler has gone `drain_s` past T_end. A window that shows up only in that late pass and was
first seen before t0 invalidates the task (`infra_error`, `setup_leak`): the tool must not be charged for it, and
the task cannot count as clean. Classification (pass, fail, refused_ok) waits for the final windows.
A change is charged to the tool unless its window belongs to a process that was already running with a window
on Donovan's workspaces before ts0 (his own background apps): those are ambient.
"""
import os
import re
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
QUIT_WAIT_S = 5.0


class Context:
    """Everything a task run needs; tests build one with fakes."""

    def __init__(self, *, tool, workdir, server, monitor, opener, referee_driver, exec_fn,
                 state_fn=None, doing=None, clock=time.time, sleep=time.sleep, watch_dirs=(DESKTOP,),
                 availability_fn=host.availability, running_fn=host.running, aborted_fn=lambda: False,
                 cleanup_driver=None, nonce_fn=lambda: secrets.token_hex(3), drain_s=1.5,
                 session_fn=lambda: (True, {}), quiet_exec=None, alive_fn=host.pid_alive, recovery_dir=None):
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
        self.quiet_exec = quiet_exec   # commands that touch no window and must still run after an abort (defaults, kill)
        self.alive_fn = alive_fn
        self.recovery_dir = recovery_dir
        self.created_ever = set()      # every window id the bench has created this run (a leftover is ours, not foreign)
        self.blocked_domains = {}      # preferences domain -> {"recovery", "command"}: a restore failed; no task may touch it again

    def qexec(self, *a, **k):
        return (self.quiet_exec or self.exec)(*a, **k)

    def wait_reports(self, q):
        """Return once everything that happened before `q` has been reported: the sampler has published a sample
        stamped `drain_s` past q (its debounce is a second, state.json lags a little)."""
        wait = getattr(self.monitor, "wait_sampled", None)
        if wait:
            wait(q + self.drain_s, timeout=self.drain_s + 10)
        else:
            self.sleep(self.drain_s)


def _save_defaults(ctx, domains, recovery_dir):
    """Back up preferences domains before an app we drive can change them.
    -> ({domain: plist xml, or None when the domain is CONFIRMED absent}, problem or None).
    Any other outcome (a timeout, a failure, empty output) is uncertain: the task is not run, because a wrong
    guess would later delete or overwrite Donovan's preferences."""
    saved = {}
    for dom in domains:
        rc, out, err, _ = ctx.qexec(["defaults", "export", dom, "-"], timeout=15)
        if rc == 0 and out.strip():
            saved[dom] = out
            if recovery_dir:
                os.makedirs(recovery_dir, exist_ok=True)
                path = os.path.join(recovery_dir, f"{dom}.plist")
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write(out)
        elif rc != 0 and re.search(r"does not exist", f"{err}\n{out}"):
            saved[dom] = None
        else:
            return {}, f"could not back up {dom} (defaults export rc {rc}: {(err or out or 'no output').strip()[:100]})"
    return saved, None


def _restore_defaults(ctx, saved, recovery_dir):
    """Put the backed-up domains back and check it. -> list of problems (empty: restored and verified; the recovery
    file is then removed, otherwise it stays for manual recovery)."""
    problems = []
    for dom, xml in saved.items():
        if xml is None:
            rc, out, err, _ = ctx.qexec(["defaults", "delete", dom], timeout=15)
            if rc != 0 and not re.search(r"does not exist", f"{err}\n{out}"):
                problems.append(f"{dom}: delete failed (rc {rc})")
            continue
        rc, out, err, _ = ctx.qexec(["defaults", "import", dom, "-"], timeout=15, stdin=xml)
        if rc != 0:
            problems.append(f"{dom}: import failed (rc {rc}: {(err or out).strip()[:80]})")
            continue
        rc2, now, _e, _ = ctx.qexec(["defaults", "export", dom, "-"], timeout=15)
        if rc2 != 0 or now.strip() != xml.strip():
            problems.append(f"{dom}: after the import the domain does not match the backup")
    if not problems and recovery_dir:
        for dom in saved:
            try:
                os.remove(os.path.join(recovery_dir, f"{dom}.plist"))
            except OSError:
                pass
    return problems


def _wait_gone(ctx, pid, seconds=QUIT_WAIT_S):
    end = ctx.clock() + seconds
    while ctx.alive_fn(pid):
        if ctx.clock() >= end:
            return False
        ctx.sleep(0.2)
    return True


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

    # A preferences domain whose restore failed earlier in this run is off limits: running another task that changes it
    # would bury the unresolved backup, and the next failure could overwrite what is left of Donovan's settings.
    blocked = [d for d in task["setup"].get("restore_defaults", []) if d in ctx.blocked_domains]
    if blocked:
        info = ctx.blocked_domains[blocked[0]]
        rec.update(status="infra_error", why=f"setup: the preferences {blocked[0]} were not restored after an earlier task; "
                   f"tasks that change them stop for the rest of the run. Recover with: {info['command']}")
        return rec
    # Back up preferences first. If the backup is uncertain nothing else is touched. Every invocation gets a directory
    # of its own: an unresolved backup is never replaced.
    recovery_dir = os.path.join(ctx.recovery_dir, f"{task['id']}-{secrets.token_hex(3)}") if ctx.recovery_dir else None
    saved_defaults, problem = _save_defaults(ctx, task["setup"].get("restore_defaults", []), recovery_dir)
    if problem:
        rec.update(status="infra_error", why="setup: " + problem + "; the task is not run")
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
        _restore_defaults(ctx, saved_defaults, recovery_dir)
        return rec

    apps = {o["app"] for o in setup.get("open", [])} | set(setup.get("quit_after", []))
    not_running_req = set(setup.get("requires", {}).get("not_running", []))
    was_running = {a: ctx.running_fn(a) for a in apps if a not in SYSTEM_APPS}
    owners = {task["app"]} | apps | TOOL_OWNERS.get(ctx.tool, set())     # this column's own processes only
    allowed = set(task.get("allowed_change_fields", []))
    windows, titles, created, app_of, pid_of_wid = {}, {}, [], {}, {}
    ts0 = ctx.clock()
    ambient_pids = ctx.monitor.user_pids_now() if ctx.monitor else frozenset()
    t0 = tt0 = None
    deferred = None            # (task, check_ok, outcome): classified once the final windows are known

    def charge(changes, into):
        counted, amb = attribute(changes, owners, ambient_pids)
        into.extend(amb)
        return counted

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
                        rec.update(status="infra_error", why=f"setup: {o['app']} did not start with the fresh --user-data-dir; not using it")
                        return rec
                else:
                    wid, _ = ctx.opener.open(o["app"], o.get("targets", []))
                if wid is None:
                    rec.update(status="infra_error", why=f"setup: could not open {o['app']} on the agent workspace")
                    return rec
                if wid not in created:
                    created.append(wid)
                app_of[wid] = o["app"]
                windows[o["as"]] = wid
                titles[o["as"]] = o.get("title", "")
                pid = ctx.opener.pid_of(wid) if hasattr(ctx.opener, "pid_of") else None
                if pid:
                    pid_of_wid[wid] = pid          # each `agent open` starts its own instance: one pid per instance
            ctx.sleep(setup.get("settle_s", 0.8))

            # Ownership: every window we made is on the agent workspace, and the apps we started own no other window
            # (a restored session would be Donovan's documents inside the run).
            listing = ctx.opener.windows()
            lost_track = [w for w in created if w not in listing]
            foreign = [w for w, (a, _t) in listing.items()
                       if a in set(app_of.values()) and w not in created and w not in ctx.created_ever]
            if lost_track or foreign:
                rec.update(status="infra_error",
                           why=(f"setup: window {lost_track[0]} is not on the agent workspace" if lost_track else
                                f"setup: {listing[foreign[0]][0]} owns window {foreign[0]} that the bench did not create "
                                "(a restored or foreign window); not running"))
                return rec

            if setup.get("hide") and setup["hide"] in not_running_req and not was_running.get(setup["hide"], False):
                ctx.exec(["osascript", "-e", 'tell application "System Events" to set visible of process '
                          f'"{setup["hide"]}" to false'], timeout=15)
                ctx.sleep(0.4)
            for alias in setup.get("close_before_run", []):    # a window that existed and is gone: the "missing window" case
                closed, left = close_windows(ctx.cleanup_driver, [windows[alias]], ctx.opener.windows, should_stop=ctx.aborted_fn)
                if windows[alias] in left:
                    rec.update(status="infra_error", why=f"setup: could not close window {windows[alias]} for the missing-window "
                               f"task ({left[windows[alias]]}); the tool is not run against a window that still exists")
                    return rec
                created = [w for w in created if w != windows[alias]]
            before = {d: host.list_dir(d) for d in ctx.watch_dirs}

            # The early gate: wait until everything seen before `q` has been reported, then read the WHOLE interval that
            # was drained (up to `q_end`, not just up to `q`), because a state.json write that lands inside the drain is
            # stamped by the tick that read it. The tool starts at q_end, so nothing can slip between the gate and t0.
            q = ctx.clock()
            ctx.wait_reports(q)
            q_end = ctx.clock()
            gate = charge(ctx.monitor.changes(ts0, q_end, 0), []) if ctx.monitor else []
            leaks = [c for c in gate if set(c["fields"]) & set(WINDOW_FIELDS)]
            if leaks:
                # shared harness code (`agent open`) put a window on his workspace: not the tool's doing and not a pass
                rec.update(status="infra_error", setup_leak=leaks,
                           why="setup leaked a window onto one of Donovan's workspaces; the tool was not run")
                return rec
            t0 = q_end
            outcome = ctx.doing(t, windows, titles)
            t1 = ctx.clock()
            ctx.sleep(ctx.drain_s)          # a dialog the last action raised 0.3 s later is stamped inside the task
            tt0 = ctx.clock()

            rec["duration_s"] = round(t1 - t0, 3)
            rec["tool_ms"] = outcome.get("tool_ms")
            rec["steps"] = outcome.get("log", [])
            for k in ("model_turns", "cost_usd", "agent_text", "tool_calls", "tool_errors", "guard_refusals", "micro"):
                if outcome.get(k) is not None:
                    rec[k] = outcome[k]
            rec["answer"] = (outcome.get("answer") or "")[:300]
            real, posted, by_pid = ctx.monitor.input(t0, tt0) if ctx.monitor else (0, 0, {})
            rec["hid_events"], rec["posted_input_events"] = real, posted
            if by_pid:
                rec["posted_input_by_pid"] = by_pid
            rec["collateral"] = [f"{d}/{n}" for d in ctx.watch_dirs for n in host.collateral(before[d], host.list_dir(d))]
            rec["refusal"] = outcome.get("refusal")

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
            if not outcome["ok"] and not t.get("impossible"):
                rec["why"] = outcome.get("why", "")
            deferred = (t, check_ok, outcome)
            return rec
        except Aborted as e:
            lost = ctx.monitor.losses[-1]["why"] if ctx.monitor and ctx.monitor.losses else None
            rec.update(status="monitor_lost" if lost else "not_run", why=f"stopped: {lost or e}")
            return rec
        except Exception as e:  # noqa: BLE001  whatever broke, the finally block's accounting must reach the result file
            rec.update(status="infra_error", why=f"{type(e).__name__}: {e}"[:300])
            return rec
    finally:
        tt0 = tt0 if tt0 is not None else ctx.clock()
        pending = {"windows": [], "apps": [], "pids": [], "defaults": []}
        notes = []
        aborted = ctx.aborted_fn()
        # one entry per instance `agent open` started, keyed by pid and never by app name: two windows of one app are
        # two instances, and each is enumerated, quit and waited on on its own
        instances = {}
        for wid, pid in pid_of_wid.items():
            instances.setdefault(pid, {"app": app_of.get(wid, "?"), "wids": []})["wids"].append(wid)
        pidless = sorted((apps - SYSTEM_APPS) - {i["app"] for i in instances.values()})
        try:
            left = {}
            if aborted:
                pending["windows"] = list(created)
            elif created:
                _, left = close_windows(ctx.cleanup_driver, created, ctx.opener.windows, should_stop=ctx.aborted_fn)
                if left:
                    rec["teardown_left"] = {str(k): v for k, v in left.items()}
                    pending["windows"] = [k for k, v in left.items() if v.startswith(("interrupted", "cannot tell", "still open"))]

            def hold(app, pid=None, note=None):
                pending["apps"].append(app)
                if pid:
                    pending["pids"].append(pid)
                if note:
                    notes.append(note)

            # Quit only instances this task started. After an abort teardown does not act on windows, but an instance of an
            # app that was not running before the task (so every window of it is ours) and that the task declared with
            # quit_after is ended quietly when preferences are to be restored, so the app's own exit cannot overwrite them.
            for pid, inst in sorted(instances.items()):
                app = inst["app"]
                guaranteed_ours = app in not_running_req and not was_running.get(app, False)
                if aborted and not (saved_defaults and guaranteed_ours and app in setup.get("quit_after", [])):
                    hold(app, pid)
                    continue
                if not ctx.alive_fn(pid):
                    continue            # it exited by itself (Calculator quits with its last window): nothing to enumerate or quit
                ok_enum, owned = ctx.cleanup_driver.pid_windows(app, pid) if not aborted else (True, [])
                tracked_open = [w for w in inst["wids"] if w in left]
                if not ok_enum or owned or tracked_open:
                    hold(app, pid, f"{app} (pid {pid}) not quit: " + ("its windows could not be enumerated" if not ok_enum else
                                   f"windows {sorted(set(owned) | set(tracked_open))} are still open"))
                    continue
                ctx.qexec(["kill", "-TERM", str(pid)], timeout=10)
                if not _wait_gone(ctx, pid):
                    hold(app, pid, f"{app} (pid {pid}) did not exit within {QUIT_WAIT_S:.0f} s")
            for app in pidless:
                guaranteed_ours = app in not_running_req and not was_running.get(app, False)
                if not guaranteed_ours:
                    continue            # no pid and not provably ours: left alone (its windows were closed above)
                if aborted:
                    hold(app)
                    continue
                if not ctx.running_fn(app):
                    continue
                # no pid to go by: the app was not running before, so the only copy is ours; ask it to quit by name
                try:
                    now_windows = ctx.opener.windows()
                except Exception:  # noqa: BLE001
                    now_windows = None
                still = [w for w, (a, _t) in (now_windows or {}).items() if a == app]
                kept = [w for w in left if app_of.get(w) == app]
                if now_windows is None or still or kept:
                    hold(app, None, f"{app} not quit: " + ("its windows could not be listed" if now_windows is None else
                                                          f"windows {sorted(set(still) | set(kept))} are still open"))
                else:
                    ctx.exec(["osascript", "-e", f'tell application "{app}" to quit'], timeout=15)
                    end = ctx.clock() + QUIT_WAIT_S
                    while ctx.running_fn(app) and ctx.clock() < end:
                        ctx.sleep(0.2)
                    if ctx.running_fn(app):
                        hold(app, None, f"{app} did not exit within {QUIT_WAIT_S:.0f} s")
            # Preferences go back only when no instance of what we drove is still running (its exit would overwrite them).
            if saved_defaults:
                driven_up = sorted({a for a in pending["apps"] if a in setup.get("quit_after", [])})
                if driven_up:
                    pending["defaults"] = list(saved_defaults)
                    notes.append(f"preferences {sorted(saved_defaults)} not restored while {driven_up} still run; "
                                 f"backup kept in {recovery_dir}")
                else:
                    problems = _restore_defaults(ctx, saved_defaults, recovery_dir)
                    if problems:
                        pending["defaults"] = list(saved_defaults)
                        notes.extend(problems + [f"backup kept in {recovery_dir}"])
        except Aborted:
            pending = {"windows": list(created), "apps": sorted(apps - SYSTEM_APPS), "pids": sorted(instances), "defaults": list(saved_defaults)}
        except Exception as e:  # noqa: BLE001  a broken cleanup tool must not hide the record or skip the accounting below
            pending = {"windows": list(created), "apps": sorted(apps - SYSTEM_APPS), "pids": sorted(instances), "defaults": list(saved_defaults)}
            notes.append(f"{type(e).__name__}: {e}"[:200])
        if pending["defaults"]:
            # An unresolved backup: no later task may change these preferences, and the way back is printed.
            for dom in pending["defaults"]:
                path = os.path.join(recovery_dir, f"{dom}.plist") if recovery_dir else "(no recovery directory)"
                cmd = (f"defaults import {dom} {path}" if saved_defaults.get(dom) is not None else f"defaults delete {dom}")
                ctx.blocked_domains[dom] = {"recovery": recovery_dir, "command": cmd}
        if any(pending.values()) or notes:
            rec["teardown_pending"] = {k: v for k, v in pending.items() if v}
            rec["teardown_pending"]["note"] = "teardown did not finish; these were left for manual recovery"
            if notes:
                rec["teardown_pending"]["error"] = "; ".join(notes)
            if pending["defaults"] and recovery_dir:
                rec["teardown_pending"]["recovery"] = recovery_dir
                rec["teardown_pending"]["recovery_commands"] = [ctx.blocked_domains[d]["command"] for d in pending["defaults"]]

        # Late pass: wait until the sampler has gone past T_end plus its debounce, then cut all three windows from
        # the full event log by stamp.
        try:
            t_end = ctx.clock()
            ctx.wait_reports(t_end)
            if ctx.monitor:
                ambient = []
                if t0 is not None:
                    setup_final = charge(ctx.monitor.changes(ts0, t0, 0), ambient)
                    task_final = charge(ctx.monitor.changes(t0, tt0, 0), ambient)
                else:
                    setup_final = charge(ctx.monitor.changes(ts0, tt0, 0), ambient)
                    task_final = []
                rec["setup_changes"] = setup_final
                rec["teardown_changes"] = charge(ctx.monitor.changes(tt0, t_end, 0), ambient)
                intended = [c for c in task_final if allowed and set(c["fields"]) <= allowed]
                rec["changes"] = [c for c in task_final if c not in intended]
                if intended:
                    rec["intended_changes"] = intended
                # Precedence, last word first: a monitor that was lost anywhere in the run always wins and the record keeps
                # the earlier status; a setup leak that only the late pass saw downgrades any SCORED status to infra_error.
                lost = ctx.monitor.lost_between(t0 if t0 is not None else ts0, t_end)
                late_leaks = [c for c in setup_final if set(c["fields"]) & set(WINDOW_FIELDS)]
                scored_now = rec.get("status") in scoring.SCORED
                if lost:
                    if "status" in rec and rec["status"] != "monitor_lost":
                        rec["earlier_status"] = rec["status"]
                    rec.update(status="monitor_lost", why=lost[0]["why"])
                    deferred = None
                elif late_leaks and "setup_leak" not in rec and (scored_now or deferred is not None):
                    if scored_now:
                        rec["earlier_status"] = rec["status"]
                    rec.update(status="infra_error", setup_leak=late_leaks,
                               why="setup leaked a window onto one of Donovan's workspaces (reported only after the task ran); not counted")
                    deferred = None
                if ambient:
                    rec["ambient_changes"] = ambient
            if deferred is not None and "status" not in rec:
                t_, check_ok, outcome = deferred
                side = {"changes": len(rec.get("changes", [])), "hid": rec.get("hid_events", 0),
                        "posted": rec.get("posted_input_events", 0), "collateral": len(rec.get("collateral", []))}
                rec["status"] = scoring.classify(t_, check_ok, outcome, outcome.get("refusal"), side)
        except Aborted:
            rec.setdefault("status", "not_run")
        ctx.created_ever.update(created)
        shutil.rmtree(tdir, ignore_errors=True)
