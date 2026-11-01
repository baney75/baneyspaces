//! The pure parts of the shell UI contract (spec/ui.md): the dock's edge and keep zone, the window
//! switcher's order, agent status badges, and the one JSON snapshot every shell surface draws from.
//! Nothing here talks to Hyprland or a socket, so all of it is unit tested.

use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap, HashSet};

// ---------------------------------------------------------------------------------------------
// Geometry

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        Rect { x, y, w, h }
    }
    pub fn contains(&self, p: (f64, f64)) -> bool {
        p.0 >= self.x && p.0 < self.x + self.w && p.1 >= self.y && p.1 < self.y + self.h
    }
    pub fn inflate(&self, by: f64) -> Rect {
        Rect::new(
            self.x - by,
            self.y - by,
            self.w + 2.0 * by,
            self.h + 2.0 * by,
        )
    }
    pub fn offset(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.w, self.h)
    }
}

#[derive(Clone, Debug)]
pub struct Screen {
    pub name: String,
    /// Logical (scaled) rectangle in the compositor's layout.
    pub rect: Rect,
}

// ---------------------------------------------------------------------------------------------
// The dock's edge, keep zone and lists (spec R-D1 to R-D6)

/// The bar you see plus this much, in points, keeps the dock up. Nothing else does (R-D3).
pub const KEEP_PT: f64 = 12.0;
/// The pointer is "on the edge" in the last rows of the screen.
pub const EDGE_PT: f64 = 2.0;
/// How long the pointer is off the keep zone before the dock goes down.
pub const AWAY_MS: u64 = 400;
/// A list closes this long after the pointer leaves it and its tile (R-D5). The shell plugin keeps
/// the timer, since only it knows which tile the pointer is on; the value is part of the contract.
#[allow(dead_code)]
pub const LIST_GRACE_MS: u64 = 250;
/// A pointer that rests where it brought the dock up keeps it up (R-D4).
const OPENER_SLOP: f64 = 3.0;
/// Before the bar is measured, the bottom of the screen this tall keeps it up.
const UNMEASURED_PT: f64 = 120.0;

#[derive(Debug, PartialEq, Eq)]
pub enum Change {
    Up(String),
    Down,
}

#[derive(Default, Debug)]
pub struct DockEdge {
    pub up: bool,
    pub monitor: Option<String>,
    /// Set by `dock show`: stays up until `dock hide`.
    pub pinned: bool,
    /// Reasons the dock must stay up (a drag, a context menu).
    pub holds: HashSet<String>,
    /// `behavior.dock.hide_ms`; `None` is the default.
    pub away_ms: Option<u64>,
    /// Bar and list rectangles as the shell reports them: monitor-local points.
    bar: Option<Rect>,
    list: Option<Rect>,
    at_edge: Option<(u64, String)>,
    away_since: Option<u64>,
    opener: Option<(f64, f64)>,
}

impl DockEdge {
    pub fn set_bar(&mut self, bar: Option<Rect>, list: Option<Rect>) {
        self.bar = bar;
        self.list = list;
    }

    pub fn list_open(&self) -> bool {
        self.list.is_some()
    }

    fn go_down(&mut self) {
        self.up = false;
        self.monitor = None;
        self.bar = None;
        self.list = None;
        self.away_since = None;
        self.opener = None;
        self.at_edge = None;
    }

    /// `dock show` and `dock hide`.
    pub fn pin(&mut self, on: bool, monitor: &str) -> Option<Change> {
        self.pinned = on;
        if on && !self.up {
            self.up = true;
            self.monitor = Some(monitor.to_string());
            self.opener = None;
            return Some(Change::Up(monitor.to_string()));
        }
        if !on && self.up && self.holds.is_empty() {
            self.go_down();
            return Some(Change::Down);
        }
        None
    }

    /// The zone that keeps the dock up on `screen`: the bar plus 12 pt, and the open list's own
    /// frame plus 12 pt. Never the whole panel (R-D3).
    pub fn keeps(&self, p: (f64, f64), screen: &Screen) -> bool {
        let o = (screen.rect.x, screen.rect.y);
        match self.bar {
            None => Rect::new(
                screen.rect.x,
                screen.rect.y + screen.rect.h - UNMEASURED_PT,
                screen.rect.w,
                UNMEASURED_PT,
            )
            .contains(p),
            Some(bar) => {
                bar.offset(o.0, o.1).inflate(KEEP_PT).contains(p)
                    || self
                        .list
                        .is_some_and(|l| l.offset(o.0, o.1).inflate(KEEP_PT).contains(p))
            }
        }
    }

    /// One look at the pointer. `fullscreen(name)` is asked only when the pointer rests on an edge.
    pub fn tick(
        &mut self,
        now_ms: u64,
        pointer: (f64, f64),
        screens: &[Screen],
        delay_ms: u64,
        fullscreen: &mut dyn FnMut(&str) -> bool,
    ) -> Option<Change> {
        let on = screens.iter().find(|s| s.rect.contains(pointer));
        if !self.up {
            let Some(s) = on else {
                self.at_edge = None;
                return None;
            };
            if pointer.1 < s.rect.y + s.rect.h - EDGE_PT {
                self.at_edge = None;
                return None;
            }
            let since = match &self.at_edge {
                Some((t, m)) if *m == s.name => *t,
                _ => {
                    self.at_edge = Some((now_ms, s.name.clone()));
                    now_ms
                }
            };
            if now_ms.saturating_sub(since) < delay_ms || fullscreen(&s.name) {
                return None;
            }
            self.up = true;
            self.monitor = Some(s.name.clone());
            self.opener = Some(pointer);
            self.away_since = None;
            self.at_edge = None;
            return Some(Change::Up(s.name.clone()));
        }
        if self.pinned {
            return None;
        }
        let mon = self.monitor.clone().unwrap_or_default();
        let screen = screens.iter().find(|s| s.name == mon);
        if let Some(o) = self.opener {
            if (pointer.0 - o.0).abs() > OPENER_SLOP || (pointer.1 - o.1).abs() > OPENER_SLOP {
                self.opener = None; // once it moves, only the zone counts
            }
        }
        let keeps = !self.holds.is_empty()
            || self.opener.is_some()
            || screen.is_some_and(|s| self.keeps(pointer, s));
        if keeps {
            self.away_since = None;
            return None;
        }
        let since = *self.away_since.get_or_insert(now_ms);
        if now_ms.saturating_sub(since) >= self.away_ms.unwrap_or(AWAY_MS) {
            self.go_down();
            return Some(Change::Down);
        }
        None
    }
}

// ---------------------------------------------------------------------------------------------
// Windows, and what the switcher steps through

#[derive(Clone, Debug)]
pub struct Win {
    pub addr: String,
    pub app: String,
    pub title: String,
    pub pid: u32,
    /// Hyprland's focus history: 0 is the window you used last.
    pub focus_rank: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub window: String,
    pub app: String,
    pub title: String,
    pub workspace: u8,
    /// Windows this app has on your workspaces (apps mode).
    pub count: usize,
}

impl Item {
    pub fn json(&self) -> Value {
        json!({ "window": self.window, "app": self.app, "title": self.title, "workspace": self.workspace, "count": self.count })
    }
}

/// What Alt+Tab offers: your windows on workspaces 1 to 9, most recently used first. `apps` keeps the
/// first (most recent) window of each app. The agent workspace is never offered.
pub fn switcher_items(wins: &[(Win, u8)], mode: &str) -> Vec<Item> {
    let mut v: Vec<&(Win, u8)> = wins.iter().collect();
    // A window that was never focused has rank -1 in Hyprland (or none): it goes to the end, not in front of the window you are on.
    let rank = |w: &Win| if w.focus_rank < 0 { i64::MAX } else { w.focus_rank };
    v.sort_by(|a, b| (rank(&a.0), &a.0.addr).cmp(&(rank(&b.0), &b.0.addr)));
    let mut count: HashMap<&str, usize> = HashMap::new();
    for (w, _) in &v {
        *count.entry(w.app.as_str()).or_default() += 1;
    }
    let mut seen = HashSet::new();
    v.iter()
        .filter(|(w, _)| mode != "apps" || seen.insert(w.app.clone()))
        .map(|(w, n)| Item {
            window: w.addr.clone(),
            app: w.app.clone(),
            title: w.title.clone(),
            workspace: *n,
            count: count[w.app.as_str()],
        })
        .collect()
}

#[derive(Default, Debug)]
pub struct Switcher {
    pub open: bool,
    pub index: usize,
    pub items: Vec<Item>,
    pub opened_at: u64,
    /// The overlay is not drawn before this: a quick tap of Alt+Tab goes straight to the window with no overlay at all.
    pub show_at: u64,
}

/// A press and release of the modifier shorter than this never shows an overlay.
pub const TAP_MS: u64 = 150;

impl Switcher {
    /// A press of Alt+Tab (`dir` +1) or Alt+Shift+Tab (-1). Opens with the window you used before
    /// this one selected, as ⌘Tab does. False if there is nothing to switch to.
    pub fn press(&mut self, fresh: Vec<Item>, dir: i32, now_ms: u64) -> bool {
        if !self.open {
            if fresh.is_empty() {
                return false;
            }
            self.index = if dir >= 0 {
                1.min(fresh.len() - 1)
            } else {
                fresh.len() - 1
            };
            self.items = fresh;
            self.open = true;
            self.show_at = now_ms + TAP_MS;
        } else if !self.items.is_empty() {
            self.show_at = self.show_at.min(now_ms); // a second press: you are holding it, so show it now
            let n = self.items.len() as i64;
            self.index = (self.index as i64 + dir.signum() as i64).rem_euclid(n) as usize;
        }
        self.opened_at = now_ms;
        true
    }

    pub fn visible(&self, now_ms: u64) -> bool {
        self.open && now_ms >= self.show_at
    }

    pub fn select(&mut self, i: usize) {
        if i < self.items.len() {
            self.index = i;
        }
    }

    pub fn commit(&mut self) -> Option<Item> {
        let it = self
            .open
            .then(|| self.items.get(self.index).cloned())
            .flatten();
        self.open = false;
        self.items.clear();
        it
    }

    pub fn cancel(&mut self) {
        self.open = false;
        self.items.clear();
    }

    pub fn json(&self, now_ms: u64) -> Value {
        json!({ "open": self.open, "visible": self.visible(now_ms), "index": self.index, "items": self.items.iter().map(Item::json).collect::<Vec<_>>() })
    }
}

// ---------------------------------------------------------------------------------------------
// Agent status badges (the Mac's turning ring, "?", "!" and finished count)

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Working,
    Asking,
    Error,
    Finished,
}

impl State {
    pub fn parse(s: &str) -> Option<State> {
        match s {
            "working" => Some(State::Working),
            "asking" => Some(State::Asking),
            "error" => Some(State::Error),
            "finished" => Some(State::Finished),
            _ => None,
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            State::Working => "working",
            State::Asking => "asking",
            State::Error => "error",
            State::Finished => "finished",
        }
    }
    fn rank(self) -> u8 {
        match self {
            State::Error => 4,
            State::Asking => 3,
            State::Working => 2,
            State::Finished => 1,
        }
    }
}

/// What a terminal title says about a coding agent: Claude Code puts a braille spinner in front
/// of the title while it works and a star when it is idle.
#[derive(Debug, PartialEq, Eq)]
pub enum TitleSays {
    Working,
    Idle,
}

pub fn title_says(title: &str) -> Option<TitleSays> {
    let c = title.trim_start().chars().next()?;
    match c {
        '\u{2800}'..='\u{28FF}' => Some(TitleSays::Working),
        '\u{2733}' => Some(TitleSays::Idle),
        _ => None,
    }
}

/// A working badge nobody has refreshed for this long is dropped (the Mac's stale limit).
pub const STALE_MS: u64 = 15 * 60 * 1000;

#[derive(Clone, Debug)]
struct Entry {
    state: State,
    at: u64,
    from_title: bool,
}

#[derive(Default, Debug)]
pub struct Badges {
    map: HashMap<String, Entry>,
}

impl Badges {
    /// A hook (or you) says what the agent in `window` is doing. `idle` clears.
    pub fn report(&mut self, window: &str, state: Option<State>, now: u64) {
        match state {
            Some(s) => {
                self.map.insert(
                    window.to_string(),
                    Entry {
                        state: s,
                        at: now,
                        from_title: false,
                    },
                );
            }
            None => {
                self.map.remove(window);
            }
        }
    }

    /// The window's title changed. Hooks outrank the title.
    pub fn title(&mut self, window: &str, title: &str, focused: bool, now: u64) {
        match title_says(title) {
            Some(TitleSays::Working) => {
                if self.map.get(window).is_some_and(|e| !e.from_title) {
                    self.map.get_mut(window).unwrap().at = now;
                } else {
                    self.map.insert(
                        window.to_string(),
                        Entry {
                            state: State::Working,
                            at: now,
                            from_title: true,
                        },
                    );
                }
            }
            Some(TitleSays::Idle) => {
                if self
                    .map
                    .get(window)
                    .is_some_and(|e| e.from_title && e.state == State::Working)
                {
                    if focused {
                        self.map.remove(window);
                    } else {
                        self.map.insert(
                            window.to_string(),
                            Entry {
                                state: State::Finished,
                                at: now,
                                from_title: true,
                            },
                        );
                    }
                }
            }
            None => {}
        }
    }

    /// You looked at it: finished and error are acknowledged.
    pub fn focus(&mut self, window: &str) {
        if self
            .map
            .get(window)
            .is_some_and(|e| matches!(e.state, State::Finished | State::Error))
        {
            self.map.remove(window);
        }
    }

    pub fn close(&mut self, window: &str) {
        self.map.remove(window);
    }

    pub fn expire(&mut self, now: u64) -> bool {
        let before = self.map.len();
        self.map
            .retain(|_, e| !(e.state == State::Working && now.saturating_sub(e.at) > STALE_MS));
        self.map.len() != before
    }

    pub fn get(&self, window: &str) -> Option<State> {
        self.map.get(window).map(|e| e.state)
    }

    pub fn best<'a>(&self, windows: impl Iterator<Item = &'a str>) -> Option<State> {
        windows.filter_map(|w| self.get(w)).max_by_key(|s| s.rank())
    }

    pub fn finished(&self) -> usize {
        self.map
            .values()
            .filter(|e| e.state == State::Finished)
            .count()
    }

    pub fn all(&self) -> BTreeMap<String, &'static str> {
        self.map
            .iter()
            .map(|(k, e)| (k.clone(), e.state.name()))
            .collect()
    }
}

/// The overview's 3 x 3 grid: an arrow key moves the highlight, never off an edge.
pub fn grid_step(i: usize, key: &str) -> usize {
    let (col, row) = (i % 3, i / 3);
    match key {
        "left" if col > 0 => i - 1,
        "right" if col < 2 => i + 1,
        "up" if row > 0 => i - 3,
        "down" if row < 2 => i + 3,
        _ => i,
    }
}

/// Super+Tab: the workspace after (or before) `from`, wrapping over the nine.
pub fn cycle(from: usize, dir: i32) -> usize {
    (from as i32 + dir.signum()).rem_euclid(9) as usize
}

// ---------------------------------------------------------------------------------------------
// The snapshot every surface draws

/// Apps on a tile before the rest fold into "+N".
pub const TILE_APPS: usize = 4;

pub struct Flags<'a> {
    pub overview: bool,
    /// The overview's highlighted workspace, 0-based, and whether it was opened by Super+Tab (let go of Super to go).
    pub overview_cursor: usize,
    pub overview_peek: bool,
    /// Drawn: a peek opened by Super+Tab only after the tap threshold.
    pub overview_visible: bool,
    pub settings: bool,
    pub launcher: bool,
    pub switcher: &'a Switcher,
    pub dock: &'a DockEdge,
    /// Seconds-resolution clock for the shell's own use.
    pub now_ms: u64,
}

/// `view` is `Model::view()`; `wins` are the windows Hyprland reports, `focused` the front one.
pub fn build_state(
    view: &Value,
    wins: &[Win],
    badges: &Badges,
    cfg: &Value,
    flags: &Flags,
    focused: Option<&str>,
) -> Value {
    let by_addr: HashMap<&str, &Win> = wins.iter().map(|w| (w.addr.as_str(), w)).collect();
    let on_ws = |n: u8| -> Vec<&str> {
        view["workspaces"][n.to_string()]
            .as_array()
            .map(|a| a.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default()
    };
    let shown_on = |n: u8| -> Vec<&str> {
        view["monitors"]
            .as_object()
            .map(|m| {
                m.iter()
                    .filter(|(_, v)| v["current"].as_u64() == Some(n as u64))
                    .map(|(k, _)| k.as_str())
                    .collect()
            })
            .unwrap_or_default()
    };
    let win_json = |a: &str| -> Value {
        let w = by_addr.get(a);
        json!({
            "window": a,
            "app": w.map(|w| w.app.as_str()).unwrap_or(""),
            "title": w.map(|w| w.title.as_str()).unwrap_or(""),
            "pid": w.map(|w| w.pid).unwrap_or(0),
            "focused": focused == Some(a),
            "badge": badges.get(a).map(State::name),
        })
    };
    let mut workspaces = vec![];
    let mut used = vec![];
    for n in 1..=9u8 {
        let list = on_ws(n);
        let shown = shown_on(n);
        // Apps in order of first window, each with its windows.
        let mut apps: Vec<(String, Vec<&str>)> = vec![];
        for a in &list {
            let class = by_addr.get(a).map(|w| w.app.clone()).unwrap_or_default();
            match apps.iter_mut().find(|(c, _)| *c == class) {
                Some((_, v)) => v.push(a),
                None => apps.push((class, vec![a])),
            }
        }
        let app_json: Vec<Value> = apps
            .iter()
            .map(|(class, ws)| {
                json!({
                    "app": class,
                    "count": ws.len(),
                    "windows": ws.iter().map(|a| win_json(a)).collect::<Vec<_>>(),
                    "focused": ws.iter().any(|a| focused == Some(*a)),
                    "badge": badges.best(ws.iter().copied()).map(State::name),
                })
            })
            .collect();
        let (shown_apps, more): (Vec<Value>, Vec<Value>) = if app_json.len() > TILE_APPS {
            (
                app_json[..TILE_APPS - 1].to_vec(),
                app_json[TILE_APPS - 1..].to_vec(),
            )
        } else {
            (app_json.clone(), vec![])
        };
        let in_use = !list.is_empty() || !shown.is_empty();
        if in_use {
            used.push(n);
        }
        workspaces.push(json!({
            "n": n,
            "empty": list.is_empty(),
            "shown_on": shown,
            "current": view["current"].as_u64() == Some(n as u64),
            "windows": list.iter().map(|a| win_json(a)).collect::<Vec<_>>(),
            "apps": app_json,
            "shown_apps": shown_apps,
            "more": more,
            "badge": badges.best(list.iter().copied()).map(State::name),
        }));
    }
    let new_target = (1..=9u8).find(|n| on_ws(*n).is_empty() && shown_on(*n).is_empty());
    json!({
        "version": 1,
        "focused_monitor": view["focused_monitor"],
        "current": view["current"],
        "active": view["active"],
        "monitors": view["monitors"],
        "workspaces": workspaces,
        "dock": {
            "tiles": used,
            "new_target": new_target,
            "up": flags.dock.up,
            "monitor": flags.dock.monitor,
            "pinned": flags.dock.pinned,
            "list_open": flags.dock.list_open(),
        },
        "agent": { "shown": view["agent"]["shown"], "windows": view["agent"]["windows"], "finished": badges.finished(), "badges": badges.all() },
        "switcher": flags.switcher.json(flags.now_ms),
        "overview": { "shown": flags.overview, "visible": flags.overview_visible, "cursor": flags.overview_cursor, "peek": flags.overview_peek },
        "launcher": { "open": flags.launcher },
        "settings": { "open": flags.settings },
        "config": cfg,
        "now": flags.now_ms,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screens() -> Vec<Screen> {
        vec![
            Screen {
                name: "A".into(),
                rect: Rect::new(0.0, 0.0, 1920.0, 1080.0),
            },
            Screen {
                name: "B".into(),
                rect: Rect::new(1920.0, 0.0, 1920.0, 1080.0),
            },
        ]
    }
    fn no_fs() -> impl FnMut(&str) -> bool {
        |_| false
    }

    #[test]
    fn the_dock_comes_up_after_the_pointer_rests_on_the_edge() {
        let mut d = DockEdge::default();
        let s = screens();
        assert_eq!(d.tick(0, (500.0, 1079.0), &s, 80, &mut no_fs()), None);
        assert_eq!(d.tick(40, (500.0, 1079.0), &s, 80, &mut no_fs()), None);
        assert_eq!(
            d.tick(90, (500.0, 1079.0), &s, 80, &mut no_fs()),
            Some(Change::Up("A".into()))
        );
        assert!(d.up);
    }

    #[test]
    fn passing_through_the_edge_does_not_bring_it_up() {
        let mut d = DockEdge::default();
        let s = screens();
        d.tick(0, (500.0, 1079.0), &s, 80, &mut no_fs());
        d.tick(30, (500.0, 700.0), &s, 80, &mut no_fs());
        assert_eq!(d.tick(200, (500.0, 700.0), &s, 80, &mut no_fs()), None);
        assert!(!d.up);
    }

    #[test]
    fn the_second_monitor_brings_up_its_own_dock() {
        let mut d = DockEdge::default();
        let s = screens();
        assert_eq!(d.tick(0, (2500.0, 1079.0), &s, 0, &mut no_fs()), Some(Change::Up("B".into())));
        assert_eq!(d.monitor.as_deref(), Some("B"));
    }

    #[test]
    fn a_full_screen_window_keeps_the_dock_down() {
        let mut d = DockEdge::default();
        let s = screens();
        let mut fs = |m: &str| m == "A";
        d.tick(0, (500.0, 1079.0), &s, 0, &mut fs);
        assert_eq!(d.tick(500, (500.0, 1079.0), &s, 0, &mut fs), None);
        assert!(!d.up);
    }

    fn up_with_bar() -> DockEdge {
        let mut d = DockEdge::default();
        let s = screens();
        d.tick(0, (960.0, 1079.0), &s, 0, &mut no_fs());
        d.tick(1, (960.0, 1079.0), &s, 0, &mut no_fs());
        assert!(d.up);
        // a 600 x 64 bar, 8 above the bottom edge, centered
        d.set_bar(Some(Rect::new(660.0, 1008.0, 600.0, 64.0)), None);
        d
    }

    #[test]
    fn the_keep_zone_is_the_bar_plus_twelve_points_and_nothing_else() {
        let d = up_with_bar();
        let s = &screens()[0];
        assert!(d.keeps((960.0, 1040.0), s), "on the bar");
        assert!(d.keeps((960.0, 1008.0 - 11.0), s), "11 pt above the bar");
        assert!(!d.keeps((960.0, 1008.0 - 13.0), s), "13 pt above the bar");
        assert!(d.keeps((660.0 - 11.0, 1040.0), s), "11 pt left of the bar");
        assert!(!d.keeps((660.0 - 13.0, 1040.0), s), "13 pt left of the bar");
        assert!(!d.keeps((100.0, 1040.0), s), "far to the side");
    }

    #[test]
    fn the_dock_goes_down_400ms_after_the_pointer_leaves_the_zone() {
        let mut d = up_with_bar();
        let s = screens();
        assert_eq!(d.tick(100, (960.0, 1040.0), &s, 0, &mut no_fs()), None);
        // moves away: first the opener hold ends, then the away delay runs
        assert_eq!(d.tick(200, (960.0, 600.0), &s, 0, &mut no_fs()), None);
        assert_eq!(d.tick(400, (960.0, 600.0), &s, 0, &mut no_fs()), None);
        assert_eq!(
            d.tick(620, (960.0, 600.0), &s, 0, &mut no_fs()),
            Some(Change::Down)
        );
        assert!(!d.up);
    }

    #[test]
    fn coming_back_in_time_cancels_the_away_delay() {
        let mut d = up_with_bar();
        let s = screens();
        d.tick(100, (960.0, 1040.0), &s, 0, &mut no_fs());
        d.tick(200, (960.0, 600.0), &s, 0, &mut no_fs());
        d.tick(300, (960.0, 600.0), &s, 0, &mut no_fs());
        d.tick(400, (960.0, 1040.0), &s, 0, &mut no_fs());
        assert_eq!(d.tick(800, (960.0, 1040.0), &s, 0, &mut no_fs()), None);
        assert!(d.up);
    }

    #[test]
    fn a_pointer_that_rests_where_it_opened_the_dock_holds_it_but_only_while_still() {
        let mut d = DockEdge::default();
        let s = screens();
        d.tick(0, (100.0, 1079.0), &s, 0, &mut no_fs());
        d.tick(1, (100.0, 1079.0), &s, 0, &mut no_fs());
        d.set_bar(Some(Rect::new(660.0, 1008.0, 600.0, 64.0)), None);
        // 2 s later, still there, off the bar: held
        assert_eq!(d.tick(2000, (100.0, 1079.0), &s, 0, &mut no_fs()), None);
        assert!(d.up);
        // moves a little to the side, outside the zone: the hold is over
        d.tick(2100, (140.0, 1079.0), &s, 0, &mut no_fs());
        assert_eq!(
            d.tick(2600, (140.0, 1079.0), &s, 0, &mut no_fs()),
            Some(Change::Down)
        );
    }

    #[test]
    fn an_open_list_adds_its_own_frame_and_the_zone_beside_it_does_not_hold() {
        let mut d = up_with_bar();
        let s = &screens()[0];
        // a 220 x 200 list standing on top of a tile
        d.set_bar(
            Some(Rect::new(660.0, 1008.0, 600.0, 64.0)),
            Some(Rect::new(800.0, 800.0, 220.0, 200.0)),
        );
        assert!(d.keeps((900.0, 850.0), s), "on the list");
        assert!(d.keeps((1020.0 + 11.0, 850.0), s), "11 pt beside the list");
        assert!(
            !d.keeps((1020.0 + 100.0, 850.0), s),
            "100 pt beside the list does not hold it"
        );
        assert!(!d.keeps((900.0, 700.0), s), "far above the list");
    }

    #[test]
    fn a_drag_or_a_menu_holds_the_dock_and_pinning_overrides_everything() {
        let mut d = up_with_bar();
        let s = screens();
        d.holds.insert("drag".into());
        d.tick(100, (960.0, 300.0), &s, 0, &mut no_fs());
        assert_eq!(d.tick(2000, (960.0, 300.0), &s, 0, &mut no_fs()), None);
        d.holds.clear();
        d.tick(2100, (960.0, 300.0), &s, 0, &mut no_fs());
        assert_eq!(
            d.tick(2600, (960.0, 300.0), &s, 0, &mut no_fs()),
            Some(Change::Down)
        );
        assert_eq!(d.pin(true, "A"), Some(Change::Up("A".into())));
        assert_eq!(d.tick(9000, (960.0, 300.0), &s, 0, &mut no_fs()), None);
        assert_eq!(d.pin(false, "A"), Some(Change::Down));
    }

    fn wins() -> Vec<(Win, u8)> {
        let w = |a: &str, app: &str, rank: i64, n: u8| {
            (
                Win {
                    addr: a.into(),
                    app: app.into(),
                    title: format!("{app} {a}"),
                    pid: 1,
                    focus_rank: rank,
                },
                n,
            )
        };
        vec![
            w("0x1", "foot", 2, 1),
            w("0x2", "firefox", 0, 3),
            w("0x3", "foot", 1, 5),
            w("0x4", "code", 3, 2),
        ]
    }

    #[test]
    fn the_switcher_lists_every_workspace_most_recent_first() {
        let items = switcher_items(&wins(), "windows");
        assert_eq!(
            items.iter().map(|i| i.window.as_str()).collect::<Vec<_>>(),
            ["0x2", "0x3", "0x1", "0x4"]
        );
        assert_eq!(items[1].workspace, 5);
    }

    #[test]
    fn apps_mode_keeps_each_apps_latest_window_and_counts() {
        let items = switcher_items(&wins(), "apps");
        assert_eq!(
            items.iter().map(|i| i.window.as_str()).collect::<Vec<_>>(),
            ["0x2", "0x3", "0x4"]
        );
        assert_eq!(items[1].count, 2);
    }

    #[test]
    fn alt_tab_selects_the_window_you_used_before_then_steps_and_wraps() {
        let mut s = Switcher::default();
        let items = switcher_items(&wins(), "windows");
        assert!(s.press(items.clone(), 1, 0));
        assert_eq!(s.index, 1);
        s.press(vec![], 1, 1);
        assert_eq!(s.index, 2);
        s.press(vec![], 1, 2);
        s.press(vec![], 1, 3);
        assert_eq!(s.index, 0, "wraps");
        s.press(vec![], -1, 4);
        assert_eq!(s.index, 3, "shift steps back");
        let it = s.commit().unwrap();
        assert_eq!(it.window, "0x4");
        assert!(!s.open);
        assert!(s.commit().is_none());
    }

    #[test]
    fn alt_shift_tab_opens_on_the_last_window_and_one_window_is_not_a_switch() {
        let mut s = Switcher::default();
        s.press(switcher_items(&wins(), "windows"), -1, 0);
        assert_eq!(s.index, 3);
        s.cancel();
        let one = switcher_items(&wins()[..1], "windows");
        assert!(s.press(one, 1, 0));
        assert_eq!(s.index, 0);
        assert!(!Switcher::default().press(vec![], 1, 0));
    }

    #[test]
    fn a_window_never_focused_goes_to_the_end_of_the_switcher_not_the_front() {
        let w = |a: &str, rank: i64, n: u8| (Win { addr: a.into(), app: "x".into(), title: a.into(), pid: 1, focus_rank: rank }, n);
        // 0x1 is the window you are on (rank 0), 0x2 the one before it (rank 1), 0x0 was never focused (rank -1, and it sorts first by address)
        let items = switcher_items(&[w("0x0", -1, 3), w("0x1", 0, 1), w("0x2", 1, 2)], "windows");
        assert_eq!(items.iter().map(|i| i.window.as_str()).collect::<Vec<_>>(), ["0x1", "0x2", "0x0"]);
        let mut s = Switcher::default();
        s.press(items, 1, 0);
        assert_eq!(s.commit().unwrap().window, "0x2", "Alt+Tab goes to the window you used before");
    }

    #[test]
    fn a_tap_never_shows_the_overlay_and_a_hold_does() {
        let mut s = Switcher::default();
        let items = switcher_items(&[(Win { addr: "0x1".into(), app: "a".into(), title: "a".into(), pid: 1, focus_rank: 0 }, 1), (Win { addr: "0x2".into(), app: "b".into(), title: "b".into(), pid: 2, focus_rank: 1 }, 2)], "windows");
        s.press(items, 1, 1000);
        assert!(s.open && !s.visible(1000) && !s.visible(1000 + TAP_MS - 1), "within the tap threshold: no overlay");
        assert!(s.visible(1000 + TAP_MS), "held past it: the overlay");
        let mut t = Switcher::default();
        t.press(vec![Item { window: "0x1".into(), app: "a".into(), title: "a".into(), workspace: 1, count: 1 }, Item { window: "0x2".into(), app: "b".into(), title: "b".into(), workspace: 2, count: 1 }], 1, 0);
        t.press(vec![], 1, 40);
        assert!(t.visible(40), "a second Tab press means you are holding it");
    }

    #[test]
    fn the_overview_grid_stops_at_its_edges_and_super_tab_wraps_over_nine() {
        assert_eq!((grid_step(0, "left"), grid_step(0, "right"), grid_step(2, "right"), grid_step(4, "up"), grid_step(7, "down")), (0, 1, 2, 1, 7));
        assert_eq!((cycle(8, 1), cycle(0, -1), cycle(3, 1), cycle(3, -1)), (0, 8, 4, 2));
    }

    #[test]
    fn claude_titles_are_read() {
        assert_eq!(title_says("⠂ Fix the dock"), Some(TitleSays::Working));
        assert_eq!(title_says("⠋ x"), Some(TitleSays::Working));
        assert_eq!(title_says("✳ Claude Code"), Some(TitleSays::Idle));
        assert_eq!(title_says("~/Projects — fish"), None);
        assert_eq!(title_says(""), None);
    }

    #[test]
    fn a_title_that_goes_idle_after_working_is_finished_unless_you_are_looking() {
        let mut b = Badges::default();
        b.title("w", "⠂ doing", false, 0);
        assert_eq!(b.get("w"), Some(State::Working));
        b.title("w", "✳ done", false, 10);
        assert_eq!(b.get("w"), Some(State::Finished));
        assert_eq!(b.finished(), 1);
        b.focus("w");
        assert_eq!(b.get("w"), None);
        b.title("w", "⠂ again", true, 20);
        b.title("w", "✳ done", true, 30);
        assert_eq!(b.get("w"), None, "you watched it finish");
    }

    #[test]
    fn hooks_outrank_titles_and_asking_survives_a_focus() {
        let mut b = Badges::default();
        b.report("w", Some(State::Asking), 0);
        b.title("w", "⠂ working", false, 5);
        assert_eq!(b.get("w"), Some(State::Asking));
        b.title("w", "✳ idle", false, 6);
        assert_eq!(b.get("w"), Some(State::Asking));
        b.focus("w");
        assert_eq!(b.get("w"), Some(State::Asking));
        b.report("w", Some(State::Error), 7);
        b.focus("w");
        assert_eq!(b.get("w"), None, "an error is acknowledged by looking");
        b.report("w", Some(State::Working), 8);
        b.report("w", None, 9);
        assert_eq!(b.get("w"), None);
    }

    #[test]
    fn a_working_badge_nobody_refreshed_expires() {
        let mut b = Badges::default();
        b.report("w", Some(State::Working), 0);
        b.report("f", Some(State::Finished), 0);
        assert!(!b.expire(STALE_MS - 1));
        assert!(b.expire(STALE_MS + 1));
        assert_eq!(b.get("w"), None);
        assert_eq!(b.get("f"), Some(State::Finished));
    }

    #[test]
    fn the_worst_state_of_an_app_wins() {
        let mut b = Badges::default();
        b.report("a", Some(State::Working), 0);
        b.report("b", Some(State::Asking), 0);
        b.report("c", Some(State::Finished), 0);
        assert_eq!(b.best(["a", "b", "c"].into_iter()), Some(State::Asking));
        assert_eq!(b.best(["a", "c"].into_iter()), Some(State::Working));
        assert_eq!(b.best(["x"].into_iter()), None);
    }

    fn snapshot(n_apps: usize) -> Value {
        let mut wins = vec![];
        let mut ws = vec![];
        for i in 0..n_apps {
            let a = format!("0x{i}");
            wins.push(Win {
                addr: a.clone(),
                app: format!("app{i}"),
                title: format!("t{i}"),
                pid: 10 + i as u32,
                focus_rank: i as i64,
            });
            ws.push(a);
        }
        let view = json!({
            "focused_monitor": "A", "current": 1, "active": "0x0",
            "monitors": { "A": { "slot": 0, "current": 1 }, "B": { "slot": 1, "current": 2 } },
            "workspaces": { "1": ws, "4": ["0x9"] },
            "agent": { "shown": false, "windows": [], "pids": [] },
        });
        wins.push(Win {
            addr: "0x9".into(),
            app: "mail".into(),
            title: "Inbox".into(),
            pid: 99,
            focus_rank: 9,
        });
        let mut badges = Badges::default();
        badges.report("0x1", Some(State::Working), 0);
        let sw = Switcher::default();
        let dock = DockEdge::default();
        let flags = Flags {
            overview: false,
            overview_cursor: 0,
            overview_peek: false,
            overview_visible: false,
            settings: false,
            launcher: false,
            switcher: &sw,
            dock: &dock,
            now_ms: 5,
        };
        build_state(&view, &wins, &badges, &json!({}), &flags, Some("0x0"))
    }

    #[test]
    fn the_snapshot_has_a_tile_for_each_workspace_in_use_plus_the_ones_you_are_on() {
        let s = snapshot(2);
        // 1 (windows, shown), 2 (shown on B, empty), 4 (a window)
        assert_eq!(s["dock"]["tiles"], json!([1, 2, 4]));
        assert_eq!(
            s["dock"]["new_target"],
            json!(3),
            "the first empty workspace nobody shows"
        );
        assert_eq!(s["workspaces"].as_array().unwrap().len(), 9);
        assert_eq!(s["workspaces"][0]["current"], json!(true));
        assert_eq!(s["workspaces"][1]["shown_on"], json!(["B"]));
    }

    #[test]
    fn four_apps_fit_five_fold_into_plus_n() {
        let four = snapshot(4);
        assert_eq!(
            four["workspaces"][0]["shown_apps"]
                .as_array()
                .unwrap()
                .len(),
            4
        );
        assert_eq!(four["workspaces"][0]["more"].as_array().unwrap().len(), 0);
        let six = snapshot(6);
        assert_eq!(
            six["workspaces"][0]["shown_apps"].as_array().unwrap().len(),
            3,
            "three and a +N"
        );
        assert_eq!(six["workspaces"][0]["more"].as_array().unwrap().len(), 3);
        assert_eq!(six["workspaces"][0]["apps"].as_array().unwrap().len(), 6);
    }

    #[test]
    fn badges_and_focus_reach_the_tile() {
        let s = snapshot(3);
        assert_eq!(s["workspaces"][0]["badge"], json!("working"));
        assert_eq!(s["workspaces"][0]["apps"][1]["badge"], json!("working"));
        assert_eq!(s["workspaces"][0]["apps"][0]["focused"], json!(true));
        assert_eq!(s["workspaces"][3]["apps"][0]["app"], json!("mail"));
    }

    #[test]
    fn with_all_nine_in_use_there_is_no_dashed_tile() {
        let mut wins = vec![];
        let mut m = serde_json::Map::new();
        for n in 1..=9 {
            let a = format!("0x{n}");
            wins.push(Win {
                addr: a.clone(),
                app: "x".into(),
                title: "".into(),
                pid: n,
                focus_rank: 0,
            });
            m.insert(n.to_string(), json!([a]));
        }
        let view = json!({ "focused_monitor": "A", "current": 1, "monitors": { "A": { "slot": 0, "current": 1 } }, "workspaces": m, "agent": {} });
        let (sw, dock) = (Switcher::default(), DockEdge::default());
        let f = Flags {
            overview: false,
            overview_cursor: 0,
            overview_peek: false,
            overview_visible: false,
            settings: false,
            launcher: false,
            switcher: &sw,
            dock: &dock,
            now_ms: 0,
        };
        let s = build_state(&view, &wins, &Badges::default(), &json!({}), &f, None);
        assert_eq!(s["dock"]["new_target"], Value::Null);
    }
}
