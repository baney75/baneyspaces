//! The Windows chords from `spec/keys.json`, and the match the keyboard hook runs on every key.
//!
//! Explorer owns Win+1 to Win+9, so `RegisterHotKey` fails for them. The daemon instead sees every
//! key in a `WH_KEYBOARD_LL` hook and swallows only the chords listed here. The hook callback has to
//! be fast, so the match is a small pure function over a pre-built table.

use baneyspaces_core::keymap;

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
}
