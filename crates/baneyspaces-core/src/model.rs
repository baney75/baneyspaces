//! The workspace model: pure state plus the rules in `spec/workspaces.md`.
//!
//! One shared pool of nine workspaces; each display shows one of them at a time, never the same
//! one as another display. The model never talks to a compositor. A platform feeds it [`Event`]s
//! (what the user asked for, what the compositor reported) and carries out the [`Effect`]s it
//! returns. Every platform's tests replay `spec/conformance/*.json` against this same code path, so
//! a rule that is not in `spec/` does not exist.

use serde::{Deserialize, Serialize};
use crate::devices::Role;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

pub const WORKSPACES: std::ops::RangeInclusive<u8> = 1..=9;

pub type WindowId = String;
pub type MonitorId = String;

/// Where a window lives.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Home {
    /// One of the nine shared workspaces.
    Workspace { n: u8 },
    /// The agent workspace: parked out of view, never shown unless the user asks.
    Agent,
}

impl Home {
    pub fn label(&self) -> String {
        match self {
            Home::Workspace { n } => n.to_string(),
            Home::Agent => "agent".into(),
        }
    }
}

fn yes() -> bool {
    true
}

/// Who caused an activation. Only `User` may take you to another workspace.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Cause {
    #[default]
    User,
    App,
    Agent,
}

/// Inputs. Commands (`Switch`, `Move`, `Agent*`) produce effects to carry out; observations
/// (`Open`, `Close`, `Activate`, `Observe*`) mirror what the compositor already did and produce
/// effects only to correct it.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(tag = "do", rename_all = "snake_case")]
pub enum Event {
    MonitorAdded {
        monitor: MonitorId,
    },
    MonitorRemoved {
        monitor: MonitorId,
    },
    /// A window opened. `monitor` is the display it appeared on (default: the one you are on);
    /// `workspace` is the workspace the compositor put it on (default: that display's).
    Open {
        window: WindowId,
        pid: u32,
        /// The process start time (0: unknown). With `pid` it tells a reused pid from the process an agent was given.
        #[serde(default)]
        start: u64,
        #[serde(default)]
        app: String,
        #[serde(default)]
        monitor: Option<MonitorId>,
        #[serde(default)]
        workspace: Option<u8>,
        /// What the window is for (`spec/devices.md`). A companion lives with the main window of
        /// its process and is never counted as a window of its own.
        #[serde(default)]
        role: Role,
        /// `"agent"`: the window lives on the agent workspace whatever process opened it.
        #[serde(default)]
        pin: Option<String>,
    },
    /// A window that already existed when the model started listening: mirrored exactly where it is.
    /// `workspace` absent means the agent workspace.
    ObserveWindow {
        window: WindowId,
        pid: u32,
        #[serde(default)]
        start: u64,
        #[serde(default)]
        app: String,
        #[serde(default)]
        workspace: Option<u8>,
        #[serde(default)]
        role: Role,
    },
    Close {
        window: WindowId,
    },
    Switch {
        n: u8,
    },
    Move {
        n: u8,
        #[serde(default)]
        window: Option<WindowId>,
        /// Go to the workspace with the window (the default); false sends it and stays.
        #[serde(default = "yes")]
        follow: bool,
    },
    Activate {
        #[serde(default)]
        window: Option<WindowId>,
        #[serde(default)]
        cause: Cause,
    },
    /// A window the compositor moved (you dragged it, a command did): mirrored, never undone.
    /// `n` absent means the agent workspace.
    ObserveMove {
        window: WindowId,
        #[serde(default)]
        n: Option<u8>,
    },
    /// What a display shows now. `n` 0 means something outside the nine.
    ObserveWorkspace {
        monitor: MonitorId,
        n: u8,
    },
    ObserveSpecial {
        shown: bool,
    },
    ObserveFocusMonitor {
        monitor: MonitorId,
    },
    FocusMonitor {
        monitor: MonitorId,
    },
    AgentRegister {
        pid: u32,
        #[serde(default)]
        start: u64,
    },
    AgentExit {
        pid: u32,
    },
    AgentShow,
    AgentHide,
    AgentToggle,
    /// `agent move`: park one of your windows on the agent workspace. It is not drivable.
    AgentSend {
        window: WindowId,
    },
    /// `agent bring`: return a window you parked.
    AgentBring {
        window: WindowId,
    },
}

/// What a platform must do. All are idempotent: the compositor may already be there.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "do", rename_all = "snake_case")]
pub enum Effect {
    /// This display shows this workspace.
    ShowWorkspace {
        monitor: MonitorId,
        workspace: u8,
    },
    FocusMonitor {
        monitor: MonitorId,
    },
    FocusWindow {
        window: WindowId,
    },
    /// Silent: no focus change, no workspace change. `to` is `"<n>"` or `"agent"`.
    MoveWindow {
        window: WindowId,
        to: String,
    },
    ShowAgent,
    HideAgent,
    /// The guard declined to follow or keep an activation.
    RefuseFollow {
        window: WindowId,
        reason: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelError {
    pub code: &'static str,
    pub message: String,
}

impl ModelError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

impl std::fmt::Display for ModelError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

#[derive(Clone, Debug)]
struct Monitor {
    slot: u32,
    /// The workspace this display shows; 0 when it shows something outside the nine.
    current: u8,
}

#[derive(Clone, Debug)]
struct Window {
    pid: u32,
    start: u64,
    app: String,
    home: Home,
    seq: u64,
    role: Role,
}

#[derive(Clone, Debug, Default)]
pub struct Model {
    monitors: BTreeMap<MonitorId, Monitor>,
    /// What each display showed last, so one that comes back shows it again.
    last_shown: BTreeMap<MonitorId, u8>,
    focused_monitor: Option<MonitorId>,
    windows: BTreeMap<WindowId, Window>,
    /// The last window in front on each workspace, so coming back lands where you left off.
    last_focused: BTreeMap<u8, WindowId>,
    active: Option<WindowId>,
    seq: u64,
    /// Agent processes BaneySpaces started: pid -> start time (0 = unchecked).
    agent_pids: BTreeMap<u32, u64>,
    agent_shown: bool,
    before_agent: Option<WindowId>,
    refused: u64,
}

impl Model {
    pub fn new() -> Self {
        Self::default()
    }

    // ---- reads -------------------------------------------------------------------------

    pub fn focused_monitor(&self) -> Option<&str> {
        self.focused_monitor.as_deref()
    }
    pub fn active(&self) -> Option<&str> {
        self.active.as_deref()
    }
    pub fn agent_shown(&self) -> bool {
        self.agent_shown
    }
    /// The workspace a display shows (0: outside the nine).
    pub fn current(&self, monitor: &str) -> Option<u8> {
        self.monitors.get(monitor).map(|m| m.current)
    }
    pub fn slot(&self, monitor: &str) -> Option<u32> {
        self.monitors.get(monitor).map(|m| m.slot)
    }
    pub fn monitors(&self) -> impl Iterator<Item = &str> {
        self.monitors.keys().map(String::as_str)
    }
    /// The display showing workspace `n`, if any.
    pub fn shown_on(&self, n: u8) -> Option<&str> {
        if n == 0 {
            return None;
        }
        self.monitors
            .iter()
            .find(|(_, m)| m.current == n)
            .map(|(k, _)| k.as_str())
    }
    pub fn home(&self, window: &str) -> Option<&Home> {
        self.windows.get(window).map(|w| &w.home)
    }
    /// Every window the model tracks.
    pub fn window_ids(&self) -> Vec<&str> {
        self.windows.keys().map(String::as_str).collect()
    }
    pub fn pid_of(&self, window: &str) -> Option<u32> {
        self.windows.get(window).map(|w| w.pid)
    }
    pub fn refused(&self) -> u64 {
        self.refused
    }
    pub fn is_tracked(&self, window: &str) -> bool {
        self.windows.contains_key(window)
    }
    /// The registered agent process, with its recorded start time.
    pub fn agent_proc(&self, pid: u32) -> Option<u64> {
        self.agent_pids.get(&pid).copied()
    }
    pub fn agent_pids(&self) -> Vec<(u32, u64)> {
        self.agent_pids.iter().map(|(p, s)| (*p, *s)).collect()
    }
    /// Windows parked on the agent workspace, oldest first.
    pub fn agent_windows(&self) -> Vec<&str> {
        self.ordered(|w| w.role != Role::Companion && w.home == Home::Agent)
    }
    /// Windows on one workspace, oldest first. A companion (a toolbar, extended controls) is not a
    /// window of its own, so it does not count here (R-D3).
    pub fn windows_on(&self, n: u8) -> Vec<&str> {
        self.ordered(|w| w.role != Role::Companion && w.home == Home::Workspace { n })
    }
    /// The companions of `pid`, oldest first.
    pub fn companions_of(&self, pid: u32) -> Vec<&str> {
        self.ordered(|w| w.role == Role::Companion && w.pid == pid)
    }
    pub fn role_of(&self, window: &str) -> Option<Role> {
        self.windows.get(window).map(|w| w.role)
    }
    /// The window a companion lives with: the newest main window of its process.
    fn main_of(&self, window: &str) -> Option<WindowId> {
        self.main_for(self.windows.get(window)?.pid)
    }
    fn main_for(&self, pid: u32) -> Option<WindowId> {
        self.windows
            .iter()
            .filter(|(_, w)| w.pid == pid && w.role == Role::Main)
            .max_by_key(|(_, w)| w.seq)
            .map(|(id, _)| id.clone())
    }
    /// Puts every companion of `main`'s process where `main` is (R-D2). One effect per companion
    /// that was elsewhere.
    fn gather_companions(&mut self, main: &str, effects: &mut Vec<Effect>) {
        let Some((pid, home)) = self.windows.get(main).map(|w| (w.pid, w.home.clone())) else { return };
        let strays: Vec<WindowId> = self
            .companions_of(pid)
            .into_iter()
            .filter(|c| self.windows[*c].home != home)
            .map(String::from)
            .collect();
        for c in strays {
            self.windows.get_mut(&c).unwrap().home = home.clone();
            effects.push(Effect::MoveWindow { window: c, to: home.label() });
        }
    }

    fn ordered(&self, keep: impl Fn(&Window) -> bool) -> Vec<&str> {
        let mut v: Vec<(&u64, &str)> = self
            .windows
            .iter()
            .filter(|(_, w)| keep(w))
            .map(|(id, w)| (&w.seq, id.as_str()))
            .collect();
        v.sort();
        v.into_iter().map(|(_, id)| id).collect()
    }

    /// A window belongs to an agent when it is parked there or its process is one BaneySpaces
    /// started for an agent. Both facts are checked: the guard works by pid *and* window.
    pub fn is_agent_window(&self, window: &str) -> bool {
        self.windows
            .get(window)
            .is_some_and(|w| w.home == Home::Agent || self.is_agent_pid(w.pid, w.start))
    }

    /// True when `pid` is a registered agent process and, if both start times are known, the
    /// same incarnation of it.
    pub fn is_agent_pid(&self, pid: u32, start: u64) -> bool {
        match self.agent_pids.get(&pid) {
            None => false,
            Some(&s) => s == 0 || start == 0 || s == start,
        }
    }

    /// The whole state as JSON: what `state.json`, `baneyspaces state` and conformance `expect` read.
    pub fn view(&self) -> Value {
        let monitors: BTreeMap<&str, Value> = self
            .monitors
            .iter()
            .map(|(id, m)| (id.as_str(), json!({ "slot": m.slot, "current": m.current })))
            .collect();
        let workspaces: BTreeMap<String, Vec<&str>> = WORKSPACES
            .map(|n| (n, self.windows_on(n)))
            .filter(|(_, w)| !w.is_empty())
            .map(|(n, w)| (n.to_string(), w))
            .collect();
        let last_focused: BTreeMap<String, &str> = self
            .last_focused
            .iter()
            .map(|(n, w)| (n.to_string(), w.as_str()))
            .collect();
        let windows: BTreeMap<&str, Value> = self
            .windows
            .iter()
            .map(|(id, w)| (id.as_str(), json!({ "pid": w.pid, "app": w.app, "home": w.home.label(), "role": w.role, "agent_owned": self.is_agent_pid(w.pid, w.start) })))
            .collect();
        let pids: Vec<u32> = self.agent_pids.keys().copied().collect();
        let current = self
            .focused_monitor
            .as_ref()
            .and_then(|m| self.monitors.get(m))
            .map(|m| m.current);
        json!({
            "focused_monitor": self.focused_monitor,
            "current": current,
            "active": self.active,
            "monitors": monitors,
            "last_focused": last_focused,
            "workspaces": workspaces,
            "windows": windows,
            "agent": { "windows": self.agent_windows(), "shown": self.agent_shown, "pids": pids },
            "guard": { "refused": self.refused },
        })
    }

    // ---- the rules ---------------------------------------------------------------------

    pub fn apply(&mut self, ev: Event) -> Result<Vec<Effect>, ModelError> {
        match ev {
            Event::MonitorAdded { monitor } => Ok(self.monitor_added(monitor)),
            Event::MonitorRemoved { monitor } => Ok(self.monitor_removed(&monitor)),
            Event::Open {
                window,
                pid,
                start,
                app,
                monitor,
                workspace,
                role,
                pin,
            } => self.open(window, pid, start, app, monitor, workspace, role, pin),
            Event::ObserveWindow {
                window,
                pid,
                start,
                app,
                workspace,
                role,
            } => self.observe_window(window, pid, start, app, workspace, role),
            Event::Close { window } => Ok(self.close(&window)),
            Event::Switch { n } => self.switch(n),
            Event::Move { n, window, follow } => self.move_window(n, window, follow),
            Event::Activate { window, cause } => Ok(self.activate(window, cause)),
            Event::ObserveMove { window, n } => self.observe_move(&window, n),
            Event::ObserveWorkspace { monitor, n } => self.observe_workspace(&monitor, n),
            Event::ObserveSpecial { shown } => Ok(self.observe_special(shown)),
            Event::ObserveFocusMonitor { monitor } => self.observe_focus_monitor(&monitor),
            Event::FocusMonitor { monitor } => self.focus_monitor(&monitor),
            Event::AgentRegister { pid, start } => Ok(self.agent_register(pid, start)),
            Event::AgentExit { pid } => {
                self.agent_pids.remove(&pid);
                Ok(vec![])
            }
            Event::AgentShow => Ok(self.agent_show()),
            Event::AgentHide => Ok(self.agent_hide()),
            Event::AgentToggle => Ok(if self.agent_shown {
                self.agent_hide()
            } else {
                self.agent_show()
            }),
            Event::AgentSend { window } => self.agent_send(&window),
            Event::AgentBring { window } => self.agent_bring(&window),
        }
    }

    fn range(n: u8) -> Result<u8, ModelError> {
        if WORKSPACES.contains(&n) {
            Ok(n)
        } else {
            Err(ModelError::new(
                "invalid_args",
                format!("workspace {n} is outside 1-9"),
            ))
        }
    }

    /// R-M2: what a display without a workspace gets: the one it showed last if nobody shows it,
    /// else the first empty workspace nobody shows, else the first nobody shows.
    pub fn pick_for(&self, id: &str) -> u8 {
        self.pick(id)
    }

    fn pick(&self, id: &str) -> u8 {
        let taken: BTreeSet<u8> = self
            .monitors
            .iter()
            .filter(|(k, _)| k.as_str() != id)
            .map(|(_, m)| m.current)
            .collect();
        if let Some(&last) = self.last_shown.get(id) {
            if last != 0 && !taken.contains(&last) {
                return last;
            }
        }
        let free: Vec<u8> = WORKSPACES.filter(|n| !taken.contains(n)).collect();
        free.iter()
            .copied()
            .find(|n| self.windows_on(*n).is_empty())
            .or_else(|| free.first().copied())
            .unwrap_or(0)
    }

    fn monitor_added(&mut self, id: MonitorId) -> Vec<Effect> {
        if self.monitors.contains_key(&id) {
            return vec![];
        }
        let taken: BTreeSet<u32> = self.monitors.values().map(|m| m.slot).collect();
        let slot = (0..).find(|s| !taken.contains(s)).unwrap_or(0);
        let first = self.monitors.is_empty();
        let current = if first {
            self.last_shown
                .get(&id)
                .copied()
                .filter(|n| *n != 0)
                .unwrap_or(1)
        } else {
            self.pick(&id)
        };
        self.monitors.insert(id.clone(), Monitor { slot, current });
        self.last_shown.insert(id.clone(), current);
        if self.focused_monitor.is_none() {
            self.focused_monitor = Some(id.clone());
            self.active = self.candidate();
        }
        if first || current == 0 {
            return vec![];
        }
        vec![Effect::ShowWorkspace {
            monitor: id,
            workspace: current,
        }]
    }

    /// R-M3: a display you unplug stops showing its workspace; the windows stay in it, out of
    /// sight, until you go to it.
    fn monitor_removed(&mut self, id: &str) -> Vec<Effect> {
        let Some(gone) = self.monitors.remove(id) else {
            return vec![];
        };
        if gone.current != 0 {
            self.last_shown.insert(id.to_string(), gone.current);
        }
        if self.focused_monitor.as_deref() == Some(id) {
            self.focused_monitor = self
                .monitors
                .iter()
                .min_by_key(|(_, m)| m.slot)
                .map(|(k, _)| k.clone());
            self.active = self.candidate();
        }
        vec![]
    }

    /// Which window should be in front on the focused display.
    fn candidate(&self) -> Option<WindowId> {
        let mon = self.focused_monitor.as_ref()?;
        self.candidate_on(self.monitors.get(mon)?.current)
    }

    fn candidate_on(&self, n: u8) -> Option<WindowId> {
        if n == 0 {
            return None;
        }
        if let Some(w) = self.last_focused.get(&n) {
            if self.windows_on(n).contains(&w.as_str()) {
                return Some(w.clone());
            }
        }
        self.windows_on(n).first().map(|s| s.to_string())
    }

    fn forget_focus(&mut self, window: &str) {
        self.last_focused.retain(|_, w| w != window);
    }

    #[allow(clippy::too_many_arguments)]
    fn open(
        &mut self,
        window: WindowId,
        pid: u32,
        start: u64,
        app: String,
        monitor: Option<MonitorId>,
        workspace: Option<u8>,
        role: Role,
        pin: Option<String>,
    ) -> Result<Vec<Effect>, ModelError> {
        if self.windows.contains_key(&window) {
            return Ok(vec![]);
        }
        // R-D1: a window that is not tracked is not moved, counted or followed.
        if role == Role::Ignore {
            return Ok(vec![]);
        }
        self.seq += 1;
        let seq = self.seq;
        // R-A3: a window an agent process opens joins the agent workspace, never yours. R-D9: so does
        // a window the device table pins there (the sandbox view), whoever opened it.
        if self.is_agent_pid(pid, start) || (pin.as_deref() == Some("agent") && role == Role::Main) {
            self.windows.insert(
                window.clone(),
                Window {
                    pid,
                    start,
                    app,
                    home: Home::Agent,
                    seq,
                    role,
                },
            );
            let mut effects = vec![Effect::MoveWindow {
                window: window.clone(),
                to: "agent".into(),
            }];
            if role == Role::Main {
                self.gather_companions(&window, &mut effects);
            }
            return Ok(effects);
        }
        // R-D2: a companion opens where its main window is, wherever the compositor put it.
        if role == Role::Companion {
            let main_home = self.main_for(pid).and_then(|m| self.windows.get(&m)).map(|m| m.home.clone());
            if let Some(home) = main_home {
                let placed = workspace.map(|n| Home::Workspace { n });
                self.windows.insert(
                    window.clone(),
                    Window {
                        pid,
                        start,
                        app,
                        home: home.clone(),
                        seq,
                        role,
                    },
                );
                if placed.as_ref() == Some(&home) {
                    return Ok(vec![]);
                }
                return Ok(vec![Effect::MoveWindow {
                    window,
                    to: home.label(),
                }]);
            }
        }
        let mon = match monitor.or_else(|| self.focused_monitor.clone()) {
            Some(m) if self.monitors.contains_key(&m) => m,
            Some(m) => return Err(ModelError::new("not_found", format!("no monitor {m}"))),
            None => return Err(ModelError::new("no_monitor", "no monitor is connected")),
        };
        // R-P1: it joins the workspace the display it appeared on is showing.
        let shown = self.monitors[&mon].current;
        let here = if shown != 0 {
            shown
        } else {
            workspace.filter(|n| WORKSPACES.contains(n)).unwrap_or(1)
        };
        let placed = workspace.unwrap_or(here);
        self.windows.insert(
            window.clone(),
            Window {
                pid,
                start,
                app,
                home: Home::Workspace { n: here },
                seq,
                role,
            },
        );
        let mut effects = vec![];
        if placed != here {
            // The compositor put it on a workspace you are not looking at: moved here, silently.
            effects.push(Effect::MoveWindow {
                window: window.clone(),
                to: here.to_string(),
            });
        }
        if role == Role::Main {
            // R-D2: companions that opened first (a toolbar before the window) come to it.
            self.gather_companions(&window, &mut effects);
        }
        if role == Role::Companion || placed != here {
            return Ok(effects);
        }
        self.last_focused.insert(here, window.clone());
        if self.focused_monitor.as_deref() == Some(mon.as_str()) {
            self.active = Some(window);
        }
        Ok(effects)
    }

    fn observe_window(
        &mut self,
        window: WindowId,
        pid: u32,
        start: u64,
        app: String,
        workspace: Option<u8>,
        role: Role,
    ) -> Result<Vec<Effect>, ModelError> {
        if self.windows.contains_key(&window) || role == Role::Ignore {
            return Ok(vec![]);
        }
        self.seq += 1;
        let seq = self.seq;
        let mut effects = vec![];
        let home = match workspace {
            None => Home::Agent,
            Some(_) if self.is_agent_pid(pid, start) => {
                effects.push(Effect::MoveWindow {
                    window: window.clone(),
                    to: "agent".into(),
                });
                Home::Agent
            }
            Some(n) => Home::Workspace { n: Self::range(n)? },
        };
        self.windows.insert(
            window.clone(),
            Window {
                pid,
                start,
                app,
                home,
                seq,
                role,
            },
        );
        // R-D2: a window already open when the daemon started is mirrored where it is, but a
        // companion found elsewhere than its main window is put back with it.
        if role == Role::Companion {
            if let Some(main) = self.main_for(pid) {
                let home = self.windows[&main].home.clone();
                if self.windows[&window].home != home {
                    self.windows.get_mut(&window).unwrap().home = home.clone();
                    effects.push(Effect::MoveWindow { window, to: home.label() });
                }
            }
        } else {
            self.gather_companions(&window, &mut effects);
        }
        Ok(effects)
    }

    fn close(&mut self, window: &str) -> Vec<Effect> {
        if self.windows.remove(window).is_none() {
            return vec![];
        }
        self.forget_focus(window);
        if self.before_agent.as_deref() == Some(window) {
            self.before_agent = None;
        }
        if self.active.as_deref() == Some(window) {
            // R-E1: empty means empty. Focus falls to this workspace or to nothing, never to another workspace.
            self.active = if self.agent_shown {
                self.agent_windows().first().map(|s| s.to_string())
            } else {
                self.candidate()
            };
        }
        vec![]
    }

    fn hide_agent_first(&mut self, effects: &mut Vec<Effect>) {
        if self.agent_shown {
            self.agent_shown = false;
            effects.push(Effect::HideAgent);
        }
    }

    /// Makes the focused display show `n`, or goes to the display that already shows it
    /// (R-S2, R-S3). Returns whether anything changed.
    fn show(&mut self, n: u8, effects: &mut Vec<Effect>) {
        let focused = self.focused_monitor.clone().unwrap_or_default();
        match self.shown_on(n).map(String::from) {
            Some(there) => {
                if there != focused {
                    self.focused_monitor = Some(there.clone());
                    effects.push(Effect::FocusMonitor { monitor: there });
                }
            }
            None => {
                if let Some(m) = self.monitors.get_mut(&focused) {
                    m.current = n;
                }
                self.last_shown.insert(focused.clone(), n);
                effects.push(Effect::ShowWorkspace {
                    monitor: focused,
                    workspace: n,
                });
            }
        }
    }

    fn switch(&mut self, n: u8) -> Result<Vec<Effect>, ModelError> {
        let n = Self::range(n)?;
        let focused = self
            .focused_monitor
            .clone()
            .ok_or_else(|| ModelError::new("no_monitor", "no monitor is connected"))?;
        let mut effects = vec![];
        // R-S4: the workspace you are already on is a no-op, unless the agent workspace is covering it.
        if self.shown_on(n) == Some(focused.as_str()) && !self.agent_shown {
            return Ok(effects);
        }
        self.hide_agent_first(&mut effects);
        self.show(n, &mut effects);
        self.active = self.candidate_on(n);
        if let Some(w) = &self.active {
            effects.push(Effect::FocusWindow { window: w.clone() });
        }
        Ok(effects)
    }

    fn move_window(
        &mut self,
        n: u8,
        window: Option<WindowId>,
        follow: bool,
    ) -> Result<Vec<Effect>, ModelError> {
        let n = Self::range(n)?;
        let w = window
            .or_else(|| self.active.clone())
            .ok_or_else(|| ModelError::new("not_found", "there is no front window to move"))?;
        // R-D4: a companion is not moved alone. Moving the toolbar moves the window it belongs to.
        let w = match self.windows.get(&w) {
            Some(c) if c.role == Role::Companion => self.main_of(&w).unwrap_or(w),
            _ => w,
        };
        let win = self
            .windows
            .get(&w)
            .ok_or_else(|| ModelError::new("not_found", format!("no window {w}")))?;
        if self.is_agent_window(&w) {
            return Err(ModelError::new("agent_window", "agent windows stay on the agent workspace; use agent bring for a window you parked"));
        }
        let Home::Workspace { n: from } = win.home else {
            unreachable!()
        };
        if from == n {
            return Ok(vec![]);
        }
        let mut effects = vec![];
        if follow {
            self.hide_agent_first(&mut effects);
        }
        self.windows.get_mut(&w).unwrap().home = Home::Workspace { n };
        if self.last_focused.get(&from) == Some(&w) {
            self.last_focused.remove(&from);
        }
        effects.push(Effect::MoveWindow {
            window: w.clone(),
            to: n.to_string(),
        });
        self.gather_companions(&w, &mut effects);
        if !follow {
            // R-V3: sent and left behind. The window moves; you, your workspaces and your focus do not.
            let visible_here = self.candidate_on(n).is_some()
                && self
                    .focused_monitor
                    .as_deref()
                    .is_some_and(|f| self.shown_on(n) == Some(f));
            if self.active.as_deref() == Some(w.as_str()) && !visible_here {
                self.active = self.candidate();
            }
            return Ok(effects);
        }
        // R-V2: you follow it: to the display that shows n, else n comes up on this display.
        self.show(n, &mut effects);
        self.last_focused.insert(n, w.clone());
        self.active = Some(w.clone());
        effects.push(Effect::FocusWindow { window: w });
        Ok(effects)
    }

    fn activate(&mut self, window: Option<WindowId>, cause: Cause) -> Vec<Effect> {
        let Some(w) = window else {
            self.active = None;
            return vec![];
        };
        if !self.windows.contains_key(&w) {
            return vec![]; // not ours: a window on a workspace outside the scheme
        }
        // R-D3: using a companion is using its main window: same follow rules, same record of focus.
        let w = match self.windows.get(&w) {
            Some(c) if c.role == Role::Companion => self.main_of(&w).unwrap_or(w),
            _ => w,
        };
        let mut effects = vec![];
        let restore = |m: &Self, effects: &mut Vec<Effect>| {
            if let Some(p) = &m.active {
                effects.push(Effect::FocusWindow { window: p.clone() });
            }
        };
        // R-G1: the guard. An agent window never takes focus or your workspace, whoever asked.
        // Once you have shown the agent workspace yourself, you are looking at it and focus is yours.
        if self.is_agent_window(&w) {
            if self.agent_shown && cause == Cause::User {
                self.active = Some(w);
                return effects;
            }
            self.refused += 1;
            effects.push(Effect::RefuseFollow {
                window: w,
                reason: "agent_window".into(),
            });
            restore(self, &mut effects);
            return effects;
        }
        let Home::Workspace { n } = self.windows[&w].home else {
            return effects;
        };
        let at = self.shown_on(n).map(String::from);
        let here = at.is_some() && at.as_deref() == self.focused_monitor.as_deref();
        // R-F2: only a user-caused activation follows. An app asking for attention does not move you.
        if cause != Cause::User && !here {
            self.refused += 1;
            effects.push(Effect::RefuseFollow {
                window: w,
                reason: "not_user_caused".into(),
            });
            restore(self, &mut effects);
            return effects;
        }
        match at {
            None => {
                // R-F1: the workspace is out of sight; it comes up on the display you are on.
                self.hide_agent_first(&mut effects);
                self.show(n, &mut effects);
                effects.push(Effect::FocusWindow { window: w.clone() });
            }
            Some(there) if !here => self.focused_monitor = Some(there), // the compositor already went there
            Some(_) => {}
        }
        self.last_focused.insert(n, w.clone());
        self.active = Some(w);
        effects
    }

    fn observe_workspace(&mut self, monitor: &str, n: u8) -> Result<Vec<Effect>, ModelError> {
        if n != 0 {
            Self::range(n)?;
        }
        let m = self
            .monitors
            .get_mut(monitor)
            .ok_or_else(|| ModelError::new("not_found", format!("no monitor {monitor}")))?;
        m.current = n;
        if n != 0 {
            self.last_shown.insert(monitor.to_string(), n);
        }
        Ok(vec![])
    }

    fn observe_move(&mut self, window: &str, n: Option<u8>) -> Result<Vec<Effect>, ModelError> {
        if !self.windows.contains_key(window) {
            return Ok(vec![]);
        }
        let to = match n {
            Some(n) => Home::Workspace { n: Self::range(n)? },
            None => Home::Agent,
        };
        // R-D5: a companion dragged off alone goes back to its main window's workspace; the
        // compositor is told, silently.
        if self.windows[window].role == Role::Companion {
            let Some(home) = self.main_of(window).and_then(|m| self.windows.get(&m)).map(|m| m.home.clone()) else {
                self.windows.get_mut(window).unwrap().home = to;
                return Ok(vec![]);
            };
            self.windows.get_mut(window).unwrap().home = home.clone();
            return Ok(if home == to { vec![] } else { vec![Effect::MoveWindow { window: window.to_string(), to: home.label() }] });
        }
        self.forget_focus(window);
        self.windows.get_mut(window).unwrap().home = to;
        if self.active.as_deref() == Some(window) && !self.agent_shown {
            let here = match &self.windows[window].home {
                Home::Workspace { n } => {
                    self.shown_on(*n).is_some()
                        && self.shown_on(*n) == self.focused_monitor.as_deref()
                }
                Home::Agent => false,
            };
            if !here {
                self.active = self.candidate();
            }
        }
        // R-D2: the companions go with it.
        let mut effects = vec![];
        self.gather_companions(window, &mut effects);
        Ok(effects)
    }

    /// R-G3: the agent workspace appearing on its own (a window activated inside it, a stray
    /// toggle) is hidden again. Showing it is a thing only you do.
    fn observe_special(&mut self, shown: bool) -> Vec<Effect> {
        if shown && !self.agent_shown {
            self.refused += 1;
            return vec![Effect::HideAgent];
        }
        if !shown && self.agent_shown {
            self.agent_shown = false;
            self.active = self
                .before_agent
                .take()
                .filter(|w| self.windows.contains_key(w))
                .or_else(|| self.candidate());
        }
        vec![]
    }

    fn observe_focus_monitor(&mut self, monitor: &str) -> Result<Vec<Effect>, ModelError> {
        if !self.monitors.contains_key(monitor) {
            return Err(ModelError::new(
                "not_found",
                format!("no monitor {monitor}"),
            ));
        }
        let changed = self.focused_monitor.as_deref() != Some(monitor);
        self.focused_monitor = Some(monitor.to_string());
        // Nothing in front yet (a model just rebuilt, its windows now known): take the display's own.
        if changed || self.active.is_none() {
            self.active = self.candidate();
        }
        Ok(vec![])
    }

    fn focus_monitor(&mut self, monitor: &str) -> Result<Vec<Effect>, ModelError> {
        let before = self.focused_monitor.clone();
        self.observe_focus_monitor(monitor)?;
        if before.as_deref() == Some(monitor) {
            return Ok(vec![]);
        }
        let mut effects = vec![Effect::FocusMonitor {
            monitor: monitor.to_string(),
        }];
        if let Some(w) = &self.active {
            effects.push(Effect::FocusWindow { window: w.clone() });
        }
        Ok(effects)
    }

    fn agent_register(&mut self, pid: u32, start: u64) -> Vec<Effect> {
        self.agent_pids.insert(pid, start);
        // An agent process has no window on your workspaces.
        let strays: Vec<WindowId> = self
            .ordered(|w| w.pid == pid && w.home != Home::Agent && (w.start == 0 || start == 0 || w.start == start))
            .into_iter()
            .map(String::from)
            .collect();
        let mut effects = vec![];
        for w in strays {
            self.send_to_agent(&w);
            effects.push(Effect::MoveWindow {
                window: w,
                to: "agent".into(),
            });
        }
        effects
    }

    fn send_to_agent(&mut self, window: &str) {
        let was_active = self.active.as_deref() == Some(window);
        self.forget_focus(window);
        self.windows.get_mut(window).unwrap().home = Home::Agent;
        if was_active {
            self.active = self.candidate();
        }
    }

    fn agent_show(&mut self) -> Vec<Effect> {
        if self.agent_shown {
            return vec![];
        }
        self.agent_shown = true;
        self.before_agent = self.active.clone();
        self.active = self.agent_windows().first().map(|s| s.to_string());
        vec![Effect::ShowAgent]
    }

    /// R-A5: hiding the agent workspace puts back exactly the window you had in front.
    fn agent_hide(&mut self) -> Vec<Effect> {
        if !self.agent_shown {
            return vec![];
        }
        self.agent_shown = false;
        self.active = self
            .before_agent
            .take()
            .filter(|w| self.windows.contains_key(w))
            .or_else(|| self.candidate());
        let mut effects = vec![Effect::HideAgent];
        if let Some(w) = &self.active {
            effects.push(Effect::FocusWindow { window: w.clone() });
        }
        effects
    }

    fn agent_send(&mut self, window: &str) -> Result<Vec<Effect>, ModelError> {
        let w = self
            .windows
            .get(window)
            .ok_or_else(|| ModelError::new("not_found", format!("no window {window}")))?;
        if w.home == Home::Agent {
            return Ok(vec![]);
        }
        let window = &match w.role {
            Role::Companion => self.main_of(window).unwrap_or_else(|| window.to_string()),
            _ => window.to_string(),
        };
        self.send_to_agent(window);
        let mut effects = vec![Effect::MoveWindow {
            window: window.to_string(),
            to: "agent".into(),
        }];
        self.gather_companions(window, &mut effects);
        Ok(effects)
    }

    fn agent_bring(&mut self, window: &str) -> Result<Vec<Effect>, ModelError> {
        let w = self
            .windows
            .get(window)
            .ok_or_else(|| ModelError::new("not_found", format!("no window {window}")))?;
        if w.home != Home::Agent {
            return Ok(vec![]);
        }
        if self.is_agent_pid(w.pid, w.start) {
            return Err(ModelError::new("agent_window", "that window belongs to a process started for an agent; it stays on the agent workspace"));
        }
        let mon = self
            .focused_monitor
            .clone()
            .ok_or_else(|| ModelError::new("no_monitor", "no monitor is connected"))?;
        let n = Some(self.monitors[&mon].current)
            .filter(|n| *n != 0)
            .unwrap_or(1);
        self.windows.get_mut(window).unwrap().home = Home::Workspace { n };
        let mut effects = vec![Effect::MoveWindow {
            window: window.to_string(),
            to: n.to_string(),
        }];
        self.gather_companions(window, &mut effects);
        Ok(effects)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(v: Value) -> Event {
        serde_json::from_value(v).unwrap()
    }

    fn two_monitors() -> Model {
        let mut m = Model::new();
        m.apply(ev(json!({"do":"monitor_added","monitor":"A"})))
            .unwrap();
        m.apply(ev(json!({"do":"monitor_added","monitor":"B"})))
            .unwrap();
        m
    }

    #[test]
    fn displays_never_show_the_same_workspace() {
        let mut m = two_monitors();
        assert_eq!((m.current("A"), m.current("B")), (Some(1), Some(2)));
        // Going to the one B shows goes to B; nothing is shown twice.
        m.apply(ev(json!({"do":"switch","n":2}))).unwrap();
        assert_eq!(m.focused_monitor(), Some("B"));
        assert_eq!((m.current("A"), m.current("B")), (Some(1), Some(2)));
        for n in 1..=9u8 {
            m.apply(ev(json!({"do":"switch","n":n}))).unwrap();
            let (a, b) = (m.current("A").unwrap(), m.current("B").unwrap());
            assert_ne!(a, b, "after switch {n}");
            assert!(m.shown_on(n).is_some());
        }
    }

    #[test]
    fn switching_to_the_workspace_you_are_on_does_nothing() {
        let mut m = two_monitors();
        assert!(m
            .apply(ev(json!({"do":"switch","n":1})))
            .unwrap()
            .is_empty());
    }

    #[test]
    fn out_of_range_is_refused() {
        let mut m = two_monitors();
        assert_eq!(
            m.apply(ev(json!({"do":"switch","n":10}))).unwrap_err().code,
            "invalid_args"
        );
        assert_eq!(
            m.apply(ev(json!({"do":"switch","n":0}))).unwrap_err().code,
            "invalid_args"
        );
    }

    #[test]
    fn slots_are_reused_lowest_first() {
        let mut m = two_monitors();
        m.apply(ev(json!({"do":"monitor_removed","monitor":"A"})))
            .unwrap();
        m.apply(ev(json!({"do":"monitor_added","monitor":"C"})))
            .unwrap();
        assert_eq!(m.slot("C"), Some(0));
        assert_eq!(m.slot("B"), Some(1));
    }

    #[test]
    fn an_unplugged_displays_windows_wait_in_their_workspace() {
        let mut m = two_monitors();
        m.apply(ev(json!({"do":"observe_focus_monitor","monitor":"B"})))
            .unwrap();
        m.apply(ev(json!({"do":"open","window":"w1","pid":1})))
            .unwrap();
        m.apply(ev(json!({"do":"monitor_removed","monitor":"B"})))
            .unwrap();
        assert_eq!(m.view()["workspaces"]["2"], json!(["w1"]));
        assert_eq!(m.shown_on(2), None);
    }
}
