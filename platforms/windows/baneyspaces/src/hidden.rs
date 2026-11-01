//! The list of windows the daemon has hidden, kept in `state.json` so a crash cannot lose one.
//!
//! The rule: write the entry down *before* a window is hidden, take it out *after* it is shown.
//! A daemon that is killed (taskkill /F, a crash, power loss) never gets to put its windows back,
//! so the next one reads this list at start and shows every window on it. Windows of processes
//! BaneySpaces started for an agent are the exception: they belong on the agent workspace, so they
//! stay hidden when the same process (pid and start time) is still running.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// How a window was taken out of sight.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum How {
    /// The shell's cloak (`IApplicationView::SetCloak`): the window stays where it is, un-drawn.
    Cloak,
    /// Moved off every screen: the fallback when the cloak call is refused.
    Park,
    /// Fully transparent, click-through and unable to take focus, but still on screen and not
    /// cloaked. Used only for the agent workspace: the hands engine (UI Automation) skips cloaked
    /// windows, so an agent's window has to stay un-cloaked to be drivable.
    Ghost,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hidden {
    pub hwnd: i64,
    pub pid: u32,
    /// The owning process's creation time (FILETIME ticks); 0 when unknown.
    pub start: u64,
    pub how: How,
    /// Where a parked window was (left, top, right, bottom).
    #[serde(default)]
    pub rect: Option<[i32; 4]>,
    /// The window belongs to a process started for an agent.
    #[serde(default)]
    pub agent: bool,
    /// A ghosted window's extended style before we changed it, to put back.
    #[serde(default)]
    pub ex_style: Option<i64>,
}

/// An agent process BaneySpaces started, so a restarted daemon still knows it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentProc {
    pub pid: u32,
    pub start: u64,
}

#[derive(Clone, Debug, Default)]
pub struct HiddenSet {
    map: BTreeMap<i64, Hidden>,
}

impl HiddenSet {
    pub fn insert(&mut self, h: Hidden) {
        self.map.insert(h.hwnd, h);
    }
    pub fn remove(&mut self, hwnd: i64) -> Option<Hidden> {
        self.map.remove(&hwnd)
    }
    pub fn get(&self, hwnd: i64) -> Option<&Hidden> {
        self.map.get(&hwnd)
    }
    pub fn contains(&self, hwnd: i64) -> bool {
        self.map.contains_key(&hwnd)
    }
    pub fn entries(&self) -> impl Iterator<Item = &Hidden> {
        self.map.values()
    }
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::to_value(self.map.values().collect::<Vec<_>>()).unwrap_or_default()
    }
}

/// What a previous run left behind, read from `state.json`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Leftovers {
    pub hidden: Vec<Hidden>,
    pub agents: Vec<AgentProc>,
}

pub fn parse_state(text: &str) -> Leftovers {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(text) else {
        return Leftovers::default();
    };
    // One bad entry must not hide the others: parse them one by one.
    let each = |key: &str| -> Vec<serde_json::Value> { v[key].as_array().cloned().unwrap_or_default() };
    Leftovers {
        hidden: each("hidden").into_iter().filter_map(|e| serde_json::from_value(e).ok()).collect(),
        agents: each("agents").into_iter().filter_map(|e| serde_json::from_value(e).ok()).collect(),
    }
}

/// What to do with one window a previous run left hidden.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Recovery {
    /// Show it again now.
    Show(Hidden),
    /// It is an agent's window and its process still runs: it stays on the agent workspace.
    KeepOnAgent(Hidden),
    /// The window or its process is gone: nothing to do, drop the entry.
    Gone(Hidden),
}

/// `exists(h)` says the window is still there and still belongs to the process the entry names.
/// `agent_alive(pid, start)` says that process is a registered agent process that is still running.
pub fn recovery_plan(
    left: &Leftovers,
    exists: impl Fn(&Hidden) -> bool,
    agent_alive: impl Fn(u32, u64) -> bool,
) -> Vec<Recovery> {
    left.hidden
        .iter()
        .cloned()
        .map(|h| {
            if !exists(&h) {
                Recovery::Gone(h)
            } else if h.agent && left.agents.iter().any(|a| a.pid == h.pid && a.start == h.start) && agent_alive(h.pid, h.start) {
                Recovery::KeepOnAgent(h)
            } else {
                Recovery::Show(h)
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(hwnd: i64, pid: u32, agent: bool) -> Hidden {
        Hidden { hwnd, pid, start: 7, how: How::Cloak, rect: None, agent, ex_style: None }
    }

    #[test]
    fn the_set_round_trips_through_state_json() {
        let mut s = HiddenSet::default();
        s.insert(h(10, 1, false));
        s.insert(Hidden { how: How::Park, rect: Some([1, 2, 3, 4]), ..h(11, 2, true) });
        let text = serde_json::json!({ "hidden": s.to_json(), "agents": [{"pid": 2, "start": 7}], "other": 1 }).to_string();
        let left = parse_state(&text);
        assert_eq!(left.hidden.len(), 2);
        assert_eq!(left.hidden[1].rect, Some([1, 2, 3, 4]));
        assert_eq!(left.agents, vec![AgentProc { pid: 2, start: 7 }]);
    }

    #[test]
    fn a_bad_or_missing_file_is_an_empty_list_and_a_bad_entry_costs_only_itself() {
        assert_eq!(parse_state(""), Leftovers::default());
        assert_eq!(parse_state("not json"), Leftovers::default());
        assert_eq!(parse_state("{}"), Leftovers::default());
        let l = parse_state(r#"{"hidden":[{"hwnd":1},{"hwnd":2,"pid":3,"start":0,"how":"cloak"}]}"#);
        assert_eq!(l.hidden.len(), 1);
        assert_eq!(l.hidden[0].hwnd, 2);
    }

    #[test]
    fn every_hidden_window_is_shown_unless_it_is_gone_or_an_agents() {
        let left = Leftovers {
            hidden: vec![h(1, 100, false), h(2, 200, true), h(3, 300, true), h(4, 400, false)],
            agents: vec![AgentProc { pid: 200, start: 7 }, AgentProc { pid: 300, start: 7 }],
        };
        let plan = recovery_plan(&left, |x| x.hwnd != 4, |pid, _| pid == 200);
        assert_eq!(plan[0], Recovery::Show(h(1, 100, false)));
        assert_eq!(plan[1], Recovery::KeepOnAgent(h(2, 200, true)));
        // An agent's window whose process died is shown rather than lost.
        assert_eq!(plan[2], Recovery::Show(h(3, 300, true)));
        assert_eq!(plan[3], Recovery::Gone(h(4, 400, false)));
    }

    #[test]
    fn an_agent_window_with_a_different_start_time_is_not_the_agents_any_more() {
        let left = Leftovers { hidden: vec![h(2, 200, true)], agents: vec![AgentProc { pid: 200, start: 99 }] };
        assert_eq!(recovery_plan(&left, |_| true, |_, _| true), vec![Recovery::Show(h(2, 200, true))]);
    }
}
