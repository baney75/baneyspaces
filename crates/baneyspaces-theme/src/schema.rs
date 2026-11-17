//! The JSON Schema for a theme file, built from the same tables the checker uses, so the two
//! cannot drift. Every field has a plain description of what it controls and where it shows.

use super::{fields, Kind, MODES, SECTIONS, SURFACES};
use serde_json::{json, Map, Value as Json};

/// What a field controls and where it shows. Empty means "missing"; a test fails on that.
/// `path` is `name`, `title`, `description`, `extends`, a section (`light`), a surface
/// (`surface.site`), a color role (`color.accent`), or `section.key` (`shape.radius`).
pub(super) fn describe(path: &str) -> &'static str {
    match path {
        "name" => "The theme's id. Lowercase letters, digits and hyphens, up to 48, not starting with a hyphen. Used in commands like `theme set <name>` and as the file name. A built-in theme's name is refused.",
        "title" => "The theme's display name, shown in lists and settings. Required unless a theme in `extends` has one.",
        "description" => "One line about the theme, shown under the title in `theme list` and settings. Optional.",
        "extends" => "The name of one other theme (built-in or yours) to start from. Fields you set replace the same fields there; everything else carries over. Up to 8 deep, no loops.",
        "light" => "Colors used when the product is in light mode. Each is \"#rrggbb\".",
        "dark" => "Colors used when the product is in dark mode. Each is \"#rrggbb\".",
        "shape" => "Corners, borders, blur, shadow, spacing and how workspace status is drawn. Same in light and dark.",
        "type" => "Fonts and text size. Same in light and dark.",
        "motion" => "How long things take to move and how they ease. Same in light and dark.",
        "surface" => "Changes for one product only. Each product named here gets the theme with these sections merged over it. Use this when only one product should look different.",
        "surface.spaces" => "Overrides for Polycarp Spaces: the workspace bar, the dock and its tiles.",
        "surface.voice" => "Overrides for Silas: the dictation overlay and its settings window.",
        "surface.browser" => "Overrides for Tabkyra: the browser side panel, chat and permission prompts.",
        "surface.site" => "Overrides for the Polycarp website.",
        "color.background" => "The page itself: the window behind everything, the bar, the side panel body and the website page.",
        "color.surface" => "Cards and panels that sit on the background: settings groups, chat replies, the permission prompt, menus and dialogs.",
        "color.sunken" => "Recessed areas inside a surface: text inputs, code blocks, switch tracks and idle workspace tiles.",
        "color.foreground" => "Normal text: body copy, labels and chat messages. Read on background, surface, sunken and selection.",
        "color.strong" => "Headings, window titles, workspace names and anything emphasized. Read on background, surface, sunken and selection.",
        "color.muted" => "Quiet text: hints, captions, timestamps, line numbers and disabled labels. Still must read on background, surface and sunken.",
        "color.border" => "Lines and outlines: dividers, input and card edges, idle indicators. Not checked for contrast.",
        "color.accent" => "The brand color: primary buttons, the selected workspace's edge, links, focus rings, switches that are on and the user's chat bubble. Also drawn as text on background and surface, so it needs 4.5 there. On sunken it is only an indicator, so it needs 3.0 and is never drawn as text.",
        "color.on_accent" => "Text and icons drawn on top of the accent color, such as a primary button's label or the user's chat text. Needs 4.5 on accent.",
        "color.selection" => "Background of selected things: the active workspace tile, the chosen row in a list and highlighted text. Foreground and strong text must read on it (4.5).",
        "color.urgent" => "Status color for what needs the person now: errors, permission prompts, delete confirmations, an urgent workspace. Drawn as text on background and surface, so it needs 4.5 there. On sunken it is only an indicator (a dot, bar or edge), so it needs 3.0 and is never drawn as text.",
        "color.working" => "Status color for work in progress: an agent running, dictation listening, loading, a busy workspace. Drawn as text on background and surface, so it needs 4.5 there. On sunken it is only an indicator (a dot, bar or edge), so it needs 3.0 and is never drawn as text.",
        "color.done" => "Status color for finished work: saved, completed, connected, a finished workspace. Drawn as text on background and surface, so it needs 4.5 there. On sunken it is only an indicator (a dot, bar or edge), so it needs 3.0 and is never drawn as text.",
        "shape.radius_small" => "Corner radius in px for small parts: keycaps, code spans, tags and the number block in a workspace indicator.",
        "shape.radius" => "Corner radius in px for everyday controls: buttons, text inputs, workspace tiles, menus and chat bubbles. 0 is square.",
        "shape.radius_large" => "Corner radius in px for big containers: cards, panels, the dictation overlay and dialogs. 0 is square.",
        "shape.border_width" => "Thickness in px of borders on cards, inputs and buttons. 0 removes them.",
        "shape.blur" => "Backdrop blur in px behind floating panels such as the dictation overlay and the dock. 0 is a plain solid panel.",
        "shape.shadow" => "Opacity of the drop shadow under floating things (overlay, dialogs, menus). 0 is flat, 1 is heavy.",
        "shape.density" => "How tight spacing is. Changes padding and gaps in the dock, lists, forms and panels. compact fits more; spacious breathes.",
        "shape.indicator" => "How a workspace's status shows in the workspace dock and bar: dot (small circle), bar (thin line along the tile) or number-block (the workspace number in a filled block).",
        "type.display" => "Font stack for big titles and the wordmark. A CSS font-family list such as 'Georgia, serif'.",
        "type.ui" => "Font stack for buttons, labels, forms and body text. A CSS font-family list.",
        "type.mono" => "Font stack for code, keycaps, workspace numbers and shortcuts. A CSS font-family list. Use a monospace family.",
        "type.size" => "Base text size in px. Other sizes scale from it.",
        "type.weight" => "Normal text weight, 300 (light) to 800 (extra bold). Headings go heavier than this.",
        "type.line_height" => "Line height as a multiple of text size, 1.0 to 2.0. Higher is airier.",
        "motion.fast" => "Duration in ms of small changes: hover, press, focus rings.",
        "motion.normal" => "Duration in ms of everyday changes: panels sliding, fades, switches.",
        "motion.slow" => "Duration in ms of large or ambient changes: the dictation overlay appearing, the working pulse.",
        "motion.easing" => "CSS easing for all motion: ease, ease-in, ease-out, ease-in-out, linear, or cubic-bezier(a, b, c, d). The first and third numbers must be between 0 and 1.",
        "motion.scale_from" => "Size a popup or button starts from or presses to, 0.5 to 1.0. 1.0 means fade only, no scaling.",
        "motion.reduced" => "true makes every exported duration 0 (no animation). Turn on for people who need less motion.",
        _ => "",
    }
}

/// Every path `describe` must answer for. Used by the tests.
#[cfg(test)]
pub(super) fn described_paths() -> Vec<String> {
    use super::ROLES;
    let mut v: Vec<String> = [
        "name",
        "title",
        "description",
        "extends",
        "light",
        "dark",
        "shape",
        "type",
        "motion",
        "surface",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    for s in SURFACES {
        v.push(format!("surface.{s}"));
    }
    for r in ROLES {
        v.push(format!("color.{r}"));
    }
    for sec in ["shape", "type", "motion"] {
        for (k, _) in fields(sec) {
            v.push(format!("{sec}.{k}"));
        }
    }
    v
}

/// One-line statement of what a value must be. Used in schema text and in error `needs`.
pub(super) fn needs(kind: Kind) -> String {
    match kind {
        Kind::Hex => "a color like \"#rrggbb\"".into(),
        Kind::Int(lo, hi) => format!("a whole number from {lo} to {hi}"),
        Kind::Float(lo, hi) => format!("a number from {lo:?} to {hi:?}"),
        Kind::Enum(o) => format!("one of {}", o.join(", ")),
        Kind::Font => "a font stack: names separated by commas; each is plain (letters, digits, spaces, hyphens, underscores) or in matching quotes with no quote, backslash, < or /* inside".into(),
        Kind::Easing => "ease, ease-in, ease-out, ease-in-out, linear or cubic-bezier(a, b, c, d) with a and c between 0 and 1".into(),
        Kind::Bool => "true or false".into(),
    }
}

pub(super) fn kind_schema(kind: Kind) -> Json {
    match kind {
        Kind::Hex => json!({"type":"string","pattern":"^#[0-9a-fA-F]{6}$","examples":["#59693f"]}),
        Kind::Int(lo, hi) => json!({"type":"integer","minimum":lo,"maximum":hi}),
        Kind::Float(lo, hi) => json!({"type":"number","minimum":lo,"maximum":hi}),
        Kind::Enum(o) => json!({"type":"string","enum":o}),
        Kind::Font => json!({
            "type":"string","minLength":1,
            // Kept in step with `check_font` in theme.rs; a test runs samples through both.
            "pattern": r#"^(?!.*/\*)\s*(?:[\p{L}\p{N}_-][\p{L}\p{N} _-]*|"[^"'\\<\p{Cc}]*[^"'\\<\p{Cc}\s][^"'\\<\p{Cc}]*"|'[^"'\\<\p{Cc}]*[^"'\\<\p{Cc}\s][^"'\\<\p{Cc}]*')(?:\s*,\s*(?:[\p{L}\p{N}_-][\p{L}\p{N} _-]*|"[^"'\\<\p{Cc}]*[^"'\\<\p{Cc}\s][^"'\\<\p{Cc}]*"|'[^"'\\<\p{Cc}]*[^"'\\<\p{Cc}\s][^"'\\<\p{Cc}]*'))*\s*$"#,
            "examples":["Georgia, serif"]
        }),
        Kind::Easing => json!({
            "type":"string",
            // Kept in step with `check_easing` in theme.rs (which also limits the x values to 0..1).
            "pattern": r"^(?:ease|ease-in|ease-out|ease-in-out|linear|cubic-bezier\(\s*[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\s*,\s*[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\s*,\s*[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\s*,\s*[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\s*\))$",
            "examples":["ease-out","cubic-bezier(0.3, 0, 0.2, 1)"]
        }),
        Kind::Bool => json!({"type":"boolean"}),
    }
}

fn with_description(mut schema: Json, path: &str) -> Json {
    if let Some(o) = schema.as_object_mut() {
        o.insert("description".into(), json!(describe(path)));
    }
    schema
}

fn section_schema(section: &str) -> Json {
    let mut props = Map::new();
    for (key, kind) in fields(section) {
        let (desc_path, s) = if section == "light" || section == "dark" {
            (format!("color.{key}"), kind_schema(kind))
        } else {
            (format!("{section}.{key}"), kind_schema(kind))
        };
        props.insert(key.to_string(), with_description(s, &desc_path));
    }
    json!({"type":"object","properties":props,"additionalProperties":false})
}

/// A section as it appears inside a theme: `$ref` to the shared definition plus its own text.
fn section_ref(section: &str) -> Json {
    let def = if MODES.contains(&section) {
        "colors"
    } else {
        section
    };
    with_description(json!({"$ref": format!("#/$defs/{def}")}), section)
}

/// The contrast rules, as (text color, background, minimum).
pub(super) fn contrast_rules() -> Vec<(&'static str, &'static str, f64)> {
    super::pairs()
}

pub(super) fn schema() -> Json {
    let mut defs = Map::new();
    defs.insert("colors".into(), section_schema("light"));
    for sec in ["shape", "type", "motion"] {
        defs.insert(sec.into(), section_schema(sec));
    }
    defs.insert(
        "overrides".into(),
        json!({
            "type":"object",
            "description":"Any of light, dark, shape, type and motion. Only the fields you list change, for this product only.",
            "properties": SECTIONS.iter().map(|s| (s.to_string(), section_ref(s))).collect::<Map<_,_>>(),
            "additionalProperties": false
        }),
    );
    let mut surface_props = Map::new();
    for s in SURFACES {
        surface_props.insert(
            s.to_string(),
            with_description(json!({"$ref":"#/$defs/overrides"}), &format!("surface.{s}")),
        );
    }
    let mut props = Map::new();
    props.insert(
        "name".into(),
        with_description(
            json!({"type":"string","pattern":"^[a-z0-9][a-z0-9-]*$","maxLength":48}),
            "name",
        ),
    );
    props.insert(
        "title".into(),
        with_description(json!({"type":"string","minLength":1}), "title"),
    );
    props.insert(
        "description".into(),
        with_description(json!({"type":"string"}), "description"),
    );
    props.insert(
        "extends".into(),
        with_description(
            json!({"type":"string","pattern":"^[a-z0-9][a-z0-9-]*$","maxLength":48}),
            "extends",
        ),
    );
    for sec in SECTIONS {
        props.insert(sec.to_string(), section_ref(sec));
    }
    props.insert(
        "surface".into(),
        with_description(
            json!({"type":"object","properties":surface_props,"additionalProperties":false}),
            "surface",
        ),
    );
    let rules: Vec<Json> = contrast_rules()
        .into_iter()
        .map(|(fg, bg, min)| {
            json!({
                "text": format!("{fg} on {bg}: contrast at least {min:?}"),
                "foreground": fg, "background": bg, "minimum": min,
                "applies_to": "light and dark, for the theme and for every product after merging"
            })
        })
        .collect();
    json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "Polycarp theme",
        "description": "A Polycarp theme: the colors, shape, type and motion of every Polycarp product and the website. \
            A theme is complete when, after `extends`, it has every field. Set `extends` and list only what changes. \
            Contrast is checked with the WCAG formula, for light and dark, for the theme and for each product after \
            merging: foreground, strong and muted on background, surface and sunken need 4.5; foreground and strong on \
            selection need 4.5; urgent, working, done and accent on background and surface need 4.5, because they are \
            used as text; on_accent on accent needs 4.5; urgent, working, done and accent on sunken need 3.0, for \
            indicators; border is not checked. \
            A theme that breaks a rule is refused whole and nothing changes; read the errors (each has a path, the actual \
            ratio and the needed one) and pick better colors. Change one value with `change <path> <value>` \
            (paths like dark.accent, shape.radius, surface.site.light.accent), or send a whole theme with `apply`.",
        "type": "object",
        "required": ["name"],
        "properties": props,
        "additionalProperties": false,
        "$defs": defs,
        "x-contrast": rules,
        "x-paths": {
            "form": "<section>.<key> or surface.<product>.<section>.<key>",
            "sections": SECTIONS,
            "products": SURFACES,
            "examples": ["dark.accent", "shape.radius", "type.mono", "motion.easing", "surface.site.light.accent"]
        },
        "examples": [{
            "name": "warmer",
            "title": "Warmer",
            "extends": "polycarp",
            "light": {"background": "#fbf0e0", "surface": "#fff7ea", "sunken": "#f0e1cb", "accent": "#a4502a", "on_accent": "#fff7ea"},
            "dark": {"background": "#2f2822", "surface": "#3a322b", "sunken": "#252019", "accent": "#e3a57a", "on_accent": "#2a1a0e"}
        }]
    })
}
