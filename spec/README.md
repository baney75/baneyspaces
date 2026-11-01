# BaneySpaces spec

One contract keeps BaneySpaces the same product on the Mac, Linux and Windows. A behavior that is
not written here does not ship on one platform alone.

| File | What it fixes |
| --- | --- |
| [workspaces.md](workspaces.md) | The workspace rules, each with an id (`R-S1`, ...) |
| [keys.json](keys.json) | The key map per platform, and what Linux replaces in Omarchy |
| [envelope.md](envelope.md) | The JSON envelope every CLI and MCP result uses, and the error codes |
| [cli.md](cli.md) | The command family and which commands exist on which platform |
| [mcp-tools.json](mcp-tools.json) | The MCP tools, as `tools/list` returns them (generated from the Rust core) |
| [conformance/](conformance/) | Cases as JSON: inputs, the effects they must produce, the state they must leave |

## Conformance cases

A case is `{ "name", "rules": ["R-S1"], "steps": [...] }`. A step is one event, with optional
checks:

```json
{ "do": "switch", "n": 4,
  "effects": [{ "do": "show_workspace", "monitor": "A", "workspace": 4 }],
  "expect": { "monitors": { "A": { "current": 4 } } } }
```

- `do` is an event: `monitor_added`, `monitor_removed`, `open`, `close`, `switch`, `move`,
  `activate`, `focus_monitor`, `observe_workspace`, `observe_special`, `observe_focus_monitor`, `observe_move`,
  `agent_register`, `agent_exit`, `agent_show`, `agent_hide`, `agent_toggle`, `agent_send`,
  `agent_bring`. Their fields are the Rust `Event` enum in `crates/baneyspaces-core/src/model.rs`.
- `effects` is the exact, ordered list the platform must carry out: `show_workspace`,
  `focus_monitor`, `focus_window`, `move_window` (`to` is `"<monitor>:<n>"` or `"agent"`),
  `show_agent`, `hide_agent`, `refuse_follow`. Effects are idempotent; the compositor may already
  be there.
- `error` is the error code the step must fail with.
- `expect` is a subset of the state view (below). An expected `[]` also matches a missing key.
- A step with only `expect` checks state.

State view: `focused_monitor`, `active`, `monitors{id:{slot,current,last_focused}}`,
`workspaces{"<monitor>:<n>":[window,...]}` (non-empty only, oldest first),
`windows{id:{pid,app,home,agent_owned}}`, `agent{windows,shown,pids}`, `guard{refused}`.

Every rule id in workspaces.md must be named by at least one case; `cargo test` checks it.
A platform runs the cases by feeding the events to its model (Rust platforms link
`baneyspaces-core`; the macOS suite and a Windows suite read the same JSON).

Regenerate the generated files after changing the core: `UPDATE_SPEC=1 cargo test -p baneyspaces-core`.
