//! The configuration model (`spec/config.md`): defaults, merging a document over them, validation
//! with exact paths and reasons, and the effective config every UI and the compositor layer read.
//! Pure: no files, no compositor. [`crate::config_store`] reads and writes the files.

use crate::action::{self, Action};
use crate::animation::{self, Curve};
use crate::chord::{self, Chord, Platform};
use crate::config_schema::{self, check, Issue};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

pub const THEMES_JSON: &str = include_str!("../../../spec/themes.json");
pub const PALETTES_JSON: &str = include_str!("../../../spec/palettes.json");

/// What the platform tells the model about itself.
#[derive(Clone, Debug)]
pub struct Env {
    pub platform: Platform,
    /// An Omarchy seat: the default theme is `omarchy` (spec/themes.md).
    pub omarchy: bool,
    /// The system's Reduce Motion setting.
    pub reduce_motion: bool,
    /// The live Omarchy palette for `palette = "auto"`, if the platform can read one.
    pub palette_auto: Option<Value>,
}

impl Env {
    pub fn new(platform: Platform) -> Self {
        Env {
            platform,
            omarchy: false,
            reduce_motion: false,
            palette_auto: None,
        }
    }
}

/// The custom themes (`themes/<name>.toml`) as parsed documents.
pub type Themes = BTreeMap<String, Value>;

fn builtin() -> Value {
    serde_json::from_str(THEMES_JSON).expect("spec/themes.json is valid JSON")
}

fn palettes() -> Value {
    serde_json::from_str(PALETTES_JSON).expect("spec/palettes.json is valid JSON")
}

pub fn builtin_theme_names() -> Vec<String> {
    builtin()["themes"]
        .as_object()
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default()
}

pub fn builtin_palette_names() -> Vec<String> {
    palettes()["palettes"]
        .as_object()
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default()
}

// ---- defaults and merging --------------------------------------------------------------------

/// The default bindings of a platform, from `spec/keys.json`, spelled with `mod`.
pub fn default_bindings(p: Platform) -> Vec<(String, String)> {
    let k = crate::keymap::keys();
    let (_, mod_default) = chord::mod_values(p);
    let plat = &k["platforms"][p.name()];
    let mut out: Vec<(String, String)> = vec![];
    let mut seen: Vec<Chord> = vec![];
    let mut add = |template: &str, n: Option<u8>, action: String| {
        if template.is_empty() {
            return;
        }
        let mut t = template.to_lowercase().replace(' ', "");
        if let Some(n) = n {
            t = t
                .replace("{key}", &n.to_string())
                .replace("{n}", &n.to_string());
        }
        // The platform's own modifier is spelled mod.
        let parts: Vec<&str> = t.split('+').collect();
        let spelled: Vec<String> = parts
            .iter()
            .enumerate()
            .map(|(i, s)| {
                if i + 1 < parts.len() && *s == mod_default {
                    "mod".to_string()
                } else {
                    s.to_string()
                }
            })
            .collect();
        let spelling = spelled.join("+");
        let Ok(c) = chord::parse(&spelling, &mod_default) else {
            return;
        };
        if seen.contains(&c) {
            return;
        }
        seen.push(c);
        out.push((spelling, action));
    };
    let s = |key: &str| plat[key].as_str().unwrap_or("").to_string();
    for n in 1..=9u8 {
        add(&s("switch"), Some(n), format!("switch {n}"));
    }
    for n in 1..=9u8 {
        add(&s("move"), Some(n), format!("move {n}"));
    }
    for n in 1..=9u8 {
        add(&s("move_stay"), Some(n), format!("move {n} --stay"));
    }
    add(&s("overview"), None, "overview".into());
    add(&s("agent_toggle"), None, "agent-workspace toggle".into());
    out
}

/// The default document of a platform: what the config is when the file is empty.
pub fn defaults(env: &Env) -> Value {
    let (_, mod_default) = chord::mod_values(env.platform);
    let bindings: Map<String, Value> = default_bindings(env.platform)
        .into_iter()
        .map(|(k, v)| (k, json!(v)))
        .collect();
    let b = builtin();
    let theme = if env.omarchy {
        b["default"]["omarchy"].clone()
    } else {
        b["default"][env.platform.name()].clone()
    };
    json!({
        "keys": { "mod": mod_default, "bindings": bindings, "modes": {} },
        "theme": { "name": theme, "palette": "auto", "override": {} },
        "animation": { "preset": "baneyspaces", "speed": 1.0, "respect_reduce_motion": true },
        "behavior": {
            "follow_focus": true,
            "new_window": "current",
            "workspace_names": {},
            "workspace_tints": {},
            "dock": { "enabled": true, "edge": "bottom", "reveal_ms": 0, "hide_ms": 400, "auto_hide": true, "size": "medium", "in_fullscreen": false, "badges": true },
            "overview": { "enabled": true, "layout": "adaptive", "empty": "compact", "previews": "live" },
            "launcher": { "enabled": true, "files": true, "install": true, "search_engine": "ddg", "agent": "claude" },
            "switcher": { "enabled": true, "mode": "windows", "hold_ms": 120 }
        },
        "rules": [],
        "bangs": [],
        "hooks": { "on_switch": "", "on_window_open": "" }
    })
}

/// Lays `over` on `base`: tables merge key by key, anything else is replaced.
pub fn merge(base: &mut Value, over: &Value) {
    match (base, over) {
        (Value::Object(b), Value::Object(o)) => {
            for (k, v) in o {
                match b.get_mut(k) {
                    Some(bv) => merge(bv, v),
                    None => {
                        b.insert(k.clone(), v.clone());
                    }
                }
            }
        }
        (b, o) => *b = o.clone(),
    }
}

// ---- parsing and writing ---------------------------------------------------------------------

/// Parses a document given as TOML or JSON (JSON when it starts with `{`).
pub fn parse_document(text: &str) -> Result<Value, Issue> {
    let t = text.trim_start();
    let v: Result<Value, String> = if t.starts_with('{') {
        serde_json::from_str(text).map_err(|e| e.to_string())
    } else {
        toml::from_str::<Value>(text).map_err(|e| e.to_string())
    };
    match v {
        Ok(v) if v.is_object() => Ok(v),
        Ok(_) => Err(Issue::new(&[], "syntax", "the document must be a table")),
        Err(e) => Err(Issue::new(
            &[],
            "syntax",
            format!(
                "not valid {}: {}",
                if t.starts_with('{') { "JSON" } else { "TOML" },
                e.trim().replace('\n', " | ")
            ),
        )),
    }
}

/// A document as TOML text. Empty tables are dropped (the file holds only what differs).
pub fn to_toml(v: &Value) -> String {
    let pruned = prune(v).unwrap_or_else(|| json!({}));
    match toml::to_string(&pruned) {
        Ok(s) => s,
        Err(e) => format!("# could not write this document as TOML: {e}\n"),
    }
}

fn prune(v: &Value) -> Option<Value> {
    match v {
        Value::Object(o) => {
            let m: Map<String, Value> = o
                .iter()
                .filter_map(|(k, v)| prune(v).map(|p| (k.clone(), p)))
                .collect();
            (!m.is_empty()).then_some(Value::Object(m))
        }
        Value::Null => None,
        other => Some(other.clone()),
    }
}

// ---- paths -----------------------------------------------------------------------------------

/// Splits `keys.bindings."mod+1"` or `rules[0].app` into segments (`#0` marks an index).
pub fn parse_path(s: &str) -> Result<Vec<String>, String> {
    let mut out = vec![];
    let mut cur = String::new();
    let mut quoted = false;
    let mut had_quote = false;
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match (c, quoted) {
            ('"', _) => {
                quoted = !quoted;
                had_quote = true;
            }
            ('\\', true) => match chars.next() {
                Some(n) => cur.push(n),
                None => return Err("a backslash at the end".into()),
            },
            ('.', false) => {
                if cur.is_empty() && !had_quote {
                    return Err("an empty name in the path".into());
                }
                out.push(std::mem::take(&mut cur));
                had_quote = false;
            }
            ('[', false) => {
                if !cur.is_empty() || had_quote {
                    out.push(std::mem::take(&mut cur));
                    had_quote = false;
                }
                let mut idx = String::new();
                loop {
                    match chars.next() {
                        Some(']') => break,
                        Some(d) if d.is_ascii_digit() => idx.push(d),
                        _ => return Err("an index is [0], [1], ...".into()),
                    }
                }
                if idx.is_empty() {
                    return Err("an index is [0], [1], ...".into());
                }
                out.push(format!("#{idx}"));
                if chars.peek() == Some(&'.') {
                    chars.next();
                }
            }
            (c, _) => cur.push(c),
        }
    }
    if quoted {
        return Err("an unclosed quote in the path".into());
    }
    if !cur.is_empty() || had_quote {
        out.push(cur);
    }
    if out.is_empty() {
        return Err("an empty path".into());
    }
    Ok(out)
}

pub fn get_path<'a>(v: &'a Value, path: &[String]) -> Option<&'a Value> {
    let mut cur = v;
    for seg in path {
        cur = match (cur, seg.strip_prefix('#')) {
            (Value::Array(a), Some(i)) => a.get(i.parse::<usize>().ok()?)?,
            (Value::Object(o), _) => o.get(seg)?,
            _ => return None,
        };
    }
    Some(cur)
}

/// Sets `path` to `val`, making the tables on the way. A step into a value that is not a table or
/// array replaces it, and validation then refuses what does not belong.
pub fn set_path(v: &mut Value, path: &[String], val: Value) -> Result<(), String> {
    let Some((first, rest)) = path.split_first() else {
        *v = val;
        return Ok(());
    };
    if let Some(i) = first.strip_prefix('#') {
        let i: usize = i.parse().map_err(|_| "bad index")?;
        let Value::Array(a) = v else {
            return Err(format!("[{i}] is an index, but this is not an array"));
        };
        if i > a.len() {
            return Err(format!(
                "index [{i}] is past the end of an array of {}",
                a.len()
            ));
        }
        if i == a.len() {
            a.push(Value::Null);
        }
        if rest.is_empty() {
            a[i] = val;
            return Ok(());
        }
        if a[i].is_null() {
            a[i] = json!({});
        }
        return set_path(&mut a[i], rest, val);
    }
    if !v.is_object() {
        *v = json!({});
    }
    let o = v.as_object_mut().expect("just made an object");
    if rest.is_empty() {
        o.insert(first.clone(), val);
        return Ok(());
    }
    let child = o.entry(first.clone()).or_insert_with(|| {
        if rest[0].starts_with('#') {
            json!([])
        } else {
            json!({})
        }
    });
    set_path(child, rest, val)
}

/// Removes `path`; returns whether anything was there. Tables left empty are dropped.
pub fn unset_path(v: &mut Value, path: &[String]) -> bool {
    let Some((first, rest)) = path.split_first() else {
        return false;
    };
    if let Some(i) = first.strip_prefix('#') {
        let (Ok(i), Value::Array(a)) = (i.parse::<usize>(), &mut *v) else {
            return false;
        };
        if i >= a.len() {
            return false;
        }
        if rest.is_empty() {
            a.remove(i);
            return true;
        }
        return unset_path(&mut a[i], rest);
    }
    let Value::Object(o) = v else { return false };
    if rest.is_empty() {
        return o.remove(first).is_some();
    }
    let Some(child) = o.get_mut(first) else {
        return false;
    };
    let hit = unset_path(child, rest);
    if hit && child.as_object().is_some_and(Map::is_empty) {
        o.remove(first);
    }
    hit
}

// ---- themes ----------------------------------------------------------------------------------

fn rolenames() -> &'static [&'static str] {
    config_schema::ROLES
}

fn token_keys() -> Vec<&'static str> {
    config_schema::tokens()
        .into_iter()
        .map(|(k, _)| k)
        .collect()
}

/// Lays token overrides on tokens. `false` and `"none"` mean no shadow and no material; they are
/// stored as null, the way `themes.json` has them.
fn lay_tokens(base: &mut Value, over: &Value) {
    let Some(o) = over.as_object() else { return };
    for (k, v) in o {
        match (k.as_str(), v) {
            ("shadow", Value::Bool(false)) | ("shadow", Value::Null) => {
                base["shadow"] = Value::Null
            }
            ("shadow", Value::Object(_)) => {
                if !base["shadow"].is_object() {
                    base["shadow"] = builtin()["themes"]["baneyspaces"]["shadow"].clone();
                }
                merge(&mut base["shadow"], v);
            }
            ("fill", Value::Object(f)) => {
                let mut f = f.clone();
                if f.get("material").and_then(Value::as_str) == Some("none") {
                    f.insert("material".into(), Value::Null);
                }
                if !base["fill"].is_object() {
                    base["fill"] = json!({});
                }
                merge(&mut base["fill"], &Value::Object(f));
            }
            (_, Value::Object(_)) => {
                if !base[k].is_object() {
                    base[k] = json!({});
                }
                merge(&mut base[k], v);
            }
            _ => base[k] = v.clone(),
        }
    }
}

/// A theme's tokens and palette after following `extends`, outermost last.
pub struct ThemeChain {
    /// Names from the root built-in theme to the named one.
    pub chain: Vec<String>,
    pub tokens: Value,
    /// The palette the nearest custom theme in the chain carries, with that theme's name.
    pub palette: Option<(String, Value)>,
}

/// Follows `extends` from `name` to a built-in theme. The error is the reason.
pub fn theme_chain(name: &str, themes: &Themes) -> Result<ThemeChain, String> {
    let b = builtin();
    let mut names = vec![];
    let mut cur = name.to_string();
    loop {
        if names.contains(&cur) {
            names.push(cur);
            return Err(format!(
                "themes extend each other in a circle: {}",
                names.join(" -> ")
            ));
        }
        names.push(cur.clone());
        if b["themes"].get(&cur).is_some() {
            break;
        }
        match themes.get(&cur) {
            None => return Err(format!("no theme named {cur:?}: built-in themes are {}; custom themes are files in themes/", builtin_theme_names().join(", "))),
            Some(t) if t.get("__broken").is_some() => return Err(t["__broken"].as_str().unwrap_or("not valid TOML").to_string()),
            Some(t) => match t.get("extends").and_then(Value::as_str) {
                Some(next) => cur = next.to_string(),
                None => return Err(format!("theme {cur:?} has no extends")),
            },
        }
        if names.len() > 16 {
            return Err("themes extend too deep (16 at most)".into());
        }
    }
    names.reverse();
    let root = &names[0];
    let mut tokens = Value::Object(
        token_keys()
            .into_iter()
            .filter_map(|k| {
                b["themes"][root.as_str()]
                    .get(k)
                    .map(|v| (k.to_string(), v.clone()))
            })
            .collect(),
    );
    let mut palette = None;
    for n in names.iter().skip(1) {
        let t = &themes[n];
        lay_tokens(&mut tokens, t);
        if let Some(p) = t.get("palette").filter(|p| p.is_object()) {
            palette = Some((n.clone(), p.clone()));
        }
    }
    Ok(ThemeChain {
        chain: names,
        tokens,
        palette,
    })
}

/// A palette from `palettes.json` by name.
pub fn named_palette(name: &str) -> Option<Value> {
    palettes()["palettes"].get(name).cloned()
}

/// Maps an Omarchy theme's `colors.toml` onto the twelve roles, the way `scripts/gen-palettes.py`
/// does for `palettes.json`.
pub fn palette_from_omarchy(colors: &Value) -> Option<Value> {
    const MAP: &[(&str, &[&str])] = &[
        ("background", &["background"]),
        ("surface", &["lighter_background", "background"]),
        ("sunken", &["dark_background", "background"]),
        ("foreground", &["foreground"]),
        (
            "strong",
            &["bright_foreground", "light_foreground", "foreground"],
        ),
        ("muted", &["dark_foreground", "muted"]),
        ("border", &["muted", "dark_foreground"]),
        ("accent", &["accent", "blue"]),
        ("selection", &["selection", "lighter_background"]),
        ("urgent", &["red"]),
        ("working", &["yellow"]),
        ("done", &["green"]),
    ];
    let mut out = Map::new();
    out.insert(
        "mode".into(),
        json!(colors.get("mode").and_then(Value::as_str).unwrap_or("dark")),
    );
    for (role, keys) in MAP {
        let c = keys.iter().find_map(|k| {
            colors
                .get(*k)
                .and_then(Value::as_str)
                .filter(|s| s.starts_with('#') && s.len() == 7)
        })?;
        out.insert((*role).into(), json!(c.to_lowercase()));
    }
    Some(Value::Object(out))
}

/// The palette in use: `(name, how it was chosen, roles)`.
pub fn resolve_palette(
    wanted: &str,
    chain: &ThemeChain,
    themes: &Themes,
    env: &Env,
) -> Result<(String, &'static str, Value), String> {
    if wanted != "auto" {
        if let Some(p) = named_palette(wanted) {
            return Ok((wanted.to_string(), "named", p));
        }
        if let Some(p) = themes
            .get(wanted)
            .and_then(|t| t.get("palette"))
            .filter(|p| p.is_object())
        {
            return Ok((wanted.to_string(), "custom", p.clone()));
        }
        return Err(format!("no palette named {wanted:?}: use auto, one of {}, or a custom theme that carries a palette", builtin_palette_names().join(", ")));
    }
    if let Some((n, p)) = &chain.palette {
        return Ok((n.clone(), "custom", p.clone()));
    }
    if let Some(p) = &env.palette_auto {
        return Ok(("auto".into(), "auto", p.clone()));
    }
    Ok((
        "catppuccin".into(),
        "fallback",
        named_palette("catppuccin").expect("catppuccin is in palettes.json"),
    ))
}

// ---- validation and the effective config -----------------------------------------------------

/// The problems in one custom theme file (`themes/<name>.toml`), with paths under `themes.<name>`.
pub fn validate_theme_file(name: &str, t: &Value, themes: &Themes) -> Vec<Issue> {
    let mut sub = vec![];
    if let Some(msg) = t.get("__broken").and_then(Value::as_str) {
        return vec![Issue { path: format!("themes.{name}"), code: "syntax", reason: msg.to_string() }];
    }
    check(&config_schema::custom_theme_node(), t, &mut vec![], &mut sub);
    if t.get("extends").is_none() {
        sub.push(Issue::new(&["extends".into()], "required", "a custom theme says which theme it extends: extends = \"omarchy\""));
    }
    if let Some(p) = t.get("palette").and_then(Value::as_object) {
        for r in rolenames() {
            if !p.contains_key(*r) {
                sub.push(Issue::new(&["palette".into(), (*r).into()], "required", format!("a palette has all twelve roles; {r} is missing")));
            }
        }
    }
    let mut out: Vec<Issue> = sub
        .into_iter()
        .map(|i| Issue { path: if i.path.is_empty() { format!("themes.{name}") } else { format!("themes.{name}.{}", i.path) }, code: i.code, reason: i.reason })
        .collect();
    if let Err(why) = theme_chain(name, themes) {
        if t.get("extends").is_some() {
            out.push(Issue { path: format!("themes.{name}.extends"), code: "bad_theme", reason: why });
        }
    }
    out
}

/// One resolved binding.
#[derive(Clone, Debug, PartialEq)]
pub struct Binding {
    pub spelling: String,
    pub chord: Chord,
    pub text: String,
    pub action: Action,
}

/// The config as it runs: the document with defaults and presets filled in, and what was
/// resolved from it.
#[derive(Clone, Debug)]
pub struct Effective {
    pub platform: Platform,
    pub doc: Value,
    pub bindings: Vec<Binding>,
    pub modes: BTreeMap<String, Vec<Binding>>,
    pub curves: Vec<(String, Curve)>,
    pub modifier: String,
}

pub struct Validated {
    pub issues: Vec<Issue>,
    pub warnings: Vec<Issue>,
    pub effective: Option<Effective>,
}

fn user_str<'a>(v: &'a Value, path: &[&str]) -> Option<&'a str> {
    let mut cur = v;
    for p in path {
        cur = cur.get(p)?;
    }
    cur.as_str()
}

fn resolve_binding_table(
    table: Option<&Value>,
    modifier: &str,
    require_modifier: bool,
    base: Vec<Binding>,
    path: &[String],
    issues: &mut Vec<Issue>,
) -> Vec<Binding> {
    let mut out = base;
    let Some(t) = table.and_then(Value::as_object) else {
        return out;
    };
    let mut seen: Vec<(Chord, String)> = vec![];
    for (spelling, val) in t {
        let mut p = path.to_vec();
        p.push(spelling.clone());
        let Some(text) = val.as_str() else { continue }; // the shape check reported it
        let c = match chord::parse(spelling, modifier) {
            Ok(c) => c,
            Err(why) => {
                issues.push(Issue::new(&p, "bad_chord", why));
                continue;
            }
        };
        if require_modifier && !c.has_modifier() {
            issues.push(Issue::new(
                &p,
                "bad_chord",
                "a binding needs at least one modifier (a bare key belongs in a mode)",
            ));
            continue;
        }
        if c == Chord::recovery() {
            issues.push(Issue::new(&p, "reserved_chord", format!("{} held for {} s is the recovery chord: it restores the default keys and theme, and config can neither bind nor remove it", c.canonical(Platform::Linux).replace("super", "the logo key"), chord::recovery_hold_ms() / 1000)));
            continue;
        }
        if let Some((_, other)) = seen.iter().find(|(sc, _)| *sc == c) {
            issues.push(Issue::new(
                &p,
                "duplicate_chord",
                format!("the same chord as {other:?} (mod is {modifier:?} here); bind it once"),
            ));
            continue;
        }
        seen.push((c.clone(), spelling.clone()));
        let action = match action::parse(text) {
            Ok(a) => a,
            Err(why) => {
                issues.push(Issue::new(&p, "bad_action", why));
                continue;
            }
        };
        out.retain(|b| b.chord != c);
        if action != Action::None {
            out.push(Binding {
                spelling: spelling.clone(),
                chord: c,
                text: text.trim().to_string(),
                action,
            });
        }
    }
    out
}

fn reaches_switch(top: &[Binding], modes: &BTreeMap<String, Vec<Binding>>) -> bool {
    let is_switch = |b: &Binding| matches!(&b.action, Action::Cli(w) if w[0] == "switch");
    top.iter().any(|b| match &b.action {
        Action::Mode(m) => modes.get(m).is_some_and(|bs| bs.iter().any(is_switch)),
        _ => is_switch(b),
    }) || top.iter().any(is_switch)
}

/// Validates a user document and, when it holds, resolves it. `themes` are the custom themes
/// (themes/*.toml), already parsed.
pub fn validate(user: &Value, env: &Env, themes: &Themes) -> Validated {
    let mut issues: Vec<Issue> = vec![];
    let mut warnings: Vec<Issue> = vec![];
    check(&config_schema::schema(), user, &mut vec![], &mut issues);
    let defaults = defaults(env);

    // Custom themes: shape, extends, palette. A problem in a theme this config uses is an error;
    // in one it does not use, a warning (a broken file you are not using never blocks a change).
    let tname = user_str(user, &["theme", "name"])
        .unwrap_or_else(|| defaults["theme"]["name"].as_str().unwrap_or("baneyspaces"))
        .to_string();
    let active: Vec<String> = theme_chain(&tname, themes)
        .map(|c| c.chain)
        .unwrap_or_else(|_| vec![tname.clone()]);
    for (name, t) in themes {
        for i in validate_theme_file(name, t, themes) {
            if active.contains(name) {
                issues.push(i);
            } else {
                warnings.push(i);
            }
        }
    }

    // keys.mod
    let (allowed, _) = chord::mod_values(env.platform);
    let mut modifier = defaults["keys"]["mod"]
        .as_str()
        .unwrap_or("super")
        .to_string();
    if let Some(m) = user_str(user, &["keys", "mod"]) {
        if allowed.iter().any(|a| a == m) {
            modifier = m.to_string();
        } else if ["cmd", "ctrl", "alt", "super", "win"].contains(&m) {
            issues.push(Issue::new(
                &["keys".into(), "mod".into()],
                "bad_mod",
                format!(
                    "{m:?} is not a modifier on {}: use {}",
                    env.platform.name(),
                    allowed
                        .iter()
                        .map(|a| format!("{a:?}"))
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            ));
        }
    }

    // keys.bindings and keys.modes
    let defaults_resolved: Vec<Binding> = default_bindings(env.platform)
        .into_iter()
        .filter_map(|(spelling, text)| {
            Some(Binding {
                chord: chord::parse(&spelling, &modifier).ok()?,
                action: action::parse(&text).ok()?,
                spelling,
                text,
            })
        })
        .collect();
    let bpath: Vec<String> = vec!["keys".into(), "bindings".into()];
    let bindings = resolve_binding_table(
        user.pointer("/keys/bindings"),
        &modifier,
        true,
        defaults_resolved,
        &bpath,
        &mut issues,
    );
    let mut modes: BTreeMap<String, Vec<Binding>> = BTreeMap::new();
    if let Some(ms) = user.pointer("/keys/modes").and_then(Value::as_object) {
        for (mname, table) in ms {
            let mpath: Vec<String> = vec!["keys".into(), "modes".into(), mname.clone()];
            if mname == "default" {
                issues.push(Issue::new(
                    &mpath,
                    "bad_mode",
                    "\"default\" is the normal keys and cannot be defined as a mode",
                ));
                continue;
            }
            let mut bs =
                resolve_binding_table(Some(table), &modifier, false, vec![], &mpath, &mut issues);
            let esc_set = table.as_object().is_some_and(|t| {
                t.keys().any(|k| {
                    chord::parse(k, &modifier).is_ok_and(|c| c.key == "escape" && !c.has_modifier())
                })
            });
            if !esc_set {
                bs.push(Binding {
                    spelling: "escape".into(),
                    chord: Chord {
                        logo: false,
                        ctrl: false,
                        alt: false,
                        shift: false,
                        key: "escape".into(),
                    },
                    text: "mode default".into(),
                    action: Action::Mode("default".into()),
                });
            }
            if !bs
                .iter()
                .any(|b| b.action == Action::Mode("default".into()))
            {
                issues.push(Issue::new(&mpath, "lockout", "this mode has no way out: bind a chord to \"mode default\" (escape does it unless you rebound it)"));
            }
            modes.insert(mname.clone(), bs);
        }
    }
    // Every `mode X` names a mode that exists.
    let all: Vec<(&Binding, Vec<String>)> = bindings
        .iter()
        .map(|b| (b, bpath.clone()))
        .chain(modes.iter().flat_map(|(m, bs)| {
            bs.iter()
                .map(move |b| (b, vec!["keys".to_string(), "modes".into(), m.clone()]))
        }))
        .collect();
    for (b, base) in all {
        if let Action::Mode(m) = &b.action {
            if m != "default" && !modes.contains_key(m) {
                let mut p = base;
                p.push(b.spelling.clone());
                issues.push(Issue::new(
                    &p,
                    "bad_action",
                    format!("mode {m:?} is not defined: add [keys.modes.{m}]"),
                ));
            }
        }
        if matches!(b.action, Action::Exec(_)) {
            warnings.push(Issue::new(
                &["keys".into(), "bindings".into(), b.spelling.clone()],
                "runs_commands",
                "exec runs a command as you when the key is pressed",
            ));
        }
    }
    if !reaches_switch(&bindings, &modes) {
        issues.push(Issue::new(&bpath, "lockout", "no binding switches to a workspace. Keep at least one \"switch <n>\" binding (or one that enters a mode that has it), so the keyboard can always reach a workspace"));
    }

    // theme
    let wanted_palette = user_str(user, &["theme", "palette"])
        .unwrap_or("auto")
        .to_string();
    let chain = match theme_chain(&tname, themes) {
        Ok(c) => Some(c),
        Err(why) => {
            if !issues.iter().any(|i| i.path.starts_with("themes."))
                || user_str(user, &["theme", "name"]).is_some()
            {
                issues.push(Issue::new(
                    &["theme".into(), "name".into()],
                    "bad_theme",
                    why,
                ));
            }
            None
        }
    };
    if let Some(chain) = &chain {
        if let Err(why) = resolve_palette(&wanted_palette, chain, themes, env) {
            issues.push(Issue::new(
                &["theme".into(), "palette".into()],
                "bad_palette",
                why,
            ));
        }
    }

    // animation
    let anim = user.get("animation").cloned().unwrap_or_else(|| json!({}));
    let mut merged_anim = defaults["animation"].clone();
    merge(&mut merged_anim, &anim);
    let speed_bad = issues.iter().any(|i| i.path == "animation.speed");
    let mut anim_issues = vec![];
    let curves = animation::resolve(&merged_anim, &mut anim_issues);
    // A speed that is itself refused would only repeat as a "too long" on every surface.
    issues.extend(anim_issues.into_iter().filter(|i| !(speed_bad && i.code == "too_long")));

    // rules
    if let Some(rules) = user.get("rules").and_then(Value::as_array) {
        for (i, r) in rules.iter().enumerate() {
            let p = |f: &str| -> Vec<String> {
                vec!["rules".to_string(), format!("#{i}"), f.to_string()]
            };
            if r.get("app").is_none() && r.get("title").is_none() {
                issues.push(Issue::new(
                    &["rules".to_string(), format!("#{i}")],
                    "required",
                    "a rule matches by app, by title or both: set app or title",
                ));
            }
            if let Some(t) = r.get("title").and_then(Value::as_str) {
                if let Err(e) = regex::Regex::new(t) {
                    issues.push(Issue::new(
                        &p("title"),
                        "bad_regex",
                        format!(
                            "not a regular expression: {}",
                            e.to_string().lines().last().unwrap_or("").trim()
                        ),
                    ));
                }
            }
        }
    }

    // bangs
    if let Some(bangs) = user.get("bangs").and_then(Value::as_array) {
        for (i, b) in bangs.iter().enumerate() {
            let p = |f: &str| -> Vec<String> { vec!["bangs".to_string(), format!("#{i}"), f.to_string()] };
            for f in ["trigger", "url"] {
                if b.get(f).is_none() {
                    issues.push(Issue::new(&["bangs".to_string(), format!("#{i}")], "required", format!("a bang needs a {f}")));
                }
            }
            if let Some(u) = b.get("url").and_then(Value::as_str) {
                if !(u.starts_with("https://") || u.starts_with("http://")) || !u.contains("{q}") {
                    issues.push(Issue::new(&p("url"), "bad_url", "a bang url is an http(s) address with {q} where the words go"));
                }
            }
        }
    }

    // hooks
    for h in ["on_switch", "on_window_open"] {
        if user_str(user, &["hooks", h]).is_some_and(|s| !s.is_empty()) {
            warnings.push(Issue::new(
                &["hooks".into(), h.into()],
                "runs_commands",
                "a hook runs a command as you on this event; it is logged and shown in Settings",
            ));
        }
    }

    if !issues.is_empty() {
        return Validated {
            issues,
            warnings,
            effective: None,
        };
    }

    // The effective document.
    let mut doc = defaults.clone();
    merge(&mut doc, user);
    doc["keys"]["mod"] = json!(modifier);
    let eff_bindings: Map<String, Value> = bindings
        .iter()
        .map(|b| (b.spelling.clone(), json!(b.text)))
        .collect();
    doc["keys"]["bindings"] = Value::Object(eff_bindings);
    let eff_modes: Map<String, Value> = modes
        .iter()
        .map(|(m, bs)| {
            (
                m.clone(),
                Value::Object(
                    bs.iter()
                        .map(|b| (b.spelling.clone(), json!(b.text)))
                        .collect(),
                ),
            )
        })
        .collect();
    doc["keys"]["modes"] = Value::Object(eff_modes);
    let mut anim_doc = merged_anim.clone();
    for (s, c) in &curves {
        let mut v = c.to_value();
        if s == "workspace" {
            v["style"] = json!(merged_anim
                .pointer("/workspace/style")
                .and_then(Value::as_str)
                .unwrap_or("off"));
        }
        let path: Vec<String> = s.split('.').map(String::from).collect();
        let _ = set_path(&mut anim_doc, &path, v);
    }
    doc["animation"] = anim_doc;
    Validated {
        issues,
        warnings,
        effective: Some(Effective {
            platform: env.platform,
            doc,
            bindings,
            modes,
            curves,
            modifier,
        }),
    }
}

/// What every UI reads, `$XDG_RUNTIME_DIR/baneyspaces/config.json` on Linux: the effective config
/// and what was resolved from it (theme tokens, the palette in use, final animation numbers).
pub fn resolved_json(eff: &Effective, env: &Env, themes: &Themes) -> Value {
    let name = eff.doc["theme"]["name"].as_str().unwrap_or("baneyspaces");
    let wanted = eff.doc["theme"]["palette"].as_str().unwrap_or("auto");
    let (tokens, chain_names, pal) = match theme_chain(name, themes) {
        Ok(chain) => {
            let mut tokens = chain.tokens.clone();
            lay_tokens(&mut tokens, &eff.doc["theme"]["override"]);
            let pal = resolve_palette(wanted, &chain, themes, env).ok();
            (tokens, chain.chain, pal)
        }
        Err(_) => (json!({}), vec![], None),
    };
    let speed = eff.doc["animation"]["speed"].as_f64().unwrap_or(1.0);
    let respect = eff.doc["animation"]["respect_reduce_motion"]
        .as_bool()
        .unwrap_or(true);
    let (pname, psource, proles) = pal.unwrap_or_else(|| {
        (
            "catppuccin".into(),
            "fallback",
            named_palette("catppuccin").unwrap_or(json!({})),
        )
    });
    let canon = |bs: &[Binding]| -> Vec<Value> {
        bs.iter().map(|b| json!({ "chord": b.chord.canonical(eff.platform), "spelling": b.spelling, "action": b.text })).collect()
    };
    json!({
        "version": 1,
        "platform": eff.platform.name(),
        "effective": eff.doc,
        "resolved": {
            "theme": { "name": name, "chain": chain_names, "tokens": tokens, "palette": { "name": pname, "source": psource, "roles": proles } },
            "animation": animation::final_numbers(&eff.curves, speed, env.reduce_motion, respect),
            "reduce_motion": env.reduce_motion && respect,
            "workspace_style": eff.doc["animation"]["workspace"]["style"],
            "keys": {
                "mod": eff.modifier,
                "bindings": canon(&eff.bindings),
                "modes": eff.modes.iter().map(|(m, bs)| (m.clone(), Value::Array(canon(bs)))).collect::<Map<_, _>>(),
                "recovery": { "chord": Chord::recovery().canonical(eff.platform), "hold_ms": chord::recovery_hold_ms() },
            }
        }
    })
}

/// The platform-neutral defaults the committed schema carries (no `keys`, whose defaults are per platform).
pub fn schema_defaults() -> Value {
    let mut d = defaults(&Env::new(Platform::Linux));
    d.as_object_mut().map(|o| o.remove("keys"));
    d["theme"]["name"] = Value::Null;
    d["theme"].as_object_mut().map(|o| o.remove("name"));
    d
}

/// The JSON Schema of `config.toml`, as committed in `spec/config.schema.json`.
pub fn schema_json() -> Value {
    let mut doc = config_schema::schema_document(&schema_defaults());
    if let Some(ct) = doc.pointer_mut("/$defs/custom_theme") {
        ct["required"] = json!(["extends"]);
    }
    doc
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env() -> Env {
        Env::new(Platform::Linux)
    }

    fn ok(user: Value) -> Effective {
        let v = validate(&user, &env(), &Themes::new());
        assert!(v.issues.is_empty(), "{:?}", v.issues);
        v.effective.unwrap()
    }

    fn bad(user: Value) -> Vec<Issue> {
        let v = validate(&user, &env(), &Themes::new());
        assert!(v.effective.is_none());
        v.issues
    }

    #[test]
    fn the_defaults_are_valid_and_the_linux_keys_are_the_ones_that_ship() {
        let e = ok(json!({}));
        assert_eq!(e.bindings.len(), 29);
        let find = |chord: &str| {
            e.bindings
                .iter()
                .find(|b| b.spelling == chord)
                .map(|b| b.text.clone())
        };
        assert_eq!(find("mod+3").as_deref(), Some("switch 3"));
        assert_eq!(find("mod+shift+9").as_deref(), Some("move 9"));
        assert_eq!(find("mod+shift+alt+5").as_deref(), Some("move 5 --stay"));
        assert_eq!(find("mod+tab").as_deref(), Some("overview"));
        assert_eq!(find("mod+grave").as_deref(), Some("agent-workspace toggle"));
        assert_eq!(e.doc["keys"]["mod"], "super");
        // The same tree validates against its own schema.
        let mut issues = vec![];
        check(&config_schema::schema(), &e.doc, &mut vec![], &mut issues);
        assert!(issues.is_empty(), "{issues:?}");
    }

    #[test]
    fn defaults_validate_on_every_platform_and_every_theme_against_the_token_schema() {
        for p in [Platform::Macos, Platform::Linux, Platform::Windows] {
            let mut env = Env::new(p);
            for omarchy in [false, true] {
                env.omarchy = omarchy;
                let v = validate(&json!({}), &env, &Themes::new());
                assert!(v.issues.is_empty(), "{}: {:?}", p.name(), v.issues);
            }
        }
        let b = builtin();
        for (name, t) in b["themes"].as_object().unwrap() {
            let mut sub = vec![];
            let tok: Value = Value::Object(
                token_keys()
                    .into_iter()
                    .filter_map(|k| t.get(k).map(|v| (k.to_string(), v.clone())))
                    .collect(),
            );
            check(
                &config_schema::custom_theme_node(),
                &tok,
                &mut vec![],
                &mut sub,
            );
            assert!(sub.is_empty(), "{name}: {sub:?}");
        }
    }

    #[test]
    fn a_user_binding_replaces_the_default_with_the_same_chord_however_it_is_spelled() {
        let e = ok(
            json!({ "keys": { "bindings": { "super+1": "exec foot", "mod+h": "none", "mod+tab": "none" } } }),
        );
        assert!(e.bindings.iter().all(|b| b.spelling != "mod+1"));
        assert_eq!(
            e.bindings
                .iter()
                .find(|b| b.spelling == "super+1")
                .unwrap()
                .text,
            "exec foot"
        );
        assert_eq!(e.bindings.len(), 28, "mod+1 replaced, mod+tab removed, mod+h had nothing to unbind");
    }

    #[test]
    fn the_recovery_chord_cannot_be_bound_or_removed() {
        for c in [
            "super+shift+escape",
            "mod+shift+escape",
            "shift+cmd+escape",
            "win+shift+escape",
        ] {
            for action in ["exec true", "none", "switch 1"] {
                let i = bad(json!({ "keys": { "bindings": { c: action } } }));
                assert!(
                    i.iter().any(|x| x.code == "reserved_chord"
                        && x.path == format!("keys.bindings.\"{c}\"")),
                    "{c} {action}: {i:?}"
                );
            }
        }
        let i =
            bad(json!({ "keys": { "modes": { "m": { "super+shift+escape": "mode default" } } } }));
        assert!(i.iter().any(|x| x.code == "reserved_chord"), "{i:?}");
        // The chord with another modifier added is a different chord.
        ok(json!({ "keys": { "bindings": { "super+shift+ctrl+escape": "exec true" } } }));
    }

    #[test]
    fn removing_every_workspace_switch_is_refused() {
        let mut none = Map::new();
        for n in 1..=9 {
            none.insert(format!("mod+{n}"), json!("none"));
        }
        let i = bad(json!({ "keys": { "bindings": none.clone() } }));
        assert_eq!(i.len(), 1, "{i:?}");
        assert_eq!(i[0].code, "lockout");
        assert_eq!(i[0].path, "keys.bindings");
        // One switch left, under another chord, is enough.
        let mut some = none;
        some.insert("mod+1".into(), json!("switch 1"));
        ok(json!({ "keys": { "bindings": some } }));
        // A switch inside a mode that a binding enters counts.
        let mut via_mode = Map::new();
        for n in 1..=9 {
            via_mode.insert(format!("mod+{n}"), json!("none"));
        }
        via_mode.insert("mod+m".into(), json!("mode nav"));
        ok(json!({ "keys": { "bindings": via_mode, "modes": { "nav": { "1": "switch 1" } } } }));
    }

    #[test]
    fn chords_actions_and_modes_are_checked_with_paths() {
        let i = bad(
            json!({ "keys": { "bindings": { "Mod+1": "switch 1", "mod+nokey": "switch 2", "mod+x": "launch", "1": "switch 3", "mod+y": "mode nowhere", "mod+j": "switch 12" } } }),
        );
        let at = |p: &str| {
            i.iter()
                .find(|x| x.path == p)
                .unwrap_or_else(|| panic!("{p} not in {i:?}"))
        };
        assert_eq!(at("keys.bindings.\"Mod+1\"").code, "bad_chord");
        assert_eq!(at("keys.bindings.\"mod+nokey\"").code, "bad_chord");
        assert_eq!(at("keys.bindings.\"mod+x\"").code, "bad_action");
        assert!(at("keys.bindings.1")
            .reason
            .contains("needs at least one modifier"));
        assert!(at("keys.bindings.\"mod+y\"").reason.contains("not defined"));
        assert!(at("keys.bindings.\"mod+j\"").reason.contains("1 to 9"));
        let dup =
            bad(json!({ "keys": { "bindings": { "mod+r": "exec a", "super+r": "exec b" } } }));
        assert!(dup.iter().any(|x| x.code == "duplicate_chord"), "{dup:?}");
    }

    #[test]
    fn a_mode_always_has_a_way_out() {
        let e = ok(json!({ "keys": { "modes": { "resize": { "h": "window resize -40 0" } } } }));
        let m = &e.modes["resize"];
        assert!(m
            .iter()
            .any(|b| b.spelling == "escape" && b.action == Action::Mode("default".into())));
        let i =
            bad(json!({ "keys": { "modes": { "resize": { "escape": "window resize 1 1" } } } }));
        assert!(
            i.iter()
                .any(|x| x.code == "lockout" && x.path == "keys.modes.resize"),
            "{i:?}"
        );
        ok(
            json!({ "keys": { "modes": { "resize": { "escape": "window resize 1 1", "q": "mode default" } } } }),
        );
    }

    #[test]
    fn the_modifier_is_checked_against_the_platform() {
        let i = bad(json!({ "keys": { "mod": "cmd" } }));
        assert_eq!(i[0].path, "keys.mod");
        assert!(i[0].reason.contains("super"));
        let mut mac = Env::new(Platform::Macos);
        mac.omarchy = false;
        let v = validate(&json!({ "keys": { "mod": "ctrl" } }), &mac, &Themes::new());
        assert!(v.issues.is_empty(), "{:?}", v.issues);
        let e = v.effective.unwrap();
        assert_eq!(
            e.bindings
                .iter()
                .find(|b| b.spelling == "mod+1")
                .unwrap()
                .chord
                .canonical(Platform::Macos),
            "ctrl+1"
        );
    }

    #[test]
    fn animation_limits_and_presets() {
        let i = bad(json!({ "animation": { "dock": { "in": { "duration_ms": 1001 } } } }));
        assert!(
            i.iter()
                .any(|x| x.path == "animation.dock.in.duration_ms" && x.code == "range"),
            "{i:?}"
        );
        let i = bad(json!({ "animation": { "preset": "omarchy", "speed": 2.6 } }));
        assert!(i.iter().any(|x| x.code == "too_long"), "{i:?}");
        let e = ok(json!({ "animation": { "preset": "omarchy" } }));
        assert_eq!(
            e.doc["animation"]["dock"]["in"],
            json!({ "curve": "bezier", "duration_ms": 400, "points": [0.23, 1.0, 0.32, 1.0] })
        );
        assert_eq!(e.doc["animation"]["workspace"]["style"], "off");
    }

    #[test]
    fn themes_extend_and_overrides_win() {
        let mut themes = Themes::new();
        themes.insert(
            "mine".into(),
            json!({ "extends": "omarchy", "radius": { "tile": 3 }, "palette": ROLES_PALETTE() }),
        );
        let env = env();
        let v = validate(
            &json!({ "theme": { "name": "mine", "override": { "radius": { "bar": 9 }, "shadow": { "radius": 5 } } } }),
            &env,
            &themes,
        );
        assert!(v.issues.is_empty(), "{:?}", v.issues);
        let eff = v.effective.unwrap();
        let r = resolved_json(&eff, &env, &themes);
        let t = &r["resolved"]["theme"];
        assert_eq!(t["chain"], json!(["omarchy", "mine"]));
        assert_eq!(
            t["tokens"]["radius"],
            json!({ "bar": 9, "tile": 3, "row": 0, "list": 0 })
        );
        assert_eq!(t["tokens"]["shadow"]["radius"], 5);
        assert_eq!(
            t["tokens"]["shadow"]["y"], 10,
            "a partial shadow is completed from the BaneySpaces theme"
        );
        assert_eq!(t["palette"]["source"], "custom");
        assert_eq!(t["palette"]["roles"]["background"], "#111111");
        // A named palette wins over the theme's own.
        let v = validate(
            &json!({ "theme": { "name": "mine", "palette": "nord" } }),
            &env,
            &themes,
        );
        let r = resolved_json(&v.effective.unwrap(), &env, &themes);
        assert_eq!(r["resolved"]["theme"]["palette"]["name"], "nord");
    }

    #[allow(non_snake_case)]
    fn ROLES_PALETTE() -> Value {
        let mut m = Map::new();
        for r in config_schema::ROLES {
            m.insert((*r).into(), json!("#111111"));
        }
        Value::Object(m)
    }

    #[test]
    fn theme_problems_name_the_theme_file() {
        let mut themes = Themes::new();
        themes.insert("a".into(), json!({ "extends": "b" }));
        themes.insert("b".into(), json!({ "extends": "a" }));
        themes.insert("c".into(), json!({ "radius": { "tile": -3 } }));
        // Themes the config does not use are warnings: they never block a change.
        let v = validate(&json!({}), &env(), &themes);
        assert!(v.issues.is_empty(), "{:?}", v.issues);
        assert!(v.warnings.iter().any(|i| i.path == "themes.a.extends"), "{:?}", v.warnings);
        assert!(v.warnings.iter().any(|i| i.path == "themes.c.radius.tile"), "{:?}", v.warnings);
        // The one in use is an error.
        let v = validate(&json!({ "theme": { "name": "c" } }), &env(), &themes);
        let at = |p: &str| v.issues.iter().any(|i| i.path == p);
        assert!(at("themes.c.radius.tile"), "{:?}", v.issues);
        assert!(at("themes.c.extends"), "{:?}", v.issues);
        assert!(at("theme.name"), "{:?}", v.issues);
        let v = validate(&json!({ "theme": { "name": "a" } }), &env(), &themes);
        assert!(v.issues.iter().any(|i| i.path == "theme.name" && i.reason.contains("circle")), "{:?}", v.issues);
        let v = validate(&json!({ "theme": { "name": "ghost" } }), &env(), &Themes::new());
        assert!(v.issues.iter().any(|i| i.path == "theme.name" && i.reason.contains("no theme named")), "{:?}", v.issues);
        let v = validate(&json!({ "theme": { "palette": "nonesuch" } }), &env(), &Themes::new());
        assert!(v.issues.iter().any(|i| i.path == "theme.palette"), "{:?}", v.issues);
    }

    #[test]
    fn rules_need_a_match_and_a_good_regex() {
        let i = bad(json!({ "rules": [{ "workspace": 2 }, { "app": "x", "title": "(" }] }));
        assert!(
            i.iter()
                .any(|x| x.path == "rules[0]" && x.code == "required"),
            "{i:?}"
        );
        assert!(
            i.iter()
                .any(|x| x.path == "rules[1].title" && x.code == "bad_regex"),
            "{i:?}"
        );
        ok(
            json!({ "rules": [{ "app": "Ghostty", "title": "^vim( |$)", "workspace": 2, "float": false }] }),
        );
    }

    #[test]
    fn auto_palette_follows_omarchy_and_falls_back() {
        let mut env = env();
        let r = resolved_json(
            &validate(&json!({}), &env, &Themes::new())
                .effective
                .unwrap(),
            &env,
            &Themes::new(),
        );
        assert_eq!(r["resolved"]["theme"]["palette"]["source"], "fallback");
        let colors = json!({ "background": "#112233", "foreground": "#FFFFFF", "accent": "#ff0000", "red": "#aa0000", "yellow": "#aaaa00", "green": "#00aa00", "muted": "#888888", "selection": "#223344" });
        env.palette_auto = palette_from_omarchy(&colors);
        assert!(env.palette_auto.is_some());
        let r = resolved_json(
            &validate(&json!({}), &env, &Themes::new())
                .effective
                .unwrap(),
            &env,
            &Themes::new(),
        );
        assert_eq!(r["resolved"]["theme"]["palette"]["source"], "auto");
        assert_eq!(
            r["resolved"]["theme"]["palette"]["roles"]["foreground"],
            "#ffffff"
        );
        assert_eq!(
            r["resolved"]["theme"]["palette"]["roles"]["surface"], "#112233",
            "falls back to background like gen-palettes.py"
        );
    }

    #[test]
    fn paths_set_get_unset() {
        let p = |s: &str| parse_path(s).unwrap();
        assert_eq!(
            p("keys.bindings.\"mod+1\""),
            vec!["keys", "bindings", "mod+1"]
        );
        assert_eq!(p("keys.bindings.mod+1"), vec!["keys", "bindings", "mod+1"]);
        assert_eq!(p("rules[0].app"), vec!["rules", "#0", "app"]);
        assert!(parse_path("a..b").is_err());
        assert!(parse_path("a[x]").is_err());
        assert!(parse_path("\"open").is_err());
        let mut v = json!({});
        set_path(&mut v, &p("animation.dock.in.duration_ms"), json!(90)).unwrap();
        set_path(&mut v, &p("rules[0].app"), json!("x")).unwrap();
        set_path(&mut v, &p("rules[1].app"), json!("y")).unwrap();
        assert!(set_path(&mut v, &p("rules[5].app"), json!("z")).is_err());
        assert_eq!(get_path(&v, &p("rules[1].app")), Some(&json!("y")));
        assert!(unset_path(&mut v, &p("animation.dock.in.duration_ms")));
        assert!(
            v.get("animation").is_none(),
            "empty tables are dropped: {v}"
        );
        assert!(!unset_path(&mut v, &p("animation.speed")));
    }

    #[test]
    fn the_file_round_trips_through_toml() {
        let doc = json!({ "keys": { "bindings": { "mod+1": "switch 1", "mod+h": "none" } }, "animation": { "speed": 1.5, "dock": { "in": { "duration_ms": 90 } } }, "rules": [{ "app": "Ghostty", "workspace": 2 }], "behavior": { "workspace_names": { "1": "Main" } } });
        let text = to_toml(&doc);
        assert_eq!(parse_document(&text).unwrap(), doc, "{text}");
        assert_eq!(
            parse_document(&serde_json::to_string(&doc).unwrap()).unwrap(),
            doc
        );
        assert!(parse_document("[keys").is_err());
        assert!(parse_document("[[x]\n")
            .unwrap_err()
            .reason
            .contains("TOML"));
        assert_eq!(to_toml(&json!({ "keys": {} })), "");
    }

    #[test]
    fn the_committed_schema_is_what_the_code_generates() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../spec/config.schema.json");
        let want = serde_json::to_string_pretty(&schema_json()).unwrap() + "\n";
        if std::env::var("UPDATE_SPEC").is_ok() {
            std::fs::write(path, &want).unwrap();
        }
        assert_eq!(
            std::fs::read_to_string(path).expect("spec/config.schema.json"),
            want,
            "regenerate with: UPDATE_SPEC=1 cargo test -p baneyspaces-core"
        );
    }

    #[test]
    fn every_setting_in_the_schema_is_in_the_defaults_or_documented_optional() {
        // A platform that reads a key the schema doesn't define, or ignores one it does, fails: the
        // keys with no default are the ones that start empty or come from a preset.
        let optional: &[&str] = &[
            "theme.override",
            "animation.dock",
            "animation.list",
            "animation.row",
            "animation.hover",
            "animation.drag_lift",
            "animation.overview",
            "animation.switcher",
            "animation.launcher",
            "animation.hud",
            "animation.cursor",
            "animation.workspace",
            "animation.border",
        ];
        let d = defaults(&env());
        fn walk(
            node: &config_schema::Node,
            path: &mut Vec<String>,
            d: &Value,
            optional: &[&str],
            missing: &mut Vec<String>,
        ) {
            if let config_schema::Kind::Object(fields) = &node.kind {
                for (k, child) in fields {
                    path.push(k.clone());
                    let dotted = path.join(".");
                    match d.get(k) {
                        Some(_) if dotted == "theme.override" => {}
                        Some(v) => walk(child, path, v, optional, missing),
                        None if optional.contains(&dotted.as_str()) => {}
                        None => missing.push(dotted),
                    }
                    path.pop();
                }
            }
        }
        let mut missing = vec![];
        walk(
            &config_schema::schema(),
            &mut vec![],
            &d,
            optional,
            &mut missing,
        );
        assert!(missing.is_empty(), "settings with no default: {missing:?}");
    }
}
