//! Hyprland's IPC: `.socket.sock` for requests (dispatch, eval, `j/` JSON queries) and
//! `.socket2.sock` for events.

use serde_json::Value;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

/// Why a request to Hyprland failed. A refusal means Hyprland answered and said no; an I/O error
/// (a timeout, a closed socket) means the request may or may not have been carried out.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HyprError {
    Refused(String),
    Io(String),
}

impl HyprError {
    pub fn uncertain(&self) -> bool {
        matches!(self, HyprError::Io(_))
    }
}

impl std::fmt::Display for HyprError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HyprError::Refused(m) | HyprError::Io(m) => f.write_str(m),
        }
    }
}

#[derive(Clone, Debug)]
pub struct Hypr {
    dir: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HyprEvent {
    OpenWindow {
        addr: String,
    },
    CloseWindow {
        addr: String,
    },
    /// None when nothing is focused.
    ActiveWindow {
        addr: Option<String>,
    },
    MonitorAdded {
        name: String,
    },
    MonitorRemoved {
        name: String,
    },
    Workspace {
        id: i64,
    },
    MoveWindow {
        addr: String,
        ws_id: i64,
        ws_name: String,
    },
    /// The special workspace shown on a monitor; an empty name means it closed.
    ActiveSpecial {
        name: String,
        monitor: String,
    },
    FocusedMon {
        monitor: String,
    },
    ConfigReloaded,
    /// A window's title changed (Claude Code's spinner lives in it).
    WindowTitle {
        addr: String,
    },
    Other,
}

fn addr(s: &str) -> String {
    let s = s.trim();
    if s.starts_with("0x") {
        s.to_string()
    } else {
        format!("0x{s}")
    }
}

/// Parses one line of socket2: `name>>data`.
pub fn parse_event(line: &str) -> HyprEvent {
    let Some((name, data)) = line.split_once(">>") else {
        return HyprEvent::Other;
    };
    let f: Vec<&str> = data.splitn(5, ',').collect();
    let get = |i: usize| f.get(i).copied().unwrap_or("");
    match name {
        "openwindow" => HyprEvent::OpenWindow { addr: addr(get(0)) },
        "closewindow" => HyprEvent::CloseWindow { addr: addr(get(0)) },
        "activewindowv2" => HyprEvent::ActiveWindow {
            addr: if get(0).trim().is_empty() || get(0).trim() == "," {
                None
            } else {
                Some(addr(get(0)))
            },
        },
        "monitoraddedv2" => HyprEvent::MonitorAdded {
            name: get(1).to_string(),
        },
        "monitorremovedv2" => HyprEvent::MonitorRemoved {
            name: get(1).to_string(),
        },
        "workspacev2" => get(0)
            .parse()
            .map(|id| HyprEvent::Workspace { id })
            .unwrap_or(HyprEvent::Other),
        "movewindowv2" => HyprEvent::MoveWindow {
            addr: addr(get(0)),
            ws_id: get(1).parse().unwrap_or(0),
            ws_name: get(2).to_string(),
        },
        "activespecialv2" => HyprEvent::ActiveSpecial {
            name: get(1).to_string(),
            monitor: get(2).to_string(),
        },
        "focusedmon" => HyprEvent::FocusedMon {
            monitor: get(0).to_string(),
        },
        "configreloaded" => HyprEvent::ConfigReloaded,
        "windowtitlev2" => HyprEvent::WindowTitle { addr: addr(get(0)) },
        _ => HyprEvent::Other,
    }
}

impl Hypr {
    pub fn from_env() -> Result<Self, String> {
        let sig = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").map_err(|_| {
            "HYPRLAND_INSTANCE_SIGNATURE is not set: not inside a Hyprland session".to_string()
        })?;
        let run = std::env::var("XDG_RUNTIME_DIR")
            .map_err(|_| "XDG_RUNTIME_DIR is not set".to_string())?;
        let dir = PathBuf::from(run).join("hypr").join(sig);
        if !dir.join(".socket.sock").exists() {
            return Err(format!("no Hyprland socket at {}", dir.display()));
        }
        Ok(Self { dir })
    }

    /// A client for a socket directory that may not exist (tests).
    #[cfg(test)]
    pub fn at(dir: PathBuf) -> Self {
        Self { dir }
    }

    pub fn dir(&self) -> &std::path::Path {
        &self.dir
    }

    fn send(&self, cmd: &str) -> std::io::Result<String> {
        let mut s = UnixStream::connect(self.dir.join(".socket.sock"))?;
        s.set_read_timeout(Some(Duration::from_secs(3)))?;
        s.set_write_timeout(Some(Duration::from_secs(3)))?;
        s.write_all(cmd.as_bytes())?;
        s.shutdown(std::net::Shutdown::Write)?;
        let mut out = String::new();
        s.read_to_string(&mut out)?;
        Ok(out)
    }

    /// A `j/` query: `monitors`, `clients`, `workspaces`, `activewindow`, `cursorpos`, `animations`.
    pub fn json(&self, what: &str) -> Result<Value, String> {
        let raw = self
            .send(&format!("j/{what}"))
            .map_err(|e| format!("hyprland {what}: {e}"))?;
        serde_json::from_str(&raw).map_err(|e| format!("hyprland {what}: bad JSON: {e}"))
    }

    /// A Lua dispatcher such as `hl.dsp.focus({ workspace = "3" })`.
    pub fn dispatch(&self, lua: &str) -> Result<(), HyprError> {
        self.ok(&format!("/dispatch {lua}"))
    }

    /// Lua run in the compositor (`hl.workspace_rule`, `hl.animation`, `hl.config`).
    pub fn eval(&self, lua: &str) -> Result<(), HyprError> {
        self.ok(&format!("/eval {lua}"))
    }

    /// Reads the config again (what `hyprctl reload` does): puts back anything the daemon changed at runtime.
    pub fn reload(&self) -> Result<(), HyprError> {
        self.ok("/reload")
    }

    fn ok(&self, cmd: &str) -> Result<(), HyprError> {
        let r = self.send(cmd).map_err(|e| HyprError::Io(format!("hyprland: {e}")))?;
        if r.trim() == "ok" {
            Ok(())
        } else {
            Err(HyprError::Refused(format!("hyprland refused `{}`: {}", cmd.chars().take(120).collect::<String>(), r.trim())))
        }
    }

    pub fn events(&self) -> std::io::Result<UnixStream> {
        UnixStream::connect(self.dir.join(".socket2.sock"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_timeout_is_uncertain_and_a_refusal_is_not() {
        assert!(HyprError::Io("x".into()).uncertain());
        assert!(!HyprError::Refused("x".into()).uncertain());
    }

    #[test]
    fn events_parse() {
        assert_eq!(
            parse_event("openwindow>>80c9c8e0,1,foot,foot"),
            HyprEvent::OpenWindow {
                addr: "0x80c9c8e0".into()
            }
        );
        assert_eq!(
            parse_event("closewindow>>80c9c8e0"),
            HyprEvent::CloseWindow {
                addr: "0x80c9c8e0".into()
            }
        );
        assert_eq!(
            parse_event("activewindowv2>>80c9c8e0"),
            HyprEvent::ActiveWindow {
                addr: Some("0x80c9c8e0".into())
            }
        );
        assert_eq!(
            parse_event("activewindowv2>>"),
            HyprEvent::ActiveWindow { addr: None }
        );
        assert_eq!(
            parse_event("activewindowv2>>,"),
            HyprEvent::ActiveWindow { addr: None }
        );
        assert_eq!(
            parse_event("monitoraddedv2>>1,HEADLESS-2,desc here, with comma"),
            HyprEvent::MonitorAdded {
                name: "HEADLESS-2".into()
            }
        );
        assert_eq!(
            parse_event("monitorremovedv2>>1,HEADLESS-2,desc"),
            HyprEvent::MonitorRemoved {
                name: "HEADLESS-2".into()
            }
        );
        assert_eq!(
            parse_event("workspacev2>>105,105"),
            HyprEvent::Workspace { id: 105 }
        );
        assert_eq!(
            parse_event("movewindowv2>>80c9c8e0,-98,special:agent"),
            HyprEvent::MoveWindow {
                addr: "0x80c9c8e0".into(),
                ws_id: -98,
                ws_name: "special:agent".into()
            }
        );
        assert_eq!(
            parse_event("activespecialv2>>-98,special:agent,HEADLESS-1"),
            HyprEvent::ActiveSpecial {
                name: "special:agent".into(),
                monitor: "HEADLESS-1".into()
            }
        );
        assert_eq!(
            parse_event("activespecialv2>>,,HEADLESS-1"),
            HyprEvent::ActiveSpecial {
                name: String::new(),
                monitor: "HEADLESS-1".into()
            }
        );
        assert_eq!(parse_event("configreloaded>>"), HyprEvent::ConfigReloaded);
        assert_eq!(
            parse_event("windowtitlev2>>80c9c8e0,⠂ Fix the dock"),
            HyprEvent::WindowTitle {
                addr: "0x80c9c8e0".into()
            }
        );
        assert_eq!(parse_event("garbage"), HyprEvent::Other);
        assert_eq!(parse_event("urgent>>abc"), HyprEvent::Other);
    }
}
