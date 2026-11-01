import unittest

import support
from support import FakeDriver, node
from benchlib import script
from benchlib.script import Interpreter


def textedit_tree():
    return node("window", "doc.txt", children=[
        node("scrollarea", children=[node("textfield", value="hello", ref="@s1:e2")]),
        node("button", "Close", ref="@s1:e5"),
        node("scrollbar", value="0.5", states=["disabled"]),
        node("scrollbar", value="0.4", ref="@s1:e9")])


class Selectors(unittest.TestCase):
    def test_role_and_name(self):
        t = textedit_tree()
        self.assertEqual(len(script.find_all(t, {"role": "button", "name": "close"})), 1)
        self.assertEqual(len(script.find_all(t, {"role": "textarea"})), 1)

    def test_exact_text_matches_one_field(self):
        t = node("window", children=[node("button", "7", description="7"), node("button", "17", ref="@s:e2")])
        self.assertEqual(len(script.find_all(t, {"role": "button", "text": "7", "exact": True})), 1)
        self.assertEqual(len(script.find_all(t, {"role": "button", "text": "7"})), 2)

    def test_not_state(self):
        hits = script.find_all(textedit_tree(), {"role": "scrollbar", "not_state": "disabled"})
        self.assertEqual([h["value"] for h in hits], ["0.4"])

    def test_within(self):
        t = node("menubar", children=[node("menuitem", "File", children=[node("menuitem", "New Folder", ref="@s:e1")]),
                                      node("menuitem", "Edit", children=[node("menuitem", "New Folder", ref="@s:e2")])])
        hit = script.find_all(t, {"name": "New Folder", "within": "Edit"})
        self.assertEqual(hit[0]["ref_id"], "@s:e2")

    def test_menu_path_skips_wrappers_and_ellipsis(self):
        t = node("menubar", children=[
            node("menuitem", "Format", ref="@s:e1", children=[node("menu", None, children=[
                node("menuitem", "Font", children=[node("menu", None, children=[node("menuitem", "Bold", ref="@s:e7")])]),
                node("menuitem", "Make Plain Text", ref="@s:e8")])]),
            node("menuitem", "File", ref="@s:e2")])
        self.assertEqual(script.find_menu_path(t, ["Format", "Make Plain Text"])["ref_id"], "@s:e8")
        self.assertEqual(script.find_menu_path(t, ["Format", "Font", "Bold"])["ref_id"], "@s:e7")
        self.assertIsNone(script.find_menu_path(t, ["Format", "Nope"]))


def interp(driver, windows=None):
    return Interpreter(driver, windows or {"doc": 7}, poll_s=0.0, sleep=lambda s: None)


class RoleAliases(unittest.TestCase):
    def test_both_sides_are_normalised(self):
        """second-F17: a node that reports 'textarea' matches a selector that says 'textfield', and the reverse."""
        for node_role in ("textarea", "textfield", "input"):
            n = node("window", children=[node(node_role, value="v", ref="@s:e1")])
            for sel in ("textarea", "textfield", "input"):
                self.assertEqual(len(script.find_all(n, {"role": sel})), 1, (node_role, sel))


class Answers(unittest.TestCase):
    def test_tree_text_collects_everything_the_window_shows(self):
        d = FakeDriver({(7, None): node("window", "w", children=[node("textfield", value="Access code ab12", ref="@s:e1")])})
        i = interp(d)
        i.run([{"do": "snapshot", "window": "doc", "answer_from": "tree_text"}])
        self.assertIn("Access code ab12", i.answers[0])

    def test_get_and_title_reads_become_the_scripted_answer(self):
        d = FakeDriver({(7, None): node("window", "doc-ab12.pdf", children=[node("textfield", value="line xyz", ref="@s:e1")])})
        i = interp(d)
        i.run([{"do": "snapshot", "window": "doc", "answer_from": "title"}])
        self.assertEqual(i.answers, ["doc-ab12.pdf"])
        d.run = lambda verb, timeout=60, **kw: support.Result(True, {"value": "line xyz"}, None, 3)
        i.run([{"do": "get", "window": "doc", "target": {"role": "textfield"}, "property": "value"}])
        self.assertEqual(i.answers[-1], "line xyz")
        self.assertGreaterEqual(i.tool_calls, 3)


class Running(unittest.TestCase):
    def test_type_snapshots_then_acts_on_the_ref(self):
        d = FakeDriver({(7, None): textedit_tree()})
        out = interp(d).run([{"do": "type", "window": "doc", "target": {"role": "textfield"}, "text": "hi"}])
        self.assertTrue(out["ok"])
        self.assertEqual(d.calls[-1], ("type", {"wid": 7, "ref": "@s1:e2", "text": "hi"}))

    def test_a_missing_target_stops_the_task(self):
        d = FakeDriver({(7, None): textedit_tree()})
        i = interp(d)
        out = i.run([{"do": "click", "window": "doc", "target": {"role": "button", "name": "Nope"}},
                     {"do": "click", "window": "doc", "target": {"role": "button", "name": "Close"}}])
        self.assertFalse(out["ok"])
        self.assertEqual(out["failed_step"], 0)
        self.assertEqual(len([c for c in d.calls if c[0] == "click"]), 0)

    def test_optional_step_failure_continues(self):
        d = FakeDriver({(7, None): textedit_tree()})
        out = interp(d).run([{"do": "click", "window": "doc", "target": {"name": "Nope"}, "optional": True},
                             {"do": "click", "window": "doc", "target": {"name": "Close"}}])
        self.assertTrue(out["ok"])

    def test_expected_refusal_is_recorded_with_its_suggestion(self):
        d = FakeDriver({})
        out = interp(d).run([{"do": "snapshot", "window_id": 999, "expect_refusal": True}])
        self.assertTrue(out["ok"])
        self.assertEqual(out["refusal"]["code"], "window_not_found")
        self.assertEqual(out["refusal"]["suggestion"], "list windows")

    def test_a_selector_that_matches_nothing_is_not_a_refusal_by_the_tool(self):
        """second-S4: the bench's own bug must not be credited as a good refusal."""
        d = FakeDriver({(7, None): textedit_tree()})
        i = interp(d)
        out = i.run([{"do": "set-value", "window": "doc", "target": {"role": "statictext"}, "value": "9", "expect_refusal": True}])
        self.assertFalse(out["ok"])
        self.assertTrue(out.get("harness_error"))
        self.assertIsNone(out["refusal"])

    def test_a_tool_error_on_an_expected_refusal_step_is_credited_with_the_tools_suggestion(self):
        d = FakeDriver({(7, None): textedit_tree()},
                       fail={"set-value": {"code": "not_supported", "message": "m", "suggestion": "Type into the text view instead.", "retry": "never"}})
        out = interp(d).run([{"do": "set-value", "window": "doc", "target": {"role": "textfield"}, "value": "9", "expect_refusal": True}])
        self.assertTrue(out["ok"])
        self.assertEqual(out["refusal"]["suggestion"], "Type into the text view instead.")

    def test_doing_it_when_a_refusal_was_expected_fails(self):
        d = FakeDriver({(7, None): textedit_tree()})
        out = interp(d).run([{"do": "snapshot", "window": "doc", "expect_refusal": True}])
        self.assertFalse(out["ok"])
        self.assertIn("instead of refusing", out["why"])

    def test_saved_ref_is_reused_without_a_new_snapshot(self):
        d = FakeDriver({(7, None): textedit_tree()})
        i = interp(d)
        i.run([{"do": "get", "window": "doc", "target": {"role": "textfield"}, "property": "value", "save_ref": "r"},
               {"do": "type", "window": "doc", "ref": "r", "text": "x"}])
        self.assertEqual(sum(1 for c in d.calls if c[0] == "snapshot"), 1)
        self.assertEqual(d.calls[-1][1]["ref"], "@s1:e2")

    def test_baneyspaces_press_is_aimed_through_a_ref(self):
        d = FakeDriver({(7, None): textedit_tree()}, needs_ref_for_press=True)
        interp(d).run([{"do": "press", "window": "doc", "key": "cmd+a"}])
        self.assertEqual(d.calls[-1], ("press", {"wid": 7, "ref": "@s1:e2", "key": "cmd+a"}))

    def test_agent_desktop_press_needs_no_ref(self):
        d = FakeDriver({(7, None): textedit_tree()}, needs_ref_for_press=False)
        interp(d).run([{"do": "press", "window": "doc", "key": "cmd+a"}])
        self.assertEqual(d.calls[-1], ("press", {"wid": 7, "ref": None, "key": "cmd+a"}))

    def test_menu_uses_the_menubar_surface(self):
        bar = node("menubar", children=[node("menuitem", "File", children=[node("menuitem", "Save", ref="@m:e3")])])
        d = FakeDriver({(7, "menubar"): bar})
        out = interp(d).run([{"do": "menu", "window": "doc", "path": ["File", "Save"]}])
        self.assertTrue(out["ok"])
        self.assertEqual(d.calls[-1], ("click", {"wid": 7, "ref": "@m:e3"}))

    def test_an_error_from_the_tool_is_logged_with_its_code(self):
        d = FakeDriver({(7, None): textedit_tree()},
                       fail={"click": {"code": "stale_ref", "message": "m", "suggestion": "snapshot again", "retry": "after_snapshot"}})
        i = interp(d)
        out = i.run([{"do": "click", "window": "doc", "target": {"name": "Close"}}])
        self.assertFalse(out["ok"])
        self.assertEqual(i.log[-1]["code"], "stale_ref")

    def test_waits_for_a_target_that_appears_late(self):
        calls = {"n": 0}

        class Late(FakeDriver):
            def snapshot(self, wid, surface=None):
                calls["n"] += 1
                return super().snapshot(wid, surface) if calls["n"] >= 3 else \
                    super().snapshot(wid, surface).__class__(True, {"tree": node("window")}, None, 5)

        clock = {"t": 0.0}
        i = Interpreter(Late({(7, None): textedit_tree()}), {"doc": 7}, poll_s=5.0,
                        sleep=lambda s: clock.__setitem__("t", clock["t"] + s), clock=lambda: clock["t"])
        out = i.run([{"do": "click", "window": "doc", "target": {"name": "Close"}}])
        self.assertTrue(out["ok"])


if __name__ == "__main__":
    unittest.main()
