//! `baneyspaces daemon`: the model driven by what Windows reports (WinEvents and a poll), the
//! chords the keyboard hook swallows, the control pipe the CLI talks to, `state.json`, the agent
//! workspace and the agent action log.
//!
//! The model decides; this file only carries it out. Where a window should be is derived, not
//! replayed: after every event each tracked window is compared with what the model says (shown on
//! some display, or not) and hidden or shown to match, and what is hidden is read back from Windows
//! on every poll, never taken from memory. That makes every step idempotent, so a missed event costs
//! one poll interval, not a lost window.
//!
//! Three rules keep a window from being lost:
//! 1. **Record first.** A window is written to `state.json` (and flushed) before it is hidden. If that
//!    write fails, nothing is hidden and the request that wanted it is refused.
//! 2. **Forget last.** An entry is removed only after the window reads back as shown. A show that fails
//!    keeps its entry and is retried on every poll.
//! 3. **Tracked while it exists.** A hidden window stays in the set as long as `IsWindow` is true,
//!    whatever its title or styles become. Only a destroyed window leaves.

use crate::agent;
use crate::apps;
use crate::cloak::{self, Cloaker};
use crate::cmdline;
use crate::engine::{self, snapshot_of};
use crate::hidden::{self, Hidden, HiddenSet, How, Recovery};
use crate::hook::{self, EndSession, Msg};
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

pub const AGENT_WORKSPACE: &str = "off-your-screen (ghost: transparent, click-through, unfocusable)";

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
    /// The user's agent job (named, so a restarted daemon opens the same one).
    pub job: Option<agent::Job>,
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

/// Sign-out or shutdown is under way: windows are shown and nothing is hidden until it is cancelled.
static STOPPING: AtomicBool = AtomicBool::new(false);
static FINISHED: AtomicBool = AtomicBool::new(false);
static CTRL_TX: OnceLock<Sender<Msg>> = OnceLock::new();
static SHARED: OnceLock<Shared> = OnceLock::new();
static PATHS: OnceLock<Paths> = OnceLock::new();

/// What a request that wanted to hide windows says when it could not save where they were.
fn save_error(why: &str) -> Envelope {
    Envelope::err(
        "internal",
        format!("nothing was hidden: BaneySpaces could not save where your windows are, so it will not hide one ({why})"),
        Retry::Safe,
        "Nothing changed; the same call can be sent again. Check that %LOCALAPPDATA%\\BaneySpaces is writable and the disk is not full.",
    )
}

impl Core {
    fn log(&self, msg: &str) {
        if self.trace {
            say(&format!("[baneyspaces] {msg}"));
        }
    }

    fn problem(&mut self, msg: String) {
        if self.problems.last() == Some(&msg) {
            return;
        }
        say(&format!("[baneyspaces] {msg}"));
        self.problems.push(msg);
        if self.problems.len() > 20 {
            self.problems.remove(0);
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

    /// An event that mirrors what Windows did (a window opened, closed, took the front). Hiding
    /// that cannot be recorded is skipped and reported, never forced.
    pub fn apply(&mut self, ev: Event) -> Result<Vec<Effect>, ModelError> {
        self.events_seen += 1;
        let effects = self.model.apply(ev)?;
        if let Err(e) = self.exec(&effects) {
            self.problem(format!("could not save the hidden-window record, so no window was hidden: {e}"));
        }
        Ok(effects)
    }

    /// A request that changes what is hidden (switch, move, agent workspace). If the record cannot be
    /// saved, the model is put back and the caller gets an error; no window was touched.
    pub fn apply_checked(&mut self, ev: Event) -> Result<Vec<Effect>, Envelope> {
        self.events_seen += 1;
        let backup = self.model.clone();
        let effects = self.model.apply(ev).map_err(model_err)?;
        match self.exec(&effects) {
            Ok(()) => Ok(effects),
            Err(e) => {
                self.model = backup;
                self.problem(format!("refused: could not save the hidden-window record: {e}"));
                Err(save_error(&e))
            }
        }
    }

    /// Carries out effects. Where windows are is derived by `sync_visibility`; only focus is
    /// an action. Every effect is idempotent.
    fn exec(&mut self, effects: &[Effect]) -> Result<(), String> {
        for e in effects {
            self.log(&format!("effect {e:?}"));
        }
        self.sync_visibility()?;
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
        let _ = self.persist();
        Ok(())
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

    /// Is `pid` a process BaneySpaces started for an agent, or one of its children?
    fn is_agent_pid(&self, pid: u32) -> bool {
        pid != 0 && (self.model.agent_proc(pid).is_some() || self.job.as_ref().is_some_and(|j| agent::in_job(j, pid)))
    }

    /// Hides and shows windows so what you see is what the model says. Shows first, so a switch
    /// never flashes the desktop between two workspaces. What is hidden is checked against Windows
    /// every time: an entry in the set is a promise, not a fact.
    ///
    /// Returns an error, with no window touched, when the record of what is about to be hidden cannot
    /// be saved.
    pub fn sync_visibility(&mut self) -> Result<(), String> {
        let stopping = STOPPING.load(Ordering::SeqCst);
        let shown = self.visible_workspaces();
        let agent_shown = self.model.agent_shown();
        #[derive(Clone, Copy, PartialEq)]
        enum Want {
            Visible,
            HideUser,
            HideAgent,
        }
        // (hwnd, pid, start, what is wanted)
        let mut wants: Vec<(i64, u32, u64, Want)> = vec![];
        let mut tracked: BTreeSet<i64> = BTreeSet::new();
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
            tracked.insert(i.hwnd);
            wants.push((i.hwnd, i.pid, i.start, w));
        }
        // An agent's other windows (a dialog its app opened, one not shown yet) follow the agent workspace too.
        for e in self.hidden.entries().filter(|e| e.agent && !tracked.contains(&e.hwnd)) {
            wants.push((e.hwnd, e.pid, e.start, if agent_shown { Want::Visible } else { Want::HideAgent }));
        }
        if stopping {
            // Sign-out in progress: everything is shown by the restore; hide nothing.
            wants.retain(|w| w.3 == Want::Visible);
        }
        // 0. A window recorded the wrong way for what it is wanted as (an agent's ghost that is now
        //    a user's) is put right first.
        let mut cloaker: Option<Option<Cloaker>> = None;
        let get = |c: &mut Option<Option<Cloaker>>| -> Option<*const Cloaker> {
            if c.is_none() {
                *c = Some(Cloaker::new().ok());
            }
            c.as_ref().and_then(|o| o.as_ref()).map(|x| x as *const Cloaker)
        };
        for (hwnd, _, _, w) in &wants {
            if let Some(e) = self.hidden.get(*hwnd).cloned() {
                let wrong = (*w == Want::HideUser && e.how == How::Ghost) || (*w == Want::HideAgent && e.how != How::Ghost);
                if wrong {
                    let c = get(&mut cloaker);
                    if cloak::show(&e, c.map(|p| unsafe { &*p })) {
                        self.hidden.remove(*hwnd);
                    }
                }
            }
        }
        // 1. Record first: every window about to be hidden is on disk before any is touched.
        let mut add: Vec<Hidden> = vec![];
        for (hwnd, pid, start, w) in &wants {
            let h = to_hwnd(*hwnd);
            if self.hidden.contains(*hwnd) || !winapi::exists(h) {
                continue;
            }
            match w {
                Want::HideUser => add.push(Hidden { hwnd: *hwnd, pid: *pid, start: *start, how: How::Cloak, rect: winapi::rect(h), agent: false, ex_style: None }),
                Want::HideAgent => add.push(Hidden { hwnd: *hwnd, pid: *pid, start: *start, how: How::Ghost, rect: winapi::rect(h), agent: true, ex_style: Some(winapi::ex_style(h)) }),
                Want::Visible => {}
            }
        }
        if !add.is_empty() {
            let before = self.hidden.clone();
            for e in &add {
                self.hidden.insert(e.clone());
            }
            if let Err(e) = self.persist() {
                self.hidden = before;
                // An agent's window is the agent's, not yours: it is kept off your screen even with the record
                // unsaved. Yours are never hidden unrecorded: the request is refused, with nothing touched.
                let agents: Vec<Hidden> = add.iter().filter(|x| x.agent).cloned().collect();
                for a in &agents {
                    self.hidden.insert(a.clone());
                    if cloak::ghost(to_hwnd(a.hwnd)).is_none() {
                        winapi::set_pos(to_hwnd(a.hwnd), cloak::PARK, cloak::PARK);
                    }
                }
                if add.iter().any(|x| !x.agent) {
                    return Err(e);
                }
                self.problem(format!("could not save the record of an agent window ({e}); it is hidden anyway"));
            }
        }
        // 2. Show. An entry goes only after the window reads back as shown; a failure keeps it and the
        //    next poll tries again (explorer.exe restarting is the usual reason).
        for (hwnd, _, _, w) in &wants {
            if *w != Want::Visible {
                continue;
            }
            if let Some(e) = self.hidden.get(*hwnd).cloned() {
                let c = get(&mut cloaker);
                if cloak::show(&e, c.map(|p| unsafe { &*p })) {
                    self.hidden.remove(*hwnd);
                    let _ = self.persist();
                } else {
                    self.log(&format!("{} did not read back as shown; will retry", window_name(*hwnd)));
                }
            }
        }
        // 3. Hide, and read it back: re-apply whatever Windows no longer agrees with.
        for (hwnd, _, _, w) in &wants {
            let h = to_hwnd(*hwnd);
            if *w == Want::Visible || !winapi::exists(h) {
                continue;
            }
            let Some(mut e) = self.hidden.get(*hwnd).cloned() else { continue };
            if cloak::still_hidden(&e) {
                continue;
            }
            self.log(&format!("{} is not hidden any more ({:?}); hiding it again", window_name(*hwnd), e.how));
            match *w {
                Want::HideUser => {
                    if e.how == How::Park && !winapi::is_iconic(h) {
                        // The app moved itself out of the parking spot: where it went is where it goes back to.
                        e.rect = winapi::rect(h);
                    }
                    let c = get(&mut cloaker);
                    e.how = cloak::hide_user(h, c.map(|p| unsafe { &*p }));
                    if e.how != How::Cloak {
                        self.problem(format!("cloak refused for {}: parked it instead", window_name(*hwnd)));
                    }
                }
                Want::HideAgent => {
                    if cloak::ghost(h).is_none() {
                        // It would not take a constant alpha: park it rather than leave it drawn on your screen.
                        self.problem(format!("{} would not ghost: parked it instead", window_name(*hwnd)));
                        e.how = How::Park;
                        winapi::set_pos(h, cloak::PARK, cloak::PARK);
                    }
                    if winapi::is_iconic(h) {
                        winapi::restore_minimized_no_activate(h);
                    }
                }
                Want::Visible => {}
            }
            self.hidden.insert(e);
        }
        if !add.is_empty() || !wants.is_empty() {
            let _ = self.persist();
        }
        Ok(())
    }

    /// The record of what is hidden and everything else `state.json` holds. Returns why it could not be saved.
    pub fn persist(&self) -> Result<(), String> {
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
        self.paths.write_atomic("state.json", &serde_json::to_string_pretty(&v).unwrap_or_default())
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
        if !self.job.as_ref().is_some_and(|j| agent::in_job(j, pid)) {
            return false;
        }
        self.log(&format!("pid {pid} is in the agent job"));
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

    /// A tracked window is gone from the model. If it is still a window and we hid it, it is shown
    /// first and its entry kept until that reads back: dropping the entry of a window that still exists
    /// would leave it cloaked with no record.
    fn close_window(&mut self, id: &str) {
        if let Some(i) = self.info.remove(id) {
            if let Some(e) = self.hidden.get(i.hwnd).cloned() {
                if winapi::exists(to_hwnd(i.hwnd)) {
                    let cl = Cloaker::new().ok();
                    if cloak::show(&e, cl.as_ref()) {
                        self.hidden.remove(i.hwnd);
                    }
                } else {
                    self.hidden.remove(i.hwnd);
                }
            }
        }
        let _ = self.apply(Event::Close { window: id.to_string() });
    }

    /// Compares the windows that exist with the ones tracked; the source of truth for open and close.
    pub fn resync_windows(&mut self, existing: bool) {
        let mut agent_pids: HashMap<u32, bool> = HashMap::new();
        let mut live: Vec<i64> = vec![];
        for h in winapi::list_top_level() {
            let id = id_of(h);
            let pid = winapi::pid_of(h);
            let agent = *agent_pids.entry(pid).or_insert_with(|| self.is_agent_pid(pid));
            if agent {
                // An agent's window, whatever it looks like: ghost it before anything else.
                self.keep_agent_window_hidden(h, false);
            }
            if winapi::is_manageable(h, self.hidden.contains(id), self.our_pid, agent) {
                live.push(id);
            }
        }
        let live_set: BTreeSet<i64> = live.iter().copied().collect();
        // Gone: destroyed, or no longer a window we would manage and not one we hid. A window we hid stays
        // tracked for as long as it exists, whatever its title or styles turn into.
        let gone: Vec<String> = self.info.iter().filter(|(_, i)| !winapi::exists(to_hwnd(i.hwnd)) || (!live_set.contains(&i.hwnd) && !self.hidden.contains(i.hwnd))).map(|(id, _)| id.clone()).collect();
        for id in gone {
            self.close_window(&id);
        }
        for hwnd in live {
            self.open_window(hwnd, existing);
        }
        // Entries for windows that were destroyed are done with.
        let dead: Vec<i64> = self.hidden.entries().filter(|e| !winapi::exists(to_hwnd(e.hwnd))).map(|e| e.hwnd).collect();
        if !dead.is_empty() {
            for d in dead {
                self.hidden.remove(d);
            }
            let _ = self.persist();
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

    /// A window of an agent's process that is not recorded yet (a dialog, a popup, a second window) is
    /// ghosted now, before the model hears of it. Recorded first, like any hidden window.
    fn keep_agent_window_hidden(&mut self, h: windows_sys::Win32::Foundation::HWND, created: bool) {
        if self.model.agent_shown() || STOPPING.load(Ordering::SeqCst) {
            return;
        }
        let id = id_of(h);
        if self.hidden.contains(id) || !winapi::exists(h) || !winapi::is_top_level(h) {
            return;
        }
        // Created: only a window that will draw as a frame or a dialog (a caption) is worth ghosting before it is
        // shown; the process's invisible helper windows (IME, GDI+) are not. Otherwise it has to be visible.
        if created && !winapi::has_caption(h) {
            return;
        }
        if !created && !winapi::is_visible(h) {
            return;
        }
        let pid = winapi::real_pid(h);
        let e = Hidden { hwnd: id, pid, start: winapi::process_start(pid), how: How::Ghost, rect: winapi::rect(h), agent: true, ex_style: Some(winapi::ex_style(h)) };
        self.hidden.insert(e.clone());
        if let Err(why) = self.persist() {
            self.problem(format!("could not save the record of an agent window ({why}); it is hidden anyway"));
        }
        if cloak::ghost(h).is_none() {
            self.problem(format!("{} would not ghost: parked it instead", window_name(id)));
            winapi::set_pos(h, cloak::PARK, cloak::PARK);
            if let Some(mut e) = self.hidden.remove(id) {
                e.how = How::Park;
                self.hidden.insert(e);
            }
        }
        let _ = self.persist();
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
        let h = to_hwnd(hwnd);
        // A window of an agent's process is ghosted the moment it is created or shown, before it paints
        // if the event arrives in time: this is what catches a dialog its app opens.
        if matches!(event, hook::EVENT_OBJECT_CREATE | hook::EVENT_OBJECT_SHOW) && winapi::exists(h) && winapi::is_top_level(h) {
            let pid = winapi::pid_of(h);
            if self.is_agent_pid(pid) {
                self.keep_agent_window_hidden(h, true);
            }
        }
        match event {
            hook::EVENT_SYSTEM_FOREGROUND => {
                if !self.model.is_tracked(&window_name(hwnd)) && winapi::is_manageable(h, false, self.our_pid, self.is_agent_pid(winapi::pid_of(h))) {
                    self.open_window(hwnd, false);
                }
                self.on_foreground(hwnd)
            }
            hook::EVENT_OBJECT_CREATE | hook::EVENT_OBJECT_SHOW | hook::EVENT_SYSTEM_MINIMIZEEND => {
                let agent = self.is_agent_pid(winapi::pid_of(h));
                if !self.model.is_tracked(&window_name(hwnd)) && winapi::is_manageable(h, self.hidden.contains(hwnd), self.our_pid, agent) {
                    self.open_window(hwnd, false);
                }
            }
            hook::EVENT_OBJECT_DESTROY | hook::EVENT_OBJECT_HIDE => {
                let id = window_name(hwnd);
                if self.model.is_tracked(&id) && !winapi::exists(h) {
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
/// started) is refused: agents never change your workspaces, your windows or the daemon. The three
/// appearance settings are the exception (Donovan, 2026-11-01): an agent may customize them, and
/// every `set` is logged with who asked.
const USER_OPS: &[&str] = &["switch", "move", "focus_monitor", "overview", "agent_show", "agent_hide", "agent_toggle", "agent_move", "agent_bring", "quit"];

/// Is the process on the other end of the pipe an agent's? By pid, against the model and the jobs.
fn peer_is_agent(c: &Core, pid: u32) -> bool {
    c.is_agent_pid(pid)
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
            match c.apply_checked(Event::Switch { n }) {
                Ok(fx) => Envelope::ok(json!({ "workspace": n, "effects": effects_json(&fx) })),
                Err(e) => e,
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
            match c.apply_checked(Event::Move { n, window, follow }) {
                Ok(fx) => Envelope::ok(json!({ "workspace": n, "follow": follow, "effects": effects_json(&fx) })),
                Err(e) => e,
            }
        }
        "focus_monitor" => {
            let mut c = lock(shared);
            match c.apply_checked(Event::FocusMonitor { monitor: arg_str(&args, "monitor").unwrap_or("").into() }) {
                Ok(fx) => Envelope::ok(json!({ "effects": effects_json(&fx) })),
                Err(e) => e,
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
                    let mut next = c.settings.clone();
                    next.insert(k.to_string(), val.clone());
                    let text = serde_json::to_string_pretty(&Value::Object(next.clone())).unwrap_or_default();
                    if let Err(e) = c.paths.write_atomic("settings.json", &text) {
                        return Envelope::err("internal", format!("the setting was not saved: {e}"), Retry::Safe, "Nothing changed; try again.");
                    }
                    c.settings = next;
                    let _ = c.persist();
                    // Who asked: the agent id and the pipe peer's pid, never the value.
                    let peer = req["_peer_pid"].as_u64().map(|p| p as u32).filter(|p| *p != 0);
                    let env = Envelope::ok(json!({}));
                    c.paths.append("actions.jsonl", &ActionRecord::from_result(now(), &agent, "set", peer, None, None, &format!("settings:{k}"), &env).to_line());
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
            let _ = c.persist();
            Envelope::ok(json!({ "shown": c.overview_shown, "note": "recorded in state.json; the overview itself arrives in part 2" }))
        }
        "agent_show" | "agent_hide" | "agent_toggle" => {
            let ev = match op {
                "agent_show" => Event::AgentShow,
                "agent_hide" => Event::AgentHide,
                _ => Event::AgentToggle,
            };
            let mut c = lock(shared);
            match c.apply_checked(ev) {
                Ok(fx) => Envelope::ok(json!({ "shown": c.model.agent_shown(), "effects": effects_json(&fx) })),
                Err(e) => e,
            }
        }
        "agent_move" | "agent_bring" => {
            let Some(w) = arg_str(&args, "window").map(String::from) else {
                return Envelope::err("invalid_args", "a window id is required", Retry::Never, "Run `baneyspaces ls` for window ids.");
            };
            let mut c = lock(shared);
            let ev = if op == "agent_move" { Event::AgentSend { window: w } } else { Event::AgentBring { window: w } };
            match c.apply_checked(ev) {
                Ok(fx) => Envelope::ok(json!({ "effects": effects_json(&fx), "drivable": false })),
                Err(e) => e,
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
        let Some(job) = c.job.as_ref() else {
            return Envelope::err("internal", "the agent job object is not available", Retry::Safe, "Restart the daemon.");
        };
        match agent::spawn(&exe, &args, cwd.as_deref(), job, console) {
            Ok(s) => {
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
        let found = c.model.agent_windows().into_iter().find(|w| !known.contains(*w) && c.model.pid_of(w).is_some_and(|p| p == spawned.pid || c.job.as_ref().is_some_and(|j| agent::in_job(j, p)))).map(String::from);
        if let Some(w) = found {
            let i = c.info.get(&w).cloned();
            let env = Envelope::ok(json!({ "window": w, "pid": c.model.pid_of(&w), "app": label, "title": i.as_ref().map(|i| i.title.clone()), "workspace": "agent", "start": spawned.start }));
            record(&c, agent, "open", Some(spawned.pid), Some(&w), None, "createprocess", &env);
            return env;
        }
    }
    let c = lock(shared);
    let alive = winapi::alive(spawned.pid, spawned.start);
    let appeared: Vec<String> = c.model.window_ids().into_iter().filter(|w| !known.contains(*w) && !c.model.is_agent_window(w)).map(String::from).collect();
    let env = if !appeared.is_empty() {
        Envelope::err("single_instance", format!("{label} opened its window in a copy that was already running, not in a process of its own"), Retry::Never, "Nothing was driven. The window that opened is left where it is, on your workspace.").with_data(json!({ "windows_that_appeared": appeared }))
    } else if !alive {
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
            format!("{app} was not started: on Windows an agent may not start any app until there is a sandbox"),
            Retry::Never,
            "No Windows app is safe to hand an agent yet: Notepad would show it your unsaved tabs, and most apps forward a launch into the copy you already run. A Windows sandbox (Windows Sandbox or a Hyper-V VM) is a later part. Use files or the command line instead.",
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
    // What an agent's action could change on your screen: which of your windows are showing, whether an
    // agent window is showing, and whether the front window is an agent's. Not the pointer and not which
    // of your windows has focus: those move when you do, and would drown the real violations.
    let mut showing: Vec<i64> = c
        .info
        .iter()
        .filter(|(id, i)| !c.model.is_agent_window(id) && !c.hidden.contains(i.hwnd) && winapi::exists(to_hwnd(i.hwnd)) && winapi::is_visible(to_hwnd(i.hwnd)))
        .map(|(_, i)| i.hwnd)
        .collect();
    showing.sort();
    let mut agent_visible: Vec<i64> = c.info.iter().filter(|(id, i)| c.model.is_agent_window(id) && !c.hidden.contains(i.hwnd) && winapi::exists(to_hwnd(i.hwnd))).map(|(_, i)| i.hwnd).collect();
    agent_visible.sort();
    let front_is_agent = c.is_agent_pid(winapi::pid_of(winapi::foreground()));
    json!({ "showing": showing, "agent_visible": agent_visible, "front_is_agent": front_is_agent, "agent_shown": c.model.agent_shown() })
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
                Some(v) => {
                    // Scope again, right before the write: the window must still be the agent's, on the agent workspace.
                    let still = {
                        let c = lock(shared);
                        let info = c.snaps.get(snapshot_of(reference.as_deref().unwrap_or("")).unwrap_or("")).cloned();
                        guard(&c, &plan.window, info.as_ref())
                    };
                    match still {
                        Ok(_) => engine::run_engine(&eng, &engine::ref_argv("set-value", &json!({"ref": reference, "value": v})), t),
                        Err(env) => Err(env),
                    }
                }
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
/// start after a crash, a clean exit and a panic alike. A window that does not read back as shown
/// keeps its entry, for the next try. Returns (shown and verified, kept on the agent workspace, still hidden).
pub fn restore_from_file(paths: &Paths, keep_agents: bool) -> (usize, usize, usize) {
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
    let (mut shown, mut kept, mut failed) = (0, 0, 0);
    let mut still: Vec<Hidden> = vec![];
    for p in plan {
        match p {
            Recovery::Show(h) => {
                if cloak::show(&h, cloaker.as_ref()) {
                    shown += 1;
                } else {
                    failed += 1;
                    still.push(h);
                }
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
    let _ = paths.write_atomic("state.json", &serde_json::to_string_pretty(&v).unwrap_or_default());
    (shown, kept, failed)
}

// ---- the control pipe -----------------------------------------------------------------------

mod pipe {
    use std::os::windows::io::FromRawHandle;
    use windows_sys::Win32::Foundation::{GetLastError, LocalFree, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Security::Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW;
    use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
    use windows_sys::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_DUPLEX};
    use windows_sys::Win32::System::Pipes::*;

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    /// Makes instances of the control pipe: this user and SYSTEM only, no remote clients.
    #[derive(Clone)]
    pub struct Server {
        name: Vec<u16>,
        sddl: Vec<u16>,
    }

    impl Server {
        pub fn new(name: &str) -> Option<Self> {
            let sid = crate::winapi::user_sid_string()?;
            Some(Self { name: wide(name), sddl: wide(&format!("D:P(A;;GA;;;{sid})(A;;GA;;;SY)")) })
        }

        /// One more instance of the pipe, waiting for a client. The very first one (`first`) fails if the
        /// name is already in use, which is how a second daemon (or a squatter) is told apart.
        pub fn create(&self, first: bool) -> Result<HANDLE, String> {
            unsafe {
                let mut sd = std::ptr::null_mut();
                if ConvertStringSecurityDescriptorToSecurityDescriptorW(self.sddl.as_ptr(), 1, &mut sd, std::ptr::null_mut()) == 0 {
                    return Err(format!("security descriptor (error {})", GetLastError()));
                }
                let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: sd, bInheritHandle: 0 };
                let mut open = PIPE_ACCESS_DUPLEX;
                if first {
                    open |= FILE_FLAG_FIRST_PIPE_INSTANCE;
                }
                let h = CreateNamedPipeW(self.name.as_ptr(), open, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, PIPE_UNLIMITED_INSTANCES, 1 << 16, 1 << 16, 0, &sa);
                LocalFree(sd);
                if h == INVALID_HANDLE_VALUE {
                    return Err(format!("cannot create the pipe (error {})", GetLastError()));
                }
                Ok(h)
            }
        }
    }

    /// Waits for a client on `h` and returns the connected pipe as a `File`.
    pub fn connect(h: HANDLE) -> Result<std::fs::File, String> {
        unsafe {
            if ConnectNamedPipe(h, std::ptr::null_mut()) == 0 && GetLastError() != 535 {
                // 535 = ERROR_PIPE_CONNECTED: the client got in first, which is fine.
                windows_sys::Win32::Foundation::CloseHandle(h);
                return Err("connect failed".into());
            }
            Ok(std::fs::File::from_raw_handle(h as *mut _))
        }
    }
}

/// One request, one answer. Anything that is not a JSON object is refused; the peer is what the pipe says.
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
        Ok(Value::Object(mut req)) => {
            req.insert("_peer_pid".into(), json!(peer));
            handle(&shared, &Value::Object(req))
        }
        Ok(_) => Envelope::err("invalid_args", "a request is one JSON object", Retry::Never, "Example: {\"op\":\"ping\"}"),
        Err(e) => Envelope::err("invalid_args", format!("bad request: {e}"), Retry::Never, ""),
    };
    let mut f = f;
    let _ = writeln!(f, "{}", env.to_json());
    let _ = f.flush();
    // Wait for the client to read before the handle closes.
    unsafe { windows_sys::Win32::Storage::FileSystem::FlushFileBuffers(std::os::windows::io::AsRawHandle::as_raw_handle(&f) as _) };
}

/// Always listening: each listener makes the next instance of the pipe the moment a client connects,
/// and there are two of them, so there is no moment with no free instance.
fn listen(shared: Shared, server: pipe::Server, first: Option<usize>) {
    let mut ready = first;
    loop {
        let h = match ready.take() {
            Some(h) => h as windows_sys::Win32::Foundation::HANDLE,
            None => match server.create(false) {
                Ok(h) => h,
                Err(e) => {
                    say(&format!("baneyspaces daemon: {e}"));
                    std::thread::sleep(Duration::from_millis(500));
                    continue;
                }
            },
        };
        match pipe::connect(h) {
            Ok(conn) => {
                let shared = shared.clone();
                std::thread::spawn(move || serve_conn(shared, conn));
            }
            Err(e) => {
                say(&format!("baneyspaces daemon: {e}"));
                std::thread::sleep(Duration::from_millis(50));
            }
        }
    }
}

unsafe extern "system" fn ctrl_handler(kind: u32) -> i32 {
    // Ctrl+C, Ctrl+Break, console close (a foreground daemon): put the windows back, then exit.
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

/// Sign-out and shutdown, heard by the daemon's hidden window (a background daemon has no console, so no
/// console event ever reaches it). Windows are put back before apps are asked to save, so a "save changes?"
/// prompt is not raised on a window nobody can see.
fn on_end_session(e: EndSession) {
    let (Some(paths), Some(shared)) = (PATHS.get(), SHARED.get()) else { return };
    match e {
        EndSession::Query | EndSession::Ending => {
            STOPPING.store(true, Ordering::SeqCst);
            let r = restore_from_file(paths, true);
            {
                let mut c = lock(shared);
                c.reload_hidden_from_file();
            }
            say(&format!("baneyspaces daemon: {e:?}: {} window(s) put back, {} agent window(s) stay, {} not restored", r.0, r.1, r.2));
            if e == EndSession::Ending {
                std::process::exit(0);
            }
        }
        EndSession::Cancelled => {
            // Cancelled: carry on. The next poll hides again what belongs on a hidden workspace.
            STOPPING.store(false, Ordering::SeqCst);
        }
    }
}

/// One daemon per user: a named mutex, taken before anything is touched. None means another is running.
fn single_instance(paths: &Paths) -> Option<windows_sys::Win32::Foundation::HANDLE> {
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS};
    use windows_sys::Win32::System::Threading::CreateMutexW;
    let name: Vec<u16> = paths.mutex_name().encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        let h = CreateMutexW(std::ptr::null(), 0, name.as_ptr());
        if h.is_null() || GetLastError() == ERROR_ALREADY_EXISTS {
            return None;
        }
        Some(h)
    }
}

impl Core {
    /// Replaces the in-memory hidden set with what `state.json` says is still hidden (after a restore).
    pub fn reload_hidden_from_file(&mut self) {
        let left = hidden::parse_state(&self.paths.read("state.json").unwrap_or_default());
        self.hidden = HiddenSet::default();
        for h in left.hidden {
            self.hidden.insert(h);
        }
    }

    /// One poll: monitors, windows, what is hidden checked against Windows, focus.
    fn poll(&mut self) {
        self.sync_monitors();
        self.resync_windows(false);
        if let Err(e) = self.sync_visibility() {
            self.problem(format!("could not save the hidden-window record; nothing new was hidden: {e}"));
        }
        self.keep_focus_off_hidden_windows();
        let _ = self.persist();
    }
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
    let _ = PATHS.set(paths.clone());
    // 1. One daemon only, decided before anything is touched: a named mutex, then the first instance of
    //    the pipe (which fails if anything else already made it). A second daemon must never get as far as
    //    putting the first one's windows back.
    let Some(_mutex) = single_instance(&paths) else {
        say("baneyspaces daemon: already running");
        return 1;
    };
    let Some(server) = pipe::Server::new(&paths.pipe_name()) else {
        say("baneyspaces daemon: cannot read your account to protect the control pipe");
        return 1;
    };
    let first = match server.create(true) {
        Ok(h) => h as usize,
        Err(e) => {
            say(&format!("baneyspaces daemon: {e}: is another daemon, or something else, using the pipe?"));
            return 1;
        }
    };
    // 2. Whatever a previous run left hidden comes back first, before anything else is done.
    let (shown, kept, failed) = restore_from_file(&paths, true);
    if shown + kept + failed > 0 {
        say(&format!("baneyspaces daemon: put back {shown} window(s) a previous run left hidden; {kept} agent window(s) stay on the agent workspace; {failed} could not be shown yet (will retry)"));
    }
    let (tx, rx): (Sender<Msg>, Receiver<Msg>) = channel();
    let core = Core {
        model: Model::new(),
        paths: paths.clone(),
        hidden: HiddenSet::default(),
        info: HashMap::new(),
        job: agent::open_job(&format!("Local\\BaneySpaces-Agents-{}", crate::paths::user_key())),
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
    let _ = SHARED.set(shared.clone());
    // A panic anywhere puts the windows back and ends the process: running on after that would be running on a
    // set of hidden windows that no longer matches the screen.
    {
        let paths = paths.clone();
        let prev = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            prev(info);
            let _ = restore_from_file(&paths, true);
            std::process::exit(101);
        }));
    }
    let _ = CTRL_TX.set(tx.clone());
    unsafe { windows_sys::Win32::System::Console::SetConsoleCtrlHandler(Some(ctrl_handler), 1) };
    {
        let mut c = lock(&shared);
        let mut log = baneyspaces_core::ActionLog::parse(&c.paths.read("actions.jsonl").unwrap_or_default());
        if log.prune(now()) > 0 {
            let _ = c.paths.write_atomic("actions.jsonl", &log.render());
        }
        // Agent processes from a previous run that are still the same process.
        let left = hidden::parse_state(&c.paths.read("state.json").unwrap_or_default());
        for a in &left.agents {
            if winapi::alive(a.pid, a.start) {
                let _ = c.model.apply(Event::AgentRegister { pid: a.pid, start: a.start });
            }
        }
        // What is still hidden: agent windows that stayed on the agent workspace, and any window that did not
        // read back as shown (its entry stays until it does).
        for h in left.hidden {
            c.hidden.insert(h);
        }
        c.sync_monitors();
        c.resync_windows(true);
        let _ = c.persist();
        let problems = hook::start(tx.clone(), keys::bindings(), on_end_session);
        for p in &problems {
            say(&format!("baneyspaces daemon: {p}"));
        }
        c.problems.extend(problems);
        let _ = c.persist();
    }
    // The control pipe: two listeners, so there is always a free instance.
    {
        let (s1, sv1) = (shared.clone(), server.clone());
        std::thread::spawn(move || listen(s1, sv1, Some(first)));
        let (s2, sv2) = (shared.clone(), server);
        std::thread::spawn(move || listen(s2, sv2, None));
    }
    say(&format!("baneyspaces daemon: ready ({})", paths.pipe_name()));
    // The worker: hook messages as they come, a poll when quiet.
    let mut last_poll = Instant::now();
    loop {
        match rx.recv_timeout(Duration::from_millis(400)) {
            Ok(Msg::Quit) => break,
            Ok(Msg::Resync) => {
                // explorer.exe restarted, the session unlocked, or the input desktop changed: look at everything now.
                last_poll = Instant::now();
                lock(&shared).poll();
            }
            Ok(Msg::Chord(args)) => {
                if trace {
                    say(&format!("[baneyspaces] chord {args:?}"));
                }
                // First, tell Windows the Win key was used so releasing it does not open Start.
                hook::mask_start_menu();
                let mut req = json!({ "op": "", "args": {} });
                match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
                    ["switch", n] => req = json!({ "op": "switch", "args": { "n": n } }),
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
            lock(&shared).poll();
        }
    }
    // Shutting down: stop the hooks, write the file, put your windows back.
    hook::stop();
    {
        let c = lock(&shared);
        let _ = c.persist();
    }
    let (shown, kept, failed) = restore_from_file(&paths, true);
    say(&format!("baneyspaces daemon: stopped; {shown} window(s) put back, {kept} agent window(s) still on the agent workspace, {failed} not restored (kept in state.json)"));
    FINISHED.store(true, Ordering::SeqCst);
    0
}
