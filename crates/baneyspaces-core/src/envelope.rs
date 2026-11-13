//! One JSON envelope everywhere: `{ok, data}` or `{ok:false, error:{code, message, retry, suggestion}}`.
//! See `spec/envelope.md`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Whether repeating the call is safe.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Retry {
    /// Nothing was delivered; the same call can be sent again.
    Safe,
    /// Take a new snapshot first; refs from the old one no longer hold.
    AfterSnapshot,
    /// Nothing was delivered, but not yet: wait, then send it again (the daemon is re-reading the
    /// compositor, or a queue ahead of this call is full).
    After,
    /// Do not repeat: it was refused, or it may already have landed.
    Never,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
    pub retry: Retry,
    pub suggestion: String,
    /// Extra facts about the failure (windows that appeared, which step failed). Never content.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub data: Option<Value>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Envelope {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub error: Option<ErrorBody>,
}

/// Every error code the envelope may carry (`spec/envelope.md`).
pub const CODES: &[&str] = &[
    "invalid_args", "not_found", "ambiguous", "not_in_scope", "needs_lend", "in_use", "not_supported", "daemon_down",
    "stale_ref", "single_instance", "needs_sandbox", "bad_arguments", "window_unmatched", "timeout", "engine_missing", "engine_error", "agent_window", "no_monitor", "compositor_error", "internal",
];

impl Envelope {
    pub fn ok(data: Value) -> Self {
        Self { ok: true, data: Some(data), error: None }
    }

    pub fn err(code: &str, message: impl Into<String>, retry: Retry, suggestion: impl Into<String>) -> Self {
        debug_assert!(CODES.contains(&code), "unknown envelope code {code}");
        Self { ok: false, data: None, error: Some(ErrorBody { code: code.into(), message: message.into(), retry, suggestion: suggestion.into(), data: None }) }
    }

    /// Attaches facts to an error (`error.data`).
    pub fn with_data(mut self, data: Value) -> Self {
        if let Some(e) = self.error.as_mut() {
            e.data = Some(data);
        }
        self
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| r#"{"ok":false,"error":{"code":"internal","message":"unserializable","retry":"never","suggestion":""}}"#.into())
    }

    /// A model error as an envelope, with the suggestion a caller can act on.
    pub fn from_model(e: &crate::model::ModelError) -> Self {
        let (retry, suggestion) = match e.code {
            "invalid_args" => (Retry::Never, "Workspaces are numbered 1 to 9."),
            "not_found" => (Retry::Safe, "Run `baneyspaces ls` to see the windows and monitors that exist."),
            "agent_window" => (Retry::Never, "Agent windows stay on the agent workspace."),
            "no_monitor" => (Retry::Safe, "Connect a monitor, then try again."),
            _ => (Retry::Never, ""),
        };
        let code = if CODES.contains(&e.code) { e.code } else { "internal" };
        Self::err(code, e.message.clone(), retry, suggestion)
    }
}

/// A right click on a ref (`click` with `button: right`) opens a context menu, which only macOS proves and keeps on the
/// agent workspace for now. Linux and Windows refuse it rather than press the element as a left click would.
pub fn refuse_right_click(verb: &str, args: &Value) -> Option<Envelope> {
    // A button that is there but no string (`2`, `true`) is no left click either (231 r1 first-F6).
    let left = match args.get("button") {
        None | Some(Value::Null) => true,
        Some(Value::String(b)) => b.eq_ignore_ascii_case("left"),
        Some(_) => false,
    };
    if verb != "click" || (left && args.get("item").map_or(true, Value::is_null)) {
        return None;
    }
    Some(Envelope::err(
        "not_supported",
        "a right click on a ref is macOS only for now; nothing was pressed",
        Retry::Never,
        "Use click without button for the element's own action.",
    ))
}

/// `agent click|toggle <ref> [--button B] [--item I]`, `--button=B` too: the flags into `args`, the ref left in `words`.
/// A flag with no value, a flag on `toggle`, or any other `--` word is refused, never dropped: a dropped `--button=right`
/// pressed the element as a left click (231 r1 second-S2, second-S3).
pub fn click_flags(verb: &str, words: &mut Vec<String>, args: &mut Value) -> Result<(), Envelope> {
    let bad = |why: String| Envelope::err("invalid_args", why, Retry::Never, &format!("usage: agent {verb} <ref>{}", if verb == "click" { " [--button left|right] [--item <title>]" } else { "" }));
    for k in ["button", "item"] {
        let (flag, inline) = (format!("--{k}"), format!("--{k}="));
        while let Some(i) = words.iter().position(|w| *w == flag || w.starts_with(&inline)) {
            let w = words.remove(i);
            let v = match w.strip_prefix(&inline) {
                Some(v) => v.to_string(),
                None if i < words.len() && !words[i].starts_with("--") => words.remove(i),
                None => String::new(),
            };
            if verb != "click" {
                return Err(bad(format!("{verb} takes no {flag}; nothing was pressed")));
            }
            if v.is_empty() {
                return Err(bad(format!("{flag} needs a value; nothing was pressed")));
            }
            args[k] = Value::String(v);
        }
    }
    if let Some(w) = words.iter().find(|w| w.starts_with("--")) {
        return Err(bad(format!("unknown option {w}; nothing was pressed")));
    }
    refuse_right_click(verb, args).map_or(Ok(()), Err)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn flags(verb: &str, words: &[&str]) -> Result<(Vec<String>, Value), String> {
        let mut w: Vec<String> = words.iter().map(|s| s.to_string()).collect();
        let mut a = json!({});
        click_flags(verb, &mut w, &mut a).map(|_| (w, a)).map_err(|e| e.error.map(|e| e.code).unwrap_or_default())
    }

    /// 231 r1 second-S2, second-S3, first-F6: no spelling of a right click is dropped and pressed as a left click.
    #[test]
    fn a_right_click_is_never_dropped_into_a_left_click() {
        for words in [&["@s:e3", "--button=right"][..], &["@s:e3", "--button", "right"], &["--item=Rename", "@s:e3"], &["@s:e3", "--item", "Rename"]] {
            assert_eq!(flags("click", words).err().as_deref(), Some("not_supported"), "{words:?}");
        }
        for words in [&["@s:e3", "--button"][..], &["@s:e3", "--button="], &["@s:e3", "--button", "--item", "x"], &["@s:e3", "--buton=right"], &["@s:e3", "--force"]] {
            assert_eq!(flags("click", words).err().as_deref(), Some("invalid_args"), "{words:?}");
        }
        for words in [&["@s:e1", "--button", "right"][..], &["@s:e1", "--item=Rename"], &["@s:e1", "--button=left"]] {
            assert_eq!(flags("toggle", words).err().as_deref(), Some("invalid_args"), "toggle {words:?}");
        }
        let (w, a) = flags("click", &["@s:e3", "--button=left"]).unwrap();
        assert_eq!((w, a), (vec!["@s:e3".to_string()], json!({"button": "left"})));
        assert_eq!(flags("toggle", &["@s:e1"]).unwrap().0, vec!["@s:e1".to_string()]);
        for b in [json!(2), json!(true), json!(["right"])] {
            assert!(refuse_right_click("click", &json!({"ref": "@s:e3", "button": b})).is_some(), "button {b}");
        }
        assert!(refuse_right_click("click", &json!({"ref": "@s:e3", "button": null})).is_none());
    }

    #[test]
    fn ok_shape_has_no_error_key() {
        let v: Value = serde_json::from_str(&Envelope::ok(json!({"a":1})).to_json()).unwrap();
        assert_eq!(v, json!({"ok":true,"data":{"a":1}}));
    }

    #[test]
    fn error_shape_carries_code_retry_and_suggestion() {
        let v: Value = serde_json::from_str(&Envelope::err("not_in_scope", "m", Retry::Never, "s").to_json()).unwrap();
        assert_eq!(v, json!({"ok":false,"error":{"code":"not_in_scope","message":"m","retry":"never","suggestion":"s"}}));
    }

    #[test]
    fn a_right_click_on_a_ref_is_refused_never_pressed() {
        for args in [json!({"ref":"@s:e1","button":"right"}), json!({"ref":"@s:e1","button":"Right","item":"Rename"}), json!({"ref":"@s:e1","item":"Rename"}), json!({"ref":"@s:e1","button":"middle"})] {
            let e = refuse_right_click("click", &args).unwrap_or_else(|| panic!("{args}"));
            assert_eq!((e.error.as_ref().unwrap().code.as_str(), e.error.as_ref().unwrap().retry), ("not_supported", Retry::Never));
        }
        assert!(refuse_right_click("click", &json!({"ref":"@s:e1"})).is_none());
        assert!(refuse_right_click("click", &json!({"ref":"@s:e1","button":"left"})).is_none());
        assert!(refuse_right_click("toggle", &json!({"ref":"@s:e1","button":"right"})).is_none());
    }

    #[test]
    fn retry_values_match_the_spec_names() {
        for (r, s) in [(Retry::Safe, "safe"), (Retry::AfterSnapshot, "after_snapshot"), (Retry::After, "after"), (Retry::Never, "never")] {
            assert_eq!(serde_json::to_value(r).unwrap(), json!(s));
        }
    }
}
