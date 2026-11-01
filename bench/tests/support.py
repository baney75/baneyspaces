import os
import sys

BENCH = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BENCH not in sys.path:
    sys.path.insert(0, BENCH)

from benchlib.drivers import Driver, Result  # noqa: E402


def node(role, name=None, value=None, ref=None, children=None, states=None, **kw):
    n = {"role": role}
    if name is not None:
        n["name"] = name
    if value is not None:
        n["value"] = value
    if ref:
        n["ref_id"] = ref
    if children:
        n["children"] = children
    if states:
        n["states"] = states
    n.update(kw)
    return n


class FakeDriver(Driver):
    """A driver whose snapshots come from `trees[(wid, surface)]` and whose actions are recorded."""
    name = "fake"

    def __init__(self, trees=None, needs_ref_for_press=False, fail=None):
        super().__init__(None)
        self.trees = trees or {}
        self.needs_ref_for_press = needs_ref_for_press
        self.calls = []
        self.fail = fail or {}

    def resolve(self):
        return True, "fake"

    pid_windows_result = (True, [])

    def pid_windows(self, app, pid):
        self.calls.append(("pid_windows", app, pid))
        return self.pid_windows_result

    def build(self, verb, **kw):
        return [verb]

    def snapshot(self, wid, surface=None):
        self.calls.append(("snapshot", wid, surface))
        if (wid, surface) in self.fail or (wid, None) in self.fail and surface is None:
            return Result(False, None, self.fail.get((wid, surface)) or self.fail[(wid, None)], 5)
        tree = self.trees.get((wid, surface)) or self.trees.get((wid, None))
        if tree is None:
            return Result(False, None, {"code": "window_not_found", "message": "gone", "suggestion": "list windows", "retry": "safe"}, 3)
        return Result(True, {"tree": tree}, None, 7)

    def run(self, verb, timeout=60, **kw):
        self.calls.append((verb, kw))
        if verb in self.fail:
            return Result(False, None, self.fail[verb], 4)
        return Result(True, {"ok": True}, None, 4)


def fake_exec(responses):
    """exec(argv, ...) answering from a list of (predicate, (rc, out, err)) pairs; records argv."""
    seen = []

    def run(argv, timeout=60, env=None, stdin=None):
        seen.append(argv)
        for pred, reply in responses:
            if pred(argv):
                return (*reply, 10)
        return 0, "", "", 10
    run.seen = seen
    return run
