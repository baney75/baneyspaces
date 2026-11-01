//! Animation presets and how a platform's final numbers come out of them (`spec/config.md`
//! Animations). `spec/animation-presets.json` is generated from this file so every platform reads
//! the same table; a test keeps the two equal.

use crate::config_schema::Issue;
use serde_json::{json, Map, Value};

/// Every surface that has a transition, as the config tree spells it (`dock.in` is the table
/// `[animation.dock.in]`).
pub const SURFACES: &[&str] = &[
    "dock.in",
    "dock.out",
    "list.in",
    "list.out",
    "row",
    "hover",
    "drag_lift",
    "overview.in",
    "overview.out",
    "overview.tile",
    "switcher.in",
    "switcher.out",
    "switcher.select",
    "launcher.in",
    "launcher.out",
    "hud.in",
    "hud.out",
    "cursor.glide",
    "workspace",
    "border",
];

pub const PRESETS: &[&str] = &["baneyspaces", "omarchy", "snappy", "smooth", "off"];

/// The longest any animation may run, after `speed`.
pub const MAX_MS: f64 = 1000.0;

#[derive(Clone, Debug, PartialEq)]
pub enum Curve {
    /// `response`: seconds to settle, roughly. `damping`: 1 is no overshoot.
    Spring {
        response: f64,
        damping: f64,
    },
    /// A cubic bezier over `duration_ms`, control points x1, y1, x2, y2.
    Bezier {
        duration_ms: u32,
        points: [f64; 4],
    },
    Linear {
        duration_ms: u32,
    },
}

impl Curve {
    /// How long it runs, in ms (a spring's settle time).
    pub fn ms(&self) -> f64 {
        match self {
            Curve::Spring { response, .. } => response * 1000.0,
            Curve::Bezier { duration_ms, .. } | Curve::Linear { duration_ms } => {
                f64::from(*duration_ms)
            }
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            Curve::Spring { .. } => "spring",
            Curve::Bezier { .. } => "bezier",
            Curve::Linear { .. } => "linear",
        }
    }

    /// The curve with every duration multiplied by `k`.
    pub fn scaled(&self, k: f64) -> Curve {
        match self {
            Curve::Spring { response, damping } => Curve::Spring {
                response: round3(response * k),
                damping: *damping,
            },
            Curve::Bezier {
                duration_ms,
                points,
            } => Curve::Bezier {
                duration_ms: (f64::from(*duration_ms) * k).round() as u32,
                points: *points,
            },
            Curve::Linear { duration_ms } => Curve::Linear {
                duration_ms: (f64::from(*duration_ms) * k).round() as u32,
            },
        }
    }

    pub fn to_value(&self) -> Value {
        match self {
            Curve::Spring { response, damping } => {
                json!({ "curve": "spring", "response": response, "damping": damping })
            }
            Curve::Bezier {
                duration_ms,
                points,
            } => json!({ "curve": "bezier", "duration_ms": duration_ms, "points": points }),
            Curve::Linear { duration_ms } => {
                json!({ "curve": "linear", "duration_ms": duration_ms })
            }
        }
    }
}

fn round3(x: f64) -> f64 {
    (x * 1000.0).round() / 1000.0
}

const QUINT: [f64; 4] = [0.23, 1.0, 0.32, 1.0];
const ALMOST_LINEAR: [f64; 4] = [0.5, 0.5, 0.75, 1.0];

fn spring(response: f64, damping: f64) -> Curve {
    Curve::Spring { response, damping }
}

/// The `baneyspaces` preset: today's macOS motion (`themes.json` baneyspaces `motion`: in 180 ms,
/// out 140, list in 140, list out 100, row 80) as springs with the same settle times. Entrances and
/// the hover and lift springs keep a little overshoot (the macOS springs are .72 and .7); exits and
/// rows are critically damped. `cursor.glide` and `border` have no macOS counterpart yet.
fn baneyspaces(surface: &str) -> Curve {
    match surface {
        "dock.in" | "overview.in" | "switcher.in" | "launcher.in" | "hud.in" | "overview.tile" => {
            spring(0.18, 0.86)
        }
        "dock.out" | "overview.out" | "switcher.out" | "launcher.out" | "hud.out" => {
            spring(0.14, 1.0)
        }
        "list.in" => spring(0.14, 0.86),
        "list.out" => spring(0.10, 1.0),
        "row" | "switcher.select" => spring(0.08, 1.0),
        "hover" => spring(0.25, 0.72),
        "drag_lift" => spring(0.20, 0.70),
        "cursor.glide" => spring(0.22, 0.90),
        "workspace" | "border" => spring(0.18, 1.0),
        other => panic!("no such surface {other}"),
    }
}

/// Omarchy's Hyprland animations (`looknfeel.lua`), Hyprland speed 1 = 100 ms. Which Omarchy leaf
/// each surface follows is in `OMARCHY_SOURCE`.
fn omarchy(surface: &str) -> Curve {
    let pop_in = Curve::Bezier {
        duration_ms: 410,
        points: QUINT,
    };
    let pop_out = Curve::Linear { duration_ms: 149 };
    let fade_in = Curve::Bezier {
        duration_ms: 173,
        points: ALMOST_LINEAR,
    };
    let fade_out = Curve::Bezier {
        duration_ms: 146,
        points: ALMOST_LINEAR,
    };
    let layers_in = Curve::Bezier {
        duration_ms: 400,
        points: QUINT,
    };
    let layers_out = Curve::Linear { duration_ms: 150 };
    match omarchy_source(surface) {
        "pop-in" => pop_in,
        "pop-out" => pop_out,
        "fade-in" => fade_in,
        "fade-out" => fade_out,
        "layers-in" => layers_in,
        "layers-out" => layers_out,
        "border" => Curve::Bezier {
            duration_ms: 539,
            points: QUINT,
        },
        other => panic!("no such Omarchy leaf {other}"),
    }
}

/// The Omarchy animation a surface follows under the `omarchy` preset.
pub fn omarchy_source(surface: &str) -> &'static str {
    match surface {
        "dock.in" | "list.in" | "overview.in" | "switcher.in" | "launcher.in" => "layers-in",
        "dock.out" | "list.out" | "overview.out" | "switcher.out" | "launcher.out" => "layers-out",
        "hud.in" | "overview.tile" | "drag_lift" | "cursor.glide" => "pop-in",
        "hud.out" => "pop-out",
        "hover" | "switcher.select" | "workspace" => "fade-in",
        "row" => "fade-out",
        "border" => "border",
        other => panic!("no such surface {other}"),
    }
}

/// A surface's curve under a preset, before the person's own settings.
pub fn preset_curve(preset: &str, surface: &str) -> Curve {
    match preset {
        "baneyspaces" => baneyspaces(surface),
        "omarchy" => omarchy(surface),
        // Every duration x 0.6, critically damped springs.
        "snappy" => match baneyspaces(surface).scaled(0.6) {
            Curve::Spring { response, .. } => spring(response, 1.0),
            c => c,
        },
        // Every duration x 1.3, damping 0.8.
        "smooth" => match baneyspaces(surface).scaled(1.3) {
            Curve::Spring { response, .. } => spring(response, 0.8),
            c => c,
        },
        "off" => Curve::Linear { duration_ms: 0 },
        other => panic!("no such preset {other}"),
    }
}

/// `spec/animation-presets.json`.
pub fn presets_document() -> Value {
    let mut presets = Map::new();
    for p in PRESETS {
        let surfaces: Map<String, Value> = SURFACES
            .iter()
            .map(|s| (s.to_string(), preset_curve(p, s).to_value()))
            .collect();
        presets.insert(p.to_string(), json!({ "surfaces": surfaces }));
    }
    let src: Map<String, Value> = SURFACES
        .iter()
        .map(|s| (s.to_string(), json!(omarchy_source(s))))
        .collect();
    json!({
        "version": 1,
        "note": "Generated from crates/baneyspaces-core/src/animation.rs (UPDATE_SPEC=1 cargo test -p baneyspaces-core). A spring's response is seconds to settle; duration_ms is milliseconds; speed multiplies both.",
        "surfaces": SURFACES,
        "workspace_style_default": "off",
        "omarchy": {
            "note": "Hyprland speed 1 = 100 ms. The leaves are Omarchy's looknfeel.lua.",
            "curves": {
                "pop-in": { "curve": "bezier", "duration_ms": 410, "points": QUINT },
                "pop-out": { "curve": "linear", "duration_ms": 149 },
                "fade-in": { "curve": "bezier", "duration_ms": 173, "points": ALMOST_LINEAR },
                "fade-out": { "curve": "bezier", "duration_ms": 146, "points": ALMOST_LINEAR },
                "layers-in": { "curve": "bezier", "duration_ms": 400, "points": QUINT },
                "layers-out": { "curve": "linear", "duration_ms": 150 },
                "border": { "curve": "bezier", "duration_ms": 539, "points": QUINT },
                "workspaces": "off"
            },
            "surface_follows": src
        },
        "presets": presets
    })
}

/// One surface's table in the user's document: `animation.dock.in` is `doc["dock"]["in"]`.
fn user_entry<'a>(anim: &'a Value, surface: &str) -> Option<&'a Value> {
    let mut cur = anim;
    for seg in surface.split('.') {
        cur = cur.get(seg)?;
    }
    cur.is_object().then_some(cur)
}

fn points_of(v: &Value) -> Option<[f64; 4]> {
    let a = v.as_array()?;
    if a.len() != 4 {
        return None;
    }
    Some([
        a[0].as_f64()?,
        a[1].as_f64()?,
        a[2].as_f64()?,
        a[3].as_f64()?,
    ])
}

/// The user's table laid over a preset's curve. Fields that belong to another curve than the one
/// asked for are an error, so a typo is never silently ignored.
pub fn overlay(base: &Curve, user: &Value, path: &[String], issues: &mut Vec<Issue>) -> Curve {
    let has = |k: &str| user.get(k).is_some();
    let named = user.get("curve").and_then(Value::as_str);
    let fail = |issues: &mut Vec<Issue>, field: &str, curve: &str| {
        let mut p = path.to_vec();
        p.push(field.to_string());
        let own = match curve {
            "spring" => "response and damping",
            "bezier" => "duration_ms and points",
            _ => "duration_ms",
        };
        issues.push(Issue::new(
            &p,
            "wrong_curve",
            format!("{field} does not apply to a {curve} curve; a {curve} curve takes {own}"),
        ));
    };
    // Which curve: the one named, else what the fields imply, else the preset's.
    let curve = match named {
        Some(c) => c,
        None if has("response") || has("damping") => "spring",
        None if has("points") => "bezier",
        None if has("duration_ms") => match base {
            Curve::Spring { .. } => "bezier",
            b => b.name(),
        },
        None => base.name(),
    };
    for (field, belongs) in [
        ("response", curve == "spring"),
        ("damping", curve == "spring"),
        ("points", curve == "bezier"),
        ("duration_ms", curve != "spring"),
    ] {
        if has(field) && !belongs {
            fail(issues, field, curve);
        }
    }
    match curve {
        "spring" => {
            let (r0, d0) = match base {
                Curve::Spring { response, damping } => (*response, *damping),
                other => (other.ms() / 1000.0, 1.0),
            };
            Curve::Spring {
                response: user.get("response").and_then(Value::as_f64).unwrap_or(r0),
                damping: user.get("damping").and_then(Value::as_f64).unwrap_or(d0),
            }
        }
        "bezier" => {
            let (d0, p0) = match base {
                Curve::Bezier {
                    duration_ms,
                    points,
                } => (*duration_ms, *points),
                other => (other.ms().round() as u32, QUINT),
            };
            let points = user.get("points").and_then(points_of).unwrap_or(p0);
            if has("points")
                && (!(0.0..=1.0).contains(&points[0]) || !(0.0..=1.0).contains(&points[2]))
            {
                let mut p = path.to_vec();
                p.push("points".into());
                issues.push(Issue::new(
                    &p,
                    "range",
                    "the x values of a bezier (the 1st and 3rd points) must be from 0 to 1",
                ));
            }
            Curve::Bezier {
                duration_ms: user
                    .get("duration_ms")
                    .and_then(Value::as_u64)
                    .map(|d| d.min(u64::from(u32::MAX)) as u32)
                    .unwrap_or(d0),
                points,
            }
        }
        _ => Curve::Linear {
            duration_ms: user
                .get("duration_ms")
                .and_then(Value::as_u64)
                .map(|d| d.min(u64::from(u32::MAX)) as u32)
                .unwrap_or_else(|| base.ms().round() as u32),
        },
    }
}

/// Every surface's curve under the `animation` table: the preset, then the person's own settings.
/// Problems (a field for the wrong curve, a duration over 1000 ms after `speed`) go to `issues`.
pub fn resolve(anim: &Value, issues: &mut Vec<Issue>) -> Vec<(String, Curve)> {
    let preset = anim
        .get("preset")
        .and_then(Value::as_str)
        .filter(|p| PRESETS.contains(p))
        .unwrap_or("baneyspaces");
    let speed = anim.get("speed").and_then(Value::as_f64).unwrap_or(1.0);
    let mut out = vec![];
    for s in SURFACES {
        let base = preset_curve(preset, s);
        let mut path: Vec<String> = vec!["animation".into()];
        path.extend(s.split('.').map(String::from));
        let curve = match user_entry(anim, s) {
            Some(u) => overlay(&base, u, &path, issues),
            None => base,
        };
        let ms = curve.ms() * speed;
        if ms > MAX_MS + 1e-9 {
            let mut p = path.clone();
            p.push(
                match curve {
                    Curve::Spring { .. } => "response",
                    _ => "duration_ms",
                }
                .into(),
            );
            let why = if (speed - 1.0).abs() > 1e-9 {
                format!(
                    "{} ms x speed {speed} = {} ms; an animation runs at most {} ms",
                    curve.ms().round(),
                    ms.round(),
                    MAX_MS as u32
                )
            } else {
                format!(
                    "{} ms; an animation runs at most {} ms",
                    ms.round(),
                    MAX_MS as u32
                )
            };
            issues.push(Issue::new(&p, "too_long", why));
        }
        out.push((s.to_string(), curve));
    }
    out
}

/// What a UI reads: each surface with `speed` applied, and `instant` when Reduce Motion is on and
/// respected (the duration is then 0).
pub fn final_numbers(
    curves: &[(String, Curve)],
    speed: f64,
    reduce_motion: bool,
    respect: bool,
) -> Value {
    let instant_all = speed == 0.0 || (reduce_motion && respect);
    let mut m = Map::new();
    for (s, c) in curves {
        let scaled = c.scaled(speed);
        let mut v = scaled.to_value();
        let ms = if instant_all {
            0
        } else {
            scaled.ms().round() as u64
        };
        v["duration_ms"] = json!(ms);
        v["instant"] = json!(instant_all || ms == 0);
        m.insert(s.clone(), v);
    }
    Value::Object(m)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn omarchy_numbers_are_the_specs() {
        let c = |s: &str| preset_curve("omarchy", s);
        assert_eq!(
            c("hud.in"),
            Curve::Bezier {
                duration_ms: 410,
                points: [0.23, 1.0, 0.32, 1.0]
            }
        );
        assert_eq!(c("hud.out"), Curve::Linear { duration_ms: 149 });
        assert_eq!(
            c("hover"),
            Curve::Bezier {
                duration_ms: 173,
                points: [0.5, 0.5, 0.75, 1.0]
            }
        );
        assert_eq!(
            c("row"),
            Curve::Bezier {
                duration_ms: 146,
                points: [0.5, 0.5, 0.75, 1.0]
            }
        );
        assert_eq!(
            c("dock.in"),
            Curve::Bezier {
                duration_ms: 400,
                points: [0.23, 1.0, 0.32, 1.0]
            }
        );
        assert_eq!(c("dock.out"), Curve::Linear { duration_ms: 150 });
        assert_eq!(
            c("border"),
            Curve::Bezier {
                duration_ms: 539,
                points: [0.23, 1.0, 0.32, 1.0]
            }
        );
    }

    #[test]
    fn baneyspaces_settles_in_the_themes_json_times() {
        let t: Value = serde_json::from_str(include_str!("../../../spec/themes.json")).unwrap();
        let m = &t["themes"]["baneyspaces"]["motion"];
        let ms = |s: &str| preset_curve("baneyspaces", s).ms().round() as u64;
        assert_eq!(ms("dock.in"), m["in_ms"].as_u64().unwrap());
        assert_eq!(ms("dock.out"), m["out_ms"].as_u64().unwrap());
        assert_eq!(ms("list.in"), m["list_in_ms"].as_u64().unwrap());
        assert_eq!(ms("list.out"), m["list_out_ms"].as_u64().unwrap());
        assert_eq!(ms("row"), m["row_ms"].as_u64().unwrap());
        for s in SURFACES {
            assert!(
                matches!(preset_curve("baneyspaces", s), Curve::Spring { .. }),
                "{s}"
            );
        }
    }

    #[test]
    fn snappy_and_smooth_scale_the_baneyspaces_times() {
        for s in SURFACES {
            let b = preset_curve("baneyspaces", s).ms();
            assert!(
                (preset_curve("snappy", s).ms() - b * 0.6).abs() < 1.0,
                "{s}"
            );
            assert!(
                (preset_curve("smooth", s).ms() - b * 1.3).abs() < 1.0,
                "{s}"
            );
            assert!(
                matches!(preset_curve("snappy", s), Curve::Spring { damping, .. } if damping == 1.0)
            );
            assert!(
                matches!(preset_curve("smooth", s), Curve::Spring { damping, .. } if damping == 0.8)
            );
            assert_eq!(preset_curve("off", s).ms(), 0.0);
        }
    }

    #[test]
    fn nothing_in_any_preset_runs_over_a_second() {
        for p in PRESETS {
            for s in SURFACES {
                assert!(preset_curve(p, s).ms() <= MAX_MS, "{p} {s}");
            }
        }
    }

    #[test]
    fn user_settings_lie_over_the_preset() {
        let mut issues = vec![];
        let anim = json!({ "preset": "omarchy", "dock": { "in": { "duration_ms": 90 } }, "hover": { "response": 0.3 } });
        let r = resolve(&anim, &mut issues);
        assert!(issues.is_empty(), "{issues:?}");
        let get = |s: &str| r.iter().find(|(n, _)| n == s).unwrap().1.clone();
        assert_eq!(
            get("dock.in"),
            Curve::Bezier {
                duration_ms: 90,
                points: QUINT
            }
        );
        assert_eq!(
            get("hover"),
            Curve::Spring {
                response: 0.3,
                damping: 1.0
            }
        );
        assert_eq!(get("dock.out"), Curve::Linear { duration_ms: 150 });
    }

    #[test]
    fn a_field_for_the_wrong_curve_is_refused() {
        let mut issues = vec![];
        resolve(
            &json!({ "dock": { "in": { "curve": "spring", "points": [0, 0, 1, 1] } } }),
            &mut issues,
        );
        assert_eq!(issues.len(), 1);
        assert_eq!(issues[0].path, "animation.dock.in.points");
        assert_eq!(issues[0].code, "wrong_curve");
    }

    #[test]
    fn speed_can_push_a_duration_over_the_limit_and_the_path_names_it() {
        let mut issues = vec![];
        resolve(&json!({ "preset": "omarchy", "speed": 2.5 }), &mut issues);
        assert!(
            issues
                .iter()
                .any(|i| i.path == "animation.border.duration_ms"
                    && i.code == "too_long"
                    && i.reason.contains("speed 2.5")),
            "{issues:?}"
        );
        let mut ok = vec![];
        resolve(&json!({ "preset": "omarchy", "speed": 1.8 }), &mut ok);
        assert!(ok.is_empty(), "{ok:?}");
    }

    #[test]
    fn reduce_motion_and_speed_zero_make_everything_instant() {
        let curves = resolve(&json!({}), &mut vec![]);
        let v = final_numbers(&curves, 1.0, true, true);
        assert_eq!(v["dock.in"]["duration_ms"], 0);
        assert_eq!(v["dock.in"]["instant"], true);
        let v = final_numbers(&curves, 1.0, true, false);
        assert_eq!(v["dock.in"]["duration_ms"], 180);
        assert_eq!(v["dock.in"]["instant"], false);
        assert_eq!(
            final_numbers(&curves, 0.0, false, true)["hover"]["instant"],
            true
        );
        assert_eq!(
            final_numbers(&curves, 0.5, false, true)["dock.in"]["duration_ms"],
            90
        );
    }

    #[test]
    fn the_committed_presets_are_what_the_code_generates() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../spec/animation-presets.json"
        );
        let want = serde_json::to_string_pretty(&presets_document()).unwrap() + "\n";
        if std::env::var("UPDATE_SPEC").is_ok() {
            std::fs::write(path, &want).unwrap();
        }
        assert_eq!(
            std::fs::read_to_string(path).expect("spec/animation-presets.json"),
            want,
            "regenerate with: UPDATE_SPEC=1 cargo test -p baneyspaces-core"
        );
    }
}
