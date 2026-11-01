import json
import unittest

import support
from support import fake_exec
from benchlib import drivers
from benchlib.drivers import AgentDesktopDriver, BaneySpacesDriver, Opener


class Commands(unittest.TestCase):
    def test_baneyspaces_uses_the_agent_family(self):
        d = BaneySpacesDriver(None, "bs")
        self.assertEqual(d.build("snapshot", wid=42), ["bs", "agent", "snapshot", "--window", "42"])
        self.assertEqual(d.build("snapshot", wid=42, surface="menubar")[-2:], ["--surface", "menubar"])
        self.assertEqual(d.build("click", ref="@s:e1"), ["bs", "agent", "click", "@s:e1"])
        self.assertEqual(d.build("type", ref="@s:e1", text="-x"), ["bs", "agent", "type", "--", "@s:e1", "-x"])
        self.assertEqual(d.build("press", ref="@s:e1", key="cmd+a"), ["bs", "agent", "press", "--", "@s:e1", "cmd+a"])
        self.assertEqual(d.build("scroll", ref="@s:e1", direction="down", amount=30),
                         ["bs", "agent", "scroll", "@s:e1", "down", "--amount", "30"])

    def test_agent_desktop_is_headless_by_default(self):
        d = AgentDesktopDriver(None, "/ad")
        for verb, kw in (("click", {"ref": "r"}), ("type", {"ref": "r", "text": "t"}),
                         ("press", {"wid": 5, "key": "k"}), ("scroll", {"ref": "r", "direction": "up"})):
            self.assertNotIn("--headed", d.build(verb, **kw))

    def test_headed_variant_adds_the_flag_and_its_own_name(self):
        d = AgentDesktopDriver(None, "/ad", headed=True)
        self.assertEqual(d.name, "agent-desktop-headed")
        self.assertIn("--headed", d.build("click", ref="r"))
        self.assertIn("--headed", d.build("press", wid=5, key="k"))

    def test_agent_desktop_window_ids_are_w_prefixed(self):
        d = AgentDesktopDriver(None, "/ad")
        self.assertEqual(d.build("snapshot", wid=114755)[:4], ["/ad", "snapshot", "--window-id", "w-114755"])
        self.assertEqual(d.build("snapshot", wid="w-9", surface="menubar")[-2:], ["--surface", "menubar"])
        self.assertEqual(d.build("press", wid=5, key="cmd+a"), ["/ad", "press", "--window-id", "w-5", "--", "cmd+a"])

    def test_text_that_looks_like_a_flag_goes_after_double_dash(self):
        d = AgentDesktopDriver(None, "/ad")
        a = d.build("type", ref="@s:e1", text="--rm")
        self.assertEqual(a[a.index("--") + 1:], ["@s:e1", "--rm"])


class Envelopes(unittest.TestCase):
    def test_success_and_failure(self):
        self.assertEqual(drivers.parse_envelope('{"ok":true,"data":{"a":1}}\n'), (True, {"a": 1}, None))
        ok, data, err = drivers.parse_envelope(
            'noise\n{"ok":false,"error":{"code":"STALE_REF","message":"m","disposition":{"retry":"safe"},"suggestion":"snapshot"}}')
        self.assertFalse(ok)
        self.assertEqual(err, {"code": "stale_ref", "message": "m", "suggestion": "snapshot", "retry": "safe"})

    def test_no_envelope(self):
        self.assertIsNone(drivers.parse_envelope("hello"))

    def test_run_without_an_envelope_is_an_error_result(self):
        d = BaneySpacesDriver(fake_exec([(lambda a: True, (1, "", "boom"))]))
        r = d.run("click", ref="r")
        self.assertFalse(r.ok)
        self.assertEqual(r.code, "no_envelope")

    def test_timeout_has_its_own_code(self):
        d = BaneySpacesDriver(fake_exec([(lambda a: True, (124, "", "timeout after 60s"))]))
        self.assertEqual(d.run("click", ref="r").code, "timeout")

    def test_a_baneyspaces_error_envelope(self):
        env = json.dumps({"ok": False, "error": {"code": "outside_agent_workspace", "message": "m", "retry": "never", "suggestion": "lend it"}})
        r = BaneySpacesDriver(fake_exec([(lambda a: True, (1, env, ""))])).run("click", ref="r")
        self.assertEqual((r.code, r.suggestion, r.error["retry"]), ("outside_agent_workspace", "lend it", "never"))


class Opening(unittest.TestCase):
    def test_json_open_returns_the_window(self):
        env = json.dumps({"ok": True, "data": {"app": "TextEdit", "window": 321}})
        o = Opener(fake_exec([(lambda a: a[2:3] == ["open"], (0, env, ""))]))
        self.assertEqual(o.open("TextEdit", ["/x"])[0], 321)

    def test_plain_text_build_is_read_back_from_status(self):
        state = {"n": 0}

        def run(argv, timeout=60, **kw):
            if argv[2] == "status":
                state["n"] += 1
                body = "agent workspace: 9\n" + ("  77\tTextEdit\tp.txt\n" if state["n"] > 1 else "  no windows there yet\n")
                return 0, body, "", 1
            return 0, "app: TextEdit\nworkspace: 9\n", "", 1
        self.assertEqual(Opener(run).open("TextEdit", ["/x"])[0], 77)

    def test_open_refused_returns_none(self):
        env = json.dumps({"ok": False, "error": {"code": "agent_workspace_off", "message": "m", "suggestion": "agent on"}})
        o = Opener(fake_exec([(lambda a: a[2:3] == ["open"], (1, env, ""))]))
        self.assertIsNone(o.open("TextEdit")[0])


if __name__ == "__main__":
    unittest.main()
