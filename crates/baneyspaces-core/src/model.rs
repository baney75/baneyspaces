//! The workspace model: pure state plus the rules in `spec/workspaces.md`.
//!
//! The model never talks to a compositor. A platform feeds it [`Event`]s (what the user asked for,
//! what the compositor reported) and carries out the [`Effect`]s it returns. Every platform's tests
//! replay `spec/conformance/*.json` against this same code path, so a rule that is not in `spec/`
//! does not exist.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

pub const WORKSPACES: std::ops::RangeInclusive<u8> = 1..=9;

pub type WindowId = String;
pub type MonitorId = String;

/// Where a window lives.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Home {
    Workspace {
        monitor: MonitorId,
        n: u8,
    },
    /// The agent workspace: parked out of view, never shown unless the user asks.
    Agent,
}

impl Home {
    pub fn label(&self) -> String {
        match self {
            Home::Workspace { monitor, n } => format!("{monitor}:{n}"),
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
    Open {
        window: WindowId,
        pid: u32,
        #[serde(default)]
        app: String,
        /// Where the compositor put it. Defaults to the monitor you are on.
        #[serde(default)]
        monitor: Option<MonitorId>,
        /// The workspace number it was put on. Defaults to that monitor's current one.
        #[serde(default)]
        workspace: Option<u8>,
    },
    Close {
        window: WindowId,
    },
    Switch {
        n: u8,
        #[serde(default)]
        monitor: Option<MonitorId>,
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
    /// Silent: no focus change, no workspace change. `to` is `"<monitor>:<n>"` or `"agent"`.
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
    current: u8,
    last_focused: BTreeMap<u8, WindowId>,
}

#[derive(Clone, Debug)]
struct Window {
    pid: u32,
    app: String,
    home: Home,
    seq: u64,
}

#[derive(Clone, Debug, Default)]
pub struct Model {
    monitors: BTreeMap<MonitorId, Monitor>,
    focused_monitor: Option<MonitorId>,
    windows: BTreeMap<WindowId, Window>,
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
    pub fn current(&self, monitor: &str) -> Option<u8> {
        self.monitors.get(monitor).map(|m| m.current)
    }
    pub fn slot(&self, monitor: &str) -> Option<u32> {
        self.monitors.get(monitor).map(|m| m.slot)
    }
    pub fn monitor_for_slot(&self, slot: u32) -> Option<&str> {
        self.monitors
            .iter()
            .find(|(_, m)| m.slot == slot)
            .map(|(k, _)| k.as_str())
    }
    pub fn monitors(&self) -> impl Iterator<Item = &str> {
        self.monitors.keys().map(String::as_str)
    }
    pub fn home(&self, window: &str) -> Option<&Home> {
        self.windows.get(window).map(|w| &w.home)
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
        self.ordered(|w| w.home == Home::Agent)
    }
    /// Windows on one workspace, oldest first.
    pub fn windows_on(&self, monitor: &str, n: u8) -> Vec<&str> {
        self.ordered(
            |w| matches!(&w.home, Home::Workspace { monitor: m, n: k } if m == monitor && *k == n),
        )
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
            .is_some_and(|w| w.home == Home::Agent || self.agent_pids.contains_key(&w.pid))
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
            .map(|(id, m)| {
                let lf: BTreeMap<String, &str> = m
                    .last_focused
                    .iter()
                    .map(|(n, w)| (n.to_string(), w.as_str()))
                    .collect();
                (
                    id.as_str(),
                    json!({ "slot": m.slot, "current": m.current, "last_focused": lf }),
                )
            })
            .collect();
        let mut workspaces: BTreeMap<String, Vec<&str>> = BTreeMap::new();
        for (id, m) in &self.monitors {
            for n in WORKSPACES {
                let ws = self.windows_on(id, n);
                if !ws.is_empty() {
                    workspaces.insert(format!("{id}:{n}"), ws);
                }
                let _ = m;
            }
        }
        // Windows whose monitor is gone wait out of sight.
        for w in self.windows.values() {
            if let Home::Workspace { monitor, n } = &w.home {
                if !self.monitors.contains_key(monitor) {
                    workspaces.entry(format!("{monitor}:{n}")).or_default();
                }
            }
        }
        for (key, list) in workspaces.iter_mut() {
            if list.is_empty() {
                if let Some((m, n)) = key.rsplit_once(':') {
                    *list = self.windows_on(m, n.parse().unwrap_or(0));
                }
            }
        }
        let windows: BTreeMap<&str, Value> = self
            .windows
            .iter()
            .map(|(id, w)| (id.as_str(), json!({ "pid": w.pid, "app": w.app, "home": w.home.label(), "agent_owned": self.agent_pids.contains_key(&w.pid) })))
            .collect();
        let pids: Vec<u32> = self.agent_pids.keys().copied().collect();
        json!({
            "focused_monitor": self.focused_monitor,
            "active": self.active,
            "monitors": monitors,
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
                app,
                monitor,
                workspace,
            } => self.open(window, pid, app, monitor, workspace),
            Event::Close { window } => Ok(self.close(&window)),
            Event::Switch { n, monitor } => self.switch(n, monitor),
            Event::Move { n, window, follow } => self.move_window(n, window, follow),
            Event::Activate { window, cause } => Ok(self.activate(window, cause)),
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

    fn monitor_added(&mut self, id: MonitorId) -> Vec<Effect> {
        if self.monitors.contains_key(&id) {
            return vec![];
        }
        let taken: BTreeSet<u32> = self.monitors.values().map(|m| m.slot).collect();
        let slot = (0..).find(|s| !taken.contains(s)).unwrap_or(0);
        self.monitors.insert(
            id.clone(),
            Monitor {
                slot,
                current: 1,
                last_focused: BTreeMap::new(),
            },
        );
        if self.focused_monitor.is_none() {
            self.focused_monitor = Some(id.clone());
        }
        // Windows that waited out of sight for this monitor come back to it.
        let waiting: Vec<WindowId> = self
            .ordered(|w| matches!(&w.home, Home::Workspace { monitor, .. } if *monitor == id))
            .into_iter()
            .map(String::from)
            .collect();
        let _ = waiting; // they already carry this monitor id; nothing to move.
        vec![]
    }

    /// R-M2: a monitor you unplug hands its windows to the lowest-numbered monitor left, same
    /// workspace number. With no monitor left they wait out of sight for it to return.
    fn monitor_removed(&mut self, id: &str) -> Vec<Effect> {
        let Some(gone) = self.monitors.remove(id) else {
            return vec![];
        };
        let _ = gone;
        let heir = self
            .monitors
            .iter()
            .min_by_key(|(_, m)| m.slot)
            .map(|(k, _)| k.clone());
        let mut effects = vec![];
        if let Some(heir) = &heir {
            let movers: Vec<WindowId> = self
                .ordered(|w| matches!(&w.home, Home::Workspace { monitor, .. } if monitor == id))
                .into_iter()
                .map(String::from)
                .collect();
            for w in movers {
                let n = match &self.windows[&w].home {
                    Home::Workspace { n, .. } => *n,
                    Home::Agent => continue,
                };
                self.windows.get_mut(&w).unwrap().home = Home::Workspace {
                    monitor: heir.clone(),
                    n,
                };
                effects.push(Effect::MoveWindow {
                    window: w,
                    to: format!("{heir}:{n}"),
                });
            }
        }
        if self.focused_monitor.as_deref() == Some(id) {
            self.focused_monitor = heir;
            self.active = self.candidate();
        }
        effects
    }

    /// Which window should be active on the focused monitor's current workspace.
    fn candidate(&self) -> Option<WindowId> {
        let mon = self.focused_monitor.as_ref()?;
        let m = self.monitors.get(mon)?;
        self.candidate_on(mon, m.current)
    }

    fn candidate_on(&self, mon: &str, n: u8) -> Option<WindowId> {
        let m = self.monitors.get(mon)?;
        if let Some(w) = m.last_focused.get(&n) {
            if self.windows_on(mon, n).contains(&w.as_str()) {
                return Some(w.clone());
            }
        }
        self.windows_on(mon, n).first().map(|s| s.to_string())
    }

    fn open(
        &mut self,
        window: WindowId,
        pid: u32,
        app: String,
        monitor: Option<MonitorId>,
        workspace: Option<u8>,
    ) -> Result<Vec<Effect>, ModelError> {
        if self.windows.contains_key(&window) {
            return Ok(vec![]);
        }
        self.seq += 1;
        let seq = self.seq;
        // R-A3: a window an agent process opens joins the agent workspace, never yours.
        if self.agent_pids.contains_key(&pid) {
            self.windows.insert(
                window.clone(),
                Window {
                    pid,
                    app,
                    home: Home::Agent,
                    seq,
                },
            );
            return Ok(vec![Effect::MoveWindow {
                window,
                to: "agent".into(),
            }]);
        }
        let mon = match monitor.or_else(|| self.focused_monitor.clone()) {
            Some(m) if self.monitors.contains_key(&m) => m,
            Some(m) => return Err(ModelError::new("not_found", format!("no monitor {m}"))),
            None => return Err(ModelError::new("no_monitor", "no monitor is connected")),
        };
        let current = self.monitors[&mon].current;
        let placed = workspace.unwrap_or(current);
        self.windows.insert(
            window.clone(),
            Window {
                pid,
                app,
                home: Home::Workspace {
                    monitor: mon.clone(),
                    n: current,
                },
                seq,
            },
        );
        // R-P1: new windows land where you are. One the compositor put elsewhere is moved here, silently.
        if placed != current {
            return Ok(vec![Effect::MoveWindow {
                window,
                to: format!("{mon}:{current}"),
            }]);
        }
        self.monitors
            .get_mut(&mon)
            .unwrap()
            .last_focused
            .insert(current, window.clone());
        if self.focused_monitor.as_deref() == Some(mon.as_str()) {
            self.active = Some(window);
        }
        Ok(vec![])
    }

    fn close(&mut self, window: &str) -> Vec<Effect> {
        let Some(w) = self.windows.remove(window) else {
            return vec![];
        };
        if let Home::Workspace { monitor, n } = &w.home {
            if let Some(m) = self.monitors.get_mut(monitor) {
                if m.last_focused.get(n).map(String::as_str) == Some(window) {
                    m.last_focused.remove(n);
                }
            }
        }
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

    fn switch(&mut self, n: u8, monitor: Option<MonitorId>) -> Result<Vec<Effect>, ModelError> {
        let n = Self::range(n)?;
        let focused = self
            .focused_monitor
            .clone()
            .ok_or_else(|| ModelError::new("no_monitor", "no monitor is connected"))?;
        let mon = monitor.unwrap_or_else(|| focused.clone());
        let cur = self
            .monitors
            .get(&mon)
            .ok_or_else(|| ModelError::new("not_found", format!("no monitor {mon}")))?
            .current;
        let mut effects = vec![];
        // R-S3: the workspace you are already on is a no-op, unless the agent workspace is covering it.
        if cur == n && !(self.agent_shown && mon == focused) {
            return Ok(effects);
        }
        if mon == focused {
            self.hide_agent_first(&mut effects);
        }
        self.monitors.get_mut(&mon).unwrap().current = n;
        if cur != n {
            effects.push(Effect::ShowWorkspace {
                monitor: mon.clone(),
                workspace: n,
            });
        }
        if mon == focused {
            self.active = self.candidate_on(&mon, n);
            if let Some(w) = &self.active {
                effects.push(Effect::FocusWindow { window: w.clone() });
            }
        }
        Ok(effects)
    }

    fn move_window(&mut self, n: u8, window: Option<WindowId>, follow: bool) -> Result<Vec<Effect>, ModelError> {
        let n = Self::range(n)?;
        let w = window
            .or_else(|| self.active.clone())
            .ok_or_else(|| ModelError::new("not_found", "there is no front window to move"))?;
        let win = self
            .windows
            .get(&w)
            .ok_or_else(|| ModelError::new("not_found", format!("no window {w}")))?;
        if self.is_agent_window(&w) {
            return Err(ModelError::new("agent_window", "agent windows stay on the agent workspace; use agent bring for a window you parked"));
        }
        let Home::Workspace { monitor, n: from } = win.home.clone() else {
            unreachable!()
        };
        if from == n {
            return Ok(vec![]);
        }
        let mut effects = vec![];
        if follow {
            self.hide_agent_first(&mut effects);
        }
        self.windows.get_mut(&w).unwrap().home = Home::Workspace { monitor: monitor.clone(), n };
        if let Some(m) = self.monitors.get_mut(&monitor) {
            if m.last_focused.get(&from) == Some(&w) {
                m.last_focused.remove(&from);
            }
        }
        effects.push(Effect::MoveWindow { window: w.clone(), to: format!("{monitor}:{n}") });
        if !follow {
            // R-V4: sent and left behind. The window moves; you, your workspace and your focus do not.
            if self.active.as_deref() == Some(w.as_str()) {
                self.active = self.candidate();
            }
            return Ok(effects);
        }
        if let Some(m) = self.monitors.get_mut(&monitor) {
            m.last_focused.insert(n, w.clone());
            m.current = n;
        }
        effects.push(Effect::ShowWorkspace { monitor: monitor.clone(), workspace: n });
        // R-V3: you follow the window you moved, onto its monitor.
        if self.focused_monitor.as_deref() != Some(monitor.as_str()) {
            self.focused_monitor = Some(monitor.clone());
            effects.push(Effect::FocusMonitor { monitor });
        }
        effects.push(Effect::FocusWindow { window: w.clone() });
        self.active = Some(w);
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
        let Home::Workspace { monitor, n } = self.windows[&w].home.clone() else {
            return effects;
        };
        let Some(m) = self.monitors.get(&monitor) else {
            return effects;
        }; // waiting out of sight
        let visible = m.current == n;
        let here = self.focused_monitor.as_deref() == Some(monitor.as_str());
        // R-G2: only a user-caused activation follows. An app asking for attention does not move you.
        if cause != Cause::User && !(visible && here) {
            self.refused += 1;
            effects.push(Effect::RefuseFollow {
                window: w,
                reason: "not_user_caused".into(),
            });
            restore(self, &mut effects);
            return effects;
        }
        if !visible {
            self.hide_agent_first(&mut effects);
            self.monitors.get_mut(&monitor).unwrap().current = n;
            effects.push(Effect::ShowWorkspace {
                monitor: monitor.clone(),
                workspace: n,
            });
        }
        if !here {
            self.focused_monitor = Some(monitor.clone());
            if !visible {
                effects.push(Effect::FocusMonitor {
                    monitor: monitor.clone(),
                });
            }
        }
        if !visible {
            effects.push(Effect::FocusWindow { window: w.clone() });
        }
        self.monitors
            .get_mut(&monitor)
            .unwrap()
            .last_focused
            .insert(n, w.clone());
        self.active = Some(w);
        effects
    }

    fn observe_workspace(&mut self, monitor: &str, n: u8) -> Result<Vec<Effect>, ModelError> {
        let n = Self::range(n)?;
        let m = self
            .monitors
            .get_mut(monitor)
            .ok_or_else(|| ModelError::new("not_found", format!("no monitor {monitor}")))?;
        m.current = n;
        Ok(vec![])
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
        if self.focused_monitor.as_deref() != Some(monitor) {
            self.focused_monitor = Some(monitor.to_string());
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
            .ordered(|w| w.pid == pid && w.home != Home::Agent)
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
        if let Some(Home::Workspace { monitor, n }) =
            self.windows.get(window).map(|w| w.home.clone())
        {
            if let Some(m) = self.monitors.get_mut(&monitor) {
                if m.last_focused.get(&n).map(String::as_str) == Some(window) {
                    m.last_focused.remove(&n);
                }
            }
        }
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
        self.send_to_agent(window);
        Ok(vec![Effect::MoveWindow {
            window: window.to_string(),
            to: "agent".into(),
        }])
    }

    fn agent_bring(&mut self, window: &str) -> Result<Vec<Effect>, ModelError> {
        let w = self
            .windows
            .get(window)
            .ok_or_else(|| ModelError::new("not_found", format!("no window {window}")))?;
        if w.home != Home::Agent {
            return Ok(vec![]);
        }
        if self.agent_pids.contains_key(&w.pid) {
            return Err(ModelError::new("agent_window", "that window belongs to a process started for an agent; it stays on the agent workspace"));
        }
        let mon = self
            .focused_monitor
            .clone()
            .ok_or_else(|| ModelError::new("no_monitor", "no monitor is connected"))?;
        let n = self.monitors[&mon].current;
        self.windows.get_mut(window).unwrap().home = Home::Workspace {
            monitor: mon.clone(),
            n,
        };
        Ok(vec![Effect::MoveWindow {
            window: window.to_string(),
            to: format!("{mon}:{n}"),
        }])
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
    fn switch_is_per_monitor() {
        let mut m = two_monitors();
        m.apply(ev(json!({"do":"switch","n":4}))).unwrap();
        assert_eq!(m.current("A"), Some(4));
        assert_eq!(m.current("B"), Some(1));
    }

    #[test]
    fn switching_to_the_same_workspace_does_nothing() {
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
    fn view_lists_waiting_windows_of_a_missing_monitor() {
        let mut m = Model::new();
        m.apply(ev(json!({"do":"monitor_added","monitor":"A"})))
            .unwrap();
        m.apply(ev(json!({"do":"open","window":"w1","pid":1})))
            .unwrap();
        m.apply(ev(json!({"do":"monitor_removed","monitor":"A"})))
            .unwrap();
        let v = m.view();
        assert_eq!(v["workspaces"]["A:1"], json!(["w1"]));
    }
}
