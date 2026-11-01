//! The configuration on Linux (`spec/config.md`): the daemon is the single writer, it applies each
//! change live, and it watches the file for hand edits.
//!
//! What a change does here:
//! - **keys**: regenerates `$XDG_STATE_HOME/baneyspaces/hyprland-keys.lua` (the include loads it on
//!   a reload) and re-runs it inside Hyprland, removing only the binds BaneySpaces made;
//! - **theme, animation**: written to `$XDG_RUNTIME_DIR/baneyspaces/config.json`, the one place the
//!   shell UI reads; the focus border's animation is also set in Hyprland;
//! - **behavior, rules**: given to the daemon's model (`Event::Settings`); hooks are kept here.
//!
//! The recovery chord is not here: the include binds it, and config can neither bind nor remove it.

use crate::daemon::{lock, Shared};
use crate::hypr::Hypr;
use crate::paths::Paths;
use crate::scheme::{lua_str, sh_quote};
use baneyspaces_core::action::Action;
use baneyspaces_core::chord::{Chord, Platform};
use baneyspaces_core::config::{self, Binding, Effective, Env};
use baneyspaces_core::config_schema::Issue;
use baneyspaces_core::config_store::{Applied, Service};
use baneyspaces_core::envelope::{Envelope, Retry};
use baneyspaces_core::history;
use baneyspaces_core::model::{Event, RuleSpec};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

// ---- the platform's side of the model --------------------------------------------------------

pub fn config_dir() -> PathBuf {
    let base = std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".into())).join(".config")
        });
    base.join("baneyspaces")
}

fn omarchy_path() -> PathBuf {
    PathBuf::from(std::env::var("OMARCHY_PATH").unwrap_or_else(|_| "/usr/share/omarchy".into()))
}

/// The live Omarchy palette, if this is an Omarchy seat with a current theme.
pub fn omarchy_palette() -> Option<Value> {
    let home = std::env::var("HOME").ok()?;
    let text =
        std::fs::read_to_string(Path::new(&home).join(".config/omarchy/current/theme/colors.toml"))
            .ok()?;
    let v: Value = toml::from_str(&text).ok()?;
    config::palette_from_omarchy(&v)
}

/// The system's Reduce Motion: GNOME's `enable-animations` setting, which GTK and Qt apps follow.
fn reduce_motion() -> bool {
    if std::env::var("BANEYSPACES_REDUCE_MOTION").is_ok_and(|v| v == "1") {
        return true;
    }
    std::process::Command::new("gsettings")
        .args(["get", "org.gnome.desktop.interface", "enable-animations"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .is_some_and(|o| String::from_utf8_lossy(&o.stdout).trim() == "false")
}

/// `light`: skip the slow probes (a CLI reset has no use for them).
pub fn make_env(light: bool) -> Env {
    let mut e = Env::new(Platform::Linux);
    e.omarchy = omarchy_path().exists();
    if !light {
        e.reduce_motion = reduce_motion();
    }
    e.palette_auto = if e.omarchy { omarchy_palette() } else { None };
    e
}

pub fn local_service(light: bool) -> Service {
    Service::new(config_dir(), make_env(light))
}

// ---- Hyprland ----------------------------------------------------------------------------------

/// Hyprland's name for a key.
pub fn hypr_key(key: &str) -> String {
    if key.len() == 1 && key.as_bytes()[0].is_ascii_digit() {
        // The digit row by keycode, as Omarchy binds it: layout independent. 1 is code 10.
        let d = key.as_bytes()[0] - b'0';
        return format!("code:{}", if d == 0 { 19 } else { 9 + d });
    }
    if key.len() == 1 {
        return key.to_uppercase();
    }
    match key {
        "escape" => "Escape".into(),
        "tab" => "Tab".into(),
        "return" => "Return".into(),
        "backspace" => "BackSpace".into(),
        "delete" => "Delete".into(),
        "insert" => "Insert".into(),
        "home" => "Home".into(),
        "end" => "End".into(),
        "pageup" => "Prior".into(),
        "pagedown" => "Next".into(),
        "up" => "Up".into(),
        "down" => "Down".into(),
        "left" => "Left".into(),
        "right" => "Right".into(),
        k if k.starts_with('f') && k[1..].chars().all(|c| c.is_ascii_digit()) => k.to_uppercase(),
        // space, grave, minus, equal, plus, brackets, backslash, semicolon, apostrophe, comma, period, slash
        k => k.to_string(),
    }
}

/// A chord as Hyprland spells it: `SUPER + SHIFT + code:10`.
pub fn hypr_chord(c: &Chord) -> String {
    let mut parts: Vec<String> = vec![];
    if c.logo {
        parts.push("SUPER".into());
    }
    if c.ctrl {
        parts.push("CTRL".into());
    }
    if c.shift {
        parts.push("SHIFT".into());
    }
        if c.alt {
        parts.push("ALT".into());
    }
parts.push(hypr_key(&c.key));
    parts.join(" + ")
}

fn plain(w: &str) -> bool {
    !w.is_empty()
        && w.chars()
            .all(|c| c.is_ascii_alphanumeric() || "_@%+=:,./-".contains(c))
}

fn dispatcher(b: &Binding, binary: &str) -> String {
    match &b.action {
        Action::Cli(w) => {
            let words: Vec<String> = w
                .iter()
                .map(|x| if plain(x) { x.clone() } else { sh_quote(x) })
                .collect();
            format!(
                "hl.dsp.exec_cmd({})",
                lua_str(&format!("{} {}", binary, words.join(" ")))
            )
        }
        Action::Exec(c) => format!("hl.dsp.exec_cmd({})", lua_str(c)),
        Action::Mode(m) if m == "default" => "hl.dsp.submap(\"reset\")".into(),
        Action::Mode(m) => format!("hl.dsp.submap({})", lua_str(m)),
        Action::None => "nil".into(),
    }
}

/// The Lua that binds `eff`'s keys, run by the include on a reload and by the daemon after a change.
/// Returns the text and how many binds it makes.
pub fn render_keys_lua(eff: &Effective, binary: &str) -> (String, usize) {
    let mut s = String::new();
    let mut count = 0;
    s.push_str("-- Generated by baneyspaces from config.toml. Do not edit: `baneyspaces config set keys.bindings.\"mod+h\" \"exec foot\"` changes it.\n");
    // Hyprland 0.56.2 crashes when more than one bind is removed through its handle, so the global
    // binds are taken out by key (hl.unbind) and the mode binds are only disabled.
    s.push_str("if __baneyspaces_keys then\n  for _, k in ipairs(__baneyspaces_keys) do pcall(hl.unbind, k) end\nend\n");
    s.push_str("if __baneyspaces_mode_binds then\n  for _, b in ipairs(__baneyspaces_mode_binds) do pcall(function() b:set_enabled(false) end) end\nend\n");
    s.push_str("__baneyspaces_keys = {}\n__baneyspaces_mode_binds = {}\n__baneyspaces_errors = 0\n");
    s.push_str("local in_mode = false\n");
    s.push_str("local function bind(keys, dsp, desc)\n  local ok, b = pcall(hl.bind, keys, dsp, { description = desc })\n  if not (ok and b) then __baneyspaces_errors = __baneyspaces_errors + 1 elseif in_mode then table.insert(__baneyspaces_mode_binds, b) else table.insert(__baneyspaces_keys, keys) end\nend\n");
    s.push_str(
        "-- A chord of yours takes the key from whatever else bound it (Omarchy's own bindings).\n",
    );
    let mut seen: Vec<String> = vec![];
    for b in &eff.bindings {
        let k = hypr_chord(&b.chord);
        if !seen.contains(&k) {
            s.push_str(&format!("pcall(hl.unbind, {})\n", lua_str(&k)));
            seen.push(k);
        }
    }
    for b in &eff.bindings {
        s.push_str(&format!(
            "bind({}, {}, {})\n",
            lua_str(&hypr_chord(&b.chord)),
            dispatcher(b, binary),
            lua_str(&format!(
                "BaneySpaces: {}",
                baneyspaces_core::action::describe(&b.action, &b.text)
            ))
        ));
        count += 1;
    }
    for (name, bs) in &eff.modes {
        s.push_str(&format!(
            "hl.define_submap({}, \"reset\", function()\n  in_mode = true\n",
            lua_str(name)
        ));
        for b in bs {
            s.push_str(&format!(
                "  bind({}, {}, {})\n",
                lua_str(&hypr_chord(&b.chord)),
                dispatcher(b, binary),
                lua_str(&format!(
                    "BaneySpaces ({name}): {}",
                    baneyspaces_core::action::describe(&b.action, &b.text)
                ))
            ));
            count += 1;
        }
        // The recovery chord works inside a mode too.
        s.push_str("  if __baneyspaces_recovery then __baneyspaces_recovery(bind) end\n");
        s.push_str("  in_mode = false\nend)\n");
    }
    (s, count)
}

/// The focus border's animation as Hyprland takes it.
fn border_lua(resolved: &Value) -> String {
    let b = &resolved["resolved"]["animation"]["border"];
    let ms = b["duration_ms"].as_u64().unwrap_or(0);
    if ms == 0 || b["instant"] == true {
        return "hl.animation({ leaf = \"border\", enabled = false })".into();
    }
    let p = match b["curve"].as_str() {
        Some("bezier") => b["points"]
            .as_array()
            .map(|a| a.iter().filter_map(Value::as_f64).collect::<Vec<_>>())
            .filter(|v| v.len() == 4)
            .unwrap_or_else(|| vec![0.23, 1.0, 0.32, 1.0]),
        Some("linear") => vec![0.0, 0.0, 1.0, 1.0],
        // A spring has no Hyprland equivalent; its settle time on the easeOutQuint curve is the closest.
        _ => vec![0.23, 1.0, 0.32, 1.0],
    };
    format!(
        "hl.curve(\"baneyspaces_border\", {{ type = \"bezier\", points = {{ {{ {}, {} }}, {{ {}, {} }} }} }})\nhl.animation({{ leaf = \"border\", enabled = true, speed = {}, bezier = \"baneyspaces_border\" }})",
        p[0], p[1], p[2], p[3], (ms as f64 / 100.0)
    )
}

// ---- applying ----------------------------------------------------------------------------------

pub fn keys_lua_path(paths: &Paths) -> PathBuf {
    paths.state.join("hyprland-keys.lua")
}

pub fn runtime_json_path(paths: &Paths) -> PathBuf {
    paths.run.join("config.json")
}

/// Writes what the UIs read, and the keys file.
pub fn write_outputs(paths: &Paths, svc: &Service, eff: &Effective) -> Result<usize, String> {
    let rt = svc.runtime_json();
    history::write_atomic(
        &runtime_json_path(paths),
        serde_json::to_string_pretty(&rt)
            .unwrap_or_default()
            .as_bytes(),
    )
    .map_err(|e| format!("cannot write config.json: {e}"))?;
    let binary = std::env::current_exe()
        .ok()
        .and_then(|p| p.to_str().map(String::from))
        .unwrap_or_else(|| "baneyspaces".into());
    let (lua, count) = render_keys_lua(eff, &binary);
    history::write_atomic(&keys_lua_path(paths), lua.as_bytes())
        .map_err(|e| format!("cannot write the keys file: {e}"))?;
    Ok(count)
}

/// Re-runs the keys file and the border animation inside Hyprland. The result says what happened.
pub fn apply_to_hyprland(hypr: &Hypr, paths: &Paths, resolved: &Value, expected: usize) -> Value {
    let mut live = json!({});
    let keys = hypr.eval(&format!(
        "dofile({})",
        lua_str(&keys_lua_path(paths).display().to_string())
    ));
    live["keys"] = match keys {
        Ok(()) => {
            let bound = hypr.json("binds").ok().and_then(|v| {
                v.as_array().map(|a| {
                    a.iter()
                        .filter(|b| {
                            b["description"]
                                .as_str()
                                .is_some_and(|d| d.starts_with("BaneySpaces"))
                        })
                        .count()
                })
            });
            match bound {
                // The recovery chord is one more bind than the config's, plus one per mode.
                Some(n) if n >= expected => json!("applied"),
                Some(n) => json!(format!("Hyprland has {n} BaneySpaces binds, expected {expected}; see `hyprctl configerrors`")),
                None => json!("applied (could not read the binds back)"),
            }
        }
        Err(e) => json!(format!("Hyprland refused the keys: {e}")),
    };
    live["border"] = match hypr.eval(&border_lua(resolved)) {
        Ok(()) => json!("applied"),
        Err(e) => json!(format!("Hyprland refused the border animation: {e}")),
    };
    live
}

/// Everything a change does outside the model, for the daemon or for a local fallback.
pub fn apply_outputs(paths: &Paths, hypr: Option<&Hypr>, svc: &Service, a: &Applied) -> Value {
    let count = match write_outputs(paths, svc, &a.effective) {
        Ok(c) => c,
        Err(e) => return json!({ "error": e }),
    };
    match hypr {
        Some(h) => apply_to_hyprland(h, paths, &a.resolved, count),
        None => json!({ "keys": "written (no Hyprland to apply to)" }),
    }
}

// ---- the daemon's runtime ----------------------------------------------------------------------

pub struct Runtime {
    pub svc: Mutex<Service>,
    pub paths: Paths,
    pub hypr: Option<Hypr>,
    pub hooks: Mutex<(String, String)>,
    /// Test only: counts applies.
    pub applies: std::sync::atomic::AtomicU64,
}

static RT: OnceLock<Runtime> = OnceLock::new();

pub fn runtime() -> Option<&'static Runtime> {
    RT.get()
}

fn log_line(paths: &Paths, v: Value) {
    paths.append("config.log", &v.to_string());
}

fn rules_of(doc: &Value) -> Vec<RuleSpec> {
    doc["rules"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|r| serde_json::from_value(r.clone()).ok())
                .collect()
        })
        .unwrap_or_default()
}

impl Runtime {
    /// Gives the model the behavior settings and keeps the hooks.
    fn apply_behavior(&self, shared: &Shared, eff: &Effective) {
        let ev = Event::Settings {
            follow_focus: eff.doc["behavior"]["follow_focus"].as_bool(),
            new_window: eff.doc["behavior"]["new_window"].as_str().map(String::from),
            rules: Some(rules_of(&eff.doc)),
        };
        let mut c = lock(shared);
        if let Err(e) = c.model.apply(ev) {
            eprintln!("baneyspaces daemon: behavior not applied: {e}");
        }
        *self.hooks.lock().unwrap_or_else(|p| p.into_inner()) = (
            eff.doc["hooks"]["on_switch"].as_str().unwrap_or("").into(),
            eff.doc["hooks"]["on_window_open"]
                .as_str()
                .unwrap_or("")
                .into(),
        );
    }

    /// Applies an effective config everywhere. `svc` is already locked by the caller.
    pub fn apply(&self, shared: &Shared, svc: &Service, a: &Applied) -> Value {
        self.applies
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            self.apply_behavior(shared, &a.effective);
            apply_outputs(&self.paths, self.hypr.as_ref(), svc, a)
    }

    /// Applies what is running now (at start, and after a Hyprland reload).
    pub fn apply_current(&self, shared: &Shared) -> Value {
        let svc = self.svc.lock().unwrap_or_else(|p| p.into_inner());
        let (eff, resolved, _) = svc.current();
        let a = Applied {
            changed: false,
            version: None,
            summary: "current".into(),
            changes: vec![],
            warnings: vec![],
            effective: eff,
            resolved,
        };
        self.apply(shared, &svc, &a)
    }
}

/// Starts the config side of the daemon: loads, applies and starts the watcher.
pub fn start(shared: &Shared, paths: &Paths, hypr: Option<Hypr>) {
    let svc = local_service(false);
    let _ = std::fs::create_dir_all(svc.themes_dir());
    let rt = Runtime {
        svc: Mutex::new(svc),
        paths: paths.clone(),
        hypr,
        hooks: Mutex::new((String::new(), String::new())),
        applies: 0.into(),
    };
    if RT.set(rt).is_err() {
        return;
    }
    let rt = runtime().expect("just set");
    // A file found on disk with no history yet is recorded as it is.
    {
        let svc = rt.svc.lock().unwrap_or_else(|p| p.into_inner());
        let _ = svc.observe();
    }
    let live = rt.apply_current(shared);
    log_line(
        paths,
        json!({ "time": history::now_rfc3339(), "event": "start", "live": live }),
    );
    let shared = shared.clone();
    std::thread::spawn(move || watch(shared));
}

/// Re-applies after a Hyprland reload (the include has just re-run) or an Omarchy theme change.
pub fn reload(shared: &Shared) {
    if let Some(rt) = runtime() {
        // The Omarchy palette may have changed with the reload.
        rt.svc
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .env
            .palette_auto = if omarchy_path().exists() {
            omarchy_palette()
        } else {
            None
        };
        rt.apply_current(shared);
    }
}

fn caller_for(shared: &Shared, req: &Value, peer: Option<u32>) -> String {
    let c = lock(shared);
    let from_peer = match peer {
        None => Some("unknown".to_string()),
        Some(p) => c.peer_agent(p),
    };
    if let Some(a) = from_peer {
        return history::agent_caller(&a);
    }
    if req["via"] == "mcp" || req["declared"] == true {
        return history::agent_caller(req["agent"].as_str().unwrap_or("agent"));
    }
    if req["as"] == "settings" {
        return "settings".into();
    }
    "user".into()
}

/// A `config_*` or `theme_*` request.
pub fn handle(shared: &Shared, op: &str, args: &Value, req: &Value, peer: Option<u32>) -> Envelope {
    let Some(rt) = runtime() else {
        return Envelope::err(
            "daemon_down",
            "the config service is not ready",
            Retry::After,
            "Try again in a moment.",
        );
    };
    let caller = caller_for(shared, req, peer);
    let svc = rt.svc.lock().unwrap_or_else(|p| p.into_inner());
    let out = svc.dispatch(op, args, &caller);
    let mut env = out.env;
    if let Some(a) = out.applied {
        let live = rt.apply(shared, &svc, &a);
            if let Some(d) = env.data.as_mut() {
            d["live"] = live.clone();
        }
        log_line(
            &rt.paths,
            json!({ "time": history::now_rfc3339(), "caller": caller, "op": op, "summary": a.summary, "version": a.version, "live": live }),
        );
    } else if !env.ok {
        log_line(
            &rt.paths,
            json!({ "time": history::now_rfc3339(), "caller": caller, "op": op, "refused": env.error.as_ref().map(|e| e.code.clone()) }),
        );
    }
    env
}

// ---- the file watcher --------------------------------------------------------------------------

fn watch(shared: Shared) {
    let Some(rt) = runtime() else { return };
    let dir = config_dir();
    let themes = dir.join("themes");
    let _ = std::fs::create_dir_all(&themes);
    // SAFETY: plain syscalls on descriptors this function owns.
    let fd = unsafe { libc::inotify_init1(libc::IN_CLOEXEC) };
    if fd < 0 {
        eprintln!("baneyspaces daemon: cannot watch the config (inotify unavailable)");
        return;
    }
    let mask = (libc::IN_CLOSE_WRITE
        | libc::IN_MOVED_TO
        | libc::IN_CREATE
        | libc::IN_DELETE
        | libc::IN_MOVED_FROM) as u32;
    for d in [&dir, &themes] {
        let Ok(c) = std::ffi::CString::new(d.as_os_str().as_encoded_bytes()) else {
            continue;
        };
        // SAFETY: `c` is a valid C string for the call.
        unsafe { libc::inotify_add_watch(fd, c.as_ptr(), mask) };
    }
    let mut buf = [0u8; 4096];
    loop {
        // SAFETY: `buf` is valid for its length.
        let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
        if n <= 0 {
            std::thread::sleep(std::time::Duration::from_millis(500));
            continue;
        }
        let mut relevant = false;
        let mut off = 0usize;
        let n = n as usize;
        while off + 16 <= n {
            let len =
                u32::from_ne_bytes(buf[off + 12..off + 16].try_into().unwrap_or([0; 4])) as usize;
            let name = buf[off + 16..(off + 16 + len).min(n)]
                .split(|b| *b == 0)
                .next()
                .unwrap_or(&[]);
            let name = String::from_utf8_lossy(name);
            if name == "config.toml" || name.ends_with(".toml") {
                relevant = true;
            }
            off += 16 + len;
        }
        if !relevant {
            continue;
        }
        // Let an editor finish (write, rename, chmod) and fold the burst into one look.
        std::thread::sleep(std::time::Duration::from_millis(120));
        // SAFETY: setting O_NONBLOCK on our own descriptor to drain the burst.
        unsafe {
            let fl = libc::fcntl(fd, libc::F_GETFL);
            libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK);
            while libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) > 0 {}
            libc::fcntl(fd, libc::F_SETFL, fl);
        }
        let svc = rt.svc.lock().unwrap_or_else(|p| p.into_inner());
        match svc.observe() {
            Ok(Some(a)) => {
                let live = rt.apply(&shared, &svc, &a);
                log_line(
                    &rt.paths,
                    json!({ "time": history::now_rfc3339(), "caller": "user", "op": "edit", "summary": a.summary, "version": a.version, "live": live }),
                );
            }
            Ok(None) => {
                // Our own write, or nothing that matters; make sure the status file is current.
                let _ = history::write_atomic(
                    &runtime_json_path(&rt.paths),
                    serde_json::to_string_pretty(&svc.runtime_json())
                        .unwrap_or_default()
                        .as_bytes(),
                );
            }
            Err(issues) => {
                // The last good config keeps running; the status file and the log say why not the file.
                let _ = history::write_atomic(
                    &runtime_json_path(&rt.paths),
                    serde_json::to_string_pretty(&svc.runtime_json())
                        .unwrap_or_default()
                        .as_bytes(),
                );
                log_line(
                    &rt.paths,
                    json!({ "time": history::now_rfc3339(), "caller": "user", "op": "edit", "refused": "config_invalid", "issues": issues.iter().map(Issue::to_json).collect::<Vec<_>>() }),
                );
                eprintln!("baneyspaces daemon: config.toml is invalid; the last good config keeps running: {}: {}", issues[0].path, issues[0].reason);
            }
        }
    }
}

// ---- hooks -------------------------------------------------------------------------------------

/// Runs a hook command as the user, detached, logged. `which` is `on_switch` or `on_window_open`.
pub fn fire_hook(which: &'static str, env: Vec<(&'static str, String)>) {
    let Some(rt) = runtime() else { return };
    let cmd = {
        let h = rt.hooks.lock().unwrap_or_else(|p| p.into_inner());
        if which == "on_switch" {
            h.0.clone()
        } else {
            h.1.clone()
        }
    };
    if cmd.trim().is_empty() {
        return;
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let cmd = if let Some(rest) = cmd.strip_prefix("~/") {
        format!("{home}/{rest}")
    } else {
        cmd
    };
    log_line(
        &rt.paths,
        json!({ "time": history::now_rfc3339(), "hook": which, "command": cmd }),
    );
    let mut p = std::process::Command::new("sh");
    p.arg("-c")
        .arg(&cmd)
        .env("BANEYSPACES_HOOK", which)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    // The hook is not an agent and does not carry one's token.
    p.env_remove("BANEYSPACES_AGENT_TOKEN");
    for (k, v) in env {
        p.env(k, v);
    }
    if let Ok(mut child) = p.spawn() {
        std::thread::spawn(move || {
            let _ = child.wait();
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use baneyspaces_core::config::Themes;

    fn eff(doc: Value) -> Effective {
        config::validate(&doc, &Env::new(Platform::Linux), &Themes::new())
            .effective
            .expect("valid")
    }

    #[test]
    fn keys_are_spelled_the_way_hyprland_wants() {
        let c = |s: &str| hypr_chord(&baneyspaces_core::chord::parse(s, "super").unwrap());
        assert_eq!(c("mod+3"), "SUPER + code:12");
        assert_eq!(c("mod+shift+alt+9"), "SUPER + SHIFT + ALT + code:18");
        assert_eq!(c("mod+0"), "SUPER + code:19");
        assert_eq!(c("mod+tab"), "SUPER + Tab");
        assert_eq!(c("ctrl+alt+pageup"), "CTRL + ALT + Prior");
        assert_eq!(c("mod+r"), "SUPER + R");
        assert_eq!(c("mod+f12"), "SUPER + F12");
        assert_eq!(c("mod+grave"), "SUPER + grave");
    }

    #[test]
    fn the_default_keys_render_to_the_include_that_ships() {
        let e = eff(json!({}));
        let (lua, n) = render_keys_lua(&e, "/bin/baneyspaces");
        assert_eq!(n, 29);
        assert!(lua.contains("bind(\"SUPER + code:12\", hl.dsp.exec_cmd(\"/bin/baneyspaces switch 3\"), \"BaneySpaces: workspace 3\")"), "{lua}");
        assert!(lua.contains("\"BaneySpaces: send window to workspace 4, stay here\""));
        assert!(lua.contains("hl.dsp.exec_cmd(\"/bin/baneyspaces agent-workspace toggle\")"));
    }

    #[test]
    fn modes_become_submaps_that_keep_the_recovery_chord() {
        let e = eff(
            json!({ "keys": { "bindings": { "mod+r": "mode resize", "mod+return": "exec foot --title 'a b'" }, "modes": { "resize": { "h": "window resize -40 0" } } } }),
        );
        let (lua, _) = render_keys_lua(&e, "/bin/bs");
        assert!(lua.contains("hl.dsp.submap(\"resize\")"));
        assert!(lua.contains("hl.define_submap(\"resize\", \"reset\", function()"));
        assert!(lua.contains("bind(\"Escape\", hl.dsp.submap(\"reset\")"));
        assert!(lua.contains("__baneyspaces_recovery(bind)"));
        assert!(lua.contains("hl.dsp.exec_cmd(\"foot --title 'a b'\")"));
        assert!(lua.contains("hl.dsp.exec_cmd(\"/bin/bs window resize -40 0\")"));
    }

    #[test]
    fn the_recovery_chord_is_never_in_the_generated_keys() {
        let e = eff(json!({}));
        let (lua, _) = render_keys_lua(&e, "bs");
        assert!(!lua.to_lowercase().contains("super + shift + escape"));
        assert!(!lua.contains("unbind, \"SUPER + SHIFT + Escape\""));
    }

    #[test]
    fn an_action_with_quotes_is_quoted_for_the_shell() {
        let e = eff(
            json!({ "keys": { "bindings": { "mod+x": "agent run -- sh -c \"echo hi there\"" } } }),
        );
        let (lua, _) = render_keys_lua(&e, "bs");
        assert!(
            lua.contains("bs agent run -- sh -c 'echo hi there'"),
            "{lua}"
        );
    }

    #[test]
    fn the_border_follows_the_preset() {
        let env = Env::new(Platform::Linux);
        let v = config::validate(
            &json!({ "animation": { "preset": "omarchy" } }),
            &env,
            &Themes::new(),
        )
        .effective
        .unwrap();
        let r = config::resolved_json(&v, &env, &Themes::new());
        let l = border_lua(&r);
        assert!(
            l.contains("speed = 5.39") && l.contains("{ 0.23, 1 }"),
            "{l}"
        );
        let v = config::validate(
            &json!({ "animation": { "preset": "off" } }),
            &env,
            &Themes::new(),
        )
        .effective
        .unwrap();
        assert!(border_lua(&config::resolved_json(&v, &env, &Themes::new()))
            .contains("enabled = false"));
    }
}
