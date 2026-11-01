//! The daemon's side of the Omarchy shell plugins: the `subscribe` stream the plugins draw from, the
//! dock's pointer watcher, the switcher, the launcher, the overview and settings toggles, windows
//! moved by drag, agent status badges and the config. The rules are in `ui.rs` and `launcher.rs`;
//! this file carries them out against Hyprland.

use crate::config::{self, Config};
use crate::daemon::{lock, Core, Shared};
use crate::launcher::{self, Action, Ctx, LWin, Mode};
use crate::scheme::{decode, lua_str, sh_quote, AGENT_SPECIAL};
use crate::ui::{self, Badges, Change, DockEdge, Rect, Screen, State, Switcher};
use baneyspaces_core::envelope::{Envelope, Retry};
use baneyspaces_core::model::{Cause, Event};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

pub type Dirty = Arc<(Mutex<bool>, Condvar)>;

pub struct ShellState {
    pub subs: Vec<Sender<String>>,
    pub dirty: Dirty,
    pub cfg: Config,
    pub dock: DockEdge,
    pub switcher: Switcher,
    pub badges: Badges,
    pub launcher_open: bool,
    pub overview_cursor: usize,
    pub overview_peek: bool,
    pub settings_open: bool,
    pub apps: Vec<launcher::App>,
    apps_at: Option<Instant>,
    /// Result id -> what Return does, for the last search.
    pub last: HashMap<String, Action>,
    pub history: HashMap<String, u32>,
    pub clock: Instant,
    uwsm: bool,
}

impl ShellState {
    pub fn new(dirty: Dirty) -> Self {
        let uwsm = which("uwsm-app").is_some()
            && std::process::Command::new("uwsm")
                .args(["check", "is-active"])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
        ShellState {
            subs: vec![],
            dirty,
            cfg: Config::load(&config::config_path()),
            dock: DockEdge::default(),
            switcher: Switcher::default(),
            badges: Badges::default(),
            launcher_open: false,
            overview_cursor: 0,
            overview_peek: false,
            settings_open: false,
            apps: vec![],
            apps_at: None,
            last: HashMap::new(),
            history: HashMap::new(),
            clock: Instant::now(),
            uwsm,
        }
    }
}

fn which(app: &str) -> Option<std::path::PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    std::env::var("PATH")
        .ok()?
        .split(':')
        .map(|d| std::path::Path::new(d).join(app))
        .find(|p| {
            p.is_file()
                && p.metadata()
                    .map(|m| m.permissions().mode() & 0o111 != 0)
                    .unwrap_or(false)
        })
}

fn fail(code: &str, msg: impl Into<String>, sug: &str) -> Envelope {
    Envelope::err(code, msg, Retry::Never, sug)
}

fn arg_s<'a>(a: &'a Value, k: &str) -> Option<&'a str> {
    a.get(k).and_then(Value::as_str)
}

fn action_of(a: &Value) -> &str {
    arg_s(a, "action").unwrap_or("toggle")
}

impl Core {
    pub fn mark_dirty(&self) {
        let (m, cv) = &*self.shell.dirty;
        *m.lock().unwrap_or_else(|p| p.into_inner()) = true;
        cv.notify_one();
    }

    pub fn now_ms(&self) -> u64 {
        self.shell.clock.elapsed().as_millis() as u64
    }

    pub fn ui_state(&self) -> Value {
        let wins: Vec<ui::Win> = self
            .clients()
            .into_iter()
            .filter(|c| c.mapped)
            .map(|c| ui::Win {
                addr: c.addr,
                app: c.class,
                title: c.title,
                pid: c.pid,
                focus_rank: c.focus_rank,
            })
            .collect();
        let view = self.model.view();
        let focused = self.model.active().map(String::from);
        let flags = ui::Flags {
            overview: self.overview_shown,
            overview_cursor: self.shell.overview_cursor,
            overview_peek: self.shell.overview_peek,
            settings: self.shell.settings_open,
            launcher: self.shell.launcher_open,
            switcher: &self.shell.switcher,
            dock: &self.shell.dock,
            now_ms: self.now_ms(),
        };
        ui::build_state(
            &view,
            &wins,
            &self.shell.badges,
            &self.shell.cfg.effective(),
            &flags,
            focused.as_deref(),
        )
    }

    /// Your windows on workspaces 1 to 9 with the workspace each is on.
    fn user_windows(&self) -> Vec<(ui::Win, u8)> {
        self.clients()
            .into_iter()
            .filter(|c| c.mapped)
            .filter_map(|c| {
                let n = decode(c.ws_id, &c.ws_name)?;
                (!self.model.is_agent_window(&c.addr)).then(|| {
                    (
                        ui::Win {
                            addr: c.addr,
                            app: c.class,
                            title: c.title,
                            pid: c.pid,
                            focus_rank: c.focus_rank,
                        },
                        n,
                    )
                })
            })
            .collect()
    }

    pub fn screens(&self) -> Vec<Screen> {
        self.monitors()
            .into_iter()
            .map(|m| Screen {
                name: m.name,
                rect: m.rect,
            })
            .collect()
    }

    fn fullscreen_on(&self, monitor: &str) -> bool {
        let Some(id) = self
            .monitors()
            .into_iter()
            .find(|m| m.name == monitor)
            .map(|m| m.ws_id)
        else {
            return false;
        };
        self.hypr
            .json("workspaces")
            .ok()
            .and_then(|v| {
                v.as_array().and_then(|a| {
                    a.iter()
                        .find(|w| w["id"].as_i64() == Some(id))
                        .map(|w| w["hasfullscreen"].as_bool().unwrap_or(false))
                })
            })
            .unwrap_or(false)
    }

    /// A window's title changed: Claude Code's spinner and star tell us what the agent is doing.
    pub fn title_changed(&mut self, addr: &str) {
        let Some(c) = self.client(addr) else { return };
        let focused = self.model.active() == Some(addr);
        let now = self.now_ms();
        let before = self.shell.badges.get(addr);
        self.shell.badges.title(addr, &c.title, focused, now);
        if before != self.shell.badges.get(addr) || !self.shell.subs.is_empty() {
            self.mark_dirty();
        }
    }

    fn apps(&mut self) -> Vec<launcher::App> {
        let stale = self
            .shell
            .apps_at
            .is_none_or(|t| t.elapsed() > Duration::from_secs(30));
        if stale {
            self.shell.apps = launcher::scan_apps(&launcher::data_dirs());
            self.shell.apps_at = Some(Instant::now());
        }
        self.shell.apps.clone()
    }

    /// Starts a command the way the Omarchy launcher does, as a child of the session.
    fn spawn_user(&self, argv: &[String], terminal: bool) -> Result<String, String> {
        let mut words: Vec<String> = vec![];
        if terminal {
            words.push("xdg-terminal-exec".into());
        }
        words.extend(argv.iter().cloned());
        let mut cmd = words
            .iter()
            .map(|w| sh_quote(w))
            .collect::<Vec<_>>()
            .join(" ");
        if self.shell.uwsm {
            cmd = format!("uwsm-app -- {cmd}");
        }
        self.hypr
            .dispatch(&format!("hl.dsp.exec_cmd({})", lua_str(&cmd)))
            .map_err(|e| e.to_string())?;
        Ok(cmd)
    }

    fn save_history(&self) {
        self.paths.write_atomic(
            "launcher-history.json",
            &json!(self.shell.history).to_string(),
        );
    }
}

// ---------------------------------------------------------------------------------------------
// The stream the plugins subscribe to

/// Waits for a change, lets a burst settle, then pushes one snapshot to every subscriber.
pub fn spawn_publisher(shared: Shared, dirty: Dirty) {
    {
        let mut c = lock(&shared);
        c.shell.history = c
            .paths
            .read("launcher-history.json")
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
    }
    std::thread::spawn(move || loop {
        {
            let (m, cv) = &*dirty;
            let mut g = m.lock().unwrap_or_else(|p| p.into_inner());
            while !*g {
                g = cv.wait(g).unwrap_or_else(|p| p.into_inner());
            }
            *g = false;
        }
        std::thread::sleep(Duration::from_millis(12));
        *dirty.0.lock().unwrap_or_else(|p| p.into_inner()) = false;
        let mut c = lock(&shared);
        if c.persist_pending {
            c.persist_pending = false;
            c.persist();
        }
        if c.shell.subs.is_empty() {
            continue;
        }
        let line = json!({ "event": "ui", "data": c.ui_state() }).to_string();
        c.shell.subs.retain(|tx| tx.send(line.clone()).is_ok());
    });
}

/// Watches the pointer for the dock (Wayland clients cannot see it), expires stale badges and
/// notices edits of config.toml. Idle when nobody is subscribed.
pub fn spawn_pointer_loop(shared: Shared) {
    std::thread::spawn(move || {
        let mut last_housekeeping = Instant::now();
        loop {
            std::thread::sleep(Duration::from_millis(50));
            let mut c = lock(&shared);
            if c.shell.subs.is_empty() {
                continue;
            }
            if last_housekeeping.elapsed() > Duration::from_secs(1) {
                last_housekeeping = Instant::now();
                let now = c.now_ms();
                let mut changed = c.shell.badges.expire(now);
                changed |= c.shell.cfg.reload();
                // A switcher nobody finished (the key release was lost) closes by itself.
                if c.shell.switcher.open && now.saturating_sub(c.shell.switcher.opened_at) > 15_000
                {
                    c.shell.switcher.cancel();
                    changed = true;
                }
                if changed {
                    c.mark_dirty();
                }
            }
            if !c.shell.cfg.get_bool("dock.enabled") || !c.shell.cfg.get_bool("dock.auto_hide") {
                continue;
            }
            let Ok(p) = c.hypr.json("cursorpos") else {
                continue;
            };
            let pointer = (
                p["x"].as_f64().unwrap_or(0.0),
                p["y"].as_f64().unwrap_or(0.0),
            );
            let screens = c.screens();
            let delay = c.shell.cfg.get_i64("dock.edge_delay_ms").max(0) as u64;
            c.shell.dock.away_ms = Some(c.shell.cfg.get_i64("dock.hide_ms").max(0) as u64);
            let in_fullscreen = c.shell.cfg.get_bool("dock.in_fullscreen");
            let now = c.now_ms();
            let mut dock = std::mem::take(&mut c.shell.dock);
            let change = dock.tick(now, pointer, &screens, delay, &mut |m| {
                !in_fullscreen && c.fullscreen_on(m)
            });
            c.shell.dock = dock;
            if let Some(ch) = change {
                if c.trace {
                    eprintln!("[baneyspaces] dock {ch:?}: pointer {pointer:?}");
                }
                c.mark_dirty();
            }
        }
    });
}

// ---------------------------------------------------------------------------------------------
// Requests

fn toggle(flag: &mut bool, action: &str) -> bool {
    match action {
        "show" => *flag = true,
        "hide" => *flag = false,
        _ => *flag = !*flag,
    }
    *flag
}

/// Settings an agent process may change (everything about looks, and the dock switch).
const AGENT_SETTINGS_NOTE: () = ();
/// Every setting an agent may change: the spec lets agents change anything in config.toml; the operations that press your
/// keys (switch, move, show the agent workspace) stay yours.
fn agent_may_set(_key: &str) -> bool {
    true
}

/// Handles the shell operations; `None` for any other operation.
pub fn handle(shared: &Shared, op: &str, args: &Value, agent: &str, peer: Option<u32>) -> Option<Envelope> {
    Some(match op {
        "ui" => Envelope::ok(lock(shared).ui_state()),
        "config" => {
            let c = lock(shared);
            Envelope::ok(
                json!({ "settings": c.shell.cfg.effective(), "keys": Config::describe(), "path": c.shell.cfg.path().display().to_string() }),
            )
        }
        "config_set" => {
            let (Some(key), Some(v)) = (arg_s(args, "key"), args.get("value")) else {
                return Some(fail(
                    "invalid_args",
                    "usage: config set <key> <value>",
                    "Run `baneyspaces config` for the keys.",
                ));
            };
            let mut c = lock(shared);
            // Agents may change anything in config.toml (Donovan, 2026-11-01); the caller is logged. Pressing your keys
            // (switch, move, the agent workspace) stays refused to them.
            let from_agent = peer.is_some_and(|p| c.is_agent_peer(p));
            if from_agent && !agent_may_set(key) {
                let env = Envelope::err(
                    "not_in_scope",
                    format!("{key} is yours"),
                    Retry::Never,
                    "Ask the user to change it.",
                );
                crate::daemon::record(&c, agent, "config_set", peer, None, Some(key), "ctl", &env);
                return Some(env);
            }
            let result = c.shell.cfg.set(key, v);
            if from_agent {
                let env = match &result {
                    Ok(_) => Envelope::ok(json!({ "key": key })),
                    Err(e) => fail(e.code, e.message.clone(), ""),
                };
                crate::daemon::record(&c, agent, "config_set", peer, None, Some(key), "ctl", &env);
            }
            match result {
                Ok(stored) => {
                    if key == "animation.workspace.style" {
                        c.configure_hyprland(&[]);
                    }
                    c.mark_dirty();
                    Envelope::ok(json!({ "key": key, "value": stored }))
                }
                Err(e) => fail(e.code, e.message, "Run `baneyspaces config` for the keys and what they take."),
            }
        }
        "overview" => overview_op(shared, args),
        "settings" => {
            let mut c = lock(shared);
            let a = action_of(args).to_string();
            let mut f = c.shell.settings_open;
            toggle(&mut f, &a);
            c.shell.settings_open = f;
            c.mark_dirty();
            Envelope::ok(json!({ "shown": f }))
        }
        "launcher" => {
            let mut c = lock(shared);
            if !c.shell.cfg.get_bool("launcher.enabled") && action_of(args) != "hide" {
                return Some(fail(
                    "not_supported",
                    "the launcher is switched off in config.toml",
                    "baneyspaces config set launcher.enabled true",
                ));
            }
            let a = action_of(args).to_string();
            let mut f = c.shell.launcher_open;
            toggle(&mut f, &a);
            c.shell.launcher_open = f;
            if f {
                c.overview_shown = false;
                c.shell.switcher.cancel();
                c.apps(); // warm the app list
            }
            c.mark_dirty();
            Envelope::ok(json!({ "shown": f }))
        }
        "dock" => dock_op(shared, args),
        "dock_bar" => {
            let mut c = lock(shared);
            let rect = |v: &Value| {
                (!v.is_null()).then(|| {
                    Rect::new(
                        v["x"].as_f64().unwrap_or(0.0),
                        v["y"].as_f64().unwrap_or(0.0),
                        v["w"].as_f64().unwrap_or(0.0),
                        v["h"].as_f64().unwrap_or(0.0),
                    )
                })
            };
            if arg_s(args, "monitor") == c.shell.dock.monitor.as_deref() {
                c.shell
                    .dock
                    .set_bar(rect(&args["bar"]), rect(&args["list"]));
            }
            Envelope::ok(json!({}))
        }
        "switcher" => switcher_op(shared, args),
        "focus" => {
            let Some(w) = arg_s(args, "window") else {
                return Some(fail(
                    "invalid_args",
                    "a window id is required",
                    "Run `baneyspaces ls` for window ids.",
                ));
            };
            let mut c = lock(shared);
            focus_window(&mut c, w)
        }
        "move_windows" => move_windows(shared, args),
        "window_close" => {
            let c = lock(shared);
            let ws: Vec<&str> = args.get("windows").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
            // Only windows of yours: an agent's windows are not closed from the dock.
            let ok: Vec<&str> = ws.into_iter().filter(|w| c.model.is_tracked(w) && !c.model.is_agent_window(w)).collect();
            if ok.is_empty() {
                return Some(fail("not_found", "no window of yours to close", "Run `baneyspaces ls`."));
            }
            for w in &ok {
                let _ = c.hypr.dispatch(&format!("hl.dsp.window.close({{ window = {} }})", lua_str(&format!("address:{w}"))));
            }
            Envelope::ok(json!({ "closed": ok }))
        }
        "badge" => badge_op(shared, args),
        "launcher_search" => launcher_search(shared, args),
        "launcher_run" => launcher_run(shared, args, agent),
        _ => return None,
    })
}

/// An overlay (launcher, switcher, overview) that held the keyboard lets go of it first, and Hyprland then
/// refocuses the window you had. What the overlay chose is done after that, or it would be undone.
pub const SETTLE_MS: u64 = 120;

fn later(shared: &Shared, f: impl FnOnce(&mut Core) + Send + 'static) {
    let shared = shared.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(SETTLE_MS));
        f(&mut lock(&shared));
    });
}

fn focus_window(c: &mut Core, w: &str) -> Envelope {
    if !c.model.is_tracked(w) {
        return fail(
            "not_found",
            format!("no window {w}"),
            "Run `baneyspaces ls`.",
        );
    }
    if c.model.is_agent_window(w) {
        return fail(
            "agent_window",
            "that window belongs to an agent; show the agent workspace to see it",
            "baneyspaces agent-workspace show",
        );
    }
    // The model hears about an activation after the compositor has done it (R-F1 brings a hidden
    // workspace up from there). A request has to make it happen first: let the model plan the
    // workspace, then ask Hyprland for the focus itself (idempotent if the plan already did).
    let r = c.apply(Event::Activate { window: Some(w.into()), cause: Cause::User });
    let _ = c.hypr.dispatch(&format!("hl.dsp.focus({{ window = {} }})", lua_str(&format!("address:{w}"))));
    match r {
        Ok(fx) => Envelope::ok(json!({ "window": w, "effects": serde_json::to_value(fx).unwrap_or(Value::Null) })),
        Err(e) => e.envelope(),
    }
}

fn dock_op(shared: &Shared, args: &Value) -> Envelope {
    let mut c = lock(shared);
    // dock.enabled = false: there is no dock to show or hold (everything else keeps working).
    if !c.shell.cfg.get_bool("dock.enabled") && matches!(action_of(args), "show" | "toggle" | "hold") {
        return fail("not_supported", "the dock is switched off (dock.enabled = false)", "baneyspaces set dock.enabled true");
    }
    let focus_mon = c
        .model
        .focused_monitor()
        .map(String::from)
        .or_else(|| c.screens().first().map(|s| s.name.clone()))
        .unwrap_or_default();
    let reason = arg_s(args, "reason").unwrap_or("script").to_string();
    let change = match action_of(args) {
        "show" => c
            .shell
            .dock
            .pin(true, arg_s(args, "monitor").unwrap_or(&focus_mon)),
        "hide" => {
            c.shell.dock.holds.clear();
            c.shell.dock.pin(false, &focus_mon)
        }
        "toggle" => {
            let on = !c.shell.dock.up;
            c.shell.dock.pin(on, &focus_mon)
        }
        "hold" => {
            c.shell.dock.holds.insert(reason);
            None
        }
        "release" => {
            c.shell.dock.holds.remove(&reason);
            None
        }
        other => {
            return fail(
                "invalid_args",
                format!("unknown dock action {other:?}"),
                "show, hide, toggle, hold or release",
            )
        }
    };
    if change.is_some() || matches!(action_of(args), "hold" | "release") {
        c.mark_dirty();
    }
    Envelope::ok(
        json!({ "up": c.shell.dock.up, "monitor": c.shell.dock.monitor, "changed": change.map(|ch| matches!(ch, Change::Up(_))) }),
    )
}

fn switcher_op(shared: &Shared, args: &Value) -> Envelope {
    let mut c = lock(shared);
    if !c.shell.cfg.get_bool("switcher.enabled") && action_of(args) != "cancel" {
        return fail(
            "not_supported",
            "the switcher is switched off in config.toml",
            "baneyspaces config set switcher.enabled true",
        );
    }
    let now = c.now_ms();
    match action_of(args) {
        "next" | "prev" | "toggle" => {
            let dir = if action_of(args) == "prev" { -1 } else { 1 };
            let items = if c.shell.switcher.open {
                vec![]
            } else {
                ui::switcher_items(&c.user_windows(), &c.shell.cfg.get_str("switcher.items"))
            };
            if !c.shell.switcher.press(items, dir, now) {
                return Envelope::ok(json!({ "open": false, "note": "no window to switch to" }));
            }
            c.overview_shown = false;
            c.shell.launcher_open = false;
        }
        "select" => {
            let i = args.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
            c.shell.switcher.select(i);
        }
        "commit" => {
            let was_open = c.shell.switcher.open;
            let it = c.shell.switcher.commit();
            c.mark_dirty();
            if let Some(it) = it {
                // The switcher's surface lets go of the keyboard now; Hyprland hands focus back to the window you
                // had, so the choice is made once that has settled (or it would be undone).
                let w = it.window.clone();
                later(shared, move |c| {
                    let _ = focus_window(c, &w);
                    c.mark_dirty();
                });
                return Envelope::ok(json!({ "open": false, "window": it.window, "workspace": it.workspace }));
            }
            return Envelope::ok(
                json!({ "open": false, "committed": false, "was_open": was_open }),
            );
        }
        "cancel" => c.shell.switcher.cancel(),
        other => {
            return fail(
                "invalid_args",
                format!("unknown switcher action {other:?}"),
                "next, prev, commit, cancel or select",
            )
        }
    }
    c.mark_dirty();
    Envelope::ok(c.shell.switcher.json())
}

fn first_empty(c: &Core) -> Option<u8> {
    let view = c.model.view();
    (1..=9u8).find(|n| {
        view["workspaces"][n.to_string()]
            .as_array()
            .is_none_or(|a| a.is_empty())
            && c.model.shown_on(*n).is_none()
    })
}

fn move_windows(shared: &Shared, args: &Value) -> Envelope {
    let windows: Vec<String> = args
        .get("windows")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    if windows.is_empty() {
        return fail(
            "invalid_args",
            "usage: move-windows <n|new> <window>...",
            "Run `baneyspaces ls` for window ids.",
        );
    }
    let mut c = lock(shared);
    let n = if args["n"] == "new" || args["new"] == true {
        match first_empty(&c) {
            Some(n) => n,
            None => {
                return fail(
                    "not_found",
                    "all nine workspaces are in use",
                    "Close something or move it to a workspace by number.",
                )
            }
        }
    } else {
        match args["n"]
            .as_u64()
            .or_else(|| args["n"].as_str().and_then(|s| s.parse().ok()))
            .and_then(|n| u8::try_from(n).ok())
            .filter(|n| (1..=9).contains(n))
        {
            Some(n) => n,
            None => {
                return fail(
                    "invalid_args",
                    "a workspace number 1 to 9, or new, is required",
                    "Example: baneyspaces move-windows 4 0x55…",
                )
            }
        }
    };
    let (mut moved, mut failed) = (vec![], vec![]);
    for w in &windows {
        match c.apply(Event::Move {
            n,
            window: Some(w.clone()),
            follow: false,
        }) {
            Ok(_) => moved.push(w.clone()),
            Err(e) => failed.push(
                json!({ "window": w, "error": e.envelope().error.map(|e| e.code) }),
            ),
        }
    }
    c.mark_dirty();
    if moved.is_empty() {
        let code = failed
            .first()
            .and_then(|f| f["error"].as_str())
            .unwrap_or("not_found")
            .to_string();
        return fail(&code, "no window was moved", "Run `baneyspaces ls`.");
    }
    Envelope::ok(json!({ "workspace": n, "moved": moved, "failed": failed }))
}

fn ancestors(pid: u32) -> Vec<u32> {
    let mut v = vec![pid];
    let mut cur = pid;
    for _ in 0..64 {
        let Ok(stat) = std::fs::read_to_string(format!("/proc/{cur}/stat")) else {
            break;
        };
        let Some(rest) = stat.rfind(')').map(|i| &stat[i + 1..]) else {
            break;
        };
        let ppid: u32 = rest
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        if ppid <= 1 || v.contains(&ppid) {
            break;
        }
        v.push(ppid);
        cur = ppid;
    }
    v
}

fn badge_op(shared: &Shared, args: &Value) -> Envelope {
    let mut c = lock(shared);
    let now = c.now_ms();
    match arg_s(args, "action").unwrap_or("set") {
        "list" => Envelope::ok(json!({ "badges": c.shell.badges.all() })),
        "set" => {
            let state = arg_s(args, "state").unwrap_or("");
            let parsed = if matches!(state, "idle" | "clear" | "none") {
                None
            } else {
                match State::parse(state) {
                    Some(s) => Some(s),
                    None => {
                        return fail(
                            "invalid_args",
                            format!("unknown state {state:?}"),
                            "working, asking, error, finished or idle",
                        )
                    }
                }
            };
            let window = match arg_s(args, "window") {
                Some(w) => Some(w.to_string()),
                None => args.get("pid").and_then(Value::as_u64).and_then(|p| {
                    let chain = ancestors(p as u32);
                    c.clients()
                        .into_iter()
                        .find(|cl| chain.contains(&cl.pid))
                        .map(|cl| cl.addr)
                }),
            };
            let Some(w) = window.filter(|w| c.client(w).is_some()) else {
                return fail("not_found", "no window for that pid or id", "Pass --window <id> (baneyspaces ls) or --pid of a process inside the terminal.");
            };
            c.shell.badges.report(&w, parsed, now);
            c.mark_dirty();
            Envelope::ok(json!({ "window": w, "state": parsed.map(State::name) }))
        }
        other => fail(
            "invalid_args",
            format!("unknown badge action {other:?}"),
            "set or list",
        ),
    }
}

// ---------------------------------------------------------------------------------------------
// The launcher

/// Runs a program and returns its stdout, giving up (and killing it) after `limit`.
fn capture(prog: &str, args: &[String], limit: Duration) -> Option<String> {
    use std::io::Read;
    let mut child = std::process::Command::new(prog)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .ok()?;
    let mut out = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut b = Vec::new();
        let _ = out.read_to_end(&mut b);
        b
    });
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if start.elapsed() < limit => std::thread::sleep(Duration::from_millis(8)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break;
            }
        }
    }
    reader
        .join()
        .ok()
        .map(|b| String::from_utf8_lossy(&b).into_owned())
}

fn find_files(text: &str) -> Vec<String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let Some(first) = text.split_whitespace().next() else {
        return vec![];
    };
    let mut args: Vec<String> = [
        "-F",
        "-i",
        "-t",
        "f",
        "-t",
        "d",
        "-d",
        "6",
        "--max-results",
        "600",
        "--absolute-path",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    for ex in [
        "node_modules",
        "target",
        ".cache",
        ".git",
        ".local",
        ".cargo",
        ".rustup",
        ".npm",
        "go",
        ".var",
        "snap",
    ] {
        args.extend(["-E".into(), ex.into()]);
    }
    args.extend(["--".into(), first.into(), home]);
    capture("fd", &args, Duration::from_millis(1500))
        .map(|o| o.lines().map(|l| l.to_string()).collect::<Vec<String>>())
        .unwrap_or_default()
        .into_iter()
        .map(|p: String| {
            if std::path::Path::new(&p).is_dir() && !p.ends_with('/') {
                format!("{p}/")
            } else {
                p
            }
        })
        .collect()
}

fn search_packages(text: &str) -> Vec<launcher::Pkg> {
    let words: Vec<String> = text
        .split_whitespace()
        .map(|w| {
            w.chars()
                .filter(|c| c.is_ascii_alphanumeric() || "._+-".contains(*c))
                .collect::<String>()
        })
        .filter(|w| !w.is_empty())
        .collect();
    if words.is_empty() {
        return vec![];
    }
    let mut args = vec!["-Ss".to_string(), "--".to_string()];
    args.extend(words);
    let mut pk = capture("pacman", &args, Duration::from_millis(2500))
        .map(|o| launcher::parse_pacman_ss(&o))
        .unwrap_or_default();
    pk.sort_by_key(|p| std::cmp::Reverse(launcher::name_score(text, &p.name)));
    pk.truncate(15);
    pk
}

fn explicit_packages() -> Vec<String> {
    capture("pacman", &["-Qqe".to_string()], Duration::from_millis(2500))
        .map(|o| o.lines().map(String::from).collect())
        .unwrap_or_default()
}

fn launcher_search(shared: &Shared, args: &Value) -> Envelope {
    let query = launcher::parse_query(
        arg_s(args, "query").unwrap_or(""),
        Mode::parse(arg_s(args, "mode").unwrap_or("all")),
    );
    let (apps, wins, spaces, history, cfg, plan) = {
        let mut c = lock(shared);
        let apps = c.apps();
        let badges = c.shell.badges.all();
        let wins: Vec<LWin> = c
            .user_windows()
            .into_iter()
            .map(|(w, n)| LWin {
                badge: badges.get(&w.addr).map(|b| b.to_string()),
                addr: w.addr,
                app: w.app,
                title: w.title,
                ws: n,
            })
            .collect();
        let spaces: Vec<(u8, Vec<String>)> = (1..=9u8)
            .map(|n| {
                let mut names: Vec<String> = vec![];
                for w in wins.iter().filter(|w| w.ws == n) {
                    let name = apps
                        .iter()
                        .find(|a| launcher::app_owns_class(a, &w.app))
                        .map(|a| a.name.clone())
                        .unwrap_or_else(|| w.app.clone());
                    if !names.contains(&name) {
                        names.push(name);
                    }
                }
                (n, names)
            })
            .collect();
        let cfg = c.shell.cfg.effective();
        let plan = launcher::plan(&query, &cfg);
        (apps, wins, spaces, c.shell.history.clone(), cfg, plan)
    };
    // Slow lookups run without the daemon's lock.
    let files = plan.files.as_deref().map(find_files).unwrap_or_default();
    let packages = plan
        .packages
        .as_deref()
        .map(search_packages)
        .unwrap_or_default();
    let explicit = if plan.explicit {
        explicit_packages()
    } else {
        vec![]
    };
    let menus = launcher::omarchy_menus();
    let ctx = Ctx {
        apps: &apps,
        windows: &wins,
        spaces: &spaces,
        history: &history,
        cfg: &cfg,
        files: &files,
        packages: &packages,
        explicit: &explicit,
        has_claude: which("claude").is_some(),
        menus: &menus,
    };
    let hits = launcher::search(&ctx, &query);
    let rows: Vec<Value> = hits.iter().map(launcher::Hit::json).collect();
    let mut c = lock(shared);
    c.shell.last = hits.into_iter().map(|h| (h.id, h.action)).collect();
    Envelope::ok(json!({ "results": rows, "mode": arg_s(args, "mode").unwrap_or("all") }))
}

fn launcher_run(shared: &Shared, args: &Value, agent: &str) -> Envelope {
    let Some(id) = arg_s(args, "id") else {
        return fail(
            "invalid_args",
            "a result id is required",
            "Run `baneyspaces launcher search <text>`.",
        );
    };
    let confirm = args["confirm"].as_bool().unwrap_or(false);
    let dry =
        args["dry_run"].as_bool().unwrap_or(false) || std::env::var("BANEYSPACES_DRY_RUN").is_ok();
    let mut c = lock(shared);
    let Some(action) = c.shell.last.get(id).cloned() else {
        return fail(
            "not_found",
            format!("no result {id:?} in the last search"),
            "Search again.",
        );
    };
    if action.needs_confirm() && !confirm {
        let (verb, name) = match &action {
            Action::Pkg { verb, name } => (*verb, name.clone()),
            _ => unreachable!(),
        };
        return Envelope::ok(
            json!({ "needs_confirm": true, "message": format!("{} {name}?", if verb == "add" { "Install" } else { "Remove" }), "command": format!("omarchy pkg {verb} {name}") }),
        );
    }
    let apps = c.apps();
    let (argv, terminal, note): (Option<Vec<String>>, bool, &str) = match &action {
        Action::Launch(app_id) => match apps.iter().find(|a| &a.id == app_id) {
            Some(a) => {
                *c.shell.history.entry(format!("app:{app_id}")).or_default() += 1;
                (Some(launcher::exec_argv(&a.exec)), a.terminal, "launched")
            }
            None => return fail("not_found", format!("no app {app_id}"), "Search again."),
        },
        Action::Run { argv, terminal } => (Some(argv.clone()), *terminal, "ran"),
        Action::Url(u) => match launcher::safe_url(u) {
            Some(u) => (Some(vec!["xdg-open".into(), u]), false, "opened"),
            None => return fail("invalid_args", "only web addresses open", ""),
        },
        Action::OpenPath(p) => (Some(vec!["xdg-open".into(), p.clone()]), false, "opened"),
        Action::Pkg { verb, name } if launcher::safe_pkg(name) => (
            Some(vec![
                "omarchy-launch-floating-terminal-with-presentation".into(),
                format!("omarchy pkg {verb} {name}"),
            ]),
            false,
            "started in a terminal",
        ),
        Action::Pkg { .. } => return fail("invalid_args", "unsafe package name", ""),
        _ => (None, false, ""),
    };
    c.shell.launcher_open = false;
    let result = if let Some(argv) = argv {
        if dry {
            Ok(json!({ "dry_run": true, "would_run": argv, "terminal": terminal }))
        } else {
            c.spawn_user(&argv, terminal)
                .map(|cmd| json!({ "did": note, "command": cmd }))
        }
    } else {
        match &action {
            Action::Focus(w) => {
                let w = w.clone();
                later(shared, move |c| {
                    let _ = focus_window(c, &w);
                    c.mark_dirty();
                });
                Ok(json!({ "did": "focus", "after_ms": SETTLE_MS }))
            }
            Action::Switch(n) => {
                let n = *n;
                later(shared, move |c| {
                    let _ = c.apply(Event::Switch { n });
                });
                Ok(json!({ "did": "switched", "workspace": n, "after_ms": SETTLE_MS }))
            }
            Action::Internal("overview") => {
                c.overview_shown = true;
                c.persist();
                Ok(json!({ "did": "overview" }))
            }
            Action::Internal("settings") => {
                c.shell.settings_open = true;
                Ok(json!({ "did": "settings" }))
            }
            Action::Internal("agent") => match c.apply(Event::AgentToggle) {
                Ok(_) => Ok(json!({ "did": "agent workspace toggled" })),
                Err(e) => return e.envelope(),
            },
            _ => Ok(json!({ "did": "nothing" })),
        }
    };
    c.save_history();
    c.mark_dirty();
    let _ = (agent, AGENT_SPECIAL);
    match result {
        Ok(v) => Envelope::ok(v),
        Err(e) => Envelope::err("internal", e, Retry::Safe, "Is Hyprland running?"),
    }
}

/// The overview. `toggle|show|hide` as before; `next|prev` are Super+Tab and Super+Shift+Tab (opens on the
/// workspace after or before the one you are on; Tab again steps; letting go of Super goes: `go`); `step`
/// moves the highlight by an arrow key; `go` goes to the highlighted workspace and closes (once the
/// overview has let go of the keyboard, or Hyprland would refocus your old window and undo it).
fn overview_op(shared: &Shared, args: &Value) -> Envelope {
    let mut c = lock(shared);
    let a = action_of(args).to_string();
    if !c.shell.cfg.get_bool("overview.enabled") && !matches!(a.as_str(), "hide" | "go") {
        return fail("not_supported", "the overview is switched off in config.toml", "baneyspaces config set overview.enabled true");
    }
    let here = c.model.view()["current"].as_u64().map(|n| (n as usize).saturating_sub(1)).unwrap_or(0).min(8);
    match a.as_str() {
        "next" | "prev" => {
            let dir = if a == "next" { 1 } else { -1 };
            if c.overview_shown {
                c.shell.overview_cursor = ui::cycle(c.shell.overview_cursor, dir);
            } else {
                c.overview_shown = true;
                c.shell.overview_peek = true;
                c.shell.overview_cursor = ui::cycle(here, dir);
            }
        }
        "step" => {
            let k = arg_s(args, "key").unwrap_or("");
            c.shell.overview_cursor = ui::grid_step(c.shell.overview_cursor, k);
        }
        "go" => {
            let n = (c.shell.overview_cursor + 1) as u8;
            let was = c.overview_shown;
            c.overview_shown = false;
            c.shell.overview_peek = false;
            c.persist();
            c.mark_dirty();
            if was {
                later(shared, move |c| {
                    let _ = c.apply(Event::Switch { n });
                });
            }
            return Envelope::ok(json!({ "shown": false, "workspace": n, "after_ms": SETTLE_MS }));
        }
        _ => {
            let mut f = c.overview_shown;
            toggle(&mut f, &a);
            if f && !c.overview_shown {
                c.shell.overview_cursor = here;
                c.shell.overview_peek = false;
            }
            c.overview_shown = f;
            if !f {
                c.shell.overview_peek = false;
            }
        }
    }
    if c.overview_shown {
        c.shell.launcher_open = false;
        c.shell.switcher.cancel();
    }
    c.persist();
    c.mark_dirty();
    Envelope::ok(json!({ "shown": c.overview_shown, "cursor": c.shell.overview_cursor, "peek": c.shell.overview_peek }))
}
