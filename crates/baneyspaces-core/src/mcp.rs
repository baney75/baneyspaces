//! The stdio MCP server's protocol half: JSON-RPC 2.0, `initialize`, `tools/list`, `tools/call`.
//! The tools are agent-scoped only: no tool switches or moves your workspaces, or reads them.
//! Tool results are the same envelope the CLI prints. See `spec/mcp-tools.json`.

use crate::envelope::{Envelope, Retry};
use serde_json::{json, Value};
use std::io::{BufRead, Write};

pub const SERVER_NAME: &str = "baneyspaces";
pub const FALLBACK_PROTOCOL: &str = "2024-11-05";

/// The tool catalog. `spec/mcp-tools.json` is generated from this and a test keeps them equal.
pub fn tools() -> Value {
    let r = |desc: &str, props: Value, req: &[&str]| json!({ "type": "object", "properties": props, "required": req, "additionalProperties": false, "description": desc });
    let s = |d: &str| json!({ "type": "string", "description": d });
    let reference = json!({ "type": "string", "pattern": "^@s[a-z0-9]+:e[0-9]+$", "description": "A ref from a snapshot, such as @s8f3k2p9:e8." });
    let window = s("A window id from agent_windows or agent_open (the Hyprland address, 0x...).");
    let agent = json!([
        { "name": "agent_status", "description": "What is on the agent workspace: windows, processes, whether it is showing.",
          "inputSchema": r("", json!({}), &[]) },
        { "name": "agent_windows", "description": "Windows on the agent workspace you may act on.",
          "inputSchema": r("", json!({}), &[]) },
        { "name": "agent_open", "description": "Start an allowlisted app on the agent workspace, by name, as its own process with its own session bus. You stay where you are. Only files inside the handoff folder may be passed: no flags, no paths to programs, no URLs (bad_arguments). An app not on the allowlist is needs_sandbox before it starts.",
          "inputSchema": r("", json!({ "app": s("The app's name, such as foot. Never a path."), "args": { "type": "array", "items": { "type": "string" }, "description": "Paths of files inside the handoff folder." } }), &["app"]) },
        { "name": "agent_snapshot", "description": "Accessibility tree of one agent window, with refs to act on.",
          "inputSchema": r("", json!({ "window": window, "interactive": { "type": "boolean" }, "compact": { "type": "boolean" } }), &["window"]) },
        { "name": "agent_find", "description": "Find elements in an agent window by role, name or text.",
          "inputSchema": r("", json!({ "window": window, "role": s("Accessibility role."), "name": s("Accessible name."), "text": s("Text content.") }), &["window"]) },
        { "name": "agent_get", "description": "Read one property (text, value, title, bounds, role, states) of a ref.",
          "inputSchema": r("", json!({ "ref": reference, "property": s("text, value, title, bounds, role or states.") }), &["ref", "property"]) },
        { "name": "agent_click", "description": "Press a ref through the accessibility API. Returns evidence read back from the element.",
          "inputSchema": r("", json!({ "ref": reference }), &["ref"]) },
        { "name": "agent_set_value", "description": "Set a ref's value through the accessibility API.",
          "inputSchema": r("", json!({ "ref": reference, "value": s("The new value.") }), &["ref", "value"]) },
        { "name": "agent_type", "description": "Insert text into a text ref through the accessibility API (no key events).",
          "inputSchema": r("", json!({ "ref": reference, "text": s("Text to insert.") }), &["ref", "text"]) },
        { "name": "agent_toggle", "description": "Toggle a checkbox or switch ref.",
          "inputSchema": r("", json!({ "ref": reference }), &["ref"]) },
        { "name": "agent_select", "description": "Select an option in a list or dropdown ref.",
          "inputSchema": r("", json!({ "ref": reference, "value": s("The option to select.") }), &["ref", "value"]) },
        { "name": "agent_scroll", "description": "Scroll a ref.",
          "inputSchema": r("", json!({ "ref": reference, "direction": { "type": "string", "enum": ["up", "down", "left", "right"] }, "amount": { "type": "integer", "minimum": 1 } }), &["ref", "direction"]) },
        { "name": "agent_shot", "description": "Capture one agent window. Returned only when asked for.",
          "inputSchema": r("", json!({ "window": window }), &["window"]) }
    ]);
    let mut all = agent.as_array().cloned().unwrap_or_default();
    all.extend(config_tools());
    Value::Array(all)
}

/// The configuration tools (`spec/config.md`, Interface): the same set as the CLI, validated
/// before anything changes, every change recorded with the caller.
pub fn config_tools() -> Vec<Value> {
    let r = |props: Value, req: &[&str]| json!({ "type": "object", "properties": props, "required": req, "additionalProperties": false });
    let s = |d: &str| json!({ "type": "string", "description": d });
    let path = s("A setting by dotted path, such as animation.dock.in.duration_ms or keys.bindings.\"mod+1\".");
    let doc = s("A whole config document as TOML or JSON text.");
    let name = s("A theme name: built-in (baneyspaces, omarchy, minimal) or a custom one.");
    vec![
        json!({ "name": "config_schema", "description": "Read this first: the JSON Schema of config.toml, every setting with its type, range and default.", "inputSchema": r(json!({}), &[]) }),
        json!({ "name": "config_get", "description": "The effective value of a setting (defaults filled in), or the whole config when no path is given.", "inputSchema": r(json!({ "path": path }), &[]) }),
        json!({ "name": "config_set", "description": "Change one setting. Validated first and applied live; refused changes name the exact path and reason (config_invalid) and change nothing. value is any JSON.", "inputSchema": r(json!({ "path": path, "value": { "description": "The new value, as JSON: a string, number, boolean, array or table." } }), &["path", "value"]) }),
        json!({ "name": "config_unset", "description": "Put one setting back to its default.", "inputSchema": r(json!({ "path": path }), &["path"]) }),
        json!({ "name": "config_apply", "description": "Replace the whole config with a TOML or JSON document, validated as one change.", "inputSchema": r(json!({ "text": doc }), &["text"]) }),
        json!({ "name": "config_validate", "description": "Check a document without applying it.", "inputSchema": r(json!({ "text": doc }), &["text"]) }),
        json!({ "name": "config_diff", "description": "What differs from the defaults, or from a history version.", "inputSchema": r(json!({ "version": { "type": "integer", "minimum": 1, "description": "A version from config_history." } }), &[]) }),
        json!({ "name": "config_undo", "description": "Step back n versions (default 1). The last 50 are kept.", "inputSchema": r(json!({ "n": { "type": "integer", "minimum": 1 } }), &[]) }),
        json!({ "name": "config_history", "description": "The versions kept, newest first, each with time, caller and a one-line summary.", "inputSchema": r(json!({}), &[]) }),
        json!({ "name": "config_reset", "description": "Put a section (keys, theme, animation, behavior, rules, hooks) or everything back to the defaults. Always works.", "inputSchema": r(json!({ "section": { "type": "string", "enum": ["keys", "theme", "animation", "behavior", "rules", "hooks"] } }), &[]) }),
        json!({ "name": "theme_list", "description": "Built-in and custom themes, and the palettes.", "inputSchema": r(json!({}), &[]) }),
        json!({ "name": "theme_show", "description": "A theme's resolved tokens and palette.", "inputSchema": r(json!({ "name": name }), &["name"]) }),
        json!({ "name": "theme_create", "description": "Create a custom theme (themes/<name>.toml) that extends another, with optional tokens to change and an optional palette of the twelve roles.", "inputSchema": r(json!({ "name": s("Lowercase letters, digits, - and _."), "extends": name, "tokens": { "type": "object", "description": "Tokens to change, as in spec/themes.json." }, "palette": { "type": "object", "description": "The twelve palette roles as #rrggbb, and optionally mode." }, "label": s("A name to show.") }), &["name", "extends"]) }),
        json!({ "name": "theme_set", "description": "Switch to a theme.", "inputSchema": r(json!({ "name": name }), &["name"]) }),
        json!({ "name": "theme_delete", "description": "Delete a custom theme. Refused while the config uses it.", "inputSchema": r(json!({ "name": name }), &["name"]) }),
    ]
}

pub fn tool_names() -> Vec<String> {
    tools().as_array().map(|a| a.iter().filter_map(|t| t["name"].as_str().map(String::from)).collect()).unwrap_or_default()
}

fn rpc_error(id: &Value, code: i64, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

/// Handles one JSON-RPC message. Returns the reply, or `None` for a notification.
pub fn handle(msg: &Value, call: &mut dyn FnMut(&str, &Value) -> Envelope) -> Option<Value> {
    let id = msg.get("id").cloned();
    let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
    let Some(id) = id else { return None }; // notifications get no reply
    Some(match method {
        "initialize" => {
            let ver = msg["params"]["protocolVersion"].as_str().unwrap_or(FALLBACK_PROTOCOL);
            json!({ "jsonrpc": "2.0", "id": id, "result": {
                "protocolVersion": ver,
                "capabilities": { "tools": { "listChanged": false } },
                "serverInfo": { "name": SERVER_NAME, "version": env!("CARGO_PKG_VERSION") },
                "instructions": "Agent computer use on the agent workspace only. Open an app with agent_open, snapshot it, act on refs, and read the evidence in each result. Nothing here touches the user's workspaces. config_* and theme_* tools change the BaneySpaces configuration (keys, themes, animations, behavior): read config_schema first; every change is validated, applied live and recorded in history under your name."
            }})
        }
        "ping" => json!({ "jsonrpc": "2.0", "id": id, "result": {} }),
        "tools/list" => json!({ "jsonrpc": "2.0", "id": id, "result": { "tools": tools() } }),
        "tools/call" => {
            let name = msg["params"]["name"].as_str().unwrap_or("");
            if !tool_names().iter().any(|n| n == name) {
                return Some(rpc_error(&id, -32602, &format!("unknown tool {name}")));
            }
            let args = msg["params"].get("arguments").cloned().unwrap_or_else(|| json!({}));
            let env = if args.is_object() { call(name, &args) } else { Envelope::err("invalid_args", "arguments must be an object", Retry::Never, "Send a JSON object.") };
            let text = env.to_json();
            json!({ "jsonrpc": "2.0", "id": id, "result": {
                "content": [{ "type": "text", "text": text }],
                "structuredContent": serde_json::to_value(&env).unwrap_or(Value::Null),
                "isError": !env.ok
            }})
        }
        _ => rpc_error(&id, -32601, &format!("method not found: {method}")),
    })
}

/// Newline-delimited JSON-RPC over stdio, until the input ends.
pub fn serve<R: BufRead, W: Write>(input: R, mut output: W, call: &mut dyn FnMut(&str, &Value) -> Envelope) -> std::io::Result<()> {
    for line in input.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Value>(&line) {
            Ok(v) if v.is_array() => Some(rpc_error(&Value::Null, -32600, "batches are not supported")),
            Ok(v) => handle(&v, call),
            Err(_) => Some(rpc_error(&Value::Null, -32700, "parse error")),
        };
        if let Some(r) = reply {
            writeln!(output, "{r}")?;
            output.flush()?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(lines: &[Value]) -> Vec<Value> {
        let input = lines.iter().map(|l| l.to_string()).collect::<Vec<_>>().join("\n");
        let mut out = Vec::new();
        let mut seen = vec![];
        let mut call = |n: &str, a: &Value| {
            seen.push((n.to_string(), a.clone()));
            Envelope::ok(json!({ "echo": n }))
        };
        serve(input.as_bytes(), &mut out, &mut call).unwrap();
        String::from_utf8(out).unwrap().lines().map(|l| serde_json::from_str(l).unwrap()).collect()
    }

    #[test]
    fn initialize_then_list_then_call() {
        let out = run(&[
            json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}),
            json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
            json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}),
            json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"agent_status","arguments":{}}}),
        ]);
        assert_eq!(out.len(), 3, "the notification gets no reply");
        assert_eq!(out[0]["result"]["protocolVersion"], "2025-06-18");
        assert!(out[0]["result"]["capabilities"]["tools"].is_object());
        assert_eq!(out[1]["result"]["tools"].as_array().unwrap().len(), tool_names().len());
        assert_eq!(out[2]["result"]["isError"], false);
        assert_eq!(out[2]["result"]["structuredContent"]["data"]["echo"], "agent_status");
    }

    #[test]
    fn the_spec_file_is_the_catalog() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../spec/mcp-tools.json");
        let want = serde_json::to_string_pretty(&json!({ "version": 1, "tools": tools() })).unwrap() + "\n";
        if std::env::var("UPDATE_SPEC").is_ok() {
            std::fs::write(path, &want).unwrap();
        }
        assert_eq!(std::fs::read_to_string(path).expect("spec/mcp-tools.json"), want, "regenerate with: UPDATE_SPEC=1 cargo test -p baneyspaces-core");
    }

    #[test]
    fn no_tool_reaches_the_users_workspaces() {
        for n in tool_names() {
            assert!(n.starts_with("agent_") || n.starts_with("config_") || n.starts_with("theme_"), "{n}");
            assert!(!n.contains("switch") && !n.contains("move"), "{n}");
        }
    }

    #[test]
    fn unknown_tool_and_method_are_json_rpc_errors() {
        let out = run(&[
            json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"switch","arguments":{}}}),
            json!({"jsonrpc":"2.0","id":2,"method":"resources/list"}),
        ]);
        assert_eq!(out[0]["error"]["code"], -32602);
        assert_eq!(out[1]["error"]["code"], -32601);
    }

    #[test]
    fn a_failed_envelope_sets_is_error() {
        let mut call = |_: &str, _: &Value| Envelope::err("not_in_scope", "no", Retry::Never, "x");
        let r = handle(&json!({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"agent_click","arguments":{"ref":"@sa:e1"}}}), &mut call).unwrap();
        assert_eq!(r["result"]["isError"], true);
        assert_eq!(r["result"]["structuredContent"]["error"]["code"], "not_in_scope");
    }

    #[test]
    fn garbage_is_a_parse_error_not_a_crash() {
        let out = run(&[]);
        assert!(out.is_empty());
        let mut o = Vec::new();
        serve("{nope\n".as_bytes(), &mut o, &mut |_, _| Envelope::ok(json!(null))).unwrap();
        assert!(String::from_utf8(o).unwrap().contains("-32700"));
    }
}
