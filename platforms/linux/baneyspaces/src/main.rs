//! `baneyspaces` for Linux (Omarchy, Hyprland). The CLI sends one request to `baneyspaces daemon`
//! and prints the envelope; `baneyspaces mcp` serves the agent tools over stdio.

mod agentws;
mod apps;
mod bus;
mod daemon;
mod hands;
mod hypr;
mod paths;
mod proc;
mod scheme;
mod shot;

use baneyspaces_core::envelope::{Envelope, Retry};
use baneyspaces_core::{keymap, mcp};
use serde_json::{json, Value};
use std::io::Write;

const HELP: &str = "baneyspaces (Linux, Hyprland)

  --version                      this build's version and the commit it came from
  switch <n>                     show workspace n (1-9) here, or go to the display that shows it
  move <n> [--stay] [--window W] send the front window to workspace n and follow it (--stay: don't)
  focus-monitor <name>           go to a monitor
  ls                             windows by workspace, and the agent workspace
  state                          the whole model as JSON
  overview                       show or hide the overview (drawn by the shell plugin, part 2)
  agent-workspace show|hide|toggle   show the agent workspace (you only; agents never do)
  agent status|windows           what is on the agent workspace
  agent open <app> [file...] [--new_window=false] [--wait S]
                                 start an allowlisted app (by name) on the agent workspace, with files
                                 from the handoff folder only: no flags, no paths, no URLs. The result's
                                 window is recorded for your session (--new_window=false reuses it)
  agent workspaces               the nine and the agent workspace: shown, current, window counts (read only)
  agent arrange full|halves|thirds|grid [window...] | frames 0xADDR=x,y,w,h ...
                                 lay out the agent workspace's windows (never yours)
  agent move --window W [--frame x,y,w,h]   an agent window onto the agent workspace, or a new frame
  agent close --window W         close a window your session's `agent open` made (nothing else)
  agent run [--dir D] -- CMD...  run a command in a terminal on the agent workspace
  agent move <window>            park one of your windows there (not drivable; you only)
  agent bring <window>           bring a window you parked back
  agent snapshot --window W [-i] [--compact]
  agent find --window W [--role R] [--name N] [--text T]
  agent get <ref> <property>     agent click <ref>      agent toggle <ref>
  agent set-value <ref> <value>  agent type <ref> <text>
  agent select <ref> <value>     agent scroll <ref> <up|down|left|right> [amount]
  agent shot --window W [--out NAME]   a PNG of one agent window, in the state folder's shots/
  agent log [--since SECS]
  agent press|key|pointer ...    not supported yet (phase 3-4)
  keys [--hypr-lua]              the key map for this platform
  daemon [--trace]               run the daemon (Omarchy autostarts it)
  stop                           stop the daemon (uninstall.sh does this)
  mcp                            MCP server on stdio (agent tools only)
  doctor                         what works and what does not

Flags, before the command: --agent-id ID (names you in the action log), --text (short human output).
After open, arrange, move --window and close: --session S (default $BANEYSPACES_SESSION, else your terminal).
With no daemon running, `switch` and `move` fall back to Hyprland's own dispatch.
Every command prints one JSON envelope: {ok, data} or {ok:false, error:{code, message, retry, suggestion}}.
";

/// Flags that belong to the command line as a whole, accepted only before the command so that a
/// command's own `--text` or `--agent-id` reaches it untouched.
#[derive(Default, Debug, PartialEq, Eq)]
struct Globals {
    text: bool,
    agent: Option<String>,
}

fn split_globals(mut args: Vec<String>) -> (Globals, Vec<String>) {
    let mut g = Globals::default();
    loop {
        match args.first().map(String::as_str) {
            Some("--text") => {
                g.text = true;
                args.remove(0);
            }
            Some("--agent-id") if args.len() >= 2 => {
                g.agent = Some(args[1].clone());
                args.drain(..2);
            }
            Some(a) if a.starts_with("--agent-id=") => {
                g.agent = Some(a["--agent-id=".len()..].to_string());
                args.remove(0);
            }
            _ => return (g, args),
        }
    }
}

/// The fallback, unless the caller is an agent's shell (it carries a launch token): the daemon
/// refuses an agent's switch and move, and with the daemon down the CLI must not be the way round
/// that. Accident-proofing, like the daemon's check.
fn guarded_fallback(req: &Value, agent_shell: bool, run: impl Fn(&Value) -> Option<Envelope>) -> Option<Envelope> {
    if agent_shell && matches!(req["op"].as_str(), Some("switch" | "move")) {
        return Some(Envelope::err(
            "not_in_scope",
            format!("{} is for you, not for an agent", req["op"].as_str().unwrap_or("this")),
            Retry::Never,
            "An agent drives only the agent workspace. Ask the user to do this.",
        ));
    }
    run(req)
}

/// What a workspace key does when the daemon is not running: Hyprland's own dispatch, so a
/// reload before the daemon starts (or a crashed daemon) leaves the keys working.
fn fallback(req: &Value) -> Option<Envelope> {
    let a = &req["args"];
    let n = a["n"].as_str().map(String::from).or_else(|| a["n"].as_u64().map(|n| n.to_string()))?;
    if n.len() != 1 || !('1'..='9').contains(&n.chars().next()?) {
        return None;
    }
    let lua = match req["op"].as_str()? {
        "switch" => format!("hl.dsp.focus({{ workspace = \"{n}\" }})"),
        "move" => {
            let follow = !a["stay"].as_bool().unwrap_or(false);
            match a["window"].as_str() {
                Some(w) if w.chars().all(|c| c.is_ascii_alphanumeric()) => format!("hl.dsp.window.move({{ workspace = \"{n}\", follow = {follow}, window = \"address:{w}\" }})"),
                Some(_) => return None,
                None => format!("hl.dsp.window.move({{ workspace = \"{n}\", follow = {follow} }})"),
            }
        }
        _ => return None,
    };
    let hypr = hypr::Hypr::from_env().ok()?;
    Some(match hypr.dispatch(&lua) {
        Ok(()) => Envelope::ok(json!({ "fallback": "hyprland", "note": "baneyspaces daemon is not running; Hyprland's own dispatch was used" })),
        Err(e) => Envelope::err("compositor_error", e.to_string(), if e.uncertain() { Retry::Never } else { Retry::Safe }, "Is Hyprland running?"),
    })
}

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

/// A Mac-style boolean flag: `--name` is true, `--name=false` or `--name=0` is false. Both spellings
/// (`new_window`, `new-window`) are taken.
fn take_bool(args: &mut Vec<String>, name: &str) -> Option<bool> {
    let names = [format!("--{name}"), format!("--{}", name.replace('_', "-"))];
    let i = args.iter().position(|a| names.iter().any(|n| a == n || a.starts_with(&format!("{n}="))))?;
    let a = args.remove(i);
    Some(match a.split_once('=') {
        Some((_, v)) => v != "false" && v != "0",
        None => true,
    })
}

/// The terminal this command runs in, the Mac's default session.
fn controlling_tty() -> Option<String> {
    (0..3).find_map(|fd| {
        let p = std::fs::read_link(format!("/proc/self/fd/{fd}")).ok()?;
        let s = p.to_string_lossy().into_owned();
        (s.starts_with("/dev/pts/") || s.starts_with("/dev/tty")).then_some(s)
    })
}

/// The agent session a request belongs to: `--session S`, else `$BANEYSPACES_SESSION`, else the
/// terminal, else "default" (the Mac's order). `close` closes only what this session's `open` made.
/// Like the agent id, it is the caller's word: accident-proofing, not a boundary.
fn session_of(args: &mut Vec<String>, env: Option<String>, tty: Option<String>) -> String {
    take(args, "--session").or(env.filter(|s| !s.is_empty())).or(tty).unwrap_or_else(|| "default".into())
}

fn session(args: &mut Vec<String>) -> String {
    session_of(args, std::env::var("BANEYSPACES_SESSION").ok(), controlling_tty())
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
            need(&a, 1, "move <n> [--stay] [--window W]")?;
            req("move", json!({ "n": a[0], "stay": stay, "window": window }))
        }
        "focus-monitor" => {
            need(&a, 1, "focus-monitor <name>")?;
            req("focus_monitor", json!({ "monitor": a[0] }))
        }
        "ls" | "state" | "overview" | "stop" => req(&cmd, json!({})),
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
            let session = session(&mut a);
            let new_window = take_bool(&mut a, "new_window");
            let wait = match take(&mut a, "--wait") {
                None => None,
                Some(w) => Some(w.parse::<u64>().map_err(|_| fail("invalid_args", &format!("--wait takes seconds, not {w}"), "usage: agent open <app> [file...] [--new_window=false] [--wait S]"))?),
            };
            need(&a, 1, "agent open <app> [args...]")?;
            let app = a.remove(0);
            let mut args = json!({ "app": app, "args": a, "session": session });
            if let Some(n) = new_window {
                args["new_window"] = json!(n);
            }
            if let Some(w) = wait {
                args["wait"] = json!(w);
            }
            req("agent_open", args)
        }
        "workspaces" => req("agent_workspaces", json!({})),
        "arrange" => {
            let session = session(&mut a);
            need(&a, 1, "agent arrange full|halves|thirds|grid [window...] | frames 0xADDR=x,y,w,h ...")?;
            let layout = a.remove(0);
            req("agent_arrange", json!({ "layout": layout, "windows": a, "session": session }))
        }
        // `agent move --window W` is the agent's verb (the Mac's hands `move`); `agent move <window>`
        // stays yours and parks one of your windows (refused to agents). The Mac tells them apart the same way.
        "move" if a.iter().any(|x| x == "--window") => {
            let session = session(&mut a);
            let window = take(&mut a, "--window");
            let frame = take(&mut a, "--frame");
            if !a.is_empty() || window.is_none() {
                return Err(fail("invalid_args", "usage: agent move --window 0xADDR [--frame x,y,width,height]", "Run `baneyspaces help`."));
            }
            let mut args = json!({ "window": window, "session": session });
            if let Some(f) = frame {
                args["frame"] = json!(f);
            }
            req("agent_move_window", args)
        }
        "close" => {
            let session = session(&mut a);
            let window = take(&mut a, "--window");
            if !a.is_empty() || window.is_none() {
                return Err(fail("invalid_args", "usage: agent close --window 0xADDR", "Run `baneyspaces help`."));
            }
            req("agent_close", json!({ "window": window, "session": session }))
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
    // `--window` belongs to the verbs that name a window. For the others everything after the ref is
    // data (typed text may well contain it).
    let window = if matches!(verb, "snapshot" | "find" | "shot") { take(&mut a, "--window") } else { None };
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
        "shot" => {
            if let Some(o) = take(&mut a, "--out") {
                args["out"] = json!(o);
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
        "open" => {
            // This server's own session, always: a tool argument cannot claim another session's windows.
            let mut a = if args.is_object() { args.clone() } else { json!({}) };
            a["session"] = json!(format!("mcp:{}", std::process::id()));
            json!({ "op": "agent_open", "agent": agent, "args": a })
        }
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

/// What this binary was built from (build.rs). It is kept in the file as plain text so `polycarp version`
/// can read it without running anything.
#[used]
static BUILD_STAMP: &str = env!("POLYCARP_BUILD_STAMP");

/// "baneyspaces 0.1.0 (abc1234)", with "-dirty" when tracked files had changes, or the version alone
/// for a build made outside a git checkout.
fn version_line(stamp: &str) -> String {
    let fields: Vec<&str> = stamp.split('|').collect();
    let (commit, dirty, version) = match fields.as_slice() {
        ["polycarp-build", "v1", commit, _date, dirty, version, "end", ..] => (*commit, *dirty == "1", *version),
        _ => ("", false, env!("CARGO_PKG_VERSION")),
    };
    if commit.len() < 7 {
        return format!("baneyspaces {version}");
    }
    format!("baneyspaces {version} ({}{})", &commit[..7], if dirty { "-dirty" } else { "" })
}

fn main() {
    if matches!(std::env::args().nth(1).as_deref(), Some("--version" | "-V" | "version")) {
        println!("{}", version_line(BUILD_STAMP));
        return;
    }
    let (globals, args) = split_globals(std::env::args().skip(1).collect());
    let text = globals.text;
    let agent = globals
        .agent
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
                // `--binary PATH` renders the include with an absolute path to the binary (install.sh).
                let bin = args.iter().position(|a| a == "--binary").and_then(|i| args.get(i + 1)).map(String::as_str).unwrap_or("baneyspaces");
                print!("{}", keymap::render_hypr_lua(bin));
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
                let mut env = daemon::call(&paths, &req);
                // With no daemon the workspace keys must still work: fall back to what Hyprland does.
                if env.error.as_ref().is_some_and(|e| e.code == "daemon_down") {
                    let agent_shell = std::env::var("BANEYSPACES_AGENT_TOKEN").is_ok();
                    if let Some(fb) = guarded_fallback(&req, agent_shell, fallback) {
                        env = fb;
                    }
                }
                print(&env, text)
            }
            Err(e) => print(&e, text),
        },
    };
    std::process::exit(code);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_version_line_carries_the_commit_from_the_stamp() {
        let sha = "0123456789abcdef0123456789abcdef01234567";
        let stamp = |dirty: u8| format!("polycarp-build|v1|{sha}|2026-11-10T00:00:00Z|{dirty}|0.1.0|end|");
        assert_eq!(version_line(&stamp(0)), "baneyspaces 0.1.0 (0123456)");
        assert_eq!(version_line(&stamp(1)), "baneyspaces 0.1.0 (0123456-dirty)");
        // Built outside a checkout: no commit, so the version alone.
        assert_eq!(version_line("polycarp-build|v1|||0|0.1.0|end|"), "baneyspaces 0.1.0");
        assert_eq!(version_line("garbage"), format!("baneyspaces {}", env!("CARGO_PKG_VERSION")));
        // The stamp this binary carries is in the shape `polycarp version` looks for.
        assert!(BUILD_STAMP.starts_with("polycarp-build|v1|") && BUILD_STAMP.ends_with("|end|"), "{BUILD_STAMP}");
        assert_eq!(BUILD_STAMP.split('|').count(), 8, "{BUILD_STAMP}");
    }

    fn v(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn typed_text_keeps_a_window_flag_in_it() {
        let req = request(v(&["agent", "type", "@sab:e3", "--window", "x"])).unwrap();
        assert_eq!(req["args"]["text"], "--window x");
        assert!(req["args"].get("window").is_none());
        let req = request(v(&["agent", "set-value", "@sab:e1", "see", "--window", "docs"])).unwrap();
        assert_eq!(req["args"]["value"], "see --window docs");
        let req = request(v(&["agent", "snapshot", "--window", "0x1", "-i"])).unwrap();
        assert_eq!(req["args"]["window"], "0x1");
    }

    #[test]
    fn shot_takes_its_window_and_out_name() {
        let req = request(v(&["agent", "shot", "--window", "0x5da0", "--out", "page.png"])).unwrap();
        assert_eq!(req["op"], "hands");
        assert_eq!((req["args"]["verb"].as_str(), req["args"]["window"].as_str(), req["args"]["out"].as_str()), (Some("shot"), Some("0x5da0"), Some("page.png")));
        let req = request(v(&["agent", "shot", "--window", "0x1"])).unwrap();
        assert!(req["args"].get("out").is_none());
    }

    #[test]
    fn a_commands_own_text_flag_reaches_the_command() {
        let (g, rest) = split_globals(v(&["agent", "find", "--window", "0x1", "--text", "needle"]));
        assert!(!g.text);
        let req = request(rest).unwrap();
        assert_eq!(req["args"]["text"], "needle");
        assert_eq!(req["args"]["verb"], "find");
    }

    #[test]
    fn globals_are_taken_only_before_the_command() {
        let (g, rest) = split_globals(v(&["--text", "--agent-id", "claude", "ls"]));
        assert_eq!((g.text, g.agent.as_deref()), (true, Some("claude")));
        assert_eq!(rest, v(&["ls"]));
        let (g, rest) = split_globals(v(&["--agent-id=x", "state"]));
        assert_eq!(g.agent.as_deref(), Some("x"));
        assert_eq!(rest, v(&["state"]));
        let (g, rest) = split_globals(v(&["agent", "open", "app", "--text", "--agent-id", "y"]));
        assert_eq!(g, Globals::default());
        assert_eq!(rest.len(), 6, "application arguments are kept verbatim");
    }

    #[test]
    fn an_agents_shell_never_gets_the_fallback() {
        let req = json!({"op":"switch","args":{"n":"3"}});
        let ran = std::cell::Cell::new(false);
        let probe = |_: &Value| {
            ran.set(true);
            Some(Envelope::ok(json!({})))
        };
        let e = guarded_fallback(&req, true, &probe).unwrap();
        assert_eq!(e.error.unwrap().code, "not_in_scope");
        assert!(!ran.get(), "the Hyprland dispatch must not run for an agent's shell");
        let e = guarded_fallback(&json!({"op":"move","args":{"n":"5"}}), true, &probe).unwrap();
        assert_eq!(e.error.unwrap().code, "not_in_scope");
        // Your own shell still falls back.
        assert!(guarded_fallback(&req, false, &probe).unwrap().ok);
        assert!(ran.get());
    }

    #[test]
    fn the_agent_workspace_verbs_parse_to_the_macs_argument_names() {
        let req = request(v(&["agent", "workspaces"])).unwrap();
        assert_eq!(req["op"], "agent_workspaces");
        let req = request(v(&["agent", "arrange", "halves", "0xa1", "0xa2", "--session", "s1"])).unwrap();
        assert_eq!(req, json!({ "op": "agent_arrange", "args": { "layout": "halves", "windows": ["0xa1", "0xa2"], "session": "s1" } }));
        let req = request(v(&["agent", "arrange", "frames", "0xa1=0,0,800,600", "--session", "s1"])).unwrap();
        assert_eq!(req["args"]["windows"], json!(["0xa1=0,0,800,600"]));
        let req = request(v(&["agent", "move", "--window", "0xa1", "--frame", "0,0,800,600", "--session", "s1"])).unwrap();
        assert_eq!(req, json!({ "op": "agent_move_window", "args": { "window": "0xa1", "frame": "0,0,800,600", "session": "s1" } }));
        let req = request(v(&["agent", "close", "--window", "0xa1", "--session", "s1"])).unwrap();
        assert_eq!(req, json!({ "op": "agent_close", "args": { "window": "0xa1", "session": "s1" } }));
        assert!(request(v(&["agent", "close", "0xa1"])).is_err(), "close names its window with --window, as on the Mac");
        assert!(request(v(&["agent", "move", "--window", "0xa1", "extra"])).is_err());
        let req = request(v(&["agent", "open", "foot", "--new_window=false", "--wait", "3", "--session", "s1"])).unwrap();
        assert_eq!(req, json!({ "op": "agent_open", "args": { "app": "foot", "args": [], "session": "s1", "new_window": false, "wait": 3 } }));
        let req = request(v(&["agent", "open", "mpv", "clip.mp4", "--new-window", "--session", "s1"])).unwrap();
        assert_eq!((req["args"]["args"].clone(), req["args"]["new_window"].clone()), (json!(["clip.mp4"]), json!(true)));
        assert!(request(v(&["agent", "open", "foot", "--wait", "soon"])).is_err());
    }

    #[test]
    fn agent_move_with_a_window_flag_is_the_agents_verb_and_without_it_yours() {
        let mine = request(v(&["agent", "move", "0xc1"])).unwrap();
        assert_eq!(mine, json!({ "op": "agent_move", "args": { "window": "0xc1" } }), "yours: parks a window (refused to agents)");
        let agents = request(v(&["agent", "move", "--window", "0xa1", "--session", "s"])).unwrap();
        assert_eq!(agents["op"], "agent_move_window");
    }

    #[test]
    fn the_session_is_the_flag_then_the_environment_then_the_terminal() {
        let mut a = v(&["x", "--session", "flag"]);
        assert_eq!(session_of(&mut a, Some("env".into()), Some("/dev/pts/3".into())), "flag");
        assert_eq!(a, v(&["x"]));
        assert_eq!(session_of(&mut v(&[]), Some("env".into()), Some("/dev/pts/3".into())), "env");
        assert_eq!(session_of(&mut v(&[]), Some(String::new()), Some("/dev/pts/3".into())), "/dev/pts/3");
        assert_eq!(session_of(&mut v(&[]), None, None), "default");
    }

    #[test]
    fn an_mcp_open_is_always_this_servers_session() {
        let r = mcp_tool_to_request("agent_open", &json!({ "app": "foot", "session": "someone-else" }), "a");
        assert_eq!(r["args"]["session"], format!("mcp:{}", std::process::id()));
    }

    #[test]
    fn the_fallback_knows_switch_and_move_and_nothing_else() {
        assert!(fallback(&json!({"op":"ls","args":{}})).is_none());
        assert!(fallback(&json!({"op":"switch","args":{"n":"10"}})).is_none());
        assert!(fallback(&json!({"op":"move","args":{"n":"3","window":"0x1; evil"}})).is_none());
    }
}
