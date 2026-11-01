//! BaneySpaces core: the workspace model, the agent scope guard, the JSON envelope and the MCP
//! types. Pure Rust, no compositor, no I/O beyond reading spec files in the conformance runner.
//! Every non-macOS platform links this; `spec/` is the contract it implements.

pub mod action;
pub mod agent;
pub mod animation;
pub mod approvals;
pub mod chord;
pub mod config;
pub mod config_schema;
pub mod config_store;
pub mod history;
pub mod conformance;
pub mod envelope;
pub mod keymap;
pub mod mcp;
pub mod model;

pub use agent::{check_scope, ActionLog, ActionRecord, Refusal, WindowFacts};
pub use envelope::{Envelope, ErrorBody, Retry};
pub use model::{Cause, Effect, Event, Home, Model, ModelError};
