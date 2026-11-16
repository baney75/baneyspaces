//! Which display a window sits on, and where it goes when its workspace comes up on another one (R-M1: workspace n
//! is the same workspace whichever display shows it). A hidden window stays where it was hidden, so without this a
//! workspace shown on display B would uncloak its windows on display A, over A's own workspace.
//!
//! The rule is the Mac's (`Geometry.carry`): the window's middle keeps its place as a fraction of the display's work
//! area, its size is kept when it fits, and it is kept inside the new display. A maximized window fills the new one.

use baneyspaces_core::model::Event;

pub type Rect = [i32; 4];

/// What a change in the display list means for the model, in the order it is applied: the displays that went
/// first, then the ones that came, in Windows' order (primary first). Removing first matters when a display is
/// swapped for another in one poll, as when a laptop lid closes on a dock: the new display is then the first one
/// and shows what you were on (R-M1, R-M3), instead of an empty workspace while yours goes out of sight. A
/// reorder with the same names is no change: a workspace belongs to its display, not to its place in the list.
pub fn monitor_events(known: &[String], now: &[String]) -> Vec<Event> {
    let gone = known.iter().filter(|m| !now.contains(m)).map(|m| Event::MonitorRemoved { monitor: m.clone() });
    let came = now.iter().filter(|m| !known.contains(m)).map(|m| Event::MonitorAdded { monitor: m.clone() });
    gone.chain(came).collect()
}

fn overlap(a: Rect, b: Rect) -> i64 {
    let w = (a[2].min(b[2]) - a[0].max(b[0])).max(0) as i64;
    let h = (a[3].min(b[3]) - a[1].max(b[1])).max(0) as i64;
    w * h
}

/// The display holding the window's middle, else the one it overlaps most, else none.
pub fn display_of(r: Rect, displays: &[(String, Rect)]) -> Option<&str> {
    let (mx, my) = ((r[0] + r[2]) / 2, (r[1] + r[3]) / 2);
    let holds = |d: &Rect| mx >= d[0] && mx < d[2] && my >= d[1] && my < d[3];
    if let Some((n, _)) = displays.iter().find(|(_, d)| holds(d)) {
        return Some(n);
    }
    displays.iter().map(|(n, d)| (n, overlap(r, *d))).filter(|(_, a)| *a > 0).max_by_key(|(_, a)| *a).map(|(n, _)| n.as_str())
}

/// `r` moved from display area `from` to display area `to`.
pub fn carry(r: Rect, from: Rect, to: Rect) -> Rect {
    let (tw, th) = (to[2] - to[0], to[3] - to[1]);
    let w = (r[2] - r[0]).min(tw);
    let h = (r[3] - r[1]).min(th);
    let frac = |mid: i32, lo: i32, len: i32| if len > 0 { (mid - lo) as f64 / len as f64 } else { 0.5 };
    let fx = frac((r[0] + r[2]) / 2, from[0], from[2] - from[0]);
    let fy = frac((r[1] + r[3]) / 2, from[1], from[3] - from[1]);
    let x = ((to[0] as f64 + fx * tw as f64) as i32 - w / 2).clamp(to[0], to[2] - w);
    let y = ((to[1] as f64 + fy * th as f64) as i32 - h / 2).clamp(to[1], to[3] - h);
    [x, y, x + w, y + h]
}

/// Where a window at `r` goes so that it is on display `to`, or None when it is there already or `to` is unknown
/// (then it is left where it is). `filled`: the window is maximized, so it takes the whole work area. A window on no
/// display, because the one it was hidden on is unplugged (R-M3), comes up in the middle of `to`, its size kept if
/// it fits: left where it was, it would come back where nothing shows it.
pub fn carried(r: Rect, displays: &[(String, Rect)], to: &str, filled: bool) -> Option<Rect> {
    let area = |n: &str| displays.iter().find(|(d, _)| d == n).map(|(_, a)| *a);
    let b = area(to)?;
    let Some(from) = display_of(r, displays) else {
        return Some(if filled { b } else { carry(r, r, b) });
    };
    if from == to {
        return None;
    }
    let a = area(from)?;
    Some(if filled { b } else { carry(r, a, b) })
}

/// R-V4: windows you moved to another display (a drag, Win+Shift+Arrow), each with that display and the workspace it
/// shows. `windows` are the ones on screen: (id, its workspace, its frame). One on a display showing its own workspace,
/// on a display showing nothing of the nine, or on no display, has not moved. Nor has one whose workspace no display
/// shows: Windows moved it off a display you unplugged, and R-M3 keeps it on its workspace, out of sight.
pub fn moved_across(windows: &[(String, u8, Rect)], displays: &[(String, Rect)], shows: impl Fn(&str) -> Option<u8>) -> Vec<(String, String, u8)> {
    let mut out = vec![];
    for (id, n, r) in windows {
        if !displays.iter().any(|(d, _)| shows(d) == Some(*n)) {
            continue;
        }
        let Some(d) = display_of(*r, displays) else { continue };
        match shows(d) {
            Some(m) if (1..=9).contains(&m) && m != *n => out.push((id.clone(), d.to_string(), m)),
            _ => {}
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use baneyspaces_core::model::Model;

    /// The daemon's `sync_monitors`, on a model: the display list Windows reports now.
    fn sync(m: &mut Model, now: &[&str]) {
        let now: Vec<String> = now.iter().map(|s| s.to_string()).collect();
        let known: Vec<String> = m.monitors().map(String::from).collect();
        for ev in monitor_events(&known, &now) {
            m.apply(ev).unwrap();
        }
    }

    fn open(m: &mut Model, w: &str, on: &str) {
        m.apply(Event::Open { window: w.into(), pid: 1, start: 0, app: "notepad".into(), monitor: Some(on.into()), workspace: None }).unwrap();
    }

    #[test]
    fn a_display_plugged_in_shows_an_empty_workspace_and_the_others_keep_theirs() {
        let mut m = Model::new();
        sync(&mut m, &["A"]);
        open(&mut m, "w1", "A");
        sync(&mut m, &["A", "B"]);
        assert_eq!((m.current("A"), m.current("B"), m.focused_monitor()), (Some(1), Some(2), Some("A")));
        sync(&mut m, &["A"]);
        sync(&mut m, &["A", "B"]);
        assert_eq!(m.current("B"), Some(2), "R-M2: it shows what it showed when it was last here");
    }

    #[test]
    fn a_display_unplugged_lets_go_of_its_workspace_and_you_go_to_the_first() {
        let mut m = Model::new();
        sync(&mut m, &["A", "B"]);
        m.apply(Event::ObserveFocusMonitor { monitor: "B".into() }).unwrap();
        open(&mut m, "w2", "B");
        sync(&mut m, &["A"]);
        assert_eq!((m.focused_monitor(), m.current("A")), (Some("A"), Some(1)));
        assert_eq!(m.shown_on(2), None, "R-M3: workspace 2 is out of sight");
        assert!(m.home("w2").is_some(), "and its window is still in it");
    }

    #[test]
    fn a_reorder_changes_nothing() {
        let mut m = Model::new();
        sync(&mut m, &["A", "B"]);
        assert!(monitor_events(&["A".into(), "B".into()], &["B".into(), "A".into()]).is_empty());
        sync(&mut m, &["B", "A"]);
        assert_eq!((m.current("A"), m.current("B")), (Some(1), Some(2)));
    }

    #[test]
    fn a_display_swapped_in_one_poll_shows_what_you_were_on() {
        // The lid closes on a dock: the laptop's display goes and the external one comes in the same poll.
        let mut m = Model::new();
        sync(&mut m, &["LAPTOP"]);
        open(&mut m, "w1", "LAPTOP");
        sync(&mut m, &["DOCK"]);
        assert_eq!((m.current("DOCK"), m.focused_monitor()), (Some(1), Some("DOCK")), "not an empty workspace with yours out of sight");
        assert_eq!(m.active(), Some("w1"));
    }

    #[test]
    fn the_daemon_syncs_displays_through_monitor_events() {
        let src = include_str!("daemon.rs").replace("\r\n", "\n");
        let start = src.find("pub fn sync_monitors(").expect("sync_monitors");
        let body = &src[start..start + src[start..].find("\n    }\n").expect("end of sync_monitors")];
        assert!(body.contains("displays::monitor_events("), "sync_monitors must apply displays::monitor_events in its order");
        assert!(!body.contains("Event::MonitorAdded"), "no second, add-first path");
    }

    fn two() -> Vec<(String, Rect)> {
        // A is 1920x1040 of work area at the origin; B, to its right, is 2560x1400.
        vec![("A".into(), [0, 0, 1920, 1040]), ("B".into(), [1920, 0, 4480, 1400])]
    }

    #[test]
    fn a_hidden_window_on_the_other_display_goes_to_the_one_showing_its_workspace() {
        // In the middle of A, 800x600: in the middle of B, the same size.
        let r = carried([560, 220, 1360, 820], &two(), "B", false).expect("it is on A, so it moves");
        assert_eq!(r, [2800, 400, 3600, 1000]);
        assert_eq!(display_of(r, &two()), Some("B"));
    }

    #[test]
    fn a_window_hidden_on_a_display_since_unplugged_comes_up_on_the_one_showing_its_workspace() {
        // It was parked from a third display, right of B, that is gone now: 800x600 at x 5000.
        let r = carried([5000, 100, 5800, 700], &two(), "A", false).expect("on no display, so it moves");
        assert_eq!(r, [560, 220, 1360, 820], "in the middle of A, the same size");
        assert_eq!(carried([5000, 100, 5800, 700], &two(), "B", true), Some([1920, 0, 4480, 1400]), "maximized, it fills B");
        assert_eq!(carried([5000, 100, 9000, 3000], &two(), "A", false), Some([0, 0, 1920, 1040]), "too big, it shrinks to A");
    }

    #[test]
    fn a_window_already_on_that_display_is_left_alone() {
        assert_eq!(carried([2000, 100, 2800, 700], &two(), "B", false), None);
        assert_eq!(carried([2000, 100, 2800, 700], &two(), "C", false), None, "an unknown display moves nothing");
    }

    #[test]
    fn it_keeps_its_place_and_stays_inside_the_new_display() {
        // Near A's right edge: near B's right edge, the same size, never past it.
        let r = carried([1420, 0, 1920, 400], &two(), "B", false).unwrap();
        assert_eq!((r[2] - r[0], r[3] - r[1]), (500, 400));
        assert!(r[0] > 3600 && r[2] <= 4480 && r[1] >= 0, "{r:?}");
        // From B's bottom right corner to the smaller A: inside A.
        let r = carried([3880, 1000, 4480, 1400], &two(), "A", false).unwrap();
        assert!(r[0] >= 0 && r[1] >= 0 && r[2] <= 1920 && r[3] <= 1040, "{r:?}");
    }

    #[test]
    fn a_window_bigger_than_the_new_display_shrinks_to_it_and_a_maximized_one_fills_it() {
        let r = carried([1920, 0, 4480, 1400], &two(), "A", false).unwrap();
        assert_eq!(r, [0, 0, 1920, 1040]);
        assert_eq!(carried([0, 0, 1920, 1040], &two(), "B", true), Some([1920, 0, 4480, 1400]));
    }

    #[test]
    fn a_window_straddling_two_displays_belongs_to_the_one_holding_its_middle() {
        assert_eq!(display_of([1500, 100, 2600, 600], &two()), Some("B"));
        assert_eq!(display_of([-500, -500, -100, -100], &two()), None, "on no display at all");
    }

    fn shows(d: &str) -> Option<u8> {
        match d {
            "A" => Some(1),
            "B" => Some(2),
            _ => None,
        }
    }

    #[test]
    fn a_window_dragged_to_the_other_display_joins_the_workspace_it_shows() {
        let w = vec![("w-1".to_string(), 1, [2000, 100, 2800, 700]), ("w-2".to_string(), 1, [100, 100, 900, 700])];
        assert_eq!(moved_across(&w, &two(), shows), vec![("w-1".to_string(), "B".to_string(), 2)], "w-2 never left A");
    }

    #[test]
    fn a_window_on_a_display_outside_the_nine_or_on_none_has_not_moved() {
        let w = vec![("w-1".to_string(), 1, [2000, 100, 2800, 700]), ("w-2".to_string(), 1, [-900, -900, -100, -100])];
        assert!(moved_across(&w, &two(), |d| (d == "A").then_some(1).or(Some(0))).is_empty());
        assert!(moved_across(&w[1..], &two(), shows).is_empty());
    }

    #[test]
    fn windows_moved_off_an_unplugged_display_stay_on_their_workspace() {
        // B (workspace 2) is gone; Windows put its window on A. Workspace 2 is out of sight, not moved (R-M3).
        let a_only = vec![("A".to_string(), [0, 0, 1920, 1040])];
        assert!(moved_across(&[("w-3".to_string(), 2, [100, 100, 900, 700])], &a_only, shows).is_empty());
    }

    /// Every poll mirrors those moves, before it decides what is hidden.
    #[test]
    fn the_daemon_mirrors_moves_before_it_hides_anything() {
        // Windows checks the source out with CRLF line ends.
        let src = &include_str!("daemon.rs").replace("\r\n", "\n");
        let poll = &src[src.find("fn poll(&mut self)").expect("poll")..];
        let mirror = poll.find("self.mirror_moves();").expect("poll mirrors moves");
        assert!(mirror < poll.find("self.sync_visibility()").unwrap(), "before sync_visibility, so a moved window is never hidden");
        let body = &src[src.find("fn mirror_moves(&mut self)").expect("mirror_moves")..];
        assert!(body[..body.find("\n    }\n").unwrap()].contains("Event::ObserveMove"));
    }

    /// The daemon carries a hidden window before it shows it, while it is still out of sight.
    #[test]
    fn the_daemon_carries_a_window_before_it_shows_it() {
        let src = include_str!("daemon.rs");
        let show = src.find("// 2. Show.").expect("the show step");
        let step = &src[show..show + src[show..].find("// 3. Hide").expect("the hide step")];
        let carry = step.find("self.carry_before_show(").expect("the show step carries the window");
        assert!(carry < step.find("cloak::show(").unwrap(), "carried before it is shown");
    }
}
