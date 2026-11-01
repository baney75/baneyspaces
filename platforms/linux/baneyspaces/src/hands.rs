//! Agent hands: agent-desktop's Linux adapter (AT-SPI), reached through the engine binary built
//! from the pinned commit (platforms/linux/engine.pin), behind BaneySpaces' scope guard.
//!
//! The engine never decides what an agent may touch. Before every call the daemon checks, by pid
//! and by window, that the target is on the agent workspace and belongs to a process BaneySpaces
//! started for an agent; refs are tied to the snapshot, window and process they came from; and
//! the engine is only ever run headless (no `--headed`), so it posts no global input.

use crate::daemon::{append_record, now, record, Core, Shared};
use crate::proc;
use crate::scheme::AGENT_SPECIAL;
use baneyspaces_core::agent::{check_scope, ActionRecord, WindowFacts};
use baneyspaces_core::envelope::{Envelope, Retry};
use serde_json::{json, Value};
use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// One hands call (listing windows, the action, the read-back) gets this long in all. The client
/// waits `daemon::CLIENT_TIMEOUT_SECS`, well over it, so the daemon's answer always arrives first.
pub const BUDGET_SECS: u64 = 50;

#[derive(Clone, Debug)]
pub struct SnapInfo {
    pub window: String,
    pub pid: u32,
    pub start: u64,
}

/// Finds the pinned engine: `$BANEYSPACES_ENGINE`, `engine/` beside the binary or in the source
/// tree, or `~/.local/share/baneyspaces/engine/`.
pub fn locate() -> Option<PathBuf> {
    let mut c: Vec<PathBuf> = vec![];
    if let Ok(p) = std::env::var("BANEYSPACES_ENGINE") {
        c.push(p.into());
    }
    if let Ok(exe) = std::env::current_exe() {
        for up in exe.ancestors().skip(1).take(5) {
            c.push(up.join("engine/agent-desktop"));
            c.push(up.join("platforms/linux/engine/agent-desktop"));
        }
    }
    if let Ok(h) = std::env::var("HOME") {
        c.push(std::path::Path::new(&h).join(".local/share/baneyspaces/engine/agent-desktop"));
    }
    c.into_iter().find(|p| p.is_file())
}

/// The snapshot id inside a ref: `@s8f3k2p9:e8` -> `s8f3k2p9`.
pub fn snapshot_of(reference: &str) -> Option<&str> {
    let rest = reference.strip_prefix('@')?;
    let (snap, el) = rest.split_once(':')?;
    let ok_snap =
        snap.starts_with('s') && snap.len() > 1 && snap.bytes().all(|b| b.is_ascii_alphanumeric());
    let ok_el = el
        .strip_prefix('e')
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()));
    (ok_snap && ok_el).then_some(snap)
}

/// What the user can see, so a result can say whether it changed while an action ran. The pointer
/// is left out: the user moves it all the time, and an agent's call never has to.
fn screen_state(c: &Core) -> Value {
    let mons: Vec<Value> = c
        .monitors()
        .iter()
        .map(|m| json!({ "n": m.name, "ws": m.ws_id, "special": m.special, "focused": m.focused }))
        .collect();
    json!({
        "monitors": mons,
        "active": c.hypr.json("activewindow").ok().and_then(|v| v["address"].as_str().map(String::from)),
    })
}

fn engine_code(code: &str) -> &'static str {
    match code {
        "ELEMENT_NOT_FOUND" | "APP_NOT_FOUND" | "WINDOW_NOT_FOUND" | "NOTIFICATION_NOT_FOUND" => {
            "not_found"
        }
        "STALE_REF" | "SNAPSHOT_NOT_FOUND" => "stale_ref",
        "AMBIGUOUS_TARGET" => "ambiguous",
        "POLICY_DENIED" | "ACTION_NOT_SUPPORTED" | "PLATFORM_NOT_SUPPORTED" => "not_supported",
        "APP_UNRESPONSIVE" | "TIMEOUT" => "timeout",
        "INVALID_ARGS" => "invalid_args",
        _ => "engine_error",
    }
}

/// The engine's envelope as ours. Action results carry the engine's own evidence, unembellished:
/// `verified` is true only when the engine read the result back from the element it targeted.
pub fn map_engine(verb: &str, resp: &Value) -> Envelope {
    if resp["ok"] == json!(true) {
        let data = resp["data"].clone();
        let mut out = json!({ "result": data });
        if !matches!(verb, "snapshot" | "find" | "get" | "shot") {
            let delivery = data["disposition"]["delivery"]
                .as_str()
                .unwrap_or("unknown");
            let routes: Vec<&str> = data["steps"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|s| s["mechanism"].as_str())
                .collect();
            out["evidence"] = json!({
                "delivery": delivery,
                "verified": delivery == "delivered_verified",
                "route": routes,
                "readback": data["details"].get("verification_scope").cloned().unwrap_or(Value::Null),
                "post_state": data.get("post_state").cloned().unwrap_or(Value::Null),
            });
        }
        return Envelope::ok(out);
    }
    let e = &resp["error"];
    let ecode = e["code"].as_str().unwrap_or("INTERNAL");
    let code = engine_code(ecode);
    let retry = match (e["disposition"]["retry"].as_str(), code) {
        (_, "stale_ref") | (_, "ambiguous") => Retry::AfterSnapshot,
        (Some("safe"), _) => Retry::Safe,
        _ => Retry::Never,
    };
    let sug = e["suggestion"]
        .as_str()
        .unwrap_or("Take a new snapshot and try again.");
    Envelope::err(
        code,
        format!(
            "[{ecode}] {}",
            e["message"].as_str().unwrap_or("the engine failed")
        ),
        retry,
        sug,
    )
}

/// True when an argument is the engine's headed switch (which allows focus and pointer input).
fn refuses_headed(args: &[String]) -> bool {
    // Only options count: after `--` everything is the user's text.
    args.iter().take_while(|a| a.as_str() != "--").any(|a| a == "--headed" || a.starts_with("--headed="))
}

/// Runs the engine with a hard timeout. No `--headed`, ever.
fn run_engine(
    engine: &std::path::Path,
    args: &[String],
    timeout: Duration,
) -> Result<Value, Envelope> {
    // The engine is only ever run headless. This is a refusal at run time, not a debug check.
    if refuses_headed(args) {
        return Err(Envelope::err("not_supported", "BaneySpaces never runs the engine headed", Retry::Never, "Agents act through the accessibility API only."));
    }
    let mut child = Command::new(engine)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| {
            Envelope::err(
                "engine_error",
                format!("cannot start the engine: {e}"),
                Retry::Safe,
                "Rebuild it: platforms/linux/scripts/build-engine.sh",
            )
        })?;
    let mut stdout = child.stdout.take();
    let reader = std::thread::spawn(move || {
        let mut s = String::new();
        if let Some(o) = stdout.as_mut() {
            let _ = o.take(32 << 20).read_to_string(&mut s);
        }
        s
    });
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Envelope::err(
                    "timeout",
                    "the engine did not answer in time",
                    Retry::Never,
                    "The app may be busy. Take a new snapshot before trying again.",
                ));
            }
        }
    }
    let out = reader.join().unwrap_or_default();
    serde_json::from_str(out.trim()).map_err(|_| {
        Envelope::err(
            "engine_error",
            "the engine printed something that is not JSON",
            Retry::Never,
            "",
        )
    })
}

/// Which engine window is this Hyprland window: same pid, same title, same process start.
fn engine_window(
    engine: &std::path::Path,
    pid: u32,
    title: &str,
    start: u64,
    timeout: Duration,
) -> Result<String, Envelope> {
    let r = run_engine(engine, &["list-windows".into()], timeout)?;
    let all = r["data"].as_array().cloned().unwrap_or_default();
    let mine: Vec<&Value> = all
        .iter()
        .filter(|w| w["pid"].as_u64() == Some(pid as u64))
        .collect();
    let by_title: Vec<&&Value> = mine
        .iter()
        .filter(|w| w["title"].as_str() == Some(title))
        .collect();
    let pick: Vec<&Value> = if by_title.len() == 1 {
        vec![**by_title.first().unwrap()]
    } else {
        mine.clone()
    };
    match pick.as_slice() {
        [] => Err(Envelope::err(
            "not_found",
            "the app has not exposed this window to accessibility (yet)",
            Retry::Safe,
            "Wait a moment and try again. Some apps need GTK_A11Y=atspi.",
        )),
        [w] => {
            // process_instance is "<boot id>:<start ticks>": a second, independent pid-reuse check.
            let inst = w["process_instance"].as_str().unwrap_or("");
            if let Some(ticks) = inst.rsplit(':').next().and_then(|t| t.parse::<u64>().ok()) {
                if start != 0 && ticks != start {
                    return Err(Envelope::err(
                        "stale_ref",
                        "the accessibility tree belongs to a different process than the window",
                        Retry::AfterSnapshot,
                        "Take a new snapshot.",
                    ));
                }
            }
            w["id"].as_str().map(String::from).ok_or_else(|| {
                Envelope::err("engine_error", "window without an id", Retry::Never, "")
            })
        }
        many => Err(Envelope::err(
            "ambiguous",
            format!("{} windows of this process match", many.len()),
            Retry::Never,
            "Give the window a distinct title.",
        )),
    }
}

const DIRECTIONS: &[&str] = &["up", "down", "left", "right"];
const PROPERTIES: &[&str] = &["text", "value", "title", "bounds", "role", "states"];

/// The engine's command line for one verb. Option values are attached with `=` so a value that
/// starts with `--` is data, never another option; positional text goes after `--`.
pub fn build_argv(verb: &str, args: &Value, window: Option<&str>, reference: &str) -> Result<Vec<String>, Envelope> {
    let bad = |m: String| Envelope::err("invalid_args", m, Retry::Never, "Run `baneyspaces help`.");
    let text = |k: &str| args[k].as_str().map(String::from);
    let mut a: Vec<String> = vec![];
    match verb {
        "snapshot" | "find" | "shot" => {
            let w = window.ok_or_else(|| bad("a window is required".into()))?;
            a.push(if verb == "shot" { "screenshot".into() } else { verb.into() });
            a.push(format!("--window-id={w}"));
            if verb == "snapshot" {
                if args["interactive"].as_bool().unwrap_or(false) {
                    a.push("-i".into());
                }
                if args["compact"].as_bool().unwrap_or(false) {
                    a.push("--compact".into());
                }
            }
            if verb == "find" {
                for k in ["role", "name", "text"] {
                    if let Some(v) = text(k) {
                        a.push(format!("--{k}={v}"));
                    }
                }
            }
        }
        "get" => {
            let p = text("property").unwrap_or_else(|| "text".into());
            if !PROPERTIES.contains(&p.as_str()) {
                return Err(bad(format!("property must be one of {}", PROPERTIES.join(", "))));
            }
            a.extend(["get".into(), format!("--property={p}"), "--".into(), reference.into()]);
        }
        "click" | "toggle" => a.extend([verb.into(), "--".into(), reference.into()]),
        "set-value" | "select" => a.extend([verb.into(), "--".into(), reference.into(), text("value").unwrap_or_default()]),
        "type" => a.extend(["type".into(), "--".into(), reference.into(), text("text").unwrap_or_default()]),
        "scroll" => {
            let d = text("direction").unwrap_or_else(|| "down".into());
            if !DIRECTIONS.contains(&d.as_str()) {
                return Err(bad(format!("direction must be one of {}", DIRECTIONS.join(", "))));
            }
            a.push("scroll".into());
            a.push(format!("--direction={d}"));
            if let Some(n) = args["amount"].as_u64() {
                a.push(format!("--amount={n}"));
            }
            a.extend(["--".into(), reference.into()]);
        }
        _ => return Err(bad(format!("unknown verb {verb}"))),
    }
    Ok(a)
}

struct Plan {
    window: String,
    pid: u32,
    start: u64,
    title: String,
}

/// The scope guard, against the compositor's own view and the model's.
fn guard(c: &Core, window: &str, expect: Option<&SnapInfo>) -> Result<Plan, Envelope> {
    let Some(cl) = c.client(window) else {
        return Err(Envelope::err(
            "not_found",
            format!("no window {window}"),
            Retry::AfterSnapshot,
            "Run `baneyspaces agent status` for the agent workspace's windows.",
        ));
    };
    // Hyprland's word is final: the window must be on the agent workspace right now.
    if cl.ws_name != AGENT_SPECIAL {
        return Err(Envelope::err("not_in_scope", "that window is not on the agent workspace", Retry::Never, "Agents act only on windows on the agent workspace. Start the app with `baneyspaces agent open`."));
    }
    let start = proc::start_time(cl.pid).unwrap_or(0);
    if let Some(s) = expect {
        if s.pid != cl.pid || (s.start != 0 && s.start != start) {
            return Err(Envelope::err(
                "stale_ref",
                "the window now belongs to a different process than the snapshot",
                Retry::AfterSnapshot,
                "Take a new snapshot.",
            ));
        }
    }
    check_scope(
        &c.model,
        &WindowFacts {
            window: window.into(),
            pid: cl.pid,
            pid_start: start,
        },
    )
    .map_err(|r| r.envelope())?;
    Ok(Plan {
        window: window.into(),
        pid: cl.pid,
        start,
        title: cl.title,
    })
}

pub fn run(shared: &Shared, agent: &str, args: &Value) -> Envelope {
    let verb = args["verb"].as_str().unwrap_or("").to_string();
    let invalid =
        |m: &str| Envelope::err("invalid_args", m, Retry::Never, "Run `baneyspaces help`.");
    let Some(engine) = locate() else {
        return Envelope::err(
            "engine_missing",
            "the hands engine (agent-desktop, pinned) is not built",
            Retry::Never,
            "Run platforms/linux/scripts/build-engine.sh, or set BANEYSPACES_ENGINE.",
        );
    };
    let window_verb = matches!(verb.as_str(), "snapshot" | "find" | "shot");
    let ref_verb = matches!(
        verb.as_str(),
        "get" | "click" | "set-value" | "type" | "toggle" | "select" | "scroll"
    );
    if !window_verb && !ref_verb {
        return Envelope::err(
            "not_supported",
            format!("agent {verb} is not available on Linux in part 1"),
            Retry::Never,
            "Use snapshot, find, get, click, set-value, type, toggle, select, scroll or shot.",
        );
    }
    let s = |k: &str| args[k].as_str().map(String::from);
    let reference = s("ref");
    if let Some(r) = &reference {
        if snapshot_of(r).is_none() {
            return invalid("a ref looks like @s8f3k2p9:e8, from a snapshot");
        }
    }

    // 1. Guard, under the lock.
    let (plan, before) = {
        let c = crate::daemon::lock(shared);
        let r = if window_verb {
            match s("window") {
                Some(w) => guard(&c, &w, None),
                None => Err(invalid(
                    "--window <id> is required (see `baneyspaces agent status`)",
                )),
            }
        } else {
            let sid = snapshot_of(reference.as_deref().unwrap_or(""))
                .unwrap_or("")
                .to_string();
            match c.snaps.get(&sid).cloned() {
                None => Err(Envelope::err(
                    "stale_ref",
                    "this ref is not from a snapshot BaneySpaces took",
                    Retry::AfterSnapshot,
                    "Take a snapshot with `baneyspaces agent snapshot` and use its refs.",
                )),
                Some(info) => guard(&c, &info.window, Some(&info)),
            }
        };
        match r {
            Ok(p) => {
                let b = screen_state(&c);
                (p, b)
            }
            Err(env) => {
                record(
                    &c,
                    agent,
                    &verb,
                    None,
                    s("window").as_deref(),
                    reference.as_deref(),
                    "atspi",
                    &env,
                );
                return env;
            }
        }
    };

    // 2. The engine, without the lock, inside one budget.
    let budget = Instant::now() + Duration::from_secs(BUDGET_SECS);
    let left = || budget.saturating_duration_since(Instant::now()).max(Duration::from_millis(500));
    let win_id = if window_verb {
        match engine_window(&engine, plan.pid, &plan.title, plan.start, left().min(Duration::from_secs(15))) {
            Ok(id) => Some(id),
            Err(env) => {
                let c = crate::daemon::lock(shared);
                record(&c, agent, &verb, Some(plan.pid), Some(&plan.window), None, "atspi", &env);
                return env;
            }
        }
    } else {
        None
    };
    let argv = match build_argv(&verb, args, win_id.as_deref(), reference.as_deref().unwrap_or("")) {
        Ok(a) => a,
        Err(env) => {
            let c = crate::daemon::lock(shared);
            record(&c, agent, &verb, Some(plan.pid), Some(&plan.window), reference.as_deref(), "atspi", &env);
            return env;
        }
    };
    let t = left();
    let raw = run_engine(&engine, &argv, t);

    // 3. Read back, record, answer.
    let mut c = crate::daemon::lock(shared);
    let mut env = match raw {
        Ok(v) => map_engine(&verb, &v),
        Err(e) => e,
    };
    if env.ok && matches!(verb.as_str(), "snapshot" | "find") {
        let sid = env
            .data
            .as_ref()
            .and_then(|d| d["result"]["snapshot_id"].as_str())
            .map(String::from);
        if let Some(sid) = sid {
            if c.snaps.len() > 256 {
                c.snaps.clear();
            }
            c.snaps.insert(
                sid,
                SnapInfo {
                    window: plan.window.clone(),
                    pid: plan.pid,
                    start: plan.start,
                },
            );
        }
    }
    let after = screen_state(&c);
    let changed = after != before;
    // Still the same window and process after the action?
    let same = guard(&c, &plan.window, None).is_ok();
    if let Some(d) = env.data.as_mut() {
        d["screen_changed"] = json!(changed);
        d["window"] = json!(plan.window);
        d["pid"] = json!(plan.pid);
        if !same {
            d["scope_changed"] = json!(true);
        }
    }
    let mut rec = ActionRecord::from_result(
        now(),
        agent,
        &verb,
        Some(plan.pid),
        Some(&plan.window),
        reference.as_deref(),
        "atspi",
        &env,
    );
    // The outcome stays what it was; what changed on screen is its own field.
    rec.screen_changed = changed;
    append_record(&c, &rec);
    env
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refs_name_their_snapshot() {
        assert_eq!(snapshot_of("@s8f3k2p9:e8"), Some("s8f3k2p9"));
        for bad in [
            "@e8",
            "s8f3:e1",
            "@s:e1",
            "@s8f3k2p9:e",
            "@s8f3k2p9:8",
            "@s8-3:e1",
            "@s8f3k2p9:e8x",
            "",
        ] {
            assert_eq!(snapshot_of(bad), None, "{bad}");
        }
    }

    #[test]
    fn engine_errors_become_ours() {
        let e = map_engine(
            "click",
            &json!({"ok":false,"error":{"code":"STALE_REF","message":"gone","disposition":{"delivery":"not_delivered","retry":"safe"}}}),
        );
        let er = e.error.unwrap();
        assert_eq!(
            (er.code.as_str(), er.retry),
            ("stale_ref", Retry::AfterSnapshot)
        );
        let e = map_engine(
            "click",
            &json!({"ok":false,"error":{"code":"ACTION_NOT_SUPPORTED","message":"no","disposition":{"delivery":"not_delivered","retry":"safe"}}}),
        );
        assert_eq!(e.error.as_ref().unwrap().code, "not_supported");
        assert_eq!(e.error.unwrap().retry, Retry::Safe);
        let e = map_engine(
            "click",
            &json!({"ok":false,"error":{"code":"ACTION_FAILED","message":"x","disposition":{"delivery":"delivered_unverified","retry":"unsafe"}}}),
        );
        assert_eq!(e.error.unwrap().retry, Retry::Never);
        let e = map_engine(
            "shot",
            &json!({"ok":false,"error":{"code":"PLATFORM_NOT_SUPPORTED","message":"wayland"}}),
        );
        assert_eq!(e.error.unwrap().code, "not_supported");
    }

    #[test]
    fn evidence_is_verified_only_when_the_engine_read_it_back() {
        let unverified = map_engine(
            "click",
            &json!({"ok":true,"data":{"disposition":{"delivery":"delivered_unverified","retry":"unsafe"},"steps":[{"mechanism":"semantic_api"}]}}),
        );
        let ev = &unverified.data.unwrap()["evidence"];
        assert_eq!(ev["verified"], false);
        assert_eq!(ev["route"], json!(["semantic_api"]));
        let verified = map_engine(
            "set-value",
            &json!({"ok":true,"data":{"disposition":{"delivery":"delivered_verified","retry":"unsafe"},"details":{"verification_scope":"element_value"},"steps":[]}}),
        );
        let ev = &verified.data.unwrap()["evidence"];
        assert_eq!(
            (ev["verified"].clone(), ev["readback"].clone()),
            (json!(true), json!("element_value"))
        );
        // Reads and captures carry no evidence claim at all.
        assert!(map_engine("snapshot", &json!({"ok":true,"data":{}}))
            .data
            .unwrap()
            .get("evidence")
            .is_none());
        assert!(map_engine("shot", &json!({"ok":true,"data":{}}))
            .data
            .unwrap()
            .get("evidence")
            .is_none());
    }

    #[test]
    fn the_engine_is_never_run_headed_not_even_by_a_value() {
        assert!(refuses_headed(&["click".into(), "--headed".into()]));
        assert!(refuses_headed(&["--headed=true".into()]));
        // A value that looks like the flag is data, because options carry their values with `=`.
        let a = build_argv("find", &json!({"name":"--headed","role":"--headed"}), Some("w-1"), "").unwrap();
        assert!(!refuses_headed(&a), "{a:?}");
        assert!(a.contains(&"--name=--headed".to_string()));
        // And the check is a refusal at run time, before anything is spawned.
        let e = run_engine(std::path::Path::new("/nonexistent"), &["--headed".into()], Duration::from_secs(1)).unwrap_err();
        assert_eq!(e.error.unwrap().code, "not_supported");
    }

    #[test]
    fn scroll_direction_and_get_property_are_checked_here_not_trusted() {
        let bad = build_argv("scroll", &json!({"direction":"--headed"}), None, "@sa:e1").unwrap_err();
        assert_eq!(bad.error.unwrap().code, "invalid_args");
        assert!(build_argv("scroll", &json!({"direction":"left","amount":2}), None, "@sa:e1").unwrap().contains(&"--direction=left".to_string()));
        assert_eq!(build_argv("get", &json!({"property":"--headed"}), None, "@sa:e1").unwrap_err().error.unwrap().code, "invalid_args");
        let ok = build_argv("get", &json!({"property":"value"}), None, "@sa:e1").unwrap();
        assert_eq!(ok, ["get", "--property=value", "--", "@sa:e1"]);
    }

    #[test]
    fn values_that_start_with_dashes_stay_positional() {
        let a = build_argv("set-value", &json!({"value":"--headed"}), None, "@sa:e1").unwrap();
        assert_eq!(a, ["set-value", "--", "@sa:e1", "--headed"]);
        assert!(!refuses_headed(&a), "text after `--` is data, even when it spells the flag");
    }
}
