//! `baneyspaces daemon`: the model driven by Hyprland's events, the control socket the CLI talks
//! to, `state.json`, the agent workspace and the agent action log.

use crate::apps;
use crate::bus;
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
    /// The private session bus this launch's processes use.
    pub bus: Option<bus::BusInfo>,
    /// The launch's session bus ended with an earlier daemon: its apps keep a dead bus address and
    /// cannot be driven until they are started again.
    pub bus_lost: bool,
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
    /// Effects the rules asked for while the model was being rebuilt; run when it is done.
    pub deferred: Vec<Effect>,
    /// Test only: how long a hands call waits between finding the window and acting on it.
    pub stall_ms: u64,
    /// The private bus daemons we started, by token (the handle, to reap them).
    pub bus_children: HashMap<String, Vec<std::process::Child>>,
    /// Stacks to take down once the Core lock is released (stopping waits for processes).
    pub pending_stops: Vec<bus::StopJob>,
}

pub type Shared = Arc<Mutex<Core>>;

/// The dispatches that make `monitor` show workspace `n`.
pub fn show_steps(monitor: &str, n: u8, lives_on: Option<&str>, focused: Option<&str>) -> Vec<String> {
    let mut v = vec![];
    if focused.is_some_and(|f| f != monitor) {
        v.push(format!("hl.dsp.focus({{ monitor = {} }})", lua_str(monitor)));
    }
    if lives_on.is_some_and(|on| on != monitor) {
        v.push(format!("hl.dsp.workspace.move({{ workspace = {}, monitor = {} }})", lua_str(&n.to_string()), lua_str(monitor)));
    }
    v.push(format!("hl.dsp.focus({{ workspace = {} }})", lua_str(&n.to_string())));
    v
}

/// Sends the steps in order. A failure says whether any earlier step went through, so a half-done
/// switch is never reported as one that changed nothing.
pub fn run_steps(steps: &[String], send: &mut dyn FnMut(&str) -> Result<(), HyprError>) -> Result<(), (HyprError, bool)> {
    for (i, step) in steps.iter().enumerate() {
        send(step).map_err(|e| (e, i > 0))?;
    }
    Ok(())
}

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

/// Leaving the daemon takes every agent bus stack with it. (A stack is the daemon's child: it dies
/// too if the daemon is killed outright.)
pub fn exit_daemon(code: i32) -> ! {
    bus::kill_all();
    std::process::exit(code)
}

pub fn lock(s: &Shared) -> MutexGuard<'_, Core> {
    s.lock().unwrap_or_else(|p| p.into_inner())
}

impl Core {
    pub fn monitors(&self) -> Vec<Mon> {
        self.try_monitors().unwrap_or_default()
    }

    /// The displays, or the error: a failed query is not an empty list.
    pub fn try_monitors(&self) -> Result<Vec<Mon>, String> {
        let v = self.hypr.json("monitors")?;
        Ok(Self::parse_monitors(&v))
    }

    fn parse_monitors(v: &Value) -> Vec<Mon> {
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
        self.try_clients().unwrap_or_default()
    }

    pub fn try_clients(&self) -> Result<Vec<Client>, String> {
        let v = self.hypr.json("clients")?;
        Ok(Self::parse_clients(&v))
    }

    fn parse_clients(v: &Value) -> Vec<Client> {
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

    /// Whether the agent workspace is showing on some display, or why that cannot be known. A failed
    /// query is not "hidden": acting on it would toggle the wrong way.
    fn special_shown(&self) -> Result<bool, HyprError> {
        let v = self.hypr.json("monitors").map_err(HyprError::Io)?;
        Ok(Self::parse_monitors(&v).iter().any(|m| m.special == AGENT_SPECIAL))
    }

    fn log(&self, msg: &str) {
        if self.trace {
            eprintln!("[baneyspaces] {msg}");
        }
    }

    // ---- Hyprland setup ------------------------------------------------------------------

    /// Turns workspace animations off, stops apps taking focus by asking, and gives a display that
    /// shows nothing of ours a workspace. Run at start and after every config reload.
    pub fn configure_hyprland(&self, new: &[String]) -> bool {
        // Instant switching and the focus rule are what the rest rests on: if either cannot be set,
        // the model stays dirty and commands are refused until they can.
        let mut ok = true;
        for lua in [
            "hl.animation({ leaf = \"workspaces\", enabled = false })",
            "hl.animation({ leaf = \"specialWorkspace\", enabled = false })",
            "hl.config({ misc = { focus_on_activate = false } })",
        ] {
            if let Err(e) = self.hypr.eval(lua) {
                self.log(&format!("could not apply {lua}: {e}"));
                ok = false;
            }
        }
        self.adopt_monitors(new) && ok
    }

    /// A display showing an empty, non-persistent workspace that is not one of the nine (the
    /// default Hyprland gives a new monitor) shows the workspace the model picked for it (R-M2).
    /// A display showing anything you keep (workspace 10 with the work dashboard) is left alone.
    fn adopt_monitors(&self, new: &[String]) -> bool {
        let Ok(spaces) = self.hypr.json("workspaces") else { return false };
        let mut ok = true;
        let spaces = spaces.as_array().cloned().unwrap_or_default();
        let before = self.monitors().into_iter().find(|m| m.focused).map(|m| m.name);
        let mut moved = false;
        for m in self.monitors() {
            let have = decode(m.ws_id, &m.ws_name);
            // The workspace this display is to show: the model's pick for a new one, else the first
            // one nobody shows, decided from what the other displays show now.
            let Some(want) = self.model.current(&m.name).filter(|n| *n != 0).or_else(|| Some(self.model.pick_for(&m.name)).filter(|n| *n != 0)) else { continue };
            // A display that was just plugged in gets the workspace R-M2 picked whenever Hyprland's
            // own default differs; any other display only when it shows nothing of the nine.
            let wanted = if new.contains(&m.name) { have != Some(want) } else { have.is_none() };
            if !wanted {
                continue;
            }
            let Some(ws) = spaces.iter().find(|w| w["id"].as_i64() == Some(m.ws_id)) else { continue };
            if ws["windows"].as_u64().unwrap_or(1) != 0 || ws["ispersistent"].as_bool().unwrap_or(true) {
                continue;
            }
            ok &= self.show_workspace(&m.name, want).is_ok();
            moved = true;
        }
        if let (true, Some(b)) = (moved, before) {
            ok &= self.hypr.dispatch(&format!("hl.dsp.focus({{ monitor = {} }})", lua_str(&b))).is_ok();
        }
        ok
    }

    /// Makes `monitor` show workspace `n`: brings the workspace there if Hyprland keeps it on
    /// another monitor, then focuses it. Leaves focus on `monitor`; callers put it back. On failure
    /// the flag says whether an earlier step had already gone through.
    fn show_workspace(&self, monitor: &str, n: u8) -> Result<(), (HyprError, bool)> {
        let lives = self.hypr.json("workspaces").ok().and_then(|v| v.as_array().and_then(|a| a.iter().find(|w| w["id"].as_i64() == Some(n as i64)).and_then(|w| w["monitor"].as_str().map(String::from))));
        let focused = self.monitors().into_iter().find(|m| m.focused).map(|m| m.name);
        let steps = show_steps(monitor, n, lives.as_deref(), focused.as_deref());
        run_steps(&steps, &mut |lua| self.hypr.dispatch(lua))
    }

    // ---- model plumbing ------------------------------------------------------------------

    pub fn apply(&mut self, ev: Event) -> Result<Vec<Effect>, ApplyError> {
        self.events_seen += 1;
        let effects = self.model.apply(ev).map_err(ApplyError::Model)?;
        if self.resyncing {
            // Re-reading Hyprland only learns. What the rules want done about it is collected and
            // run afterwards, once, with its failures recorded.
            self.deferred.extend(effects.iter().cloned());
            return Ok(effects);
        }
        let r = self.exec(&effects);
        self.persist();
        if let Err((err, delivered_any)) = r {
            // The model has committed a state the compositor may not have reached. Re-read it
            // before anything else is accepted.
            self.log(&format!("dispatch failed ({err}); re-reading Hyprland"));
            self.resync();
            return Err(ApplyError::Compositor { err, delivered_any });
        }
        Ok(effects)
    }

    /// Before a command: if the last failure left the model unsure, learn the compositor's state
    /// first. If it is still unsure, the command is refused (`compositor_error`, retry `after`)
    /// rather than run against a model that may be wrong.
    pub fn ensure_fresh(&mut self) -> Result<(), Envelope> {
        if self.dirty {
            self.resync();
        }
        if self.dirty {
            return Err(Envelope::err(
                "compositor_error",
                "BaneySpaces could not read Hyprland's state after the last failure, so it will not act on a guess",
                Retry::After,
                "Wait a moment and send it again; check `baneyspaces doctor` if it keeps failing.",
            ));
        }
        Ok(())
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
            let d = |lua: &str| self.hypr.dispatch(lua).map_err(|e| (e, false));
            let r = match e {
                Effect::ShowWorkspace { monitor, workspace } => self.show_workspace(monitor, *workspace),
                Effect::FocusMonitor { monitor } => d(&format!("hl.dsp.focus({{ monitor = {} }})", lua_str(monitor))),
                Effect::FocusWindow { window } => d(&format!("hl.dsp.focus({{ window = {} }})", lua_str(&format!("address:{window}")))),
                Effect::MoveWindow { window, to } => {
                    let dest = if to == "agent" { Some(AGENT_SPECIAL.to_string()) } else { to.parse::<u8>().ok().map(|n| n.to_string()) };
                    match dest {
                        Some(dest) => d(&format!("hl.dsp.window.move({{ workspace = {}, follow = false, window = {} }})", lua_str(&dest), lua_str(&format!("address:{window}")))),
                        None => Ok(()),
                    }
                }
                Effect::ShowAgent => match self.special_shown() {
                    Err(e) => Err((e, false)),
                    Ok(true) => Ok(()),
                    Ok(false) => d(&format!("hl.dsp.workspace.toggle_special({})", lua_str(AGENT_SPECIAL_NAME))),
                },
                Effect::HideAgent => {
                    // The toggle acts on the focused monitor, so go to the one that shows the agent
                    // workspace first; the end of this function puts focus back.
                    let shown = self.hypr.json("monitors").map_err(|e| (HyprError::Io(e), false)).map(|v| Self::parse_monitors(&v).into_iter().find(|m| m.special == AGENT_SPECIAL));
                    match shown {
                        Err(e) => Err(e),
                        Ok(None) => Ok(()),
                        Ok(Some(m)) => {
                            let mut r = Ok(());
                            let mut went = false;
                            if !m.focused {
                                r = d(&format!("hl.dsp.focus({{ monitor = {} }})", lua_str(&m.name)));
                                went = r.is_ok();
                            }
                            r.and_then(|_| d(&format!("hl.dsp.workspace.toggle_special({})", lua_str(AGENT_SPECIAL_NAME))).map_err(|(e, _)| (e, went)))
                        }
                    }
                }
                Effect::RefuseFollow { .. } => Ok(()),
                Effect::SetFloat { window, float } => d(&format!("hl.dsp.window.float({{ action = {}, window = {} }})", lua_str(if *float { "enable" } else { "disable" }), lua_str(&format!("address:{window}")))),
            };
            if let Err((err, partial)) = r {
                self.log(&format!("effect failed: {err}"));
                return Err((err, i > 0 || partial));
            }
        }
        // A switch on a monitor you are not on must not take you there. Only after effects this
        // command sent: an observed event (you moved the pointer, clicked a workspace) is the user's
        // doing and is never undone.
        if effects.is_empty() {
            return Ok(());
        }
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
        let _ = self.apply(Event::Open { window: c.addr.clone(), pid: c.pid, start, app: c.class.clone(), monitor, workspace: n, title: c.title.clone() });
        if on_agent && !matches!(self.model.home(&c.addr), Some(Home::Agent)) {
            let _ = self.apply(Event::AgentSend { window: c.addr.clone() });
        }
    }

    /// Rebuilds the model from Hyprland. While it runs nothing is dispatched for the windows and
    /// focus it finds: the effects the rules ask for are collected and run once at the end. (Setup,
    /// turning animations off and giving an empty foreign display a workspace, is its own step.)
    pub fn resync(&mut self) {
        // Read the compositor before touching the model: if it cannot be read, the old model stays,
        // and stays marked dirty (a failed query is not an empty desktop).
        let (mut mons, clients) = match (self.try_monitors(), self.try_clients()) {
            (Ok(m), Ok(c)) => (m, c),
            (m, c) => {
                self.log(&format!("cannot re-read Hyprland: {:?} {:?}", m.err(), c.err()));
                self.dirty = true;
                return;
            }
        };
        self.resyncing = true;
        self.model = Model::new();
        let order = self.paths.read("monitors.json").and_then(|t| serde_json::from_str::<Vec<String>>(&t).ok()).unwrap_or_default();
        mons.sort_by_key(|m| (order.iter().position(|o| *o == m.name).unwrap_or(usize::MAX), m.id));
        for m in &mons {
            let _ = self.model.apply(Event::MonitorAdded { monitor: m.name.clone() });
        }
        self.paths.write_atomic("monitors.json", &json!(mons.iter().map(|m| m.name.clone()).collect::<Vec<_>>()).to_string());
        // What each display shows NOW comes first. The setup below decides from it; deciding from the
        // fresh model's guess (display A on 1, display B on 2) would take a workspace off the display
        // you are looking at.
        self.observe_monitors(false);
        let set_up = self.configure_hyprland(&[]);
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
        for c in &clients {
            self.open_client(c, true);
        }
        // With the windows known, the window to put in front on the display you are on is known too.
        if let Some(f) = mons.iter().find(|m| m.focused) {
            let _ = self.model.apply(Event::ObserveFocusMonitor { monitor: f.name.clone() });
        }
        // An agent workspace found showing was not shown by you (R-G3): it is hidden again, as a
        // deferred effect like everything else found here.
        if mons.iter().any(|m| m.special == AGENT_SPECIAL) {
            let _ = self.apply(Event::ObserveSpecial { shown: true });
        }
        // An agent window found in front is handled by the same rule as at any other time (R-G1): the
        // user's window is put back, as a deferred effect.
        if let Ok(v) = self.hypr.json("activewindow") {
            if let Some(a) = v["address"].as_str() {
                let _ = self.apply(Event::Activate { window: Some(a.into()), cause: Cause::User });
            }
        }
        self.resyncing = false;
        // What the rules want done about what was found (an agent process's window on your
        // workspace, say) runs now. A failure here is recorded: the next command re-reads again.
        let todo = std::mem::take(&mut self.deferred);
        self.dirty = !set_up;
        if !todo.is_empty() {
            if let Err((err, _)) = self.exec(&todo) {
                self.log(&format!("corrective effects after a re-read failed: {err}"));
                self.dirty = true;
            }
        }
        self.persist();
    }

    /// The launch tokens we issued, kept (0600) so a restart still knows the terminal an agent is
    /// running in. A token with no live process and older than a minute is dropped.
    pub fn save_tokens(&self) {
        let m: serde_json::Map<String, Value> = self.tokens.iter().map(|(t, i)| (t.clone(), json!({ "agent": i.agent, "app": i.app, "at": i.at, "bus_lost": i.bus_lost, "bus": i.bus.as_ref().map(|b| json!({ "addr": b.addr, "pid": b.pid, "start": b.start })) }))).collect();
        self.paths.write_atomic("tokens.json", &Value::Object(m).to_string());
    }

    fn load_tokens(&mut self) {
        let Some(Value::Object(m)) = self.paths.read("tokens.json").and_then(|t| serde_json::from_str::<Value>(&t).ok()) else { return };
        for (tok, v) in m {
            let at = v["at"].as_u64().unwrap_or(0);
            let bus = v["bus"].as_object().map(|b| bus::BusInfo { addr: b.get("addr").and_then(Value::as_str).unwrap_or("").into(), pid: b.get("pid").and_then(Value::as_u64).unwrap_or(0) as u32, start: b.get("start").and_then(Value::as_u64).unwrap_or(0) });
            // The stacks die with the daemon that started them, so after a restart there is none to remember.
            let alive = bus.as_ref().is_some_and(|b| proc::start_time(b.pid) == Some(b.start));
            let bus_lost = v["bus_lost"].as_bool().unwrap_or(false) || (bus.is_some() && !alive);
            let bus = bus.filter(|_| alive);
            let info = TokenInfo { agent: v["agent"].as_str().unwrap_or("agent").into(), app: v["app"].as_str().unwrap_or("").into(), at, bus, bus_lost };
            if now().saturating_sub(at) > 60 && proc::pids_with_token(&tok).is_empty() {
                // Nothing runs under it any more: its bus and profile go too.
                self.tokens.insert(tok.clone(), info);
                self.drop_token(&tok);
                continue;
            }
            self.tokens.entry(tok).or_insert(info);
        }
        self.save_tokens();
    }

    /// A launch token whose processes are all gone: stop its private bus, delete its profile.
    fn drop_token(&mut self, tok: &str) {
        let info = self.tokens.remove(tok);
        let kids = self.bus_children.remove(tok);
        // Stopping a stack waits for processes to exit; that happens after the lock is released.
        self.pending_stops.push(bus::StopJob { run: self.paths.run.clone(), token: tok.to_string(), kids, info: info.and_then(|i| i.bus) });
        let _ = std::fs::remove_dir_all(apps::profile_dir(&self.paths.state, tok));
    }

    /// Upkeep for launch tokens: those with no live process (and older than a minute) are dropped,
    /// and agent profiles older than a week that no live token owns are deleted.
    pub fn reap_tokens(&mut self) {
        let t = now();
        let gone: Vec<String> = self.tokens.iter().filter(|(tok, i)| t.saturating_sub(i.at) > 60 && proc::pids_with_token(tok).is_empty()).map(|(tok, _)| tok.clone()).collect();
        for tok in &gone {
            self.drop_token(tok);
        }
        if !gone.is_empty() {
            self.save_tokens();
        }
        let live: HashSet<String> = self.tokens.keys().map(|t| t[..8.min(t.len())].to_string()).collect();
        apps::prune_profiles(&self.paths.state, std::time::SystemTime::now(), 7 * 86_400, &live);
    }

    /// Windows the compositor has and the model lacks (an event missed), and the other way round.
    pub fn reconcile_windows(&mut self) {
        let Ok(clients) = self.try_clients() else { return };
        for c in &clients {
            if !self.model.is_tracked(&c.addr) {
                self.open_client(c, true);
            }
        }
        let live: HashSet<&str> = clients.iter().map(|c| c.addr.as_str()).collect();
        let gone: Vec<String> = self.model.window_ids().into_iter().filter(|w| !live.contains(*w)).map(String::from).collect();
        for w in gone {
            let _ = self.apply(Event::Close { window: w });
        }
    }

    /// R-F2 on Linux rests on `misc:focus_on_activate = false`: with it, an app asking for focus
    /// never gets it, so every activation the daemon sees is yours. Hyprland can lose the setting
    /// (a config reload, a stray eval), so it is read back and put back.
    pub fn ensure_focus_setting(&self) -> bool {
        match self.hypr.json("getoption misc:focus_on_activate") {
            Err(_) => false,
            Ok(v) => {
                let on = v["int"].as_i64() == Some(1) || v["bool"].as_bool() == Some(true);
                if on {
                    self.log("misc:focus_on_activate was on; turning it off again");
                    return self.hypr.eval("hl.config({ misc = { focus_on_activate = false } })").is_ok();
                }
                true
            }
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
                // An event can arrive after the focus has moved on (our own dispatches make some: a
                // monitor is focused for a moment to hide the agent workspace there). Only what is
                // true now counts; a newer event follows if focus really changed.
                let now_active = self.hypr.json("activewindow").ok().and_then(|v| v["address"].as_str().map(String::from));
                if now_active != addr {
                    self.log("stale activation ignored");
                    return;
                }
                let _ = self.apply(Event::Activate { window: addr, cause: Cause::User });
            }
            HyprEvent::MonitorAdded { name } => {
                if !self.model.monitors().any(|m| m == name) {
                    let _ = self.model.apply(Event::MonitorAdded { monitor: name.clone() });
                    let order: Vec<String> = {
                        let mut v: Vec<(u32, String)> = self.model.monitors().filter_map(|m| Some((self.model.slot(m)?, m.to_string()))).collect();
                        v.sort();
                        v.into_iter().map(|x| x.1).collect()
                    };
                    self.paths.write_atomic("monitors.json", &json!(order).to_string());
                    if !self.configure_hyprland(std::slice::from_ref(&name)) {
                        self.dirty = true;
                    }
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
                match self.special_shown() {
                    Ok(shown) => {
                        let _ = self.apply(Event::ObserveSpecial { shown });
                    }
                    Err(e) => {
                        // Not knowing is not "hidden": re-read before the next command.
                        self.log(&format!("cannot tell whether the agent workspace is showing: {e}"));
                        self.dirty = true;
                    }
                }
            }
            HyprEvent::ConfigReloaded => {
                if Self::include_installed() == Some(false) {
                    eprintln!("baneyspaces daemon: the BaneySpaces include is gone from hyprland.lua; exiting");
                    let _ = std::fs::remove_file(self.paths.ctl_socket());
                    exit_daemon(0);
                }
                if !self.configure_hyprland(&[]) {
                    self.dirty = true;
                }
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

/// The window `move` acts on when none is named: Hyprland's active window now. A failed query is an
/// error and an empty desktop is "nothing to move"; the model's idea of the front window is never used.
pub fn front_window(active: Result<Value, String>) -> Result<String, Envelope> {
    match active {
        Err(e) => Err(Envelope::err("compositor_error", format!("cannot tell which window is in front: {e}"), Retry::Safe, "Name the window with --window, or try again.")),
        Ok(v) => match v["address"].as_str().filter(|a| !a.is_empty()) {
            Some(a) => Ok(a.to_string()),
            None => Err(Envelope::err("not_found", "there is no front window to move", Retry::Safe, "Focus a window first, or name one with --window.")),
        },
    }
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

/// Whether a caller is refused the operations that belong to the user. Fails closed: with no peer
/// pid the caller is not known to be you.
pub fn refuses_user_op(peer: Option<u32>, is_agent: impl Fn(u32) -> bool) -> bool {
    peer.is_none_or(is_agent)
}

/// Operations that belong to you. A peer that is an agent (it carries a launch token we issued, or
/// is a registered agent process) is refused them. This guards against accidents, such as an
/// agent shell running `baneyspaces switch 3`; it is not a boundary against a hostile process of
/// your own user, which could unset its environment.
const USER_ONLY: &[&str] = &["switch", "move", "focus_monitor", "agent_show", "agent_hide", "agent_toggle", "agent_move", "agent_bring", "overview", "stop"];

impl Core {
    /// The launch this process belongs to lost its session bus when the daemon restarted.
    pub fn bus_lost_for(&self, pid: u32) -> bool {
        proc::token_of(pid).and_then(|t| self.tokens.get(&t)).is_some_and(|i| i.bus_lost)
    }

    /// The agent a control-socket peer is, if it is one: the name its launch was given.
    pub fn peer_agent(&self, pid: u32) -> Option<String> {
        if let Some(i) = proc::token_of(pid).and_then(|t| self.tokens.get(&t)) {
            return Some(i.agent.clone());
        }
        (self.model.agent_proc(pid).is_some() && self.model.is_agent_pid(pid, proc::start_time(pid).unwrap_or(0))).then(|| "agent".to_string())
    }

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
        // An unknown peer (SO_PEERCRED failed) is treated as an agent: the real CLI always has a pid.
        if refuses_user_op(peer, |p| c.is_agent_peer(p)) {
            let env = Envelope::err(
                "not_in_scope",
                format!("{op} is for you, not for an agent"),
                Retry::Never,
                "An agent drives only the agent workspace. Ask the user to do this.",
            );
            record(&c, &agent, op, peer, None, None, "ctl", &env);
            return env;
        }
        if let Err(env) = c.ensure_fresh() {
            return env;
        }
    }
    if op.starts_with("config_") || op.starts_with("theme_") {
        return crate::cfg::handle(shared, op, &args, req, peer);
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
                exit_daemon(0);
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
            let follow = !args.get("stay").and_then(Value::as_bool).unwrap_or(false);
            // With no window named, the front window is the one Hyprland says is active right now:
            // never one the model remembers (it may be stale), never a guess when the query fails.
            let window = match arg_str(&args, "window").map(String::from) {
                Some(w) => w,
                None => match front_window(c.hypr.json("activewindow")) {
                    Ok(w) => {
                        if !c.model.is_tracked(&w) {
                            if let Some(cl) = c.client(&w) {
                                c.open_client(&cl, true); // an event that has not been handled yet
                            }
                        }
                        w
                    }
                    Err(env) => return env,
                },
            };
            match c.apply(Event::Move { n, window: Some(window), follow }) {
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
        "agent_open" => agent_open(shared, &agent, &args, false),
        "test_open" => agent_open(shared, &agent, &args, true),
        "test_reap" => {
            // Test only: pretend every token is old, then run the upkeep that drops dead ones.
            let mut c = lock(shared);
            for t in c.tokens.values_mut() {
                t.at = 0;
            }
            c.reap_tokens();
            c.save_tokens();
            Envelope::ok(json!({ "tokens_left": c.tokens.len() }))
        }
        "test_stall" => {
            lock(shared).stall_ms = args["ms"].as_u64().unwrap_or(0);
            Envelope::ok(json!({ "stall_ms": args["ms"] }))
        }
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
            json!({ "window": w, "app": cl.map(|c| c.class.clone()).unwrap_or_default(), "title": cl.map(|c| c.title.clone()).unwrap_or_default(), "pid": pid, "drivable": pid.is_some_and(|p| c.model.agent_proc(p).is_some() && !c.bus_lost_for(p)) })
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

/// What an agent launch is: the named app with files, a command in a terminal, or (tests only) a
/// raw command that skips the allowlist.
enum Plan {
    Open { app: String, files: Vec<String> },
    Run { cmd: Vec<String>, dir: Option<String> },
    Test { app: String, args: Vec<String>, private_bus: bool },
}

struct Prepared {
    label: String,
    argv: Vec<String>,
}

fn bad_args(msg: impl Into<String>) -> Envelope {
    Envelope::err(
        "bad_arguments",
        msg,
        Retry::Never,
        "Name an allowlisted app, then files inside the handoff folder. No flags, no paths to programs, no URLs.",
    )
}

fn needs_sandbox(label: &str, why: &str) -> Envelope {
    Envelope::err(
        "needs_sandbox",
        format!("{label}: {why}"),
        Retry::Never,
        "Deny by default: an app that is not known to run as its own process could hand your launches to the agent's copy, or take the agent's request into yours. Use the app's files or command line instead; a sandbox for apps like this comes later.",
    )
    .with_data(json!({ "allowed": apps::allowed() }))
}

/// The system binary for an allowlisted name, or the refusal.
fn system_binary(app: &str) -> Result<std::path::PathBuf, Envelope> {
    let path = std::env::var("PATH").unwrap_or_default();
    match apps::resolve_system(app, &path) {
        apps::Resolve::Ok(p) => Ok(p),
        apps::Resolve::NotFound => Err(Envelope::err("not_found", format!("{app} is not installed"), Retry::Never, "Install it, or use another app on the list.")),
        apps::Resolve::NotSystem(p) => Err(needs_sandbox(app, &format!("what {app} resolves to here ({}) is not the system binary", p.display()))),
    }
}

/// Turns a plan into the command to run. Every flag in it was put there by BaneySpaces.
fn prepare(c: &Core, plan: &Plan, token: &str) -> Result<Prepared, Envelope> {
    let profile = apps::profile_dir(&c.paths.state, token);
    let with_policy = |name: &str, tail: Vec<String>| -> Result<Vec<String>, Envelope> {
        let bin = system_binary(name)?;
        let mut argv = vec![bin.to_string_lossy().into_owned()];
        match apps::known(name, &profile) {
            Some(apps::Launch::Separate) => {}
            Some(apps::Launch::Flags(f)) => {
                let _ = std::fs::create_dir_all(&profile);
                argv.extend(f);
            }
            None => return Err(needs_sandbox(name, "is not on the list of apps BaneySpaces can start as a separate process for an agent")),
        }
        argv.extend(tail);
        Ok(argv)
    };
    match plan {
        Plan::Open { app, files } => {
            if app.contains('/') || app.is_empty() || app.starts_with('-') {
                return Err(bad_args("name the app (such as foot), not a path or a flag"));
            }
            if apps::known(app, &profile).is_none() {
                return Err(needs_sandbox(app, "is not on the list of apps BaneySpaces can start as a separate process for an agent"));
            }
            if !files.is_empty() && !apps::takes_files(app) {
                return Err(bad_args(format!("{app} takes no files here: a terminal runs its argument as a command. Use `agent run` for commands.")));
            }
            let files = apps::check_files(files, &c.paths.handoff()).map_err(bad_args)?;
            Ok(Prepared { label: app.clone(), argv: with_policy(app, files)? })
        }
        Plan::Run { cmd, dir } => {
            let terminals: [(&str, &[&str]); 4] = [("foot", &["--"]), ("ghostty", &["-e"]), ("kitty", &[]), ("alacritty", &["-e"])];
            let path = std::env::var("PATH").unwrap_or_default();
            let Some((term, pre)) = terminals.iter().find(|(t, _)| matches!(apps::resolve_system(t, &path), apps::Resolve::Ok(_))) else {
                return Err(Envelope::err("not_found", "no system terminal found (foot, ghostty, kitty or alacritty)", Retry::Never, "Install one of them."));
            };
            let mut tail: Vec<String> = vec![];
            if let Some(d) = dir {
                match *term {
                    "foot" => tail.extend(["-D".into(), d.clone()]),
                    "kitty" => tail.extend(["-d".into(), d.clone()]),
                    "ghostty" => tail.push(format!("--working-directory={d}")),
                    _ => tail.extend(["--working-directory".into(), d.clone()]),
                }
            }
            tail.extend(pre.iter().map(|s| s.to_string()));
            tail.extend(cmd.iter().cloned());
            Ok(Prepared { label: (*term).to_string(), argv: with_policy(term, tail)? })
        }
        Plan::Test { app, args, .. } => {
            let exe = which(app).ok_or_else(|| Envelope::err("not_found", format!("no program {app:?} on PATH"), Retry::Never, "Give an executable name or a full path."))?;
            let mut argv = vec![exe.to_string_lossy().into_owned()];
            argv.extend(args.iter().cloned());
            Ok(Prepared { label: app.clone(), argv })
        }
    }
}

/// Starts the plan as a new process on the agent workspace, on a private session bus of its own,
/// then waits for a window of its own.
fn launch_on_agent(shared: &Shared, agent: &str, plan: Plan) -> Envelope {
    let token = match proc::random_token() {
        Ok(t) => t,
        Err(e) => return Envelope::err("internal", format!("no random bytes: {e}"), Retry::Never, ""),
    };
    let private_bus = !matches!(plan, Plan::Test { private_bus: false, .. });
    // 1. Under the lock, briefly: check the plan and read what is needed.
    let (prep, known, run_dir) = {
        let c = lock(shared);
        let prep = match prepare(&c, &plan, &token) {
            Ok(p) => p,
            Err(env) => {
                record(&c, agent, "open", None, None, None, "preflight", &env);
                return env;
            }
        };
        let known: HashSet<String> = c.model.window_ids().into_iter().map(String::from).collect();
        (prep, known, c.paths.run.clone())
    };
    let label = prep.label.clone();
    // 2. Without the lock: the bus stack takes a second or two to come up, and your keys must not wait
    //    for it. One session bus per launch: GApplication and friends forward over it, so with a bus
    //    of its own the agent's copy never meets yours, in either direction.
    let mut bus_env = String::new();
    let mut started = None;
    if private_bus {
        match bus::start(&run_dir, &token) {
            Ok((kids, info)) => {
                bus_env = format!("DBUS_SESSION_BUS_ADDRESS={} ", sh_quote(&info.addr));
                started = Some((kids, info));
            }
            Err(e) => {
                let env = Envelope::err("not_supported", format!("cannot give the app a session bus of its own, so it is not started: {e}"), Retry::Never, "Install dbus and at-spi2-core.");
                let c = lock(shared);
                record(&c, agent, "open", None, None, None, "preflight", &env);
                return env;
            }
        }
    }
    // 3. Under the lock again: record the launch and start the app. The app does not get the means to
    //    drive the compositor (its IPC signature): accident-proofing, like the rest.
    {
        let mut c = lock(shared);
        let (kids, bus_info) = match started {
            Some((k, i)) => (Some(k), Some(i)),
            None => (None, None),
        };
        if let Some(k) = kids {
            c.bus_children.insert(token.clone(), k);
        }
        let cmd = format!(
            "env -u HYPRLAND_INSTANCE_SIGNATURE -u HYPRLAND_CMD BANEYSPACES_AGENT_TOKEN={token} BANEYSPACES_AGENT_ID={} {bus_env}{}",
            sh_quote(agent),
            prep.argv.iter().map(|a| sh_quote(a)).collect::<Vec<_>>().join(" ")
        );
        c.tokens.insert(token.clone(), TokenInfo { agent: agent.into(), app: label.clone(), at: now(), bus: bus_info, bus_lost: false });
        c.save_tokens();
        let lua = format!("hl.dsp.exec_cmd({}, {{ workspace = \"{} silent\" }})", lua_str(&cmd), AGENT_SPECIAL);
        if let Err(e) = c.hypr.dispatch(&lua) {
            c.drop_token(&token);
            c.save_tokens();
            let env = hypr_failure(&e, "could not start the app");
            record(&c, agent, "open", None, None, None, "exec", &env);
            return env;
        }
    }
    let label = label.as_str();
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

fn str_list(a: &Value, k: &str) -> Vec<String> {
    a.get(k).and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(String::from).collect()
}

fn agent_open(shared: &Shared, agent: &str, args: &Value, test: bool) -> Envelope {
    let Some(app) = arg_str(args, "app") else {
        return Envelope::err("invalid_args", "an app is required", Retry::Never, "Example: baneyspaces agent open foot");
    };
    let list = str_list(args, "args");
    let plan = if test {
        Plan::Test { app: app.into(), args: list, private_bus: args["private_bus"].as_bool().unwrap_or(true) }
    } else {
        Plan::Open { app: app.into(), files: list }
    };
    launch_on_agent(shared, agent, plan)
}

/// `agent run`: a command in a terminal on the agent workspace. It is a shell with your uid, so
/// what it runs is not limited to the allowlist; the private session bus keeps its D-Bus apps from
/// meeting yours. Accident-proofing, not a boundary.
fn agent_run(shared: &Shared, agent: &str, args: &Value) -> Envelope {
    let cmd = str_list(args, "command");
    if cmd.is_empty() {
        return Envelope::err("invalid_args", "a command is required after --", Retry::Never, "Example: baneyspaces agent run --dir ~/Projects/x -- claude");
    }
    launch_on_agent(shared, agent, Plan::Run { cmd, dir: arg_str(args, "dir").map(String::from) })
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
    bus::install_signal_handlers();
    // One daemon at a time: the lock is held for the life of the process.
    let _lock = match take_lock(&paths) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("baneyspaces daemon: {e}");
            return 1;
        }
    };
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
        deferred: vec![],
        stall_ms: 0,
        bus_children: HashMap::new(),
        pending_stops: vec![],
    };
    let shared: Shared = Arc::new(Mutex::new(core));
    // Connect to Hyprland's events FIRST. They queue in the socket while the state is read, so a
    // window that opens, closes or moves in between is replayed afterwards and is never missed.
    let stream = match hypr.events() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("baneyspaces daemon: cannot read Hyprland events: {e}");
            return 1;
        }
    };
    {
        let mut c = lock(&shared);
        prune_if_due(&c.paths, now(), &c.last_prune);
        c.resync();
        c.reap_tokens();
        // Buses left by an earlier daemon (its directory gone, or no live token owns them) are killed.
        let tags: HashSet<String> = c.tokens.iter().filter(|(_, i)| i.bus.is_some()).map(|(t, _)| t[..8.min(t.len())].to_string()).collect();
        let swept = bus::sweep(&c.paths.run, &tags);
        bus::sweep_dirs(&c.paths.run, &tags);
        if swept > 0 {
            eprintln!("baneyspaces daemon: swept {swept} leftover bus process(es)");
        }
    }
    if let Some(ms) = std::env::var("BANEYSPACES_TEST_EVENT_DELAY_MS").ok().and_then(|v| v.parse::<u64>().ok()).filter(|_| std::env::var("BANEYSPACES_TEST_OPS").is_ok_and(|v| v == "1")) {
        std::thread::sleep(Duration::from_millis(ms)); // test only: events pile up before they are read
    }
    {
        let shared = shared.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stream).lines() {
                let Ok(line) = line else { break };
                let ev = parse_event(&line);
                if ev != HyprEvent::Other {
                    let after = ev.clone();
                    lock(&shared).on_hypr_event(ev);
                    // Hooks and the config re-apply run with the lock released.
                    match after {
                        HyprEvent::Workspace { id } if (1..=9).contains(&id) => crate::cfg::fire_hook("on_switch", vec![("BANEYSPACES_WORKSPACE", id.to_string())]),
                        HyprEvent::OpenWindow { addr } => crate::cfg::fire_hook("on_window_open", vec![("BANEYSPACES_WINDOW", addr)]),
                        HyprEvent::ConfigReloaded => crate::cfg::reload(&shared),
                        _ => {}
                    }
                }
            }
            eprintln!("baneyspaces daemon: Hyprland closed the event socket; exiting");
            exit_daemon(0);
        });
    }
    // Upkeep: forget agent processes that died or whose pid was reused, keep the focus setting
    // R-F2 rests on, and let the action log shed old records.
    {
        let shared = shared.clone();
        std::thread::spawn(move || {
          let mut tick = 0u32;
          loop {
            std::thread::sleep(Duration::from_secs(2));
            let stops = {
            let mut c = lock(&shared);
            c.reconcile_agents();
            c.reconcile_windows();
            if !c.ensure_focus_setting() {
                c.dirty = true; // the focus rule cannot be confirmed: commands wait until it can
            }
            tick += 1;
            if tick % 5 == 0 {
                c.reap_tokens();
            }
            prune_if_due(&c.paths, now(), &c.last_prune);
            std::mem::take(&mut c.pending_stops)
            };
            // Taking a stack down waits for its processes to exit: with the lock released.
            for job in stops {
                job.run();
            }
          }
        });
    }
    crate::cfg::start(&shared, &paths, Some(hypr.clone()));
    eprintln!("baneyspaces daemon: ready ({})", sock.display());
    for conn in listener.incoming().flatten() {
        let shared = shared.clone();
        std::thread::spawn(move || serve_conn(shared, conn));
    }
    0
}

/// An exclusive, non-blocking lock on a file next to the socket. Two daemons starting together
/// (the autostart fires on start and on reload) cannot both pass the check-then-bind that follows.
pub fn take_lock(paths: &Paths) -> Result<std::fs::File, String> {
    use std::os::unix::io::AsRawFd;
    let f = std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(paths.run.join("daemon.lock")).map_err(|e| format!("cannot open the lock file: {e}"))?;
    // SAFETY: a valid fd from the file just opened.
    if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err("already running (the lock is held)".into());
    }
    Ok(f)
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
        let hypr = Hypr::at(paths.run.join("no-hyprland"));
        test_core_on(paths, hypr)
    }

    fn test_core_on(paths: Paths, hypr: Hypr) -> Core {
        Core {
            model: Model::new(),
            hypr,
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
            deferred: vec![],
            stall_ms: 0,
            bus_children: HashMap::new(),
            pending_stops: vec![],
        }
    }

    /// A stand-in for Hyprland's socket: answers each request with `answer(request)` and logs it.
    fn fake_hypr(tag: &str, answer: impl Fn(&str) -> String + Send + 'static) -> (Core, std::sync::Arc<Mutex<Vec<String>>>) {
        let paths = temp_paths(tag);
        let dir = paths.run.join("hypr");
        std::fs::create_dir_all(&dir).unwrap();
        let l = UnixListener::bind(dir.join(".socket.sock")).unwrap();
        let log = std::sync::Arc::new(Mutex::new(Vec::<String>::new()));
        let seen = log.clone();
        std::thread::spawn(move || {
            for conn in l.incoming().flatten() {
                let mut req = String::new();
                let mut c = conn;
                let _ = c.read_to_string(&mut req);
                seen.lock().unwrap().push(req.clone());
                let _ = c.write_all(answer(&req).as_bytes());
            }
        });
        (test_core_on(paths, Hypr::at(dir)), log)
    }

    fn mon(id: i64, name: &str, focused: bool, ws: i64) -> Value {
        json!({ "id": id, "name": name, "focused": focused, "disabled": false, "activeWorkspace": { "id": ws, "name": ws.to_string() }, "specialWorkspace": { "name": "" } })
    }

    #[test]
    fn a_resync_never_takes_a_workspace_off_the_display_you_are_looking_at() {
        // A shows 2, B shows an empty workspace 10 outside the nine. The fresh model guesses A=1, B=2;
        // acting on that guess would move workspace 2 onto B.
        let monitors = json!([mon(0, "A", true, 2), mon(1, "B", false, 10)]).to_string();
        let spaces = json!([{ "id": 2, "windows": 0, "ispersistent": false, "monitor": "A" }, { "id": 10, "windows": 0, "ispersistent": false, "monitor": "B" }]).to_string();
        let (mut c, log) = fake_hypr("resync-guess", move |r| match r {
            "j/monitors" => monitors.clone(),
            "j/workspaces" => spaces.clone(),
            "j/clients" => "[]".into(),
            "j/activewindow" => "{}".into(),
            r if r.starts_with("j/getoption") => "{\"int\":0}".into(),
            _ => "ok".into(),
        });
        c.resync();
        let log = log.lock().unwrap();
        assert!(!log.iter().any(|r| r.contains("workspace.move")), "{log:?}");
        assert_eq!(c.model.current("A"), Some(2), "what A shows is left alone");
        assert!(log.iter().any(|r| r.contains("focus({ workspace = \"1\" })")), "B is given a free workspace: {log:?}");
        assert!(!c.dirty);
    }

    #[test]
    fn an_agent_window_in_front_at_resync_is_handled_and_the_users_window_put_back() {
        let monitors = json!([mon(0, "A", true, 1)]).to_string();
        let clients = json!([
            { "address": "0x1", "pid": 11, "workspace": { "id": 1, "name": "1" }, "monitor": 0, "class": "foot", "title": "mine", "mapped": true },
            { "address": "0xa", "pid": 22, "workspace": { "id": -98, "name": "special:agent" }, "monitor": 0, "class": "foot", "title": "agent's", "mapped": true }
        ])
        .to_string();
        let (mut c, log) = fake_hypr("resync-guard", move |r| match r {
            "j/monitors" => monitors.clone(),
            "j/workspaces" => "[]".into(),
            "j/clients" => clients.clone(),
            "j/activewindow" => "{\"address\":\"0xa\"}".into(),
            r if r.starts_with("j/getoption") => "{\"int\":0}".into(),
            _ => "ok".into(),
        });
        c.resync();
        assert!(log.lock().unwrap().iter().any(|r| r.contains("focus({ window = \"address:0x1\" })")), "{:?}", log.lock().unwrap());
        assert_eq!(c.model.refused(), 1);
        assert!(!c.dirty);
    }

    #[test]
    fn an_agent_workspace_found_showing_at_start_is_hidden_again() {
        let mut m = mon(0, "A", true, 1);
        m["specialWorkspace"] = json!({ "name": "special:agent" });
        let monitors = json!([m]).to_string();
        let (mut c, log) = fake_hypr("resync-special", move |r| match r {
            "j/monitors" => monitors.clone(),
            "j/workspaces" | "j/clients" => "[]".into(),
            "j/activewindow" => "{}".into(),
            r if r.starts_with("j/getoption") => "{\"int\":0}".into(),
            _ => "ok".into(),
        });
        c.resync();
        assert!(log.lock().unwrap().iter().any(|r| r.contains("toggle_special")), "{:?}", log.lock().unwrap());
    }

    #[test]
    fn a_setup_failure_keeps_the_model_dirty_and_commands_wait() {
        let monitors = json!([mon(0, "A", true, 1)]).to_string();
        let (mut c, _log) = fake_hypr("config-fail", move |r| match r {
            "j/monitors" => monitors.clone(),
            "j/workspaces" | "j/clients" => "[]".into(),
            "j/activewindow" => "{}".into(),
            r if r.starts_with("/eval") => "error: no".into(),
            _ => "ok".into(),
        });
        c.resync();
        assert!(c.dirty, "animations and focus_on_activate could not be set");
        let e = c.ensure_fresh().unwrap_err().error.unwrap();
        assert_eq!((e.code.as_str(), e.retry), ("compositor_error", Retry::After));
    }

    #[test]
    fn a_failed_monitors_query_never_reads_as_the_agent_workspace_being_hidden() {
        let (mut c, log) = fake_hypr("special-query", |r| if r == "j/monitors" { "not json".into() } else { "ok".into() });
        assert!(c.special_shown().is_err());
        let r = c.exec(&[Effect::ShowAgent]);
        assert!(r.is_err(), "no toggle on a guess");
        assert!(!log.lock().unwrap().iter().any(|r| r.contains("toggle_special")));
    }

    #[test]
    fn move_acts_on_the_window_in_front_now_or_on_nothing() {
        assert_eq!(front_window(Ok(json!({"address":"0x7"}))).unwrap(), "0x7");
        assert_eq!(front_window(Ok(json!({}))).unwrap_err().error.unwrap().code, "not_found");
        assert_eq!(front_window(Ok(json!({"address":""}))).unwrap_err().error.unwrap().code, "not_found");
        let e = front_window(Err("timed out".into())).unwrap_err().error.unwrap();
        assert_eq!((e.code.as_str(), e.retry), ("compositor_error", Retry::Safe));
    }

    #[test]
    fn issued_tokens_survive_a_restart_privately_and_stale_ones_do_not() {
        use std::os::unix::fs::PermissionsExt;
        let mut a = test_core("tokens");
        let me = proc::random_token().unwrap();
        a.tokens.insert("fresh".into(), TokenInfo { agent: "claude".into(), app: "foot".into(), at: now(), bus: None, bus_lost: false });
        a.tokens.insert("old-and-dead".into(), TokenInfo { agent: "x".into(), app: "y".into(), at: now() - 3600, bus: None, bus_lost: false });
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
    fn rebuilding_the_model_dispatches_nothing_until_it_is_done() {
        let mut c = test_core("resync");
        c.resyncing = true;
        c.apply(Event::MonitorAdded { monitor: "A".into() }).unwrap();
        // The second display's workspace is a corrective effect: collected, not sent.
        let fx = c.apply(Event::MonitorAdded { monitor: "B".into() }).unwrap();
        assert_eq!(fx.len(), 1);
        assert_eq!(c.deferred.len(), 1);
        // Sending it now (there is no Hyprland behind this fake) fails, and that is recorded rather than lost.
        c.resyncing = false;
        let todo = std::mem::take(&mut c.deferred);
        assert!(c.exec(&todo).is_err());
    }

    #[test]
    fn a_launch_profile_is_deleted_with_its_token() {
        let mut c = test_core("profile");
        let tok = "abcd1234efgh5678";
        c.tokens.insert(tok.into(), TokenInfo { agent: "a".into(), app: "chromium".into(), at: 0, bus: None, bus_lost: false });
        let prof = apps::profile_dir(&c.paths.state, tok);
        std::fs::create_dir_all(prof.join("Default")).unwrap();
        std::fs::write(prof.join("Default/Cookies"), "x").unwrap();
        c.drop_token(tok);
        assert!(!prof.exists(), "the profile goes with the token");
        assert!(!c.tokens.contains_key(tok));
    }

    #[test]
    fn a_model_that_cannot_be_refreshed_refuses_the_command() {
        let mut c = test_core("dirty");
        c.dirty = true; // Hyprland is unreachable behind this fake
        let e = c.ensure_fresh().unwrap_err();
        let er = e.error.unwrap();
        assert_eq!((er.code.as_str(), er.retry), ("compositor_error", Retry::After));
        assert!(c.dirty, "and it stays dirty: the next command re-reads again");
    }

    #[test]
    fn an_unknown_caller_is_refused_the_users_operations() {
        assert!(refuses_user_op(None, |_| false), "no peer pid: not known to be you");
        assert!(refuses_user_op(Some(7), |p| p == 7));
        assert!(!refuses_user_op(Some(8), |p| p == 7));
    }

    #[test]
    fn only_one_daemon_can_hold_the_lock() {
        let p = temp_paths("lock");
        let first = take_lock(&p).unwrap();
        assert!(take_lock(&p).is_err(), "a second daemon must not get past the lock");
        drop(first);
        assert!(take_lock(&p).is_ok(), "and it is free again once the first is gone");
    }

    #[test]
    fn a_half_done_switch_is_never_reported_as_having_changed_nothing() {
        let steps = show_steps("B", 4, Some("A"), Some("A")); // focus B, move the workspace, focus it
        assert_eq!(steps.len(), 3);
        for fail_at in 0..3usize {
            let mut seen = 0;
            let r = run_steps(&steps, &mut |_| {
                let i = seen;
                seen += 1;
                if i == fail_at { Err(HyprError::Refused("no".into())) } else { Ok(()) }
            });
            let (_, partial) = r.unwrap_err();
            assert_eq!(partial, fail_at > 0, "failing step {fail_at}");
        }
        // And that flag is what makes the envelope's retry `never`.
        let e = ApplyError::Compositor { err: HyprError::Refused("no".into()), delivered_any: true }.envelope();
        assert_eq!(e.error.unwrap().retry, Retry::Never);
        assert_eq!(show_steps("A", 4, None, Some("A")).len(), 1, "nothing to move and already focused: one dispatch");
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
