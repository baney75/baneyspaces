//! The Windows chords from `spec/keys.json`, and the match the keyboard hook runs on every key.
//!
//! Explorer owns Win+1 to Win+9, so `RegisterHotKey` fails for them. The daemon instead sees every
//! key in a `WH_KEYBOARD_LL` hook and swallows only the chords listed here. The hook callback has to
//! be fast, so the match is a small pure function over a pre-built table.

use baneyspaces_core::keymap;
use std::sync::atomic::{AtomicU32, Ordering};

pub const VK_LWIN: u32 = 0x5B;
pub const VK_RWIN: u32 = 0x5C;
pub const VK_OEM_3: u32 = 0xC0; // the grave / backtick key

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Mods {
    pub win: bool,
    pub shift: bool,
    pub alt: bool,
    pub ctrl: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Binding {
    pub mods: Mods,
    pub vk: u32,
    /// The `baneyspaces` arguments this chord runs, e.g. `["switch", "3"]`.
    pub args: Vec<String>,
}

/// `"win+shift+{n}"` with a digit, or `"win+grave"`, as modifiers and a virtual-key code.
pub fn parse_chord(template: &str, digit: Option<u8>) -> Option<(Mods, u32)> {
    let mut mods = Mods::default();
    let mut vk = None;
    for part in template.split('+').map(str::trim) {
        match part {
            "win" | "cmd" | "super" => mods.win = true,
            "shift" => mods.shift = true,
            "alt" => mods.alt = true,
            "ctrl" => mods.ctrl = true,
            "{n}" => vk = Some(0x30 + u32::from(digit?)),
            "grave" => vk = Some(VK_OEM_3),
            _ => return None,
        }
    }
    vk.map(|k| (mods, k))
}

/// Every binding the spec gives Windows: switch 1-9, move 1-9, move-and-stay 1-9 (none by default),
/// the agent workspace toggle. Overview has no key in part 1.
pub fn bindings() -> Vec<Binding> {
    let k = keymap::keys();
    let w = &k["platforms"]["windows"];
    let mut out = vec![];
    let mut add = |template: &str, digit: Option<u8>, args: Vec<String>| {
        if let Some((mods, vk)) = parse_chord(template, digit) {
            out.push(Binding { mods, vk, args });
        }
    };
    for n in 1..=9u8 {
        add(w["switch"].as_str().unwrap_or(""), Some(n), vec!["switch".into(), n.to_string()]);
    }
    for n in 1..=9u8 {
        add(w["move"].as_str().unwrap_or(""), Some(n), vec!["move".into(), n.to_string()]);
    }
    for n in 1..=9u8 {
        add(w["move_stay"].as_str().unwrap_or(""), Some(n), vec!["move".into(), n.to_string(), "--stay".into()]);
    }
    add(w["agent_toggle"].as_str().unwrap_or(""), None, vec!["agent-workspace".into(), "toggle".into()]);
    out
}

/// The binding for this key with exactly these modifiers held, if any.
pub fn lookup<'a>(table: &'a [Binding], vk: u32, mods: Mods) -> Option<&'a Binding> {
    table.iter().find(|b| b.vk == vk && b.mods == mods)
}

/// The virtual keys of the modifiers the chords use, grouped.
pub const WIN_KEYS: &[u32] = &[VK_LWIN, VK_RWIN];
pub const SHIFT_KEYS: &[u32] = &[0xA0, 0xA1, 0x10];
pub const ALT_KEYS: &[u32] = &[0xA4, 0xA5, 0x12];
pub const CTRL_KEYS: &[u32] = &[0xA2, 0xA3, 0x11];
pub const MOD_KEYS: [u32; 11] = [0x5B, 0x5C, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x10, 0x11, 0x12];

/// A key-down this recent is believed even when `GetAsyncKeyState` has not caught up yet (a chord sent
/// by a VM or a remote session puts two keys in the same millisecond).
pub const RECENT_MS: u32 = 40;

/// Which modifier keys the hook believes are down, and since when (the event's tick, 0 = up).
///
/// The hook only sees key events on the user's desktop. A key-up that happens elsewhere (Win+L and the
/// secure desktop, Ctrl+Alt+Del, a UAC prompt, a key released while an elevated window has focus)
/// never arrives, and a counter that trusted itself would call that modifier down forever. So the count
/// is only a hint: on every candidate chord each modifier it believes down is confirmed against the
/// real key state, or by a key-down so recent the real state may not show it yet. One that fails is
/// cleared. All atomics: the hook callback takes no lock.
pub struct ModState {
    down_at: [AtomicU32; 256],
}

impl Default for ModState {
    fn default() -> Self {
        Self::new()
    }
}

impl ModState {
    pub const fn new() -> Self {
        #[allow(clippy::declare_interior_mutable_const)]
        const Z: AtomicU32 = AtomicU32::new(0);
        Self { down_at: [Z; 256] }
    }

    /// A modifier key event. `tick` is the event's time in milliseconds.
    pub fn event(&self, vk: u32, down: bool, tick: u32) {
        if MOD_KEYS.contains(&vk) {
            // 0 means up, so a down at tick 0 is stored as 1.
            self.down_at[vk as usize].store(if down { tick.max(1) } else { 0 }, Ordering::Relaxed);
        }
    }

    /// Believe `vk` is down from `tick` (the hook just started and the key already was).
    pub fn assume_down(&self, vk: u32, tick: u32) {
        self.event(vk, true, tick);
    }

    /// Forget everything: the session locked or unlocked, or the input desktop changed.
    pub fn reset(&self) {
        for k in MOD_KEYS {
            self.down_at[k as usize].store(0, Ordering::Relaxed);
        }
    }

    fn group_held(&self, keys: &[u32], now: u32, real: &impl Fn(u32) -> bool) -> bool {
        let mut held = false;
        for k in keys {
            let at = self.down_at[*k as usize].load(Ordering::Relaxed);
            if at == 0 {
                continue;
            }
            if real(*k) || now.wrapping_sub(at) < RECENT_MS {
                held = true;
            } else {
                // Believed down, not down: its key-up was missed.
                self.down_at[*k as usize].store(0, Ordering::Relaxed);
            }
        }
        held
    }

    /// The modifiers really held at `now`. `real(vk)` is the system's own answer for a key.
    pub fn mods(&self, now: u32, real: impl Fn(u32) -> bool) -> Mods {
        Mods {
            win: self.group_held(WIN_KEYS, now, &real),
            shift: self.group_held(SHIFT_KEYS, now, &real),
            alt: self.group_held(ALT_KEYS, now, &real),
            ctrl: self.group_held(CTRL_KEYS, now, &real),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const WIN: Mods = Mods { win: true, shift: false, alt: false, ctrl: false };
    const WIN_SHIFT: Mods = Mods { win: true, shift: true, alt: false, ctrl: false };

    #[test]
    fn windows_has_switch_move_and_the_agent_toggle() {
        let t = bindings();
        assert_eq!(t.len(), 9 + 9 + 1, "move_stay has no default key on Windows");
        assert_eq!(lookup(&t, 0x32, WIN).unwrap().args, ["switch", "2"]);
        assert_eq!(lookup(&t, 0x39, WIN_SHIFT).unwrap().args, ["move", "9"]);
        assert_eq!(lookup(&t, VK_OEM_3, WIN).unwrap().args, ["agent-workspace", "toggle"]);
    }

    #[test]
    fn only_exact_chords_match() {
        let t = bindings();
        assert!(lookup(&t, 0x31, Mods::default()).is_none(), "a bare 1 is the app's");
        assert!(lookup(&t, 0x31, Mods { ctrl: true, ..WIN }).is_none(), "Win+Ctrl+1 is not ours");
        assert!(lookup(&t, 0x30, WIN).is_none(), "workspace 0 does not exist");
        assert!(lookup(&t, 0x41, WIN).is_none(), "Win+A is the shell's");
    }

    #[test]
    fn chords_are_unique() {
        let t = bindings();
        for (i, a) in t.iter().enumerate() {
            for b in &t[i + 1..] {
                assert!(!(a.vk == b.vk && a.mods == b.mods), "{:?} twice", a.args);
            }
        }
    }

    #[test]
    fn the_spec_column_is_what_the_daemon_reads() {
        let (m, vk) = parse_chord("win+shift+{n}", Some(4)).unwrap();
        assert_eq!((m, vk), (WIN_SHIFT, 0x34));
        assert!(parse_chord("win+nonsense", None).is_none());
        assert!(parse_chord("", None).is_none());
        assert!(parse_chord("win+{n}", None).is_none(), "a digit chord needs a digit");
    }

    #[test]
    fn a_missed_key_up_does_not_leave_win_stuck() {
        // Win goes down at t=1000 and its key-up never arrives (Win+L, then unlock). Much later a plain "2"
        // is typed, and the system says Win is up: it must not count as Win+2, and the stale state is cleared.
        let m = ModState::new();
        m.event(VK_LWIN, true, 1000);
        let mods = m.mods(900_000, |_| false);
        assert!(!mods.win);
        assert!(lookup(&bindings(), 0x32, mods).is_none());
        // And it stays cleared: a second look, with the system still saying up, agrees.
        assert!(!m.mods(900_050, |_| false).win);
    }

    #[test]
    fn a_held_win_key_is_believed_while_the_system_agrees() {
        let m = ModState::new();
        m.event(VK_LWIN, true, 1000);
        assert!(m.mods(60_000, |k| k == VK_LWIN).win, "held for a minute, system says down");
        let mods = m.mods(60_001, |k| k == VK_LWIN);
        assert_eq!(lookup(&bindings(), 0x32, mods).unwrap().args, ["switch", "2"]);
    }

    #[test]
    fn a_chord_in_the_same_millisecond_is_believed_before_the_system_catches_up() {
        let m = ModState::new();
        m.event(VK_LWIN, true, 5000);
        assert!(m.mods(5002, |_| false).win, "down 2 ms ago, system not updated yet");
        assert!(!m.mods(5000 + RECENT_MS + 1, |_| false).win, "but not forever");
    }

    #[test]
    fn a_stuck_shift_or_ctrl_is_cleared_too_and_a_real_key_up_clears_it() {
        let m = ModState::new();
        m.event(0xA0, true, 10);
        m.event(0xA2, true, 10);
        let mods = m.mods(100_000, |_| false);
        assert!(!mods.shift && !mods.ctrl);
        m.event(VK_RWIN, true, 100_000);
        m.event(VK_RWIN, false, 100_200);
        assert!(!m.mods(100_300, |_| true).win, "a delivered key-up wins over a real state read");
    }

    #[test]
    fn reset_forgets_everything() {
        let m = ModState::new();
        m.event(VK_LWIN, true, 1000);
        m.reset();
        assert_eq!(m.mods(1001, |_| true), Mods::default());
    }
}
