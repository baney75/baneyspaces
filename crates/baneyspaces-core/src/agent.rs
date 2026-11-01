//! The agent scope guard and the action record.
//!
//! The line is drawn by process: an agent drives a process BaneySpaces started for it, in a window
//! that sits on the agent workspace. Both facts are checked on every action, by pid (with its
//! start time, so a reused pid does not pass) and by window.

use crate::envelope::{Envelope, Retry};
use crate::model::{Home, Model};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// What the platform read about one window, just before an action.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WindowFacts {
    pub window: String,
    pub pid: u32,
    /// The process start time (clock ticks since boot on Linux). 0 when unknown.
    pub pid_start: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub message: String,
    pub suggestion: String,
}

impl Refusal {
    pub fn envelope(&self) -> Envelope {
        Envelope::err(self.code, self.message.clone(), Retry::Never, self.suggestion.clone())
    }
}

/// Scope guard. An action may proceed only if the window is on the agent workspace AND its
/// process is a registered agent process (same pid, same start time).
pub fn check_scope(model: &Model, facts: &WindowFacts) -> Result<(), Refusal> {
    match model.home(&facts.window) {
        None => {
            return Err(Refusal {
                code: "not_found",
                message: format!("no window {}", facts.window),
                suggestion: "Run `baneyspaces agent status` to list the agent workspace's windows.".into(),
            })
        }
        Some(Home::Agent) => {}
        Some(Home::Workspace { .. }) => {
            return Err(Refusal {
                code: "not_in_scope",
                message: "that window is on one of your workspaces".into(),
                suggestion: "Agents act only on windows on the agent workspace. Start the app with `baneyspaces agent open`.".into(),
            })
        }
    }
    if model.pid_of(&facts.window) != Some(facts.pid) {
        return Err(Refusal {
            code: "stale_ref",
            message: "the window now belongs to a different process".into(),
            suggestion: "Take a new snapshot.".into(),
        });
    }
    match model.agent_proc(facts.pid) {
        None => Err(Refusal {
            code: "needs_lend",
            message: "BaneySpaces did not start this process for an agent".into(),
            suggestion: "Open the app with `baneyspaces agent open <app>` so it runs as its own process, or ask the user to lend it.".into(),
        }),
        Some(start) if start != 0 && facts.pid_start != 0 && start != facts.pid_start => Err(Refusal {
            code: "stale_ref",
            message: "the process id was reused by another program".into(),
            suggestion: "Take a new snapshot.".into(),
        }),
        Some(_) => Ok(()),
    }
}

/// One line of the action log. It never holds snapshot text, values, typed text or captures:
/// only who did what to which window and how it came out.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActionRecord {
    /// Seconds since the Unix epoch.
    pub at: u64,
    pub agent: String,
    pub verb: String,
    pub pid: Option<u32>,
    pub window: Option<String>,
    #[serde(rename = "ref")]
    pub reference: Option<String>,
    pub route: String,
    pub result: String,
    pub refusal: Option<String>,
    /// True when what the user sees changed while the action ran. A separate fact: it says nothing
    /// about the outcome (`result`) and is not caused by the agent unless nothing else moved.
    #[serde(default)]
    pub screen_changed: bool,
}

/// The log keeps 30 days (`RETENTION_DAYS`).
pub const RETENTION_DAYS: u64 = 30;

#[derive(Clone, Debug, Default)]
pub struct ActionLog {
    pub records: Vec<ActionRecord>,
}

impl ActionLog {
    pub fn parse(text: &str) -> Self {
        Self { records: text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect() }
    }

    /// Drops records older than 30 days. Returns how many went.
    pub fn prune(&mut self, now: u64) -> usize {
        let cutoff = now.saturating_sub(RETENTION_DAYS * 86_400);
        let before = self.records.len();
        self.records.retain(|r| r.at >= cutoff);
        before - self.records.len()
    }

    pub fn render(&self) -> String {
        self.records.iter().filter_map(|r| serde_json::to_string(r).ok()).collect::<Vec<_>>().join("\n") + if self.records.is_empty() { "" } else { "\n" }
    }
}

/// Drops records older than 30 days from the text of an action log. `None` when nothing was old
/// enough, so the caller rewrites the file only when it must.
pub fn prune_text(text: &str, now: u64) -> Option<String> {
    let mut log = ActionLog::parse(text);
    (log.prune(now) > 0).then(|| log.render())
}

/// How often the append path looks for old records (at most once an hour).
pub const PRUNE_EVERY_SECS: u64 = 3600;

impl ActionRecord {
    pub fn to_line(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }

    /// Builds a record from an envelope result without ever copying `data`.
    #[allow(clippy::too_many_arguments)]
    pub fn from_result(at: u64, agent: &str, verb: &str, pid: Option<u32>, window: Option<&str>, reference: Option<&str>, route: &str, env: &Envelope) -> Self {
        let (result, refusal) = match (&env.ok, &env.error) {
            (true, _) => ("ok".to_string(), None),
            (false, Some(e)) => (e.code.clone(), if matches!(e.code.as_str(), "not_in_scope" | "needs_lend" | "in_use" | "not_supported" | "stale_ref" | "single_instance") { Some(e.code.clone()) } else { None }),
            (false, None) => ("internal".into(), None),
        };
        Self { at, agent: agent.into(), verb: verb.into(), pid, window: window.map(String::from), reference: reference.map(String::from), route: route.into(), result, refusal, screen_changed: false }
    }
}

/// Fields a record may carry, for the test that keeps content out of the log.
pub const RECORD_FIELDS: &[&str] = &["at", "agent", "verb", "pid", "window", "ref", "route", "result", "refusal", "screen_changed"];

/// True when a JSON value is a record with exactly the allowed fields.
pub fn is_content_free(v: &Value) -> bool {
    v.as_object().is_some_and(|o| o.keys().all(|k| RECORD_FIELDS.contains(&k.as_str())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Event;
    use serde_json::json;

    fn model() -> Model {
        let mut m = Model::new();
        for e in [
            json!({"do":"monitor_added","monitor":"A"}),
            json!({"do":"agent_register","pid":500,"start":77}),
            json!({"do":"open","window":"mine","pid":100}),
            json!({"do":"open","window":"agent1","pid":500}),
            json!({"do":"open","window":"stranger","pid":600}),
            json!({"do":"agent_send","window":"stranger"}),
        ] {
            m.apply(serde_json::from_value::<Event>(e).unwrap()).unwrap();
        }
        m
    }

    fn facts(w: &str, pid: u32, start: u64) -> WindowFacts {
        WindowFacts { window: w.into(), pid, pid_start: start }
    }

    #[test]
    fn agent_process_on_agent_workspace_passes() {
        assert!(check_scope(&model(), &facts("agent1", 500, 77)).is_ok());
    }

    #[test]
    fn user_window_is_out_of_scope() {
        assert_eq!(check_scope(&model(), &facts("mine", 100, 5)).unwrap_err().code, "not_in_scope");
    }

    #[test]
    fn parked_user_window_needs_a_lend() {
        assert_eq!(check_scope(&model(), &facts("stranger", 600, 5)).unwrap_err().code, "needs_lend");
    }

    #[test]
    fn reused_pid_is_stale() {
        assert_eq!(check_scope(&model(), &facts("agent1", 500, 99)).unwrap_err().code, "stale_ref");
    }

    #[test]
    fn window_taken_over_by_another_pid_is_stale() {
        assert_eq!(check_scope(&model(), &facts("agent1", 501, 77)).unwrap_err().code, "stale_ref");
    }

    #[test]
    fn unknown_window_is_not_found() {
        assert_eq!(check_scope(&model(), &facts("nope", 1, 1)).unwrap_err().code, "not_found");
    }

    #[test]
    fn log_prunes_after_thirty_days_and_holds_no_content() {
        let day = 86_400;
        let rec = |at| ActionRecord { at, agent: "a".into(), verb: "click".into(), pid: Some(1), window: Some("w".into()), reference: Some("@s1:e2".into()), route: "atspi".into(), result: "ok".into(), refusal: None, screen_changed: false };
        let mut log = ActionLog { records: vec![rec(0), rec(31 * day), rec(40 * day)] };
        assert_eq!(log.prune(40 * day), 1);
        assert_eq!(log.records.len(), 2);
        let again = ActionLog::parse(&log.render());
        assert_eq!(again.records, log.records);
        let v: Value = serde_json::from_str(&rec(1).to_line()).unwrap();
        assert!(is_content_free(&v));
        let env = Envelope::ok(json!({"tree": "SECRET TEXT"}));
        let r = ActionRecord::from_result(1, "a", "snapshot", None, None, None, "atspi", &env);
        assert!(!r.to_line().contains("SECRET"));
    }
}
