//! The hands engine: vercel-labs/agent-desktop's Windows adapter (UI Automation), built from the
//! pinned commit (platforms/linux/engine.pin, the same one macOS and Linux use) by
//! `platforms/windows/scripts/build-engine.ps1`.
//!
//! The engine never decides what an agent may touch: the daemon checks scope first, by pid and by
//! window. It is only ever run headless (never `--headed`), so it sends no physical input: no
//! `SendInput`, no cursor move, no cursor overlay. Everything here is portable and tested anywhere.

use baneyspaces_core::envelope::{Envelope, Retry};
use serde_json::{json, Value};
use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Finds the pinned engine: `$BANEYSPACES_ENGINE`, `engine\` beside the binary or in the source
/// tree, or `%LOCALAPPDATA%\BaneySpaces\engine\`.
pub fn locate() -> Option<PathBuf> {
    let name = if cfg!(windows) { "agent-desktop.exe" } else { "agent-desktop" };
    let mut c: Vec<PathBuf> = vec![];
    if let Ok(p) = std::env::var("BANEYSPACES_ENGINE") {
        c.push(p.into());
    }
    if let Ok(exe) = std::env::current_exe() {
        for up in exe.ancestors().skip(1).take(5) {
            c.push(up.join("engine").join(name));
            c.push(up.join("platforms/windows/engine").join(name));
        }
    }
    if let Ok(h) = std::env::var("LOCALAPPDATA") {
        c.push(std::path::Path::new(&h).join("BaneySpaces/engine").join(name));
    }
    c.into_iter().find(|p| p.is_file())
}

/// The snapshot id inside a ref: `@s8f3k2p9:e8` -> `s8f3k2p9`.
pub fn snapshot_of(reference: &str) -> Option<&str> {
    let rest = reference.strip_prefix('@')?;
    let (snap, el) = rest.split_once(':')?;
    let ok_snap = snap.starts_with('s') && snap.len() > 1 && snap.bytes().all(|b| b.is_ascii_alphanumeric());
    let ok_el = el.strip_prefix('e').is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()));
    (ok_snap && ok_el).then_some(snap)
}

fn engine_code(code: &str) -> &'static str {
    match code {
        "ELEMENT_NOT_FOUND" | "APP_NOT_FOUND" | "WINDOW_NOT_FOUND" | "NOTIFICATION_NOT_FOUND" => "not_found",
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
            let delivery = data["disposition"]["delivery"].as_str().unwrap_or("unknown");
            let routes: Vec<&str> = data["steps"].as_array().into_iter().flatten().filter_map(|s| s["mechanism"].as_str()).collect();
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
    // Retry rule (spec/envelope.md): a call that failed without the engine saying it is safe is
    // never retried, because the action may already have landed.
    let retry = match (e["disposition"]["retry"].as_str(), code) {
        (_, "stale_ref") | (_, "ambiguous") => Retry::AfterSnapshot,
        (Some("safe"), _) => Retry::Safe,
        _ => Retry::Never,
    };
    let sug = e["suggestion"].as_str().unwrap_or("Take a new snapshot and try again.");
    Envelope::err(code, format!("[{ecode}] {}", e["message"].as_str().unwrap_or("the engine failed")), retry, sug)
}

/// Runs the engine with a hard timeout. No `--headed`, ever. A timeout is `retry: never`: the
/// engine did not say "safe", so the action may have landed.
pub fn run_engine(engine: &std::path::Path, args: &[String], timeout: Duration) -> Result<Value, Envelope> {
    debug_assert!(!args.iter().any(|a| a == "--headed"));
    let mut cmd = Command::new(engine);
    cmd.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    // The engine keeps its snapshots in a private directory it insists this user owns, so give it
    // one of ours rather than a shared default another (elevated) process may have created.
    let home = crate::paths::Paths::from_env().state.join("engine-state");
    let _ = std::fs::create_dir_all(&home);
    cmd.env("AGENT_DESKTOP_HOME", &home);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW: no console flash on the user's screen
    }
    let mut child = cmd.spawn().map_err(|e| {
        Envelope::err("engine_error", format!("cannot start the engine: {e}"), Retry::Safe, "Rebuild it: platforms/windows/scripts/build-engine.ps1")
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
                return Err(Envelope::err("timeout", "the engine did not answer in time", Retry::Never, "The app may be busy. Take a new snapshot before trying again."));
            }
        }
    }
    let out = reader.join().unwrap_or_default();
    serde_json::from_str(out.trim()).map_err(|_| Envelope::err("engine_error", "the engine printed something that is not JSON", Retry::Never, ""))
}

/// The engine command line for a window verb (`snapshot`, `find`, `shot`).
pub fn window_argv(verb: &str, window_id: &str, args: &Value) -> Vec<String> {
    let s = |k: &str| args[k].as_str().map(String::from);
    let mut argv: Vec<String> = match verb {
        "snapshot" => vec!["snapshot".into(), "--window-id".into(), window_id.into()],
        "find" => vec!["find".into(), "--window-id".into(), window_id.into()],
        _ => vec!["screenshot".into(), "--window-id".into(), window_id.into()],
    };
    match verb {
        "snapshot" => {
            if args["interactive"].as_bool().unwrap_or(false) {
                argv.push("-i".into());
            }
            if args["compact"].as_bool().unwrap_or(false) {
                argv.push("--compact".into());
            }
        }
        "find" => {
            for k in ["role", "name", "text"] {
                if let Some(v) = s(k) {
                    argv.extend([format!("--{k}"), v]);
                }
            }
        }
        _ => {}
    }
    argv
}

/// The engine command line for a ref verb. `type` is not here: the engine's `type` is keystroke
/// synthesis (`SendInput`) and needs `--headed`, so BaneySpaces never calls it. See [`type_value`].
pub fn ref_argv(verb: &str, args: &Value) -> Vec<String> {
    let s = |k: &str| args[k].as_str().map(String::from);
    let r = s("ref").unwrap_or_default();
    match verb {
        "get" => vec!["get".into(), r, "--property".into(), s("property").unwrap_or_else(|| "text".into())],
        "click" | "toggle" => vec![verb.into(), r],
        "set-value" | "select" => vec![verb.into(), "--".into(), r, s("value").unwrap_or_default()],
        _ => {
            let mut v = vec!["scroll".into(), r, "--direction".into(), s("direction").unwrap_or_else(|| "down".into())];
            if let Some(n) = args["amount"].as_u64() {
                v.extend(["--amount".into(), n.to_string()]);
            }
            v
        }
    }
}

/// `agent type` on Windows: insert text through UI Automation, with no key events. UI Automation
/// has no "insert at the caret", so the field's current value is read and the field is set to that
/// value plus the text (an append). The engine reads the result back, so `verified` is honest.
pub fn type_value(current: &Value, text: &str) -> Option<String> {
    let cur = &current["data"];
    let prior = ["value", "text"].iter().find_map(|k| cur[k].as_str().map(String::from)).or_else(|| cur.as_str().map(String::from))?;
    Some(format!("{prior}{text}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refs_name_their_snapshot() {
        assert_eq!(snapshot_of("@s8f3k2p9:e8"), Some("s8f3k2p9"));
        for bad in ["@e8", "s8f3:e1", "@s:e1", "@s8f3k2p9:e", "@s8f3k2p9:8", "@s8-3:e1", "@s8f3k2p9:e8x", ""] {
            assert_eq!(snapshot_of(bad), None, "{bad}");
        }
    }

    #[test]
    fn engine_errors_become_ours_and_only_safe_is_retried() {
        let e = map_engine("click", &json!({"ok":false,"error":{"code":"STALE_REF","message":"gone","disposition":{"delivery":"not_delivered","retry":"safe"}}}));
        let er = e.error.unwrap();
        assert_eq!((er.code.as_str(), er.retry), ("stale_ref", Retry::AfterSnapshot));
        let e = map_engine("click", &json!({"ok":false,"error":{"code":"ACTION_NOT_SUPPORTED","message":"no","disposition":{"delivery":"not_delivered","retry":"safe"}}}));
        assert_eq!(e.error.as_ref().unwrap().code, "not_supported");
        assert_eq!(e.error.unwrap().retry, Retry::Safe);
        // The engine did not say "safe": never retry.
        for body in [
            json!({"ok":false,"error":{"code":"ACTION_FAILED","message":"x","disposition":{"delivery":"delivered_unverified","retry":"unsafe"}}}),
            json!({"ok":false,"error":{"code":"ACTION_FAILED","message":"x"}}),
        ] {
            assert_eq!(map_engine("click", &body).error.unwrap().retry, Retry::Never);
        }
        let e = map_engine("type", &json!({"ok":false,"error":{"code":"POLICY_DENIED","message":"headless"}}));
        assert_eq!(e.error.unwrap().code, "not_supported");
    }

    #[test]
    fn evidence_is_verified_only_when_the_engine_read_it_back() {
        let unverified = map_engine("click", &json!({"ok":true,"data":{"disposition":{"delivery":"delivered_unverified","retry":"unsafe"},"steps":[{"mechanism":"semantic_api"}]}}));
        let ev = &unverified.data.unwrap()["evidence"];
        assert_eq!(ev["verified"], false);
        assert_eq!(ev["route"], json!(["semantic_api"]));
        let verified = map_engine("set-value", &json!({"ok":true,"data":{"disposition":{"delivery":"delivered_verified","retry":"unsafe"},"details":{"verification_scope":"element_value"},"steps":[]}}));
        let ev = &verified.data.unwrap()["evidence"];
        assert_eq!((ev["verified"].clone(), ev["readback"].clone()), (json!(true), json!("element_value")));
        assert!(map_engine("snapshot", &json!({"ok":true,"data":{}})).data.unwrap().get("evidence").is_none());
    }

    #[test]
    fn the_engine_is_never_run_headed_and_never_asked_to_type_with_keys() {
        let src = include_str!("engine.rs");
        let flag = ["--", "headed"].concat();
        for pat in [format!("\"{flag}\".into()"), format!("\"{flag}\".to_string()"), format!("format!(\"{flag}")] {
            assert!(!src.contains(&pat), "{pat}");
        }
        // No verb the engine would send as physical input is ever built.
        for verb in ["click", "toggle", "set-value", "select", "get", "scroll"] {
            let argv = ref_argv(verb, &json!({"ref":"@sab:e1","value":"v","property":"text"}));
            assert!(!argv.iter().any(|a| matches!(a.as_str(), "type" | "press" | "key" | "mouse-click" | "mouse-move" | "drag" | "hover" | "double-click" | "right-click" | "focus" | "focus-window")), "{verb}: {argv:?}");
        }
    }

    #[test]
    fn type_appends_to_the_current_value() {
        assert_eq!(type_value(&json!({"data":{"value":"ab"}}), "cd").as_deref(), Some("abcd"));
        assert_eq!(type_value(&json!({"data":{"text":""}}), "x").as_deref(), Some("x"));
        assert_eq!(type_value(&json!({"data":"hi "}), "x").as_deref(), Some("hi x"));
        assert_eq!(type_value(&json!({"data":{}}), "x"), None);
    }

    #[test]
    fn argv_for_each_verb() {
        assert_eq!(window_argv("snapshot", "w-1", &json!({"interactive":true,"compact":true})), ["snapshot", "--window-id", "w-1", "-i", "--compact"]);
        assert_eq!(window_argv("find", "w-1", &json!({"role":"button","name":"OK"})), ["find", "--window-id", "w-1", "--role", "button", "--name", "OK"]);
        assert_eq!(ref_argv("set-value", &json!({"ref":"@sa:e2","value":"v"})), ["set-value", "--", "@sa:e2", "v"]);
        assert_eq!(ref_argv("scroll", &json!({"ref":"@sa:e2","direction":"up","amount":4})), ["scroll", "@sa:e2", "--direction", "up", "--amount", "4"]);
    }
}
