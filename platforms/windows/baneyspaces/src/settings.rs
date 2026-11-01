//! The three shared settings from `spec/themes.md` (PR #112): `appearance.theme`,
//! `appearance.palette` and `dock.enabled`. Part 1 has no dock or themed UI, so this only stores
//! and returns them (`baneyspaces set|get`); the themed UI and the dock switch's effect are part 2.
//! Stored in `%LOCALAPPDATA%\BaneySpaces\settings.json`.

use serde_json::{json, Map, Value};

pub const THEMES: &[&str] = &["baneyspaces", "omarchy", "minimal"];
pub const KEYS: &[&str] = &["appearance.theme", "appearance.palette", "dock.enabled"];

/// The defaults on Windows (`spec/themes.json`, `default.windows`).
pub fn defaults() -> Map<String, Value> {
    let mut m = Map::new();
    m.insert("appearance.theme".into(), json!("baneyspaces"));
    m.insert("appearance.palette".into(), json!("auto"));
    m.insert("dock.enabled".into(), json!(true));
    m
}

/// What is stored over the defaults. A missing, damaged or out-of-range entry falls back to its default.
pub fn parse(text: &str) -> Map<String, Value> {
    let mut out = defaults();
    if let Ok(Value::Object(stored)) = serde_json::from_str::<Value>(text) {
        for k in KEYS {
            if let Some(v) = stored.get(*k) {
                if let Ok(ok) = validate(k, &value_text(v)) {
                    out.insert((*k).into(), ok);
                }
            }
        }
    }
    out
}

fn value_text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// A value for `key`, checked against the spec. The palette is `auto` or a palette's name
/// (lower case words); the names in `palettes.json` arrive with that file.
pub fn validate(key: &str, value: &str) -> Result<Value, String> {
    match key {
        "appearance.theme" => {
            let v = value.trim().to_lowercase();
            THEMES.contains(&v.as_str()).then(|| json!(v)).ok_or_else(|| format!("appearance.theme is one of {}", THEMES.join(", ")))
        }
        "appearance.palette" => {
            let v = value.trim().to_lowercase();
            let ok = !v.is_empty() && v.len() <= 64 && v.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_');
            ok.then(|| json!(v)).ok_or_else(|| "appearance.palette is \"auto\" or a palette name such as \"tokyo-night\"".to_string())
        }
        "dock.enabled" => match value.trim().to_lowercase().as_str() {
            "true" | "on" | "yes" | "1" => Ok(json!(true)),
            "false" | "off" | "no" | "0" => Ok(json!(false)),
            _ => Err("dock.enabled is true or false".into()),
        },
        _ => Err(format!("unknown setting {key:?}; the settings are {}", KEYS.join(", "))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_the_specs_windows_defaults() {
        let d = defaults();
        assert_eq!(d["appearance.theme"], "baneyspaces");
        assert_eq!(d["appearance.palette"], "auto");
        assert_eq!(d["dock.enabled"], true);
        assert_eq!(parse(""), d);
        assert_eq!(parse("not json"), d);
    }

    #[test]
    fn values_are_checked() {
        assert_eq!(validate("appearance.theme", "Omarchy").unwrap(), "omarchy");
        assert!(validate("appearance.theme", "neon").is_err());
        assert_eq!(validate("dock.enabled", "off").unwrap(), false);
        assert!(validate("dock.enabled", "maybe").is_err());
        assert_eq!(validate("appearance.palette", "tokyo-night").unwrap(), "tokyo-night");
        assert!(validate("appearance.palette", "../x").is_err());
        assert!(validate("appearance.palette", "").is_err());
        assert!(validate("nope", "x").is_err());
    }

    #[test]
    fn stored_values_override_and_bad_ones_fall_back() {
        let s = parse(r#"{"appearance.theme":"minimal","dock.enabled":false,"appearance.palette":"Bad Name!"}"#);
        assert_eq!(s["appearance.theme"], "minimal");
        assert_eq!(s["dock.enabled"], false);
        assert_eq!(s["appearance.palette"], "auto");
    }
}
