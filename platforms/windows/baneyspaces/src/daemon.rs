//! `baneyspaces daemon`: the model driven by what Windows reports (WinEvents and a poll), the
//! chords the keyboard hook swallows, the control pipe the CLI talks to, `state.json`, the agent
//! workspace and the agent action log.
//!
//! The model decides; this file only carries it out. Where a window should be is derived, not
//! replayed: after every event each tracked window is compared with what the model says (shown on
//! some display, or not) and hidden or shown to match. That makes every step idempotent, so a
//! missed event costs one poll interval, not a lost window.

use crate::agent;
use crate::apps;
use crate::cloak::{self, Cloaker};
use crate::cmdline;
use crate::engine::{self, snapshot_of};
use crate::hidden::{self, Hidden, HiddenSet, How, Recovery};
use crate::hook::{self, Msg};
use crate::ipc;
use crate::keys;
use crate::paths::Paths;
use crate::settings;
use crate::winapi::{self, hwnd as to_hwnd, id_of, window_name};
use baneyspaces_core::agent::{check_scope, ActionRecord, WindowFacts};
use baneyspaces_core::envelope::{Envelope, Retry};
use baneyspaces_core::model::{Cause, Effect, Event, Home, Model, ModelError};
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashMap};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const AGENT_WORKSPACE: &str = "cloaked-off-your-screen (ghost: transparent, click-through, unfocusable)";

pub fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

#[derive(Clone, Debug)]
pub struct WinInfo {
    pub hwnd: i64,
    pub pid: u32,
    pub start: u64,
    pub title: String,
    pub app: String,
}

#[derive(Clone, Debug)]
pub struct SnapInfo {
    pub window: String,
    pub pid: u32,
    pub start: u64,
}

pub struct Core {
    pub model: Model,
    pub paths: Paths,
    pub hidden: HiddenSet,
    pub info: HashMap<String, WinInfo>,
    pub jobs: Vec<(String, agent::Job)>,
    pub snaps: HashMap<String, SnapInfo>,
    pub overview_shown: bool,
    pub events_seen: u64,
    pub started: u64,
    pub trace: bool,
    pub our_pid: u32,
    pub problems: Vec<String>,
    pub settings: serde_json::Map<String, Value>,
    pub tx: Sender<Msg>,
}

pub type Shared = Arc<Mutex<Core>>;

pub fn lock(s: &Shared) -> MutexGuard<'_, Core> {
    s.lock().unwrap_or_else(|p| p.into_inner())
}

static LOG: OnceLock<Mutex<std::fs::File>> = OnceLock::new();

/// A line of daemon output: to the log file when there is one (the daemon has no console then),
/// else to stderr. Never panics: a closed console must not take the daemon down.
pub fn say(msg: &str) {
    if let Some(f) = LOG.get() {
        if let Ok(mut f) = f.lock() {
            let _ = writeln!(f, "{msg}");
        }
    } else {
        let _ = writeln!(std::io::stderr(), "{msg}");
    }
}

static STOPPING: AtomicBool = AtomicBool::new(false);
static FINISHED: AtomicBool = AtomicBool::new(false);
static CTRL_TX: OnceLock<Sender<Msg>> = OnceLock::new();

impl Core {
    fn log(&self, msg: &str) {
        if self.trace {
            say(&format!("[baneyspaces] {msg}"));
        }
    }

    // ---- monitors ------------------------------------------------------------------------

    pub fn sync_monitors(&mut self) {
        let now: Vec<String> = winapi::monitors().into_iter().map(|m| m.name).collect();
        if now.is_empty() {
            return;
        }
        let known: Vec<String> = self.model.monitors().map(String::from).collect();
        for m in &now {
            if !known.contains(m) {
                let _ = self.apply(Event::MonitorAdded { monitor: m.clone() });
            }
        }
        for m in &known {
            if !now.contains(m) {
                let _ = self.apply(Event::MonitorRemoved { monitor: m.clone() });
            }
        }
        if self.model.focused_monitor().is_none() {
            if let Some(m) = now.first() {
                let _ = self.apply(Event::ObserveFocusMonitor { monitor: m.clone() });
            }
        }
    }

    // ---- the model's effects -------------------------------------------------------------

    pub fn apply(&mut self, ev: Event) -> Result<Vec<Effect>, ModelError> {
        self.events_seen += 1;
        let effects = self.model.apply(ev)?;
        self.exec(&effects);
        Ok(effects)
    }

    /// Carries out effects. Where windows are is derived by `sync_visibility`; only focus is
    /// an action. Every effect is idempotent.
    fn exec(&mut self, effects: &[Effect]) {
        for e in effects {
            self.log(&format!("effect {e:?}"));
        }
        self.sync_visibility();
        // The last focus effect wins: it is where the model says the front should be.
        let focus = effects.iter().rev().find_map(|e| match e {
            Effect::FocusWindow { window } => Some(window.clone()),
            _ => None,
        });
        if let Some(w) = focus {
            if let Some(i) = self.info.get(&w) {
                if !self.hidden.contains(i.hwnd) {
                    winapi::set_foreground(to_hwnd(i.hwnd));
                }
            }
        }
        self.keep_focus_off_hidden_windows();
        self.persist();
    }

    /// Focus never rests on a window that is out of sight (R-E1): typing would go to it.
    fn keep_focus_off_hidden_windows(&mut self) {
        let fg = id_of(winapi::foreground());
        let Some(h) = self.hidden.get(fg).cloned() else { return };
        if h.how == How::Ghost && self.model.agent_shown() {
            return;
        }
        let target = self.model.active().and_then(|w| self.info.get(w)).filter(|i| !self.hidden.contains(i.hwnd)).map(|i| to_hwnd(i.hwnd));
        winapi::set_foreground(target.unwrap_or_else(winapi::shell_window));
    }

    fn visible_workspaces(&self) -> BTreeSet<u8> {
        self.model.monitors().filter_map(|m| self.model.current(m)).filter(|n| *n != 0).collect()
    }

    /// Hides and shows windows so what you see is what the model says. Shows first, so a switch
    /// never flashes the desktop between two workspaces.
    pub fn sync_visibility(&mut self) {
        let shown = self.visible_workspaces();
        let agent_shown = self.model.agent_shown();
        #[derive(PartialEq)]
        enum Want {
            Visible,
            HideUser,
            HideAgent,
        }
        let mut wants: Vec<(String, WinInfo, Want)> = vec![];
        for (id, i) in &self.info {
            let w = match self.model.home(id) {
                Some(Home::Workspace { n }) => {
                    if shown.contains(n) {
                        Want::Visible
                    } else {
                        Want::HideUser
                    }
                }
                Some(Home::Agent) => {
                    if agent_shown {
                        Want::Visible
                    } else {
                        Want::HideAgent
                    }
                }
                None => continue,
            };
            wants.push((id.clone(), i.clone(), w));
        }
        let mut cloaker: Option<Option<Cloaker>> = None;
        let get = |c: &mut Option<Option<Cloaker>>| -> Option<*const Cloaker> {
            if c.is_none() {
                *c = Some(Cloaker::new().ok());
            }
            c.as_ref().and_then(|o| o.as_ref()).map(|x| x as *const Cloaker)
        };
        // 1. Show.
        for (_, i, w) in &wants {
            if *w != Want::Visible {
                continue;
            }
            if let Some(e) = self.hidden.get(i.hwnd).cloned() {
                let c = get(&mut cloaker);
                cloak::show(&e, c.map(|p| unsafe { &*p }));
                self.hidden.remove(i.hwnd);
                self.persist();
            }
        }
        // 2. Hide.
        for (_, i, w) in &wants {
            let h = to_hwnd(i.hwnd);
            if !winapi::exists(h) {
                continue;
            }
            match w {
                Want::Visible => {}
                Want::HideUser => {
                    match self.hidden.get(i.hwnd).map(|e| e.how) {
                        Some(How::Cloak) | Some(How::Park) => continue,
                        Some(How::Ghost) => {
                            let e = self.hidden.get(i.hwnd).cloned().unwrap();
                            cloak::show(&e, None);
                            self.hidden.remove(i.hwnd);
                        }
                        None => {}
                    }
                    // Write ahead: the entry is on disk before the window moves.
                    self.hidden.insert(Hidden { hwnd: i.hwnd, pid: i.pid, start: i.start, how: How::Cloak, rect: winapi::rect(h), agent: false, ex_style: None });
                    self.persist();
                    let c = get(&mut cloaker);
                    let how = cloak::hide_user(h, c.map(|p| unsafe { &*p }));
                    if how != How::Cloak {
                        self.problems.push(format!("cloak refused for {}: parked it instead", window_name(i.hwnd)));
                        if let Some(mut e) = self.hidden.remove(i.hwnd) {
                            e.how = how;
                            self.hidden.insert(e);
                        }
                        self.persist();
                    }
                }
                Want::HideAgent => {
                    match self.hidden.get(i.hwnd).map(|e| e.how) {
                        Some(How::Ghost) => continue,
                        Some(_) => {
                            let e = self.hidden.get(i.hwnd).cloned().unwrap();
                            let c = get(&mut cloaker);
                            cloak::show(&e, c.map(|p| unsafe { &*p }));
                            self.hidden.remove(i.hwnd);
                        }
                        None => {}
                    }
                    let ex = winapi::ex_style(h);
                    self.hidden.insert(Hidden { hwnd: i.hwnd, pid: i.pid, start: i.start, how: How::Ghost, rect: winapi::rect(h), agent: true, ex_style: Some(ex) });
                    self.persist();
                    cloak::ghost(h);
                    // It started minimized so it never drew on your screen; the engine cannot read
                    // a minimized window, so it is restored now that it is invisible.
                    if winapi::is_iconic(h) {
                        winapi::restore_minimized_no_activate(h);
                    }
                }
            }
        }
    }

    pub fn persist(&self) {
        let mut v = self.model.view();
        v["version"] = json!(1);
        v["platform"] = json!("windows");
        v["agent_workspace"] = json!(AGENT_WORKSPACE);
        v["hiding"] = json!({ "your_workspaces": "shell cloak (IApplicationView::SetCloak), parked off-screen if refused", "agent_workspace": "ghost (transparent, click-through, no focus)" });
        v["hidden"] = self.hidden.to_json();
        let procs: Vec<Value> = self.model.agent_pids().into_iter().map(|(p, s)| json!({ "pid": p, "start": s })).collect();
        v["agents"] = json!(procs);
        v["settings"] = Value::Object(self.settings.clone());
        v["overview"] = json!({ "shown": self.overview_shown });
        v["daemon"] = json!({ "pid": self.our_pid, "started": self.started, "events": self.events_seen, "problems": self.problems });
        self.paths.write_atomic("state.json", &serde_json::to_string_pretty(&v).unwrap_or_default());
    }

    // ---- windows -------------------------------------------------------------------------

    fn facts_of(&self, hwnd: i64) -> WinInfo {
        let h = to_hwnd(hwnd);
        let pid = winapi::real_pid(h);
        WinInfo { hwnd, pid, start: winapi::process_start(pid), title: winapi::title(h), app: winapi::process_name(pid) }
    }

    /// Registers `pid` as an agent process if it is one BaneySpaces started (or a descendant).
    fn adopt_agent_pid(&mut self, pid: u32) -> bool {
        if self.model.agent_proc(pid).is_some() {
            return true;
        }
        let Some(agent) = self.jobs.iter().find(|(_, j)| agent::in_job(j, pid)).map(|(a, _)| a.clone()) else {
            return false;
        };
        self.log(&format!("pid {pid} is in {agent}'s job"));
        let start = winapi::process_start(pid);
        let _ = self.apply(Event::AgentRegister { pid, start });
        true
    }

    /// One window appeared. `existing` windows (found at start) are mirrored where they are; a
    /// new one follows the placement rules.
    fn open_window(&mut self, hwnd: i64, existing: bool) {
        let id = window_name(hwnd);
        if self.model.is_tracked(&id) {
            return;
        }
        let info = self.facts_of(hwnd);
        if info.pid == 0 || info.pid == self.our_pid {
            return;
        }
        self.adopt_agent_pid(info.pid);
        let monitor = winapi::monitor_name_of(to_hwnd(hwnd)).filter(|m| self.model.monitors().any(|x| x == m));
        self.info.insert(id.clone(), info.clone());
        if existing {
            // Already open: exactly where it is. Agent windows (parked from a previous run) stay parked.
            let on_agent = self.model.agent_proc(info.pid).is_some() || self.hidden.get(hwnd).is_some_and(|h| h.how == How::Ghost);
            let workspace = if on_agent { None } else { monitor.as_deref().and_then(|m| self.model.current(m)).filter(|n| *n != 0).or(Some(1)) };
            let _ = self.apply(Event::ObserveWindow { window: id, pid: info.pid, start: info.start, app: info.app, workspace });
            return;
        }
        let _ = self.apply(Event::Open { window: id.clone(), pid: info.pid, start: info.start, app: info.app, monitor, workspace: None });
        if self.model.agent_proc(info.pid).is_some() && !matches!(self.model.home(&id), Some(Home::Agent)) {
            let _ = self.apply(Event::AgentSend { window: id });
        }
    }

    fn close_window(&mut self, id: &str) {
        if let Some(i) = self.info.remove(id) {
            self.hidden.remove(i.hwnd);
        }
        let _ = self.apply(Event::Close { window: id.to_string() });
    }

    /// Compares the windows that exist with the ones tracked; the source of truth for open and close.
    pub fn resync_windows(&mut self, existing: bool) {
        let mut live: Vec<i64> = vec![];
        for h in winapi::list_top_level() {
            let id = id_of(h);
            if winapi::is_manageable(h, self.hidden.contains(id), self.our_pid) {
                live.push(id);
            }
        }
        let live_set: BTreeSet<i64> = live.iter().copied().collect();
        let gone: Vec<String> = self.info.iter().filter(|(_, i)| !live_set.contains(&i.hwnd)).map(|(id, _)| id.clone()).collect();
        for id in gone {
            // A window we hid is still "visible" to Windows; if it is not in the list it is really gone
            // (or turned into something we would not manage, like a tool window).
            self.close_window(&id);
        }
        for hwnd in live {
            self.open_window(hwnd, existing);
        }
        // Titles change; keep `ls` honest.
        let ids: Vec<(String, i64)> = self.info.iter().map(|(k, v)| (k.clone(), v.hwnd)).collect();
        for (id, hwnd) in ids {
            let t = winapi::title(to_hwnd(hwnd));
            if let Some(i) = self.info.get_mut(&id) {
                i.title = t;
            }
        }
    }

    /// The foreground changed. Only an activation you caused may take you to another workspace (R-F1,
    /// R-F2): Windows gives no cause, so input in the last 300 ms is yours, anything else is the app's.
    fn on_foreground(&mut self, hwnd: i64) {
        let id = window_name(hwnd);
        if !self.model.is_tracked(&id) || self.model.active() == Some(id.as_str()) {
            return;
        }
        let cause = if winapi::idle_ms() < 300 { Cause::User } else { Cause::App };
        self.log(&format!("foreground {id} cause {cause:?}"));
        let _ = self.apply(Event::Activate { window: Some(id), cause });
    }

    fn on_win_event(&mut self, event: u32, hwnd: i64) {
        match event {
            hook::EVENT_SYSTEM_FOREGROUND => {
                // A new window may take the foreground before we saw it open.
                if !self.model.is_tracked(&window_name(hwnd)) && winapi::is_manageable(to_hwnd(hwnd), false, self.our_pid) {
                    self.open_window(hwnd, false);
                }
                self.on_foreground(hwnd)
            }
            hook::EVENT_OBJECT_CREATE | hook::EVENT_OBJECT_SHOW | hook::EVENT_SYSTEM_MINIMIZEEND => {
                if !self.model.is_tracked(&window_name(hwnd)) && winapi::is_manageable(to_hwnd(hwnd), false, self.our_pid) {
                    self.open_window(hwnd, false);
                }
            }
            hook::EVENT_OBJECT_DESTROY | hook::EVENT_OBJECT_HIDE => {
                let id = window_name(hwnd);
                if self.model.is_tracked(&id) && !winapi::exists(to_hwnd(hwnd)) {
                    self.close_window(&id);
                }
            }
            _ => {}
        }
    }

    /// The window you mean when you did not name one: the front window, if it is one of ours.
    fn front_window(&self) -> Option<String> {
        let id = window_name(id_of(winapi::foreground()));
        self.model.is_tracked(&id).then_some(id)
    }
}

// ---- requests -----------------------------------------------------------------------------

fn arg_str<'a>(a: &'a Value, k: &str) -> Option<&'a str> {
    a.get(k).and_then(Value::as_str)
}

fn arg_n(a: &Value) -> Result<u8, Envelope> {
    a.get("n")
        .and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))
        .and_then(|n| u8::try_from(n).ok())
        .ok_or_else(|| Envelope::err("invalid_args", "a workspace number 1 to 9 is required", Retry::Never, "Example: baneyspaces switch 3"))
}

fn effects_json(fx: &[Effect]) -> Value {
    serde_json::to_value(fx).unwrap_or(Value::Null)
}

fn model_err(e: ModelError) -> Envelope {
    Envelope::from_model(&e)
}

/// Operations only you may ask for. An agent's process (one BaneySpaces started, or anything it
/// started) is refused: agents never change your workspaces, your settings or the daemon.
const USER_OPS: &[&str] = &["switch", "move", "focus_monitor", "overview", "agent_show", "agent_hide", "agent_toggle", "agent_move", "agent_bring", "set", "quit"];

/// Is the process on the other end of the pipe an agent's? By pid, against the model and the jobs.
fn peer_is_agent(c: &Core, pid: u32) -> bool {
    pid != 0 && (c.model.agent_proc(pid).is_some() || c.jobs.iter().any(|(_, j)| agent::in_job(j, pid)))
}

pub fn handle(shared: &Shared, req: &Value) -> Envelope {
    let op = req["op"].as_str().unwrap_or("");
    if USER_OPS.contains(&op) {
        let peer = req["_peer_pid"].as_u64().unwrap_or(0) as u32;
        if peer_is_agent(&lock(shared), peer) {
            return Envelope::err("not_in_scope", format!("{op} is for you, not an agent: it was refused"), Retry::Never, "Agents work inside the agent workspace; only the person using this PC changes workspaces and settings.");
        }
    }
    let args = req.get("args").cloned().unwrap_or_else(|| json!({}));
    let agent = req["agent"].as_str().unwrap_or("agent").to_string();
    match op {
        "ping" => Envelope::ok(json!({ "pong": true, "pid": std::process::id() })),
        "quit" => {
            let c = lock(shared);
            let _ = c.tx.send(Msg::Quit);
            Envelope::ok(json!({ "stopping": true, "note": "your windows are being put back; agent windows stay hidden" }))
        }
        "switch" => {
            let n = match arg_n(&args) {
                Ok(n) => n,
                Err(e) => return e,
            };
            let mut c = lock(shared);
            c.sync_monitors();
            match c.apply(Event::Switch { n }) {
                Ok(fx) => Envelope::ok(json!({ "workspace": n, "effects": effects_json(&fx) })),
                Err(e) => model_err(e),
            }
        }
        "move" => {
            let n = match arg_n(&args) {
                Ok(n) => n,
                Err(e) => return e,
            };
            let mut c = lock(shared);
            let follow = !args.get("stay").and_then(Value::as_bool).unwrap_or(false);
            let window = match resolve_window(&c, &args) {
                Ok(w) => w,
                Err(e) => return e,
            };
            match c.apply(Event::Move { n, window, follow }) {
                Ok(fx) => Envelope::ok(json!({ "workspace": n, "follow": follow, "effects": effects_json(&fx) })),
                Err(e) => model_err(e),
            }
        }
        "focus_monitor" => {
            let mut c = lock(shared);
            match c.apply(Event::FocusMonitor { monitor: arg_str(&args, "monitor").unwrap_or("").into() }) {
                Ok(fx) => Envelope::ok(json!({ "effects": effects_json(&fx) })),
                Err(e) => model_err(e),
            }
        }
        "get" => {
            let c = lock(shared);
            match arg_str(&args, "key") {
                None => Envelope::ok(Value::Object(c.settings.clone())),
                Some(k) => match c.settings.get(k) {
                    Some(v) => Envelope::ok(json!({ k: v })),
                    None => Envelope::err("invalid_args", format!("unknown setting {k:?}"), Retry::Never, format!("The settings are {}.", settings::KEYS.join(", "))),
                },
            }
        }
        "set" => {
            let (Some(k), Some(v)) = (arg_str(&args, "key"), arg_str(&args, "value")) else {
                return Envelope::err("invalid_args", "usage: set <key> <value>", Retry::Never, "Example: baneyspaces set dock.enabled false");
            };
            match settings::validate(k, v) {
                Err(m) => Envelope::err("invalid_args", m, Retry::Never, format!("The settings are {}.", settings::KEYS.join(", "))),
                Ok(val) => {
                    let mut c = lock(shared);
                    c.settings.insert(k.to_string(), val.clone());
                    let text = serde_json::to_string_pretty(&Value::Object(c.settings.clone())).unwrap_or_default();
                    c.paths.write_atomic("settings.json", &text);
                    c.persist();
                    Envelope::ok(json!({ k: val, "note": "stored; the themed UI and the dock arrive in Windows part 2" }))
                }
            }
        }
        "state" => {
            let c = lock(shared);
            let mut v = c.model.view();
            v["version"] = json!(1);
            v["platform"] = json!("windows");
            v["hidden"] = c.hidden.to_json();
            Envelope::ok(v)
        }
        "ls" => Envelope::ok(ls(&lock(shared))),
        "overview" => {
            let mut c = lock(shared);
            c.overview_shown = !c.overview_shown;
            c.persist();
            Envelope::ok(json!({ "shown": c.overview_shown, "note": "recorded in state.json; the overview itself arrives in part 2" }))
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
                Err(e) => model_err(e),
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
                Err(e) => model_err(e),
            }
        }
        "agent_status" | "agent_windows" => Envelope::ok(agent_status(&lock(shared))),
        "agent_open" => agent_open(shared, &agent, &args),
        "agent_run" => agent_run(shared, &agent, &args),
        "agent_log" => agent_log(&lock(shared), &args),
        "hands" => hands(shared, &agent, &args),
        _ => Envelope::err("invalid_args", format!("unknown operation {op:?}"), Retry::Never, "Run `baneyspaces help`."),
    }
}

/// `--window w-123` (or a bare hwnd), `--app notepad`, else the front window.
fn resolve_window(c: &Core, args: &Value) -> Result<Option<String>, Envelope> {
    if let Some(w) = arg_str(args, "window") {
        return match winapi::parse_window_name(w) {
            Some(n) => Ok(Some(window_name(n))),
            None => Err(Envelope::err("invalid_args", format!("{w:?} is not a window id"), Retry::Never, "Window ids look like w-197330; `baneyspaces ls` lists them.")),
        };
    }
    if let Some(app) = arg_str(args, "app") {
        let want = app.to_lowercase();
        let want = want.strip_suffix(".exe").unwrap_or(&want).to_string();
        let mut hits: Vec<&String> = c.info.iter().filter(|(id, i)| i.app == want && !c.model.is_agent_window(id)).map(|(id, _)| id).collect();
        hits.sort();
        return match hits.as_slice() {
            [] => Err(Envelope::err("not_found", format!("no open window of {app}"), Retry::Safe, "Run `baneyspaces ls`.")),
            [one] => Ok(Some((*one).clone())),
            many => Err(Envelope::err("ambiguous", format!("{} windows of {app}: {}", many.len(), many.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", ")), Retry::Never, "Name one with --window.")),
        };
    }
    Ok(c.front_window())
}

fn ls(c: &Core) -> Value {
    let view = c.model.view();
    let mut spaces = serde_json::Map::new();
    if let Some(ws) = view["workspaces"].as_object() {
        for (k, list) in ws {
            let rows: Vec<Value> = list
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(|w| {
                    let i = c.info.get(w);
                    let h = i.and_then(|i| c.hidden.get(i.hwnd));
                    json!({ "window": w, "app": i.map(|i| i.app.clone()).unwrap_or_default(), "title": i.map(|i| i.title.clone()).unwrap_or_default(), "pid": i.map(|i| i.pid), "hidden": h.map(|h| h.how) })
                })
                .collect();
            spaces.insert(k.clone(), json!(rows));
        }
    }
    json!({ "focused_monitor": view["focused_monitor"], "active": view["active"], "monitors": view["monitors"], "workspaces": spaces, "agent": agent_status(c) })
}

fn agent_status(c: &Core) -> Value {
    let windows: Vec<Value> = c
        .model
        .agent_windows()
        .into_iter()
        .map(|w| {
            let i = c.info.get(w);
            let pid = c.model.pid_of(w);
            json!({ "window": w, "app": i.map(|i| i.app.clone()).unwrap_or_default(), "title": i.map(|i| i.title.clone()).unwrap_or_default(), "pid": pid, "drivable": pid.is_some_and(|p| c.model.agent_proc(p).is_some()) })
        })
        .collect();
    json!({ "workspace": AGENT_WORKSPACE, "shown": c.model.agent_shown(), "windows": windows, "processes": c.model.agent_pids().len(), "refused": c.model.refused() })
}

fn record(c: &Core, agent: &str, verb: &str, pid: Option<u32>, window: Option<&str>, reference: Option<&str>, route: &str, env: &Envelope) {
    c.paths.append("actions.jsonl", &ActionRecord::from_result(now(), agent, verb, pid, window, reference, route, env).to_line());
}

fn agent_log(c: &Core, args: &Value) -> Envelope {
    let since = args.get("since").and_then(Value::as_u64).map(|s| now().saturating_sub(s)).unwrap_or(0);
    let log = baneyspaces_core::ActionLog::parse(&c.paths.read("actions.jsonl").unwrap_or_default());
    let rows: Vec<&ActionRecord> = log.records.iter().filter(|r| r.at >= since).collect();
    Envelope::ok(json!({ "records": rows, "retention_days": baneyspaces_core::agent::RETENTION_DAYS }))
}

fn path_dirs() -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    if let Ok(w) = std::env::var("SystemRoot") {
        v.push(PathBuf::from(&w).join("System32"));
        v.push(PathBuf::from(w));
    }
    v
}

/// Starts `exe args` as a new process in its own job on the agent workspace, then waits for a window of its own.
fn launch_on_agent(shared: &Shared, agent: &str, label: &str, exe: PathBuf, args: Vec<String>, cwd: Option<String>, console: bool) -> Envelope {
    let (spawned, known): (agent::Spawned, BTreeSet<String>) = {
        // The lock is held across the spawn: the process is registered before its first window can be seen.
        let mut c = lock(shared);
        let known: BTreeSet<String> = c.model.window_ids().into_iter().map(String::from).collect();
        let Some(job) = agent::new_job() else {
            return Envelope::err("internal", "cannot create a job object", Retry::Safe, "");
        };
        match agent::spawn(&exe, &args, cwd.as_deref(), &job, console) {
            Ok(s) => {
                c.jobs.push((agent.to_string(), job));
                let _ = c.apply(Event::AgentRegister { pid: s.pid, start: s.start });
                (s, known)
            }
            Err(e) => {
                let env = Envelope::err("internal", e, Retry::Safe, "Check the path and try again.");
                record(&c, agent, "open", None, None, None, "createprocess", &env);
                return env;
            }
        }
    };
    let deadline = Instant::now() + Duration::from_secs(8);
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(40));
        let mut c = lock(shared);
        c.resync_windows(false);
        let found = c.model.agent_windows().into_iter().find(|w| !known.contains(*w) && c.model.pid_of(w).is_some_and(|p| p == spawned.pid || c.jobs.last().is_some_and(|(_, j)| agent::in_job(j, p)))).map(String::from);
        if let Some(w) = found {
            let i = c.info.get(&w).cloned();
            let env = Envelope::ok(json!({ "window": w, "pid": c.model.pid_of(&w), "app": label, "title": i.as_ref().map(|i| i.title.clone()), "workspace": "agent", "start": spawned.start }));
            record(&c, agent, "open", Some(spawned.pid), Some(&w), None, "createprocess", &env);
            return env;
        }
    }
    let c = lock(shared);
    let alive = winapi::alive(spawned.pid, spawned.start);
    let env = if !alive {
        Envelope::err("single_instance", format!("{label} exited without a window of its own: it most likely handed the request to an instance that was already running"), Retry::Never, "Agents only drive a process BaneySpaces started. Use the app's files or command line instead, or ask the user to lend it.")
    } else {
        Envelope::err("timeout", format!("{label} is running (pid {}) but opened no window within 8 s", spawned.pid), Retry::Never, "Check `baneyspaces agent status`; the app may be slow to start.")
    };
    record(&c, agent, "open", Some(spawned.pid), None, None, "createprocess", &env);
    env
}

fn agent_open(shared: &Shared, agent: &str, args: &Value) -> Envelope {
    let Some(app) = arg_str(args, "app") else {
        return Envelope::err("invalid_args", "an app is required", Retry::Never, "Example: baneyspaces agent open notepad");
    };
    if !apps::may_start(app) {
        let env = Envelope::err(
            "needs_sandbox",
            format!("{app} is not on the list of apps BaneySpaces can start as a separate process for an agent"),
            Retry::Never,
            "Deny by default: an app that is not known to run as its own process could hand your launches to the agent's copy, or take the agent's request into yours. Use the app's files or command line instead; a sandbox for apps like this comes later.",
        )
        .with_data(json!({ "allowed": apps::allowed() }));
        record(&lock(shared), agent, "open", None, None, None, "preflight", &env);
        return env;
    }
    let Some(exe) = cmdline::find_program(app, &path_dirs(), |p| p.is_file()) else {
        return Envelope::err("not_found", format!("no program {app:?} on PATH"), Retry::Never, "Give an executable name or a full path.");
    };
    let extra: Vec<String> = args.get("args").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(String::from).collect();
    launch_on_agent(shared, agent, app, exe, extra, None, false)
}

fn agent_run(shared: &Shared, agent: &str, _args: &Value) -> Envelope {
    // A console window on Windows is owned by Windows Terminal or conhost, a process BaneySpaces did not
    // start, so the window cannot be tied to the agent's process. Refused rather than guessed at.
    let env = Envelope::err(
        "needs_sandbox",
        "agent run is not available on Windows in part 1: a console window belongs to Windows Terminal, not to the process BaneySpaces would start",
        Retry::Never,
        "Use `agent open` for an app on the list, or run the command yourself. Terminals arrive with the sandbox in a later part.",
    )
    .with_data(json!({ "allowed": apps::allowed() }));
    record(&lock(shared), agent, "run", None, None, None, "preflight", &env);
    env
}

// ---- hands --------------------------------------------------------------------------------

/// What you can see, so an action can prove it changed none of it: the front window, the pointer,
/// and which of your windows are showing.
fn screen_state(c: &Core) -> Value {
    let mut pt = windows_sys::Win32::Foundation::POINT { x: 0, y: 0 };
    unsafe { windows_sys::Win32::UI::WindowsAndMessaging::GetCursorPos(&mut pt) };
    let mut showing: Vec<i64> = c.info.values().filter(|i| !c.hidden.contains(i.hwnd) && winapi::exists(to_hwnd(i.hwnd)) && winapi::is_visible(to_hwnd(i.hwnd))).map(|i| i.hwnd).collect();
    showing.sort();
    json!({ "front": id_of(winapi::foreground()), "cursor": [pt.x, pt.y], "showing": showing, "agent_shown": c.model.agent_shown() })
}

struct Plan {
    window: String,
    pid: u32,
    start: u64,
}

/// The scope guard against the model and against Windows' own word on who owns the window now.
fn guard(c: &Core, window: &str, expect: Option<&SnapInfo>) -> Result<Plan, Envelope> {
    let Some(i) = c.info.get(window) else {
        return Err(Envelope::err("not_found", format!("no window {window}"), Retry::AfterSnapshot, "Run `baneyspaces agent status` for the agent workspace's windows."));
    };
    let h = to_hwnd(i.hwnd);
    if !winapi::exists(h) {
        return Err(Envelope::err("not_found", format!("window {window} is gone"), Retry::AfterSnapshot, "Run `baneyspaces agent status`."));
    }
    if !matches!(c.model.home(window), Some(Home::Agent)) {
        return Err(Envelope::err("not_in_scope", "that window is not on the agent workspace", Retry::Never, "Agents act only on windows on the agent workspace. Start the app with `baneyspaces agent open`."));
    }
    let pid = winapi::real_pid(h);
    let start = winapi::process_start(pid);
    if let Some(s) = expect {
        if s.pid != pid || (s.start != 0 && s.start != start) {
            return Err(Envelope::err("stale_ref", "the window now belongs to a different process than the snapshot", Retry::AfterSnapshot, "Take a new snapshot."));
        }
    }
    check_scope(&c.model, &WindowFacts { window: window.into(), pid, pid_start: start }).map_err(|r| r.envelope())?;
    Ok(Plan { window: window.into(), pid, start })
}

fn hands(shared: &Shared, agent: &str, args: &Value) -> Envelope {
    let verb = args["verb"].as_str().unwrap_or("").to_string();
    let invalid = |m: &str| Envelope::err("invalid_args", m, Retry::Never, "Run `baneyspaces help`.");
    let Some(eng) = engine::locate() else {
        return Envelope::err("engine_missing", "the hands engine (agent-desktop, pinned) is not built", Retry::Never, "Run platforms/windows/scripts/build-engine.ps1, or set BANEYSPACES_ENGINE.");
    };
    let window_verb = matches!(verb.as_str(), "snapshot" | "find" | "shot");
    let ref_verb = matches!(verb.as_str(), "get" | "click" | "set-value" | "type" | "toggle" | "select" | "scroll");
    if !window_verb && !ref_verb {
        return Envelope::err("not_supported", format!("agent {verb} is not available on Windows in part 1"), Retry::Never, "Use snapshot, find, get, click, set-value, type, toggle, select, scroll or shot.");
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
        let c = lock(shared);
        let r = if window_verb {
            match s("window").and_then(|w| winapi::parse_window_name(&w)) {
                Some(n) => guard(&c, &window_name(n), None),
                None => Err(invalid("--window <id> is required (see `baneyspaces agent status`)")),
            }
        } else {
            let sid = snapshot_of(reference.as_deref().unwrap_or("")).unwrap_or("").to_string();
            match c.snaps.get(&sid).cloned() {
                None => Err(Envelope::err("stale_ref", "this ref is not from a snapshot BaneySpaces took", Retry::AfterSnapshot, "Take a snapshot with `baneyspaces agent snapshot` and use its refs.")),
                Some(info) => guard(&c, &info.window, Some(&info)),
            }
        };
        match r {
            Ok(p) => {
                let b = screen_state(&c);
                (p, b)
            }
            Err(env) => {
                record(&c, agent, &verb, None, s("window").as_deref(), reference.as_deref(), "uia", &env);
                return env;
            }
        }
    };
    // 2. The engine, without the lock. Never headed: no SendInput, no cursor, no overlay.
    let t = Duration::from_secs(40);
    let raw: Result<Value, Envelope> = if window_verb {
        engine::run_engine(&eng, &engine::window_argv(&verb, &plan.window, args), t)
    } else if verb == "type" {
        // The engine's `type` is keystroke synthesis. Insert through UI Automation instead: read, then set.
        let cur = engine::run_engine(&eng, &engine::ref_argv("get", &json!({"ref": reference, "property": "value"})), t);
        match cur {
            Err(e) => Err(e),
            Ok(cur) if cur["ok"] != json!(true) => Ok(cur),
            Ok(cur) => match engine::type_value(&cur, args["text"].as_str().unwrap_or("")) {
                Some(v) => engine::run_engine(&eng, &engine::ref_argv("set-value", &json!({"ref": reference, "value": v})), t),
                None => Err(Envelope::err("not_supported", "this element does not expose a text value to insert into", Retry::Never, "Take a snapshot and pick a text field; or use set-value on a ref that has a value.")),
            },
        }
    } else {
        engine::run_engine(&eng, &engine::ref_argv(&verb, args), t)
    };
    // 3. Read back, record, answer.
    let mut c = lock(shared);
    let mapped_verb = if verb == "type" { "set-value" } else { verb.as_str() };
    let mut env = match raw {
        Ok(v) => engine::map_engine(mapped_verb, &v),
        Err(e) => e,
    };
    if env.ok && matches!(verb.as_str(), "snapshot" | "find") {
        if let Some(sid) = env.data.as_ref().and_then(|d| d["result"]["snapshot_id"].as_str()).map(String::from) {
            if c.snaps.len() > 256 {
                c.snaps.clear();
            }
            c.snaps.insert(sid, SnapInfo { window: plan.window.clone(), pid: plan.pid, start: plan.start });
        }
    }
    let changed = screen_state(&c) != before;
    let same = guard(&c, &plan.window, None).is_ok();
    if let Some(d) = env.data.as_mut() {
        d["screen_changed"] = json!(changed);
        d["window"] = json!(plan.window);
        d["pid"] = json!(plan.pid);
        if !same {
            d["scope_changed"] = json!(true);
        }
    }
    let mut rec = ActionRecord::from_result(now(), agent, &verb, Some(plan.pid), Some(&plan.window), reference.as_deref(), "uia", &env);
    if changed {
        rec.result = "screen_changed".into();
    }
    c.paths.append("actions.jsonl", &rec.to_line());
    env
}

// ---- putting windows back ------------------------------------------------------------------

/// Reads `state.json` and shows every window a run left hidden, except agent windows whose process
/// still runs (they belong on the agent workspace). Works from the file alone, so it serves a
/// start after a crash, a clean exit and a panic alike. Returns what it did.
pub fn restore_from_file(paths: &Paths, keep_agents: bool) -> (usize, usize) {
    let left = hidden::parse_state(&paths.read("state.json").unwrap_or_default());
    // A cloaked or parked window is put back whenever the handle is still a window: undoing a cloak
    // on a window that is not cloaked does nothing, so a reused handle costs nothing, and a Store
    // app's process id cannot be read reliably from a cloaked frame. A ghost is different: undoing
    // it rewrites the window's styles, so its process must still be the one that was recorded.
    let exists = |h: &Hidden| {
        let w = to_hwnd(h.hwnd);
        winapi::exists(w) && (h.how != How::Ghost || ((h.pid == 0 || winapi::real_pid(w) == h.pid) && (h.start == 0 || winapi::process_start(h.pid) == h.start)))
    };
    let alive = |pid, start| keep_agents && winapi::alive(pid, start);
    let plan = hidden::recovery_plan(&left, exists, alive);
    let cloaker = Cloaker::new().ok();
    let (mut shown, mut kept) = (0, 0);
    let mut still: Vec<Hidden> = vec![];
    for p in plan {
        match p {
            Recovery::Show(h) => {
                cloak::show(&h, cloaker.as_ref());
                shown += 1;
            }
            Recovery::KeepOnAgent(h) => {
                kept += 1;
                still.push(h);
            }
            Recovery::Gone(_) => {}
        }
    }
    // Rewrite the file with only what is still hidden. Everything else in it is the old view.
    let text = paths.read("state.json").unwrap_or_default();
    let mut v: Value = serde_json::from_str(&text).unwrap_or_else(|_| json!({}));
    v["hidden"] = serde_json::to_value(&still).unwrap_or_default();
    paths.write_atomic("state.json", &serde_json::to_string_pretty(&v).unwrap_or_default());
    (shown, kept)
}

/// Safety net for a window a lost run left cloaked with no record of it: shell-cloaked, titled, an
/// app window, and on the current virtual desktop (so not just another desktop's). Shown again.
pub fn rescue_stray_cloaks(our_pid: u32) -> usize {
    let cloaker = Cloaker::new().ok();
    let mut n = 0;
    for h in winapi::list_top_level() {
        if winapi::cloaked(h) == 2 && winapi::is_visible(h) {
            say(&format!("[baneyspaces] stray? {} manageable={} on_current_desktop={:?}", window_name(id_of(h)), winapi::is_manageable(h, true, our_pid), cloak::on_current_desktop(h)));
        }
        if winapi::cloaked(h) == 2 && winapi::is_visible(h) && winapi::is_manageable(h, true, our_pid) && cloak::on_current_desktop(h) == Some(true) {
            if let Some(c) = cloaker.as_ref() {
                if c.set(h, false).is_ok() {
                    n += 1;
                }
            }
        }
    }
    n
}

// ---- the control pipe -----------------------------------------------------------------------

mod pipe {
    use std::os::windows::io::FromRawHandle;
    use windows_sys::Win32::Foundation::{GetLastError, LocalFree, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Security::Authorization::{ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW};
    use windows_sys::Win32::Security::{GetTokenInformation, TokenUser, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER};
    use windows_sys::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_DUPLEX};
    use windows_sys::Win32::System::Pipes::*;
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    /// The current user's SID as text, for a security descriptor that admits only this user and SYSTEM.
    fn user_sid() -> Option<String> {
        unsafe {
            let mut tok: HANDLE = std::ptr::null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut tok) == 0 {
                return None;
            }
            let mut need = 0u32;
            GetTokenInformation(tok, TokenUser, std::ptr::null_mut(), 0, &mut need);
            let mut buf = vec![0u8; need as usize];
            let ok = GetTokenInformation(tok, TokenUser, buf.as_mut_ptr() as *mut _, need, &mut need) != 0;
            windows_sys::Win32::Foundation::CloseHandle(tok);
            if !ok {
                return None;
            }
            let tu = &*(buf.as_ptr() as *const TOKEN_USER);
            let mut s: *mut u16 = std::ptr::null_mut();
            if ConvertSidToStringSidW(tu.User.Sid, &mut s) == 0 {
                return None;
            }
            let mut n = 0;
            while *s.add(n) != 0 {
                n += 1;
            }
            let out = String::from_utf16_lossy(std::slice::from_raw_parts(s, n));
            LocalFree(s as *mut _);
            Some(out)
        }
    }

    pub struct Server {
        name: Vec<u16>,
        sddl: Vec<u16>,
        first: bool,
    }

    impl Server {
        pub fn new(name: &str) -> Option<Self> {
            let sid = user_sid()?;
            Some(Self { name: wide(name), sddl: wide(&format!("D:P(A;;GA;;;{sid})(A;;GA;;;SY)")), first: true })
        }

        /// Waits for one client and returns the connected pipe as a `File`.
        pub fn accept(&mut self) -> Result<std::fs::File, String> {
            unsafe {
                let mut sd = std::ptr::null_mut();
                if ConvertStringSecurityDescriptorToSecurityDescriptorW(self.sddl.as_ptr(), 1, &mut sd, std::ptr::null_mut()) == 0 {
                    return Err(format!("security descriptor (error {})", GetLastError()));
                }
                let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: sd, bInheritHandle: 0 };
                let mut open = PIPE_ACCESS_DUPLEX;
                if self.first {
                    open |= FILE_FLAG_FIRST_PIPE_INSTANCE;
                }
                let h = CreateNamedPipeW(self.name.as_ptr(), open, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, PIPE_UNLIMITED_INSTANCES, 1 << 16, 1 << 16, 0, &sa);
                LocalFree(sd);
                if h == INVALID_HANDLE_VALUE {
                    return Err(format!("cannot create the pipe (error {})", GetLastError()));
                }
                self.first = false;
                if ConnectNamedPipe(h, std::ptr::null_mut()) == 0 && GetLastError() != 535 {
                    // 535 = ERROR_PIPE_CONNECTED: the client got in first, which is fine.
                    windows_sys::Win32::Foundation::CloseHandle(h);
                    return Err("connect failed".into());
                }
                Ok(std::fs::File::from_raw_handle(h as *mut _))
            }
        }
    }
}

fn serve_conn(shared: Shared, f: std::fs::File) {
    let mut line = String::new();
    {
        let mut r = BufReader::new(&f).take(1 << 20);
        if r.read_line(&mut line).is_err() {
            return;
        }
    }
    let peer = {
        let mut pid = 0u32;
        unsafe { windows_sys::Win32::System::Pipes::GetNamedPipeClientProcessId(std::os::windows::io::AsRawHandle::as_raw_handle(&f) as _, &mut pid) };
        pid
    };
    let env = match serde_json::from_str::<Value>(&line) {
        Ok(mut req) => {
            // The peer is what the pipe says, never what the request claims.
            req["_peer_pid"] = json!(peer);
            handle(&shared, &req)
        }
        Err(e) => Envelope::err("invalid_args", format!("bad request: {e}"), Retry::Never, ""),
    };
    let mut f = f;
    let _ = writeln!(f, "{}", env.to_json());
    let _ = f.flush();
    // Wait for the client to read before the handle closes.
    unsafe { windows_sys::Win32::Storage::FileSystem::FlushFileBuffers(std::os::windows::io::AsRawHandle::as_raw_handle(&f) as _) };
}

unsafe extern "system" fn ctrl_handler(kind: u32) -> i32 {
    // Ctrl+C, Ctrl+Break, console close, logoff, shutdown: put the windows back, then exit.
    let _ = kind;
    if let Some(tx) = CTRL_TX.get() {
        STOPPING.store(true, Ordering::SeqCst);
        let _ = tx.send(Msg::Quit);
        let t = Instant::now();
        while !FINISHED.load(Ordering::SeqCst) && t.elapsed() < Duration::from_secs(8) {
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    1
}

pub fn run(trace: bool, log: Option<PathBuf>) -> i32 {
    if let Some(p) = log {
        if let Ok(f) = std::fs::OpenOptions::new().create(true).append(true).open(&p) {
            let _ = LOG.set(Mutex::new(f));
        }
    }
    let paths = Paths::from_env();
    if let Err(e) = paths.ensure() {
        say(&format!("baneyspaces daemon: {e}"));
        return 1;
    }
    if ipc::call(&paths, &json!({ "op": "ping" })).ok {
        say(&format!("baneyspaces daemon: already running"));
        return 1;
    }
    // 1. Whatever a previous run left hidden comes back first, before anything else is done.
    let (shown, kept) = restore_from_file(&paths, true);
    if shown + kept > 0 {
        say(&format!("baneyspaces daemon: put back {shown} window(s) a previous run left hidden; {kept} agent window(s) stay on the agent workspace"));
    }
    let strays = rescue_stray_cloaks(std::process::id());
    if strays > 0 {
        say(&format!("baneyspaces daemon: showed {strays} window(s) that were cloaked with no record of it"));
    }
    let Some(mut server) = pipe::Server::new(&paths.pipe_name()) else {
        say(&format!("baneyspaces daemon: cannot read your account to protect the control pipe"));
        return 1;
    };
    let (tx, rx): (Sender<Msg>, Receiver<Msg>) = channel();
    let core = Core {
        model: Model::new(),
        paths: paths.clone(),
        hidden: HiddenSet::default(),
        info: HashMap::new(),
        jobs: vec![],
        snaps: HashMap::new(),
        overview_shown: false,
        events_seen: 0,
        started: now(),
        trace,
        our_pid: std::process::id(),
        problems: vec![],
        settings: settings::parse(&paths.read("settings.json").unwrap_or_default()),
        tx: tx.clone(),
    };
    let shared: Shared = Arc::new(Mutex::new(core));
    // Put windows back even if the daemon panics.
    {
        let paths = paths.clone();
        let prev = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let _ = restore_from_file(&paths, true);
            prev(info);
        }));
    }
    let _ = CTRL_TX.set(tx.clone());
    unsafe { windows_sys::Win32::System::Console::SetConsoleCtrlHandler(Some(ctrl_handler), 1) };
    {
        let mut c = lock(&shared);
        let mut log = baneyspaces_core::ActionLog::parse(&c.paths.read("actions.jsonl").unwrap_or_default());
        if log.prune(now()) > 0 {
            c.paths.write_atomic("actions.jsonl", &log.render());
        }
        // Agent processes from a previous run that are still the same process.
        let left = hidden::parse_state(&c.paths.read("state.json").unwrap_or_default());
        for a in &left.agents {
            if winapi::alive(a.pid, a.start) {
                let _ = c.model.apply(Event::AgentRegister { pid: a.pid, start: a.start });
            }
        }
        // Agent windows that stayed ghosted are still hidden: read them back into the set.
        for h in left.hidden.iter().filter(|h| h.agent) {
            c.hidden.insert(h.clone());
        }
        c.sync_monitors();
        c.resync_windows(true);
        c.persist();
        let problems = hook::start(tx.clone(), keys::bindings());
        for p in &problems {
            say(&format!("baneyspaces daemon: {p}"));
        }
        c.problems.extend(problems);
        c.persist();
    }
    // The control pipe.
    {
        let shared = shared.clone();
        std::thread::spawn(move || loop {
            match server.accept() {
                Ok(conn) => {
                    let shared = shared.clone();
                    std::thread::spawn(move || serve_conn(shared, conn));
                }
                Err(e) => {
                    say(&format!("baneyspaces daemon: {e}"));
                    std::thread::sleep(Duration::from_millis(500));
                }
            }
        });
    }
    say(&format!("baneyspaces daemon: ready ({})", paths.pipe_name()));
    // The worker: hook messages as they come, a poll when quiet.
    let mut last_poll = Instant::now();
    loop {
        match rx.recv_timeout(Duration::from_millis(400)) {
            Ok(Msg::Quit) => break,
            Ok(Msg::Chord(args)) => {
                // First, tell Windows the Win key was used so releasing it does not open Start.
                hook::mask_start_menu();
                let mut req = json!({ "op": "", "args": {} });
                match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
                    ["switch", n] => {
                        req = json!({ "op": "switch", "args": { "n": n } });
                    }
                    ["move", n] => req = json!({ "op": "move", "args": { "n": n, "stay": false } }),
                    ["move", n, "--stay"] => req = json!({ "op": "move", "args": { "n": n, "stay": true } }),
                    ["agent-workspace", "toggle"] => req = json!({ "op": "agent_toggle", "args": {} }),
                    _ => {}
                }
                let env = handle(&shared, &req);
                if !env.ok {
                    say(&format!("baneyspaces daemon: chord {args:?}: {}", env.to_json()));
                }
            }
            Ok(Msg::Win { event, hwnd }) => {
                lock(&shared).on_win_event(event, hwnd);
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(_) => break,
        }
        if last_poll.elapsed() >= Duration::from_millis(400) {
            last_poll = Instant::now();
            let mut c = lock(&shared);
            c.sync_monitors();
            c.resync_windows(false);
            c.sync_visibility();
            c.keep_focus_off_hidden_windows();
            c.persist();
        }
    }
    // Shutting down: stop the hooks, write the file, put your windows back.
    hook::stop();
    {
        let c = lock(&shared);
        c.persist();
    }
    let (shown, kept) = restore_from_file(&paths, true);
    say(&format!("baneyspaces daemon: stopped; {shown} window(s) put back, {kept} agent window(s) still on the agent workspace"));
    FINISHED.store(true, Ordering::SeqCst);
    0
}
