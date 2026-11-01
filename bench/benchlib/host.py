"""The Mac as the harness sees it: idle time, BaneySpaces' state, what is installed or running."""
import json
import os
import re
import subprocess

IDLE_REQUIRED_S = 600
STATE_PATH = os.path.expanduser("~/Library/Application Support/BaneySpaces/state.json")
APP_DIRS = ("/Applications", "/System/Applications", "/System/Applications/Utilities",
            "/Applications/Utilities", os.path.expanduser("~/Applications"))
SANDBOX_AVAILABLE = False   # phase 2 of the design; until it exists every `place: sandbox` task is unavailable
CHATGPT_ROUTE = None        # how ChatGPT's computer use would be run INSIDE the sandbox VM. None: there is none yet.
# Columns that run only in the sandbox VM (#111), never on this Mac: ChatGPT's Sky, which can act on and read
# the whole desktop, and agent-desktop in --headed mode, which takes focus and posts real keys and clicks onto
# Donovan's live session. On the host only the background columns run: BaneySpaces and agent-desktop headless.
SANDBOX_ONLY_TOOLS = ("chatgpt", "agent-desktop-headed")
# What `baneyspaces agent open` starts on the host (phase 1, Policies.swift `separateInstance`): a new instance told
# `-ApplePersistenceIgnoreState YES`, on a file from the handoff folder. Everything else answers needs_sandbox.
AGENT_OPEN_HOST_APPS = {"TextEdit": "com.apple.TextEdit", "Calculator": "com.apple.calculator", "Preview": "com.apple.Preview"}
HANDOFF = os.path.expanduser("~/Library/Application Support/BaneySpaces/hands/handoff")
# ChatGPT's Sky/cua_repl never runs on this Mac: availability() refuses it for every task and codex_command()
# refuses to build the command without a route. No flag or environment variable changes either.


def hid_idle_seconds(run=subprocess.run):
    """Seconds since the last real keyboard or mouse event (IOHIDSystem HIDIdleTime)."""
    out = run(["ioreg", "-c", "IOHIDSystem"], capture_output=True, text=True, timeout=10).stdout
    m = re.search(r'"HIDIdleTime"\s*=\s*(\d+)', out)
    if not m:
        raise RuntimeError("ioreg printed no HIDIdleTime")
    return int(m.group(1)) / 1e9


def idle_gate(idle, required=IDLE_REQUIRED_S):
    """-> (ok, message)"""
    if idle >= required:
        return True, f"idle {idle:.0f} s"
    return False, (f"not run: user active (HIDIdleTime {idle:.0f} s, need {required} s). "
                   "The bench acts on a live Mac and runs only while Donovan is away.")


def read_state(path=STATE_PATH):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def apps_on_user_workspaces(state):
    """App names with a window on a workspace that is not the agent workspace."""
    agent = state.get("agentWorkspace")
    apps = set()
    for ws, wins in (state.get("workspaces") or {}).items():
        if str(ws) == str(agent):
            continue
        for w in wins:
            apps.add(w.get("app", ""))
    return apps


def installed(app, dirs=APP_DIRS, exists=os.path.exists):
    return any(exists(os.path.join(d, app + ".app")) for d in dirs)


def running(app, run=subprocess.run):
    r = run(["pgrep", "-x", app], capture_output=True, text=True)
    return r.returncode == 0


def availability(task, state, tool=None, *, installed_fn=installed, running_fn=running, sandbox=None):
    """None when the task can run here, else why not ("unavailable: ...").

    place: sandbox           needs the phase 2 sandbox; skipped until it exists (once-per-user apps)
    requires.installed       every app must be installed
    requires.exclusive       the app must have no window on a workspace of Donovan's: key presses and
                             menus act on an app's key window, and it must not be his
    requires.not_running     the app must not be running at all (we start it, hide it, quit it)
    requires.env             environment flags that must be 1 (e.g. the agent browser profile exists)
    A task is checked here at every level (scripted, agent and micro), before anything is opened.
    """
    if tool in SANDBOX_ONLY_TOOLS and (tool != "chatgpt" or CHATGPT_ROUTE is None or task.get("place", "host") != "sandbox"):
        return (f"unavailable: sandbox_only: {tool} runs only inside the sandbox VM (needs sandbox, #111), never on this Mac")
    if task.get("place", "host") == "sandbox" and not (SANDBOX_AVAILABLE if sandbox is None else sandbox):
        return "unavailable: needs sandbox (phase 2)"
    if task.get("place", "host") == "host":
        refused = [o["app"] for o in task["setup"].get("open", []) if o["app"] not in AGENT_OPEN_HOST_APPS]
        if refused:
            return (f"unavailable: needs sandbox: `baneyspaces agent open` starts only {', '.join(sorted(AGENT_OPEN_HOST_APPS))} on the host "
                    f"(it answers needs_sandbox for {refused[0]})")
    req = task["setup"].get("requires", {})
    for app in req.get("installed", []):
        if not installed_fn(app):
            return f"unavailable: {app} is not installed on this Mac"
    if state is None and (req.get("exclusive")):
        return "unavailable: BaneySpaces state.json is unreadable, so Donovan's windows cannot be ruled out"
    mine = apps_on_user_workspaces(state) if state else set()
    for app in req.get("exclusive", []):
        if app in mine:
            return f"unavailable: {app} has a window on one of Donovan's workspaces"
    for app in req.get("not_running", []):
        if running_fn(app):
            return f"unavailable: {app} is already running (not Donovan's to drive)"
    for var in req.get("env", []):
        if os.environ.get(var) != "1":
            return f"unavailable: needs {var}=1 ({req.get('env_why', 'not set up on this Mac')})"
    return None


def micro_task(tool):
    """The micro level as a task, so it goes through the runner's own setup path (drain, attribution, leak check,
    window ownership, teardown): TextEdit on an empty file and Calculator, both the bench's own."""
    req = {"installed": ["TextEdit", "Calculator"], "exclusive": ["TextEdit"], "not_running": ["Calculator"]}
    if tool == "chatgpt":
        req["not_running"] = ["Calculator", "TextEdit"]   # Sky addresses an app, not a window: ours must be the only one
    return {"id": f"micro-{tool}", "app": "TextEdit", "category": "micro", "place": "host", "goal": "per-action latency",
            "setup": {"requires": req, "files": {"micro.txt": ""}, "restore_defaults": ["com.apple.calculator"],
                      "quit_after": ["Calculator"], "settle_s": 1.0,
                      "open": [{"app": "TextEdit", "as": "text", "targets": ["{tmp}/micro.txt"], "title": "micro.txt"},
                               {"app": "Calculator", "as": "calc", "title": "Calculator"}]},
            "steps": [{"do": "wait", "ms": 0}], "check": {"kind": "nothing"}}


CAFFEINATE = ["caffeinate", "-dims"]
# -d display, -i idle sleep, -m disk, -s system sleep. Not -u: that declares user activity, which would reset the
# very idle clock the run's guard reads. Held with `-t <budget>` only for the level being run, so a stuck run lets go.


def hold_awake(budget_s, popen=subprocess.Popen):
    """Keep the display and the system awake for at most `budget_s` seconds. Returns the process (terminate it
    when the level ends). Holding the display awake also holds off the screensaver lock, so it is bounded."""
    return popen(CAFFEINATE + ["-t", str(int(budget_s))], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def session_gate(ok, state):
    """-> (ok, message) from the monitor's session state (locked, asleep, off console, loginwindow in front, secure input)."""
    if ok:
        return True, "screen awake and unlocked"
    why = [k for k in ("locked", "asleep", "loginwindow") if state.get(k)]
    if state.get("secure_input"):
        why.append("under secure keyboard input (someone may be typing)")
    if state.get("console") is False:
        why.append("not on the console")
    return False, ("not run: the screen is " + ", ".join(why or ["not usable"]) +
                   ". Actions on a locked or sleeping Mac fail or land on the login window; wake and unlock it, then start the run.")


def list_dir(path):
    try:
        return sorted(os.listdir(path))
    except OSError:
        return []


def collateral(before, after):
    """Entries that appeared in a watched directory while a tool ran."""
    return sorted(set(after) - set(before))
