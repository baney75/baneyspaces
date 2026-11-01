//! `baneyspaces daemon`: the model driven by Hyprland's events, the control socket the CLI talks
//! to, `state.json`, the agent workspace and the agent action log.

use crate::apps;
use crate::hands;
use crate::hypr::{parse_event, Hypr, HyprError, HyprEvent};
use crate::paths::Paths;
use crate::proc;
use crate::scheme::{decode, lua_str, sh_quote, AGENT_SPECIAL, AGENT_SPECIAL_NAME};
use baneyspaces_core::agent::{prune_text, ActionRecord, PRUNE_EVERY_SECS};
use baneyspaces_core::envelope::{Envelope, Retry};
use baneyspaces_core::model::{Cause, Effect, Event, Home, Model, ModelError};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct Client {
    pub addr: String,
    pub pid: u32,
    pub ws_id: i64,
    pub ws_name: String,
    pub monitor: i64,
    pub class: String,
    pub title: String,
    pub mapped: bool,
}

#[derive(Clone, Debug)]
pub struct Mon {
    pub id: i64,
    pub name: String,
    pub focused: bool,
    pub ws_id: i64,
    pub ws_name: String,
    pub special: String,
    pub disabled: bool,
}

pub struct TokenInfo {
    pub agent: String,
    pub app: String,
    pub at: u64,
}

pub struct Core {
    pub model: Model,
    pub hypr: Hypr,
    pub paths: Paths,
    pub tokens: HashMap<String, TokenInfo>,
    /// token -> pids registered through it
    pub token_pids: HashMap<String, Vec<u32>>,
    /// snapshot id -> the window and process it was taken of
    pub snaps: HashMap<String, hands::SnapInfo>,
    pub overview_shown: bool,
    pub events_seen: u64,
    pub started: u64,
    pub trace: bool,
    /// The model may disagree with the compositor (a dispatch failed and a re-read did not work).
    pub dirty: bool,
    pub last_prune: std::cell::Cell<u64>,
    /// `BANEYSPACES_TEST_OPS=1`: lets nested.sh fake a reused pid and a failing dispatch.
    pub test_ops: bool,
    pub fail_next: Option<bool>,
    pub resyncing: bool,
}

pub type Shared = Arc<Mutex<Core>>;

/// Why a command could not be carried out.
#[derive(Debug)]
pub enum ApplyError {
    /// The rules refused it.
    Model(ModelError),
    /// The rules accepted it but Hyprland refused or did not answer. `delivered_any`: an earlier
    /// step of the same command went through.
    Compositor { err: HyprError, delivered_any: bool },
}

impl ApplyError {
    pub fn envelope(&self) -> Envelope {
        match self {
            ApplyError::Model(e) => Envelope::from_model(e),
            ApplyError::Compositor { err, delivered_any } => {
                // Only a clean refusal before anything moved is safe to repeat.
                let retry = if err.uncertain() || *delivered_any { Retry::Never } else { Retry::Safe };
                Envelope::err(
                    "compositor_error",
                    format!("Hyprland did not carry it out: {err}"),
                    retry,
                    "BaneySpaces re-read Hyprland's state. Look at `baneyspaces state` before trying again.",
                )
                .with_data(json!({ "uncertain": err.uncertain(), "earlier_steps_went_through": delivered_any }))
            }
        }
    }
}

pub fn lock(s: &Shared) -> MutexGuard<'_, Core> {
    s.lock().unwrap_or_else(|p| p.into_inner())
}

impl Core {
    pub fn monitors(&self) -> Vec<Mon> {
        let Ok(v) = self.hypr.json("monitors") else {
            return vec![];
        };
        v.as_array()
            .map(|a| {
                a.iter()
                    .map(|m| Mon {
                        id: m["id"].as_i64().unwrap_or(-1),
                        name: m["name"].as_str().unwrap_or("").into(),
                        focused: m["focused"].as_bool().unwrap_or(false),
                        ws_id: m["activeWorkspace"]["id"].as_i64().unwrap_or(0),
                        ws_name: m["activeWorkspace"]["name"].as_str().unwrap_or("").into(),
                        special: m["specialWorkspace"]["name"].as_str().unwrap_or("").into(),
                        disabled: m["disabled"].as_bool().unwrap_or(false),
                    })
                    .filter(|m| !m.disabled)
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn clients(&self) -> Vec<Client> {
        let Ok(v) = self.hypr.json("clients") else {
            return vec![];
        };
        v.as_array()
            .map(|a| {
                a.iter()
                    .map(|c| Client {
                        addr: c["address"].as_str().unwrap_or("").into(),
                        pid: c["pid"].as_u64().unwrap_or(0) as u32,
                        ws_id: c["workspace"]["id"].as_i64().unwrap_or(0),
                        ws_name: c["workspace"]["name"].as_str().unwrap_or("").into(),
                        monitor: c["monitor"].as_i64().unwrap_or(-1),
                        class: c["class"].as_str().unwrap_or("").into(),
                        title: c["title"].as_str().unwrap_or("").into(),
                        mapped: c["mapped"].as_bool().unwrap_or(true),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn client(&self, addr: &str) -> Option<Client> {
        self.clients().into_iter().find(|c| c.addr == addr)
    }

    fn special_shown(&self) -> bool {
        self.monitors().iter().any(|m| m.special == AGENT_SPECIAL)
    }

    fn log(&self, msg: &str) {
        if self.trace {
            eprintln!("[baneyspaces] {msg}");
        }
    }

    // ---- Hyprland setup ------------------------------------------------------------------

    /// Turns workspace animations off, stops apps taking focus by asking, and gives a display that
    /// shows nothing of ours a workspace. Run at start and after every config reload.
    pub fn configure_hyprland(&self) {
        let _ = self.hypr.eval("hl.animation({ leaf = \"workspaces\", enabled = false })");
        let _ = self.hypr.eval("hl.animation({ leaf = \"specialWorkspace\", enabled = false })");
        let _ = self.hypr.eval("hl.config({ misc = { focus_on_activate = false } })");
        self.adopt_monitors();
    }

    /// A display showing an empty, non-persistent workspace that is not one of the nine (the
    /// default Hyprland gives a new monitor) shows the workspace the model picked for it (R-M2).
    /// A display showing anything you keep (workspace 10 with the work dashboard) is left alone.
    fn adopt_monitors(&self) {
        let Ok(spaces) = self.hypr.json("workspaces") else { return };
        let spaces = spaces.as_array().cloned().unwrap_or_default();
        let before = self.monitors().into_iter().find(|m| m.focused).map(|m| m.name);
        let mut moved = false;
        for m in self.monitors() {
            if decode(m.ws_id, &m.ws_name).is_some() {
                continue;
            }
            let Some(n) = self.model.current(&m.name).filter(|n| *n != 0) else { continue };
            let Some(ws) = spaces.iter().find(|w| w["id"].as_i64() == Some(m.ws_id)) else { continue };
            if ws["windows"].as_u64().unwrap_or(1) != 0 || ws["ispersistent"].as_bool().unwrap_or(true) {
                continue;
            }
            let _ = self.show_workspace(&m.name, n);
            moved = true;
        }
        if let (true, Some(b)) = (moved, before) {
            let _ = self.hypr.dispatch(&format!("hl.dsp.focus({{ monitor = {} }})", lua_str(&b)));
        }
    }

    /// Makes `monitor` show workspace `n`: brings the workspace there if Hyprland keeps it on
    /// another monitor, then focuses it. Leaves focus on `monitor`; callers put it back.
    fn show_workspace(&self, monitor: &str, n: u8) -> Result<(), HyprError> {
        let lives = self.hypr.json("workspaces").ok().and_then(|v| v.as_array().and_then(|a| a.iter().find(|w| w["id"].as_i64() == Some(n as i64)).and_then(|w| w["monitor"].as_str().map(String::from))));
        if self.monitors().iter().find(|m| m.focused).is_some_and(|m| m.name != monitor) {
            self.hypr.dispatch(&format!("hl.dsp.focus({{ monitor = {} }})", lua_str(monitor)))?;
        }
        if lives.is_some_and(|on| on != monitor) {
            self.hypr.dispatch(&format!("hl.dsp.workspace.move({{ workspace = {}, monitor = {} }})", lua_str(&n.to_string()), lua_str(monitor)))?;
        }
        self.hypr.dispatch(&format!("hl.dsp.focus({{ workspace = {} }})", lua_str(&n.to_string())))
    }

    // ---- model plumbing ------------------------------------------------------------------

    pub fn apply(&mut self, ev: Event) -> Result<Vec<Effect>, ApplyError> {
        self.events_seen += 1;
        let effects = self.model.apply(ev).map_err(ApplyError::Model)?;
        let r = self.exec(&effects);
        self.persist();
        if let (Err((err, delivered_any)), false) = (r, self.resyncing) {
            // The model has committed a state the compositor may not have reached. Re-read it
            // before anything else is accepted.
            self.log(&format!("dispatch failed ({err}); re-reading Hyprland"));
            self.resync();
            self.dirty = self.monitors().is_empty();
            return Err(ApplyError::Compositor { err, delivered_any });
        }
        Ok(effects)
    }

    /// Before a command: if the last failure left the model unsure, learn the compositor's state first.
    pub fn ensure_fresh(&mut self) {
        if self.dirty {
            self.resync();
            self.dirty = self.monitors().is_empty();
        }
    }

    /// Carries out effects. Every one is idempotent: Hyprland may already be there. A failure stops
    /// the list and says whether any earlier effect went through.
    fn exec(&mut self, effects: &[Effect]) -> Result<(), (HyprError, bool)> {
        if !effects.is_empty() {
            if let Some(io) = self.fail_next.take() {
                let m = "test: injected failure".to_string();
                return Err((if io { HyprError::Io(m) } else { HyprError::Refused(m) }, false));
            }
        }
        for (i, e) in effects.iter().enumerate() {
            self.log(&format!("effect {e:?}"));
            let r = match e {
                Effect::ShowWorkspace { monitor, workspace } => self.show_workspace(monitor, *workspace),
                Effect::FocusMonitor { monitor } => self.hypr.dispatch(&format!("hl.dsp.focus({{ monitor = {} }})", lua_str(monitor))),
                Effect::FocusWindow { window } => self.hypr.dispatch(&format!("hl.dsp.focus({{ window = {} }})", lua_str(&format!("address:{window}")))),
                Effect::MoveWindow { window, to } => {
                    let dest = if to == "agent" { Some(AGENT_SPECIAL.to_string()) } else { to.parse::<u8>().ok().map(|n| n.to_string()) };
                    match dest {
                        Some(d) => self.hypr.dispatch(&format!("hl.dsp.window.move({{ workspace = {}, follow = false, window = {} }})", lua_str(&d), lua_str(&format!("address:{window}")))),
                        None => Ok(()),
                    }
                }
                Effect::ShowAgent => {
                    if self.special_shown() { Ok(()) } else { self.hypr.dispatch(&format!("hl.dsp.workspace.toggle_special({})", lua_str(AGENT_SPECIAL_NAME))) }
                }
                Effect::HideAgent => {
                    if self.special_shown() { self.hypr.dispatch(&format!("hl.dsp.workspace.toggle_special({})", lua_str(AGENT_SPECIAL_NAME))) } else { Ok(()) }
                }
                Effect::RefuseFollow { .. } => Ok(()),
            };
            if let Err(err) = r {
                self.log(&format!("effect failed: {err}"));
                return Err((err, i > 0));
            }
        }
        // A switch on a monitor you are not on must not take you there.
        if let Some(want) = self.model.focused_monitor().map(String::from) {
            if self.monitors().iter().find(|m| m.focused).is_some_and(|m| m.name != want) {
                self.hypr.dispatch(&format!("hl.dsp.focus({{ monitor = {} }})", lua_str(&want))).map_err(|e| (e, true))?;
            }
        }
        Ok(())
    }

    pub fn persist(&self) {
        let mut v = self.model.view();
        v["version"] = json!(1);
        v["platform"] = json!("linux");
        v["agent_workspace"] = json!(AGENT_SPECIAL);
        v["scheme"] = json!("one pool: workspace n is hyprland workspace n (1-9); agent: special:agent");
        v["overview"] = json!({ "shown": self.overview_shown });
        v["daemon"] = json!({ "pid": std::process::id(), "started": self.started, "events": self.events_seen });
        self.paths.write_atomic(
            "state.json",
            &serde_json::to_string_pretty(&v).unwrap_or_default(),
        );
        let procs: Vec<Value> = self
            .model
            .agent_pids()
            .into_iter()
            .map(|(p, s)| json!({ "pid": p, "start": s }))
            .collect();
        self.paths
            .write_atomic("agents.json", &json!(procs).to_string());
    }

    /// Drops every registered agent process that has died or whose pid now belongs to another
    /// program (its start time changed), so a reused pid is never mistaken for an agent.
    pub fn reconcile_agents(&mut self) {
        for (pid, start) in self.model.agent_pids() {
            let live = proc::start_time(pid);
            if live.is_none() || (start != 0 && live != Some(start)) {
                self.log(&format!("agent process {pid} is gone or was reused; forgetting it"));
                let _ = self.apply(Event::AgentExit { pid });
                for v in self.token_pids.values_mut() {
                    v.retain(|p| *p != pid);
                }
            }
        }
    }

    /// Registers `pid` as an agent process if it carries a launch token we issued. A registration
    /// whose start time no longer matches is dropped first.
    fn adopt_agent_pid(&mut self, pid: u32) -> bool {
        let live = proc::start_time(pid);
        if let Some(start) = self.model.agent_proc(pid) {
            if self.model.is_agent_pid(pid, live.unwrap_or(0)) && live.is_some() {
                let _ = start;
                return true;
            }
            let _ = self.apply(Event::AgentExit { pid });
        }
        let Some(tok) = proc::token_of(pid) else {
            return false;
        };
        if !self.tokens.contains_key(&tok) {
            return false;
        }
        let start = live.unwrap_or(0);
        self.token_pids.entry(tok).or_default().push(pid);
        let _ = self.apply(Event::AgentRegister { pid, start });
        true
    }

    /// A window Hyprland reports: classify and feed the model. `existing` windows (found at
    /// start, or arriving from outside the scheme) are mirrored exactly where they are; a new
    /// window follows the placement rules.
    pub fn open_client(&mut self, c: &Client, existing: bool) {
        if !c.mapped || self.model.is_tracked(&c.addr) {
            return;
        }
        let on_agent = c.ws_name == AGENT_SPECIAL;
        let n = if on_agent { None } else { decode(c.ws_id, &c.ws_name) };
        if !on_agent && n.is_none() {
            return; // outside the scheme: not ours
        }
        self.reconcile_agents();
        self.adopt_agent_pid(c.pid);
        let start = proc::start_time(c.pid).unwrap_or(0);
        if existing {
            let ev = Event::ObserveWindow { window: c.addr.clone(), pid: c.pid, start, app: c.class.clone(), workspace: n };
            let _ = self.apply(ev);
            return;
        }
        let monitor = self.monitors().into_iter().find(|m| m.id == c.monitor).map(|m| m.name);
        let _ = self.apply(Event::Open { window: c.addr.clone(), pid: c.pid, start, app: c.class.clone(), monitor, workspace: n });
        if on_agent && !matches!(self.model.home(&c.addr), Some(Home::Agent)) {
            let _ = self.apply(Event::AgentSend { window: c.addr.clone() });
        }
    }

    /// Rebuilds the model from Hyprland. Effects are not carried out: this only learns.
    pub fn resync(&mut self) {
        self.resyncing = true;
        self.model = Model::new();
        let mut mons = self.monitors();
        let order = self.paths.read("monitors.json").and_then(|t| serde_json::from_str::<Vec<String>>(&t).ok()).unwrap_or_default();
        mons.sort_by_key(|m| (order.iter().position(|o| *o == m.name).unwrap_or(usize::MAX), m.id));
        for m in &mons {
            let _ = self.model.apply(Event::MonitorAdded { monitor: m.name.clone() });
        }
        self.paths.write_atomic("monitors.json", &json!(mons.iter().map(|m| m.name.clone()).collect::<Vec<_>>()).to_string());
        self.configure_hyprland();
        self.observe_monitors(false);
        for (pid, start) in self
            .paths
            .read("agents.json")
            .and_then(|t| serde_json::from_str::<Vec<Value>>(&t).ok())
            .unwrap_or_default()
            .iter()
            .filter_map(|v| Some((v["pid"].as_u64()? as u32, v["start"].as_u64()?)))
        {
            if proc::start_time(pid) == Some(start) {
                let _ = self.model.apply(Event::AgentRegister { pid, start });
            }
        }
        self.load_tokens();
        for c in self.clients() {
            self.open_client(&c, true);
        }
        if self.special_shown() {
            let _ = self.model.apply(Event::AgentShow);
        }
        if let Ok(v) = self.hypr.json("activewindow") {
            if let Some(a) = v["address"].as_str() {
                let _ = self.model.apply(Event::Activate { window: Some(a.into()), cause: Cause::User });
            }
        }
        self.resyncing = false;
        self.persist();
    }

    /// The launch tokens we issued, kept (0600) so a restart still knows the terminal an agent is
    /// running in. A token with no live process and older than a minute is dropped.
    pub fn save_tokens(&self) {
        let m: serde_json::Map<String, Value> = self.tokens.iter().map(|(t, i)| (t.clone(), json!({ "agent": i.agent, "app": i.app, "at": i.at }))).collect();
        self.paths.write_atomic("tokens.json", &Value::Object(m).to_string());
    }

    fn load_tokens(&mut self) {
        let Some(Value::Object(m)) = self.paths.read("tokens.json").and_then(|t| serde_json::from_str::<Value>(&t).ok()) else { return };
        for (tok, v) in m {
            let at = v["at"].as_u64().unwrap_or(0);
            if now().saturating_sub(at) > 60 && proc::pids_with_token(&tok).is_empty() {
                continue;
            }
            self.tokens.entry(tok).or_insert(TokenInfo { agent: v["agent"].as_str().unwrap_or("agent").into(), app: v["app"].as_str().unwrap_or("").into(), at });
        }
        self.save_tokens();
    }

    /// R-F2 on Linux rests on `misc:focus_on_activate = false`: with it, an app asking for focus
    /// never gets it, so every activation the daemon sees is yours. Hyprland can lose the setting
    /// (a config reload, a stray eval), so it is read back and put back.
    pub fn ensure_focus_setting(&self) {
        let on = self.hypr.json("getoption misc:focus_on_activate").ok().is_some_and(|v| v["int"].as_i64() == Some(1) || v["bool"].as_bool() == Some(true));
        if on {
            self.log("misc:focus_on_activate was on; turning it off again");
            let _ = self.hypr.eval("hl.config({ misc = { focus_on_activate = false } })");
        }
    }

    /// Whether the include is still installed: Some(false) when hyprland.lua exists and no longer
    /// mentions BaneySpaces.
    pub fn include_installed() -> Option<bool> {
        let home = std::env::var("HOME").ok()?;
        let text = std::fs::read_to_string(std::path::Path::new(&home).join(".config/hypr/hyprland.lua")).ok()?;
        Some(text.contains(">>> baneyspaces") || text.contains("baneyspaces/baneyspaces.lua"))
    }

    /// Mirrors what each display shows and which display has focus.
    fn observe_monitors(&mut self, with_effects: bool) {
        let mons = self.monitors();
        for m in &mons {
            let n = decode(m.ws_id, &m.ws_name).unwrap_or(0);
            if self.model.current(&m.name) != Some(n) {
                let ev = Event::ObserveWorkspace { monitor: m.name.clone(), n };
                if with_effects { let _ = self.apply(ev); } else { let _ = self.model.apply(ev); }
            }
        }
        if let Some(f) = mons.iter().find(|m| m.focused) {
            if self.model.focused_monitor() != Some(f.name.as_str()) {
                let ev = Event::ObserveFocusMonitor { monitor: f.name.clone() };
                if with_effects { let _ = self.apply(ev); } else { let _ = self.model.apply(ev); }
            }
        }
    }

    /// After a display goes away Hyprland hands its workspaces to another monitor and may bring one
    /// up there. The workspace stays out of sight until you go to it (R-M3): put each display back
    /// on what the model says it shows.
    fn reassert(&mut self) {
        let before = self.monitors().into_iter().find(|m| m.focused).map(|m| m.name);
        for m in self.monitors() {
            let want = self.model.current(&m.name).unwrap_or(0);
            if want != 0 && decode(m.ws_id, &m.ws_name) != Some(want) {
                let _ = self.show_workspace(&m.name, want);
            }
        }
        if let Some(b) = before {
            let _ = self.hypr.dispatch(&format!("hl.dsp.focus({{ monitor = {} }})", lua_str(&b)));
        }
    }

    pub fn on_hypr_event(&mut self, ev: HyprEvent) {
        match ev {
            HyprEvent::OpenWindow { addr } => {
                if let Some(c) = self.client(&addr) {
                    self.open_client(&c, false);
                }
            }
            HyprEvent::CloseWindow { addr } => {
                let _ = self.apply(Event::Close { window: addr });
            }
            HyprEvent::ActiveWindow { addr } => {
                let _ = self.apply(Event::Activate { window: addr, cause: Cause::User });
            }
            HyprEvent::MonitorAdded { name } => {
                if !self.model.monitors().any(|m| m == name) {
                    let _ = self.model.apply(Event::MonitorAdded { monitor: name });
                    let order: Vec<String> = {
                        let mut v: Vec<(u32, String)> = self.model.monitors().filter_map(|m| Some((self.model.slot(m)?, m.to_string()))).collect();
                        v.sort();
                        v.into_iter().map(|x| x.1).collect()
                    };
                    self.paths.write_atomic("monitors.json", &json!(order).to_string());
                    self.configure_hyprland();
                }
                self.observe_monitors(true);
                self.persist();
            }
            HyprEvent::MonitorRemoved { name } => {
                let _ = self.apply(Event::MonitorRemoved { monitor: name });
                self.reassert();
            }
            HyprEvent::Workspace { .. } | HyprEvent::FocusedMon { .. } => self.observe_monitors(true),
            HyprEvent::MoveWindow { addr, ws_id, ws_name } => {
                if !self.model.is_tracked(&addr) {
                    if let Some(c) = self.client(&addr) {
                        self.open_client(&c, true);
                    }
                    return;
                }
                if ws_name == AGENT_SPECIAL {
                    let _ = self.apply(Event::ObserveMove { window: addr, n: None });
                } else if let Some(n) = decode(ws_id, &ws_name) {
                    let _ = self.apply(Event::ObserveMove { window: addr, n: Some(n) });
                } else {
                    // Left the scheme (to workspace 10, a scratchpad): no longer ours.
                    let _ = self.apply(Event::Close { window: addr });
                }
            }
            HyprEvent::ActiveSpecial { .. } => {
                let shown = self.special_shown();
                let _ = self.apply(Event::ObserveSpecial { shown });
            }
            HyprEvent::ConfigReloaded => {
                if Self::include_installed() == Some(false) {
                    eprintln!("baneyspaces daemon: the BaneySpaces include is gone from hyprland.lua; exiting");
                    let _ = std::fs::remove_file(self.paths.ctl_socket());
                    std::process::exit(0);
                }
                self.configure_hyprland();
                self.observe_monitors(true);
            }
            HyprEvent::Other => {}
        }
    }
}

// ---- requests -----------------------------------------------------------------------------

fn arg_str<'a>(a: &'a Value, k: &str) -> Option<&'a str> {
    a.get(k).and_then(Value::as_str)
}

fn arg_n(a: &Value) -> Result<u8, Envelope> {
    a.get("n")
        .and_then(|v| {
            v.as_u64()
                .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
        })
        .and_then(|n| u8::try_from(n).ok())
        .ok_or_else(|| {
            Envelope::err(
                "invalid_args",
                "a workspace number 1 to 9 is required",
                Retry::Never,
                "Example: baneyspaces switch 3",
            )
        })
}

fn effects_json(fx: &[Effect]) -> Value {
    serde_json::to_value(fx).unwrap_or(Value::Null)
}


fn which(app: &str) -> Option<std::path::PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    let ok = |p: &std::path::Path| {
        p.is_file()
            && p.metadata()
                .map(|m| m.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
    };
    if app.contains('/') {
        let p = std::path::PathBuf::from(app);
        return ok(&p).then_some(p);
    }
    std::env::var("PATH")
        .ok()?
        .split(':')
        .map(|d| std::path::Path::new(d).join(app))
        .find(|p| ok(p))
}

/// Operations that belong to you. A peer that is an agent (it carries a launch token we issued, or
/// is a registered agent process) is refused them. This guards against accidents, such as an
/// agent shell running `baneyspaces switch 3`; it is not a boundary against a hostile process of
/// your own user, which could unset its environment.
const USER_ONLY: &[&str] = &["switch", "move", "focus_monitor", "agent_show", "agent_hide", "agent_toggle", "agent_move", "agent_bring", "overview", "stop"];

impl Core {
    /// Whether the process on the other end of the control socket is an agent.
    pub fn is_agent_peer(&self, pid: u32) -> bool {
        if proc::token_of(pid).is_some_and(|t| self.tokens.contains_key(&t)) {
            return true;
        }
        self.model.agent_proc(pid).is_some() && self.model.is_agent_pid(pid, proc::start_time(pid).unwrap_or(0))
    }
}

pub fn handle(shared: &Shared, req: &Value, peer: Option<u32>) -> Envelope {
    let op = req["op"].as_str().unwrap_or("");
    let args = req.get("args").cloned().unwrap_or_else(|| json!({}));
    let agent = req["agent"].as_str().unwrap_or("agent").to_string();
    if USER_ONLY.contains(&op) {
        let mut c = lock(shared);
        if peer.is_some_and(|p| c.is_agent_peer(p)) {
            let env = Envelope::err(
                "not_in_scope",
                format!("{op} is for you, not for an agent"),
                Retry::Never,
                "An agent drives only the agent workspace. Ask the user to do this.",
            );
            record(&c, &agent, op, peer, None, None, "ctl", &env);
            return env;
        }
        c.ensure_fresh();
    }
    if op.starts_with("test_") && !lock(shared).test_ops {
        return Envelope::err("invalid_args", "test operations are off", Retry::Never, "");
    }
    match op {
        "ping" => Envelope::ok(json!({ "pong": true, "pid": std::process::id() })),
        "stop" => {
            let sock = lock(shared).paths.ctl_socket();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(150));
                let _ = std::fs::remove_file(&sock);
                std::process::exit(0);
            });
            Envelope::ok(json!({ "stopping": true }))
        }
        "test_register_pid" => {
            let mut c = lock(shared);
            let pid = args["pid"].as_u64().unwrap_or(0) as u32;
            let start = args["start"].as_u64().unwrap_or(0);
            match c.apply(Event::AgentRegister { pid, start }) {
                Ok(_) => Envelope::ok(json!({ "registered": pid })),
                Err(e) => e.envelope(),
            }
        }
        "test_fail_next" => {
            lock(shared).fail_next = Some(args["io"].as_bool().unwrap_or(false));
            Envelope::ok(json!({ "armed": true }))
        }
        "switch" => {
            let n = match arg_n(&args) {
                Ok(n) => n,
                Err(e) => return e,
            };
            let mut c = lock(shared);
            match c.apply(Event::Switch { n }) {
                Ok(fx) => Envelope::ok(json!({ "workspace": n, "effects": effects_json(&fx) })),
                Err(e) => e.envelope(),
            }
        }
        "move" => {
            let n = match arg_n(&args) {
                Ok(n) => n,
                Err(e) => return e,
            };
            let mut c = lock(shared);
            let window = arg_str(&args, "window").map(String::from);
            let follow = !args.get("stay").and_then(Value::as_bool).unwrap_or(false);
            // With no window named, the front window is the one Hyprland says is active.
            let window = window.or_else(|| c.hypr.json("activewindow").ok().and_then(|v| v["address"].as_str().map(String::from)));
            match c.apply(Event::Move { n, window, follow }) {
                Ok(fx) => Envelope::ok(json!({ "workspace": n, "follow": follow, "effects": effects_json(&fx) })),
                Err(e) => e.envelope(),
            }
        }
        "focus_monitor" => {
            let mut c = lock(shared);
            match c.apply(Event::FocusMonitor { monitor: arg_str(&args, "monitor").unwrap_or("").into() }) {
                Ok(fx) => Envelope::ok(json!({ "effects": effects_json(&fx) })),
                Err(e) => e.envelope(),
            }
        }
        "state" => {
            let c = lock(shared);
            let mut v = c.model.view();
            v["version"] = json!(1);
            Envelope::ok(v)
        }
        "ls" => Envelope::ok(ls(&lock(shared))),
        "overview" => {
            let mut c = lock(shared);
            c.overview_shown = !c.overview_shown;
            c.persist();
            Envelope::ok(json!({ "shown": c.overview_shown, "note": "recorded in state.json; the overview is drawn by the Omarchy shell plugin (part 2)" }))
        }
        "agent_show" | "agent_hide" | "agent_toggle" => {
            let ev = match op {
                "agent_show" => Event::AgentShow,
                "agent_hide" => Event::AgentHide,
                _ => Event::AgentToggle,
            };
            let mut c = lock(shared);
            match c.apply(ev) {
                Ok(fx) => Envelope::ok(json!({ "shown": c.model.agent_shown(), "effects": effects_json(&fx) })),
                Err(e) => e.envelope(),
            }
        }
        "agent_move" | "agent_bring" => {
            let Some(w) = arg_str(&args, "window").map(String::from) else {
                return Envelope::err("invalid_args", "a window id is required", Retry::Never, "Run `baneyspaces ls` for window ids.");
            };
            let mut c = lock(shared);
            let ev = if op == "agent_move" { Event::AgentSend { window: w } } else { Event::AgentBring { window: w } };
            match c.apply(ev) {
                Ok(fx) => Envelope::ok(json!({ "effects": effects_json(&fx), "drivable": false })),
                Err(e) => e.envelope(),
            }
        }
        "agent_status" | "agent_windows" => Envelope::ok(agent_status(&lock(shared))),
        "agent_open" => agent_open(shared, &agent, &args),
        "agent_run" => agent_run(shared, &agent, &args),
        "agent_log" => agent_log(&lock(shared), &args),
        "hands" => hands::run(shared, &agent, &args),
        _ => Envelope::err("invalid_args", format!("unknown operation {op:?}"), Retry::Never, "Run `baneyspaces help`."),
    }
}

fn ls(c: &Core) -> Value {
    let clients: BTreeMap<String, Client> = c
        .clients()
        .into_iter()
        .map(|x| (x.addr.clone(), x))
        .collect();
    let view = c.model.view();
    let mut spaces = serde_json::Map::new();
    if let Some(ws) = view["workspaces"].as_object() {
        for (k, list) in ws {
            let rows: Vec<Value> = list.as_array().into_iter().flatten().filter_map(Value::as_str).map(|w| {
                let cl = clients.get(w);
                json!({ "window": w, "app": cl.map(|c| c.class.clone()).unwrap_or_default(), "title": cl.map(|c| c.title.clone()).unwrap_or_default(), "pid": cl.map(|c| c.pid) })
            }).collect();
            spaces.insert(k.clone(), json!(rows));
        }
    }
    json!({ "focused_monitor": view["focused_monitor"], "active": view["active"], "monitors": view["monitors"], "workspaces": spaces, "agent": agent_status(c) })
}

fn agent_status(c: &Core) -> Value {
    let clients: BTreeMap<String, Client> = c
        .clients()
        .into_iter()
        .map(|x| (x.addr.clone(), x))
        .collect();
    let windows: Vec<Value> = c
        .model
        .agent_windows()
        .into_iter()
        .map(|w| {
            let cl = clients.get(w);
            let pid = c.model.pid_of(w);
            json!({ "window": w, "app": cl.map(|c| c.class.clone()).unwrap_or_default(), "title": cl.map(|c| c.title.clone()).unwrap_or_default(), "pid": pid, "drivable": pid.is_some_and(|p| c.model.agent_proc(p).is_some()) })
        })
        .collect();
    json!({ "workspace": AGENT_SPECIAL, "shown": c.model.agent_shown(), "windows": windows, "processes": c.model.agent_pids().len(), "refused": c.model.refused() })
}

/// Appends one line to the action log, and at most once an hour drops records older than 30 days.
/// `last` holds the time of the last look; `now` is passed in so a test can move the clock.
pub fn append_and_maybe_prune(paths: &Paths, line: &str, now: u64, last: &std::cell::Cell<u64>) {
    paths.append("actions.jsonl", line);
    prune_if_due(paths, now, last);
}

pub fn prune_if_due(paths: &Paths, now: u64, last: &std::cell::Cell<u64>) {
    if last.get() != 0 && now.saturating_sub(last.get()) < PRUNE_EVERY_SECS {
        return;
    }
    last.set(now);
    if let Some(text) = paths.read("actions.jsonl") {
        if let Some(kept) = prune_text(&text, now) {
            paths.write_atomic("actions.jsonl", &kept);
        }
    }
}

pub fn append_record(c: &Core, rec: &ActionRecord) {
    append_and_maybe_prune(&c.paths, &rec.to_line(), now(), &c.last_prune);
}

pub fn record(c: &Core, agent: &str, verb: &str, pid: Option<u32>, window: Option<&str>, reference: Option<&str>, route: &str, env: &Envelope) {
    append_record(c, &ActionRecord::from_result(now(), agent, verb, pid, window, reference, route, env));
}

fn agent_log(c: &Core, args: &Value) -> Envelope {
    let floor = now().saturating_sub(baneyspaces_core::agent::RETENTION_DAYS * 86_400);
    let since = args.get("since").and_then(Value::as_u64).map(|s| now().saturating_sub(s)).unwrap_or(0).max(floor);
    let log = baneyspaces_core::ActionLog::parse(&c.paths.read("actions.jsonl").unwrap_or_default());
    let rows: Vec<&ActionRecord> = log.records.iter().filter(|r| r.at >= since).collect();
    Envelope::ok(json!({ "records": rows, "retention_days": baneyspaces_core::agent::RETENTION_DAYS }))
}

fn hypr_failure(e: &HyprError, what: &str) -> Envelope {
    let retry = if e.uncertain() { Retry::Never } else { Retry::Safe };
    Envelope::err("compositor_error", format!("{what}: {e}"), retry, "Is Hyprland running? Check `baneyspaces doctor`.")
}

/// Starts `argv` as a new process on the agent workspace, then waits for a window of its own.
/// Before launching it refuses an app that would hand the request to a copy you already run.
fn launch_on_agent(shared: &Shared, agent: &str, label: &str, mut argv: Vec<String>) -> Envelope {
    let token = match proc::random_token() {
        Ok(t) => t,
        Err(e) => return Envelope::err("internal", format!("no random bytes: {e}"), Retry::Never, ""),
    };
    let known: HashSet<String>;
    {
        let mut c = lock(shared);
        let exe = std::path::PathBuf::from(&argv[0]);
        let profile = apps::profile_dir(&c.paths.state, &token);
        match apps::known(&argv[0], &profile) {
            Some(apps::Launch::Separate) => {}
            Some(apps::Launch::Flags(flags)) => {
                let _ = std::fs::create_dir_all(&profile);
                for (i, f) in flags.into_iter().enumerate() {
                    argv.insert(1 + i, f);
                }
            }
            None => {
                let tokens: HashSet<String> = c.tokens.keys().cloned().collect();
                let key = apps::instance_key(&exe, &argv[1..]);
                if let Some(pid) = apps::user_instance(&key, &tokens) {
                    let env = Envelope::err(
                        "needs_sandbox",
                        format!("{label} is already running for you (pid {pid}) and would hand the request to that copy, so an agent would be working in your own app"),
                        Retry::Never,
                        "Agents drive only a process BaneySpaces starts as a new instance. Use the app's files or command line instead; a sandbox for apps like this comes later.",
                    )
                    .with_data(json!({ "user_pid": pid }));
                    record(&c, agent, "open", None, None, None, "preflight", &env);
                    return env;
                }
            }
        }
        known = c.model.window_ids().into_iter().map(String::from).collect();
        let cmd = format!(
            "env BANEYSPACES_AGENT_TOKEN={token} BANEYSPACES_AGENT_ID={} {}",
            sh_quote(agent),
            argv.iter().map(|a| sh_quote(a)).collect::<Vec<_>>().join(" ")
        );
        c.tokens.insert(token.clone(), TokenInfo { agent: agent.into(), app: label.into(), at: now() });
        c.save_tokens();
        let lua = format!("hl.dsp.exec_cmd({}, {{ workspace = \"{} silent\" }})", lua_str(&cmd), AGENT_SPECIAL);
        if let Err(e) = c.hypr.dispatch(&lua) {
            let env = hypr_failure(&e, "could not start the app");
            record(&c, agent, "open", None, None, None, "exec", &env);
            return env;
        }
    }
    let deadline = Instant::now() + Duration::from_secs(8);
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
        let c = lock(shared);
        if let Some(pid) = c.token_pids.get(&token).and_then(|v| v.first()).copied() {
            if let Some(w) = c.model.agent_windows().into_iter().find(|w| c.model.pid_of(w) == Some(pid)).map(String::from) {
                let title = c.client(&w).map(|x| x.title).unwrap_or_default();
                let env = Envelope::ok(json!({ "window": w, "pid": pid, "app": label, "title": title, "workspace": AGENT_SPECIAL, "start": proc::start_time(pid) }));
                record(&c, agent, "open", Some(pid), Some(&w), None, "exec", &env);
                return env;
            }
        }
    }
    let c = lock(shared);
    let alive = proc::pids_with_token(&token);
    // Windows that appeared while we waited and are not the agent's: the app may have forwarded to
    // a copy of yours. They are left exactly where they are; this only says so.
    let strays: Vec<Value> = c
        .model
        .window_ids()
        .into_iter()
        .filter(|w| !known.contains(*w) && !c.model.is_agent_window(w))
        .map(|w| json!({ "window": w, "pid": c.model.pid_of(w) }))
        .collect();
    let mut env = if alive.is_empty() {
        let extra = if strays.is_empty() { "" } else { "; a window of yours appeared meanwhile and was left where it is" };
        Envelope::err(
            "single_instance",
            format!("{label} exited without a window of its own: it most likely handed the request to an instance that was already running{extra}"),
            Retry::Never,
            "Agents drive only a process BaneySpaces started. Use the app's files or command line instead, or ask the user to lend it.",
        )
    } else {
        Envelope::err("timeout", format!("{label} is running (pid {}) but opened no window within 8 s", alive[0]), Retry::Never, "Check `baneyspaces agent status`; the app may need a display flag.")
    };
    if !strays.is_empty() {
        env = env.with_data(json!({ "windows_that_appeared": strays }));
    }
    record(&c, agent, "open", alive.first().copied(), None, None, "exec", &env);
    env
}

fn agent_open(shared: &Shared, agent: &str, args: &Value) -> Envelope {
    let Some(app) = arg_str(args, "app") else {
        return Envelope::err("invalid_args", "an app is required", Retry::Never, "Example: baneyspaces agent open zenity --info");
    };
    let Some(exe) = which(app) else {
        return Envelope::err("not_found", format!("no program {app:?} on PATH"), Retry::Never, "Give an executable name or a full path.");
    };
    let mut argv = vec![exe.to_string_lossy().into_owned()];
    argv.extend(args.get("args").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(String::from));
    launch_on_agent(shared, agent, app, argv)
}

fn agent_run(shared: &Shared, agent: &str, args: &Value) -> Envelope {
    let cmd: Vec<String> = args
        .get("command")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(String::from)
        .collect();
    if cmd.is_empty() {
        return Envelope::err(
            "invalid_args",
            "a command is required after --",
            Retry::Never,
            "Example: baneyspaces agent run --dir ~/Projects/x -- claude",
        );
    }
    let terminals: [(&str, &[&str]); 4] = [
        ("foot", &[]),
        ("ghostty", &["-e"]),
        ("kitty", &[]),
        ("alacritty", &["-e"]),
    ];
    let Some((term, pre)) = terminals.iter().find(|(t, _)| which(t).is_some()) else {
        return Envelope::err(
            "not_found",
            "no terminal found (foot, ghostty, kitty or alacritty)",
            Retry::Never,
            "Install one of them.",
        );
    };
    let mut argv = vec![which(term).unwrap().to_string_lossy().into_owned()];
    if let Some(d) = arg_str(args, "dir") {
        match *term {
            "foot" => argv.extend(["-D".into(), d.into()]),
            "kitty" => argv.extend(["-d".into(), d.into()]),
            "ghostty" => argv.push(format!("--working-directory={d}")),
            _ => argv.extend(["--working-directory".into(), d.into()]),
        }
    }
    argv.extend(pre.iter().map(|s| s.to_string()));
    argv.extend(cmd);
    launch_on_agent(shared, agent, term, argv)
}

// ---- serving --------------------------------------------------------------------------------

/// The pid of the process on the other end of a Unix socket (SO_PEERCRED).
fn peer_pid(s: &UnixStream) -> Option<u32> {
    use std::os::unix::io::AsRawFd;
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: `cred` and `len` are valid for the call; the fd is a live socket.
    let r = unsafe { libc::getsockopt(s.as_raw_fd(), libc::SOL_SOCKET, libc::SO_PEERCRED, &mut cred as *mut _ as *mut libc::c_void, &mut len) };
    (r == 0 && cred.pid > 0).then_some(cred.pid as u32)
}

fn serve_conn(shared: Shared, mut s: UnixStream) {
    let _ = s.set_read_timeout(Some(Duration::from_secs(10)));
    let peer = peer_pid(&s);
    let mut line = String::new();
    let mut r = BufReader::new(&s).take(1 << 20);
    if r.read_line(&mut line).is_err() {
        return;
    }
    let env = match serde_json::from_str::<Value>(&line) {
        Ok(req) => handle(&shared, &req, peer),
        Err(e) => Envelope::err("invalid_args", format!("bad request: {e}"), Retry::Never, ""),
    };
    let _ = writeln!(s, "{}", env.to_json());
}

pub fn run(trace: bool) -> i32 {
    let hypr = match Hypr::from_env() {
        Ok(h) => h,
        Err(e) => {
            eprintln!("baneyspaces daemon: {e}");
            return 1;
        }
    };
    let paths = Paths::from_env();
    if let Err(e) = paths.ensure() {
        eprintln!("baneyspaces daemon: {e}");
        return 1;
    }
    let sock = paths.ctl_socket();
    if UnixStream::connect(&sock).is_ok() {
        eprintln!("baneyspaces daemon: already running ({})", sock.display());
        return 1;
    }
    let _ = std::fs::remove_file(&sock);
    let listener = match UnixListener::bind(&sock) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("baneyspaces daemon: cannot bind {}: {e}", sock.display());
            return 1;
        }
    };
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&sock, std::fs::Permissions::from_mode(0o600));
    }
    let core = Core {
        model: Model::new(),
        hypr: hypr.clone(),
        paths: paths.clone(),
        tokens: HashMap::new(),
        token_pids: HashMap::new(),
        snaps: HashMap::new(),
        overview_shown: false,
        events_seen: 0,
        started: now(),
        trace,
        dirty: false,
        last_prune: std::cell::Cell::new(0),
        test_ops: std::env::var("BANEYSPACES_TEST_OPS").is_ok_and(|v| v == "1"),
        fail_next: None,
        resyncing: false,
    };
    let shared: Shared = Arc::new(Mutex::new(core));
    {
        let mut c = lock(&shared);
        prune_if_due(&c.paths, now(), &c.last_prune);
        c.resync();
    }
    // Hyprland's events.
    {
        let shared = shared.clone();
        let stream = match hypr.events() {
            Ok(s) => s,
            Err(e) => {
                eprintln!("baneyspaces daemon: cannot read Hyprland events: {e}");
                return 1;
            }
        };
        std::thread::spawn(move || {
            for line in BufReader::new(stream).lines() {
                let Ok(line) = line else { break };
                let ev = parse_event(&line);
                if ev != HyprEvent::Other {
                    lock(&shared).on_hypr_event(ev);
                }
            }
            eprintln!("baneyspaces daemon: Hyprland closed the event socket; exiting");
            std::process::exit(0);
        });
    }
    // Upkeep: forget agent processes that died or whose pid was reused, keep the focus setting
    // R-F2 rests on, and let the action log shed old records.
    {
        let shared = shared.clone();
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_secs(2));
            let mut c = lock(&shared);
            c.reconcile_agents();
            c.ensure_focus_setting();
            prune_if_due(&c.paths, now(), &c.last_prune);
        });
    }
    eprintln!("baneyspaces daemon: ready ({})", sock.display());
    for conn in listener.incoming().flatten() {
        let shared = shared.clone();
        std::thread::spawn(move || serve_conn(shared, conn));
    }
    0
}

/// How long the CLI and MCP client wait for the daemon. The daemon's own budget for one hands call
/// (`hands::BUDGET_SECS`) is well under this, so a reply always comes first unless something is wrong.
pub const CLIENT_TIMEOUT_SECS: u64 = 90;

/// Sends one request to the running daemon.
pub fn call(paths: &Paths, req: &Value) -> Envelope {
    call_timeout(paths, req, Duration::from_secs(CLIENT_TIMEOUT_SECS))
}

/// A connect failure means nothing was sent: `daemon_down`, safe to repeat. Once the request is
/// written, silence is not safety: a read timeout or an empty reply is `timeout`, never repeat.
pub fn call_timeout(paths: &Paths, req: &Value, wait: Duration) -> Envelope {
    let down = || Envelope::err("daemon_down", "baneyspaces daemon is not running", Retry::Safe, "Start it: baneyspaces daemon (Omarchy starts it from the autostart file).");
    let Ok(mut s) = UnixStream::connect(paths.ctl_socket()) else {
        return down();
    };
    let _ = s.set_read_timeout(Some(wait));
    if writeln!(s, "{req}").is_err() {
        return down();
    }
    let uncertain = || {
        Envelope::err(
            "timeout",
            "the daemon did not answer in time; the command may or may not have been carried out",
            Retry::Never,
            "Look at the state (`baneyspaces state`, `baneyspaces agent status`) before trying again.",
        )
    };
    let mut out = String::new();
    match BufReader::new(&s).read_line(&mut out) {
        Ok(0) | Err(_) => uncertain(),
        Ok(_) if out.is_empty() => uncertain(),
        Ok(_) => serde_json::from_str(&out).unwrap_or_else(|_| Envelope::err("internal", "unreadable reply from the daemon", Retry::Never, "")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_paths(tag: &str) -> Paths {
        let base = std::env::temp_dir().join(format!("bs-test-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let p = Paths { state: base.join("state"), run: base.join("run") };
        p.ensure().unwrap();
        p
    }

    fn test_core(tag: &str) -> Core {
        let paths = temp_paths(tag);
        Core {
            model: Model::new(),
            hypr: Hypr::at(paths.run.join("no-hyprland")),
            paths,
            tokens: HashMap::new(),
            token_pids: HashMap::new(),
            snaps: HashMap::new(),
            overview_shown: false,
            events_seen: 0,
            started: now(),
            trace: false,
            dirty: false,
            last_prune: std::cell::Cell::new(0),
            test_ops: false,
            fail_next: None,
            resyncing: false,
        }
    }

    #[test]
    fn issued_tokens_survive_a_restart_privately_and_stale_ones_do_not() {
        use std::os::unix::fs::PermissionsExt;
        let mut a = test_core("tokens");
        let me = proc::random_token().unwrap();
        a.tokens.insert("fresh".into(), TokenInfo { agent: "claude".into(), app: "foot".into(), at: now() });
        a.tokens.insert("old-and-dead".into(), TokenInfo { agent: "x".into(), app: "y".into(), at: now() - 3600 });
        let _ = me;
        a.save_tokens();
        let mode = std::fs::metadata(a.paths.state.join("tokens.json")).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        // A new daemon (same state directory) loads them.
        let mut b = test_core("tokens2");
        b.paths = a.paths.clone();
        b.load_tokens();
        assert!(b.tokens.contains_key("fresh"), "a token issued a moment ago is kept");
        assert!(!b.tokens.contains_key("old-and-dead"), "an old token no process carries is dropped");
        assert_eq!(b.tokens["fresh"].agent, "claude");
    }

    #[test]
    fn a_dead_or_reused_agent_pid_is_forgotten() {
        let mut c = test_core("reuse");
        let me = std::process::id();
        let start = proc::start_time(me).unwrap();
        c.model.apply(Event::AgentRegister { pid: me, start }).unwrap();
        c.model.apply(Event::AgentRegister { pid: u32::MAX - 7, start: 5 }).unwrap(); // not a live pid
        c.model.apply(Event::AgentRegister { pid: 1, start: 1 }).unwrap(); // a live pid with another start time
        c.reconcile_agents();
        let pids: Vec<u32> = c.model.agent_pids().into_iter().map(|p| p.0).collect();
        assert_eq!(pids, vec![me], "only the live process with the matching start time stays");
    }

    #[test]
    fn no_socket_is_daemon_down_and_safe() {
        let p = temp_paths("down");
        let e = call_timeout(&p, &json!({"op":"ping"}), Duration::from_millis(100));
        let er = e.error.unwrap();
        assert_eq!((er.code.as_str(), er.retry), ("daemon_down", Retry::Safe));
    }

    #[test]
    fn silence_after_the_write_is_a_timeout_and_never_safe() {
        let p = temp_paths("slow");
        let l = UnixListener::bind(p.ctl_socket()).unwrap();
        let t = std::thread::spawn(move || {
            let (mut c, _) = l.accept().unwrap();
            let mut buf = String::new();
            BufReader::new(&c).read_line(&mut buf).unwrap();
            std::thread::sleep(Duration::from_millis(600)); // never answers in time
            let _ = writeln!(c, "{{\"ok\":true}}");
        });
        let e = call_timeout(&p, &json!({"op":"hands"}), Duration::from_millis(150));
        let er = e.error.unwrap();
        assert_eq!((er.code.as_str(), er.retry), ("timeout", Retry::Never));
        t.join().unwrap();
    }

    #[test]
    fn a_closed_connection_without_a_reply_is_also_uncertain() {
        let p = temp_paths("closed");
        let l = UnixListener::bind(p.ctl_socket()).unwrap();
        let t = std::thread::spawn(move || {
            let (c, _) = l.accept().unwrap();
            let mut buf = String::new();
            BufReader::new(&c).read_line(&mut buf).unwrap();
        });
        let e = call_timeout(&p, &json!({"op":"hands"}), Duration::from_secs(2));
        assert_eq!(e.error.unwrap().code, "timeout");
        t.join().unwrap();
    }

    #[test]
    fn the_hands_budget_is_well_under_the_client_wait() {
        assert!(crate::hands::BUDGET_SECS * 3 / 2 < CLIENT_TIMEOUT_SECS);
    }

    #[test]
    fn the_log_sheds_old_records_when_a_line_is_appended_and_not_more_than_hourly() {
        let day = 86_400u64;
        let p = temp_paths("prune");
        let rec = |at: u64| format!("{{\"at\":{at},\"agent\":\"a\",\"verb\":\"click\",\"pid\":1,\"window\":null,\"ref\":null,\"route\":\"atspi\",\"result\":\"ok\",\"refusal\":null,\"screen_changed\":false}}");
        let last = std::cell::Cell::new(0);
        let t0 = 100 * day;
        // An old record and a recent one are on disk; the daemon has run for 31 days since the old one.
        p.append("actions.jsonl", &rec(t0 - 31 * day));
        p.append("actions.jsonl", &rec(t0 - day));
        append_and_maybe_prune(&p, &rec(t0), t0, &last);
        let lines = p.read("actions.jsonl").unwrap().lines().count();
        assert_eq!(lines, 2, "the 31-day-old record went on append");
        // Within the hour it does not look again, even with a new old record on disk.
        p.append("actions.jsonl", &rec(t0 - 40 * day));
        append_and_maybe_prune(&p, &rec(t0 + 60), t0 + 60, &last);
        assert_eq!(p.read("actions.jsonl").unwrap().lines().count(), 4);
        // An hour later it does.
        append_and_maybe_prune(&p, &rec(t0 + 3700), t0 + 3700, &last);
        assert_eq!(p.read("actions.jsonl").unwrap().lines().count(), 4 - 1 + 1);
    }

    #[test]
    fn effects_failure_envelope_is_never_safe_when_uncertain() {
        let io = ApplyError::Compositor { err: HyprError::Io("timed out".into()), delivered_any: false }.envelope();
        assert_eq!(io.error.as_ref().unwrap().retry, Retry::Never);
        let refused = ApplyError::Compositor { err: HyprError::Refused("no".into()), delivered_any: false }.envelope();
        assert_eq!(refused.error.as_ref().unwrap().retry, Retry::Safe);
        let partial = ApplyError::Compositor { err: HyprError::Refused("no".into()), delivered_any: true }.envelope();
        assert_eq!(partial.error.as_ref().unwrap().retry, Retry::Never);
        assert_eq!(partial.error.unwrap().code, "compositor_error");
    }
}
