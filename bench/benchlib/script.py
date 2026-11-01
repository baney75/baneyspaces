"""The task-step interpreter: the same steps for every tool.

A step names a window by alias and a target by semantic selector (role, name, value, text). The
interpreter takes a fresh snapshot of the window, finds the element, and hands the ref to the
driver. Snapshots cost the same for every tool; none is cached.
"""
import time

from .drivers import Result

ROLE_ALIASES = {"textarea": "textfield", "input": "textfield"}


def norm(s):
    return (s or "").replace("…", "").replace("...", "").strip().lower()


def canon_role(role):
    r = norm(role)
    return ROLE_ALIASES.get(r, r)


def role_of(node):
    return canon_role(node.get("role"))


def walk(node, path=()):
    """Depth-first (node, ancestor names) pairs."""
    if not isinstance(node, dict):
        return
    yield node, path
    here = path + (norm(node.get("name")),)
    for child in node.get("children") or []:
        yield from walk(child, here)


def matches(node, sel):
    if "role" in sel:
        if role_of(node) != canon_role(sel["role"]):
            return False
    for field in ("name", "value", "text"):
        if field not in sel:
            continue
        want = norm(sel[field])
        if field == "text":
            haves = [norm(str(node.get(k, ""))) for k in ("name", "value", "title", "description")]
        else:
            haves = [norm(str(node.get(field, "")))]
        if sel.get("exact"):
            if want not in haves:
                return False
        elif not any(want in h for h in haves):
            return False
    if "state" in sel and sel["state"] not in (node.get("states") or []):
        return False
    if "not_state" in sel and sel["not_state"] in (node.get("states") or []):
        return False
    return True


def tree_text(tree):
    """Everything the window shows as text: names, values, titles and descriptions of every node."""
    parts = []
    for n, _ in walk(tree):
        for k in ("name", "value", "title", "description"):
            if n.get(k):
                parts.append(str(n[k]))
    return "\n".join(parts)


def find_all(tree, sel):
    within = norm(sel["within"]) if sel.get("within") else None
    return [n for n, path in walk(tree) if (not within or within in path) and matches(n, sel)]


def ref_of(node):
    return node.get("ref_id") or node.get("ref")


def find_menu_path(tree, names):
    """The node reached by following menu names (File > Save As...) in a menubar tree.

    Wrapper nodes between a menu item and its items are skipped.
    """
    def name_ok(node, want):
        have = norm(node.get("name"))
        return bool(have) and (have == norm(want) or have.startswith(norm(want)))

    def descend(node, remaining):
        if not remaining:
            return node
        for child in node.get("children") or []:
            if name_ok(child, remaining[0]):
                hit = descend(child, remaining[1:])
                if hit:
                    return hit
            elif not norm(child.get("name")):
                hit = descend(child, remaining)
                if hit:
                    return hit
        return None

    return descend(tree, list(names))


class StepError(Exception):
    def __init__(self, code, message, suggestion="", result=None):
        super().__init__(message)
        self.code, self.message, self.suggestion, self.result = code, message, suggestion, result


class Interpreter:
    def __init__(self, driver, windows, poll_s=3.0, sleep=time.sleep, clock=time.monotonic):
        self.driver = driver
        self.windows = windows          # alias -> window id
        self.refs = {}
        self.poll_s = poll_s
        self.sleep, self.clock = sleep, clock
        self.log = []
        self.tool_ms = 0
        self.tool_calls = 0
        self.answers = []          # what the task's read steps returned: the scripted "answer"

    def _wid(self, step):
        if "window_id" in step:
            return step["window_id"]
        return self.windows[step["window"]]

    def _snap(self, wid, surface):
        res = self.driver.snapshot(wid, surface)
        self.tool_ms += res.ms
        self.tool_calls += 1
        return res

    def locate(self, step):
        """Snapshot until the target is found (up to poll_s); return (ref, node)."""
        wid = self._wid(step)
        surfaces = step.get("surfaces") or ["window"]
        sel = step["target"]
        deadline = self.clock() + self.poll_s
        last = None
        while True:
            for surface in surfaces:
                res = self._snap(wid, surface)
                if not res.ok:
                    last = res
                    if surface == surfaces[0] and len(surfaces) == 1:
                        raise StepError(res.code or "snapshot_failed", (res.error or {}).get("message", ""),
                                        res.suggestion, res)
                    continue
                hits = [h for h in find_all((res.data or {}).get("tree") or {}, sel) if ref_of(h)]
                if hits:
                    nth = sel.get("nth", 0)
                    node = hits[nth] if nth < len(hits) else hits[-1]
                    return ref_of(node), node
            if self.clock() >= deadline:
                break
            self.sleep(0.25)
        raise StepError(last.code if last is not None and not last.ok else "target_not_found",
                        (last.error or {}).get("message", "") if last is not None and not last.ok
                        else f"no element matched {sel}",
                        (last.suggestion if last is not None and not last.ok else "Take a snapshot and check the selector."),
                        last)

    def locate_menu(self, step):
        res = self._snap(self._wid(step), "menubar")
        self._require(res)
        node = find_menu_path((res.data or {}).get("tree") or {}, step["path"])
        if not node or not ref_of(node):
            raise StepError("target_not_found", f"no menu item {' > '.join(step['path'])}", "", res)
        return ref_of(node), node

    def press_ref(self, step):
        """BaneySpaces aims a key through a ref in the window: the target's, else the first usable one."""
        if step.get("ref") in self.refs:
            return self.refs[step["ref"]]
        if "target" in step:
            return self.locate(step)[0]
        res = self._snap(self._wid(step), None)
        self._require(res)
        for node, _ in walk((res.data or {}).get("tree") or {}):
            if ref_of(node) and role_of(node) in ("textfield", "table", "list", "scrollarea", "button", "outline"):
                return ref_of(node)
        raise StepError("target_not_found", "nothing in the window to aim a key at", "", res)

    def run(self, steps):
        """Run steps in order. Returns {"ok", "refusal", "failed_step", "why"}; the log is self.log."""
        refusal = None
        for i, step in enumerate(steps):
            expect_refusal = step.get("expect_refusal", False)
            try:
                res = self.step(step)
            except StepError as e:
                r = e.result
                info = {"code": e.code, "suggestion": e.suggestion, "message": e.message[:200],
                        "ok": False, "ms": r.ms if r else 0}
                if expect_refusal and r is not None and not r.ok and r.error and e.code != "target_not_found":
                    # the TOOL said no, with its own code and suggestion
                    refusal = {"code": e.code, "suggestion": e.suggestion, "retry": r.error.get("retry")}
                    self.log.append({"do": step["do"], "refused": True, **info})
                    continue
                if expect_refusal:
                    # the bench's own selector matched nothing: not the tool refusing, and not credited
                    self.log.append({"do": step["do"], "harness_error": True, **info})
                    return {"ok": False, "refusal": None, "failed_step": i,
                            "why": f"not a tool refusal: {e.code}: {e.message[:100]}", "harness_error": True}
                self.log.append({"do": step["do"], **info})
                if step.get("optional"):
                    continue
                return {"ok": False, "refusal": None, "failed_step": i, "why": f"{e.code}: {e.message[:120]}"}
            self.log.append({"do": step["do"], **res.brief()})
            if expect_refusal:
                return {"ok": False, "refusal": None, "failed_step": i,
                        "why": "the tool did it instead of refusing"}
        return {"ok": True, "refusal": refusal, "failed_step": None, "why": ""}

    def step(self, step):
        do = step["do"]
        if do == "wait":
            self.sleep(step.get("ms", 300) / 1000)
            return Result(True)
        if do == "snapshot":
            res = self._snap(self._wid(step), (step.get("surfaces") or [None])[0])
            self._require(res)
            if step.get("answer_from") == "title":
                self.answers.append(str(((res.data or {}).get("tree") or {}).get("name", "")))
            elif step.get("answer_from") == "tree_text":
                self.answers.append(tree_text((res.data or {}).get("tree") or {}))
            return res
        if do == "menu":
            ref, _ = self.locate_menu(step)
            return self._act("click", step, ref=ref)
        if do == "press":
            ref = self.press_ref(step) if self.driver.needs_ref_for_press else None
            return self._act("press", step, ref=ref, key=step["key"])
        if step.get("ref") in self.refs:
            ref = self.refs[step["ref"]]
        else:
            ref, _ = self.locate(step)
        if step.get("save_ref"):
            self.refs[step["save_ref"]] = ref
        kw = {"ref": ref}
        if do in ("type", "set-value"):
            kw["text"] = step["text"] if do == "type" else step["value"]
        elif do == "scroll":
            kw["direction"] = step["direction"]
            kw["amount"] = step.get("amount", 3)
        elif do == "select":
            kw["option"] = step.get("option")
        elif do == "get":
            kw["prop"] = step.get("property")
        return self._act(do, step, **kw)

    def _act(self, verb, step, **kw):
        wid = self._wid(step) if ("window" in step or "window_id" in step) else None
        res = self.driver.run(verb, wid=wid, **kw)
        self.tool_ms += res.ms
        self.tool_calls += 1
        self._require(res)
        if verb == "get":
            self.answers.append(str((res.data or {}).get("value", (res.data or {}).get("text", ""))))
        return res

    @staticmethod
    def _require(res):
        if not res.ok:
            raise StepError(res.code or "error", (res.error or {}).get("message", ""), res.suggestion, res)
