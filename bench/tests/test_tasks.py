import json
import os
import tempfile
import unittest

import support  # noqa: F401
from benchlib import tasks

TASKS = os.path.join(support.BENCH, "tasks")


class TaskFiles(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tasks = tasks.load_tasks(TASKS)

    def test_there_are_thirty(self):
        self.assertEqual(len(self.tasks), 30)

    def test_every_task_has_the_four_parts(self):
        for t in self.tasks:
            for k in ("id", "app", "setup", "steps", "check", "goal"):
                self.assertIn(k, t, t["id"])

    def test_the_mix_the_design_asks_for(self):
        apps = {t["app"] for t in self.tasks}
        for a in ("TextEdit", "Finder", "Notes", "System Settings", "Calculator", "Preview", "Safari",
                  "Google Chrome", "Firefox", "Helium", "Cursor"):
            self.assertIn(a, apps)
        cats = [t["category"] for t in self.tasks]
        self.assertGreaterEqual(cats.count("menu"), 3)
        self.assertGreaterEqual(cats.count("dialog"), 2)
        self.assertGreaterEqual(cats.count("scroll"), 1)
        self.assertGreaterEqual(cats.count("hidden"), 1)
        self.assertGreaterEqual(cats.count("two-window"), 2)
        self.assertEqual(cats.count("refusal"), 3)
        self.assertEqual(cats.count("browser"), 4)
        self.assertEqual(cats.count("electron"), 1)

    def test_two_window_tasks_open_two_windows_of_one_app(self):
        for t in self.tasks:
            if t["category"] == "two-window":
                opens = t["setup"]["open"]
                self.assertEqual(len(opens), 2)
                self.assertEqual(opens[0]["app"], opens[1]["app"])
                self.assertEqual(len(t["check"]["checks"]), 2, "both windows are read back")

    def test_refusal_tasks_are_marked_impossible(self):
        for t in self.tasks:
            self.assertEqual(t["category"] == "refusal", bool(t.get("impossible")), t["id"])

    def test_every_expected_failure_says_why_and_names_a_phase(self):
        n = 0
        for t in self.tasks:
            for tool, exp in t.get("expected_fail", {}).items():
                n += 1
                self.assertTrue(exp["why"])
                self.assertIn("phase", exp)
        self.assertGreater(n, 0)

    def test_nothing_touches_a_path_outside_the_run_directory(self):
        for t in self.tasks:
            blob = json.dumps(t)
            self.assertNotIn("/Users/", blob, t["id"])
            self.assertNotIn("~", blob, t["id"])

    def test_placeholders_expand_everywhere(self):
        t = next(x for x in self.tasks if x["id"] == "safari-form")
        out = tasks.expand(t, {"tmp": "/t", "base": "http://127.0.0.1:9", "port": 9, "fixtures": "/t"})
        self.assertNotIn("{base}", json.dumps(out))
        self.assertIn("http://127.0.0.1:9/form", json.dumps(out))

    def test_browser_pages_are_local_only(self):
        for t in self.tasks:
            if t["category"] == "browser":
                for o in t["setup"]["open"]:
                    for target in o["targets"]:
                        self.assertTrue(target.startswith("{base}/"))


class Safety(unittest.TestCase):
    """first-F2, sol-F1: the bench never touches Donovan's data or windows."""

    @classmethod
    def setUpClass(cls):
        cls.tasks = tasks.load_tasks(TASKS)

    def test_once_per_user_apps_only_run_in_the_sandbox(self):
        for t in self.tasks:
            apps = {o["app"] for o in t["setup"].get("open", [])} | {t["app"]}
            if apps & tasks.ONCE_PER_USER:
                self.assertEqual(t.get("place"), "sandbox", t["id"])
        sandbox = {t["id"] for t in self.tasks if t.get("place") == "sandbox"}
        self.assertEqual(sandbox, {"notes-search-field", "safari-form", "firefox-form"})

    def test_every_host_task_guards_every_app_it_opens(self):
        for t in self.tasks:
            if t.get("place", "host") != "host":
                continue
            req = t["setup"].get("requires", {})
            for o in t["setup"].get("open", []):
                self.assertTrue(o["app"] in req.get("exclusive", []) or o["app"] in req.get("not_running", []), t["id"])

    def test_host_browsers_need_an_agent_profile_and_must_not_be_running(self):
        for t in self.tasks:
            if t["category"] == "browser" and t.get("place", "host") == "host":
                req = t["setup"]["requires"]
                self.assertIn("BENCH_AGENT_BROWSER_PROFILE", req["env"], t["id"])
                self.assertIn(t["app"], req["not_running"], t["id"])

    def test_nothing_is_hidden_or_quit_unless_the_bench_must_have_started_it(self):
        for t in self.tasks:
            req = t["setup"].get("requires", {}).get("not_running", [])
            for app in t["setup"].get("quit_after", []) + ([t["setup"]["hide"]] if t["setup"].get("hide") else []):
                self.assertIn(app, req, t["id"])

    def test_the_three_validators_reject_the_unsafe_shapes(self):
        base = {"id": "x", "app": "Notes", "category": "notes", "goal": "g", "check": {"kind": "nothing"},
                "setup": {"requires": {"exclusive": ["Notes"]}, "open": [{"app": "Notes", "as": "w"}]},
                "steps": [{"do": "wait"}]}
        self.assertRaises(tasks.TaskError, tasks.validate, base)                      # Notes on the host
        tasks.validate(dict(base, place="sandbox"))
        chrome = dict(base, id="y", app="Google Chrome", category="browser",
                      setup={"requires": {"not_running": ["Google Chrome"]}, "open": [{"app": "Google Chrome", "as": "w"}]})
        self.assertRaises(tasks.TaskError, tasks.validate, chrome)                    # no agent profile gate
        calc = dict(base, id="z", app="Calculator", category="calculator",
                    setup={"requires": {"installed": ["Calculator"]}, "open": [{"app": "Calculator", "as": "w"}], "quit_after": ["Calculator"]})
        self.assertRaises(tasks.TaskError, tasks.validate, calc)                      # opens + quits without not_running

    def test_read_tasks_hold_a_value_only_observation_can_give(self):
        reads = [t for t in self.tasks if t.get("requires_tool_call")]
        self.assertGreaterEqual(len(reads), 2)
        for t in reads:
            self.assertIn("{nonce}", json.dumps(t["setup"]), t["id"])
            self.assertIn("{nonce}", json.dumps(t["check"]), t["id"])

    def test_keys_are_an_expected_failure_for_baneyspaces_phase_one(self):
        for t in self.tasks:
            if any(s.get("do") == "press" for s in t["steps"]):
                self.assertIn("baneyspaces", t.get("expected_fail", {}), t["id"])

    def test_the_nonce_is_only_ever_inside_a_documents_content(self):
        """second-S2, sol-F2, first-F2: not in a goal, a title, a file name or an open target."""
        for t in self.tasks:
            if "{nonce}" not in json.dumps(t):
                continue
            self.assertNotIn("{nonce}", t["goal"], t["id"])
            self.assertNotIn("{nonce}", json.dumps(t["setup"].get("open", [])), t["id"])
            self.assertFalse(any("{nonce}" in k for k in t["setup"].get("files", {})), t["id"])
        bad = {"id": "x", "app": "A", "category": "textedit", "goal": "g", "check": {"kind": "nothing"},
               "setup": {"requires": {"exclusive": ["A"]}, "files": {"f-{nonce}.txt": "x"}, "open": [{"app": "A", "as": "w"}]},
               "steps": [{"do": "wait"}]}
        self.assertRaises(tasks.TaskError, tasks.validate, bad)

    def test_expand_rewrites_dict_keys_so_fixtures_land_where_the_task_opens_them(self):
        """sol-F1, second-S1"""
        out = tasks.expand({"files": {"{tmp}/a-{nonce}.txt": "v {nonce}"}}, {"tmp": "/t", "base": "", "port": 0, "fixtures": "", "nonce": "ab12"})
        self.assertEqual(out, {"files": {"/t/a-ab12.txt": "v ab12"}})

    def test_every_nonce_task_would_write_its_fixture_where_it_opens_it(self):
        from benchlib import fixtures
        for t in self.tasks:
            if "{nonce}" not in json.dumps(t):
                continue
            with tempfile.TemporaryDirectory() as d:
                x = tasks.expand(t, {"tmp": d, "base": "", "port": 0, "fixtures": d, "nonce": "ab12cd"})
                fixtures.write_files(d, x["setup"].get("files", {}))
                for o in x["setup"]["open"]:
                    for target in o.get("targets", []):
                        self.assertTrue(os.path.exists(target), (t["id"], target))

    def test_the_pdf_carries_the_secret_as_page_text_not_in_its_name(self):
        from benchlib import fixtures
        t = next(x for x in self.tasks if x["id"] == "preview-read-open-pdf")
        x = tasks.expand(t, {"tmp": "/t", "base": "", "port": 0, "fixtures": "/t", "nonce": "ab12cd"})
        (name, spec), = x["setup"]["files"].items()
        self.assertNotIn("ab12cd", name)
        self.assertIn(b"Access code ab12cd", fixtures.pdf_bytes(spec["pdf_pages"], text=spec["text"]))

    def test_host_electron_needs_an_isolated_profile(self):
        t = next(x for x in self.tasks if x["id"] == "electron-cursor-read-editor")
        self.assertIn("BENCH_AGENT_ELECTRON_PROFILE", t["setup"]["requires"]["env"])
        bad = json.loads(json.dumps(t))
        bad["setup"]["requires"].pop("env")
        self.assertRaises(tasks.TaskError, tasks.validate, bad)

    def test_the_refusal_goals_do_not_give_the_answer_away(self):
        """second-S5"""
        for t in self.tasks:
            if t["category"] == "refusal":
                for hint in ("refuse", "does not exist", "read-only", "is gone", "say what to do"):
                    self.assertNotIn(hint, t["goal"].lower(), t["id"])

    def test_the_stale_ref_task_allows_only_the_close_it_does_itself(self):
        t = next(x for x in self.tasks if x["id"] == "refuse-stale-ref")
        self.assertEqual(set(t["allowed_change_fields"]), {"key_window", "front"})

    def test_the_stale_ref_task_checks_the_intended_close(self):
        t = next(x for x in self.tasks if x["id"] == "refuse-stale-ref")
        self.assertIn("window_gone", json.dumps(t["check"]))


class Validation(unittest.TestCase):
    def good(self):
        return {"id": "x", "app": "A", "category": "textedit", "goal": "g",
                "setup": {"requires": {"exclusive": ["A"]}, "open": [{"app": "A", "as": "w"}]},
                "steps": [{"do": "press", "window": "w", "key": "a"}], "check": {"kind": "nothing"}}

    def test_good_passes(self):
        tasks.validate(self.good())

    def test_unknown_verb(self):
        t = self.good()
        t["steps"][0]["do"] = "teleport"
        self.assertRaises(tasks.TaskError, tasks.validate, t)

    def test_unknown_window_alias(self):
        t = self.good()
        t["steps"][0]["window"] = "nope"
        self.assertRaises(tasks.TaskError, tasks.validate, t)

    def test_ax_check_needs_a_known_window(self):
        t = self.good()
        t["check"] = {"kind": "ax", "window": "zzz", "target": {}}
        self.assertRaises(tasks.TaskError, tasks.validate, t)

    def test_refusal_needs_an_expected_refusal_step(self):
        t = self.good()
        t["category"] = "refusal"
        t["impossible"] = True
        self.assertRaises(tasks.TaskError, tasks.validate, t)

    def test_id_must_match_file_name(self):
        with tempfile.TemporaryDirectory() as d:
            t = self.good()
            t["id"] = "other"
            with open(os.path.join(d, "x.json"), "w") as fh:
                json.dump(t, fh)
            self.assertRaises(tasks.TaskError, tasks.load_tasks, d)


if __name__ == "__main__":
    unittest.main()
