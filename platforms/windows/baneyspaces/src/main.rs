//! `baneyspaces` for Windows. The CLI sends one request to `baneyspaces daemon` over a named pipe
//! and prints the envelope; `baneyspaces mcp` serves the agent tools over stdio.
//!
//! Everything that touches Windows is behind `cfg(windows)`; the rest (request parsing, the key
//! map, the persisted hidden list, the engine's envelope mapping) builds and is tested anywhere.

mod engine;
mod hidden;
mod ipc;
mod keys;
mod paths;

#[cfg(windows)]
mod agent;
#[cfg(windows)]
mod cloak;
#[cfg(windows)]
mod daemon;
#[cfg(windows)]
mod hook;
#[cfg(windows)]
mod winapi;

use baneyspaces_core::envelope::{Envelope, Retry};
use baneyspaces_core::{keymap, mcp};
use serde_json::{json, Value};
use std::io::Write;

const HELP: &str = "baneyspaces (Windows)

  switch <n>                     show workspace n (1-9) here, or go to the display that shows it
  move <n> [--stay] [--window W|--app NAME]  send the front window (or W: w-<hwnd>) to workspace n and follow it
  focus-monitor <name>           go to a monitor (\\\\.\\DISPLAY1 ...)
  ls                             windows by workspace, and the agent workspace
  state                          the whole model as JSON
  overview                       show or hide the overview (recorded; drawn in part 2)
  agent-workspace show|hide|toggle   show the agent workspace (you only; agents never do)
  agent status|windows           what is on the agent workspace
  agent open <app> [args...]     start an app as its own process on the agent workspace
  agent run [--dir D] -- CMD...  run a command in a console window on the agent workspace
  agent move <window>            park one of your windows there (not drivable)
  agent bring <window>           bring a window you parked back
  agent snapshot --window W [-i] [--compact]
  agent find --window W [--role R] [--name N] [--text T]
  agent get <ref> <property>     agent click <ref>      agent toggle <ref>
  agent set-value <ref> <value>  agent type <ref> <text>
  agent select <ref> <value>     agent scroll <ref> <up|down|left|right> [amount]
  agent shot --window W          agent log [--since SECS]
  agent press|key|pointer ...    not supported yet (phase 3-4)
  keys                           the key map for this platform
  daemon [--trace]               run the daemon (the Startup shortcut runs it)
  daemon stop                    ask the running daemon to restore every window and exit
  mcp                            MCP server on stdio (agent tools only)
  doctor                         what works and what does not

Flags: --agent-id ID (names you in the action log), --text (short human output).
Every command prints one JSON envelope: {ok, data} or {ok:false, error:{code, message, retry, suggestion}}.
";

fn fail(code: &str, msg: &str, sug: &str) -> Envelope {
    Envelope::err(code, msg, Retry::Never, sug)
}

/// Pulls `--flag value` out of `args`.
fn take(args: &mut Vec<String>, flag: &str) -> Option<String> {
    let i = args.iter().position(|a| a == flag)?;
    args.remove(i);
    (i < args.len()).then(|| args.remove(i))
}

fn take_switch(args: &mut Vec<String>, flag: &str) -> bool {
    match args.iter().position(|a| a == flag) {
        Some(i) => {
            args.remove(i);
            true
        }
        None => false,
    }
}

fn need(args: &[String], n: usize, usage: &str) -> Result<(), Envelope> {
    if args.len() >= n {
        Ok(())
    } else {
        Err(fail(
            "invalid_args",
            &format!("usage: {usage}"),
            "Run `baneyspaces help`.",
        ))
    }
}

/// Turns the command line into a daemon request.
fn request(mut a: Vec<String>) -> Result<Value, Envelope> {
    let Some(cmd) = (!a.is_empty()).then(|| a.remove(0)) else {
        return Err(fail(
            "invalid_args",
            "no command",
            "Run `baneyspaces help`.",
        ));
    };
    let req = |op: &str, args: Value| Ok(json!({ "op": op, "args": args }));
    match cmd.as_str() {
        "switch" => {
            need(&a, 1, "switch <n>")?;
            req("switch", json!({ "n": a[0] }))
        }
        "move" => {
            let stay = take_switch(&mut a, "--stay");
            let window = take(&mut a, "--window");
            let app = take(&mut a, "--app");
            need(&a, 1, "move <n> [--stay] [--window W|--app NAME]")?;
            req("move", json!({ "n": a[0], "stay": stay, "window": window, "app": app }))
        }
        "focus-monitor" => {
            need(&a, 1, "focus-monitor <name>")?;
            req("focus_monitor", json!({ "monitor": a[0] }))
        }
        "ls" | "state" | "overview" => req(&cmd, json!({})),
        "agent-workspace" => {
            need(&a, 1, "agent-workspace show|hide|toggle")?;
            match a[0].as_str() {
                "show" | "hide" | "toggle" => req(&format!("agent_{}", a[0]), json!({})),
                _ => Err(fail(
                    "invalid_args",
                    "usage: agent-workspace show|hide|toggle",
                    "",
                )),
            }
        }
        "agent" => agent_request(a),
        _ => Err(fail(
            "invalid_args",
            &format!("unknown command {cmd:?}"),
            "Run `baneyspaces help`.",
        )),
    }
}

const HANDS: &[&str] = &[
    "snapshot",
    "find",
    "get",
    "click",
    "set-value",
    "type",
    "toggle",
    "select",
    "scroll",
    "shot",
];

fn agent_request(mut a: Vec<String>) -> Result<Value, Envelope> {
    let Some(sub) = (!a.is_empty()).then(|| a.remove(0)) else {
        return Err(fail(
            "invalid_args",
            "usage: agent <status|open|run|snapshot|...>",
            "Run `baneyspaces help`.",
        ));
    };
    let req = |op: &str, args: Value| Ok(json!({ "op": op, "args": args }));
    match sub.as_str() {
        "status" | "windows" => req(&format!("agent_{sub}"), json!({})),
        "open" => {
            need(&a, 1, "agent open <app> [args...]")?;
            let app = a.remove(0);
            req("agent_open", json!({ "app": app, "args": a }))
        }
        "run" => {
            let dir = take(&mut a, "--dir");
            let cmd: Vec<String> = match a.iter().position(|x| x == "--") {
                Some(i) => a[i + 1..].to_vec(),
                None => a.clone(),
            };
            req("agent_run", json!({ "dir": dir, "command": cmd }))
        }
        "move" | "bring" => {
            need(&a, 1, &format!("agent {sub} <window>"))?;
            req(&format!("agent_{sub}"), json!({ "window": a[0] }))
        }
        "log" => {
            let since = take(&mut a, "--since").and_then(|s| s.parse::<u64>().ok());
            req("agent_log", json!({ "since": since }))
        }
        "press" | "key" | "pointer" | "click-at" | "mouse" | "focus" | "lend" | "return" => Err(Envelope::err(
            "not_supported",
            format!("agent {sub} is not available on Windows in part 1"),
            Retry::Never,
            "Keys and pointer arrive in phase 3-4, and only for the agent workspace. Use set-value or type on a ref instead.",
        )),
        v if HANDS.contains(&v) => hands_request(v, a),
        _ => Err(fail("invalid_args", &format!("unknown agent command {sub:?}"), "Run `baneyspaces help`.")),
    }
}

fn hands_request(verb: &str, mut a: Vec<String>) -> Result<Value, Envelope> {
    let window = take(&mut a, "--window");
    let mut args = json!({ "verb": verb });
    if let Some(w) = window {
        args["window"] = json!(w);
    }
    match verb {
        "snapshot" => {
            args["interactive"] =
                json!(take_switch(&mut a, "-i") | take_switch(&mut a, "--interactive"));
            args["compact"] = json!(take_switch(&mut a, "--compact"));
        }
        "find" => {
            for k in ["role", "name", "text"] {
                if let Some(v) = take(&mut a, &format!("--{k}")) {
                    args[k] = json!(v);
                }
            }
        }
        "get" => {
            need(&a, 2, "agent get <ref> <property>")?;
            args["ref"] = json!(a[0]);
            args["property"] = json!(a[1]);
        }
        "click" | "toggle" => {
            need(&a, 1, &format!("agent {verb} <ref>"))?;
            args["ref"] = json!(a[0]);
        }
        "set-value" | "select" => {
            need(&a, 2, &format!("agent {verb} <ref> <value>"))?;
            args["ref"] = json!(a[0]);
            args["value"] = json!(a[1..].join(" "));
        }
        "type" => {
            need(&a, 2, "agent type <ref> <text>")?;
            args["ref"] = json!(a[0]);
            args["text"] = json!(a[1..].join(" "));
        }
        "scroll" => {
            need(&a, 2, "agent scroll <ref> <direction> [amount]")?;
            args["ref"] = json!(a[0]);
            args["direction"] = json!(a[1]);
            if let Some(n) = a.get(2).and_then(|s| s.parse::<u64>().ok()) {
                args["amount"] = json!(n);
            }
        }
        _ => {}
    }
    Ok(json!({ "op": "hands", "args": args }))
}

fn print(env: &Envelope, text: bool) -> i32 {
    if text {
        match (&env.data, &env.error) {
            (_, Some(e)) => eprintln!("{}: {} ({})", e.code, e.message, e.suggestion),
            (Some(d), _) => println!("{}", serde_json::to_string_pretty(d).unwrap_or_default()),
            _ => {}
        }
    } else {
        println!("{}", env.to_json());
    }
    match &env.error {
        None => 0,
        Some(e) if e.code == "invalid_args" => 2,
        Some(_) => 1,
    }
}

fn mcp_tool_to_request(name: &str, args: &Value, agent: &str) -> Value {
    let verb = name
        .strip_prefix("agent_")
        .unwrap_or(name)
        .replace('_', "-");
    match verb.as_str() {
        "status" | "windows" => json!({ "op": format!("agent_{verb}"), "agent": agent }),
        "open" => json!({ "op": "agent_open", "agent": agent, "args": args }),
        v => {
            let mut a = args.clone();
            a["verb"] = json!(v);
            json!({ "op": "hands", "agent": agent, "args": a })
        }
    }
}

fn doctor(paths: &paths::Paths) -> Envelope {
    let mut checks = vec![];
    let mut add = |name: &str, ok: bool, detail: String| {
        checks.push(json!({ "check": name, "ok": ok, "detail": detail }))
    };
    add("windows", cfg!(windows), if cfg!(windows) { "running on Windows".into() } else { "this build is not for Windows: only the CLI parts run".to_string() });
    let ping = ipc::call(paths, &json!({ "op": "ping" }));
    add(
        "daemon",
        ping.ok,
        ping.error
            .map(|e| e.message)
            .unwrap_or_else(|| "running".into()),
    );
    match engine::locate() {
        Some(p) => add("hands engine", true, p.display().to_string()),
        None => add(
            "hands engine",
            false,
            "not built: platforms/windows/scripts/build-engine.ps1".into(),
        ),
    }
    add("state directory", paths.state.exists(), paths.state.display().to_string());
    let ok = checks.iter().all(|c| c["ok"] == true);
    Envelope::ok(json!({ "healthy": ok, "checks": checks }))
}

fn run_daemon(args: &[String]) -> i32 {
    #[cfg(windows)]
    {
        if args.get(1).map(String::as_str) == Some("stop") {
            let paths = paths::Paths::from_env();
            return print(&ipc::call(&paths, &json!({ "op": "quit" })), false);
        }
        daemon::run(args.iter().any(|a| a == "--trace"))
    }
    #[cfg(not(windows))]
    {
        let _ = args;
        eprintln!("baneyspaces daemon: this build is not for Windows");
        1
    }
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let text = take_switch(&mut args, "--text");
    let agent = take(&mut args, "--agent-id")
        .or_else(|| std::env::var("BANEYSPACES_AGENT_ID").ok())
        .unwrap_or_else(|| "agent".into());
    let paths = paths::Paths::from_env();
    let Some(first) = args.first().cloned() else {
        print!("{HELP}");
        std::process::exit(2);
    };
    let code = match first.as_str() {
        "help" | "--help" | "-h" => {
            print!("{HELP}");
            0
        }
        "daemon" => run_daemon(&args),
        "keys" => {
            let platform = take(&mut args, "--platform").unwrap_or_else(|| "windows".into());
            let all = keymap::keys();
            match all["platforms"].get(&platform) {
                Some(p) => print(&Envelope::ok(json!({ "platform": platform, "keys": p, "actions": all["actions"] })), text),
                None => print(&fail("invalid_args", &format!("no platform {platform:?}"), "Use macos, linux or windows."), text),
            }
        }
        "doctor" => print(&doctor(&paths), text),
        "mcp" => {
            let stdin = std::io::stdin();
            let mut out = std::io::stdout();
            let mut call =
                |name: &str, a: &Value| ipc::call(&paths, &mcp_tool_to_request(name, a, &agent));
            let r = mcp::serve(stdin.lock(), &mut out, &mut call);
            let _ = out.flush();
            if r.is_ok() {
                0
            } else {
                1
            }
        }
        _ => match request(args) {
            Ok(mut req) => {
                req["agent"] = json!(agent);
                print(&ipc::call(&paths, &req), text)
            }
            Err(e) => print(&e, text),
        },
    };
    std::process::exit(code);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn switch_and_move_become_requests() {
        assert_eq!(request(v(&["switch", "3"])).unwrap(), json!({"op":"switch","args":{"n":"3"}}));
        let r = request(v(&["move", "2", "--stay", "--app", "notepad"])).unwrap();
        assert_eq!(r["args"], json!({"n":"2","stay":true,"window":null,"app":"notepad"}));
    }

    #[test]
    fn unknown_and_short_commands_are_invalid_args() {
        for bad in [v(&[]), v(&["frobnicate"]), v(&["switch"]), v(&["agent"]), v(&["agent", "open"])] {
            assert_eq!(request(bad).unwrap_err().error.unwrap().code, "invalid_args");
        }
    }

    #[test]
    fn keys_and_pointer_are_not_supported_in_part_one() {
        for sub in ["press", "key", "pointer", "lend", "return"] {
            assert_eq!(request(v(&["agent", sub])).unwrap_err().error.unwrap().code, "not_supported");
        }
    }

    #[test]
    fn hands_requests_carry_their_window_and_ref() {
        let r = request(v(&["agent", "type", "@s8f3k2p9:e8", "hello", "world"])).unwrap();
        assert_eq!(r["args"], json!({"verb":"type","ref":"@s8f3k2p9:e8","text":"hello world"}));
        let r = request(v(&["agent", "snapshot", "--window", "w-1", "-i"])).unwrap();
        assert_eq!(r["args"]["window"], "w-1");
        assert_eq!(r["args"]["interactive"], true);
    }
}
