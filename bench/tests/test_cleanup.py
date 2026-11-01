import unittest

import support
from support import FakeDriver, node
from benchlib import cleanup


def win(children):
    return node("window", "doc", children=children)


class Close(unittest.TestCase):
    def driver(self, tree, sheet=None):
        trees = {(7, None): tree}
        if sheet is not None:
            trees[(7, "sheet")] = sheet
        return FakeDriver(trees)

    def test_only_the_windows_own_close_button_is_pressed(self):
        """first-F1: a toolbar Delete (Notes' trash) or a Close deeper in the tree is never clicked."""
        tree = win([node("button", "Close", ref="@s:e1"),
                    node("toolbar", children=[node("button", "Delete", ref="@s:e2"), node("button", "Close", ref="@s:e3")]),
                    node("button", "Discard", ref="@s:e4")])
        d = self.driver(tree)
        cleanup.close_windows(d, [7], lambda: {7: ("TextEdit", "doc")}, rounds=1)
        clicked = [c[1]["ref"] for c in d.calls if c[0] == "click"]
        self.assertEqual(clicked, ["@s:e1"])

    def test_a_sheet_is_declined_with_dont_save_never_delete(self):
        sheet = node("sheet", children=[node("button", "Delete", ref="@s:e8"), node("button", "Don’t Save", ref="@s:e9"),
                                        node("button", "Discard", ref="@s:e7")])
        d = self.driver(win([node("button", "Close", ref="@s:e1")]), sheet)
        cleanup.close_windows(d, [7], lambda: {7: ("TextEdit", "doc")}, rounds=1)
        clicked = [c[1]["ref"] for c in d.calls if c[0] == "click"]
        self.assertIn("@s:e9", clicked)
        self.assertNotIn("@s:e8", clicked)
        self.assertNotIn("@s:e7", clicked)

    def test_a_window_the_bench_did_not_create_is_never_touched(self):
        d = FakeDriver({(99, None): win([node("button", "Close", ref="@s:e1")])})
        cleanup.close_windows(d, [7], lambda: {99: ("Notes", "n")})
        self.assertEqual([c for c in d.calls if c[0] == "click"], [])

    def test_a_created_window_that_moved_off_the_agent_workspace_is_left_alone(self):
        d = self.driver(win([node("button", "Close", ref="@s:e1")]))
        closed, left = cleanup.close_windows(d, [7], lambda: {})
        self.assertEqual(closed, [])
        self.assertIn(7, left)
        self.assertEqual([c for c in d.calls if c[0] == "click"], [])

    def test_teardown_stops_before_every_action_once_the_run_is_aborted(self):
        """sol-F4: no action after real input, a lost monitor or a lock."""
        flag = {"stop": False}
        d = self.driver(win([node("button", "Close", ref="@s:e1")]))
        orig = d.run

        def run(verb, timeout=60, **kw):
            flag["stop"] = True               # the abort arrives right after the first action
            return orig(verb, timeout, **kw)
        d.run = run
        closed, left = cleanup.close_windows(d, [7, 8], lambda: {7: ("X", "t"), 8: ("X", "t")}, should_stop=lambda: flag["stop"])
        clicks = [c for c in d.calls if c[0] == "click"]
        self.assertEqual(len(clicks), 1)
        self.assertIn("interrupted", left[7])
        self.assertIn("interrupted", left[8])

    def test_already_aborted_means_not_a_single_call(self):
        d = self.driver(win([node("button", "Close", ref="@s:e1")]))
        closed, left = cleanup.close_windows(d, [7], lambda: {7: ("X", "t")}, should_stop=lambda: True)
        self.assertEqual(d.calls, [])
        self.assertIn(7, left)

    def test_a_window_already_gone_counts_as_closed(self):
        closed, left = cleanup.close_windows(FakeDriver({}), [7], lambda: {7: ("X", "t")})
        self.assertEqual((closed, left), ([7], {}))


if __name__ == "__main__":
    unittest.main()
