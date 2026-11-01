//! Agent hands: agent-desktop's Linux adapter (AT-SPI), reached through the pinned engine
//! binary, behind BaneySpaces' scope guard.
use crate::daemon::Shared;
use baneyspaces_core::envelope::{Envelope, Retry};
use serde_json::Value;

#[derive(Clone, Debug)]
pub struct SnapInfo {
    pub window: String,
    pub pid: u32,
    pub start: u64,
}

pub fn run(_shared: &Shared, _agent: &str, _args: &Value) -> Envelope {
    Envelope::err(
        "engine_missing",
        "hands are not wired yet",
        Retry::Never,
        "",
    )
}

/// Finds the pinned engine: `$BANEYSPACES_ENGINE`, `engine/` beside the binary or in the source
/// tree, or `~/.local/share/baneyspaces/engine/`.
pub fn locate() -> Option<std::path::PathBuf> {
    let mut c: Vec<std::path::PathBuf> = vec![];
    if let Ok(p) = std::env::var("BANEYSPACES_ENGINE") {
        c.push(p.into());
    }
    if let Ok(exe) = std::env::current_exe() {
        for up in exe.ancestors().skip(1).take(5) {
            c.push(up.join("engine/agent-desktop"));
            c.push(up.join("platforms/linux/engine/agent-desktop"));
        }
    }
    if let Ok(h) = std::env::var("HOME") {
        c.push(std::path::Path::new(&h).join(".local/share/baneyspaces/engine/agent-desktop"));
    }
    c.into_iter().find(|p| p.is_file())
}
