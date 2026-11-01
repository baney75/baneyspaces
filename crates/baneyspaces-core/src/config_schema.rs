//! The schema of `config.toml`, as one tree of [`Node`]s. Three things come from this one tree, so
//! they cannot disagree: the shape check (with exact paths and reasons), the JSON Schema committed
//! as `spec/config.schema.json`, and the list of tokens a theme may set.
//!
//! Why a hand-written tree and not `schemars` on derived structs: the config is a merged JSON
//! value (defaults, then the file, then a preset), never a struct; the paths the validator reports
//! (`keys.bindings."mod+1"`, `animation.dock.in.duration_ms`) are the paths `config set` takes; and
//! `schemars` would add a proc macro and its tree to every platform's build for a schema this small.
//! A test keeps the committed schema equal to the generated one, and another checks the defaults
//! and every built-in theme against the tree.

use serde_json::{json, Map, Value};

/// What a map key must look like.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum KeyKind {
    /// Any non-empty key of at most 64 characters.
    Any,
    /// The spelling of a chord; the real check (key names, `mod`) is [`crate::chord::parse`].
    Chord,
    /// A mode or theme name.
    Name,
    /// A workspace number, `"1"` to `"9"`.
    Workspace,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StrKind {
    Free {
        max: usize,
    },
    /// `#rrggbb`.
    Color,
    /// A mode, theme or palette name, or `auto`.
    Name,
}

#[derive(Clone, Debug)]
pub enum Kind {
    Bool,
    Int(i64, i64),
    Num(f64, f64),
    Str(StrKind),
    Enum(Vec<String>),
    Const(Value),
    Array {
        items: Box<Node>,
        min: usize,
        max: usize,
    },
    /// Known keys only.
    Object(Vec<(String, Node)>),
    Map {
        key: KeyKind,
        value: Box<Node>,
        max: usize,
    },
    AnyOf(Vec<Node>),
}

#[derive(Clone, Debug)]
pub struct Node {
    pub kind: Kind,
    pub doc: String,
}

/// One problem found in a document: where, what kind, and why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Issue {
    pub path: String,
    pub code: &'static str,
    pub reason: String,
}

impl Issue {
    pub fn new(path: &[String], code: &'static str, reason: impl Into<String>) -> Self {
        Issue {
            path: path_string(path),
            code,
            reason: reason.into(),
        }
    }

    pub fn to_json(&self) -> Value {
        json!({ "path": self.path, "code": self.code, "reason": self.reason })
    }
}

/// `a.b."mod+1"`, `rules[0].app`: dots between names, quotes around a name that is not plain.
pub fn path_string(path: &[String]) -> String {
    let mut s = String::new();
    for seg in path {
        if let Some(idx) = seg.strip_prefix('#') {
            s.push_str(&format!("[{idx}]"));
            continue;
        }
        if !s.is_empty() {
            s.push('.');
        }
        if !seg.is_empty()
            && seg
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        {
            s.push_str(seg);
        } else {
            s.push_str(&format!(
                "\"{}\"",
                seg.replace('\\', "\\\\").replace('"', "\\\"")
            ));
        }
    }
    s
}

// ---- constructors ----------------------------------------------------------------------------

fn n(kind: Kind, doc: &str) -> Node {
    Node {
        kind,
        doc: doc.to_string(),
    }
}
fn boolean(doc: &str) -> Node {
    n(Kind::Bool, doc)
}
fn int(lo: i64, hi: i64, doc: &str) -> Node {
    n(Kind::Int(lo, hi), doc)
}
fn num(lo: f64, hi: f64, doc: &str) -> Node {
    n(Kind::Num(lo, hi), doc)
}
fn text(max: usize, doc: &str) -> Node {
    n(Kind::Str(StrKind::Free { max }), doc)
}
fn color(doc: &str) -> Node {
    n(Kind::Str(StrKind::Color), doc)
}
fn choice(values: &[&str], doc: &str) -> Node {
    n(
        Kind::Enum(values.iter().map(|s| s.to_string()).collect()),
        doc,
    )
}
fn object(fields: Vec<(&str, Node)>, doc: &str) -> Node {
    n(
        Kind::Object(
            fields
                .into_iter()
                .map(|(k, v)| (k.to_string(), v))
                .collect(),
        ),
        doc,
    )
}
fn map(key: KeyKind, value: Node, max: usize, doc: &str) -> Node {
    n(
        Kind::Map {
            key,
            value: Box::new(value),
            max,
        },
        doc,
    )
}

/// The palette roles, in `spec/palettes.json` order.
pub const ROLES: &[&str] = &[
    "background",
    "surface",
    "sunken",
    "foreground",
    "strong",
    "muted",
    "border",
    "accent",
    "selection",
    "urgent",
    "working",
    "done",
];

fn role(doc: &str) -> Node {
    let mut v: Vec<&str> = ROLES.to_vec();
    v.push("light");
    v.push("workspace");
    choice(&v, doc)
}

/// Every token `spec/themes.json` defines, with the range each may take.
pub fn tokens() -> Vec<(&'static str, Node)> {
    let nullable_shadow = n(
        Kind::AnyOf(vec![
            n(Kind::Const(json!(false)), "false: no shadow"),
            n(Kind::Const(Value::Null), "null: no shadow"),
            object(
                vec![
                    ("radius", num(0.0, 200.0, "blur radius")),
                    ("y", num(-200.0, 200.0, "vertical offset")),
                    ("opacity", num(0.0, 1.0, "opacity of black")),
                ],
                "a soft shadow",
            ),
        ]),
        "false (or null) for none, or {radius, y, opacity}. TOML has no null, so write false.",
    );
    let material = n(
        Kind::AnyOf(vec![
            choice(
                &["ultra-thin", "thin", "regular", "thick", "none"],
                "the platform's blur",
            ),
            n(Kind::Const(Value::Null), "null: opaque"),
        ]),
        "The platform's blur, or \"none\" (null in JSON) for an opaque fill in tint_role.",
    );
    vec![
        ("radius", object(vec![("bar", num(0.0, 200.0, "the dock bar")), ("tile", num(0.0, 200.0, "a tile")), ("row", num(0.0, 200.0, "a list row")), ("list", num(0.0, 200.0, "the +N list and window strip panel"))], "Corner radius in points.")),
        (
            "border",
            object(
                vec![
                    ("width", num(0.0, 20.0, "points")),
                    ("role", role("a palette role, or light, or workspace")),
                    ("opacity", num(0.0, 1.0, "applies to role")),
                    ("gradient", n(Kind::Array { items: Box::new(num(0.0, 1.0, "opacity")), min: 2, max: 2 }, "opacity at the top, then at the bottom")),
                    ("focused_role", role("for the current workspace, the selected row and the hovered tile")),
                    ("focused_width", num(0.0, 20.0, "points")),
                ],
                "The panel border.",
            ),
        ),
        (
            "fill",
            object(
                vec![
                    ("material", material),
                    ("tint_role", role("laid over the material")),
                    ("tint_opacity", num(0.0, 1.0, "of tint_role")),
                    ("opacity", num(0.0, 1.0, "of the whole panel")),
                    ("adjustable", boolean("Settings may change the opacity")),
                ],
                "The panel fill.",
            ),
        ),
        ("shadow", nullable_shadow),
        (
            "font",
            object(
                vec![
                    ("family", text(64, "A key into themes.json fonts (system-sans, monospace) or a font family name; the first installed family is used.")),
                    ("size", num(6.0, 72.0, "points")),
                    ("weight", choice(&["light", "regular", "medium", "semibold", "bold"], "weight")),
                ],
                "Type.",
            ),
        ),
        ("space", object(vec![("gap", num(0.0, 200.0, "between tiles")), ("padding", num(0.0, 200.0, "panel padding")), ("tile", num(8.0, 400.0, "tile size"))], "Spacing in points.")),
        ("indicator", choice(&["dot", "bar", "number-block"], "How a workspace shows in the dock, the bar module and the overview.")),
        (
            "motion",
            object(
                vec![
                    ("in_ms", int(0, 1000, "")),
                    ("out_ms", int(0, 1000, "")),
                    ("list_in_ms", int(0, 1000, "")),
                    ("list_out_ms", int(0, 1000, "")),
                    ("row_ms", int(0, 1000, "")),
                    ("scale_from", num(0.5, 1.0, "1 means no scaling")),
                    ("lift", num(1.0, 2.0, "1 means no lift")),
                ],
                "The theme's own motion tokens. The animation section decides durations; scale_from and lift are the transforms.",
            ),
        ),
    ]
}

fn tokens_object(doc: &str) -> Node {
    object(tokens().into_iter().collect(), doc)
}

/// The twelve roles of a palette, and its mode.
pub fn palette_node() -> Node {
    let mut f: Vec<(&str, Node)> = ROLES
        .iter()
        .map(|r| (*r, color(&format!("the {r} color"))))
        .collect();
    f.push(("mode", choice(&["dark", "light"], "dark or light")));
    object(f, "The twelve palette roles as #rrggbb.")
}

/// The file `themes/<name>.toml`.
pub fn custom_theme_node() -> Node {
    let mut fields: Vec<(String, Node)> = vec![
        (
            "extends".into(),
            n(
                Kind::Str(StrKind::Name),
                "The built-in or custom theme this one starts from. Required.",
            ),
        ),
        ("label".into(), text(64, "A name to show.")),
        ("palette".into(), palette_node()),
    ];
    fields.extend(tokens().into_iter().map(|(k, v)| (k.to_string(), v)));
    n(
        Kind::Object(fields),
        "A custom theme: extends, tokens to change, and optionally a palette.",
    )
}

/// One animation transition.
fn entry(doc: &str) -> Node {
    object(
        vec![
            (
                "curve",
                choice(&["spring", "bezier", "linear"], "spring | bezier | linear"),
            ),
            (
                "response",
                num(0.0, 1.0, "spring: seconds to settle, roughly (at most 1)"),
            ),
            ("damping", num(0.05, 3.0, "spring: 1 = no overshoot")),
            (
                "duration_ms",
                int(0, 1000, "bezier and linear: milliseconds, at most 1000"),
            ),
            (
                "points",
                n(
                    Kind::Array {
                        items: Box::new(num(-2.0, 3.0, "")),
                        min: 4,
                        max: 4,
                    },
                    "bezier control points x1, y1, x2, y2 (x in 0..1)",
                ),
            ),
        ],
        doc,
    )
}

fn workspace_entry() -> Node {
    let Kind::Object(mut f) =
        entry("The workspace transition, used only when style is not off.").kind
    else {
        unreachable!()
    };
    f.push(("style".into(), choice(&["off", "fade", "slide"], "off (the default) switches instantly; fade and slide draw over a snapshot, windows never move")));
    n(Kind::Object(f), "Workspace switches. Off by default.")
}

/// The animation surfaces as the config tree spells them (`dock.in` is the table `[animation.dock.in]`).
pub fn animation_node() -> Node {
    let group =
        |names: &[&str], doc: &str| object(names.iter().map(|k| (*k, entry(k))).collect(), doc);
    object(
        vec![
            ("preset", choice(&["baneyspaces", "omarchy", "snappy", "smooth", "off"], "The motion everything starts from.")),
            ("speed", num(0.0, 10.0, "Multiplies every duration; 0 = off, 0.5 = twice as fast. A result over 1000 ms is refused.")),
            ("respect_reduce_motion", boolean("Reduce Motion sets every duration to 0 unless this is false.")),
            ("dock", group(&["in", "out"], "The dock.")),
            ("list", group(&["in", "out"], "The +N list and window strip.")),
            ("row", entry("A list row.")),
            ("hover", entry("A tile under the pointer.")),
            ("drag_lift", entry("A dragged item lifting.")),
            ("overview", group(&["in", "out", "tile"], "The overview.")),
            ("switcher", group(&["in", "out", "select"], "The window switcher.")),
            ("launcher", group(&["in", "out"], "The launcher.")),
            ("hud", group(&["in", "out"], "The workspace HUD.")),
            ("cursor", group(&["glide"], "The agent cursor.")),
            ("workspace", workspace_entry()),
            ("border", entry("The focus border (Linux).")),
        ],
        "Animations. Every transition runs on the compositor.",
    )
}

/// The whole of `config.toml`.
pub fn schema() -> Node {
    let action = text(
        1000,
        "A baneyspaces CLI command line, or exec <command>, mode <name>, or none.",
    );
    let bindings = map(
        KeyKind::Chord,
        action.clone(),
        512,
        "Chord to action. \"none\" unbinds a default.",
    );
    let behavior_dock = object(
        vec![
            ("enabled", boolean("Same as dock.enabled in themes.md.")),
            (
                "edge",
                choice(&["bottom", "left", "right"], "Which edge reveals the dock."),
            ),
            ("reveal_ms", int(0, 5000, "Wait before the dock comes up.")),
            ("hide_ms", int(0, 10000, "Wait before the dock goes down.")),
            ("auto_hide", boolean("(Linux) false keeps the dock up and reserves its space.")),
            ("size", choice(&["small", "medium", "large"], "(Linux) the size of the tiles")),
            ("in_fullscreen", boolean("(Linux) come up over a full-screen window")),
            ("badges", boolean("(Linux) agent status on app icons")),
        ],
        "The dock.",
    );
    let rule = object(
        vec![
            ("app", text(200, "An app name or bundle id.")),
            (
                "title",
                text(500, "A regular expression the window title must match."),
            ),
            ("workspace", int(1, 9, "Send the window to this workspace.")),
            ("float", boolean("Keep the window floating.")),
        ],
        "First match wins.",
    );
    object(
        vec![
            (
                "keys",
                object(
                    vec![
                        ("mod", choice(&["cmd", "ctrl", "alt", "super", "win"], "The platform modifier. cmd, ctrl, alt on macOS; super on Linux; win, ctrl, alt on Windows.")),
                        ("bindings", bindings.clone()),
                        ("modes", map(KeyKind::Name, map(KeyKind::Chord, action, 512, "Chord to action inside the mode."), 32, "Named sets of bindings. escape leaves a mode unless it is rebound.")),
                    ],
                    "Key bindings.",
                ),
            ),
            (
                "theme",
                object(
                    vec![
                        ("name", n(Kind::Str(StrKind::Name), "A built-in theme or a file in themes/.")),
                        ("palette", n(Kind::Str(StrKind::Name), "auto, a palette in palettes.json, or a custom theme's palette.")),
                        ("override", tokens_object("Any token from themes.json, for this machine only.")),
                    ],
                    "The look.",
                ),
            ),
            ("animation", animation_node()),
            (
                "behavior",
                object(
                    vec![
                        ("follow_focus", boolean("Switch to a window's workspace when you activate it yourself.")),
                        ("new_window", choice(&["current", "app"], "current | app (where the app's other windows are)")),
                        ("workspace_names", map(KeyKind::Workspace, text(32, "a name"), 9, "Workspace number to name.")),
                        ("workspace_tints", map(KeyKind::Workspace, color("a tint"), 9, "Workspace number to #rrggbb.")),
                        ("dock", behavior_dock),
                        ("overview", object(vec![("enabled", boolean("(Linux) false turns the overview off")), ("layout", choice(&["adaptive", "grid"], "adaptive gives workspaces with windows the room")), ("empty", choice(&["compact", "full", "hidden"], "how empty workspaces show")), ("previews", choice(&["live", "icons"], "live needs screen capture permission"))], "The overview.")),
                        ("launcher", object(vec![("enabled", boolean("(Linux) false turns the launcher off")), ("files", boolean("(Linux) search files and folders in your home folder")), ("install", boolean("(Linux) offer to install and remove apps (omarchy pkg)")), ("search_engine", text(32, "(Linux) the bang trigger of the engine a plain search goes to")), ("agent", text(32, "(Linux) the bang trigger of the agent a leading ? asks"))], "The launcher (Linux).")),
                        ("switcher", object(vec![("enabled", boolean("(Linux) false turns the switcher off")), ("mode", choice(&["windows", "apps"], "what the switcher lists")), ("hold_ms", int(0, 2000, "how long a hold before it shows"))], "The window switcher.")),
                    ],
                    "Behavior.",
                ),
            ),
            ("rules", n(Kind::Array { items: Box::new(rule), min: 0, max: 200 }, "Window rules, first match wins.")),
            ("bangs", n(Kind::Array { items: Box::new(object(vec![("trigger", n(Kind::Str(StrKind::Name), "The word after ! in the launcher.")), ("name", text(64, "A name to show.")), ("url", text(500, "An http(s) address with {q} where the words go.")), ("agent", boolean("Ask an agent instead of opening a page."))], "A launcher bang.")), min: 0, max: 100 }, "(Linux) your own launcher bangs, such as !jira PROJ-1.")),
            ("hooks", object(vec![("on_switch", text(1000, "a command run as you after a workspace switch")), ("on_window_open", text(1000, "a command run as you when a window opens"))], "Commands run as you on these events, logged. Shown in Settings.")),
        ],
        "BaneySpaces configuration (spec/config.md).",
    )
}

// ---- the shape check -------------------------------------------------------------------------

fn type_name(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "a boolean",
        Value::Number(n) if n.is_i64() || n.is_u64() => "an integer",
        Value::Number(_) => "a number",
        Value::String(_) => "a string",
        Value::Array(_) => "an array",
        Value::Object(_) => "a table",
    }
}

fn is_color(s: &str) -> bool {
    s.len() == 7 && s.starts_with('#') && s[1..].chars().all(|c| c.is_ascii_hexdigit())
}

fn key_ok(kind: &KeyKind, k: &str) -> Result<(), String> {
    match kind {
        KeyKind::Any => {
            if k.is_empty() || k.len() > 64 {
                return Err("a key is 1 to 64 characters".into());
            }
        }
        KeyKind::Chord => {
            if k.is_empty() || k.len() > 64 || !k.chars().all(|c| c.is_ascii_graphic()) {
                return Err("a chord is 1 to 64 printable characters, such as \"mod+1\"".into());
            }
        }
        KeyKind::Name => {
            if !crate::action::is_name(k) {
                return Err("a name is lowercase letters, digits, - and _ (at most 32), starting with a letter or digit".into());
            }
        }
        KeyKind::Workspace => {
            if !matches!(k.parse::<u8>(), Ok(1..=9)) || k.len() != 1 {
                return Err("a workspace is a number from 1 to 9".into());
            }
        }
    }
    Ok(())
}

/// Checks `v` against `node`, pushing every problem found.
pub fn check(node: &Node, v: &Value, path: &mut Vec<String>, out: &mut Vec<Issue>) {
    match &node.kind {
        Kind::Bool => {
            if !v.is_boolean() {
                out.push(Issue::new(
                    path,
                    "type",
                    format!("expected true or false, got {}", type_name(v)),
                ));
            }
        }
        Kind::Int(lo, hi) => match v.as_i64() {
            Some(i) if i >= *lo && i <= *hi => {}
            Some(i) => out.push(Issue::new(
                path,
                "range",
                format!("{i} is out of range: it must be from {lo} to {hi}"),
            )),
            None => out.push(Issue::new(
                path,
                "type",
                format!("expected a whole number, got {}", type_name(v)),
            )),
        },
        Kind::Num(lo, hi) => match v.as_f64() {
            Some(f) if f.is_finite() && f >= *lo && f <= *hi => {}
            Some(f) => out.push(Issue::new(
                path,
                "range",
                format!("{f} is out of range: it must be from {lo} to {hi}"),
            )),
            None => out.push(Issue::new(
                path,
                "type",
                format!("expected a number, got {}", type_name(v)),
            )),
        },
        Kind::Str(k) => match v.as_str() {
            None => out.push(Issue::new(
                path,
                "type",
                format!("expected a string, got {}", type_name(v)),
            )),
            Some(s) => match k {
                StrKind::Free { max } => {
                    if s.chars().count() > *max {
                        out.push(Issue::new(
                            path,
                            "length",
                            format!("at most {max} characters (this is {})", s.chars().count()),
                        ));
                    }
                    if s.contains('\0') {
                        out.push(Issue::new(path, "value", "no NUL characters"));
                    }
                }
                StrKind::Color => {
                    if !is_color(s) {
                        out.push(Issue::new(
                            path,
                            "value",
                            format!("{s:?} is not a color: write #rrggbb"),
                        ));
                    }
                }
                StrKind::Name => {
                    if s != "auto" && !crate::action::is_name(s) {
                        out.push(Issue::new(path, "value", format!("{s:?} is not a name: lowercase letters, digits, - and _ (at most 32)")));
                    }
                }
            },
        },
        Kind::Enum(values) => match v.as_str() {
            Some(s) if values.iter().any(|x| x == s) => {}
            Some(s) => out.push(Issue::new(
                path,
                "value",
                format!("{s:?} is not one of: {}", values.join(", ")),
            )),
            None => out.push(Issue::new(
                path,
                "type",
                format!(
                    "expected one of: {} (got {})",
                    values.join(", "),
                    type_name(v)
                ),
            )),
        },
        Kind::Const(c) => {
            if v != c {
                out.push(Issue::new(path, "value", format!("expected {c}")));
            }
        }
        Kind::Array { items, min, max } => match v.as_array() {
            None => out.push(Issue::new(
                path,
                "type",
                format!("expected an array, got {}", type_name(v)),
            )),
            Some(a) => {
                if a.len() < *min || a.len() > *max {
                    out.push(Issue::new(
                        path,
                        "length",
                        if min == max {
                            format!("needs exactly {min} items (has {})", a.len())
                        } else {
                            format!("needs {min} to {max} items (has {})", a.len())
                        },
                    ));
                }
                for (i, item) in a.iter().enumerate() {
                    path.push(format!("#{i}"));
                    check(items, item, path, out);
                    path.pop();
                }
            }
        },
        Kind::Object(fields) => match v.as_object() {
            None => out.push(Issue::new(
                path,
                "type",
                format!("expected a table, got {}", type_name(v)),
            )),
            Some(o) => {
                for (k, val) in o {
                    path.push(k.clone());
                    match fields.iter().find(|(name, _)| name == k) {
                        Some((_, child)) => check(child, val, path, out),
                        None => {
                            let names: Vec<&str> = fields.iter().map(|(n, _)| n.as_str()).collect();
                            let near = nearest(k, &names);
                            let hint = near
                                .map(|n| format!(" (did you mean {n:?}?)"))
                                .unwrap_or_default();
                            out.push(Issue::new(
                                path,
                                "unknown_key",
                                format!(
                                    "no such setting{hint}; allowed here: {}",
                                    names.join(", ")
                                ),
                            ));
                        }
                    }
                    path.pop();
                }
            }
        },
        Kind::Map { key, value, max } => match v.as_object() {
            None => out.push(Issue::new(
                path,
                "type",
                format!("expected a table, got {}", type_name(v)),
            )),
            Some(o) => {
                if o.len() > *max {
                    out.push(Issue::new(
                        path,
                        "length",
                        format!("at most {max} entries (has {})", o.len()),
                    ));
                }
                for (k, val) in o {
                    path.push(k.clone());
                    if let Err(why) = key_ok(key, k) {
                        out.push(Issue::new(path, "bad_key", why));
                    } else {
                        check(value, val, path, out);
                    }
                    path.pop();
                }
            }
        },
        Kind::AnyOf(options) => {
            let mut best: Option<Vec<Issue>> = None;
            for o in options {
                let mut sub = vec![];
                check(o, v, path, &mut sub);
                if sub.is_empty() {
                    return;
                }
                if best.as_ref().is_none_or(|b| sub.len() < b.len()) {
                    best = Some(sub);
                }
            }
            // Report the closest option's problems, naming nothing the others would accept.
            out.extend(best.unwrap_or_default());
        }
    }
}

/// The allowed name closest to a misspelled one, if it is close.
pub fn nearest<'a>(word: &str, names: &[&'a str]) -> Option<&'a str> {
    fn dist(a: &str, b: &str) -> usize {
        let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
        let mut prev: Vec<usize> = (0..=b.len()).collect();
        for i in 1..=a.len() {
            let mut cur = vec![i];
            for j in 1..=b.len() {
                cur.push(
                    (prev[j] + 1)
                        .min(cur[j - 1] + 1)
                        .min(prev[j - 1] + usize::from(a[i - 1] != b[j - 1])),
                );
            }
            prev = cur;
        }
        prev[b.len()]
    }
    names
        .iter()
        .map(|n| (dist(word, n), *n))
        .filter(|(d, _)| *d <= 2.max(word.len() / 3))
        .min_by_key(|(d, _)| *d)
        .map(|(_, n)| n)
}

// ---- JSON Schema -----------------------------------------------------------------------------

/// The node as JSON Schema (draft 2020-12).
pub fn json_schema(node: &Node) -> Value {
    let mut m = Map::new();
    let doc = |m: &mut Map<String, Value>| {
        if !node.doc.is_empty() {
            m.insert("description".into(), json!(node.doc));
        }
    };
    match &node.kind {
        Kind::Bool => {
            m.insert("type".into(), json!("boolean"));
        }
        Kind::Int(lo, hi) => {
            m.insert("type".into(), json!("integer"));
            m.insert("minimum".into(), json!(lo));
            m.insert("maximum".into(), json!(hi));
        }
        Kind::Num(lo, hi) => {
            m.insert("type".into(), json!("number"));
            m.insert("minimum".into(), json!(lo));
            m.insert("maximum".into(), json!(hi));
        }
        Kind::Str(k) => {
            m.insert("type".into(), json!("string"));
            match k {
                StrKind::Free { max } => {
                    m.insert("maxLength".into(), json!(max));
                }
                StrKind::Color => {
                    m.insert("pattern".into(), json!("^#[0-9a-fA-F]{6}$"));
                }
                StrKind::Name => {
                    m.insert("pattern".into(), json!("^([a-z0-9][a-z0-9_-]{0,31}|auto)$"));
                }
            }
        }
        Kind::Enum(values) => {
            m.insert("enum".into(), json!(values));
        }
        Kind::Const(c) => {
            m.insert("const".into(), c.clone());
        }
        Kind::Array { items, min, max } => {
            m.insert("type".into(), json!("array"));
            m.insert("items".into(), json_schema(items));
            m.insert("minItems".into(), json!(min));
            m.insert("maxItems".into(), json!(max));
        }
        Kind::Object(fields) => {
            m.insert("type".into(), json!("object"));
            let props: Map<String, Value> = fields
                .iter()
                .map(|(k, v)| (k.clone(), json_schema(v)))
                .collect();
            m.insert("properties".into(), Value::Object(props));
            m.insert("additionalProperties".into(), json!(false));
        }
        Kind::Map { key, value, max } => {
            m.insert("type".into(), json!("object"));
            m.insert("additionalProperties".into(), json_schema(value));
            m.insert("maxProperties".into(), json!(max));
            let pat = match key {
                KeyKind::Any => "^.{1,64}$",
                KeyKind::Chord => "^[a-z0-9+]{1,64}$",
                KeyKind::Name => "^[a-z0-9][a-z0-9_-]{0,31}$",
                KeyKind::Workspace => "^[1-9]$",
            };
            m.insert("propertyNames".into(), json!({ "pattern": pat }));
        }
        Kind::AnyOf(options) => {
            m.insert(
                "anyOf".into(),
                Value::Array(options.iter().map(json_schema).collect()),
            );
        }
    }
    doc(&mut m);
    Value::Object(m)
}

/// The text of `spec/config.schema.json`. `defaults` is the platform-neutral default document:
/// each default is attached to its setting.
pub fn schema_document(defaults: &Value) -> Value {
    let mut root = json_schema(&schema());
    attach_defaults(&mut root, defaults);
    let o = root.as_object_mut().expect("the schema is an object");
    let mut head = Map::new();
    head.insert(
        "$schema".into(),
        json!("https://json-schema.org/draft/2020-12/schema"),
    );
    head.insert(
        "$id".into(),
        json!("https://github.com/baney75/baneyspaces/blob/main/spec/config.schema.json"),
    );
    head.insert("title".into(), json!("BaneySpaces config.toml"));
    for (k, v) in std::mem::take(o) {
        head.insert(k, v);
    }
    head.insert(
        "$defs".into(),
        json!({
            "custom_theme": json_schema(&custom_theme_node()),
            "chord": { "description": "modifiers then one key, lowercase, joined with +: mod, cmd, super, win, ctrl, alt, shift; key names are in spec/keys.json under chords.keys. Needs a modifier in keys.bindings; the recovery chord (logo+shift+escape) is never bindable.", "type": "string" },
            "action": { "description": "A baneyspaces CLI command line (spec/cli.md), exec <command>, mode <name> or none.", "type": "string" },
            "issue": { "type": "object", "required": ["path", "code", "reason"], "properties": { "path": { "type": "string" }, "code": { "type": "string" }, "reason": { "type": "string" } } }
        }),
    );
    Value::Object(head)
}

fn attach_defaults(schema: &mut Value, defaults: &Value) {
    let (Some(props), Some(d)) = (
        schema.get_mut("properties").and_then(Value::as_object_mut),
        defaults.as_object(),
    ) else {
        return;
    };
    for (k, dv) in d {
        if let Some(child) = props.get_mut(k) {
            if dv.is_object() && child.get("properties").is_some() {
                attach_defaults(child, dv);
            } else if let Some(c) = child.as_object_mut() {
                c.insert("default".into(), dv.clone());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn issues(v: Value) -> Vec<Issue> {
        let mut out = vec![];
        check(&schema(), &v, &mut vec![], &mut out);
        out
    }

    #[test]
    fn paths_are_quoted_only_when_needed() {
        let p = |s: &[&str]| path_string(&s.iter().map(|x| x.to_string()).collect::<Vec<_>>());
        assert_eq!(p(&["keys", "bindings", "mod+1"]), "keys.bindings.\"mod+1\"");
        assert_eq!(
            p(&["animation", "dock", "in", "duration_ms"]),
            "animation.dock.in.duration_ms"
        );
        assert_eq!(p(&["rules", "#0", "app"]), "rules[0].app");
    }

    #[test]
    fn a_good_document_has_no_issues() {
        assert!(issues(json!({ "keys": { "mod": "super", "bindings": { "mod+h": "none" } }, "animation": { "speed": 1.5, "dock": { "in": { "curve": "bezier", "duration_ms": 200, "points": [0.2, 1, 0.3, 1] } } }, "theme": { "override": { "shadow": false, "radius": { "tile": 4 } } }, "rules": [{ "app": "Ghostty", "workspace": 2 }] })).is_empty());
    }

    #[test]
    fn every_failure_has_an_exact_path_and_a_reason() {
        let i = issues(
            json!({ "animation": { "dock": { "in": { "duration_ms": 1200 } }, "speed": "fast" }, "keyz": 1, "behavior": { "dock": { "edge": "top" } }, "rules": [{ "workspace": 12 }] }),
        );
        let by = |p: &str| {
            i.iter()
                .find(|x| x.path == p)
                .unwrap_or_else(|| panic!("no issue at {p}: {i:?}"))
        };
        assert_eq!(by("animation.dock.in.duration_ms").code, "range");
        assert!(by("animation.dock.in.duration_ms")
            .reason
            .contains("0 to 1000"));
        assert_eq!(by("animation.speed").code, "type");
        assert_eq!(by("keyz").code, "unknown_key");
        assert!(by("keyz").reason.contains("did you mean \"keys\""));
        assert_eq!(by("behavior.dock.edge").code, "value");
        assert!(by("behavior.dock.edge")
            .reason
            .contains("bottom, left, right"));
        assert_eq!(by("rules[0].workspace").code, "range");
    }

    #[test]
    fn schema_json_has_the_same_shape() {
        let s = schema_document(&json!({}));
        assert_eq!(
            s["properties"]["animation"]["properties"]["dock"]["properties"]["in"]["properties"]
                ["duration_ms"]["maximum"],
            1000
        );
        assert_eq!(s["additionalProperties"], false);
        assert!(s["$defs"]["custom_theme"]["properties"]["extends"].is_object());
    }
}
