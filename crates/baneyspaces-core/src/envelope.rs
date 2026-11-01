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
    "stale_ref", "single_instance", "needs_sandbox", "bad_arguments", "window_unmatched", "timeout", "engine_missing", "engine_error", "agent_window", "no_monitor", "compositor_error", "config_invalid", "internal",
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
    fn retry_values_match_the_spec_names() {
        for (r, s) in [(Retry::Safe, "safe"), (Retry::AfterSnapshot, "after_snapshot"), (Retry::After, "after"), (Retry::Never, "never")] {
            assert_eq!(serde_json::to_value(r).unwrap(), json!(s));
        }
    }
}
