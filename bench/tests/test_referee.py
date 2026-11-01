import os
import tempfile
import unittest

import support
from support import FakeDriver, node
from benchlib.referee import Referee


class Fake:
    def __init__(self, subs):
        self.submissions = subs


class Checks(unittest.TestCase):
    def ref(self, trees=None, subs=()):
        d = FakeDriver(trees or {})
        return Referee(d.snapshot, {"doc": 7, "gone": 99}, Fake(list(subs)))

    def test_file_kinds(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "a.txt")
            open(p, "w").write("hello world")
            r = self.ref()
            self.assertTrue(r.evaluate({"kind": "file", "path": p, "equals": "hello world"})[0])
            self.assertFalse(r.evaluate({"kind": "file", "path": p, "equals": "hello"})[0])
            self.assertTrue(r.evaluate({"kind": "file", "path": p, "contains": "lo wo"})[0])
            self.assertTrue(r.evaluate({"kind": "file", "path": p, "regex": "w.rld$"})[0])
            self.assertTrue(r.evaluate({"kind": "file", "path": d, "is_dir": True})[0])
            self.assertTrue(r.evaluate({"kind": "file", "path": os.path.join(d, "no"), "absent": True})[0])
            self.assertFalse(r.evaluate({"kind": "file", "path": os.path.join(d, "no")})[0])

    def test_bold_rtf_regex_matches_bold_only(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "n.rtf")
            c = {"kind": "file", "path": p, "regex": "\\\\b[ \\\\]"}
            open(p, "w").write(r"{\rtf1\f0\fs24 plain}")
            self.assertFalse(self.ref().evaluate(c)[0])
            open(p, "w").write(r"{\rtf1\f0\b\fs24 bold}")
            self.assertTrue(self.ref().evaluate(c)[0])

    def test_form_needs_every_field(self):
        r = self.ref(subs=[{"name": "Ada", "email": "x"}])
        self.assertTrue(r.evaluate({"kind": "form", "fields": {"name": "Ada"}})[0])
        self.assertFalse(r.evaluate({"kind": "form", "fields": {"name": "Ada", "email": "y"}})[0])
        self.assertFalse(self.ref().evaluate({"kind": "form", "fields": {"name": "Ada"}})[0])

    def test_ax_value_and_window_title(self):
        tree = node("window", "Appearance", children=[node("textfield", value="abc\n", ref="@s:e1"),
                                                      node("scrollbar", value="0.6"), node("scrollbar", value="0.1", states=["disabled"])])
        r = self.ref({(7, None): tree})
        self.assertTrue(r.evaluate({"kind": "ax", "window": "doc", "target": {"role": "textfield"}, "equals": "abc"})[0])
        self.assertTrue(r.evaluate({"kind": "ax", "window": "doc", "target": {"role": "textfield"}, "contains": "bc"})[0])
        self.assertFalse(r.evaluate({"kind": "ax", "window": "doc", "target": {"role": "textfield"}, "equals": "abd"})[0])
        self.assertTrue(r.evaluate({"kind": "ax", "window": "doc", "target": {"role": "scrollbar", "not_state": "disabled"}, "gt": 0.2})[0])
        self.assertFalse(r.evaluate({"kind": "ax", "window": "doc", "target": {"role": "scrollbar", "state": "disabled"}, "gt": 0.2})[0])
        self.assertTrue(r.evaluate({"kind": "window_title", "window": "doc", "equals": "appearance"})[0])
        self.assertFalse(r.evaluate({"kind": "window_title", "window": "doc", "contains": "display"})[0])
        self.assertTrue(r.evaluate({"kind": "ax", "window": "doc", "target": {"role": "button"}, "exists": False})[0])

    def test_a_closed_window_cannot_be_read(self):
        ok, why = self.ref().evaluate({"kind": "window_title", "window": "gone", "contains": "x"})
        self.assertFalse(ok)
        self.assertIn("unreadable", why)

    def test_menubar_surface_is_requested(self):
        d = FakeDriver({(7, "menubar"): node("menubar", children=[node("menuitem", "Make Rich Text", ref="@m:e1")])})
        r = Referee(d.snapshot, {"doc": 7})
        self.assertTrue(r.evaluate({"kind": "ax", "window": "doc", "surface": "menubar", "target": {"name": "Make Rich Text"}})[0])

    def test_answer_check(self):
        ref = Referee(FakeDriver({}).snapshot, {}, answer="DONE the name is doc-ab12.pdf")
        self.assertTrue(ref.evaluate({"kind": "answer", "contains": "doc-ab12.pdf"})[0])
        self.assertFalse(ref.evaluate({"kind": "answer", "contains": "doc-ffff.pdf"})[0])
        self.assertFalse(Referee(FakeDriver({}).snapshot, {}).evaluate({"kind": "answer", "contains": "x"})[0])

    def test_window_gone(self):
        d = FakeDriver({(7, None): node("window", "x")})
        r = Referee(d.snapshot, {"open": 7, "closed": 8})
        self.assertFalse(r.evaluate({"kind": "window_gone", "window": "open"})[0])
        self.assertTrue(r.evaluate({"kind": "window_gone", "window": "closed"})[0])

    def test_all_stops_at_the_first_failure(self):
        r = self.ref(subs=[{"a": "1"}])
        ok, d = r.evaluate({"kind": "all", "checks": [{"kind": "form", "fields": {"a": "1"}}, {"kind": "form", "fields": {"a": "2"}}]})
        self.assertFalse(ok)


if __name__ == "__main__":
    unittest.main()
