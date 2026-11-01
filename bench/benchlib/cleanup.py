"""Teardown: close the windows the bench itself opened, nothing else.

Window ids are recorded when the bench opens them. A window is closed only if its id is one of those
AND `agent status` still lists it on the agent workspace. The only buttons pressed are the window's own
Close button (a direct child of the window root) and, on a sheet or alert, "Don't Save". Never "Delete",
"Discard" or anything matched by text in the main window tree: those are real commands in real apps.
"""
from .script import find_all, ref_of

DECLINE = ("Don't Save", "Don’t Save")
GONE_CODES = ("window_not_found", "app_not_found")


def is_gone(res):
    """Only the tool saying the window or app does not exist counts as closed. A timeout, a crash or a permission
    error says nothing about the window, which may well still be open."""
    return (not res.ok) and res.code in GONE_CODES


def window_close_button(tree):
    """The window's own Close button: a direct child of the root, never one deeper in the tree."""
    for child in tree.get("children") or []:
        if str(child.get("role", "")).lower() == "button" and child.get("name") == "Close" and ref_of(child):
            return child
    return None


def decline_button(tree):
    for name in DECLINE:
        hits = [h for h in find_all(tree, {"role": "button", "name": name, "exact": True}) if ref_of(h)]
        if hits:
            return hits[0]
    return None


def close_windows(driver, created, agent_windows, rounds=3, should_stop=lambda: False):
    """Close each created window id that is still ours. -> (closed ids, left ids with a reason).

    created: ids the bench opened; agent_windows(): {id: (app, title)} now on the agent workspace.
    should_stop() is the run's abort: checked before EVERY action, so teardown never keeps acting after
    real input, a lost monitor or a lock. What was not closed is reported as left ("interrupted").
    """
    closed, left = [], {}
    for n, wid in enumerate(created):
        if should_stop():
            for rest in created[n:]:
                left[rest] = "interrupted: the run was aborted"
            break
        if wid not in agent_windows():
            res = driver.snapshot(wid)
            if is_gone(res):
                closed.append(wid)          # already gone
            elif res.ok:
                left[wid] = "not on the agent workspace any more; left alone"
            else:
                left[wid] = f"cannot tell whether it is open ({res.code}); left alone"
            continue
        interrupted = False
        for _ in range(rounds):
            if should_stop():
                interrupted = True
                break
            res = driver.snapshot(wid)
            if not res.ok:
                break           # gone, or unreadable: the check after the loop decides which
            tree = (res.data or {}).get("tree") or {}
            btn = window_close_button(tree)
            if btn is not None:
                driver.run("click", ref=ref_of(btn))
            for surface in ("sheet", "alert"):
                if should_stop():
                    interrupted = True
                    break
                sheet = driver.snapshot(wid, surface)
                if sheet.ok:
                    d = decline_button((sheet.data or {}).get("tree") or {})
                    if d is not None:
                        driver.run("click", ref=ref_of(d))
            if interrupted:
                break
        if interrupted:
            left[wid] = "interrupted: the run was aborted"
        else:
            final = driver.snapshot(wid)
            if is_gone(final):
                closed.append(wid)
            elif final.ok:
                left[wid] = "still open after three close attempts"
            else:
                left[wid] = f"cannot tell whether it closed ({final.code})"
    return closed, left
