"""Task files: loading, validation and placeholder expansion.

A task is one JSON file in bench/tasks. Both runners execute the same `steps`; only the command line
they build for each step differs (see drivers.py).
"""
import json
import os
import re

TOOLS = ("baneyspaces", "agent-desktop", "agent-desktop-headed")

STEP_VERBS = {
    "snapshot", "click", "type", "set-value", "press", "scroll", "select", "toggle", "menu", "wait", "get",
}
CHECK_KINDS = {"file", "ax", "window_title", "window_gone", "answer", "form", "nothing", "all"}
PLACES = {"host", "sandbox"}
# Apps with one instance per user: they hold Donovan's data, so they only run in the sandbox.
ONCE_PER_USER = {"Notes", "Safari", "Mail", "Calendar", "Messages", "Photos", "Reminders", "Contacts"}
CATEGORIES = {
    "textedit", "finder", "notes", "settings", "calculator", "preview", "browser", "electron",
    "menu", "dialog", "scroll", "hidden", "two-window", "refusal",
}
SURFACES = {"window", "menubar", "sheet", "menu", "focused", "popover", "alert"}
PLACEHOLDER = re.compile(r"\{(tmp|base|port|fixtures|nonce)\}")


class TaskError(ValueError):
    pass


def load_tasks(directory):
    """Every bench/tasks/*.json, sorted by id, validated."""
    tasks = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(directory, name)
        with open(path, encoding="utf-8") as fh:
            try:
                task = json.load(fh)
            except json.JSONDecodeError as exc:
                raise TaskError(f"{name}: not valid JSON: {exc}") from exc
        if task.get("id") != name[:-5]:
            raise TaskError(f"{name}: id must be {name[:-5]!r}, not {task.get('id')!r}")
        validate(task)
        tasks.append(task)
    ids = [t["id"] for t in tasks]
    if len(set(ids)) != len(ids):
        raise TaskError("duplicate task ids")
    return tasks


def validate(task):
    tid = task.get("id", "?")

    def bad(msg):
        raise TaskError(f"{tid}: {msg}")

    for key in ("id", "app", "category", "goal", "setup", "steps", "check"):
        if key not in task:
            bad(f"missing {key}")
    if task["category"] not in CATEGORIES:
        bad(f"unknown category {task['category']!r}")
    place = task.get("place", "host")
    if place not in PLACES:
        bad(f"unknown place {place!r}")
    if not isinstance(task["steps"], list) or not task["steps"]:
        bad("steps must be a non-empty list")
    setup = task["setup"]
    aliases = {o["as"] for o in setup.get("open", [])}
    req = setup.get("requires", {})
    if place == "host":
        apps = {o["app"] for o in setup.get("open", [])}
        for app in apps & ONCE_PER_USER:
            bad(f"{app} is a once-per-user app: its task must be place: sandbox")
        for app in apps:
            if app not in req.get("exclusive", []) and app not in req.get("not_running", []):
                bad(f"host task opens {app} without requires.exclusive or requires.not_running for it")
        if task["category"] == "browser" and not setup.get("profile"):
            bad("a host browser task needs setup.profile (a fresh --user-data-dir under the bench temp dir)")
        if task["category"] == "browser" and task["app"] not in req.get("not_running", []):
            bad("a host browser task needs requires.not_running for the browser")
    for app in setup.get("quit_after", []):
        if app not in req.get("not_running", []):
            bad(f"quit_after {app} is only safe for an app required not_running")
    if setup.get("hide") and setup["hide"] not in req.get("not_running", []):
        bad("hide is only safe for an app required not_running")
    if task.get("requires_tool_call") and not _has_answer(task["check"]):
        bad("requires_tool_call tasks need an answer check")
    # The nonce is the thing only observing the window can tell: it lives in a document's CONTENT and
    # nowhere an agent is told or can list (goal, window titles, file names, the open target).
    blob_outside = json.dumps({"goal": task["goal"], "open": setup.get("open", []), "file_names": list(setup.get("files", {}))})
    if "{nonce}" in blob_outside:
        bad("{nonce} may only appear inside a file's content and in the check, never in the goal, a title or a file name")
    if place == "host" and task["category"] == "electron" and not setup.get("profile"):
        bad("a host Electron task needs setup.profile (a fresh --user-data-dir: it restores the previous session's windows otherwise)")
    for alias in setup.get("close_before_run", []):
        if alias not in aliases:
            bad(f"close_before_run names {alias!r}, which setup.open does not open")
    for f in task.get("allowed_change_fields", []):
        if f not in ("front", "key_window"):
            bad(f"allowed_change_fields may only name front and key_window, not {f!r}")
    for o in setup.get("open", []):
        if "app" not in o or "as" not in o:
            bad("setup.open entries need app and as")
    for i, step in enumerate(task["steps"]):
        if step.get("do") not in STEP_VERBS:
            bad(f"step {i}: unknown verb {step.get('do')!r}")
        win = step.get("window")
        if win is not None and win not in aliases:
            bad(f"step {i}: window {win!r} is not opened by setup.open")
        if step["do"] == "menu" and not step.get("path"):
            bad(f"step {i}: menu needs path")
        if step["do"] in ("click", "type", "set-value", "scroll", "select", "toggle", "get"):
            if "target" not in step and "ref" not in step:
                bad(f"step {i}: {step['do']} needs target or ref")
        if step["do"] in ("snapshot",) and win is None and "window_id" not in step:
            bad(f"step {i}: snapshot needs window or window_id")
        for s in step.get("surfaces", []):
            if s not in SURFACES:
                bad(f"step {i}: unknown surface {s!r}")
    _check(task["check"], aliases, bad)
    for tool, exp in task.get("expected_fail", {}).items():
        if tool not in TOOLS:
            bad(f"expected_fail names unknown tool {tool!r}")
        if not exp.get("why"):
            bad(f"expected_fail for {tool} needs a why")
    if task.get("impossible") and task["category"] != "refusal":
        bad("impossible tasks are in the refusal category")
    if task["category"] == "refusal":
        if not task.get("impossible"):
            bad("refusal tasks set impossible: true")
        if not any(s.get("expect_refusal") for s in task["steps"]):
            bad("refusal tasks need a step with expect_refusal")


def _has_answer(check):
    return check.get("kind") == "answer" or any(_has_answer(c) for c in check.get("checks", []))


def _check(check, aliases, bad):
    kind = check.get("kind")
    if kind not in CHECK_KINDS:
        bad(f"unknown check kind {kind!r}")
    if kind == "all":
        for sub in check.get("checks", []):
            _check(sub, aliases, bad)
        if not check.get("checks"):
            bad("check all needs checks")
    if kind in ("ax", "window_title", "window_gone") and check.get("window") not in aliases:
        bad(f"check window {check.get('window')!r} is not opened by setup.open")


def expand(value, ctx):
    """Replace {tmp}, {base}, {port}, {fixtures}, {nonce} in every string of a JSON value, dict keys included
    (fixture paths are keys)."""
    if isinstance(value, str):
        return PLACEHOLDER.sub(lambda m: str(ctx[m.group(1)]), value)
    if isinstance(value, list):
        return [expand(v, ctx) for v in value]
    if isinstance(value, dict):
        return {expand(k, ctx): expand(v, ctx) for k, v in value.items()}
    return value
