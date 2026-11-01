import json
import os
import tempfile
import unittest

import support  # noqa: F401
from benchlib import agents, host


class Idle(unittest.TestCase):
    def test_parse_hid_idle_from_ioreg(self):
        class R:
            stdout = '    | |   "HIDIdleTime" = 612000000000\n'
        self.assertAlmostEqual(host.hid_idle_seconds(lambda *a, **k: R()), 612.0)

    def test_gate(self):
        self.assertTrue(host.idle_gate(601)[0])
        ok, msg = host.idle_gate(12)
        self.assertFalse(ok)
        self.assertIn("not run: user active", msg)
        self.assertTrue(host.idle_gate(30, required=10)[0])


STATE = {"agentWorkspace": 9, "workspaces": {"1": [{"app": "Helium", "id": 1}], "2": [{"app": "Claude", "id": 2}],
                                              "9": [{"app": "TextEdit", "id": 3}]}}


class Availability(unittest.TestCase):
    def task(self, **req):
        return {"setup": {"requires": req}}

    def test_apps_on_user_workspaces_ignore_the_agent_workspace(self):
        self.assertEqual(host.apps_on_user_workspaces(STATE), {"Helium", "Claude"})

    def test_ok_when_nothing_is_in_the_way(self):
        self.assertIsNone(host.availability(self.task(installed=["TextEdit"], exclusive=["TextEdit"]), STATE,
                                            installed_fn=lambda a: True, running_fn=lambda a: False))

    def test_not_installed(self):
        why = host.availability(self.task(installed=["Firefox"]), STATE, installed_fn=lambda a: False)
        self.assertIn("not installed", why)

    def test_exclusive_blocks_when_donovan_has_a_window(self):
        why = host.availability(self.task(exclusive=["Helium"]), STATE, installed_fn=lambda a: True)
        self.assertIn("one of Donovan's workspaces", why)

    def test_running_app_is_not_driven_whole(self):
        why = host.availability(self.task(not_running=["Calculator"]), STATE, installed_fn=lambda a: True,
                                running_fn=lambda a: True)
        self.assertIn("already running", why)

    def test_env_flag(self):
        t = self.task(env=["BENCH_X"])
        os.environ.pop("BENCH_X", None)
        self.assertIn("BENCH_X", host.availability(t, STATE))
        os.environ["BENCH_X"] = "1"
        try:
            self.assertIsNone(host.availability(t, STATE))
        finally:
            del os.environ["BENCH_X"]

    def test_collateral(self):
        self.assertEqual(host.collateral(["a"], ["a", "untitled folder"]), ["untitled folder"])


class Places(unittest.TestCase):
    def test_sandbox_tasks_are_unavailable_until_the_sandbox_exists(self):
        t = {"place": "sandbox", "setup": {"requires": {}}}
        self.assertEqual(host.availability(t, STATE), "unavailable: needs sandbox (phase 2)")
        self.assertIsNone(host.availability(t, STATE, sandbox=True))

    def test_unreadable_state_blocks_an_exclusive_task(self):
        self.assertIn("unreadable", host.availability({"setup": {"requires": {"exclusive": ["TextEdit"]}}}, None, installed_fn=lambda a: True))

    def test_micro_has_the_same_gate_as_a_task(self):
        """sol-F1, second-F11"""
        ok = dict(installed_fn=lambda a: True, running_fn=lambda a: False)
        self.assertIsNone(host.availability(host.micro_task("baneyspaces"), STATE, **ok))
        busy = {"agentWorkspace": 9, "workspaces": {"1": [{"app": "TextEdit", "id": 1}], "9": []}}
        self.assertIn("TextEdit", host.availability(host.micro_task("baneyspaces"), busy, **ok))
        self.assertIn("Calculator", host.availability(host.micro_task("agent-desktop"), STATE, installed_fn=lambda a: True,
                                                      running_fn=lambda a: a == "Calculator"))

    def test_chatgpt_micro_needs_textedit_not_running_at_all(self):
        """Sky addresses an app by name: the bench's window must be the only one."""
        why = host.availability(host.micro_task("chatgpt"), STATE, installed_fn=lambda a: True, running_fn=lambda a: a == "TextEdit")
        self.assertIn("TextEdit", why)


class Infra(unittest.TestCase):
    def parsed(self, **kw):
        return dict({"ok": False, "turns": None, "tool_calls": 0, "text": "", "error": None}, **kw)

    def test_cua_repl_start_failure_is_fatal_infra(self):
        r = agents.infra_failure("chatgpt", 1, "", "ERROR: MCP server cua_repl failed to start: timed out", self.parsed())
        self.assertTrue(r[1])
        self.assertIn("cua_repl did not start", r[0])

    def test_auth_and_quota_are_fatal_infra(self):
        for msg in ("usage limit reached", "Please run /login", "rate limit exceeded", "401 Unauthorized"):
            self.assertTrue(agents.infra_failure("baneyspaces", 1, "", msg, self.parsed())[1], msg)

    def test_a_timeout_with_no_tool_call_is_infra_but_after_work_it_is_the_tools(self):
        self.assertFalse(agents.infra_failure("chatgpt", 124, "", "timeout", self.parsed())[1])
        self.assertIsNone(agents.infra_failure("chatgpt", 124, "", "timeout", self.parsed(tool_calls=4)))
        self.assertIsNone(agents.infra_failure("baneyspaces", 124, "", "timeout", self.parsed(tool_errors=1)))

    def test_a_timeout_after_real_calls_is_scored_through_the_whole_exec_path(self):
        """sol-F3, end to end: the child is killed, its partial output survives, the calls count, the task is a fail."""
        import sys
        from benchlib.execs import Exec
        script = ("import json,sys,time\n"
                  "print(json.dumps({'type':'item.completed','item':{'type':'mcp_tool_call','server':'cua_repl','tool':'js'}}),flush=True)\n"
                  "time.sleep(30)\n")
        rc, out, err, ms = Exec()([sys.executable, "-c", script], timeout=1.0)
        self.assertEqual(rc, 124)
        parsed = agents.parse_codex(out)
        self.assertEqual(parsed["tool_calls"], 1)
        self.assertIsNone(agents.infra_failure("chatgpt", rc, out, err, parsed))

    def test_a_baneyspaces_mcp_that_never_connected_is_fatal_infra(self):
        """first-F8: claude still returns a normal one-turn result when the server failed."""
        r = agents.infra_failure("baneyspaces", 0, "", "", self.parsed(ok=True, turns=1, mcp={"baneyspaces": "failed"}))
        self.assertTrue(r[1])
        self.assertIn("did not connect", r[0])
        r2 = agents.infra_failure("baneyspaces", 0, "", "", self.parsed(ok=True, turns=1, mcp={}))
        self.assertTrue(r2[1])
        self.assertIsNone(agents.infra_failure("baneyspaces", 0, "", "", self.parsed(ok=True, turns=5, tool_calls=3, mcp={"baneyspaces": "connected"})))

    def test_no_result_at_all_is_infra(self):
        self.assertIn("no result", agents.infra_failure("agent-desktop", 1, "", "boom", self.parsed())[0])

    def test_a_normal_failure_after_real_work_is_charged_to_the_tool(self):
        self.assertIsNone(agents.infra_failure("chatgpt", 0, "", "", self.parsed(ok=True, turns=6, tool_calls=5)))
        self.assertIsNone(agents.infra_failure("baneyspaces", 0, "", "", self.parsed(ok=False, turns=9, tool_calls=8, error="error_max_turns", mcp={"baneyspaces": "connected"})))


class Plugin(unittest.TestCase):
    def test_versions_sort_numerically(self):
        """second-F20: 10.0.0 is newer than 9.0.0"""
        with tempfile.TemporaryDirectory() as d:
            for v in ("9.0.0", "10.0.0", "26.1023.50603"):
                os.makedirs(os.path.join(d, v))
                open(os.path.join(d, v, ".mcp.json"), "w").write("{}")
            self.assertTrue(agents.find_plugin_mcp(d).endswith("26.1023.50603/.mcp.json"))
            os.rename(os.path.join(d, "26.1023.50603"), os.path.join(d, "x"))
            self.assertTrue(agents.find_plugin_mcp(d).endswith("10.0.0/.mcp.json"))


class Prompts(unittest.TestCase):
    TASK = {"goal": "Do the thing.", "setup": {"open": [{"app": "TextEdit", "as": "doc", "title": "a.txt"}]}}

    def test_ids_are_given_to_tools_that_need_them_not_to_chatgpt(self):
        p = agents.build_prompt(self.TASK, {"doc": 77}, {"doc": "a.txt"}, "baneyspaces")
        self.assertIn("window id 77", p)
        self.assertIn('titled "a.txt"', p)
        self.assertNotIn("window id", agents.build_prompt(self.TASK, {"doc": 77}, {"doc": "a.txt"}, "chatgpt"))

    def test_a_task_with_no_window_forbids_launching_anything(self):
        """second-F18"""
        p = agents.build_prompt({"goal": "g", "setup": {}}, {}, {}, "chatgpt")
        self.assertIn("do not open any app or window", p)
        self.assertNotIn("open what you need", p)

    def test_the_prompt_never_contains_the_nonce(self):
        """second-S2, sol-F2: the answer cannot be echoed from the prompt."""
        import json as js
        from benchlib import tasks as T
        for t in T.load_tasks(os.path.join(support.BENCH, "tasks")):
            if not t.get("requires_tool_call"):
                continue
            x = T.expand(t, {"tmp": "/t", "base": "b", "port": 1, "fixtures": "/t", "nonce": "9f3a7c"})
            wins = {o["as"]: 41 for o in x["setup"]["open"]}
            titles = {o["as"]: o.get("title", "") for o in x["setup"]["open"]}
            for tool in ("baneyspaces", "agent-desktop", "chatgpt"):
                self.assertNotIn("9f3a7c", agents.build_prompt(x, wins, titles, tool), (t["id"], tool))
            self.assertIn("9f3a7c", js.dumps(x["setup"]["files"]))      # it is in the document, where only looking finds it

    def test_the_prompt_forbids_shortcuts(self):
        p = agents.build_prompt(self.TASK, {"doc": 1}, {}, "baneyspaces")
        self.assertIn("Do not use a shell", p)
        self.assertIn("DONE or REFUSED", p)


def stream(*events):
    return "\n".join(json.dumps(e) for e in events)


INIT = {"type": "system", "subtype": "init", "mcp_servers": [{"name": "baneyspaces", "status": "connected"}]}


def use(i, name, inp=None):
    return {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": i, "name": name, "input": inp or {}}]}}


def res(i, content, err=False):
    return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": i, "content": content, "is_error": err}]}}


FINAL = {"type": "result", "is_error": False, "num_turns": 4, "total_cost_usd": 0.1, "result": "DONE typed it"}


class Claude(unittest.TestCase):
    def test_baneyspaces_gets_only_its_mcp_server(self):
        c = agents.claude_command("baneyspaces", "P", "claude", "/tmp/m.json")
        self.assertEqual(c[c.index("--tools") + 1], "")
        self.assertEqual(c[c.index("--allowedTools") + 1], "mcp__baneyspaces")
        self.assertIn("--strict-mcp-config", c)
        self.assertEqual(c[c.index("--output-format") + 1], "stream-json")
        self.assertIn("--verbose", c)

    def test_agent_desktop_gets_bash_limited_to_the_guard_not_the_raw_binary(self):
        """second-S3"""
        c = agents.claude_command("agent-desktop", "P", "claude", "/tmp/m.json", "/x/agent-desktop-guard")
        self.assertEqual(c[c.index("--tools") + 1], "Bash")
        self.assertEqual(c[c.index("--allowedTools") + 1], "Bash(/x/agent-desktop-guard:*)")
        self.assertNotIn("Bash(/x/agent-desktop:", " ".join(c))

    def test_both_claude_columns_share_model_and_turn_limit(self):
        a = agents.claude_command("baneyspaces", "P", "claude", "m")
        b = agents.claude_command("agent-desktop", "P", "claude", "m", "/g")
        for flag in ("--model", "--max-turns", "--permission-mode", "--setting-sources"):
            self.assertEqual(a[a.index(flag) + 1], b[b.index(flag) + 1])

    def test_counts_only_computer_use_calls_that_came_back_fine(self):
        out = stream(INIT, use("a", "mcp__baneyspaces__snapshot"), res("a", '{"ok":true,"data":{}}'),
                     use("b", "mcp__baneyspaces__click"), res("b", "denied", err=True), FINAL)
        r = agents.parse_claude(out)
        self.assertEqual((r["ok"], r["turns"], r["text"], r["tool_calls"], r["tool_errors"], r["shortcut"]), (True, 4, "DONE typed it", 1, 0, None))

    def test_a_tool_refusal_is_read_from_the_envelope_with_its_own_suggestion(self):
        env = '{"ok":false,"error":{"code":"window_not_found","message":"m","retry":"safe","suggestion":"Run agent windows."}}'
        r = agents.parse_claude(stream(INIT, use("a", "mcp__baneyspaces__snapshot"), res("a", env), FINAL))
        self.assertEqual((r["tool_calls"], r["tool_errors"]), (0, 1))
        self.assertEqual(r["refusals"][0], {"code": "window_not_found", "suggestion": "Run agent windows.", "retry": "safe"})

    def test_a_bash_call_to_the_guard_is_computer_use_and_any_other_tool_that_ran_is_a_shortcut(self):
        out = stream(use("a", "Bash", {"command": f"{agents.GUARD} snapshot --window-id w-1"}), res("a", '{"ok":true,"data":{}}'),
                     use("b", "Read", {"file_path": "/tmp/x"}), res("b", "secret"), FINAL)
        r = agents.parse_claude(out)
        self.assertEqual((r["tool_calls"], r["shortcut"]), (1, "Read"))
        denied = agents.parse_claude(stream(use("b", "Bash", {"command": "cat /tmp/x"}), res("b", "not allowed", err=True), FINAL))
        self.assertIsNone(denied["shortcut"])             # an attempt the permissions refused is not a shortcut

    def test_a_partial_stream_still_shows_the_calls_made_before_the_timeout(self):
        """sol-F3"""
        r = agents.parse_claude(stream(INIT, use("a", "mcp__baneyspaces__snapshot"), res("a", '{"ok":true}'),
                                       use("b", "mcp__baneyspaces__click"), res("b", '{"ok":true}')))
        self.assertEqual((r["ok"], r["turns"], r["tool_calls"]), (False, None, 2))

    def test_the_init_line_reports_the_mcp_server_status(self):
        r = agents.parse_claude(stream({"type": "system", "subtype": "init", "mcp_servers": [{"name": "baneyspaces", "status": "failed"}]}))
        self.assertEqual(r["mcp"], {"baneyspaces": "failed"})
        self.assertFalse(agents.parse_claude("nothing")["ok"])
        self.assertFalse(agents.parse_claude(stream({"type": "result", "is_error": True, "subtype": "error_max_turns"}))["ok"])


class Codex(unittest.TestCase):
    def mcp(self, d):
        spec = {"mcpServers": {"cua_repl": {
            "command": "/node", "args": ["--import", "file:///r.mjs", "/cua-repl.mjs"], "enabled": False,
            "env_vars": ["A_B"], "startup_timeout_sec": 120,
            "env": {"CUA_REPL_ENABLED_SURFACES": "", "NODE_REPL_TRUSTED_SERVICES": "{}", "X": "1"}}}}
        p = os.path.join(d, ".mcp.json")
        json.dump(spec, open(p, "w"))
        return p

    def test_overrides_enable_cua_repl_with_the_computer_surface(self):
        with tempfile.TemporaryDirectory() as d:
            ov = agents.cua_repl_overrides(self.mcp(d))
        pairs = [ov[i + 1] for i in range(0, len(ov), 2)]
        self.assertTrue(all(ov[i] == "-c" for i in range(0, len(ov), 2)))
        joined = "\n".join(pairs)
        self.assertIn("mcp_servers.cua_repl.enabled=true", joined)
        self.assertIn('mcp_servers.cua_repl.command="/node"', joined)
        self.assertIn('"CUA_REPL_ENABLED_SURFACES" = "computer"', joined)
        self.assertIn("@oai/sky/service", joined)
        self.assertIn('mcp_servers.cua_repl.args=["--import", "file:///r.mjs", "/cua-repl.mjs"]', joined)

    def test_the_user_config_is_never_opened(self):
        for line in open(agents.__file__).read().splitlines():
            if "config.toml" in line:
                self.assertNotIn("open(", line)
                self.assertNotIn("write", line)

    def test_codex_command_is_read_only_and_ephemeral(self):
        with tempfile.TemporaryDirectory() as d:
            c = agents.codex_command("PROMPT", "codex", self.mcp(d), "/cwd")
        self.assertEqual(c[:2], ["codex", "exec"])
        self.assertEqual(c[c.index("-s") + 1], "read-only")
        self.assertIn("--ephemeral", c)
        self.assertEqual(c[-1], "PROMPT")
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", c)

    def test_the_users_other_mcp_servers_are_switched_off_for_the_invocation(self):
        with tempfile.TemporaryDirectory() as d:
            c = agents.codex_command("P", "codex", self.mcp(d), "/cwd", disable=["magnus-coordination", "baneyvault"])
        self.assertIn("mcp_servers.magnus-coordination.enabled=false", c)
        self.assertIn("mcp_servers.baneyvault.enabled=false", c)

    def test_other_servers_are_read_from_the_config_without_opening_it_for_writing(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "config.toml")
            open(p, "w").write('[mcp_servers.cua_repl]\nenabled=false\n[mcp_servers.rea]\ncommand="x"\n[mcp_servers.tabkyra]\ncommand="y"\n')
            self.assertEqual(agents.other_mcp_servers(p), ["rea", "tabkyra"])
            self.assertEqual(agents.other_mcp_servers(os.path.join(d, "missing")), [])

    def test_only_cua_repl_calls_count_and_a_shell_command_is_a_shortcut(self):
        """first-F2"""
        lines = [json.dumps(x) for x in (
            {"type": "item.completed", "item": {"type": "mcp_tool_call", "server": "cua_repl", "tool": "js"}},
            {"type": "item.completed", "item": {"type": "mcp_tool_call", "server": "cua_repl", "tool": "js", "error": "boom"}},
            {"type": "item.completed", "item": {"type": "agent_message", "text": "DONE typed"}},
            {"type": "turn.completed"})]
        r = agents.parse_codex("\n".join(lines))
        self.assertEqual((r["ok"], r["tool_calls"], r["tool_errors"], r["shortcut"], r["text"]), (True, 1, 1, None, "DONE typed"))
        shell = agents.parse_codex(json.dumps({"type": "item.completed", "item": {"type": "command_execution", "command": "cat x"}}))
        self.assertEqual((shell["tool_calls"], shell["shell_calls"], shell["shortcut"]), (0, 1, "a shell command"))
        other = agents.parse_codex(json.dumps({"type": "item.completed", "item": {"type": "mcp_tool_call", "server": "baneyvault", "tool": "q"}}))
        self.assertEqual((other["tool_calls"], other["shortcut"]), (0, "baneyvault"))
        self.assertFalse(agents.parse_codex(json.dumps({"type": "turn.failed", "error": "x"}))["ok"])

    def test_toml_values(self):
        self.assertEqual(agents.toml_value({"a": ["b", True, 3]}), '{"a" = ["b", true, 3]}')


if __name__ == "__main__":
    unittest.main()
