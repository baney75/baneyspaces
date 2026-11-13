# CLI

One command family on every platform. Every command prints one envelope ([envelope.md](envelope.md));
`--text` prints a short human line instead where one exists. Targets are a ref (`@s8f3k2p9:e8`), a
window id, or a pid.

| Command | macOS | Linux | Windows |
| --- | --- | --- | --- |
| `switch <n>` | yes | yes | yes |
| `move <n> [--stay]` | yes | yes | yes |
| `ls` | yes (session rows) | yes (windows by workspace) | yes |
| `state` | yes (`state.json`) | yes (`state.json`) | yes |
| `overview` | yes | records the request; the shell plugin shows it (part 2) | yes |
| `agent on|off` | yes | not needed (the agent workspace always exists) | yes |
| `agent-workspace show|hide|toggle` | the key | yes | yes |
| `agent status` | yes | yes | yes |
| `agent windows` | yes | yes | yes |
| `agent open <app> [file...]` | yes | yes: an allowlisted app by name, files from the handoff folder only | yes |
| `agent run [--dir D] -- CMD` | yes | yes | yes |
| `agent move <window>`, `agent bring <window>` | yes | yes | yes |
| `agent workspaces` | yes | yes (`special:agent` row, `number: null`) | not supported yet |
| `agent open ... [--new_window=false] [--wait S]` | yes | yes | not supported yet |
| `agent arrange full\|halves\|thirds\|grid [window...]`, `frames ID=x,y,w,h ...` | yes | yes | not supported yet |
| `agent move --window W [--frame x,y,w,h]` (the agent's verb; without `--window` it is yours) | yes | yes; a window that needs a lend or Full Access is `not_supported` | not supported yet |
| `agent close --window W` (only windows this session's `open` made) | yes | yes | not supported yet |
| `agent snapshot|find|get|click|set-value|type|toggle|select|scroll|shot` | yes | yes (AT-SPI) | yes (UI Automation) |
| `agent snapshot` rows: `--format rows\|json`, `--query`, `--since latest`, `--max_elements N`; a bare row number as a ref (the MCP `snapshot` tool answers rows by default) | yes | `not_supported` (JSON tree only) | `not_supported` (JSON tree only) |
| `agent press|key|pointer` | phase 3-4 | `not_supported` (part 1) | phase 3-4 |
| `agent click-at --window W --x X --y Y [--count 1\|2\|3] [--button left]` (window-local points; `count` outside 1 to 3 is `bad_arguments`; `--button right` is not available yet and answers `not_supported`) | yes | `not_supported` | `not_supported` |
| `agent log [--since SECS]` | yes | yes | yes |
| `agent lend|return` | the user only | `not_supported` (later) | the user only |
| `keys [--platform P]` | yes | yes | yes |
| `daemon` | the app | yes | the app |
| `stop` | quit the app | yes (the uninstall script uses it) | quit the app |
| `mcp` | yes | yes | yes |
| `doctor` | yes | yes | yes |

## Doctor

`doctor` prints the app's status lines. On macOS one is `polycarp_theme`: `none (...)`, or
`in force: <title> (<name>, mode <m>)` when a Polycarp theme draws instead of `appearance.theme` and
`appearance.palette` ([themes.md](themes.md), "Polycarp themes"). It needs the app running and past launch.

## State file

`state.json` is the model's `view` plus `"version": 1`, `"platform"`, `"agent_workspace"`, and, on
Linux, a top-level `"scheme"` (a one-line description of the workspace mapping). macOS: `~/Library/Application Support/BaneySpaces/state.json`.
Linux: `$XDG_STATE_HOME/baneyspaces/state.json` (default `~/.local/state/baneyspaces/`).

## Agent identity

`--agent-id ID` or `BANEYSPACES_AGENT_ID` names the caller in the action log (default `agent`).
`agent log` prints the records: agent id, verb, pid, window id, ref, route, result, refusal. It never
holds snapshot text, values, typed text or captures. Records older than 30 days are dropped.

## MCP

`baneyspaces mcp` serves [mcp-tools.json](mcp-tools.json) over stdio. There is no tool that switches,
moves or lists your workspaces.

## Global flags

`--text` and `--agent-id ID` (or `--agent-id=ID`) are read only **before** the command. After the
command every argument belongs to it (`agent find --text needle` filters by text).

## Without the daemon

On Linux `switch` and `move` (including `--stay`) fall back to Hyprland's own dispatch when the
daemon is down, so the bound keys keep working; the reply says `fallback: hyprland`. Everything else
returns `daemon_down`.
