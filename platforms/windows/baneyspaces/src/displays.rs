//! Which display a window sits on, and where it goes when its workspace comes up on another one (R-M1: workspace n
//! is the same workspace whichever display shows it). A hidden window stays where it was hidden, so without this a
//! workspace shown on display B would uncloak its windows on display A, over A's own workspace.
//!
//! The rule is the Mac's (`Geometry.carry`): the window's middle keeps its place as a fraction of the display's work
//! area, its size is kept when it fits, and it is kept inside the new display. A maximized window fills the new one.

pub type Rect = [i32; 4];

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

/// Where a window at `r` goes so that it is on display `to`, or None when it is there already or either display is
/// unknown (then it is left where it is). `filled`: the window is maximized, so it takes the whole work area.
pub fn carried(r: Rect, displays: &[(String, Rect)], to: &str, filled: bool) -> Option<Rect> {
    let from = display_of(r, displays)?;
    if from == to {
        return None;
    }
    let area = |n: &str| displays.iter().find(|(d, _)| d == n).map(|(_, a)| *a);
    let (a, b) = (area(from)?, area(to)?);
    Some(if filled { b } else { carry(r, a, b) })
}

#[cfg(test)]
mod tests {
    use super::*;

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
