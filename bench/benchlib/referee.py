"""Reading the result back, the same way for every tool.

Checks read the file system, the fixture server's log, or the window through agent-desktop's
read-only `snapshot` (never an action). A tool is never asked whether it succeeded.
"""
import os
import re

from .script import find_all, ref_of, role_of, walk


class Referee:
    """`snapshot(wid, surface)` returns a driver Result; `windows` maps alias -> window id."""

    def __init__(self, snapshot, windows, server=None, answer=""):
        self.snapshot = snapshot
        self.windows = windows
        self.server = server
        self.answer = answer or ""

    def _answer(self, c):
        """What the tool or its agent reported, which only observing the app could have told it."""
        if "contains" in c:
            ok = c["contains"] in self.answer
            return ok, f"answer {'has' if ok else 'lacks'} {c['contains']!r} (answer: {self.answer[:80]!r})"
        return False, "answer check needs contains"

    def _window_gone(self, c):
        wid = self.windows.get(c["window"])
        res = self.snapshot(wid, None) if wid is not None else None
        gone = res is not None and not res.ok and res.code in ("window_not_found", "app_not_found")
        return gone, f"window {wid} {'is gone' if gone else 'is still there'}"

    def evaluate(self, check):
        """-> (passed, detail)"""
        kind = check["kind"]
        return getattr(self, "_" + kind)(check)

    def _nothing(self, check):
        return True, "no side effect expected"

    def _all(self, check):
        details = []
        for sub in check["checks"]:
            ok, d = self.evaluate(sub)
            details.append(d)
            if not ok:
                return False, "; ".join(details)
        return True, "; ".join(details)

    def _file(self, c):
        path = c["path"]
        if c.get("absent"):
            return (not os.path.exists(path)), f"{path} {'absent' if not os.path.exists(path) else 'still exists'}"
        if not os.path.exists(path):
            return False, f"{path} does not exist"
        if c.get("is_dir"):
            return os.path.isdir(path), f"{path} is {'a' if os.path.isdir(path) else 'not a'} directory"
        with open(path, "rb") as fh:
            body = fh.read().decode("utf-8", "replace")
        if "equals" in c:
            ok = body == c["equals"] or (c.get("strip") and body.strip() == c["equals"].strip())
            return ok, f"{os.path.basename(path)} = {body[:80]!r}"
        if "contains" in c:
            return c["contains"] in body, f"{os.path.basename(path)} {'has' if c['contains'] in body else 'lacks'} {c['contains']!r}"
        if "regex" in c:
            hit = re.search(c["regex"], body) is not None
            return hit, f"{os.path.basename(path)} {'matches' if hit else 'does not match'} /{c['regex']}/"
        return True, f"{path} exists"

    def _form(self, c):
        subs = self.server.submissions if self.server else []
        want = c["fields"]
        for s in subs:
            if all(s.get(k) == v for k, v in want.items()):
                return True, f"form received {want}"
        return False, f"form received {subs[-1] if subs else 'nothing'}, wanted {want}"

    def _read(self, c):
        wid = self.windows.get(c["window"])
        if wid is None:
            return None, "window was never opened"
        res = self.snapshot(wid, c.get("surface"))
        if not res.ok:
            return None, f"window {wid} unreadable: {res.code}"
        return (res.data or {}).get("tree") or {}, ""

    def _window_title(self, c):
        tree, why = self._read(c)
        if tree is None:
            return False, why
        title = tree.get("name") or tree.get("title") or ""
        if "equals" in c:
            return title.strip().lower() == c["equals"].strip().lower(), f"title {title!r}"
        return c["contains"].lower() in title.lower(), f"title {title!r}"

    def _ax(self, c):
        tree, why = self._read(c)
        if tree is None:
            return False, why
        hits = find_all(tree, c["target"])
        want_exists = c.get("exists", True)
        if "equals" not in c and "contains" not in c and "gt" not in c:
            return (bool(hits) == want_exists), f"{len(hits)} match(es) for {c['target']}"
        prop = c.get("property", "value")
        values = [str(h.get(prop, "")) for h in hits]
        if not hits:
            return False, f"nothing matched {c['target']}"
        for v in values:
            if "equals" in c and (v == c["equals"] or (c.get("strip", True) and v.strip() == c["equals"].strip())):
                return True, f"{prop} = {v[:80]!r}"
            if "contains" in c and c["contains"] in v:
                return True, f"{prop} has {c['contains']!r}"
            if "gt" in c:
                try:
                    if float(v) > c["gt"]:
                        return True, f"{prop} {v} > {c['gt']}"
                except ValueError:
                    pass
        return False, f"{prop} was {[v[:60] for v in values]}"
