//! `baneyspaces` for Linux (Omarchy, Hyprland). The CLI sends one request to `baneyspaces daemon`
//! and prints the envelope; `baneyspaces mcp` serves the agent tools over stdio.

mod daemon;
mod hands;
mod hypr;
mod paths;
mod proc;
mod scheme;

use baneyspaces_core::envelope::{Envelope, Retry};
use baneyspaces_core::{keymap, mcp};
use serde_json::{json, Value};
use std::io::Write;

const HELP: &str = "baneyspaces (Linux, Hyprland)

  switch <n>                     go to workspace n (1-9) on the monitor you are on
  move <n> [--stay] [--window W] send the front window to workspace n and follow it (--stay: don't)
  focus-monitor <name>           go to a monitor
  ls                             windows by workspace, and the agent workspace
  state                          the whole model as JSON
  overview                       show or hide the overview (drawn by the shell plugin, part 2)
  agent-workspace show|hide|toggle   show the agent workspace (you only; agents never do)
  agent status|windows           what is on the agent workspace
  agent open <app> [args...]     start an app as its own process on the agent workspace
  agent run [--dir D] -- CMD...  run a command in a terminal on the agent workspace
  agent move <window>            park one of your windows there (not drivable)
  agent bring <window>           bring a window you parked back
  agent snapshot --window W [-i] [--compact]
  agent find --window W [--role R] [--name N] [--text T]
  agent get <ref> <property>     agent click <ref>      agent toggle <ref>
  agent set-value <ref> <value>  agent type <ref> <text>
  agent select <ref> <value>     agent scroll <ref> <up|down|left|right> [amount]
  agent shot --window W          agent log [--since SECS]
  agent press|key|pointer ...    not supported yet (phase 3-4)
  keys [--hypr-lua]              the key map for this platform
  daemon [--trace]               run the daemon (Omarchy autostarts it)
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
            let monitor = take(&mut a, "--monitor");
            need(&a, 1, "switch <n> [--monitor M]")?;
            req("switch", json!({ "n": a[0], "monitor": monitor }))
        }
        "move" => {
            let stay = take_switch(&mut a, "--stay");
            let window = take(&mut a, "--window");
            need(&a, 1, "move <n> [--stay] [--window W]")?;
            req("move", json!({ "n": a[0], "stay": stay, "window": window }))
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
            format!("agent {sub} is not available on Linux in part 1"),
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
    match hypr::Hypr::from_env() {
        Ok(h) => add("hyprland", true, h.dir().display().to_string()),
        Err(e) => add("hyprland", false, e),
    }
    let ping = daemon::call(paths, &json!({ "op": "ping" }));
    add(
        "daemon",
        ping.ok,
        ping.error
            .map(|e| e.message)
            .unwrap_or_else(|| "running".into()),
    );
    match hands::locate() {
        Some(p) => add("hands engine", true, p.display().to_string()),
        None => add(
            "hands engine",
            false,
            "not built: platforms/linux/scripts/build-engine.sh".into(),
        ),
    }
    add(
        "accessibility bus",
        std::env::var("DBUS_SESSION_BUS_ADDRESS").is_ok()
            || std::env::var("XDG_RUNTIME_DIR")
                .map(|r| std::path::Path::new(&r).join("bus").exists())
                .unwrap_or(false),
        "session bus (AT-SPI is reached through it)".into(),
    );
    let ok = checks.iter().all(|c| c["ok"] == true);
    Envelope::ok(json!({ "healthy": ok, "checks": checks }))
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
        "daemon" => daemon::run(args.iter().any(|a| a == "--trace")),
        "keys" => {
            if args.iter().any(|a| a == "--hypr-lua") {
                print!("{}", keymap::render_hypr_lua("baneyspaces"));
                0
            } else {
                print(&Envelope::ok(keymap::keys()), text)
            }
        }
        "doctor" => print(&doctor(&paths), text),
        "mcp" => {
            let stdin = std::io::stdin();
            let mut out = std::io::stdout();
            let mut call =
                |name: &str, a: &Value| daemon::call(&paths, &mcp_tool_to_request(name, a, &agent));
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
                print(&daemon::call(&paths, &req), text)
            }
            Err(e) => print(&e, text),
        },
    };
    std::process::exit(code);
}
