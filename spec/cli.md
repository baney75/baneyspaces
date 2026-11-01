# CLI

One command family on every platform. Every command prints one envelope ([envelope.md](envelope.md));
`--text` prints a short human line instead where one exists. Targets are a ref (`@s8f3k2p9:e8`), a
window id, or a pid.

| Command | macOS | Linux | Windows |
| --- | --- | --- | --- |
| `switch <n>` | yes | yes | yes |
| `move <n> [--stay]` | yes | yes | yes |
| `ls` | yes (Deck rows) | yes (windows by workspace) | yes |
| `state` | yes (`state.json`) | yes (`state.json`) | yes |
| `overview` | yes | records the request; the shell plugin shows it (part 2) | yes |
| `agent on|off` | yes | not needed (the agent workspace always exists) | yes |
| `agent show|hide|toggle` | the key | yes | yes |
| `agent status` | yes | yes | yes |
| `agent windows` | yes | yes | yes |
| `agent open <app> [args...]` | yes | yes | yes |
| `agent run [--dir D] -- CMD` | yes | yes | yes |
| `agent move <window>`, `agent bring <window>` | yes | yes | yes |
| `agent snapshot|find|get|click|set-value|type|toggle|select|scroll|shot` | yes | yes (AT-SPI) | yes (UI Automation) |
| `agent press|key|pointer` | phase 3-4 | `not_supported` (part 1) | phase 3-4 |
| `agent log [--since SECS]` | yes | yes | yes |
| `agent lend|return` | the user only | `not_supported` (later) | the user only |
| `keys [--platform P]` | yes | yes | yes |
| `daemon` | the app | yes | the app |
| `mcp` | yes | yes | yes |
| `doctor` | yes | yes | yes |

## State file

`state.json` is the model's `view` plus `"version": 1`, `"platform"`, `"agent_workspace"`, and, on
Linux, `"hyprland": {"scheme": ...}`. macOS: `~/Library/Application Support/BaneySpaces/state.json`.
Linux: `$XDG_STATE_HOME/baneyspaces/state.json` (default `~/.local/state/baneyspaces/`).

## Agent identity

`--agent-id ID` or `BANEYSPACES_AGENT_ID` names the caller in the action log (default `agent`).
`agent log` prints the records: agent id, verb, pid, window id, ref, route, result, refusal. It never
holds snapshot text, values, typed text or captures. Records older than 30 days are dropped.

## MCP

`baneyspaces mcp` serves [mcp-tools.json](mcp-tools.json) over stdio. There is no tool that switches,
moves or lists your workspaces.
