//! How BaneySpaces workspaces map onto Hyprland's (documented in platforms/linux/README.md).
//!
//! One shared pool: BaneySpaces workspace n is Hyprland workspace `n`, for n in 1 to 9. Hyprland
//! keeps a workspace on one monitor; when a display is to show workspace n, the daemon brings it to
//! that display (`workspace.move`) and focuses it. A workspace no display shows stays on whichever
//! monitor held it, out of sight. Everything else (workspace 10, `special:scratchpad`, named
//! workspaces) is outside the scheme and left alone. The agent workspace is the special workspace
//! `special:agent`.

pub const AGENT_SPECIAL: &str = "special:agent";
pub const AGENT_SPECIAL_NAME: &str = "agent";

/// The BaneySpaces workspace for a Hyprland workspace id and name, if it is one of the nine.
pub fn decode(id: i64, name: &str) -> Option<u8> {
    if name.starts_with("special:") || id < 0 {
        return None;
    }
    u8::try_from(id).ok().filter(|n| (1..=9).contains(n))
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
    fn the_nine_are_ours_and_nothing_else() {
        for n in 1..=9i64 {
            assert_eq!(decode(n, &n.to_string()), Some(n as u8));
        }
        for id in [0, 10, 11, 100, 101, 205, -1, -98] {
            assert_eq!(decode(id, &id.to_string()), None, "{id}");
        }
        assert_eq!(decode(-98, "special:agent"), None);
        assert_eq!(decode(3, "special:scratchpad"), None);
    }

    #[test]
    fn quoting() {
        assert_eq!(lua_str("a\"b\\c\nd"), "\"a\\\"b\\\\c\\nd\"");
        assert_eq!(sh_quote("it's"), "'it'\\''s'");
    }
}
