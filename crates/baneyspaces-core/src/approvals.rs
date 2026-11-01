//! Executable configuration waits for a click (`spec/config.md`, Who may change what).
//!
//! A hook, and a key binding whose action runs a command (`exec ...`, `agent run ...`) or changes
//! the configuration (`config ...`, `theme ...`, `set ...`), is **pending** and inert until the
//! person approves it in Settings. An approval is per entry, keyed by a hash of (path, value), so
//! any change to the value makes the entry pending again. Approvals are kept in
//! `approvals.json`, outside `config.toml`, in the state directory (mode 0600), and only the
//! Settings UI writes the file, on a real click. No CLI, MCP or socket operation approves.

use crate::action::Action;
use crate::config::{Binding, Effective};
use crate::config_schema::path_string;
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;
use std::path::Path;

/// One executable setting that is waiting for approval, or approved.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pending {
    /// The hash of (path, value): what an approval is keyed by.
    pub id: String,
    /// `hooks.on_switch`, `keys.bindings."mod+h"`, `keys.modes.resize.h`.
    pub path: String,
    pub segments: Vec<String>,
    pub value: String,
    /// `hook`, `exec binding` or `config binding`.
    pub kind: &'static str,
}

impl Pending {
    pub fn to_json(&self, written_by: Option<&str>) -> Value {
        json!({ "id": self.id, "path": self.path, "value": self.value, "kind": self.kind, "written_by_hint": written_by })
    }
}

/// SHA-256 as lowercase hex.
pub fn sha256_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                chunk[4 * i],
                chunk[4 * i + 1],
                chunk[4 * i + 2],
                chunk[4 * i + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let t1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (x, y) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *x = x.wrapping_add(y);
        }
    }
    h.iter().map(|x| format!("{x:08x}")).collect()
}

/// The id an approval is keyed by.
pub fn entry_id(path: &str, value: &str) -> String {
    sha256_hex(format!("{path}\0{value}").as_bytes()).to_string()
}

/// Whether an action changes the machine or the configuration, and so needs a click.
pub fn action_kind(a: &Action) -> Option<&'static str> {
    match a {
        Action::Exec(_) => Some("exec binding"),
        Action::Cli(w) => match (w[0].as_str(), w.get(1).map(String::as_str)) {
            ("config" | "theme" | "set", _) => Some("config binding"),
            ("agent", Some("run")) => Some("exec binding"),
            _ => None,
        },
        _ => None,
    }
}

fn entry(segments: Vec<String>, value: &str, kind: &'static str) -> Pending {
    let path = path_string(&segments);
    Pending {
        id: entry_id(&path, value),
        path,
        segments,
        value: value.to_string(),
        kind,
    }
}

/// Every executable setting in the effective config.
pub fn executable_entries(eff: &Effective) -> Vec<Pending> {
    let mut out = vec![];
    for h in ["on_switch", "on_window_open"] {
        if let Some(v) = eff.doc["hooks"][h]
            .as_str()
            .filter(|s| !s.trim().is_empty())
        {
            out.push(entry(vec!["hooks".into(), h.into()], v, "hook"));
        }
    }
    let mut add = |prefix: Vec<String>, b: &Binding| {
        if let Some(kind) = action_kind(&b.action) {
            let mut segs = prefix;
            segs.push(b.spelling.clone());
            out.push(entry(segs, &b.text, kind));
        }
    };
    for b in &eff.bindings {
        add(vec!["keys".into(), "bindings".into()], b);
    }
    for (m, bs) in &eff.modes {
        for b in bs {
            add(vec!["keys".into(), "modes".into(), m.clone()], b);
        }
    }
    out
}

/// The config that runs: executable entries that are not approved are taken out. Returns it with
/// the entries that are waiting.
pub fn activate(eff: &Effective, approved: &BTreeSet<String>) -> (Effective, Vec<Pending>) {
    let all = executable_entries(eff);
    let waiting: Vec<Pending> = all
        .into_iter()
        .filter(|p| !approved.contains(&p.id))
        .collect();
    if waiting.is_empty() {
        return (eff.clone(), waiting);
    }
    let mut a = eff.clone();
    let pending = |segs: &[String]| waiting.iter().any(|p| p.segments == segs);
    for h in ["on_switch", "on_window_open"] {
        if pending(&["hooks".to_string(), h.to_string()]) {
            a.doc["hooks"][h] = json!("");
        }
    }
    let keep = |prefix: &[String], b: &Binding| {
        let mut segs = prefix.to_vec();
        segs.push(b.spelling.clone());
        !pending(&segs)
    };
    let top = vec!["keys".to_string(), "bindings".to_string()];
    a.bindings.retain(|b| keep(&top, b));
    for (m, bs) in a.modes.iter_mut() {
        let prefix = vec!["keys".to_string(), "modes".to_string(), m.clone()];
        bs.retain(|b| keep(&prefix, b));
    }
    a.doc["keys"]["bindings"] = Value::Object(
        a.bindings
            .iter()
            .map(|b| (b.spelling.clone(), json!(b.text)))
            .collect(),
    );
    a.doc["keys"]["modes"] = Value::Object(
        a.modes
            .iter()
            .map(|(m, bs)| {
                (
                    m.clone(),
                    Value::Object(
                        bs.iter()
                            .map(|b| (b.spelling.clone(), json!(b.text)))
                            .collect::<Map<_, _>>(),
                    ),
                )
            })
            .collect(),
    );
    (a, waiting)
}

/// The ids approved in `approvals.json`. A file that is missing or damaged approves nothing.
pub fn load(path: &Path) -> BTreeSet<String> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| {
            v["approved"]
                .as_object()
                .map(|o| o.keys().cloned().collect())
        })
        .unwrap_or_default()
}

/// Records an approval. This is the Settings UI's write (and the test-only Settings operation's):
/// nothing in the CLI, MCP or control socket calls it.
pub fn approve(path: &Path, entry_path: &str, value: &str, time: &str) -> std::io::Result<String> {
    let mut doc: Value = std::fs::read_to_string(path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_else(|| json!({ "format": 1, "approved": {} }));
    let id = entry_id(entry_path, value);
    if !doc["approved"].is_object() {
        doc["approved"] = json!({});
    }
    doc["approved"][&id] = json!({ "path": entry_path, "value": value, "time": time });
    // Keep the newest 500.
    if let Some(o) = doc["approved"].as_object_mut() {
        if o.len() > 500 {
            let mut keys: Vec<(String, String)> = o
                .iter()
                .map(|(k, v)| (v["time"].as_str().unwrap_or("").to_string(), k.clone()))
                .collect();
            keys.sort();
            for (_, k) in keys.iter().take(o.len() - 500) {
                o.remove(k);
            }
        }
    }
    write_private(
        path,
        serde_json::to_string_pretty(&doc)
            .unwrap_or_default()
            .as_bytes(),
    )?;
    Ok(id)
}

/// A file only the user may read or write.
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    #[cfg(unix)]
    use std::os::unix::fs::OpenOptionsExt;
    let dir = path
        .parent()
        .ok_or_else(|| std::io::Error::other("no parent directory"))?;
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".approvals.{}.tmp", std::process::id()));
    let mut o = std::fs::OpenOptions::new();
    o.write(true).create(true).truncate(true);
    #[cfg(unix)]
    o.mode(0o600);
    let mut f = o.open(&tmp)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    std::fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chord::Platform;
    use crate::config::{validate, Env, Themes};

    fn eff(doc: Value) -> Effective {
        validate(&doc, &Env::new(Platform::Linux), &Themes::new())
            .effective
            .expect("valid")
    }

    #[test]
    fn sha256_matches_the_known_answers() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex(&[b'a'; 1000]),
            "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
        );
    }

    #[test]
    fn only_executable_entries_are_pending() {
        let e = eff(json!({
            "keys": { "bindings": { "mod+h": "exec foot", "mod+j": "move 2", "mod+k": "config set theme.name minimal", "mod+l": "theme set minimal", "mod+y": "agent run -- sh -c 'x'", "mod+u": "overview", "mod+n": "mode m" }, "modes": { "m": { "x": "exec true", "y": "switch 2" } } },
            "hooks": { "on_switch": "echo hi", "on_window_open": "" },
            "animation": { "speed": 0.5 }, "theme": { "name": "minimal" }
        }));
        let (active, waiting) = activate(&e, &BTreeSet::new());
        let paths: Vec<&str> = waiting.iter().map(|p| p.path.as_str()).collect();
        for p in [
            "hooks.on_switch",
            "keys.bindings.\"mod+h\"",
            "keys.bindings.\"mod+k\"",
            "keys.bindings.\"mod+l\"",
            "keys.bindings.\"mod+y\"",
            "keys.modes.m.x",
        ] {
            assert!(paths.contains(&p), "{p} missing from {paths:?}");
        }
        assert_eq!(waiting.len(), 6, "{paths:?}");
        // They are inert; everything else runs.
        assert_eq!(active.doc["hooks"]["on_switch"], "");
        assert!(active
            .bindings
            .iter()
            .all(|b| !["mod+h", "mod+k", "mod+l", "mod+y"].contains(&b.spelling.as_str())));
        assert!(
            active.bindings.iter().any(|b| b.spelling == "mod+j")
                && active.bindings.iter().any(|b| b.spelling == "mod+3")
        );
        assert!(
            active.modes["m"].iter().any(|b| b.spelling == "y")
                && active.modes["m"].iter().all(|b| b.spelling != "x")
        );
        assert_eq!(active.doc["animation"]["speed"], 0.5);
        // The configured document still shows them.
        assert_eq!(e.doc["keys"]["bindings"]["mod+h"], "exec foot");
    }

    #[test]
    fn an_approval_is_per_entry_and_a_changed_value_is_pending_again() {
        let e = eff(
            json!({ "keys": { "bindings": { "mod+h": "exec foot" } }, "hooks": { "on_switch": "echo a" } }),
        );
        let waiting = activate(&e, &BTreeSet::new()).1;
        let h = waiting
            .iter()
            .find(|p| p.path == "keys.bindings.\"mod+h\"")
            .unwrap();
        let mut ok = BTreeSet::new();
        ok.insert(h.id.clone());
        let (a, w) = activate(&e, &ok);
        assert_eq!(w.len(), 1, "the hook is still waiting");
        assert!(a.bindings.iter().any(|b| b.spelling == "mod+h"));
        assert_eq!(a.doc["hooks"]["on_switch"], "");
        // The same path with another value is another entry.
        let e2 = eff(json!({ "keys": { "bindings": { "mod+h": "exec foot -e sh" } } }));
        assert_eq!(activate(&e2, &ok).1.len(), 1);
        // The same value on another path is another entry.
        let e3 = eff(json!({ "keys": { "bindings": { "mod+g": "exec foot" } } }));
        assert_eq!(activate(&e3, &ok).1.len(), 1);
        assert_ne!(entry_id("a", "b"), entry_id("ab", ""));
    }

    #[test]
    fn the_file_is_private_and_a_damaged_one_approves_nothing() {
        let d = std::env::temp_dir().join(format!("bs-appr-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let f = d.join("approvals.json");
        assert!(load(&f).is_empty());
        let id = approve(&f, "hooks.on_switch", "echo a", "2026-11-01T00:00:00Z").unwrap();
        assert!(load(&f).contains(&id));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&f).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        std::fs::write(&f, "{not json").unwrap();
        assert!(load(&f).is_empty());
        let _ = std::fs::remove_dir_all(&d);
    }
}
