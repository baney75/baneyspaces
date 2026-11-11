//! The verbs an agent uses to manage its own workspace on Hyprland: `workspaces`, `arrange`,
//! `move --window`, `close`, and the session record `open` keeps. The same names, arguments and
//! result fields as the Mac (`HandsRouter+Workspaces.swift`, `ChildWindows.swift` in the macOS app),
//! so an agent's script works on both.
//!
//! Three rules hold for every verb here:
//!
//! - **Nothing is shown and focus never moves.** Every dispatch is built by one of the functions
//!   below, each says why it keeps focus where it is, and `send` refuses any dispatch that `loud`
//!   flags before it reaches Hyprland. Windows are always named by address: a Hyprland dispatcher
//!   with no window acts on the focused one, which is yours.
//! - **Only the agent's windows.** A window is the agent's when its process is one BaneySpaces started
//!   for an agent (pid and start time) and Hyprland has it on `special:agent`, checked again right
//!   before every dispatch. A window you parked there yourself (`agent move <window>`) is still
//!   yours: never laid out, moved or closed. Linux has no lend sheet yet, so what the Mac allows only
//!   through a lend or Full Access is `not_supported` here, and says so.
//! - **`close` closes only what this session's `open` made**, by Hyprland address and `stableId` plus
//!   pid and start time, and only while it is still on `special:agent`. An address can come back for
//!   a later window of the same process; its `stableId` does not, so that window is not the
//!   session's. It never quits an app or kills a process.

#![allow(clippy::result_large_err)] // the crate's convention: an `Envelope` is the error, as in daemon.rs and hands.rs

use crate::daemon::{lock, record, Client, Core, Shared};
use crate::proc;
use crate::scheme::{lua_str, AGENT_SPECIAL};
use baneyspaces_core::envelope::{Envelope, Retry};
use baneyspaces_core::model::{Home, Model};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

// ---- the session record -------------------------------------------------------------------

/// One window an `open` of a session made: the process that owns it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Opened {
    pub pid: u32,
    /// The process start time; 0 when it could not be read.
    pub start: u64,
    /// The app name `open` was given (foot, mpv, ...).
    pub app: String,
    /// Hyprland's `stableId` of the window when it was recorded. An address is reused, this is not:
    /// a later window at the same address has another one. Empty when Hyprland reported none, and
    /// then the record never passes `opened_by`.
    pub stable: String,
}

/// One window of a session's record, with the order it was opened in.
#[derive(Clone, Debug)]
struct Entry {
    o: Opened,
    seq: u64,
}

/// Which windows each agent session opened with `open`, by Hyprland address and process, so
/// `close` closes only those. A window is never recorded for two sessions. Kept in memory: after a
/// daemon restart no session owns anything, so `close` refuses (fails closed).
#[derive(Default, Debug)]
pub struct SessionWindows {
    opened: HashMap<String, HashMap<String, Entry>>,
    seq: u64,
}

impl SessionWindows {
    /// Records `window` for `session`. False when the session is empty or another session owns it.
    pub fn record(&mut self, session: &str, window: &str, o: Opened) -> bool {
        if session.is_empty() || self.owner(window).is_some_and(|s| s != session) {
            return false;
        }
        self.seq += 1;
        let seq = self.seq;
        self.opened.entry(session.to_string()).or_default().insert(window.to_string(), Entry { o, seq });
        true
    }

    pub fn owner(&self, window: &str) -> Option<&str> {
        self.opened.iter().find(|(_, w)| w.contains_key(window)).map(|(s, _)| s.as_str())
    }

    /// Whether this session opened this exact window of this exact process. Start times are compared
    /// when both are known, so a reused pid does not pass. `stable` is the window's `stableId` now: it
    /// must be the one recorded, so another window at a reused address does not pass, and a window
    /// with no `stableId` (then or now) never passes.
    pub fn opened_by(&self, session: &str, window: &str, pid: u32, start: u64, stable: &str) -> bool {
        !session.is_empty()
            && !stable.is_empty()
            && self.opened.get(session).and_then(|w| w.get(window)).is_some_and(|e| e.o.pid == pid && e.o.start != 0 && e.o.start == start && e.o.stable == stable)
    }

    /// Drops what is recorded under this address for any window but the one with this `stableId`.
    pub fn keep_only(&mut self, window: &str, stable: &str) {
        for w in self.opened.values_mut() {
            if w.get(window).is_some_and(|e| stable.is_empty() || e.o.stable != stable) {
                w.remove(window);
            }
        }
    }

    pub fn forget(&mut self, window: &str) {
        for w in self.opened.values_mut() {
            w.remove(window);
        }
    }

    /// This session's windows, address and record, oldest opened first (never by address: a newer
    /// window can have a lower one).
    pub fn of(&self, session: &str) -> Vec<(String, Opened)> {
        let mut v: Vec<(u64, String, Opened)> = self.opened.get(session).map(|w| w.iter().map(|(k, e)| (e.seq, k.clone(), e.o.clone())).collect()).unwrap_or_default();
        v.sort_by_key(|x| x.0);
        v.into_iter().map(|(_, k, o)| (k, o)).collect()
    }
}

// ---- dispatches ---------------------------------------------------------------------------

/// A Hyprland window address as `hyprctl clients` prints it: `0x` and hex digits. Anything else is
/// refused before a selector is built, because a selector Hyprland cannot read means "the focused
/// window" to its dispatchers.
pub fn valid_addr(s: &str) -> bool {
    s.strip_prefix("0x").is_some_and(|h| !h.is_empty() && h.len() <= 16 && h.bytes().all(|b| b.is_ascii_hexdigit()))
}

fn sel(addr: &str) -> String {
    lua_str(&format!("address:{addr}"))
}

/// Floats the window in place so it can take an exact frame. Hyprland's `floatWindow` changes the
/// layout mode and raises the window within its own workspace (stacking order only): it does not
/// focus it, and its workspace stays hidden.
pub fn float_on(addr: &str) -> String {
    format!("hl.dsp.window.float({{ action = \"enable\", window = {} }})", sel(addr))
}

/// An exact size. Hyprland's `resize` resizes the window's layout target and nothing else: no focus,
/// no workspace change.
pub fn resize_to(addr: &str, w: i64, h: i64) -> String {
    format!("hl.dsp.window.resize({{ x = {w}, y = {h}, window = {} }})", sel(addr))
}

/// An exact position, in Hyprland's global layout coordinates. Hyprland's `move` with `x` and `y`
/// moves the window's layout target and nothing else: no focus, no workspace change. Absolute, not a
/// step: `Config::Actions::move` (src/config/shared/actions/ConfigActions.cpp, v0.56.2) moves by
/// `pos - window->position(GEOMETRIC_GOAL)` unless `relative = true`, and `resize` the same with the size.
pub fn move_to(addr: &str, x: i64, y: i64) -> String {
    format!("hl.dsp.window.move({{ x = {x}, y = {y}, window = {} }})", sel(addr))
}

/// Onto the agent workspace without showing it. `follow = false` is Hyprland's silent move
/// (`movetoworkspacesilent`): the target workspace is not shown, and focus changes only if the moved
/// window had it (then to the window under it). An agent window never has focus: the guard puts
/// yours back whenever one gets it.
pub fn to_agent(addr: &str) -> String {
    format!("hl.dsp.window.move({{ workspace = {}, follow = false, window = {} }})", lua_str(AGENT_SPECIAL), sel(addr))
}

/// Asks the window to close, as its close button or Super+W would (an xdg-toplevel close request).
/// Hyprland's `closeWindow` sends the request and nothing else: no focus change, nothing shown, and
/// the app may ask to save first. It never kills the process (that would be `kill`).
pub fn close(addr: &str) -> String {
    format!("hl.dsp.window.close({{ window = {} }})", sel(addr))
}

/// Why a dispatch would show a workspace, move focus or act on a window it does not name, or None
/// when it is quiet. The new verbs send nothing this flags (`send` refuses it), and the tests run
/// every string sent through it. `exec_cmd` is allowed only as `open` sends it: silent, on the agent
/// workspace.
pub fn loud(lua: &str) -> Option<&'static str> {
    let t = lua.trim_start();
    // hyprctl's classic dispatchers, in case one is ever written here by hand.
    const CLASSIC: &[&str] = &["workspace ", "togglespecialworkspace", "focuswindow", "focusmonitor", "movefocus", "movetoworkspace ", "focusurgentorlast", "focuscurrentorlast", "cyclenext", "pin", "fullscreen", "bringactivetotop"];
    if let Some(c) = CLASSIC.iter().find(|c| t.starts_with(**c)) {
        return Some(match *c {
            "workspace " | "togglespecialworkspace" | "movetoworkspace " => "show a workspace",
            _ => "move focus or bring a window forward",
        });
    }
    if t.starts_with("hl.dsp.exec_cmd(") {
        let silent = format!("{{ workspace = \"{AGENT_SPECIAL} silent\" }})");
        return (!t.ends_with(&silent)).then_some("start something that is not silent on the agent workspace");
    }
    const LUA: &[(&str, &str)] = &[
        ("hl.dsp.focus", "move focus"),
        ("hl.dsp.workspace.", "show or move a workspace"),
        ("follow = true", "follow a window to its workspace"),
        ("hl.dsp.window.pin", "show a window on every workspace"),
        ("hl.dsp.window.fullscreen", "bring a window forward"),
        ("hl.dsp.window.cycle_next", "move focus"),
        ("hl.dsp.window.bring_to_top", "bring a window forward"),
        ("hl.dsp.cursor", "move the pointer"),
        ("hl.dsp.exec", "start something"),
    ];
    if let Some((_, why)) = LUA.iter().find(|(k, _)| t.contains(k)) {
        return Some(why);
    }
    if t.starts_with("hl.dsp.window.move(") && t.contains("workspace =") && !t.contains("follow = false") {
        return Some("follow a window to its workspace");
    }
    let named = t.find("window = \"address:0x").is_some();
    (!named).then_some("act on whichever window has focus")
}

/// Sends one dispatch from these verbs, after `loud` has passed it.
fn send(c: &Core, lua: &str) -> Result<(), String> {
    if let Some(why) = loud(lua) {
        return Err(format!("BaneySpaces refused its own dispatch, which would {why}"));
    }
    c.hypr.dispatch(lua).map_err(|e| e.to_string())
}

// ---- geometry -----------------------------------------------------------------------------

/// A frame in logical pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    fn json(&self) -> Value {
        json!({ "x": self.x as i64, "y": self.y as i64, "width": self.w as i64, "height": self.h as i64 })
    }
}

/// `arrange`'s layouts, the Mac's names (`AgentArrange.Layout`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Layout {
    Full,
    Halves,
    Thirds,
    Grid,
    Frames,
}

impl Layout {
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s.to_ascii_lowercase().as_str() {
            "full" => Self::Full,
            "halves" => Self::Halves,
            "thirds" => Self::Thirds,
            "grid" => Self::Grid,
            "frames" => Self::Frames,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Full => "full",
            Self::Halves => "halves",
            Self::Thirds => "thirds",
            Self::Grid => "grid",
            Self::Frames => "frames",
        }
    }
}

/// The smallest window a layout or a frame makes (the Mac's `AgentArrange.minSize`).
pub const MIN_W: f64 = 240.0;
pub const MIN_H: f64 = 160.0;

/// One frame per window, in order, inside `area` (the Mac's `AgentArrange.frames`). `halves` and
/// `thirds` are columns; windows past the last column start the columns again, on top of the first.
pub fn frames(layout: Layout, count: usize, area: Rect) -> Vec<Rect> {
    if count == 0 {
        return vec![];
    }
    let columns = |n: usize| -> Vec<Rect> {
        let w = (area.w / n as f64).floor();
        (0..count).map(|i| Rect { x: area.x + (i % n) as f64 * w, y: area.y, w, h: area.h }).collect()
    };
    match layout {
        Layout::Full | Layout::Frames => vec![area; count],
        Layout::Halves => columns(2),
        Layout::Thirds => columns(3),
        Layout::Grid => {
            let cols = (count as f64).sqrt().ceil() as usize;
            let rows = (count as f64 / cols as f64).ceil() as usize;
            let (w, h) = ((area.w / cols as f64).floor(), (area.h / rows as f64).floor());
            (0..count).map(|i| Rect { x: area.x + (i % cols) as f64 * w, y: area.y + (i / cols) as f64 * h, w, h }).collect()
        }
    }
}

/// `x,y,width,height`, finite numbers.
pub fn parse_rect(text: &str) -> Option<Rect> {
    let n: Vec<f64> = text.split(',').map(|p| p.trim().parse::<f64>()).collect::<Result<_, _>>().ok()?;
    (n.len() == 4 && n.iter().all(|v| v.is_finite())).then(|| Rect { x: n[0], y: n[1], w: n[2], h: n[3] })
}

/// `0x5da0=0,0,800,600`: a window address and a frame from the area's top-left corner.
pub fn parse_frame(text: &str) -> Option<(String, Rect)> {
    let (id, rest) = text.split_once('=')?;
    let id = id.trim();
    valid_addr(id).then_some(())?;
    Some((id.to_string(), parse_rect(rest)?))
}

/// A frame given relative to the area, made absolute and kept inside it, at least the minimum size
/// (the Mac's `AgentArrange.place`).
pub fn place(rel: Rect, area: Rect) -> Rect {
    let w = rel.w.max(MIN_W).min(area.w);
    let h = rel.h.max(MIN_H).min(area.h);
    let x = (area.x + rel.x).max(area.x).min(area.x + area.w - w);
    let y = (area.y + rel.y).max(area.y).min(area.y + area.h - h);
    Rect { x: x.floor(), y: y.floor(), w: w.floor(), h: h.floor() }
}

/// The usable area of one `hyprctl -j monitors` entry, in global logical pixels: its position, its
/// mode divided by its scale (swapped when it is rotated), less what bars reserve.
pub fn usable_area(m: &Value) -> Option<Rect> {
    let (pw, ph) = (m["width"].as_f64()?, m["height"].as_f64()?);
    let scale = m["scale"].as_f64().filter(|s| *s > 0.0).unwrap_or(1.0);
    let rotated = m["transform"].as_i64().unwrap_or(0) % 2 == 1;
    let (lw, lh) = if rotated { (ph / scale, pw / scale) } else { (pw / scale, ph / scale) };
    let r: Vec<f64> = m["reserved"].as_array().map(|a| a.iter().map(|v| v.as_f64().unwrap_or(0.0)).collect()).unwrap_or_default();
    let get = |i: usize| r.get(i).copied().unwrap_or(0.0).max(0.0);
    let (l, t, rr, b) = (get(0), get(1), get(2), get(3));
    let a = Rect { x: (m["x"].as_f64()? + l).floor(), y: (m["y"].as_f64()? + t).floor(), w: (lw - l - rr).floor(), h: (lh - t - b).floor() };
    (a.w > 0.0 && a.h > 0.0).then_some(a)
}

/// The area windows on `special:agent` are laid out in: the usable area of the monitor that holds
/// the agent workspace (`hyprctl -j workspaces`), else the one showing it, else the focused one
/// (where Hyprland creates it when the first agent window arrives).
pub fn agent_area(workspaces: &Value, monitors: &Value) -> Option<Rect> {
    let mons = monitors.as_array()?;
    let held = workspaces.as_array().into_iter().flatten().find(|w| w["name"].as_str() == Some(AGENT_SPECIAL)).and_then(|w| w["monitorID"].as_i64());
    let m = held
        .and_then(|id| mons.iter().find(|m| m["id"].as_i64() == Some(id)))
        .or_else(|| mons.iter().find(|m| m["specialWorkspace"]["name"].as_str() == Some(AGENT_SPECIAL)))
        .or_else(|| mons.iter().find(|m| m["focused"].as_bool() == Some(true)))?;
    usable_area(m)
}

// ---- whose window is it -------------------------------------------------------------------

/// What a window is to the agent asking.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Standing {
    /// A window of an agent process, on `special:agent` by Hyprland's word and the model's.
    Own,
    /// A dialog of an agent process: floating, not floated by `arrange` or `move`, and not the oldest
    /// window of its process on the agent workspace (so a process always keeps one window of its
    /// own), or not placed on any workspace yet.
    Child,
    /// A window of an agent process that is not on the agent workspace (yet: the daemon moves it).
    OwnElsewhere,
    /// Anything else: yours, including a window you parked on the agent workspace (`agent move
    /// <window>`). Never laid out, moved or closed for an agent.
    Yours,
}

/// Hyprland reports a window that is on no workspace with workspace id -1 and no name.
fn unplaced(cl: &Client) -> bool {
    cl.ws_id == -1 || cl.ws_name.is_empty()
}

/// The rule, in one place. `start` is the window's process start time now; `oldest` says whether
/// this is the first window of its process to arrive on `special:agent` (the model's order);
/// `placed` whether `arrange` or `move` floated this window.
pub fn standing(model: &Model, cl: &Client, start: u64, oldest: bool, placed: bool) -> Standing {
    let agent_pid = model.agent_proc(cl.pid).is_some() && model.is_agent_pid(cl.pid, start);
    if !agent_pid {
        return Standing::Yours;
    }
    let on_agent = cl.ws_name == AGENT_SPECIAL;
    let home_agent = matches!(model.home(&cl.addr), Some(Home::Agent)) && model.pid_of(&cl.addr) == Some(cl.pid);
    if cl.floating && !placed && ((on_agent && !oldest) || unplaced(cl)) {
        return Standing::Child;
    }
    if on_agent && home_agent {
        return Standing::Own;
    }
    Standing::OwnElsewhere
}

/// Whether `addr` is the first window of process `pid` on the agent workspace, in the model's order.
pub(crate) fn oldest_of(model: &Model, clients: &[Client], pid: u32, addr: &str) -> bool {
    model.agent_windows().into_iter().find(|w| clients.iter().any(|o| o.addr == *w && o.pid == pid && o.ws_name == AGENT_SPECIAL)) == Some(addr)
}

/// A dialog of an agent process that Hyprland has not placed on any workspace yet. `hands` treats
/// it as on the agent workspace (it is the agent's, and it is not on yours).
pub fn unplaced_child(model: &Model, cl: &Client, start: u64) -> bool {
    cl.floating && unplaced(cl) && model.agent_proc(cl.pid).is_some() && model.is_agent_pid(cl.pid, start)
}

/// Each window on Hyprland's list with its standing.
fn standings(c: &Core, clients: &[Client]) -> Vec<(Client, Standing)> {
    clients
        .iter()
        .filter(|cl| cl.mapped)
        .map(|cl| {
            let start = proc::start_time(cl.pid).unwrap_or(0);
            let s = standing(&c.model, cl, start, oldest_of(&c.model, clients, cl.pid, &cl.addr), c.is_placed(cl));
            (cl.clone(), s)
        })
        .collect()
}

/// The window a child belongs to: the oldest other window of its process on the agent workspace.
pub fn parent_of(model: &Model, clients: &[Client], child: &Client) -> Option<String> {
    model.agent_windows().into_iter().find(|w| *w != child.addr && clients.iter().any(|o| o.addr == *w && o.pid == child.pid)).map(String::from)
}

fn scope_name(s: Standing) -> &'static str {
    match s {
        Standing::Own | Standing::Child => "agent_workspace",
        Standing::OwnElsewhere => "moved_out_by_user",
        Standing::Yours => "yours",
    }
}

fn no_lend(what: &str) -> Envelope {
    Envelope::err(
        "not_supported",
        format!("{what} is one of your windows, and Linux has no lend sheet yet"),
        Retry::Never,
        "On the Mac only a window the user lends, or any window under Full Access, comes to the agent workspace. Neither exists on Linux yet, so an agent never moves or lays out the user's windows here, not even one the user parked on the agent workspace.",
    )
}

// ---- workspaces ---------------------------------------------------------------------------

/// `workspaces`: the nine and the agent workspace, which are shown, which one you are on, how many
/// windows each holds, and where each window the agent may use is. Counts only, never titles of your
/// windows. Read only: it sends nothing to Hyprland.
pub fn workspace_list(workspaces: &Value, monitors: &Value, usable: &[(Client, Standing)]) -> Value {
    let mons = monitors.as_array().cloned().unwrap_or_default();
    let ws = workspaces.as_array().cloned().unwrap_or_default();
    let focused = mons.iter().find(|m| m["focused"].as_bool() == Some(true));
    let count = |pred: &dyn Fn(&Value) -> bool| ws.iter().find(|w| pred(w)).and_then(|w| w["windows"].as_i64()).unwrap_or(0);
    let agent_shown = mons.iter().any(|m| m["specialWorkspace"]["name"].as_str() == Some(AGENT_SPECIAL));
    let mut rows: Vec<Value> = (1..=9i64)
        .map(|n| {
            let shown = mons.iter().any(|m| m["activeWorkspace"]["id"].as_i64() == Some(n));
            let current = focused.is_some_and(|m| m["activeWorkspace"]["id"].as_i64() == Some(n));
            json!({ "number": n, "shown": shown, "current": current, "agent": false, "windows": count(&|w| w["id"].as_i64() == Some(n) && w["name"].as_str().is_none_or(|s| !s.starts_with("special:"))) })
        })
        .collect();
    let current_agent = focused.is_some_and(|m| m["specialWorkspace"]["name"].as_str() == Some(AGENT_SPECIAL));
    rows.push(json!({ "number": Value::Null, "name": AGENT_SPECIAL, "shown": agent_shown, "current": current_agent, "agent": true, "windows": count(&|w| w["name"].as_str() == Some(AGENT_SPECIAL)) }));
    let mut yours: Vec<&(Client, Standing)> = usable.iter().filter(|(_, s)| !matches!(s, Standing::Yours)).collect();
    yours.sort_by(|a, b| a.0.addr.cmp(&b.0.addr));
    json!({
        "agent_workspace": AGENT_SPECIAL,
        "agent_workspace_shown": agent_shown,
        "access": "default",
        "workspaces": rows,
        "your_windows": yours.iter().map(|(cl, s)| json!({ "id": cl.addr, "app": cl.class, "pid": cl.pid, "workspace": if cl.ws_name.is_empty() { Value::Null } else { json!(cl.ws_name) }, "scope": scope_name(*s) })).collect::<Vec<_>>(),
        "note": "Agents never change which workspace is shown and never create, rename or delete workspaces. Work on the agent workspace; while it is shown the user is looking at it.",
    })
}

pub fn workspaces(shared: &Shared, agent: &str) -> Envelope {
    let c = lock(shared);
    let env = match (c.hypr.json("workspaces"), c.hypr.json("monitors"), c.try_clients()) {
        (Ok(ws), Ok(mons), Ok(clients)) => Envelope::ok(workspace_list(&ws, &mons, &standings(&c, &clients))),
        (Err(e), _, _) | (_, Err(e), _) | (_, _, Err(e)) => Envelope::err("compositor_error", format!("cannot read Hyprland: {e}"), Retry::Safe, "Is Hyprland running? Check `baneyspaces doctor`."),
    };
    record(&c, agent, "workspaces", None, None, None, "ctl", &env);
    env
}

// ---- arrange and move ---------------------------------------------------------------------

/// The process and the window (`stableId`) a target was selected with, checked again before every
/// dispatch.
#[derive(Clone, Debug)]
struct Owner {
    pid: u32,
    start: u64,
    stable: String,
}

/// Right before a dispatch: Hyprland is asked again, and the window must still be on `special:agent`,
/// be the same window (`stableId`, since an address is reused) and belong to the same registered
/// agent process (pid and start time). The Core lock does not stop
/// the compositor: the user can move a window back between the selection and the dispatch.
fn still_agents(c: &Core, addr: &str, who: &Owner) -> Result<(), Step> {
    let clients = c.try_clients().map_err(|e| Step::Compositor(format!("cannot read Hyprland: {e}")))?;
    let cl = clients.into_iter().find(|x| x.addr == addr).ok_or_else(|| Step::Scope(format!("window {addr} is gone")))?;
    let start = proc::start_time(cl.pid).unwrap_or(0);
    if cl.ws_name != AGENT_SPECIAL {
        return Err(Step::Scope(format!("window {addr} left the agent workspace")));
    }
    if cl.stable_id != who.stable {
        return Err(Step::Scope(format!("window {addr} is another window now (the one chosen closed)")));
    }
    if cl.pid != who.pid || (who.start != 0 && start != who.start) || c.model.agent_proc(cl.pid).is_none() || !c.model.is_agent_pid(cl.pid, start) {
        return Err(Step::Scope(format!("window {addr} no longer belongs to the agent process it was chosen with")));
    }
    Ok(())
}

/// Checks the target, then sends one dispatch.
fn send_checked(c: &Core, addr: &str, who: &Owner, lua: &str) -> Result<(), Step> {
    still_agents(c, addr, who)?;
    send(c, lua).map_err(Step::Compositor)
}

/// Why a step was not sent: the window's scope changed (stop everything), or Hyprland said no.
#[derive(Debug)]
enum Step {
    Scope(String),
    Compositor(String),
}

/// Why a frame was not fully applied, with whether the window had already been changed.
#[derive(Debug)]
enum Halt {
    /// The window's scope changed: stop everything.
    Scope(String, bool),
    /// Hyprland refused a step or did not answer it.
    Compositor(String, bool),
}

/// Gives one window a frame: float it, size it, place it, each step after `still_agents`. Each
/// dispatch names the window and none focuses it or shows its workspace (see the builders). `Ok`
/// means all three steps were taken (Hyprland applies a frame at once, also on a hidden special
/// workspace). `Err` says which step stopped it and whether the window had already been changed.
fn apply_frame(c: &mut Core, addr: &str, who: &Owner, f: Rect) -> Result<(), Halt> {
    let steps = [float_on(addr), resize_to(addr, f.w as i64, f.h as i64), move_to(addr, f.x as i64, f.y as i64)];
    for (i, lua) in steps.iter().enumerate() {
        match send_checked(c, addr, who, lua) {
            Ok(()) => {
                // Floated by us from the first step on, so a half-placed window is never taken for a dialog.
                c.placed.insert(addr.to_string(), who.stable.clone());
            }
            Err(Step::Scope(why)) => return Err(Halt::Scope(why, i > 0)),
            Err(Step::Compositor(e)) => {
                // Refused or unanswered: what Hyprland did is not known, so it is read again before the next command.
                c.dirty = true;
                return Err(Halt::Compositor(e, i > 0));
            }
        }
    }
    Ok(())
}

fn owner_of(cl: &Client) -> Owner {
    Owner { pid: cl.pid, start: proc::start_time(cl.pid).unwrap_or(0), stable: cl.stable_id.clone() }
}

/// The answer when a target's scope changed mid-call: nothing more was sent, and which windows were
/// and were not changed.
fn stopped(why: &str, changed: &[String], not_changed: &[String], done: Vec<Value>) -> Envelope {
    Envelope::err("not_in_scope", format!("{why}, so BaneySpaces stopped and sent nothing more"), Retry::Never, "Run `baneyspaces agent workspaces` to see where the windows are now.")
        .with_data(json!({ "changed": changed, "not_changed": not_changed, "windows": done }))
}

fn area_now(c: &Core) -> Result<Rect, Envelope> {
    let read = |what: &str| c.hypr.json(what).map_err(|e| Envelope::err("compositor_error", format!("cannot read Hyprland: {e}"), Retry::Safe, "Is Hyprland running?"));
    let (ws, mons) = (read("workspaces")?, read("monitors")?);
    agent_area(&ws, &mons).ok_or_else(|| Envelope::err("engine_error", "the screen's size couldn't be read", Retry::Safe, "Try again."))
}

pub fn arrange(shared: &Shared, agent: &str, args: &Value) -> Envelope {
    let mut c = lock(shared);
    let env = arrange_locked(&mut c, args);
    record(&c, agent, "arrange", None, None, None, "ctl", &env);
    env
}

fn arrange_locked(c: &mut Core, args: &Value) -> Envelope {
    let bad = |m: String| Envelope::err("invalid_args", m, Retry::Never, "usage: agent arrange full|halves|thirds|grid [window...] | frames 0xADDR=x,y,width,height ...");
    let Some(layout) = args["layout"].as_str().and_then(Layout::parse) else {
        return bad(format!("layout is full, halves, thirds, grid or frames, not {:?}", args["layout"].as_str().unwrap_or("")));
    };
    let items: Vec<String> = args["windows"].as_array().into_iter().flatten().filter_map(Value::as_str).map(String::from).collect();
    let mut wanted: Vec<(String, Option<Rect>)> = vec![];
    for it in &items {
        if layout == Layout::Frames {
            match parse_frame(it) {
                Some((a, r)) => wanted.push((a, Some(r))),
                None => return bad(format!("{it} isn't 0xADDR=x,y,width,height")),
            }
        } else if valid_addr(it) {
            wanted.push((it.clone(), None));
        } else {
            return bad(format!("{it} isn't a window address (0x...)"));
        }
    }
    if layout == Layout::Frames && wanted.is_empty() {
        return bad("frames needs 0xADDR=x,y,width,height for each window".into());
    }
    let clients = match c.try_clients() {
        Ok(v) => v,
        Err(e) => return Envelope::err("compositor_error", format!("cannot read Hyprland: {e}"), Retry::Safe, "Is Hyprland running?"),
    };
    let all = standings(c, &clients);
    // Oldest first, as the model saw them arrive (the Mac sorts by window id, which is the same order there).
    let order = c.model.agent_windows().into_iter().map(String::from).collect::<Vec<_>>();
    let mine: Vec<&(Client, Standing)> = order.iter().filter_map(|w| all.iter().find(|(cl, s)| cl.addr == *w && *s == Standing::Own)).collect();
    let chosen: Vec<(Client, Option<Rect>)> = if wanted.is_empty() {
        mine.iter().map(|(cl, _)| (cl.clone(), None)).collect()
    } else {
        let mut v = vec![];
        for (a, r) in &wanted {
            match mine.iter().find(|(cl, _)| cl.addr == *a) {
                Some((cl, _)) => v.push((cl.clone(), *r)),
                None => {
                    return match all.iter().find(|(cl, _)| cl.addr == *a) {
                        Some((cl, Standing::Yours)) => no_lend(&format!("window {a} of {}", cl.class)),
                        _ => Envelope::err("not_in_scope", format!("window {a} isn't a window of yours on the agent workspace"), Retry::Never, "arrange lays out only agent workspace windows; `agent workspaces` lists where yours are. A dialog goes with its window."),
                    }
                }
            }
        }
        v
    };
    if chosen.is_empty() {
        return Envelope::ok(json!({ "layout": layout.name(), "windows": [], "note": "no window of yours is on the agent workspace" }));
    }
    let area = match area_now(c) {
        Ok(a) => a,
        Err(e) => return e,
    };
    let laid = frames(layout, chosen.len(), area);
    let mut out = vec![];
    let mut changed: Vec<String> = vec![];
    for (i, (cl, rel)) in chosen.iter().enumerate() {
        let f = match rel {
            Some(r) => place(*r, area),
            None => place(Rect { x: laid[i].x - area.x, y: laid[i].y - area.y, w: laid[i].w, h: laid[i].h }, area),
        };
        match apply_frame(c, &cl.addr, &owner_of(cl), f) {
            Ok(()) => {
                changed.push(cl.addr.clone());
                out.push(json!({ "window": cl.addr, "app": cl.class, "applied": "now", "frame": f.json() }));
            }
            // The Mac's `applied`: a window Hyprland refused is skipped and the rest are still laid out.
            Err(Halt::Compositor(e, touched)) => {
                if touched {
                    changed.push(cl.addr.clone());
                }
                out.push(json!({ "window": cl.addr, "app": cl.class, "applied": format!("skipped: {e}"), "frame": f.json() }));
            }
            Err(Halt::Scope(why, partly)) => {
                if partly {
                    changed.push(cl.addr.clone());
                }
                let not_changed: Vec<String> = chosen.iter().map(|(x, _)| x.addr.clone()).filter(|a| !changed.contains(a)).collect();
                return stopped(&why, &changed, &not_changed, out);
            }
        }
    }
    Envelope::ok(json!({ "layout": layout.name(), "area": area.json(), "windows": out }))
}

pub fn move_window(shared: &Shared, agent: &str, args: &Value) -> Envelope {
    let mut c = lock(shared);
    let (env, pid) = move_locked(&mut c, args);
    record(&c, agent, "move", pid, args["window"].as_str(), None, "ctl", &env);
    env
}

fn move_locked(c: &mut Core, args: &Value) -> (Envelope, Option<u32>) {
    let Some(addr) = args["window"].as_str().filter(|a| valid_addr(a)).map(String::from) else {
        return (Envelope::err("invalid_args", "--window 0xADDR is required (a window address from `agent windows` or `agent open`)", Retry::Never, "usage: agent move --window 0xADDR [--frame x,y,width,height]"), None);
    };
    let frame = match args["frame"].as_str() {
        None => None,
        Some(t) => match parse_rect(t) {
            Some(r) => Some(r),
            None => return (Envelope::err("invalid_args", format!("frame is x,y,width,height, not {t}"), Retry::Never, "usage: agent move --window 0xADDR [--frame x,y,width,height]"), None),
        },
    };
    let clients = match c.try_clients() {
        Ok(v) => v,
        Err(e) => return (Envelope::err("compositor_error", format!("cannot read Hyprland: {e}"), Retry::Safe, "Is Hyprland running?"), None),
    };
    let all = standings(c, &clients);
    let Some((cl, st)) = all.into_iter().find(|(cl, _)| cl.addr == addr) else {
        return (Envelope::err("not_found", format!("no window {addr}"), Retry::AfterSnapshot, "Run `baneyspaces agent windows`."), None);
    };
    let pid = Some(cl.pid);
    let who = owner_of(&cl);
    let from = if cl.ws_name.is_empty() { Value::Null } else { json!(cl.ws_name) };
    let moves = match st {
        Standing::Own => false,
        Standing::OwnElsewhere if !cl.ws_name.is_empty() => return (moved_out(&cl), pid),
        Standing::OwnElsewhere => true,
        Standing::Child => return (Envelope::err("not_supported", format!("window {addr} is a dialog of {}; it goes where its app's window goes", cl.class), Retry::Never, "Answer it where it is, or move its parent window."), pid),
        Standing::Yours => return (no_lend(&format!("window {addr} of {}", cl.class)), pid),
    };
    if moves {
        // The Mac's rule: nothing is moved onto the agent workspace while the user is looking at it.
        let shown = c.hypr.json("monitors").ok().and_then(|v| v.as_array().map(|a| a.iter().any(|m| m["specialWorkspace"]["name"].as_str() == Some(AGENT_SPECIAL))));
        match shown {
            Some(false) => {}
            Some(true) => return (Envelope::err("in_use", "the user is looking at the agent workspace, so nothing is moved onto it now", Retry::Safe, "Retry once it is hidden, or work on a window already there. Do not ask the user to hide it."), pid),
            None => return (Envelope::err("compositor_error", "cannot tell whether the agent workspace is shown", Retry::Safe, "Try again."), pid),
        }
        // Only a window Hyprland has not placed yet comes over (the daemon moves those there anyway, R-A3).
        // Checked again right before: still unplaced, and still that agent process's.
        let fresh = c.client(&addr);
        let ok = fresh.as_ref().is_some_and(|f| f.ws_name.is_empty() && f.stable_id == who.stable && f.pid == who.pid && (who.start == 0 || proc::start_time(f.pid).unwrap_or(0) == who.start) && c.model.is_agent_pid(f.pid, who.start) && c.model.agent_proc(f.pid).is_some());
        if !ok {
            return (stopped(&format!("window {addr} no longer belongs to the agent process it was chosen with"), &[], std::slice::from_ref(&addr), vec![]), pid);
        }
        if let Err(e) = send(c, &to_agent(&addr)) {
            return (Envelope::err("compositor_error", format!("Hyprland did not move it: {e}"), Retry::Never, "Run `baneyspaces agent windows`."), pid);
        }
    }
    let mut data = json!({ "window": addr, "app": cl.class, "from": from, "to": AGENT_SPECIAL, "moved": moves });
    if let Some(rel) = frame {
        let area = match area_now(c) {
            Ok(a) => a,
            Err(e) => return (e, pid),
        };
        let f = place(rel, area);
        // Which windows a stopped frame leaves changed: this one, if a step or the move was taken.
        let split = |partly: bool| -> (Vec<String>, Vec<String>) { if partly || moves { (vec![addr.clone()], vec![]) } else { (vec![], vec![addr.clone()]) } };
        match apply_frame(c, &addr, &who, f) {
            Ok(()) => {
                data["frame"] = f.json();
                data["applied"] = json!("now");
            }
            Err(Halt::Scope(why, partly)) => {
                let (ch, not) = split(partly);
                return (stopped(&why, &ch, &not, vec![data]), pid);
            }
            // A frame Hyprland refused or did not answer is a failure, never `ok`.
            Err(Halt::Compositor(e, partly)) => {
                let (ch, not) = split(partly);
                let env = Envelope::err("compositor_error", format!("Hyprland did not apply the frame: {e}"), Retry::Never, "The window may be partly changed (see changed). Run `baneyspaces agent windows` before you try again.")
                    .with_data(json!({ "changed": ch, "not_changed": not, "windows": [data] }));
                return (env, pid);
            }
        }
    }
    (Envelope::ok(data), pid)
}

/// An agent's window the user took to one of their workspaces is theirs from then on: nothing is
/// sent for it until they move it back to the agent workspace.
fn moved_out(cl: &Client) -> Envelope {
    Envelope::err("not_in_scope", format!("window {} of {} is on workspace {}: the user moved it out of the agent workspace, so it is theirs now", cl.addr, cl.class, cl.ws_name), Retry::Never, "Leave it where it is. It is back in scope only if the user moves it back.")
}

// ---- close --------------------------------------------------------------------------------

/// Why `close` refuses this window for this session, or None. Only a window this session's `open`
/// made (the same `stableId`, not just the same address), of the same process, still the agent's on
/// the agent workspace.
pub fn close_refusal(sessions: &SessionWindows, session: &str, cl: &Client, start: u64, st: Standing) -> Option<Envelope> {
    if !sessions.opened_by(session, &cl.addr, cl.pid, start, &cl.stable_id) {
        return Some(Envelope::err(
            "not_in_scope",
            format!("window {} of {} wasn't opened by this session", cl.addr, cl.class),
            Retry::Never,
            "close closes only windows your own `agent open` made in this session; leave the rest as they are. Answer a dialog with its own buttons.",
        ));
    }
    if st != Standing::Own {
        return Some(Envelope::err("not_in_scope", format!("window {} is no longer the agent's on the agent workspace", cl.addr), Retry::Never, "Leave it as it is."));
    }
    None
}

/// Whether a window that appeared after a close request is one `close` may report: of the same
/// registered agent process (`start` is the closed window's process start time) and on the agent
/// workspace by Hyprland's word, or a dialog it has not placed on any workspace yet.
fn asked_by(model: &Model, x: &Client, start: u64) -> bool {
    let now = proc::start_time(x.pid).unwrap_or(0);
    now == start && model.agent_proc(x.pid).is_some() && model.is_agent_pid(x.pid, now) && (x.ws_name == AGENT_SPECIAL || (x.floating && unplaced(x)))
}

pub fn close_window(shared: &Shared, agent: &str, args: &Value) -> Envelope {
    let session = args["session"].as_str().unwrap_or("").to_string();
    let Some(addr) = args["window"].as_str().filter(|a| valid_addr(a)).map(String::from) else {
        let env = Envelope::err("invalid_args", "--window 0xADDR is required (the window your `agent open` returned)", Retry::Never, "usage: agent close --window 0xADDR");
        record(&lock(shared), agent, "close", None, None, None, "ctl", &env);
        return env;
    };
    let (cl, start, before) = {
        let c = lock(shared);
        let clients = match c.try_clients() {
            Ok(v) => v,
            Err(e) => {
                let env = Envelope::err("compositor_error", format!("cannot read Hyprland: {e}"), Retry::Safe, "Is Hyprland running?");
                record(&c, agent, "close", None, Some(&addr), None, "ctl", &env);
                return env;
            }
        };
        let all = standings(&c, &clients);
        let Some((cl, st)) = all.iter().find(|(cl, _)| cl.addr == addr).cloned() else {
            let env = Envelope::err("not_found", format!("no window {addr}"), Retry::Never, "It may be closed already. Run `baneyspaces agent windows`.");
            record(&c, agent, "close", None, Some(&addr), None, "ctl", &env);
            return env;
        };
        let start = proc::start_time(cl.pid).unwrap_or(0);
        if let Some(env) = close_refusal(&c.sessions, &session, &cl, start, st) {
            record(&c, agent, "close", Some(cl.pid), Some(&addr), None, "ctl", &env);
            return env;
        }
        if let Err(step) = send_checked(&c, &addr, &Owner { pid: cl.pid, start, stable: cl.stable_id.clone() }, &close(&addr)) {
            let env = match step {
                Step::Scope(why) => stopped(&why, &[], std::slice::from_ref(&addr), vec![]),
                Step::Compositor(e) => Envelope::err("compositor_error", format!("Hyprland did not take the close request: {e}"), Retry::Never, "Run `baneyspaces agent windows`."),
            };
            record(&c, agent, "close", Some(cl.pid), Some(&addr), None, "ctl", &env);
            return env;
        }
        // By address and `stableId`: a new window at an address seen before is still a new window.
        let before: HashSet<(String, String)> = clients.iter().map(|x| (x.addr.clone(), x.stable_id.clone())).collect();
        (cl, start, before)
    };
    // Without the lock: give the app a second to close, or to ask (a save dialog of the same process).
    let deadline = Instant::now() + Duration::from_millis(1000);
    let (mut gone, mut opened) = (false, None);
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(100));
        let c = lock(shared);
        let Ok(now) = c.try_clients() else { continue };
        // Gone when Hyprland no longer lists that window: the address with the same `stableId`.
        gone = !now.iter().any(|x| x.addr == addr && x.stable_id == cl.stable_id);
        // What the app asked before closing: a new window of the same process, and only one that is
        // the agent's to read (on the agent workspace, or a dialog not placed yet). A window the user
        // took to their workspace is theirs, and its title is not reported.
        opened = now
            .iter()
            .find(|x| x.pid == cl.pid && !before.contains(&(x.addr.clone(), x.stable_id.clone())) && asked_by(&c.model, x, start))
            .map(|d| json!({ "window": d.addr, "kind": if d.floating { "dialog" } else { "window" }, "title": d.title, "waiting": true, "parent": addr }));
        if gone || opened.is_some() {
            break;
        }
    }
    let mut c = lock(shared);
    let mut data = json!({ "window": addr, "app": cl.class, "pressed": "close", "target": { "window": addr, "pid": cl.pid, "app": cl.class, "scope": "agent_workspace" } });
    if let Some(o) = opened {
        data["opened"] = o;
        data["note"] = json!("the app asked something before closing: answer the dialog in opened");
    } else {
        data["closed"] = json!(gone);
    }
    if gone {
        c.sessions.forget(&addr);
        c.placed.remove(&addr);
    }
    let env = Envelope::ok(data);
    record(&c, agent, "close", Some(cl.pid), Some(&addr), None, "ctl", &env);
    env
}

// ---- open: the session's claim and new_window: false ----------------------------------------

/// `open` with `new_window: false` and no files: this session's newest window of that app, if it is
/// still the agent's on the agent workspace. Nothing starts.
pub fn reuse(c: &Core, session: &str, app: &str) -> Option<Value> {
    let clients = c.try_clients().ok()?;
    let all = standings(c, &clients);
    c.sessions
        .of(session)
        .into_iter()
        .rev()
        .filter(|(_, o)| o.app == app)
        .find_map(|(addr, o)| {
            let (cl, st) = all.iter().find(|(cl, _)| cl.addr == addr)?;
            let start = proc::start_time(cl.pid).unwrap_or(0);
            (*st == Standing::Own && c.sessions.opened_by(session, &addr, cl.pid, start, &cl.stable_id)).then(|| {
                json!({ "window": addr, "pid": o.pid, "app": app, "title": cl.title, "workspace": AGENT_SPECIAL, "reused": true, "focus": { "changed": false, "returned": false } })
            })
        })
}

/// What `open` says about focus: whether the window in front changed at any time while it ran, and
/// whether the daemon's guard gave it back (it refuses every activation of an agent window). A focus
/// the guard took back leaves the same window in front at both ends, and still counts as a change.
pub fn focus_json(front_before: Option<&str>, front_after: Option<&str>, refused_before: u64, refused_after: u64) -> Value {
    let returned = refused_after > refused_before;
    json!({ "changed": front_before != front_after || returned, "returned": returned })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::tests::{fake_hypr, mon};
    use baneyspaces_core::model::Event;
    use std::sync::{Arc, Mutex};

    const OWN: &str = "0xa1";
    const OWN2: &str = "0xa2";
    const DIALOG: &str = "0xa3";
    const PARKED: &str = "0xb1";
    const YOURS: &str = "0xc1";

    fn client(addr: &str, pid: u32, ws: &str, floating: bool) -> Value {
        let id = if ws == AGENT_SPECIAL { -98 } else { ws.parse::<i64>().unwrap_or(-1) };
        json!({ "address": addr, "pid": pid, "workspace": { "id": id, "name": ws }, "monitor": 0, "class": "foot", "title": format!("t{addr}"), "mapped": true, "floating": floating, "stableId": "1" })
    }

    fn area_mon(special: &str) -> Value {
        let mut m = mon(0, "A", true, 1);
        m["x"] = json!(0);
        m["y"] = json!(0);
        m["width"] = json!(1920);
        m["height"] = json!(1080);
        m["scale"] = json!(1.0);
        m["transform"] = json!(0);
        m["reserved"] = json!([0, 30, 0, 0]);
        m["specialWorkspace"] = json!({ "name": special });
        m
    }

    /// A Core on a fake Hyprland: the agent process is this test process (so its start time reads),
    /// your windows belong to pid 1 (not an agent). Returns the shared core and everything sent.
    fn setup(tag: &str, agent_shown: bool) -> (Shared, Arc<Mutex<Vec<String>>>) {
        setup_with(tag, agent_shown, None)
    }

    /// When the user takes a window back: `(window, rule)`, where `rule(reads of j/clients so far,
    /// dispatches so far)` says whether Hyprland now has that window on workspace 3.
    type Leaves = Option<(&'static str, fn(usize, usize) -> bool)>;

    fn setup_with(tag: &str, agent_shown: bool, leaves: Leaves) -> (Shared, Arc<Mutex<Vec<String>>>) {
        let me = std::process::id();
        let list = move |gone: Option<&str>| {
            let ws = |a: &str| if gone == Some(a) { "3" } else { AGENT_SPECIAL };
            json!([
                client(OWN, me, ws(OWN), false),
                client(OWN2, me, ws(OWN2), false),
                client(DIALOG, me, AGENT_SPECIAL, true),
                client(PARKED, 1, AGENT_SPECIAL, false),
                client(YOURS, 1, "3", false),
            ])
            .to_string()
        };
        let reads = std::sync::atomic::AtomicUsize::new(0);
        let sent = std::sync::atomic::AtomicUsize::new(0);
        let monitors = json!([area_mon(if agent_shown { AGENT_SPECIAL } else { "" })]).to_string();
        let workspaces = json!([
            { "id": 1, "name": "1", "windows": 0, "monitorID": 0 },
            { "id": 3, "name": "3", "windows": 1, "monitorID": 0 },
            { "id": -98, "name": AGENT_SPECIAL, "windows": 4, "monitorID": 0 }
        ])
        .to_string();
        let (mut c, log) = fake_hypr(tag, move |r| {
            use std::sync::atomic::Ordering::SeqCst;
            match r {
                "j/clients" => {
                    let n = reads.fetch_add(1, SeqCst);
                    list(leaves.and_then(|(w, rule)| rule(n, sent.load(SeqCst)).then_some(w)))
                }
                "j/monitors" => monitors.clone(),
                "j/workspaces" => workspaces.clone(),
                "j/activewindow" => "{\"address\":\"0xc1\"}".into(),
                _ => {
                    if r.starts_with("/dispatch ") {
                        sent.fetch_add(1, SeqCst);
                    }
                    "ok".into()
                }
            }
        });
        let start = proc::start_time(me).unwrap_or(0);
        for (w, pid, ws) in [(OWN, me, None), (OWN2, me, None), (DIALOG, me, None), (PARKED, 1, None), (YOURS, 1, Some(3))] {
            c.model.apply(Event::ObserveWindow { window: w.into(), pid, start: if pid == me { start } else { 0 }, app: "foot".into(), workspace: ws }).unwrap();
        }
        c.model.apply(Event::AgentRegister { pid: me, start }).unwrap();
        (Arc::new(Mutex::new(c)), log)
    }

    fn dispatches(log: &Arc<Mutex<Vec<String>>>) -> Vec<String> {
        log.lock().unwrap().iter().filter_map(|r| r.strip_prefix("/dispatch ").map(String::from)).collect()
    }

    /// Everything sent to Hyprland in a test: reads, or dispatches that are quiet and name their window.
    fn assert_all_quiet(log: &Arc<Mutex<Vec<String>>>) {
        for r in log.lock().unwrap().iter() {
            if r.starts_with("j/") {
                continue;
            }
            let lua = r.strip_prefix("/dispatch ").unwrap_or_else(|| panic!("only reads and dispatches are sent: {r}"));
            assert_eq!(loud(lua), None, "{lua}");
            for bad in ["workspace ", "togglespecialworkspace", "focuswindow", "focusmonitor", "hl.dsp.focus", "toggle_special", "follow = true", "hl.dsp.workspace."] {
                if bad == "workspace " {
                    assert!(!lua.starts_with(bad), "{lua}");
                } else {
                    assert!(!lua.contains(bad), "{bad} in {lua}");
                }
            }
        }
    }

    fn code(e: &Envelope) -> String {
        e.error.as_ref().map(|e| e.code.clone()).unwrap_or_default()
    }

    #[test]
    fn the_dispatch_strings_are_exact() {
        assert_eq!(float_on("0xa1"), r#"hl.dsp.window.float({ action = "enable", window = "address:0xa1" })"#);
        assert_eq!(resize_to("0xa1", 960, 1050), r#"hl.dsp.window.resize({ x = 960, y = 1050, window = "address:0xa1" })"#);
        assert_eq!(move_to("0xa1", 0, 30), r#"hl.dsp.window.move({ x = 0, y = 30, window = "address:0xa1" })"#);
        assert_eq!(to_agent("0xa1"), r#"hl.dsp.window.move({ workspace = "special:agent", follow = false, window = "address:0xa1" })"#);
        assert_eq!(close("0xa1"), r#"hl.dsp.window.close({ window = "address:0xa1" })"#);
        for d in [float_on("0x1"), resize_to("0x1", 1, 1), move_to("0x1", 0, 0), to_agent("0x1"), close("0x1")] {
            assert_eq!(loud(&d), None, "{d}");
        }
    }

    #[test]
    fn the_denylist_catches_focus_and_showing_and_unnamed_windows() {
        for d in [
            "workspace 3",
            "togglespecialworkspace agent",
            "focuswindow address:0x1",
            "focusmonitor A",
            r#"hl.dsp.focus({ window = "address:0x1" })"#,
            r#"hl.dsp.workspace.toggle_special("agent")"#,
            r#"hl.dsp.workspace.move({ workspace = "3", monitor = "A" })"#,
            r#"hl.dsp.window.move({ workspace = "special:agent", window = "address:0x1" })"#,
            r#"hl.dsp.window.move({ workspace = "special:agent", follow = true, window = "address:0x1" })"#,
            r#"hl.dsp.window.pin({ window = "address:0x1" })"#,
            r#"hl.dsp.window.close({ })"#,
            r#"hl.dsp.window.close()"#,
            r#"hl.dsp.window.resize({ x = 1, y = 1 })"#,
            r#"hl.dsp.exec_cmd("foot")"#,
        ] {
            assert!(loud(d).is_some(), "{d} must be refused");
        }
        assert_eq!(loud(r#"hl.dsp.exec_cmd("env foot", { workspace = "special:agent silent" })"#), None, "open's launch is silent on the agent workspace");
    }

    #[test]
    fn a_selector_is_built_only_from_an_address() {
        assert!(valid_addr("0x5da0") && valid_addr("0xABCdef0123"));
        for bad in ["", "0x", "5da0", "active", "0x5da0\" }) hl.dsp.focus({", "address:0x1", "0x12345678901234567", "0xg1"] {
            assert!(!valid_addr(bad), "{bad}");
        }
    }

    #[test]
    fn layouts_are_the_macs() {
        let a = Rect { x: 0.0, y: 30.0, w: 1920.0, h: 1050.0 };
        assert_eq!(Layout::parse("Halves"), Some(Layout::Halves));
        assert_eq!(Layout::parse("columns"), None);
        assert_eq!(frames(Layout::Full, 2, a), vec![a, a]);
        let h = frames(Layout::Halves, 3, a);
        assert_eq!((h[0].x, h[1].x, h[2].x, h[1].w), (0.0, 960.0, 0.0, 960.0), "the third starts the columns again");
        let t = frames(Layout::Thirds, 3, a);
        assert_eq!((t[2].x, t[2].w), (1280.0, 640.0));
        let g = frames(Layout::Grid, 3, a);
        assert_eq!(g.len(), 3);
        assert_eq!((g[1].x, g[2].x, g[2].y, g[2].w, g[2].h), (960.0, 0.0, 555.0, 960.0, 525.0));
        assert!(frames(Layout::Grid, 0, a).is_empty());
        // place: absolute, inside the area, at least the minimum size.
        assert_eq!(place(Rect { x: 10.0, y: 10.0, w: 800.0, h: 600.0 }, a), Rect { x: 10.0, y: 40.0, w: 800.0, h: 600.0 });
        assert_eq!(place(Rect { x: 5000.0, y: -50.0, w: 10.0, h: 10.0 }, a), Rect { x: 1680.0, y: 30.0, w: 240.0, h: 160.0 });
        assert_eq!(parse_frame("0xa1=0,0,800,600"), Some(("0xa1".into(), Rect { x: 0.0, y: 0.0, w: 800.0, h: 600.0 })));
        for bad in ["a1=0,0,1,1", "0xa1=0,0,1", "0xa1=0,0,1,nan", "0xa1"] {
            assert_eq!(parse_frame(bad), None, "{bad}");
        }
    }

    #[test]
    fn the_area_is_the_agent_monitors_usable_part() {
        let mut m = area_mon("");
        assert_eq!(usable_area(&m), Some(Rect { x: 0.0, y: 30.0, w: 1920.0, h: 1050.0 }));
        m["scale"] = json!(2.0);
        m["transform"] = json!(1);
        assert_eq!(usable_area(&m), Some(Rect { x: 0.0, y: 30.0, w: 540.0, h: 930.0 }), "scaled and rotated");
        let mut b = area_mon("");
        b["id"] = json!(1);
        b["x"] = json!(1920);
        b["focused"] = json!(false);
        let ws = json!([{ "name": AGENT_SPECIAL, "monitorID": 1 }]);
        assert_eq!(agent_area(&ws, &json!([area_mon(""), b])).unwrap().x, 1920.0, "the monitor that holds special:agent, not the focused one");
        assert_eq!(agent_area(&json!([]), &json!([area_mon("")])).unwrap().x, 0.0, "else the focused one");
    }

    #[test]
    fn workspaces_has_the_macs_fields_and_never_a_title_of_yours() {
        let (shared, log) = setup("aws-list", false);
        let env = workspaces(&shared, "t");
        let d = env.data.expect("ok");
        for k in ["agent_workspace", "agent_workspace_shown", "access", "workspaces", "your_windows", "note"] {
            assert!(d.get(k).is_some(), "{k}");
        }
        assert_eq!(d["agent_workspace"], AGENT_SPECIAL);
        assert_eq!(d["agent_workspace_shown"], false);
        let rows = d["workspaces"].as_array().unwrap();
        assert_eq!(rows.len(), 10, "the nine and the agent workspace");
        for r in rows {
            for k in ["number", "shown", "current", "agent", "windows"] {
                assert!(r.get(k).is_some(), "{k} in {r}");
            }
        }
        assert_eq!((rows[0]["shown"].clone(), rows[0]["current"].clone()), (json!(true), json!(true)));
        assert_eq!(rows[2]["windows"], 1);
        assert_eq!((rows[9]["agent"].clone(), rows[9]["name"].clone(), rows[9]["windows"].clone()), (json!(true), json!(AGENT_SPECIAL), json!(4)));
        let yours = d["your_windows"].as_array().unwrap();
        let ids: Vec<&str> = yours.iter().map(|w| w["id"].as_str().unwrap()).collect();
        assert_eq!(ids, [OWN, OWN2, DIALOG], "the agent's; not your window on workspace 3, and not one you parked");
        for w in yours {
            for k in ["id", "app", "pid", "workspace", "scope"] {
                assert!(w.get(k).is_some(), "{k}");
            }
        }
        assert!(!d.to_string().contains("t0xc1"), "never the title of your window");
        assert!(dispatches(&log).is_empty(), "read only");
    }

    #[test]
    fn arrange_sends_exact_frames_for_the_agents_windows_only() {
        let (shared, log) = setup("aws-arrange", false);
        let env = arrange(&shared, "t", &json!({ "layout": "halves" }));
        let d = env.data.expect("ok");
        assert_eq!(d["layout"], "halves");
        assert_eq!(d["area"], json!({ "x": 0, "y": 30, "width": 1920, "height": 1050 }));
        let ws: Vec<&str> = d["windows"].as_array().unwrap().iter().map(|w| w["window"].as_str().unwrap()).collect();
        assert_eq!(ws, [OWN, OWN2], "the dialog goes with its window, and your windows (on 3, or parked on the agent workspace) are never touched");
        for w in d["windows"].as_array().unwrap() {
            for k in ["window", "app", "applied", "frame"] {
                assert!(w.get(k).is_some(), "{k}");
            }
            assert_eq!(w["applied"], "now");
        }
        assert_eq!(
            dispatches(&log),
            [
                float_on(OWN), resize_to(OWN, 960, 1050), move_to(OWN, 0, 30),
                float_on(OWN2), resize_to(OWN2, 960, 1050), move_to(OWN2, 960, 30),
            ]
        );
        assert_all_quiet(&log);
        // Named windows: yours is refused before anything is sent, and so is a dialog.
        log.lock().unwrap().clear();
        assert_eq!(code(&arrange(&shared, "t", &json!({ "layout": "grid", "windows": [OWN, YOURS] }))), "not_supported");
        let e = arrange(&shared, "t", &json!({ "layout": "frames", "windows": [format!("{PARKED}=0,0,800,600")] }));
        assert_eq!(code(&e), "not_supported", "a window you parked takes no frame");
        assert!(e.error.unwrap().message.contains("no lend sheet"));
        assert_eq!(code(&arrange(&shared, "t", &json!({ "layout": "grid", "windows": [DIALOG] }))), "not_in_scope");
        assert_eq!(code(&arrange(&shared, "t", &json!({ "layout": "frames", "windows": ["0xa1=0,0,800"] }))), "invalid_args");
        assert_eq!(code(&arrange(&shared, "t", &json!({ "layout": "columns" }))), "invalid_args");
        assert!(dispatches(&log).is_empty(), "{:?}", dispatches(&log));
        let env = arrange(&shared, "t", &json!({ "layout": "frames", "windows": ["0xa2=100,0,800,600"] }));
        assert_eq!(env.data.unwrap()["windows"][0]["frame"], json!({ "x": 100, "y": 30, "width": 800, "height": 600 }));
        assert_eq!(dispatches(&log), [float_on(OWN2), resize_to(OWN2, 800, 600), move_to(OWN2, 100, 30)]);
        assert_all_quiet(&log);
    }

    #[test]
    fn move_refuses_your_window_and_a_dialog_and_frames_the_agents() {
        let (shared, log) = setup("aws-move", false);
        let e = move_window(&shared, "t", &json!({ "window": YOURS }));
        assert_eq!(code(&e), "not_supported");
        assert!(e.error.unwrap().message.contains("no lend sheet"), "says why");
        assert_eq!(code(&move_window(&shared, "t", &json!({ "window": DIALOG }))), "not_supported");
        assert_eq!(code(&move_window(&shared, "t", &json!({ "window": "0xdead" }))), "not_found");
        assert_eq!(code(&move_window(&shared, "t", &json!({ "window": "active" }))), "invalid_args");
        assert_eq!(code(&move_window(&shared, "t", &json!({ "window": OWN, "frame": "1,2,3" }))), "invalid_args");
        assert!(dispatches(&log).is_empty(), "nothing sent for a refusal: {:?}", dispatches(&log));
        let d = move_window(&shared, "t", &json!({ "window": OWN, "frame": "0,0,800,600" })).data.expect("ok");
        for k in ["window", "app", "from", "to", "moved", "frame", "applied"] {
            assert!(d.get(k).is_some(), "{k}");
        }
        assert_eq!((d["moved"].clone(), d["to"].clone(), d["applied"].clone()), (json!(false), json!(AGENT_SPECIAL), json!("now")));
        assert_eq!(dispatches(&log), [float_on(OWN), resize_to(OWN, 800, 600), move_to(OWN, 0, 30)]);
        // A window you parked is yours: no frame, no move, said the same way.
        log.lock().unwrap().clear();
        for args in [json!({ "window": PARKED }), json!({ "window": PARKED, "frame": "0,0,800,600" })] {
            let e = move_window(&shared, "t", &args);
            assert_eq!(code(&e), "not_supported", "{args}");
            assert!(e.error.unwrap().message.contains("no lend sheet"));
        }
        assert!(dispatches(&log).is_empty(), "{:?}", dispatches(&log));
        assert_all_quiet(&log);
    }

    #[test]
    fn an_agent_window_the_user_moved_out_is_theirs() {
        for shown in [false, true] {
            let (shared, log) = setup(&format!("aws-moved-out-{shown}"), shown);
            // The user took the agent's foot window to workspace 3, where it is in front.
            let me = std::process::id();
            let start = proc::start_time(me).unwrap_or(0);
            {
                let mut c = shared.lock().unwrap();
                c.model.apply(Event::ObserveWindow { window: "0xa9".into(), pid: me, start, app: "foot".into(), workspace: Some(3) }).unwrap();
                c.sessions.record("s1", "0xa9", Opened { pid: me, start, app: "foot".into(), stable: "1".into() });
            }
            let clients = json!([client("0xa9", me, "3", false)]).to_string();
            let monitors = json!([area_mon(if shown { AGENT_SPECIAL } else { "" })]).to_string();
            let (fake, flog) = fake_hypr(&format!("aws-moved-out2-{shown}"), move |r| match r {
                "j/clients" => clients.clone(),
                "j/monitors" => monitors.clone(),
                "j/workspaces" => "[]".into(),
                "j/activewindow" => "{\"address\":\"0xa9\"}".into(),
                _ => "ok".into(),
            });
            shared.lock().unwrap().hypr = fake.hypr.clone();
            for e in [
                move_window(&shared, "t", &json!({ "window": "0xa9" })),
                move_window(&shared, "t", &json!({ "window": "0xa9", "frame": "0,0,800,600" })),
                arrange(&shared, "t", &json!({ "layout": "full", "windows": ["0xa9"] })),
                close_window(&shared, "t", &json!({ "window": "0xa9", "session": "s1" })),
            ] {
                assert_eq!(code(&e), "not_in_scope", "{:?}", e.error);
            }
            assert!(dispatches(&flog).is_empty(), "nothing sent: {:?}", dispatches(&flog));
            let d = workspaces(&shared, "t").data.expect("still listed");
            assert_eq!(d["your_windows"][0]["scope"], "moved_out_by_user");
            assert!(dispatches(&log).is_empty());
        }
    }

    #[test]
    fn close_closes_only_what_this_session_opened() {
        let (shared, log) = setup("aws-close", false);
        let me = std::process::id();
        let start = proc::start_time(me).unwrap_or(0);
        shared.lock().unwrap().sessions.record("s1", OWN, Opened { pid: me, start, app: "foot".into(), stable: "1".into() });
        let refuse = |w: &str, s: &str| code(&close_window(&shared, "t", &json!({ "window": w, "session": s })));
        assert_eq!(refuse(OWN2, "s1"), "not_in_scope", "the agent's window, but not opened by this session");
        assert_eq!(refuse(OWN, "s2"), "not_in_scope", "another session's window");
        assert_eq!(refuse(OWN, ""), "not_in_scope", "no session");
        assert_eq!(refuse(YOURS, "s1"), "not_in_scope", "your window");
        assert_eq!(refuse(PARKED, "s1"), "not_in_scope", "a window you parked");
        assert_eq!(refuse("active", "s1"), "invalid_args");
        assert!(dispatches(&log).is_empty(), "nothing was sent for any refusal: {:?}", dispatches(&log));
        let d = close_window(&shared, "t", &json!({ "window": OWN, "session": "s1" })).data.expect("ok");
        for k in ["window", "app", "pressed", "target"] {
            assert!(d.get(k).is_some(), "{k}");
        }
        assert_eq!(d["closed"], false, "the fake Hyprland keeps listing it");
        assert_eq!(dispatches(&log), [close(OWN)]);
        assert_all_quiet(&log);
    }

    #[test]
    fn a_reused_pid_does_not_pass_close() {
        let mut s = SessionWindows::default();
        assert!(s.record("s1", "0x1", Opened { pid: 7, start: 100, app: "foot".into(), stable: "5".into() }));
        assert!(!s.record("s2", "0x1", Opened { pid: 7, start: 100, app: "foot".into(), stable: "5".into() }), "never two sessions");
        assert!(s.opened_by("s1", "0x1", 7, 100, "5"));
        assert!(!s.opened_by("s1", "0x1", 7, 101, "5"), "same pid, another process");
        assert!(!s.opened_by("s1", "0x1", 8, 100, "5"));
        assert!(!s.opened_by("s2", "0x1", 7, 100, "5"));
        s.forget("0x1");
        assert!(!s.opened_by("s1", "0x1", 7, 100, "5"));
        assert!(!s.record("", "0x2", Opened { pid: 7, start: 1, app: "x".into(), stable: "5".into() }));
    }

    #[test]
    fn another_window_at_the_same_address_does_not_pass_close() {
        let mut s = SessionWindows::default();
        assert!(s.record("s1", "0x1", Opened { pid: 7, start: 100, app: "foot".into(), stable: "5".into() }));
        assert!(!s.opened_by("s1", "0x1", 7, 100, "6"), "same address, pid and start time, another window");
        assert!(!s.opened_by("s1", "0x1", 7, 100, ""), "a window that reports no stableId");
        // Recorded with no stableId: never owned, whatever the window reports now.
        assert!(s.record("s1", "0x2", Opened { pid: 7, start: 100, app: "foot".into(), stable: String::new() }));
        assert!(!s.opened_by("s1", "0x2", 7, 100, ""));
        assert!(!s.opened_by("s1", "0x2", 7, 100, "5"));
        // keep_only: the record stays for the same window and goes for any other, or for none.
        s.keep_only("0x1", "5");
        assert_eq!(s.owner("0x1"), Some("s1"));
        s.keep_only("0x1", "6");
        assert_eq!(s.owner("0x1"), None);
        s.keep_only("0x2", "");
        assert_eq!(s.owner("0x2"), None);
    }

    /// A Core like `setup`'s whose Hyprland lists `clients(dispatches so far)` and answers each
    /// dispatch with `answer(dispatch)`.
    fn setup_on(tag: &str, clients: impl Fn(usize) -> Value + Send + 'static, answer: fn(&str) -> &'static str) -> (Shared, Arc<Mutex<Vec<String>>>) {
        let (shared, _) = setup(&format!("{tag}-model"), false);
        let sent = std::sync::atomic::AtomicUsize::new(0);
        let monitors = json!([area_mon("")]).to_string();
        let (fake, log) = fake_hypr(tag, move |r| {
            use std::sync::atomic::Ordering::SeqCst;
            match r {
                "j/clients" => clients(sent.load(SeqCst)).to_string(),
                "j/monitors" => monitors.clone(),
                "j/workspaces" => json!([{ "id": -98, "name": AGENT_SPECIAL, "windows": 1, "monitorID": 0 }]).to_string(),
                _ => match r.strip_prefix("/dispatch ") {
                    Some(lua) => {
                        sent.fetch_add(1, SeqCst);
                        answer(lua).into()
                    }
                    None => "ok".into(),
                },
            }
        });
        shared.lock().unwrap().hypr = fake.hypr.clone();
        (shared, log)
    }

    #[test]
    fn a_frame_hyprland_refuses_is_an_error_from_move() {
        let me = std::process::id();
        let (shared, log) = setup_on("aws-move-refused", move |_| json!([client(OWN, me, AGENT_SPECIAL, false)]), |lua| if lua.contains("window.resize") { "resize: no such window" } else { "ok" });
        let e = move_window(&shared, "t", &json!({ "window": OWN, "frame": "0,0,800,600" }));
        assert!(!e.ok, "a frame that was not applied is never ok");
        assert_eq!(code(&e), "compositor_error");
        let d = e.error.unwrap().data.expect("what was changed");
        assert_eq!((d["changed"].clone(), d["not_changed"].clone()), (json!([OWN]), json!([])), "it was floated before the resize failed");
        assert_eq!(dispatches(&log), [float_on(OWN), resize_to(OWN, 800, 600)], "nothing is sent after the step that failed");
        assert!(shared.lock().unwrap().dirty, "Hyprland is read again before the next command");
        // The first step refused: nothing was changed.
        let (shared, _log) = setup_on("aws-move-refused-first", move |_| json!([client(OWN, me, AGENT_SPECIAL, false)]), |_| "no");
        let e = move_window(&shared, "t", &json!({ "window": OWN, "frame": "0,0,800,600" }));
        assert_eq!(code(&e), "compositor_error");
        assert_eq!(e.error.unwrap().data.unwrap()["not_changed"], json!([OWN]));
    }

    #[test]
    fn close_reports_only_a_new_window_that_is_still_the_agents() {
        let me = std::process::id();
        let start = proc::start_time(me).unwrap_or(0);
        let mut asked = client("0xd1", me, AGENT_SPECIAL, true);
        asked["stableId"] = json!("2");
        let mut taken = client("0xd1", me, "3", false);
        taken["stableId"] = json!("2");
        // The app asks to save: a new dialog of the same process on the agent workspace is reported.
        let dialog = asked.clone();
        let (shared, _log) = setup_on("aws-close-asked", move |sent| if sent == 0 { json!([client(OWN, me, AGENT_SPECIAL, false)]) } else { json!([client(OWN, me, AGENT_SPECIAL, false), dialog.clone()]) }, |_| "ok");
        shared.lock().unwrap().sessions.record("s1", OWN, Opened { pid: me, start, app: "foot".into(), stable: "1".into() });
        let d = close_window(&shared, "t", &json!({ "window": OWN, "session": "s1" })).data.expect("ok");
        assert_eq!((d["opened"]["window"].clone(), d["opened"]["title"].clone()), (json!("0xd1"), json!("t0xd1")));
        // The same process opens a window and the user takes it to workspace 3 before the look: it is
        // theirs, so it is not reported and its title is not read.
        let (shared, _log) = setup_on("aws-close-taken", move |sent| if sent == 0 { json!([client(OWN, me, AGENT_SPECIAL, false)]) } else { json!([client(OWN, me, AGENT_SPECIAL, false), taken.clone()]) }, |_| "ok");
        shared.lock().unwrap().sessions.record("s1", OWN, Opened { pid: me, start, app: "foot".into(), stable: "1".into() });
        let d = close_window(&shared, "t", &json!({ "window": OWN, "session": "s1" })).data.expect("ok");
        assert!(d.get("opened").is_none(), "{d}");
        assert!(!d.to_string().contains("t0xd1"), "never the title of a window on your workspace");
        assert_eq!(d["closed"], false);
        // The window closes and another takes its address (another stableId): it is closed, by stableId.
        let mut reborn = client(OWN, me, "3", false);
        reborn["stableId"] = json!("9");
        let (shared, _log) = setup_on("aws-close-reborn", move |sent| if sent == 0 { json!([client(OWN, me, AGENT_SPECIAL, false)]) } else { json!([reborn.clone()]) }, |_| "ok");
        shared.lock().unwrap().sessions.record("s1", OWN, Opened { pid: me, start, app: "foot".into(), stable: "1".into() });
        let d = close_window(&shared, "t", &json!({ "window": OWN, "session": "s1" })).data.expect("ok");
        assert_eq!(d["closed"], true, "{d}");
        assert!(d.get("opened").is_none(), "{d}");
    }

    #[test]
    fn a_dialog_is_usable_only_from_an_agent_process() {
        let me = std::process::id();
        let start = proc::start_time(me).unwrap_or(0);
        let mut m = Model::new();
        m.apply(Event::ObserveWindow { window: "0x1".into(), pid: me, start, app: "foot".into(), workspace: None }).unwrap();
        m.apply(Event::ObserveWindow { window: "0x2".into(), pid: me, start, app: "foot".into(), workspace: None }).unwrap();
        m.apply(Event::AgentRegister { pid: me, start }).unwrap();
        let cl = |addr: &str, pid: u32, ws_id: i64, ws: &str, floating: bool| Client { addr: addr.into(), pid, ws_id, ws_name: ws.into(), monitor: 0, class: "x".into(), title: String::new(), mapped: true, stable_id: String::new(), floating };
        assert_eq!(standing(&m, &cl("0x2", me, -98, AGENT_SPECIAL, true), start, false, false), Standing::Child);
        assert_eq!(standing(&m, &cl("0x2", me, -98, AGENT_SPECIAL, true), start, false, true), Standing::Own, "floated by arrange, not a dialog");
        assert_eq!(standing(&m, &cl("0x1", me, -98, AGENT_SPECIAL, false), start, true, false), Standing::Own);
        assert_eq!(standing(&m, &cl("0x1", me, -98, AGENT_SPECIAL, true), start, true, false), Standing::Own, "the oldest window of its process is never a dialog, floating or not");
        assert_eq!(standing(&m, &cl("0x9", me, -1, "", true), start, false, false), Standing::Child, "unplaced");
        assert!(unplaced_child(&m, &cl("0x9", me, -1, "", true), start));
        // Another process's dialog, on the agent workspace or unplaced, is not the agent's.
        assert_eq!(standing(&m, &cl("0x8", 1, -98, AGENT_SPECIAL, true), 0, false, false), Standing::Yours);
        assert!(!unplaced_child(&m, &cl("0x8", 1, -1, "", true), 0));
        // The agent's dialog that landed on your workspace is not usable there.
        assert_eq!(standing(&m, &cl("0x7", me, 3, "3", true), start, false, false), Standing::OwnElsewhere);
        assert!(!unplaced_child(&m, &cl("0x7", me, 3, "3", true), start));
        assert!(!unplaced_child(&m, &cl("0x9", me, -1, "", false), start), "a dialog floats");
    }

    #[test]
    fn a_process_with_only_floating_windows_keeps_one_of_its_own() {
        // Two floating windows of one agent process on the agent workspace, nothing tiled: the first to
        // arrive is the process's own window, the second its dialog.
        let me = std::process::id();
        let start = proc::start_time(me).unwrap_or(0);
        let mut m = Model::new();
        for w in ["0x5", "0x4"] {
            m.apply(Event::ObserveWindow { window: w.into(), pid: me, start, app: "foot".into(), workspace: None }).unwrap();
        }
        m.apply(Event::AgentRegister { pid: me, start }).unwrap();
        let cl = |addr: &str| Client { addr: addr.into(), pid: me, ws_id: -98, ws_name: AGENT_SPECIAL.into(), monitor: 0, class: "x".into(), title: String::new(), mapped: true, stable_id: String::new(), floating: true };
        let clients = [cl("0x4"), cl("0x5")];
        assert!(oldest_of(&m, &clients, me, "0x5"), "arrival order, not address order");
        assert!(!oldest_of(&m, &clients, me, "0x4"));
        assert_eq!(standing(&m, &clients[1], start, oldest_of(&m, &clients, me, "0x5"), false), Standing::Own);
        assert_eq!(standing(&m, &clients[0], start, oldest_of(&m, &clients, me, "0x4"), false), Standing::Child);
    }

    #[test]
    fn a_session_lists_its_windows_in_the_order_they_opened() {
        let mut s = SessionWindows::default();
        for w in ["0xf", "0xa", "0x1b"] {
            assert!(s.record("s1", w, Opened { pid: 7, start: 1, app: "foot".into(), stable: "5".into() }));
        }
        let ws: Vec<String> = s.of("s1").into_iter().map(|(w, _)| w).collect();
        assert_eq!(ws, ["0xf", "0xa", "0x1b"]);
    }

    #[test]
    fn arrange_stops_at_a_window_that_left_and_sends_nothing_for_it() {
        // OWN2 goes back to workspace 3 after OWN's three dispatches: none is sent for OWN2.
        let (shared, log) = setup_with("aws-revalidate-a", false, Some((OWN2, |_, sent| sent >= 3)));
        let e = arrange(&shared, "t", &json!({ "layout": "halves" }));
        assert_eq!(code(&e), "not_in_scope");
        let d = e.error.unwrap().data.expect("which windows changed");
        assert_eq!((d["changed"].clone(), d["not_changed"].clone()), (json!([OWN]), json!([OWN2])));
        assert_eq!(dispatches(&log), [float_on(OWN), resize_to(OWN, 960, 1050), move_to(OWN, 0, 30)]);
        assert_all_quiet(&log);
        // OWN leaves between its own steps: the steps after are not sent, and it counts as changed.
        let (shared, log) = setup_with("aws-revalidate-b", false, Some((OWN, |_, sent| sent >= 1)));
        let d = arrange(&shared, "t", &json!({ "layout": "halves" })).error.unwrap().data.unwrap();
        assert_eq!((d["changed"].clone(), d["not_changed"].clone()), (json!([OWN]), json!([OWN2])));
        assert_eq!(dispatches(&log), [float_on(OWN)]);
        // It leaves right after it was chosen: nothing at all is sent.
        let (shared, log) = setup_with("aws-revalidate-c", false, Some((OWN, |reads, _| reads >= 1)));
        let d = arrange(&shared, "t", &json!({ "layout": "halves" })).error.unwrap().data.unwrap();
        assert_eq!((d["changed"].clone(), d["not_changed"].clone()), (json!([]), json!([OWN, OWN2])));
        assert!(dispatches(&log).is_empty(), "{:?}", dispatches(&log));
    }

    #[test]
    fn move_sends_nothing_for_a_window_that_left_after_it_was_chosen() {
        let (shared, log) = setup_with("aws-revalidate-move", false, Some((OWN, |reads, _| reads >= 1)));
        let e = move_window(&shared, "t", &json!({ "window": OWN, "frame": "0,0,800,600" }));
        assert_eq!(code(&e), "not_in_scope");
        assert_eq!(e.error.unwrap().data.unwrap()["not_changed"], json!([OWN]));
        assert!(dispatches(&log).is_empty(), "{:?}", dispatches(&log));
    }

    #[test]
    fn focus_is_reported_like_the_macs() {
        assert_eq!(focus_json(Some("0x1"), Some("0x1"), 3, 3), json!({ "changed": false, "returned": false }));
        assert_eq!(focus_json(Some("0x1"), Some("0x2"), 3, 4), json!({ "changed": true, "returned": true }));
        assert_eq!(focus_json(Some("0x1"), Some("0x1"), 3, 4), json!({ "changed": true, "returned": true }), "taken and given back is still a change");
    }
}
