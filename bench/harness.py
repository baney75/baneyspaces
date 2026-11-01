#!/usr/bin/env python3
"""Head-to-head benchmark: BaneySpaces vs agent-desktop vs ChatGPT computer use.

  harness.py --tool baneyspaces|agent-desktop|agent-desktop-headed|chatgpt|all
             --level scripted|agent|micro|all  [--dry-run] [--only ID,...]

Levels
  scripted  the same task steps through each tool's command line (success, screen changes, time)
  agent     each tool's own agent does the task from its goal: `claude -p` for baneyspaces and
            agent-desktop, `codex exec` + ChatGPT computer use for chatgpt (adds model turns)
  micro     per-action latency (snapshot, click, type, read-back), called directly

Places: a task runs on the agent workspace (`place: host`) or needs the sandbox (`place: sandbox`, skipped
as "needs sandbox (phase 2)" until it exists). Every tool runs a task in the same place.

A real run needs the Mac idle (HIDIdleTime >= 600 s), checks again before every task, and stops the
moment idle drops under 5 s or the screen-change monitor is lost. There is no override.
"""
import argparse
import datetime
import json
import os
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from benchlib import agents, host, micro, monitor, report, scoring  # noqa: E402
from benchlib.cleanup import close_windows  # noqa: E402
from benchlib.drivers import AgentDesktopDriver, BaneySpacesDriver, Opener, which  # noqa: E402
from benchlib.execs import Aborted, Exec, PgidRegistry  # noqa: E402
from benchlib.fixtures import FixtureServer  # noqa: E402
from benchlib.runner import Context, run_task  # noqa: E402
from benchlib.script import Interpreter  # noqa: E402
from benchlib.tasks import TaskError, load_tasks  # noqa: E402

ROOT = os.path.dirname(HERE)
TOOLS_DIR = os.path.join(ROOT, ".tools")
LEVEL_TOOLS = {
    "scripted": ["baneyspaces", "agent-desktop", "agent-desktop-headed"],
    "agent": ["baneyspaces", "agent-desktop", "chatgpt"],
    "micro": ["baneyspaces", "agent-desktop", "chatgpt"],
}
SENDS_INPUT = {"agent-desktop-headed", "chatgpt"}   # post synthetic input: need the sampler's event tap to be told apart from Donovan
EXIT_USER_ACTIVE = 3


def paths():
    return {
        "baneyspaces": os.environ.get("BENCH_BANEYSPACES", "baneyspaces"),
        "agent_desktop": os.environ.get("BENCH_AGENT_DESKTOP",
                                        os.path.join(TOOLS_DIR, "agent-desktop-src/target/release/agent-desktop")),
        "claude": os.environ.get("BENCH_CLAUDE", "claude"),
        "codex": os.environ.get("BENCH_CODEX", "codex"),
        "sampler": os.path.join(TOOLS_DIR, "bench-sample"),
        "sampler_src": os.path.join(HERE, "lib", "sampler.swift"),
    }


def plan_for(tool_arg, level_arg):
    levels = list(LEVEL_TOOLS) if level_arg == "all" else [level_arg]
    return [(lv, tool) for lv in levels for tool in LEVEL_TOOLS[lv] if tool_arg in ("all", tool)]


def resolve_plan(plan, p):
    """-> [(level, tool, ok, detail)]"""
    rows = []
    for level, tool in plan:
        if tool == "baneyspaces":
            ok, d = BaneySpacesDriver(None, p["baneyspaces"]).resolve()
            if ok and level == "agent":
                ok2 = bool(which(p["claude"]))
                ok, d = ok2, f"{d}; claude -p: {p['claude'] if ok2 else 'not found'}"
        elif tool.startswith("agent-desktop"):
            ok, d = AgentDesktopDriver(None, p["agent_desktop"], headed=tool.endswith("headed")).resolve()
            if ok and tool.endswith("headed"):
                d += "; runs only in the sandbox: every task is unavailable (sandbox_only) on this Mac"
            if ok and level == "agent":
                ok2 = bool(which(p["claude"])) and os.access(agents.GUARD, os.X_OK)
                ok, d = ok2, f"{d}; claude -p: {p['claude'] if which(p['claude']) else 'not found'}; guard: {agents.GUARD}"
        else:  # chatgpt
            mcp = agents.find_plugin_mcp()
            node = os.path.join(agents.CUA_NODE, "bin", "node")
            ok = bool(which(p["codex"])) and mcp is not None and os.access(node, os.X_OK)
            d = (f"codex {which(p['codex'])}; cua_repl from {mcp}; runs only in the sandbox: every task is unavailable on this Mac"
                 if ok else "needs codex, ChatGPT.app's cua_node and the unified-computer-use plugin")
        rows.append((level, tool, ok, d))
    return rows


def referee_row(p):
    """agent-desktop is the referee and the cleanup driver for EVERY run, whichever column runs."""
    ok, d = AgentDesktopDriver(None, p["agent_desktop"]).resolve()
    return [("all", "referee (agent-desktop)", ok, d)]


def load(tasks_dir, only=None):
    tasks = load_tasks(tasks_dir)
    if only:
        wanted = set(only)
        unknown = wanted - {t["id"] for t in tasks}
        if unknown:
            raise TaskError(f"unknown task ids: {sorted(unknown)}")
        tasks = [t for t in tasks if t["id"] in wanted]
    return tasks


def dry_run(args, p):
    tasks = load(os.path.join(HERE, "tasks"), args.only)
    print(f"{len(tasks)} tasks")
    for t in tasks:
        exp = ",".join(f"{k}:expected-fail" for k in t.get("expected_fail", {}))
        place = "" if t.get("place", "host") == "host" else "[sandbox]"
        print(f"  {t['id']:<34} {t['category']:<10} {t['app']:<16} {place:<10} {exp}")
    rows = referee_row(p) + resolve_plan(plan_for(args.tool, args.level), p)
    print("\nrunners")
    bad = 0
    for level, tool, ok, detail in rows:
        print(f"  {level:<9} {tool:<22} {'resolved' if ok else 'MISSING':<9} {detail}")
        bad += 0 if ok else 1
    return 1 if bad else 0


def plist_value(exec_fn, bundle, key):
    """One Info.plist key, or None when it is absent (plutil exits non-zero)."""
    rc, out, _, _ = exec_fn(["plutil", "-extract", key, "raw", "-o", "-", f"{bundle}/Contents/Info.plist"], timeout=10)
    return out.strip() if rc == 0 and out.strip() else None


def tool_versions(p, exec_fn):
    def run(argv):
        try:
            rc, out, err, _ = exec_fn(argv, timeout=15)
            return (out or err).strip().splitlines()[0] if (out or err).strip() else "?"
        except Exception:  # noqa: BLE001
            return "?"

    def installed_app():
        for base in (os.path.expanduser("~/Applications"), "/Applications"):
            if os.path.isdir(f"{base}/BaneySpaces.app"):
                return f"{base}/BaneySpaces.app"
        return None

    def app_commit(app):
        """The commit the installed app was built from, if its bundle records one."""
        for key in ("BSGitCommit", "GitCommit", "BaneySpacesCommit", "CFBundleGitCommit"):
            v = plist_value(exec_fn, app, key)
            if v:
                return v
        return "not recorded in the app bundle"

    def commit(cwd):
        r = subprocess.run(["git", "-C", cwd, "rev-parse", "--short=12", "HEAD"], capture_output=True, text=True)
        return r.stdout.strip() or "?"

    pin = {}
    with open(os.path.join(HERE, "PIN"), encoding="utf-8") as fh:
        for line in fh:
            if "=" in line and not line.startswith("#"):
                k, v = line.strip().split("=", 1)
                pin[k] = v
    sky_pkg = os.path.join(agents.CUA_NODE, "lib/node_modules/@oai/sky/package.json")
    sky_ver = "?"
    if os.path.exists(sky_pkg):
        with open(sky_pkg, encoding="utf-8") as fh:
            sky_ver = json.load(fh).get("version", "?")
    app = installed_app()
    return {
        "bench_commit": commit(ROOT),
        "baneyspaces": {"app": (plist_value(exec_fn, app, "CFBundleShortVersionString") or "?") if app else "not installed",
                        "app_commit": app_commit(app) if app else "not installed"},
        "agent-desktop": {"version": run([p["agent_desktop"], "--version"]), "pinned_commit": pin.get("ENGINE_COMMIT", "?")[:12]},
        "chatgpt": {"app": plist_value(exec_fn, agents.CHATGPT_APP, "CFBundleShortVersionString") or "?",
                    "codex": run([p["codex"], "--version"]), "sky": sky_ver,
                    "plugin": os.path.relpath(agents.find_plugin_mcp() or "none", os.path.expanduser("~/.codex"))},
        "claude": run([p["claude"], "--version"]),
        "claude_model": agents.CLAUDE_MODEL,
        "macos": run(["sw_vers", "-productVersion"]),
    }


def make_doing(level, tool, p, exec_fn, workdir, cwd=None):
    """The part of a task run that differs per tool and level."""
    if level == "scripted":
        if tool == "baneyspaces":
            driver = BaneySpacesDriver(exec_fn, p["baneyspaces"])
        else:
            driver = AgentDesktopDriver(exec_fn, p["agent_desktop"], headed=tool.endswith("headed"))

        def doing(task, windows, titles):
            it = Interpreter(driver, windows)
            out = it.run(task["steps"])
            out.update(log=it.log, tool_ms=it.tool_ms, tool_calls=it.tool_calls, answer="\n".join(it.answers))
            return out
        return doing

    if tool == "chatgpt":
        def doing(task, windows, titles):
            raise agents.SandboxOnly("ChatGPT computer use runs only inside the sandbox VM, never on this Mac")
        return doing

    # level == agent
    os.makedirs(workdir, exist_ok=True)       # the column directory may not exist yet (the context creates it later)
    mcp_path = os.path.join(workdir, f"mcp-{tool}.json")
    cfg = agents.baneyspaces_mcp_config(p["baneyspaces"]) if tool == "baneyspaces" else agents.empty_mcp_config()
    with open(mcp_path, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh)
    guard_file = os.path.join(workdir, "guard.json")

    def doing(task, windows, titles):
        prompt = agents.build_prompt(task, windows, titles, tool)
        env = None
        cmd = agents.claude_command(tool, prompt, p["claude"], mcp_path)
        if tool == "agent-desktop":
            with open(guard_file, "w", encoding="utf-8") as fh:
                json.dump({"windows": [f"w-{w}" for w in windows.values()], "snapshots": []}, fh)
            env = {"BENCH_AD_BIN": p["agent_desktop"], "BENCH_GUARD_FILE": guard_file}
            cmd += ["--append-system-prompt", agents.agent_desktop_skill_prompt()]
        rc, out, err, ms = exec_fn(cmd, timeout=agents.AGENT_TIMEOUT_S, cwd=cwd, env=env)
        parsed = agents.parse_claude(out)
        text = parsed.get("text", "")
        base = {"log": [{"do": "agent", "ok": parsed["ok"], "ms": ms, "message": (parsed.get("error") or err or "")[:200]}],
                "tool_ms": ms, "model_turns": parsed.get("turns"), "cost_usd": parsed.get("cost_usd"),
                "agent_text": text[:300], "answer": text, "tool_calls": parsed.get("tool_calls", 0),
                "tool_errors": parsed.get("tool_errors", 0), "shortcut": parsed.get("shortcut"), "refusal": None,
                "guard_refusals": parsed.get("guard_refusals", 0)}
        infra = agents.infra_failure(tool, rc, out, err, parsed)
        if infra:
            return dict(base, ok=False, infra=infra[0], fatal_infra=infra[1], why=infra[0])
        if task.get("impossible"):
            r = agents.attempted_refusal(task, parsed.get("refusals", []), windows)
            if r:       # the TOOL's own code and suggestion, from the call that attempted the impossible action
                base["refusal"] = {"code": r["code"], "suggestion": r["suggestion"], "retry": r.get("retry")}
        return dict(base, ok=parsed["ok"] or base["refusal"] is not None, why=parsed.get("error") or "")
    return doing


def run_is_full(recs, only, aborted):
    """A result may feed latest.md and the ratchet only if every task was attempted, none was skipped by --only, the
    run was not cut short, and at least one task was actually scored (a run that scored nothing measured nothing)."""
    scored = any(r["status"] in scoring.SCORED for r in recs)
    return (not only) and not aborted and scored and all(r["status"] != "not_run" for r in recs)


def tool_order(tools, i):
    """Quiet tools first, rotated per task so no tool always goes first (quota and warm caches),
    tools that may post real input last."""
    quiet = [t for t in tools if t not in SENDS_INPUT]
    loud = [t for t in tools if t in SENDS_INPUT]
    k = i % len(quiet) if quiet else 0
    return quiet[k:] + quiet[:k] + loud


class RunState:
    """What the guards share: the abort event, why it was set, and the gates every task passes.

    idle_fn is seconds since the last REAL input (hardware events; programs posting events do not count).
    """

    def __init__(self, abort, idle_fn, session_fn=lambda: (True, {}), tap_ok=True, required=host.IDLE_REQUIRED_S):
        self.abort, self.idle_fn, self.session_fn, self.tap_ok, self.required = abort, idle_fn, session_fn, tap_ok, required
        self.reason = {}
        self.stop = False
        self.stop_reason = ""
        self.deadline = None          # monotonic time the caffeinate budget runs out; the run stops then
        self.healthy_fn = lambda: (True, "")      # the screen-change monitor's health; set once it is running

    def halt(self, why):
        self.stop, self.stop_reason = True, why

    def gate(self):
        """Before every task (and micro run): -> None, or why the run must stop. Real idle >= 600 s, screen usable."""
        if self.abort.is_set():
            return self.reason_text()
        ok, why = self.healthy_fn()
        if not ok:
            self.reason.update(kind="lost", why=why)
            return self.reason_text()
        if self.deadline is not None and time.monotonic() > self.deadline:
            self.reason.update(kind="budget")
            return "the level's time budget ran out (the Mac is no longer held awake)"
        idle = self.idle_fn()
        if idle < self.required:
            self.reason.update(kind="input", idle=round(idle, 1))
            return f"real input seen on this Mac (idle {idle:.0f} s, need {self.required:.0f} s)"
        ok, sess = self.session_fn()
        if not ok:
            self.reason.update(kind="locked")
            return host.session_gate(ok, sess)[1]
        return None

    def reason_text(self):
        k = self.reason.get("kind", "abort")
        if k == "input":
            return f"real input seen on this Mac (idle {self.reason.get('idle')} s)"
        if k == "lost":
            return f"the screen-change monitor was lost: {self.reason.get('why')}"
        if k == "locked":
            return "the screen locked or the display went to sleep"
        if k == "budget":
            return "the level's time budget ran out"
        if k == "registry":
            return "the sampler did not acknowledge a child's process group, so the child was not started"
        if k == "signal":
            return "the harness was interrupted (SIGINT or SIGTERM)"
        return "aborted"


def run_group(tasks, ctxs, st, run_task_fn=run_task, progress=lambda level, tool, t, rec: None, level=""):
    """Run every task for every tool in ctxs, interleaved (tools take turns per task).

    Before each task the run must pass the gate: real idle >= 600 s and an awake, unlocked screen.
    Real input, a lost monitor or a lock stops the whole run: the rest are `not_run`. A tool that posts
    synthetic input (headed, ChatGPT) is not stopped by its own input (the sampler's tap tells it from
    Donovan's); without the tap it is `unavailable`. Any exception from a task is recorded as
    infra_error and the run goes on; a fatal infra error stops that column only.
    """
    records = {tool: [] for tool in ctxs}
    dead = {}
    for i, t in enumerate(tasks):
        for tool in tool_order(list(ctxs), i):
            base = {"id": t["id"], "category": t["category"], "app": t["app"], "place": t.get("place", "host"),
                    "impossible": bool(t.get("impossible"))}
            if st.stop:
                rec = dict(base, status="not_run", why=f"the run stopped: {st.stop_reason}")
            elif tool in dead:
                rec = dict(base, status="not_run", why=dead[tool])
            elif tool in SENDS_INPUT and not st.tap_ok:
                rec = dict(base, status="unavailable", why="unavailable: needs the sampler's input tap (Input Monitoring) to tell "
                           "this tool's posted input from Donovan's")
            else:
                why = st.gate()
                if why:
                    st.halt(why)
                    rec = dict(base, status="not_run", why=f"the run stopped: {why}")
                else:
                    try:
                        rec = run_task_fn(t, ctxs[tool])
                    except Aborted:
                        rec = dict(base, status="not_run", why="stopped: input seen, monitor lost or screen locked")
                    except Exception as e:  # noqa: BLE001  one task must never take the run down
                        rec = dict(base, status="infra_error", why=f"{type(e).__name__}: {e}"[:300])
                    if rec.get("fatal_infra"):
                        dead[tool] = f"column stopped, not measured: {rec['why']}"
                    # teardown is part of the task: input, a lock or a lost monitor during it stops the run too
                    if not st.abort.is_set():
                        hok, hwhy = st.healthy_fn()
                        if not hok:
                            st.reason.update(kind="lost", why=hwhy)
                            st.abort.set()
                    if st.abort.is_set() and not st.stop:
                        st.halt(st.reason_text())
            records[tool].append(rec)
            progress(level, tool, t, rec)
    return records, dead


def micro_doing(tool, p, exec_fn):
    """The measured part of the micro level, run by the runner after its own setup (drain, attribution, leak check,
    window ownership) so a window that landed on Donovan's workspace invalidates it before one action is sent."""
    if tool == "chatgpt":
        def doing(task, windows, titles):
            raise agents.SandboxOnly("ChatGPT computer use runs only inside the sandbox VM, never on this Mac")
        return doing
    if tool == "baneyspaces":
        driver = BaneySpacesDriver(exec_fn, p["baneyspaces"])
        noop = [p["baneyspaces"], "--version"]
    else:
        driver = AgentDesktopDriver(exec_fn, p["agent_desktop"])
        noop = [p["agent_desktop"], "--version"]

    def doing(task, windows, titles):
        noop_ms = micro.noop_spawn_ms(exec_fn, noop)
        lat, errs = micro.run_micro(driver, windows["text"], windows["calc"], noop_ms)
        problems = micro.invalid(lat, errs)
        # a measurement with failed actions or missing samples is kept as a diagnostic, never as a result
        return {"ok": True, "log": [], "micro": {"status": "invalid" if problems else "ok", "latency": lat, "errors": errs,
                "problems": problems, "noop_spawn_ms": noop_ms, "noop_command": noop, "method": micro.METHOD_CLI}}
    return doing


def run_micro_level(tool, ctx, run_task_fn=run_task):
    """-> the micro result dict for one tool. The micro level is a pseudo task (TextEdit on an empty file and
    Calculator) run by the runner, so it has the runner's availability gate, drain, attribution, `setup_leak`,
    window-ownership check, safe quit and defaults restore. A leak or any setup failure makes it invalid/n/a."""
    task = host.micro_task(tool)
    rec = run_task_fn(task, ctx)
    out = {"setup_changes": rec.get("setup_changes", []), "changes": rec.get("changes", []),
           "teardown_changes": rec.get("teardown_changes", []), "ambient_changes": rec.get("ambient_changes", [])}
    for k in ("teardown_pending", "teardown_left"):
        if k in rec:
            out[k] = rec[k]
    if rec["status"] == "unavailable":
        return dict(out, status="n/a", why=rec["why"], latency=None)
    if rec.get("setup_leak"):
        return dict(out, status="invalid", why=rec["why"], setup_leak=rec["setup_leak"], latency=None)
    if rec["status"] in ("infra_error", "monitor_lost", "not_run") or not rec.get("micro"):
        return dict(out, status="n/a", why=rec.get("why", rec["status"]), latency=None)
    m = rec["micro"]
    if rec["changes"]:                      # the measured actions disturbed the screen: not a clean measurement
        m = dict(m, status="invalid", problems=list(m.get("problems", [])) + ["screen changes during the measured actions"])
    return dict(m, **out)


def level_budget_s(level, n_tasks, n_tools):
    """Wall-clock allowance for one level; caffeinate is held for no longer than this and the run stops when it ends."""
    per = {"scripted": 90, "agent": agents.AGENT_TIMEOUT_S + 60, "micro": 600}[level]
    return min(6 * 3600, 900 + per * (n_tasks if level != "micro" else 1) * max(1, n_tools))


def real_run(args, p):
    tasks = load(os.path.join(HERE, "tasks"), args.only)
    plan = plan_for(args.tool, args.level)
    rows = referee_row(p) + resolve_plan(plan, p)
    missing = [r for r in rows if not r[2]]
    if missing:
        print("cannot run, unresolved:", file=sys.stderr)
        for lv, tool, _, d in missing:
            print(f"  {lv} {tool}: {d}", file=sys.stderr)
        return 1
    idle = host.hid_idle_seconds()
    ok, msg = host.idle_gate(idle)
    if not ok:
        print(msg)
        return EXIT_USER_ACTIVE
    print(f"idle gate: {msg}")
    status = Exec()([p["baneyspaces"], "agent", "status"], timeout=15)[1]
    if "agent workspace: off" in status or "agent workspace:" not in status:
        print("not run: the BaneySpaces agent workspace is off or BaneySpaces is not running "
              "(baneyspaces agent on). Every app must open on workspace 9, never on Donovan's.")
        return 1
    if not os.path.isdir(host.HANDOFF):
        print(f"not run: the agent handoff folder {host.HANDOFF} does not exist; `baneyspaces agent open` takes files only from there "
              "(is BaneySpaces phase 1 installed?).")
        return 1

    abort = threading.Event()
    sampler_dir = tempfile.mkdtemp(prefix="bench-sampler-")
    registry = PgidRegistry(os.path.join(sampler_dir, "allow.json"))
    exec_fn = Exec(abort=abort, registry=registry)      # the one abort: tools, teardown and quits all stop on it
    st = RunState(abort, lambda: 0.0)

    def on_hid(ev):
        st.reason.update(kind="input", idle=0.0)
        abort.set()

    def on_lost(loss):
        st.reason.update(kind="lost", why=loss["why"])
        abort.set()

    def on_session(state):
        st.reason.update(kind="locked", state=state)
        abort.set()

    monitor.build_sampler(p["sampler_src"], p["sampler"])
    mon = monitor.Monitor([p["sampler"], "--allow-file", registry.path], on_hid=on_hid, on_lost=on_lost, on_session=on_session).start()
    registry.waiter = mon.wait_allow_version

    def on_registration_failure(version):
        st.reason.update(kind="registry", version=version)
        abort.set()
    registry.on_failure = on_registration_failure       # a child is never started unregistered: the run aborts
    st.healthy_fn = mon.healthy

    def on_signal(signum, _frame):
        st.reason.update(kind="signal", signum=signum)
        abort.set()
        exec_fn.kill_all()
    old_handlers = {s: signal.signal(s, on_signal) for s in (signal.SIGINT, signal.SIGTERM)}
    try:
        # The sampler is up: re-check what was true before the (unmonitored) compile.
        ok, msg = host.idle_gate(mon.real_idle())
        if not ok:
            print(msg)
            return EXIT_USER_ACTIVE
        sess_ok, sess = mon.session_ok()
        sok, smsg = host.session_gate(sess_ok, sess)
        if not sok:
            print(smsg)
            return EXIT_USER_ACTIVE
        st.idle_fn, st.session_fn, st.tap_ok = mon.real_idle, mon.session_ok, mon.tap_ok
        if not mon.tap_ok:
            print("note: the input tap is unavailable (grant Input Monitoring to the sampler); the idle guard falls back to HID idle time")
        return _run_levels(args, p, tasks, plan, mon, st, abort, exec_fn, sess)
    finally:
        exec_fn.kill_all()           # no tool child outlives the monitor and the guards
        for s, hnd in old_handlers.items():
            signal.signal(s, hnd)
        mon.stop()
        shutil.rmtree(sampler_dir, ignore_errors=True)


def _run_levels(args, p, tasks, plan, mon, st, abort, exec_fn, sess):
    server = FixtureServer().start()
    # Fixtures live in the agent handoff folder (the only place `agent open` takes files from), in a directory of this
    # run's own. Nothing in a prompt names it.
    workdir = tempfile.mkdtemp(prefix="bench-run-", dir=host.HANDOFF)
    cwd = tempfile.mkdtemp(prefix="bench-cwd-")          # the agents' cwd: empty, no path to the fixtures
    opener = Opener(exec_fn, p["baneyspaces"])
    referee_driver = AgentDesktopDriver(exec_fn, p["agent_desktop"])
    cleanup_driver = AgentDesktopDriver(exec_fn, p["agent_desktop"])     # shares the abort
    versions = tool_versions(p, Exec())
    now = datetime.datetime.now()
    date, hms = args.date or now.date().isoformat(), now.strftime("%H%M%S")
    run_id = f"{date}-{hms}-{secrets.token_hex(2)}"
    results_dir = args.results_dir
    exit_code = 0
    created_ever = set()
    blocked_domains = {}
    host_state = {"session": sess, "caffeinate": " ".join(host.CAFFEINATE) + " -t <level budget>", "input_tap": mon.tap_ok}
    caveats = ["ChatGPT computer use and agent-desktop --headed run only inside the sandbox VM (#111) and are not measured on this Mac",
               "the BaneySpaces and agent-desktop agent columns are confined (MCP allowlist, agent-desktop-guard)"]

    def finish(level, tool, recs, dead):
        aborted = dead.get(tool, "")
        # a stopped run is aborted even if every record reached a status: the stop may have come during the last
        # task's teardown, after it was already classified
        aborted = aborted if aborted.startswith("column stopped") else (f"stopped: {st.stop_reason}" if st.stop else "")
        full = run_is_full(recs, args.only, aborted)
        report.write_result(results_dir, {
            "tool": tool, "level": level, "date": date, "hms": hms, "run_id": run_id, "only": args.only, "full": full,
            "versions": versions, "host": os.uname().nodename, "aborted": aborted or None, "tasks": recs,
            "summary": scoring.summarize(recs), "monitor": mon.health(), "host_state": host_state, "caveats": caveats})

    def context(level, tool, doing):
        wd = os.path.join(workdir, f"{level}-{tool}")
        os.makedirs(wd, exist_ok=True)
        c = Context(tool=tool, workdir=wd, server=server, monitor=mon, opener=opener, referee_driver=referee_driver,
                    cleanup_driver=cleanup_driver, exec_fn=exec_fn, state_fn=_state, doing=doing, aborted_fn=abort.is_set,
                    session_fn=mon.session_ok, quiet_exec=host.quiet_exec,
                    recovery_dir=os.path.join(TOOLS_DIR, "recovery", run_id))
        c.created_ever = created_ever
        c.blocked_domains = blocked_domains          # shared: a domain whose restore failed stays off limits for every column
        return c

    try:
        for level in [lv for lv in ("scripted", "agent", "micro") if any(l == lv for l, _ in plan)]:
            tools = [t for lv, t in plan if lv == level]
            # Awake only for this level and only for its budget; released between levels. This also holds off the
            # screensaver lock, so the exposure is bounded and the run stops when the budget ends.
            budget = level_budget_s(level, len(tasks), len(tools))
            awake = host.hold_awake(budget)
            st.deadline = time.monotonic() + budget
            try:
                if level == "micro":
                    for tool in tool_order(tools, 0):
                        why = st.gate() if not st.stop else st.stop_reason
                        if why:
                            st.halt(why)
                            break
                        ctx = context(level, tool, micro_doing(tool, p, exec_fn))
                        try:
                            m = run_micro_level(tool, ctx)
                        except Aborted:
                            m = {"status": "n/a", "why": "stopped: input seen, monitor lost or screen locked", "latency": None}
                        except Exception as e:  # noqa: BLE001
                            m = {"status": "n/a", "why": f"{type(e).__name__}: {e}"[:300], "latency": None}
                        if abort.is_set() and not st.stop:
                            st.halt(st.reason_text())
                        hok, _hwhy = mon.healthy()
                        good = m.get("status") == "ok" and not st.stop and not abort.is_set() and hok
                        report.write_result(results_dir, {"tool": tool, "level": level, "date": date, "hms": hms, "run_id": run_id,
                                                          "only": None, "full": good, "versions": versions,
                                                          "micro": m, "aborted": None if good else (m.get("why") or st.stop_reason or "not a clean measurement"),
                                                          "monitor": mon.health(), "host_state": host_state})
                    continue
                ctxs = {tool: context(level, tool, make_doing(level, tool, p, exec_fn, os.path.join(workdir, f"{level}-{tool}"), cwd))
                        for tool in tools}
                records, dead = run_group(tasks, ctxs, st, level=level,
                                          progress=lambda lv, tool, t, rec: print(f"  {lv:<8} {tool:<20} {t['id']:<34} {rec['status']}"))
                for tool in tools:
                    finish(level, tool, records[tool], dead)
            finally:
                awake.terminate()
                st.deadline = None
            if st.stop:
                break
    finally:
        for dom, info in blocked_domains.items():
            print(f"RECOVERY NEEDED: Calculator-style preferences {dom} were not restored. Put them back with:\n  {info['command']}\n"
                  f"  (backup directory: {info['recovery']})", file=sys.stderr)
        if st.stop or abort.is_set():
            exit_code = EXIT_USER_ACTIVE
        server.stop()
        shutil.rmtree(workdir, ignore_errors=True)
        shutil.rmtree(cwd, ignore_errors=True)
        report.write_latest(results_dir)
    return exit_code


def _state():
    try:
        return host.read_state()
    except (OSError, ValueError):
        return None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tool", default="all", choices=["baneyspaces", "agent-desktop", "agent-desktop-headed", "chatgpt", "all"])
    ap.add_argument("--level", default="all", choices=["scripted", "agent", "micro", "all"])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--only", type=lambda s: s.split(","), default=None)
    ap.add_argument("--write-latest", action="store_true",
                    help="regenerate results/latest.md from the result files (and the tool versions now); runs nothing")
    ap.add_argument("--date")
    ap.add_argument("--results-dir", default=os.path.join(HERE, "results"))
    args = ap.parse_args(argv)
    p = paths()
    if args.write_latest:
        v = tool_versions(p, Exec())
        print(report.write_latest(args.results_dir, versions=v, today=datetime.date.today().isoformat()))
        return 0
    try:
        return dry_run(args, p) if args.dry_run else real_run(args, p)
    except TaskError as e:
        print(f"task error: {e}", file=sys.stderr)
        return 2
    except Aborted as e:
        print(str(e))
        return EXIT_USER_ACTIVE


if __name__ == "__main__":
    sys.exit(main())
