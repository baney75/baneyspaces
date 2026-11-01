"""Level 1, end to end: each tool's own agent does the task from a plain-language goal.

baneyspaces   `claude -p` with the BaneySpaces MCP server (`baneyspaces mcp`) as its only tool
agent-desktop `claude -p` with Bash limited to bench/agent-desktop-guard, a wrapper around the pinned
              binary that refuses any window id or ref that is not one of THIS task's windows
chatgpt       `codex exec` with ChatGPT's computer use (the cua_repl MCP server), switched on for this
              one invocation by -c overrides; ~/.codex/config.toml is never written

The two claude runs use the same model and the same prompt; codex uses the model Donovan's Codex
sign-in is set to, so the comparison is tool plus its own agent, as shipped.
Nothing here uses an API key: both CLIs run on Donovan's sign-ins.

Shortcuts are detected, not assumed away: claude's stream shows every tool call, codex's JSONL shows
every item. A shell command (codex) or any tool that is not the computer-use tool counts as a
`shortcut` and fails the task. Calls are counted only when they are computer-use calls that returned.
"""
import json
import os
import re
import shlex

CLAUDE_MODEL = os.environ.get("BENCH_CLAUDE_MODEL", "sonnet")
MAX_TURNS = 40
AGENT_TIMEOUT_S = 300

PLUGIN_GLOB_ROOT = os.path.expanduser("~/.codex/plugins/cache/openai-bundled/unified-computer-use")
CHATGPT_APP = "/Applications/ChatGPT.app"
CUA_NODE = CHATGPT_APP + "/Contents/Resources/cua_node"
USER_CODEX_CONFIG = os.path.expanduser("~/.codex/config.toml")


class SandboxOnly(RuntimeError):
    """ChatGPT's computer use (Sky/cua_repl) runs ONLY inside the sandbox VM, never on Donovan's Mac."""


GUARD = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "agent-desktop-guard")

RULES = (
    "Use only the computer-use tool you were given. Do not use a shell, osascript, files or the "
    "network to do the task, and do not take over the user's screen: other windows on this Mac are "
    "not yours. Work only in the windows named below. Do not ask questions. When the task is done "
    "(or you cannot do it safely), reply with one line starting DONE or REFUSED and say why."
)


def window_lines(task, windows, titles, with_ids):
    lines = []
    for o in task["setup"].get("open", []):
        wid = windows.get(o["as"])
        desc = f'{o["app"]} window titled "{titles.get(o["as"], o.get("title", o["app"]))}"'
        if with_ids and wid is not None:
            desc += f" (window id {wid})"
        lines.append("- " + desc)
    return lines


def build_prompt(task, windows, titles, tool):
    with_ids = tool != "chatgpt"
    parts = [f"Task: {task['goal']}", "", "These windows are already open for you:"]
    parts += window_lines(task, windows, titles, with_ids) or ["- none; do not open any app or window"]
    parts += ["", RULES]
    return "\n".join(parts)


# ---- claude -p ------------------------------------------------------------------------------------

# The exact BaneySpaces MCP tools an agent in the bench may call. Not `open`, `lend`, `return` or `shot`: an agent that
# follows a tool's suggestion ("lend it") could pull one of Donovan's windows onto the agent workspace, or start an
# app there. The bench opens what the task needs before the agent starts. A test compares this list with the tools
# BaneySpaces ships, so a new tool must be decided on here.
MCP_ALLOWED_TOOLS = ("windows", "snapshot", "find", "get", "click", "type", "set_value", "press", "scroll", "select", "toggle")
# click-at and drag (phase 4) are denied until the bench has a canvas task; press stays allowed (it is scoped the same way).
MCP_DENIED_TOOLS = ("open", "lend", "return", "shot", "click_at", "drag")


def claude_command(tool, prompt, claude_bin, mcp_config_path=None, guard_path=None):
    cmd = [claude_bin, "-p", prompt, "--model", CLAUDE_MODEL, "--output-format", "stream-json", "--verbose",
           "--max-turns", str(MAX_TURNS), "--no-session-persistence", "--disable-slash-commands",
           "--setting-sources", "", "--strict-mcp-config", "--permission-mode", "dontAsk"]
    if tool == "baneyspaces":
        cmd += ["--mcp-config", mcp_config_path, "--tools", "",
                "--allowedTools", ",".join(f"mcp__baneyspaces__{n}" for n in MCP_ALLOWED_TOOLS)]
    elif tool == "agent-desktop":
        cmd += ["--tools", "Bash", "--allowedTools", f"Bash({guard_path or GUARD}:*)", "--mcp-config", mcp_config_path]
    else:
        raise ValueError(tool)
    return cmd


def baneyspaces_mcp_config(binary):
    return {"mcpServers": {"baneyspaces": {"command": binary, "args": ["mcp"]}}}


def empty_mcp_config():
    return {"mcpServers": {}}


def agent_desktop_skill_prompt(guard_path=None):
    g = guard_path or GUARD
    return (f"You operate desktop apps with the agent-desktop CLI through the guard at {g} (run it by that full path, "
            f"one command per Bash call; it takes the same arguments as agent-desktop). Name windows only by the "
            f"--window-id you were given; it refuses any other window, any --app, and --headed. Read the guide with "
            f"`{g} skills get desktop`. Every command prints one JSON envelope.")


def _result_ok(content):
    """A tool result counts as a computer-use success unless it is an error or an envelope with ok:false."""
    text = content if isinstance(content, str) else json.dumps(content)
    return '"ok":false' not in text.replace(" ", "") and '"ok": false' not in text


def _envelope_error(content):
    text = content if isinstance(content, str) else " ".join(str(c.get("text", "")) for c in content if isinstance(c, dict))
    for line in reversed([ln for ln in text.splitlines() if ln.strip()]):
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(o, dict) and o.get("ok") is False and isinstance(o.get("error"), dict):
            e = o["error"]
            return {"code": str(e.get("code", "")).lower(), "suggestion": e.get("suggestion") or "", "retry": e.get("retry")}
    return None


def _verb_of(name, inp, guard):
    """The agent-desktop or BaneySpaces verb a computer-use tool_use performed (set-value, snapshot, ...)."""
    if name.startswith("mcp__baneyspaces__"):
        return name[len("mcp__baneyspaces__"):].replace("_", "-")
    words = str(inp.get("command", "")).replace(guard, "", 1).split()
    return words[0] if words else ""


def attempted_refusal(task, refusals, windows):
    """The last refusal that came from the call that ATTEMPTED the impossible action, or None.

    Matches the verb of the task's expect_refusal step, and, where the call names a window, that window. An unrelated
    call that happens to return ok:false (a find that matched nothing, a stale ref) is not the refusal the task asks for.
    """
    steps = [s for s in task.get("steps", []) if s.get("expect_refusal")]
    out = None
    for r in refusals:
        for s in steps:
            if r.get("verb") != s["do"]:
                continue
            inp = r.get("input") or {}
            want = windows.get(s.get("window")) if s.get("window") else None
            named = inp.get("window")
            if named is None:
                cmd = str(inp.get("command", ""))
                m = __import__("re").search(r"--window-id[= ]w?-?(\d+)", cmd)
                named = m.group(1) if m else None
            if want is not None and named is not None and str(named).replace("w-", "") != str(want):
                continue
            out = r
    return out


def parse_claude(stdout, guard_path=None):
    """Parse `claude -p --output-format stream-json --verbose`.

    -> {ok, turns, cost_usd, text, error, tool_calls, tool_errors, attempted, guard_refusals, refusals, shortcut, mcp, error_text}
    tool_calls   computer-use calls that came back fine; tool_errors those the TOOL refused (an envelope with ok:false);
    attempted    computer-use calls issued, returned or not; guard_refusals the bench guard's own refusals, which are
                 never the tool's (its binary was not reached)
    shortcut     a tool other than the computer-use tool actually ran (a denied attempt is not one)
    mcp          {server: status} from the init line, to notice an MCP server that never connected
    Works on a partial stream (a run killed at its timeout still shows the calls it made).
    """
    guard = guard_path or GUARD
    uses, results, mcp, final = {}, {}, {}, None
    for line in stdout.splitlines():
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = ev.get("type")
        if t == "system" and ev.get("subtype") == "init":
            for s in ev.get("mcp_servers") or []:
                mcp[s.get("name")] = s.get("status")
        elif t == "assistant":
            for c in (ev.get("message") or {}).get("content") or []:
                if isinstance(c, dict) and c.get("type") == "tool_use":
                    uses[c.get("id")] = (c.get("name", ""), c.get("input") or {})
        elif t == "user":
            for c in (ev.get("message") or {}).get("content") or []:
                if isinstance(c, dict) and c.get("type") == "tool_result":
                    results[c.get("tool_use_id")] = (bool(c.get("is_error")), c.get("content"))
        elif t == "result":
            final = ev
    calls = errors = attempted = guard_refusals = 0
    refusals, shortcut = [], None
    for uid, (name, inp) in uses.items():
        cu = name.startswith("mcp__baneyspaces") or (name == "Bash" and guard in str(inp.get("command", "")))
        is_err, content = results.get(uid, (True, None))
        if cu:
            attempted += 1          # issued, whether or not it ever came back (a hang inside the tool is the tool's)
            env_err = _envelope_error(content) if content is not None else None
            if env_err and env_err["code"] == "guard_refused":
                guard_refusals += 1     # the bench's own guard said no; the tool's binary was never reached
            elif env_err:
                errors += 1
                refusals.append(dict(env_err, verb=_verb_of(name, inp, guard), input=inp))
            elif not is_err and content is not None and _result_ok(content):
                calls += 1
        elif not is_err and content is not None:
            shortcut = shortcut or name
    if final is None:
        return {"ok": False, "turns": None, "cost_usd": None, "text": "", "tool_calls": calls, "tool_errors": errors,
                "attempted": attempted, "guard_refusals": guard_refusals, "refusals": refusals, "shortcut": shortcut,
                "mcp": mcp, "error": "claude printed no result", "error_text": ""}
    is_err = bool(final.get("is_error", False))
    return {"ok": not is_err, "turns": final.get("num_turns"), "cost_usd": final.get("total_cost_usd"),
            "text": str(final.get("result", ""))[:2000], "tool_calls": calls, "tool_errors": errors, "attempted": attempted,
            "guard_refusals": guard_refusals, "refusals": refusals, "shortcut": shortcut, "mcp": mcp,
            "error": final.get("subtype") if is_err else None,
            # account and quota errors are read from here (the result event) and stderr, never from the agent's prose
            "error_text": (str(final.get("subtype", "")) + " " + str(final.get("result", ""))) if is_err else ""}


# ---- codex exec with ChatGPT computer use ----------------------------------------------------------

def find_plugin_mcp(root=PLUGIN_GLOB_ROOT):
    """The newest unified-computer-use plugin's .mcp.json (it defines cua_repl), or None."""
    if not os.path.isdir(root):
        return None
    for ver in sorted(os.listdir(root), key=version_key, reverse=True):
        p = os.path.join(root, ver, ".mcp.json")
        if os.path.isfile(p):
            return p
    return None


def version_key(name):
    """26.1023.50603 -> (26, 1023, 50603); parts that are not numbers sort before numbers. 10.0.0 > 9.0.0."""
    return tuple((1, int(p)) if p.isdigit() else (0, p) for p in re.split(r"[.\-]", name))


def toml_str(s):
    return json.dumps(s)


def toml_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, str):
        return toml_str(v)
    if isinstance(v, list):
        return "[" + ", ".join(toml_value(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join(f"{json.dumps(k)} = {toml_value(x)}" for k, x in v.items()) + "}"
    raise TypeError(type(v))


def other_mcp_servers(config_path=USER_CODEX_CONFIG):
    """Names of the MCP servers in the user's Codex config other than cua_repl (read only). The ChatGPT
    column disables them for its one invocation so the only tool beyond codex's shell is computer use."""
    try:
        import tomllib
        with open(config_path, "rb") as fh:
            return sorted(n for n in (tomllib.load(fh).get("mcp_servers") or {}) if n != "cua_repl")
    except (OSError, ValueError, ImportError):
        return []


def cua_repl_overrides(mcp_json_path, disable=()):
    """-c overrides that define and enable cua_repl for ONE `codex exec`, from the plugin's own .mcp.json,
    and switch off the user's other MCP servers.

    ~/.codex/config.toml lists cua_repl as a disabled stub whose command is the ChatGPT app itself;
    `enabled=true` alone would start the Electron app. The real server is node + cua-repl.mjs with the
    computer surface on and the Sky service trusted, so every field is set here.
    """
    with open(mcp_json_path, encoding="utf-8") as fh:
        spec = json.load(fh)["mcpServers"]["cua_repl"]
    env = dict(spec.get("env", {}))
    env["CUA_REPL_ENABLED_SURFACES"] = "computer"
    env["NODE_REPL_TRUSTED_SERVICES"] = json.dumps({"sky": "@oai/sky/service"})
    fields = {
        "command": spec["command"], "args": spec.get("args", []), "enabled": True,
        "env": env, "env_vars": spec.get("env_vars", []),
        "startup_timeout_sec": spec.get("startup_timeout_sec", 120),
        "default_tools_approval_mode": "approve",
    }
    out = []
    for k, v in fields.items():
        out += ["-c", f"mcp_servers.cua_repl.{k}={toml_value(v)}"]
    for name in disable:
        out += ["-c", f"mcp_servers.{name}.enabled=false"]
    return out


def codex_command(prompt, codex_bin, mcp_json_path, cwd, disable=(), sandbox_route=None):
    """codex exec for the ChatGPT column. `-s read-only` confines codex's own shell tool only (and still
    lets it READ files). The cua_repl server is a separate node process codex starts, outside that sandbox,
    and whether its REPL can write files is NOT established. So nothing relies on the sandbox: any shell
    command or non-computer-use tool call is detected in the JSONL and fails the task, the fixture's secret
    lives only inside a document's content, and the cwd is an empty directory with no path to the fixtures.

    Sky/cua_repl never starts on Donovan's Mac: there is no flag or environment variable that allows it. The
    only way to build this command is to hand over a `sandbox_route` (the VM that will run it), and no such route
    exists until the phase 2 sandbox does, so on the host this always raises SandboxOnly."""
    if not sandbox_route:
        raise SandboxOnly("ChatGPT computer use runs only inside the sandbox VM, never on this Mac")
    return [codex_bin, "exec", "--json", "--ephemeral", "--skip-git-repo-check", "-s", "read-only",
            "-C", cwd, *cua_repl_overrides(mcp_json_path, disable), prompt]


def parse_codex(stdout):
    """-> {ok, turns, tool_calls, tool_errors, shell_calls, shortcut, text, error}.

    tool_calls   cua_repl calls that came back fine; shell_calls any command codex ran itself;
    shortcut     a shell command, or a call to any server other than cua_repl.
    `turns` approximates model round trips as all calls + 1. Works on a partial stream.
    """
    calls = errors = shell = attempted = 0
    other = None
    text, failed, done = "", None, False
    for line in stdout.splitlines():
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        item = ev.get("item") or {}
        etype = ev.get("type", "")
        if etype == "item.started" and item.get("type") == "mcp_tool_call" and "cua_repl" in str(item.get("server") or ""):
            attempted += 1
        if etype == "item.completed":
            kind = item.get("type", "")
            if kind == "command_execution":
                shell += 1
            elif kind == "mcp_tool_call" or ("tool" in kind and kind != "agent_message"):
                server = str(item.get("server") or item.get("tool_server") or "")
                if "cua_repl" in server or (not server and "cua_repl" in json.dumps(item)):
                    if item.get("error") or item.get("status") == "failed":
                        errors += 1
                    else:
                        calls += 1
                else:
                    other = other or (server or kind)
            elif kind == "agent_message":
                text = item.get("text", text)
        elif etype == "turn.completed":
            done = True
        elif etype in ("turn.failed", "error"):
            failed = str(ev.get("message") or ev.get("error") or ev)[:300]
    shortcut = ("a shell command" if shell else None) or other
    return {"ok": done and failed is None, "turns": calls + errors + shell + 1 if done else None, "tool_calls": calls,
            "tool_errors": errors, "attempted": max(attempted, calls + errors), "shell_calls": shell, "shortcut": shortcut,
            "text": text[:2000], "error": failed, "error_text": failed or ""}


AUTH_QUOTA = re.compile(r"(rate.?limit|quota|usage limit|limit reached|not logged in|please run /login|log ?in again|"
                        r"unauthori[sz]ed|\b401\b|\b403\b|invalid api key|credit balance|overloaded|\b529\b)", re.I)
MCP_FAIL = re.compile(r"(cua_repl[^\n]{0,160}(fail|error|could not|timed out|timeout|not found)|"
                      r"(fail|error|could not|timed out)[^\n]{0,160}cua_repl|mcp[^\n]{0,40}(start|initiali[sz])[^\n]{0,40}(fail|error|timed))", re.I)


def infra_failure(tool, rc, out, err, parsed, timeout_s=AGENT_TIMEOUT_S):
    """-> None, or (reason, fatal) when the failure is the harness's or the account's, not the tool's.

    Charged to the tool when its agent really ran: it made computer-use calls (or got refusals) and then
    failed to finish, including by running out of time. fatal means every later task would fail the same
    way (the MCP server will not connect, signed out, quota gone), so the column is stopped and reported
    n/a instead of scoring nothing 30 times.
    """
    # Account, quota and start-up errors are read from stderr and from the stream's own error events,
    # never from the agent's prose or a tool's output (an agent may well write "REFUSED: not authorized").
    text = f"{err}\n{parsed.get('error_text', '')}"
    worked = max(parsed.get("attempted") or 0, (parsed.get("tool_calls") or 0) + (parsed.get("tool_errors") or 0))
    if tool == "chatgpt" and MCP_FAIL.search(text) and not worked:
        return "cua_repl did not start: " + (err or parsed.get("error_text") or out).strip()[:200], True
    if tool == "baneyspaces":
        status = (parsed.get("mcp") or {}).get("baneyspaces")
        if status is not None and status != "connected":
            return f"the baneyspaces MCP server did not connect (status {status})", True
        if "mcp" in parsed and parsed["mcp"] == {} and parsed.get("turns") is not None and not worked:
            return "claude listed no MCP servers: baneyspaces mcp did not start", True
    if AUTH_QUOTA.search(text) and not worked:
        return "account or quota error: " + (err or parsed.get("error_text") or "").strip()[:200], True
    if rc == 124 and not worked:
        return f"timed out after {timeout_s} s with no computer-use call", False
    if parsed.get("turns") is None and not parsed.get("ok") and not worked and rc != 124:
        return "the agent produced no result: " + (parsed.get("error") or err or out or "no output").strip()[:200], False
    return None


def shell_join(argv):
    return " ".join(shlex.quote(a) for a in argv)
