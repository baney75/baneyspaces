//! Chords as config spells them (`spec/config.md` Keys, `spec/keys.json` `chords`): lowercase
//! modifiers joined with `+`, then one key name. `mod` is the configured `keys.mod`; `cmd`, `super`
//! and `win` are one physical key, the logo key.

use serde_json::Value;
use std::sync::OnceLock;

/// The platforms the shared config runs on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Platform {
    Macos,
    Linux,
    Windows,
}

impl Platform {
    pub fn name(self) -> &'static str {
        match self {
            Platform::Macos => "macos",
            Platform::Linux => "linux",
            Platform::Windows => "windows",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "macos" => Some(Platform::Macos),
            "linux" => Some(Platform::Linux),
            "windows" => Some(Platform::Windows),
            _ => None,
        }
    }

    /// What the logo key is called here.
    pub fn logo(self) -> &'static str {
        match self {
            Platform::Macos => "cmd",
            Platform::Linux => "super",
            Platform::Windows => "win",
        }
    }
}

struct ChordSpec {
    keys: Vec<String>,
    mods: Vec<String>,
    logo: Vec<String>,
    hold_ms: u64,
    value: Value,
}

fn spec() -> &'static ChordSpec {
    static S: OnceLock<ChordSpec> = OnceLock::new();
    S.get_or_init(|| {
        let v = crate::keymap::keys();
        let list = |k: &str| {
            v["chords"][k]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default()
        };
        ChordSpec {
            keys: list("keys"),
            mods: list("modifiers"),
            logo: list("logo"),
            hold_ms: v["chords"]["recovery"]["hold_ms"].as_u64().unwrap_or(2000),
            value: v["chords"].clone(),
        }
    })
}

/// Every key name a chord may end in (`spec/keys.json` `chords.keys`).
pub fn key_names() -> &'static [String] {
    &spec().keys
}

/// The modifier spellings a chord may start with.
pub fn modifier_names() -> &'static [String] {
    &spec().mods
}

/// The values `keys.mod` may take on a platform, and its default there.
pub fn mod_values(p: Platform) -> (Vec<String>, String) {
    let m = &spec().value["mod"][p.name()];
    (
        m["allowed"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default(),
        m["default"].as_str().unwrap_or("super").to_string(),
    )
}

/// How long the recovery chord is held, in ms.
pub fn recovery_hold_ms() -> u64 {
    spec().hold_ms
}

/// A chord with `mod` already resolved: which modifiers, which key.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Chord {
    pub logo: bool,
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub key: String,
}

impl Chord {
    pub fn has_modifier(&self) -> bool {
        self.logo || self.ctrl || self.alt || self.shift
    }

    /// The chord in the platform's own spelling, modifiers in a fixed order.
    pub fn canonical(&self, p: Platform) -> String {
        let mut parts: Vec<&str> = vec![];
        if self.logo {
            parts.push(p.logo());
        }
        if self.ctrl {
            parts.push("ctrl");
        }
        if self.alt {
            parts.push("alt");
        }
        if self.shift {
            parts.push("shift");
        }
        parts.push(&self.key);
        parts.join("+")
    }

    /// The recovery chord of a platform: the logo key, Shift and Escape.
    pub fn recovery() -> Chord {
        Chord {
            logo: true,
            ctrl: false,
            alt: false,
            shift: true,
            key: "escape".into(),
        }
    }
}

/// Reads a chord. `modifier` is the configured `keys.mod` (one of `cmd`, `super`, `win`, `ctrl`,
/// `alt`). The error is the reason, written so an agent can fix the spelling.
pub fn parse(spelling: &str, modifier: &str) -> Result<Chord, String> {
    if spelling.is_empty() {
        return Err("a chord cannot be empty".into());
    }
    if spelling != spelling.to_lowercase() {
        return Err(format!(
            "chords are lowercase: write {:?}",
            spelling.to_lowercase()
        ));
    }
    if spelling.chars().any(char::is_whitespace) {
        return Err(
            "a chord has no spaces: join modifiers and the key with +, as in \"mod+shift+1\""
                .into(),
        );
    }
    let (mods, key) = match spelling.rsplit_once('+') {
        // A trailing "+" would be the plus key itself; it is spelled "plus".
        Some((_, "")) => {
            return Err("a chord ends in a key name; the + key is spelled \"plus\"".into())
        }
        Some((m, k)) => (Some(m), k),
        None => (None, spelling),
    };
    if !key_names().iter().any(|k| k == key) {
        let hint = if modifier_names().iter().any(|m| m == key) {
            format!(" ({key:?} is a modifier; a chord ends in a key)")
        } else {
            String::new()
        };
        return Err(format!(
            "unknown key {key:?}{hint}; key names are listed in spec/keys.json under chords.keys"
        ));
    }
    let mut c = Chord {
        logo: false,
        ctrl: false,
        alt: false,
        shift: false,
        key: key.to_string(),
    };
    for m in mods.into_iter().flat_map(|m| m.split('+')) {
        if m.is_empty() {
            return Err("empty modifier (a doubled +)".into());
        }
        let resolved = if m == "mod" { modifier } else { m };
        let slot = if spec().logo.iter().any(|l| l == resolved) {
            &mut c.logo
        } else {
            match resolved {
                "ctrl" => &mut c.ctrl,
                "alt" => &mut c.alt,
                "shift" => &mut c.shift,
                _ => {
                    return Err(format!(
                        "unknown modifier {m:?}; use mod, cmd, super, win, ctrl, alt or shift"
                    ))
                }
            }
        };
        if *slot {
            return Err(format!(
                "modifier {m:?} appears twice (mod is {modifier:?} here)"
            ));
        }
        *slot = true;
    }
    Ok(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mod_resolves_and_logo_spellings_are_one_key() {
        assert_eq!(
            parse("mod+1", "super").unwrap(),
            parse("super+1", "super").unwrap()
        );
        assert_eq!(
            parse("cmd+1", "super").unwrap(),
            parse("win+1", "super").unwrap()
        );
        assert_ne!(
            parse("mod+1", "alt").unwrap(),
            parse("super+1", "alt").unwrap()
        );
        assert_eq!(
            parse("shift+mod+1", "super")
                .unwrap()
                .canonical(Platform::Linux),
            "super+shift+1"
        );
        assert_eq!(
            parse("mod+shift+1", "cmd")
                .unwrap()
                .canonical(Platform::Macos),
            "cmd+shift+1"
        );
    }

    #[test]
    fn spelling_errors_say_how_to_fix_them() {
        assert!(parse("Mod+1", "super").unwrap_err().contains("lowercase"));
        assert!(parse("mod + 1", "super").unwrap_err().contains("no spaces"));
        assert!(parse("mod+", "super").unwrap_err().contains("plus"));
        assert!(parse("mod+shift", "super")
            .unwrap_err()
            .contains("is a modifier"));
        assert!(parse("mod+enter", "super")
            .unwrap_err()
            .contains("unknown key"));
        assert!(parse("hyper+1", "super")
            .unwrap_err()
            .contains("unknown modifier"));
        assert!(parse("mod+super+1", "super").unwrap_err().contains("twice"));
        assert!(parse("mod++1", "super").unwrap_err().contains("doubled"));
        assert!(parse("", "super").is_err());
    }

    #[test]
    fn the_recovery_chord_is_logo_shift_escape_on_every_platform() {
        for p in [Platform::Macos, Platform::Linux, Platform::Windows] {
            let spelled = spec().value["recovery"][p.name()]
                .as_str()
                .unwrap()
                .to_string();
            assert_eq!(
                parse(&spelled, "super").unwrap(),
                Chord::recovery(),
                "{}",
                p.name()
            );
            assert_eq!(Chord::recovery().canonical(p), spelled);
        }
        assert_eq!(recovery_hold_ms(), 2000);
    }

    #[test]
    fn keys_json_names_are_unique_and_lowercase() {
        let mut k = key_names().to_vec();
        assert!(k.len() > 60);
        assert!(k.iter().all(|n| *n == n.to_lowercase() && !n.contains('+')));
        k.sort();
        k.dedup();
        assert_eq!(k.len(), key_names().len());
    }
}
