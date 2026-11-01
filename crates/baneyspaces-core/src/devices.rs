//! Device and VM apps: simulators, emulators and virtual machines (`spec/devices.md`).
//!
//! `spec/devices.json` says which apps these are and what their windows are for. [`classify`]
//! turns what a platform knows about one window into a [`Decision`]; the workspace model then
//! keeps companions with their main window (`R-D2` to `R-D5`). The table is the same file the
//! macOS app embeds, so a rule cannot ship on one platform alone.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::OnceLock;

/// The table, as the spec file has it.
pub const DEVICES_JSON: &str = include_str!("../../../spec/devices.json");

/// What a window is for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    /// An application window: it has a workspace, a tile, a place in the switcher.
    #[default]
    Main,
    /// A toolbar, extended controls, a mini bar: it lives with the main window of its process and
    /// is never counted as a window of its own.
    Companion,
    /// Not tracked at all: BaneySpaces neither moves it nor counts it.
    Ignore,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct Match {
    #[serde(default)]
    pub bundle: Vec<String>,
    #[serde(default)]
    pub process: Vec<String>,
    #[serde(default)]
    pub class: Vec<String>,
    #[serde(default)]
    pub exe: Vec<String>,
    /// A process name pattern that counts only when its command line has this argument: the Android
    /// emulator's `qemu-system-*` is started with `-avd`, a plain QEMU never is.
    #[serde(default)]
    pub process_arg: BTreeMap<String, String>,
    /// A process name pattern that counts only for a window whose title starts with this.
    #[serde(default)]
    pub process_title: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct WindowRule {
    #[serde(default)]
    pub title_prefix: Option<String>,
    #[serde(default)]
    pub title_contains: Option<String>,
    #[serde(default)]
    pub title_is: Option<String>,
    #[serde(default)]
    pub title_empty: Option<bool>,
    /// Only for a standard (`true`) or a non-standard (`false`) window.
    #[serde(default)]
    pub standard: Option<bool>,
    /// Only on this platform.
    #[serde(default)]
    pub platform: Option<String>,
    /// `"sandbox_process"`: the platform applies `home` only to a process BaneySpaces' sandbox started.
    #[serde(default)]
    pub only_if: Option<String>,
    pub role: Role,
    /// `"agent"`: the window lives on the agent workspace (the sandbox view).
    #[serde(default)]
    pub home: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct Keys {
    /// `none` (host shortcuts still arrive), `tap` (the app takes system keys with an event tap),
    /// `hook` (a keyboard hook, Windows), `inhibit` (Wayland keyboard-shortcuts-inhibit).
    pub capture: String,
    #[serde(default)]
    pub release: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct App {
    pub id: String,
    pub label: String,
    pub kind: String,
    #[serde(rename = "match")]
    pub matches: BTreeMap<String, Match>,
    pub windows: Vec<WindowRule>,
    /// The app changes its own window's size (a device rotates, a guest changes resolution).
    #[serde(default)]
    pub resizes_itself: bool,
    /// Float it on a tiling compositor: its aspect ratio is fixed.
    #[serde(default)]
    pub float: bool,
    #[serde(default)]
    pub keys: BTreeMap<String, Keys>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Table {
    pub version: u32,
    pub apps: Vec<App>,
}

/// What a platform knows about one window.
#[derive(Clone, Debug, Default)]
pub struct Facts<'a> {
    /// `macos`, `linux` or `windows`.
    pub platform: &'a str,
    /// macOS bundle id.
    pub bundle: &'a str,
    /// The process's executable name (without a path).
    pub process: &'a str,
    /// Linux window class / app id.
    pub class: &'a str,
    /// Windows executable name.
    pub exe: &'a str,
    /// The process's command line arguments (empty when unknown).
    pub args: &'a [&'a str],
    pub title: &'a str,
    /// A standard application window (macOS: subrole AXStandardWindow). Compositor windows are.
    pub standard: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Decision {
    /// The table entry that matched; `None` for an app that is not a device app.
    pub app: Option<String>,
    pub role: Role,
    /// The window lives on the agent workspace whatever process opened it.
    pub agent_home: bool,
    pub resizes_itself: bool,
    pub float: bool,
    /// `agent_home` applies only to a process the sandbox started (R-D9).
    pub sandbox_only: bool,
}

impl Decision {
    fn plain(facts: &Facts) -> Self {
        Self {
            app: None,
            role: if facts.standard {
                Role::Main
            } else {
                Role::Ignore
            },
            agent_home: false,
            resizes_itself: false,
            float: false,
            sandbox_only: false,
        }
    }
}

/// An exact name, or a prefix with a trailing `*`; case does not matter.
pub fn name_matches(pattern: &str, name: &str) -> bool {
    if name.is_empty() {
        return false;
    }
    let (p, n) = (pattern.to_lowercase(), name.to_lowercase());
    match p.strip_suffix('*') {
        Some(prefix) => n.starts_with(prefix),
        None => p == n,
    }
}

impl Match {
    fn hits(&self, f: &Facts) -> bool {
        self.bundle
            .iter()
            .any(|p| p == f.bundle && !f.bundle.is_empty())
            || self.process.iter().any(|p| name_matches(p, f.process))
            || self.class.iter().any(|p| name_matches(p, f.class))
            || self.exe.iter().any(|p| name_matches(p, f.exe))
            || self
                .process_arg
                .iter()
                .any(|(p, arg)| name_matches(p, f.process) && f.args.iter().any(|a| a == arg))
            || self.process_title.iter().any(|(p, t)| {
                (name_matches(p, f.process) || name_matches(p, f.exe))
                    && f.title.starts_with(t.as_str())
            })
    }
}

impl WindowRule {
    fn hits(&self, f: &Facts) -> bool {
        let title = f.title;
        self.platform.as_deref().map_or(true, |p| p == f.platform)
            && self.standard.map_or(true, |s| s == f.standard)
            && self
            .title_prefix
            .as_deref()
            .map_or(true, |p| title.starts_with(p))
            && self
                .title_contains
                .as_deref()
                .map_or(true, |p| title.contains(p))
            && self.title_is.as_deref().map_or(true, |p| title == p)
            && self.title_empty.map_or(true, |e| title.is_empty() == e)
    }
}

impl Table {
    pub fn parse(text: &str) -> Result<Table, String> {
        let t: Table = serde_json::from_str(text).map_err(|e| format!("devices.json: {e}"))?;
        if t.version != 1 {
            return Err(format!(
                "devices.json: version {} is not understood",
                t.version
            ));
        }
        Ok(t)
    }

    /// The table that ships (`spec/devices.json`).
    pub fn builtin() -> &'static Table {
        static T: OnceLock<Table> = OnceLock::new();
        T.get_or_init(|| Table::parse(DEVICES_JSON).expect("spec/devices.json is valid"))
    }

    /// The device app a window belongs to, if any.
    pub fn app_of(&self, f: &Facts) -> Option<&App> {
        self.apps
            .iter()
            .find(|a| a.matches.get(f.platform).is_some_and(|m| m.hits(f)))
    }

    /// R-D1: the role of one window. First rule that hits wins. A window that is not a standard
    /// application window is never `main`.
    pub fn classify(&self, f: &Facts) -> Decision {
        let Some(app) = self.app_of(f) else {
            return Decision::plain(f);
        };
        let rule = app.windows.iter().find(|r| r.hits(f));
        let mut role = rule.map_or(if f.standard { Role::Main } else { Role::Ignore }, |r| {
            r.role
        });
        if role == Role::Main && !f.standard {
            role = Role::Ignore;
        }
        Decision {
            app: Some(app.id.clone()),
            role,
            agent_home: role == Role::Main && rule.and_then(|r| r.home.as_deref()) == Some("agent"),
            resizes_itself: app.resizes_itself,
            float: app.float,
            sandbox_only: rule.is_some_and(|r| r.only_if.as_deref() == Some("sandbox_process")),
        }
    }
}

/// Classify with the built-in table.
pub fn classify(f: &Facts) -> Decision {
    Table::builtin().classify(f)
}

/// R-D8: whether `pid` is a registered agent root or descends from one. `roots` maps pid to start
/// time; `start_of` and `parent_of` read the live process table. A root whose pid now has another
/// start time (the pid was reused) is no root. The walk is bounded, so a parent loop ends.
pub fn descends_from(roots: &BTreeMap<u32, u64>, pid: u32, start_of: impl Fn(u32) -> Option<u64>, parent_of: impl Fn(u32) -> Option<u32>) -> bool {
    let mut at = pid;
    for _ in 0..64 {
        if let Some(&want) = roots.get(&at) {
            if want == 0 || start_of(at) == Some(want) {
                return true;
            }
        }
        match parent_of(at) {
            Some(p) if p > 1 && p != at => at = p,
            _ => return false,
        }
    }
    false
}

/// Replays one `spec/conformance/devices/placement.json` case.
pub fn run_placement_case(case: &Value) -> Result<(), String> {
    let name = case["name"].as_str().unwrap_or("?");
    let table = |k: &str| -> BTreeMap<u32, u64> {
        case[k].as_object().into_iter().flatten().filter_map(|(p, v)| Some((p.parse().ok()?, v.as_u64()?))).collect()
    };
    let (mut roots, starts) = (table("roots"), table("starts"));
    // Descendants recorded while their parent lived count as roots of their own.
    roots.extend(table("recorded"));
    let parents: BTreeMap<u32, u32> = table("parents").into_iter().map(|(k, v)| (k, v as u32)).collect();
    let pid = case["pid"].as_u64().unwrap_or(0) as u32;
    let got = descends_from(&roots, pid, |p| starts.get(&p).copied(), |p| parents.get(&p).copied());
    match case["expect"].as_bool() {
        Some(want) if want == got => Ok(()),
        want => Err(format!("{name}: expected {want:?}, got {got}")),
    }
}

/// Replays one `spec/conformance/devices/classify.json` case.
pub fn run_classify_case(case: &Value) -> Result<(), String> {
    let name = case["name"].as_str().unwrap_or("?");
    let s = |k: &str| case["facts"][k].as_str().unwrap_or("").to_string();
    let (platform, bundle, process, class, exe, title) = (
        s("platform"),
        s("bundle"),
        s("process"),
        s("class"),
        s("exe"),
        s("title"),
    );
    let standard = case["facts"]["standard"].as_bool().unwrap_or(true);
    let args: Vec<String> = case["facts"]["args"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|a| a.as_str().map(String::from))
        .collect();
    let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
    let d = classify(&Facts {
        platform: &platform,
        bundle: &bundle,
        process: &process,
        class: &class,
        exe: &exe,
        args: &arg_refs,
        title: &title,
        standard,
    });
    let e = &case["expect"];
    let role = serde_json::to_value(d.role).unwrap();
    if let Some(want) = e.get("role") {
        if want != &role {
            return Err(format!("{name}: role: expected {want}, got {role}"));
        }
    }
    if let Some(want) = e.get("app") {
        let got = d
            .app
            .as_ref()
            .map_or(Value::Null, |a| Value::String(a.clone()));
        if want != &got {
            return Err(format!("{name}: app: expected {want}, got {got}"));
        }
    }
    for (key, got) in [
        ("agent_home", d.agent_home),
        ("resizes_itself", d.resizes_itself),
        ("float", d.float),
        ("sandbox_only", d.sandbox_only),
    ] {
        if let Some(want) = e.get(key).and_then(Value::as_bool) {
            if want != got {
                return Err(format!("{name}: {key}: expected {want}, got {got}"));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts<'a>(platform: &'a str, process: &'a str, title: &'a str) -> Facts<'a> {
        Facts {
            platform,
            process,
            title,
            standard: true,
            ..Default::default()
        }
    }

    #[test]
    fn the_shipped_table_parses_and_every_app_has_a_rule_and_a_match() {
        let t = Table::builtin();
        assert!(t.apps.len() >= 10);
        for a in &t.apps {
            assert!(!a.windows.is_empty(), "{} has no window rule", a.id);
            assert!(!a.matches.is_empty(), "{} matches nothing", a.id);
            for p in a.matches.keys().chain(a.keys.keys()) {
                assert!(
                    ["macos", "linux", "windows"].contains(&p.as_str()),
                    "{}: unknown platform {p}",
                    a.id
                );
            }
        }
        let ids: std::collections::BTreeSet<_> = t.apps.iter().map(|a| &a.id).collect();
        assert_eq!(ids.len(), t.apps.len(), "duplicate app id");
    }

    #[test]
    fn names_match_exactly_or_by_prefix_and_ignore_case() {
        assert!(name_matches("qemu-system-*", "qemu-system-aarch64"));
        assert!(name_matches("Emulator", "emulator"));
        assert!(!name_matches("emulator", "emulator64-crash"));
        assert!(!name_matches("qemu-system-*", ""));
        assert!(!name_matches("tart", "tartan"));
    }

    #[test]
    fn a_non_standard_window_is_never_main() {
        let mut f = facts("macos", "tart", "anything");
        f.standard = false;
        assert_eq!(classify(&f).role, Role::Ignore);
        let args = ["-avd", "Pixel_9"];
        let mut e = facts("macos", "qemu-system-aarch64", "");
        e.args = &args;
        e.standard = false;
        assert_eq!(
            classify(&e).role,
            Role::Companion,
            "a panel of the emulator travels with it"
        );
    }

    #[test]
    fn an_unknown_app_is_a_plain_window() {
        let d = classify(&facts("linux", "foot", "x"));
        assert_eq!((d.app, d.role), (None, Role::Main));
    }

    #[test]
    fn the_sandbox_view_is_pinned_to_the_agent_workspace() {
        let d = classify(&facts("macos", "tart", "bsx-s-ba0365d2"));
        assert!(d.agent_home && d.role == Role::Main);
        assert!(!classify(&facts("macos", "tart", "my-own-vm")).agent_home);
    }

    #[test]
    fn the_spec_cases_for_process_trees_pass() {
        let text = std::fs::read_to_string(crate::conformance::spec_dir().join("conformance/devices/placement.json")).unwrap();
        let cases: Vec<Value> = serde_json::from_str(&text).unwrap();
        assert!(cases.len() >= 6);
        let failures: Vec<_> = cases.iter().filter_map(|c| run_placement_case(c).err()).collect();
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }

    #[test]
    fn the_geometry_and_key_case_files_are_well_formed() {
        for (file, min) in [("geometry.json", 8), ("keys.json", 12)] {
            let text = std::fs::read_to_string(crate::conformance::spec_dir().join("conformance/devices").join(file)).unwrap();
            let cases: Vec<Value> = serde_json::from_str(&text).unwrap();
            assert!(cases.len() >= min, "{file}: {} cases", cases.len());
            assert!(cases.iter().all(|c| c["name"].is_string() && c["rules"].is_array() && c.get("expect").is_some()), "{file}");
        }
    }

    #[test]
    fn the_spec_cases_for_classification_pass() {
        let text = std::fs::read_to_string(
            crate::conformance::spec_dir().join("conformance/devices/classify.json"),
        )
        .unwrap();
        let cases: Vec<Value> = serde_json::from_str(&text).unwrap();
        assert!(
            cases.len() >= 12,
            "only {} classification cases",
            cases.len()
        );
        let failures: Vec<_> = cases
            .iter()
            .filter_map(|c| run_classify_case(c).err())
            .collect();
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }
}
