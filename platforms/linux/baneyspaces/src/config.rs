//! `~/.config/baneyspaces/config.toml`, read with the paths and defaults of `spec/config.md`.
//!
//! This is the small loader part 2 ships with: it reads the file (and writes one key at a time with `toml_edit`, so
//! comments and order survive) but does not validate a whole document, keep history or know the `keys` table. Those
//! belong to the shared core's config module. A known key with a bad value falls back to its default and is reported in
//! `errors`; unknown keys are ignored. The shell plugin sees the settings under the short names in `internal`.

use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use toml_edit::{value as tv, DocumentMut, Item};

#[derive(Clone, Copy, Debug)]
pub enum Kind {
    Bool,
    Enum(&'static [&'static str]),
    Int(i64, i64),
    Float(f64, f64),
    /// Free text, at most 64 characters.
    Str,
}

pub struct Key {
    /// The path in config.toml (spec/config.md).
    pub path: &'static str,
    /// Where the shell plugin finds it in the snapshot: `section.name`.
    pub internal: &'static str,
    pub kind: Kind,
    pub default: &'static str,
    pub help: &'static str,
    /// In spec/config.md. The rest are Linux additions the schema owner should take in.
    pub spec: bool,
}

const fn k(path: &'static str, internal: &'static str, kind: Kind, default: &'static str, spec: bool, help: &'static str) -> Key {
    Key { path, internal, kind, default, help, spec }
}

const PRESETS: &[&str] = &["baneyspaces", "omarchy", "snappy", "smooth", "off"];

/// Every key, in the order Settings shows them.
pub const KEYS: &[Key] = &[
    k("behavior.dock.enabled", "dock.enabled", Kind::Bool, "true", true, "Show the Workspace Dock."),
    k("behavior.dock.edge", "dock.edge", Kind::Enum(&["bottom", "left", "right"]), "bottom", true, "Which edge the dock comes from (Linux draws the bottom one so far)."),
    k("behavior.dock.reveal_ms", "dock.edge_delay_ms", Kind::Int(0, 1000), "0", true, "How long the pointer rests on the edge before the dock comes up."),
    k("behavior.dock.hide_ms", "dock.hide_ms", Kind::Int(0, 5000), "400", true, "How long the pointer is off the dock before it goes down."),
    k("behavior.dock.auto_hide", "dock.auto_hide", Kind::Bool, "true", false, "Hide the dock until the pointer rests on the edge; false keeps it up and reserves its space."),
    k("behavior.dock.size", "dock.size", Kind::Enum(&["small", "medium", "large"]), "medium", false, "Size of the tiles."),
    k("behavior.dock.in_fullscreen", "dock.in_fullscreen", Kind::Bool, "false", false, "Let the dock come up over a full-screen window."),
    k("behavior.dock.badges", "dock.badges", Kind::Bool, "true", false, "Show agent status on app icons."),
    k("behavior.switcher.enabled", "switcher.enabled", Kind::Bool, "true", false, "Alt+Tab switches across every workspace."),
    k("behavior.switcher.mode", "switcher.items", Kind::Enum(&["windows", "apps"]), "windows", true, "Step through windows, or through apps (their last window)."),
    k("behavior.switcher.hold_ms", "switcher.hold_ms", Kind::Int(0, 2000), "120", true, "The Mac's hold-Tab delay (not used on Linux)."),
    k("behavior.launcher.enabled", "launcher.enabled", Kind::Bool, "true", false, "Super+Space opens the BaneySpaces launcher."),
    k("behavior.launcher.files", "launcher.files", Kind::Bool, "true", false, "Search files and folders in your home folder."),
    k("behavior.launcher.install", "launcher.install", Kind::Bool, "true", false, "Offer to install and remove apps (omarchy pkg)."),
    k("behavior.launcher.search_engine", "launcher.search_engine", Kind::Str, "ddg", false, "Bang trigger of the engine a plain search goes to."),
    k("behavior.launcher.agent", "launcher.agent", Kind::Str, "claude", false, "Bang trigger of the agent a leading ? asks."),
    k("behavior.overview.enabled", "overview.enabled", Kind::Bool, "true", false, "Super+Tab shows all nine workspaces."),
    k("behavior.overview.previews", "overview.previews", Kind::Enum(&["live", "icons"]), "live", true, "Window previews (a capture where the compositor gives one) or icons."),
    k("behavior.overview.layout", "overview.layout", Kind::Enum(&["adaptive", "grid"]), "adaptive", true, "Linux draws the 3 x 3 grid for both so far."),
    k("behavior.overview.empty", "overview.empty", Kind::Enum(&["compact", "full", "hidden"]), "compact", true, "Linux draws every workspace the same size so far."),
    k("behavior.follow_focus", "behavior.follow_focus", Kind::Bool, "true", true, "Switch to a window's workspace when you activate it yourself (always on so far)."),
    k("behavior.new_window", "behavior.new_window", Kind::Enum(&["current", "app"]), "current", true, "Where a new window lands (current only so far)."),
    k("theme.name", "appearance.theme", Kind::Enum(&["baneyspaces", "omarchy", "minimal"]), "omarchy", true, "Shape, type and motion of every panel (spec/themes.md)."),
    k("theme.palette", "appearance.palette", Kind::Str, "auto", true, "`auto` follows the live Omarchy theme, or the name of a palette (spec/palettes.json)."),
    k("animation.preset", "motion.preset", Kind::Enum(PRESETS), "baneyspaces", true, "baneyspaces | omarchy | snappy | smooth | off."),
    k("animation.speed", "motion.speed", Kind::Float(0.0, 4.0), "1.0", true, "Multiplies every duration; 0 is off."),
    k("animation.respect_reduce_motion", "motion.respect_reduce", Kind::Bool, "true", true, "Instant when the desktop asks for reduced motion."),
    k("animation.workspace.style", "motion.workspace_style", Kind::Enum(&["off", "fade", "slide"]), "off", true, "Workspace switches are instant (Omarchy's choice too); fade or slide turn Hyprland's animation on."),
    k("animation.dock.in.duration_ms", "motion.dock_in_ms", Kind::Int(-1, 1000), "-1", true, "Dock slide-in time; -1 uses the preset."),
    k("animation.dock.out.duration_ms", "motion.dock_out_ms", Kind::Int(-1, 1000), "-1", true, "Dock slide-out time; -1 uses the preset."),
    k("animation.list.in.duration_ms", "motion.list_in_ms", Kind::Int(-1, 1000), "-1", true, "List and panel in time; -1 uses the preset."),
    k("animation.list.out.duration_ms", "motion.list_out_ms", Kind::Int(-1, 1000), "-1", true, "List and panel out time; -1 uses the preset."),
    k("animation.row.duration_ms", "motion.row_ms", Kind::Int(-1, 1000), "-1", true, "Row hover time; -1 uses the preset."),
];

pub fn find(path: &str) -> Option<&'static Key> {
    KEYS.iter().find(|k| k.path == path)
}

fn parse_default(key: &Key) -> Value {
    match key.kind {
        Kind::Bool => json!(key.default == "true"),
        Kind::Int(..) => json!(key.default.parse::<i64>().unwrap_or(0)),
        Kind::Float(..) => json!(key.default.parse::<f64>().unwrap_or(0.0)),
        Kind::Enum(_) | Kind::Str => json!(key.default),
    }
}

/// `raw` (text from the CLI or a TOML value) as a value of the key's kind.
pub fn coerce(key: &Key, raw: &Value) -> Result<Value, String> {
    let text = match raw {
        Value::String(s) => s.trim().to_string(),
        other => other.to_string(),
    };
    match key.kind {
        Kind::Bool => match text.to_lowercase().as_str() {
            "true" | "on" | "yes" | "1" => Ok(json!(true)),
            "false" | "off" | "no" | "0" => Ok(json!(false)),
            _ => Err(format!("{} takes true or false", key.path)),
        },
        Kind::Enum(opts) => opts
            .iter()
            .find(|o| o.eq_ignore_ascii_case(&text))
            .map(|o| json!(o))
            .ok_or_else(|| format!("{} takes one of: {}", key.path, opts.join(", "))),
        Kind::Int(lo, hi) => text.parse::<i64>().ok().filter(|n| (lo..=hi).contains(n)).map(|n| json!(n)).ok_or_else(|| format!("{} takes a whole number from {lo} to {hi}", key.path)),
        Kind::Float(lo, hi) => text.parse::<f64>().ok().filter(|n| n.is_finite() && (lo..=hi).contains(n)).map(|n| json!(n)).ok_or_else(|| format!("{} takes a number from {lo} to {hi}", key.path)),
        Kind::Str => {
            if text.chars().count() > 64 || text.chars().any(char::is_control) {
                return Err(format!("{} takes short plain text", key.path));
            }
            if key.path == "theme.palette" && text != "auto" && !palette_names().contains(&text) {
                return Err(format!("theme.palette takes auto or one of: {}", palette_names().join(", ")));
            }
            Ok(json!(text))
        }
    }
}

/// The palettes of spec/palettes.json (the file the shell plugin reads too).
pub fn palette_names() -> Vec<String> {
    static NAMES: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();
    NAMES
        .get_or_init(|| {
            let v: Value = serde_json::from_str(include_str!("../../../../spec/palettes.json")).expect("spec/palettes.json is valid JSON");
            v["palettes"].as_object().map(|m| m.keys().cloned().collect()).unwrap_or_default()
        })
        .clone()
}

pub fn is_hex_color(s: &str) -> bool {
    let h = s.strip_prefix('#').unwrap_or("");
    matches!(h.len(), 3 | 6 | 8) && h.chars().all(|c| c.is_ascii_hexdigit())
}

/// Is `path` (below `theme.override.`) a token themes.json defines? Returns what kind of value it takes.
fn override_token(path: &str) -> Option<Value> {
    let v: Value = serde_json::from_str(include_str!("../../../../spec/themes.json")).ok()?;
    let mut cur = &v["themes"]["omarchy"];
    for part in path.strip_prefix("theme.override.")?.split('.') {
        cur = cur.get(part)?;
    }
    (!cur.is_object() && !cur.is_array() && !cur.is_null()).then(|| cur.clone())
}

/// What went wrong with a change: `invalid_args` for a key or value that is not allowed, `config_invalid` for the file.
#[derive(Debug)]
pub struct CfgError {
    pub code: &'static str,
    pub message: String,
}

fn bad(m: impl Into<String>) -> CfgError {
    CfgError { code: "invalid_args", message: m.into() }
}

fn invalid(m: impl Into<String>) -> CfgError {
    CfgError { code: "config_invalid", message: m.into() }
}

/// The limits for a `theme.override` token, by what it is: times 0 to 1000 ms (spec/config.md), opacity 0 to 1, radius and
/// borders and spacing and sizes in sane points, scale and lift near 1.
fn override_range(path: &str) -> (f64, f64) {
    let p = path.strip_prefix("theme.override.").unwrap_or(path);
    if p.ends_with("_ms") {
        (0.0, 1000.0)
    } else if p.ends_with("opacity") {
        (0.0, 1.0)
    } else if p.starts_with("radius.") {
        (0.0, 64.0)
    } else if p == "border.width" || p == "border.focused_width" {
        (0.0, 16.0)
    } else if p == "space.tile" {
        (16.0, 200.0)
    } else if p.starts_with("space.") {
        (0.0, 100.0)
    } else if p == "font.size" {
        (6.0, 48.0)
    } else if p == "motion.scale_from" {
        (0.5, 1.0)
    } else if p == "motion.lift" {
        (1.0, 1.5)
    } else {
        (-1000.0, 1000.0)
    }
}

/// Is `value` an allowed value for the override token `path`? (`sample` is what themes.json has there.)
fn override_check(path: &str, sample: &Value, value: &Value) -> Result<(), String> {
    match (sample, value) {
        (Value::Bool(_), Value::Bool(_)) => Ok(()),
        (Value::Number(_), Value::Number(n)) => {
            let (lo, hi) = override_range(path);
            let f = n.as_f64().unwrap_or(f64::NAN);
            if f.is_finite() && f >= lo && f <= hi { Ok(()) } else { Err(format!("{path} takes a number from {lo} to {hi}")) }
        }
        (Value::String(_), Value::String(t)) => {
            let leaf = path.rsplit('.').next().unwrap_or("");
            let ok = match leaf {
                "indicator" => ["dot", "bar", "number-block"].contains(&t.as_str()),
                "weight" => ["regular", "medium"].contains(&t.as_str()),
                "role" | "focused_role" | "tint_role" => ["background", "surface", "sunken", "foreground", "strong", "muted", "border", "accent", "selection", "urgent", "working", "done", "light", "workspace"].contains(&t.as_str()),
                _ => t.chars().count() <= 64 && !t.chars().any(char::is_control),
            };
            if ok { Ok(()) } else { Err(format!("{path} does not take {t:?}")) }
        }
        _ => Err(format!("{path} takes a value of the same kind as the theme's")),
    }
}

/// The `[theme.override]` tree with everything dropped that is not a token of themes.json or is out of range.
fn filter_override(tree: &Value, prefix: &str, errors: &mut Vec<String>) -> Value {
    let Some(m) = tree.as_object() else { return json!({}) };
    let mut out = Map::new();
    for (k, v) in m {
        let path = format!("{prefix}{k}");
        if v.is_object() {
            let sub = filter_override(v, &format!("{path}."), errors);
            if sub.as_object().is_some_and(|o| !o.is_empty()) {
                out.insert(k.clone(), sub);
            }
            continue;
        }
        match override_token(&path) {
            Some(sample) => match override_check(&path, &sample, v) {
                Ok(()) => {
                    out.insert(k.clone(), v.clone());
                }
                Err(e) => errors.push(format!("{e} (ignored)")),
            },
            None => errors.push(format!("{path} is not a token of themes.json (ignored)")),
        }
    }
    Value::Object(out)
}

fn insert_at(t: &mut dyn toml_edit::TableLike, parts: &[&str], value: Item, full: &str) -> Result<(), CfgError> {
    if parts.len() == 1 {
        // An existing key keeps its comments (the ones above it and the one after its value).
        if let Some(old) = t.get_mut(parts[0]) {
            let mut value = value;
            if let (Some(o), Some(n)) = (old.as_value(), value.as_value_mut()) {
                *n.decor_mut() = o.decor().clone();
            }
            *old = value;
        } else {
            t.insert(parts[0], value);
        }
        return Ok(());
    }
    if t.get(parts[0]).is_none() {
        t.insert(parts[0], toml_edit::table());
    }
    match t.get_mut(parts[0]).and_then(|i| i.as_table_like_mut()) {
        Some(sub) => insert_at(sub, &parts[1..], value, full),
        None => Err(invalid(format!("{full}: {} is not a table in config.toml, so nothing was changed", parts[0]))),
    }
}

fn item_to_json(item: &Item) -> Option<Value> {
    if let Some(t) = item.as_table_like() {
        let mut m = Map::new();
        for (k, v) in t.iter() {
            if let Some(j) = item_to_json(v) {
                m.insert(k.to_string(), j);
            }
        }
        return Some(Value::Object(m));
    }
    let v = item.as_value()?;
    if let Some(b) = v.as_bool() {
        return Some(json!(b));
    }
    if let Some(n) = v.as_integer() {
        return Some(json!(n));
    }
    if let Some(f) = v.as_float() {
        return Some(json!(f));
    }
    if let Some(a) = v.as_array() {
        return Some(Value::Array(a.iter().filter_map(|x| x.as_float().map(|f| json!(f)).or_else(|| x.as_integer().map(|n| json!(n)))).collect()));
    }
    v.as_str().map(|s| json!(s))
}

/// A bang of your own: `[[bangs]] trigger = "jira" name = "Jira" url = "https://…/{q}"`. Only web addresses.
fn custom_bangs(doc: &DocumentMut, errors: &mut Vec<String>) -> Vec<Value> {
    let mut out = vec![];
    let Some(arr) = doc.get("bangs").and_then(Item::as_array_of_tables) else { return out };
    for t in arr.iter() {
        let get = |k: &str| t.get(k).and_then(Item::as_str).map(str::trim).unwrap_or("");
        let trig = get("trigger").trim_start_matches('!').to_lowercase();
        let url = get("url");
        let ok = !trig.is_empty() && trig.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') && (url.starts_with("https://") || url.starts_with("http://")) && url.contains("{q}");
        if !ok {
            errors.push(format!("bangs: ignored {trig:?} (needs a trigger and an http(s) url with {{q}})"));
            continue;
        }
        let name = if get("name").is_empty() { trig.as_str() } else { get("name") };
        out.push(json!({ "trigger": trig, "name": name, "url": url, "agent": t.get("agent").and_then(Item::as_bool).unwrap_or(false) }));
    }
    out
}

pub struct Config {
    path: PathBuf,
    doc: DocumentMut,
    stamp: Option<std::time::SystemTime>,
    errors: Vec<String>,
    /// The file on disk does not parse: `set` refuses until it does, and never writes over it.
    broken: Option<String>,
    cache: std::cell::RefCell<Option<Value>>,
}

pub fn config_path() -> PathBuf {
    let base = std::env::var("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".into())).join(".config"));
    base.join("baneyspaces").join("config.toml")
}

impl Config {
    pub fn load(path: &Path) -> Self {
        let mut c = Config { path: path.to_path_buf(), doc: DocumentMut::new(), stamp: None, errors: vec![], broken: None, cache: std::cell::RefCell::new(None) };
        c.reload();
        c
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn mtime(&self) -> Option<std::time::SystemTime> {
        std::fs::metadata(&self.path).and_then(|m| m.modified()).ok()
    }

    /// Reads the file again; true if it changed since the last read.
    pub fn reload(&mut self) -> bool {
        let stamp = self.mtime();
        if stamp == self.stamp && self.stamp.is_some() {
            return false;
        }
        let changed = stamp != self.stamp;
        self.stamp = stamp;
        self.errors.clear();
        self.cache.replace(None);
        match std::fs::read_to_string(&self.path) {
            Ok(text) => match text.parse::<DocumentMut>() {
                Ok(doc) => {
                    self.doc = doc;
                    self.broken = None;
                }
                Err(e) => {
                    // The last good settings keep running; the error is shown and `set` is refused.
                    self.errors.push(format!("config.toml: {e}"));
                    self.broken = Some(e.to_string());
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                self.doc = DocumentMut::new();
                self.broken = None;
            }
            Err(e) => {
                self.errors.push(format!("config.toml cannot be read: {e}"));
                self.broken = Some(e.to_string());
            }
        }
        changed
    }

    fn raw(&self, path: &str) -> Option<Value> {
        let mut item = self.doc.as_item();
        for part in path.split('.') {
            item = item.get(part)?;
        }
        item_to_json(item).filter(|v| !v.is_object())
    }

    /// The effective settings: defaults, then the file, under the plugin's names.
    pub fn effective(&self) -> Value {
        if let Some(v) = self.cache.borrow().as_ref() {
            return v.clone();
        }
        let v = self.compute_effective();
        self.cache.replace(Some(v.clone()));
        v
    }

    fn compute_effective(&self) -> Value {
        let mut root = Map::new();
        let mut errors = self.errors.clone();
        for key in KEYS {
            let (sec, name) = key.internal.split_once('.').unwrap();
            let mut v = match self.raw(key.path) {
                Some(raw) => coerce(key, &raw).unwrap_or_else(|e| {
                    errors.push(format!("{e} (using {})", key.default));
                    parse_default(key)
                }),
                None => parse_default(key),
            };
            if key.path == "behavior.dock.edge" && v != json!("bottom") {
                errors.push(format!("behavior.dock.edge = {v}: the dock is drawn at the bottom on Linux so far"));
                v = json!("bottom");
            }
            if key.path == "behavior.overview.previews" {
                v = json!(v == json!("live")); // the plugin asks "thumbnails?"
            }
            let internal_name = if key.path == "behavior.overview.previews" { "thumbnails" } else { name };
            root.entry(sec).or_insert_with(|| json!({})).as_object_mut().unwrap().insert(internal_name.into(), v);
        }
        // Tokens of themes.json for this machine only: [theme.override].
        let over = self.doc.get("theme").and_then(|t| t.get("override")).and_then(item_to_json).unwrap_or_else(|| json!({}));
        let over = filter_override(&over, "theme.override.", &mut errors);
        root.entry("appearance").or_insert_with(|| json!({})).as_object_mut().unwrap().insert("override".into(), over);
        root.insert("bangs".into(), json!(custom_bangs(&self.doc, &mut errors)));
        root.insert("errors".into(), json!(errors));
        root.insert("path".into(), json!(self.path.display().to_string()));
        Value::Object(root)
    }

    /// The value `raw` stands for at `path`, or why not.
    fn validate(path: &str, raw: &Value) -> Result<Value, CfgError> {
        match find(path) {
            Some(key) => coerce(key, raw).map_err(bad),
            None => {
                let sample = override_token(path).ok_or_else(|| bad(format!("unknown setting {path:?}; `baneyspaces config` lists them")))?;
                let text = raw.as_str().map(str::to_string).unwrap_or_else(|| raw.to_string());
                let value = match sample {
                    Value::Bool(_) => json!(text.parse::<bool>().map_err(|_| bad(format!("{path} takes true or false")))?),
                    Value::Number(_) => json!(text.parse::<f64>().ok().filter(|n| n.is_finite()).ok_or_else(|| bad(format!("{path} takes a number")))?),
                    _ => json!(text),
                };
                override_check(path, &sample, &value).map_err(bad)?;
                Ok(value)
            }
        }
    }

    /// Sets one key. The file on disk is read again under a lock right before the write (a hand edit since the last read is
    /// kept), a file that does not parse is never overwritten, a path through a value that is not a table is refused, and
    /// the write is a temporary file renamed into place next to the real file (a symlinked config keeps its link).
    pub fn set(&mut self, path: &str, raw: &Value) -> Result<Value, CfgError> {
        use std::os::fd::AsRawFd;
        let v = Self::validate(path, raw)?;
        let target = std::fs::canonicalize(&self.path).unwrap_or_else(|_| self.path.clone());
        let dir = target.parent().ok_or_else(|| invalid("no config directory"))?.to_path_buf();
        std::fs::create_dir_all(&dir).map_err(|e| invalid(format!("cannot create {}: {e}", dir.display())))?;
        let lock = std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(dir.join(".config.toml.lock")).map_err(|e| invalid(format!("cannot lock {}: {e}", dir.display())))?;
        // SAFETY: a valid open file descriptor; the lock is released when `lock` is dropped.
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) };
        let text = match std::fs::read_to_string(&target) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
            Err(e) => return Err(invalid(format!("cannot read {}: {e}; nothing was changed", target.display()))),
        };
        let mut doc = text.parse::<DocumentMut>().map_err(|e| invalid(format!("{} has a syntax error, so nothing was changed: {e}", target.display())))?;
        let item = match &v {
            Value::Bool(b) => tv(*b),
            Value::Number(n) if n.is_i64() => tv(n.as_i64().unwrap()),
            Value::Number(n) => tv((n.as_f64().unwrap() * 1000.0).round() / 1000.0),
            Value::String(s) => tv(s.as_str()),
            _ => return Err(bad("unsupported value")),
        };
        let parts: Vec<&str> = path.split('.').collect();
        insert_at(doc.as_table_mut(), &parts, item, path)?;
        let tmp = dir.join(format!(".config.toml.tmp-{}", std::process::id()));
        std::fs::write(&tmp, doc.to_string()).map_err(|e| invalid(format!("cannot write {}: {e}", tmp.display())))?;
        std::fs::rename(&tmp, &target).map_err(|e| {
            let _ = std::fs::remove_file(&tmp);
            invalid(format!("cannot write {}: {e}", target.display()))
        })?;
        self.doc = doc;
        self.broken = None;
        self.errors.retain(|e| !e.starts_with("config.toml"));
        self.stamp = self.mtime();
        self.cache.replace(None);
        Ok(v)
    }

    pub fn get_bool(&self, path: &str) -> bool {
        self.effective_value(path).as_bool().unwrap_or(false)
    }

    pub fn get_i64(&self, path: &str) -> i64 {
        self.effective_value(path).as_i64().unwrap_or(0)
    }

    pub fn get_str(&self, path: &str) -> String {
        self.effective_value(path).as_str().unwrap_or("").to_string()
    }

    /// By the plugin's name (`dock.enabled`).
    pub fn effective_value(&self, internal: &str) -> Value {
        let (sec, name) = internal.split_once('.').unwrap_or((internal, ""));
        self.effective()[sec][name].clone()
    }

    /// The list of keys for `baneyspaces config`, with help text.
    pub fn describe() -> Value {
        json!(KEYS
            .iter()
            .map(|k| {
                let kind = match k.kind {
                    Kind::Bool => json!("bool"),
                    Kind::Enum(o) => json!({ "enum": o }),
                    Kind::Int(a, b) => json!({ "int": [a, b] }),
                    Kind::Float(a, b) => json!({ "float": [a, b] }),
                    Kind::Str => json!("text"),
                };
                json!({ "key": k.path, "kind": kind, "default": parse_default(k), "help": k.help, "in_spec": k.spec })
            })
            .collect::<Vec<_>>())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("bs-config-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d.join("config.toml")
    }

    #[test]
    fn no_file_gives_the_specs_defaults() {
        let e = Config::load(&tmp("none")).effective();
        assert_eq!(e["dock"]["enabled"], json!(true));
        assert_eq!(e["dock"]["hide_ms"], json!(400));
        assert_eq!(e["dock"]["edge_delay_ms"], json!(0));
        assert_eq!(e["appearance"]["theme"], json!("omarchy"));
        assert_eq!(e["appearance"]["palette"], json!("auto"));
        assert_eq!(e["appearance"]["override"], json!({}));
        assert_eq!(e["motion"]["preset"], json!("baneyspaces"));
        assert_eq!(e["motion"]["speed"], json!(1.0));
        assert_eq!(e["motion"]["workspace_style"], json!("off"), "workspace switches are instant by default");
        assert_eq!(e["motion"]["respect_reduce"], json!(true));
        assert_eq!(e["switcher"]["items"], json!("windows"));
        assert_eq!(e["overview"]["thumbnails"], json!(true));
        assert_eq!(e["errors"], json!([]));
    }

    #[test]
    fn the_file_uses_the_specs_paths_and_a_bad_value_falls_back() {
        let p = tmp("over");
        std::fs::write(&p, "[behavior.dock]\nsize = \"large\"\nreveal_ms = 5000\nauto_hide = false\nedge = \"left\"\n[theme]\nname = \"minimal\"\npalette = \"nord\"\n[theme.override]\nfill.opacity = 0.5\nradius.tile = 4\n[animation]\npreset = \"omarchy\"\n[animation.dock.in]\nduration_ms = 90\n[behavior.overview]\npreviews = \"icons\"\n").unwrap();
        let e = Config::load(&p).effective();
        assert_eq!(e["dock"]["size"], json!("large"));
        assert_eq!(e["dock"]["auto_hide"], json!(false));
        assert_eq!(e["dock"]["edge_delay_ms"], json!(0), "out of range: default");
        assert_eq!(e["dock"]["edge"], json!("bottom"), "left is read but only the bottom is drawn");
        assert_eq!(e["appearance"]["theme"], json!("minimal"));
        assert_eq!(e["appearance"]["palette"], json!("nord"));
        assert_eq!(e["appearance"]["override"]["fill"]["opacity"], json!(0.5));
        assert_eq!(e["appearance"]["override"]["radius"]["tile"], json!(4));
        assert_eq!(e["motion"]["preset"], json!("omarchy"));
        assert_eq!(e["motion"]["dock_in_ms"], json!(90));
        assert_eq!(e["overview"]["thumbnails"], json!(false));
        assert_eq!(e["errors"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn a_broken_file_does_not_stop_the_daemon() {
        let p = tmp("broken");
        std::fs::write(&p, "[dock\nsize = ").unwrap();
        let c = Config::load(&p);
        assert_eq!(c.effective()["dock"]["enabled"], json!(true));
        assert_eq!(c.effective()["errors"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn set_validates_keeps_comments_and_writes_nested_paths() {
        let p = tmp("set");
        std::fs::write(&p, "# my notes\n[behavior.dock]\n# size of tiles\nsize = \"small\"\n").unwrap();
        let mut c = Config::load(&p);
        assert!(c.set("behavior.dock.size", &json!("huge")).is_err());
        assert!(c.set("behavior.dock.nope", &json!(1)).is_err());
        assert!(c.set("theme.palette", &json!("red; rm")).is_err());
        assert!(c.set("theme.name", &json!("glass")).is_err());
        assert!(c.set("animation.dock.in.duration_ms", &json!(5000)).is_err(), "over 1000 ms is refused");
        assert_eq!(c.set("behavior.dock.size", &json!("large")).unwrap(), json!("large"));
        assert_eq!(c.set("behavior.dock.auto_hide", &json!("off")).unwrap(), json!(false));
        assert_eq!(c.set("theme.palette", &json!("tokyo-night")).unwrap(), json!("tokyo-night"));
        assert_eq!(c.set("animation.dock.in.duration_ms", &json!("120")).unwrap(), json!(120));
        assert_eq!(c.set("animation.workspace.style", &json!("fade")).unwrap(), json!("fade"));
        assert_eq!(c.set("theme.override.fill.opacity", &json!("0.7")).unwrap(), json!(0.7));
        assert!(c.set("theme.override.fill.nope", &json!(1)).is_err());
        assert!(c.set("theme.override.radius", &json!(1)).is_err(), "a table is not a token");
        let text = std::fs::read_to_string(&p).unwrap();
        assert!(text.contains("# my notes") && text.contains("# size of tiles"), "{text}");
        let again = Config::load(&p).effective();
        assert_eq!(again["dock"]["size"], json!("large"));
        assert_eq!(again["motion"]["dock_in_ms"], json!(120));
        assert_eq!(again["motion"]["workspace_style"], json!("fade"));
        assert_eq!(again["appearance"]["override"]["fill"]["opacity"], json!(0.7));
    }

    #[test]
    fn reload_sees_an_edit() {
        let p = tmp("reload");
        let mut c = Config::load(&p);
        assert!(!c.reload());
        std::fs::write(&p, "[behavior.launcher]\nfiles = false\n").unwrap();
        assert!(c.reload());
        assert_eq!(c.effective()["launcher"]["files"], json!(false));
    }

    #[test]
    fn bangs_of_your_own_are_checked() {
        let p = tmp("bangs");
        std::fs::write(&p, "[[bangs]]\ntrigger = \"!Jira\"\nname = \"Jira\"\nurl = \"https://acme.atlassian.net/browse/{q}\"\n[[bangs]]\ntrigger = \"x\"\nurl = \"file:///etc/passwd?{q}\"\n[[bangs]]\ntrigger = \"y\"\nurl = \"https://nowords.example/\"\n").unwrap();
        let e = Config::load(&p).effective();
        assert_eq!(e["bangs"].as_array().unwrap().len(), 1);
        assert_eq!(e["bangs"][0]["trigger"], json!("jira"));
        assert_eq!(e["errors"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn every_key_default_is_valid_for_its_own_kind() {
        for key in KEYS {
            assert!(coerce(key, &parse_default(key)).is_ok(), "{}", key.path);
        }
    }

    #[test]
    fn the_example_file_lists_every_key_with_its_default_and_changes_nothing() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../omarchy/config.example.toml");
        let text = std::fs::read_to_string(path).expect("config.example.toml");
        for key in KEYS {
            let name = key.path.rsplit('.').next().unwrap();
            let line = text.lines().find(|l| l.starts_with(&format!("# {name} = "))).unwrap_or_else(|| panic!("{} is not in config.example.toml", key.path));
            let shown = line.split('=').nth(1).unwrap().split('#').next().unwrap().trim().trim_matches('"').to_string();
            let want = if matches!(key.kind, Kind::Float(..)) { key.default.trim_end_matches(".0").to_string() } else { key.default.to_string() };
            assert_eq!(shown.trim_end_matches(".0"), want, "{}: the example's default differs", key.path);
        }
        let p = tmp("example");
        std::fs::write(&p, &text).unwrap();
        let c = Config::load(&p);
        assert_eq!(c.effective()["errors"], json!([]));
        assert_eq!(c.effective()["dock"]["size"], json!("medium"));
    }

    #[test]
    fn the_plugin_carries_exactly_the_spec_files_and_they_have_every_token() {
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../../..");
        let plugin = format!("{root}/platforms/linux/omarchy/plugins/io.github.baney75.baneyspaces");
        for f in ["themes.json", "palettes.json"] {
            assert_eq!(std::fs::read(format!("{root}/spec/{f}")).unwrap(), std::fs::read(format!("{plugin}/{f}")).unwrap(), "{f}: copy it from spec/ into the plugin");
        }
        let t: Value = serde_json::from_str(&std::fs::read_to_string(format!("{root}/spec/themes.json")).unwrap()).unwrap();
        assert_eq!(t["themes"].as_object().unwrap().len(), 3);
        for (name, th) in t["themes"].as_object().unwrap() {
            for k in ["radius", "border", "fill", "font", "space", "indicator", "motion"] {
                assert!(!th[k].is_null(), "{name} lacks {k}");
            }
            for k in ["bar", "tile", "row", "list"] {
                assert!(th["radius"][k].is_number(), "{name}.radius.{k}");
            }
            assert!(th.get("shadow").is_some(), "{name}.shadow (an object or null)");
        }
        let p: Value = serde_json::from_str(&std::fs::read_to_string(format!("{root}/spec/palettes.json")).unwrap()).unwrap();
        assert_eq!(p["palettes"].as_object().unwrap().len(), 22);
        let roles: Vec<&str> = p["roles"].as_array().unwrap().iter().filter_map(Value::as_str).collect();
        for (n, pal) in p["palettes"].as_object().unwrap() {
            for r in &roles {
                assert!(pal[r].as_str().is_some_and(is_hex_color), "{n}.{r}");
            }
        }
        assert_eq!(palette_names().len(), 22);
    }

    #[test]
    fn set_keeps_a_hand_edit_made_since_the_last_read() {
        let p = tmp("handedit");
        let mut c = Config::load(&p);
        c.set("behavior.dock.size", &json!("large")).unwrap();
        // a person edits the file; the daemon has not looked yet
        std::fs::write(&p, "# mine\n[behavior.dock]\nsize = \"large\"\nbadges = false\n").unwrap();
        c.set("behavior.launcher.files", &json!("false")).unwrap();
        let text = std::fs::read_to_string(&p).unwrap();
        assert!(text.contains("# mine") && text.contains("badges = false") && text.contains("files = false"), "{text}");
    }

    #[test]
    fn a_file_with_a_syntax_error_is_never_overwritten() {
        let p = tmp("syntax");
        let broken = "[behavior.dock\nsize = \"large\n# my notes\n";
        std::fs::write(&p, broken).unwrap();
        let mut c = Config::load(&p);
        let e = c.set("behavior.dock.size", &json!("small")).unwrap_err();
        assert_eq!(e.code, "config_invalid");
        assert!(e.message.contains("syntax error") && e.message.contains("line"), "{}", e.message);
        assert_eq!(std::fs::read_to_string(&p).unwrap(), broken, "the file is as the person left it");
        assert_eq!(c.effective()["dock"]["enabled"], json!(true), "the last good settings keep running");
        std::fs::write(&p, "[behavior.dock]\nsize = \"large\"\n").unwrap();
        assert!(c.set("behavior.dock.size", &json!("small")).is_ok(), "once it parses, set works again");
    }

    #[test]
    fn a_value_where_a_table_belongs_is_a_typed_error_not_a_panic() {
        for (text, key, val) in [("behavior = false\n", "behavior.dock.enabled", "true"), ("[behavior]\ndock = true\n", "behavior.dock.size", "large"), ("animation = \"off\"\n", "animation.preset", "snappy"), ("theme = \"omarchy\"\n", "theme.palette", "nord")] {
            let p = tmp("scalar");
            std::fs::write(&p, text).unwrap();
            let mut c = Config::load(&p);
            let e = c.set(key, &json!(val)).unwrap_err();
            assert_eq!(e.code, "config_invalid", "{key}: {}", e.message);
            assert!(e.message.contains("not a table"), "{}", e.message);
            assert_eq!(std::fs::read_to_string(&p).unwrap(), text, "the file is untouched");
        }
    }

    #[test]
    fn a_symlinked_config_stays_a_symlink() {
        let p = tmp("link");
        let real = p.parent().unwrap().join("dotfiles-config.toml");
        std::fs::write(&real, "# in my dotfiles\n").unwrap();
        std::os::unix::fs::symlink(&real, &p).unwrap();
        let mut c = Config::load(&p);
        c.set("behavior.dock.size", &json!("large")).unwrap();
        assert!(std::fs::symlink_metadata(&p).unwrap().file_type().is_symlink());
        let text = std::fs::read_to_string(&real).unwrap();
        assert!(text.contains("# in my dotfiles") && text.contains("size = \"large\""), "{text}");
    }

    #[test]
    fn override_tokens_have_the_limits_of_what_they_are() {
        let p = tmp("limits");
        let mut c = Config::load(&p);
        for (k, v) in [("theme.override.motion.in_ms", "100000000"), ("theme.override.motion.in_ms", "-1"), ("theme.override.fill.opacity", "-5"), ("theme.override.fill.opacity", "1.5"), ("theme.override.radius.bar", "1e9"), ("theme.override.radius.tile", "65"), ("theme.override.space.tile", "4"), ("theme.override.font.size", "400"), ("theme.override.motion.scale_from", "0"), ("theme.override.indicator", "sparkle"), ("theme.override.border.role", "nonsense")] {
            assert!(c.set(k, &json!(v)).is_err(), "{k} = {v} should be refused");
        }
        for (k, v) in [("theme.override.motion.in_ms", "1000"), ("theme.override.fill.opacity", "0.5"), ("theme.override.radius.bar", "64"), ("theme.override.indicator", "dot"), ("theme.override.border.role", "accent")] {
            assert!(c.set(k, &json!(v)).is_ok(), "{k} = {v} should be accepted");
        }
    }

    #[test]
    fn a_hand_written_override_that_is_not_a_token_is_dropped_and_reported() {
        let p = tmp("badover");
        std::fs::write(&p, "[theme.override]\nradius = 4\n\n[theme.override.fill]\nopacity = 9\nnope = 1\n\n[theme.override.space]\ntile = 70\n").unwrap();
        let e = Config::load(&p).effective();
        assert_eq!(e["appearance"]["override"], json!({ "space": { "tile": 70 } }), "radius = 4 would erase every radius");
        assert_eq!(e["errors"].as_array().unwrap().len(), 3);
    }
}
