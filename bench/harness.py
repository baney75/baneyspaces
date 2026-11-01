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
from benchlib.execs import Aborted, Exec  # noqa: E402
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
            if parsed.get("refusals"):
                r = parsed["refusals"][-1]          # the TOOL's own code and suggestion (never the guard's), not the agent's prose
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

    def halt(self, why):
        self.stop, self.stop_reason = True, why

    def gate(self):
        """Before every task (and micro run): -> None, or why the run must stop. Real idle >= 600 s, screen usable."""
        if self.abort.is_set():
            return self.reason_text()
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
                    if st.abort.is_set() and not st.stop:
                        st.halt(st.reason_text())
            records[tool].append(rec)
            progress(level, tool, t, rec)
    return records, dead


def run_micro_level(tool, p, exec_fn, opener, workdir, referee_driver, cleanup_driver, state_fn, aborted_fn,
                    running_fn=host.running):
    """-> result dict for the micro level of one tool. Same availability gate as a task; only windows
    this function opened are touched, and Calculator is quit only if it was not running before."""
    from benchlib import fixtures
    why = host.availability(host.micro_task(tool), state_fn(), tool)
    if why:
        return {"status": "n/a", "why": why, "latency": None}
    if tool == "chatgpt":
        raise agents.SandboxOnly("ChatGPT computer use runs only inside the sandbox VM, never on this Mac")
    os.makedirs(workdir, exist_ok=True)
    fixtures.write_files(workdir, {"micro.txt": ""})
    created = []
    started = [a for a in ("TextEdit", "Calculator") if not running_fn(a)]
    try:
        te, _ = opener.open("TextEdit", [os.path.join(workdir, "micro.txt")])
        if te is not None:
            created.append(te)
        calc, _ = opener.open("Calculator", [])
        if calc is not None:
            created.append(calc)
        if te is None or calc is None:
            return {"status": "n/a", "why": "could not open TextEdit and Calculator on the agent workspace", "latency": None}
        time.sleep(1.0)
        if tool == "baneyspaces":
            driver = BaneySpacesDriver(exec_fn, p["baneyspaces"])
            noop = [p["baneyspaces"], "--version"]
        else:
            driver = AgentDesktopDriver(exec_fn, p["agent_desktop"])
            noop = [p["agent_desktop"], "--version"]
        noop_ms = micro.noop_spawn_ms(exec_fn, noop)
        lat, errs = micro.run_micro(driver, te, calc, noop_ms)
        problems = micro.invalid(lat, errs)
        # a measurement with failed actions or missing samples is kept as a diagnostic, never as a result
        return {"status": "invalid" if problems else "ok", "latency": lat, "errors": errs, "problems": problems,
                "noop_spawn_ms": noop_ms, "noop_command": noop, "method": micro.METHOD_CLI}
    finally:
        if not aborted_fn():       # after an abort the bench's own windows stay where they are
            try:
                if created:
                    close_windows(cleanup_driver, created, opener.windows, should_stop=aborted_fn)
                for app in started:
                    if not aborted_fn() and running_fn(app):
                        exec_fn(["osascript", "-e", f'tell application "{app}" to quit'], timeout=15)
            except Aborted:
                pass


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

    abort = threading.Event()
    exec_fn = Exec(abort=abort)             # the one abort: tools, teardown and quits all stop on it
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
    mon = monitor.Monitor([p["sampler"]], on_hid=on_hid, on_lost=on_lost, on_session=on_session).start()
    awake = None
    try:
        # The sampler is up: re-check what was true before the (unmonitored) compile, then keep the Mac awake.
        ok, msg = host.idle_gate(mon.real_idle())
        if not ok:
            print(msg)
            return EXIT_USER_ACTIVE
        sess_ok, sess = mon.session_ok()
        sok, smsg = host.session_gate(sess_ok, sess)
        if not sok:
            print(smsg)
            return EXIT_USER_ACTIVE
        awake = host.hold_awake()
        st.idle_fn, st.session_fn, st.tap_ok = mon.real_idle, mon.session_ok, mon.tap_ok
        if not mon.tap_ok:
            print("note: the input tap is unavailable (grant Input Monitoring to the sampler); tools that post input will be skipped")
        return _run_levels(args, p, tasks, plan, mon, st, abort, exec_fn, sess, awake is not None)
    finally:
        if awake is not None:
            awake.terminate()
        mon.stop()


def _run_levels(args, p, tasks, plan, mon, st, abort, exec_fn, sess, awake):
    server = FixtureServer().start()
    workdir = tempfile.mkdtemp(prefix="bench-run-")      # fixtures: private, never referenced in a prompt
    cwd = tempfile.mkdtemp(prefix="bench-cwd-")          # agents' cwd: empty, no path to the fixtures
    opener = Opener(exec_fn, p["baneyspaces"])
    referee_driver = AgentDesktopDriver(exec_fn, p["agent_desktop"])
    cleanup_driver = AgentDesktopDriver(exec_fn, p["agent_desktop"])     # shares the abort
    versions = tool_versions(p, Exec())
    now = datetime.datetime.now()
    date, hms = args.date or now.date().isoformat(), now.strftime("%H%M%S")
    run_id = f"{date}-{hms}-{secrets.token_hex(2)}"
    results_dir = args.results_dir
    exit_code = 0
    host_state = {"session": sess, "caffeinate": " ".join(host.CAFFEINATE) if awake else None, "input_tap": mon.tap_ok}
    caveats = ["ChatGPT computer use runs only inside the sandbox VM and is not measured on this Mac",
               "the BaneySpaces and agent-desktop agent columns are confined (MCP scope, agent-desktop-guard)"]

    def finish(level, tool, recs, dead):
        aborted = dead.get(tool, "")
        aborted = aborted if aborted.startswith("column stopped") else (
            f"stopped: {st.stop_reason}" if st.stop and any(r["status"] == "not_run" for r in recs) else "")
        full = run_is_full(recs, args.only, aborted)
        report.write_result(results_dir, {
            "tool": tool, "level": level, "date": date, "hms": hms, "run_id": run_id, "only": args.only, "full": full,
            "versions": versions, "host": os.uname().nodename, "aborted": aborted or None, "tasks": recs,
            "summary": scoring.summarize(recs), "monitor": mon.health(), "host_state": host_state, "caveats": caveats})

    try:
        for level in [lv for lv in ("scripted", "agent", "micro") if any(l == lv for l, _ in plan)]:
            tools = [t for lv, t in plan if lv == level]
            if level == "micro":
                for tool in tool_order(tools, 0):
                    why = st.gate() if not st.stop else st.stop_reason
                    if why:
                        st.halt(why)
                        break
                    if tool in SENDS_INPUT and not mon.tap_ok and tool != "chatgpt":
                        m = {"status": "n/a", "why": "needs the sampler's input tap (Input Monitoring)", "latency": None}
                    else:
                        try:
                            m = run_micro_level(tool, p, exec_fn, opener, os.path.join(workdir, "micro-" + tool), referee_driver,
                                                cleanup_driver, _state, abort.is_set)
                        except Aborted:
                            m = {"status": "n/a", "why": "stopped: input seen, monitor lost or screen locked", "latency": None}
                        except Exception as e:  # noqa: BLE001
                            m = {"status": "n/a", "why": f"{type(e).__name__}: {e}"[:300], "latency": None}
                    if abort.is_set() and not st.stop:
                        st.halt(st.reason_text())
                    report.write_result(results_dir, {"tool": tool, "level": level, "date": date, "hms": hms, "run_id": run_id,
                                                      "only": None, "full": m.get("status") == "ok", "versions": versions,
                                                      "micro": m, "aborted": None if m.get("status") == "ok" else m.get("why"),
                                                      "monitor": mon.health(), "host_state": host_state})
                continue
            ctxs = {}
            for tool in tools:
                wd = os.path.join(workdir, f"{level}-{tool}")
                os.makedirs(wd, exist_ok=True)
                ctxs[tool] = Context(tool=tool, workdir=wd, server=server, monitor=mon, opener=opener,
                                     referee_driver=referee_driver, cleanup_driver=cleanup_driver, exec_fn=exec_fn,
                                     state_fn=_state, doing=make_doing(level, tool, p, exec_fn, wd, cwd),
                                     aborted_fn=abort.is_set, session_fn=mon.session_ok)
            records, dead = run_group(tasks, ctxs, st, level=level,
                                      progress=lambda lv, tool, t, rec: print(f"  {lv:<8} {tool:<20} {t['id']:<34} {rec['status']}"))
            for tool in tools:
                finish(level, tool, records[tool], dead)
            if st.stop:
                exit_code = EXIT_USER_ACTIVE
                break
    finally:
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
