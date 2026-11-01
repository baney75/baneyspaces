//! How BaneySpaces workspaces map onto Hyprland workspaces (documented in platforms/linux/README.md).
//!
//! Monitor slot 0 owns Hyprland workspaces 1 to 9. Slot s >= 1 owns 100*s + 1 to 100*s + 9
//! (101-109, 201-209, ...). Each id is pinned to its monitor with a workspace rule, so a window
//! sent to 105 lands on the second monitor even while you are on the first. Everything else
//! (workspace 10, `special:scratchpad`, named workspaces) is outside the scheme and left alone.
//! The agent workspace is the special workspace `special:agent`.

pub const AGENT_SPECIAL: &str = "special:agent";
pub const AGENT_SPECIAL_NAME: &str = "agent";

pub fn ws_id(slot: u32, n: u8) -> i64 {
    if slot == 0 {
        n as i64
    } else {
        100 * slot as i64 + n as i64
    }
}

/// `(slot, n)` for a Hyprland workspace id inside the scheme.
pub fn decode_id(id: i64) -> Option<(u32, u8)> {
    if (1..=9).contains(&id) {
        return Some((0, id as u8));
    }
    if id > 100 && (1..=9).contains(&(id % 100)) {
        return Some(((id / 100) as u32, (id % 100) as u8));
    }
    None
}

/// Decodes a Hyprland workspace by id and name. Named workspaces (negative ids) and specials are outside the scheme.
pub fn decode(id: i64, name: &str) -> Option<(u32, u8)> {
    if name.starts_with("special:") || id < 0 {
        return None;
    }
    decode_id(id)
}

/// Escapes text for a double-quoted Lua string.
pub fn lua_str(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '\\' => o.push_str("\\\\"),
            '"' => o.push_str("\\\""),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\0' => {}
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

/// Single-quotes a word for `sh -c`.
pub fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_round_trip() {
        for slot in 0..4u32 {
            for n in 1..=9u8 {
                assert_eq!(decode_id(ws_id(slot, n)), Some((slot, n)));
            }
        }
    }

    #[test]
    fn ids_outside_the_scheme_are_left_alone() {
        for id in [0, 10, 11, 99, 100, 110, 150, -1, -98] {
            assert_eq!(decode_id(id), None, "{id}");
        }
        assert_eq!(decode(-98, "special:agent"), None);
        assert_eq!(decode(3, "special:scratchpad"), None);
        assert_eq!(decode(10, "10"), None);
    }

    #[test]
    fn quoting() {
        assert_eq!(lua_str("a\"b\\c\nd"), "\"a\\\"b\\\\c\\nd\"");
        assert_eq!(sh_quote("it's"), "'it'\\''s'");
    }
}
