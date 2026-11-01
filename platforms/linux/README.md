# BaneySpaces for Linux (Omarchy, Hyprland)

Part 1: the workspace model, the Hyprland daemon, the agent workspace and the agent hands. No dock,
launcher or overview yet (part 2, as Omarchy shell plugins). Hyprland stays the compositor;
BaneySpaces owns what you interact with.

```
spec/                          the contract every platform implements (rules, keys, envelope, MCP, conformance cases)
crates/baneyspaces-core/       the model, the scope guard, the envelope, MCP, the conformance runner (Rust, no I/O)
platforms/linux/baneyspaces/   the `baneyspaces` binary: CLI, `daemon`, `mcp`
platforms/linux/omarchy/       the Hyprland include, the daemon's autostart, install.sh / uninstall.sh
platforms/linux/scripts/       build-engine.sh: the pinned agent-desktop, built with --locked
platforms/linux/tests/         nested.sh (the integration test), omarchy-scripts.sh, the GTK test app
```

## How BaneySpaces workspaces map onto Hyprland's

One shared pool of nine, as on the Mac: workspace n is Hyprland workspace `n`, and each display
shows one of them, never the same as another display.

| BaneySpaces | Hyprland |
| --- | --- |
| Workspace n (1-9) | workspace `n` |
| `switch n`, n shown on no display | the display you are on shows `n`: the daemon brings workspace `n` to it (`workspace.move`) if Hyprland keeps it on another monitor, then focuses it |
| `switch n`, n shown on another display | focus that display; nothing else changes |
| The agent workspace | the special workspace `special:agent` |
| Anything else (workspace 10, `special:scratchpad`, named workspaces) | not ours: never moved, never counted |

A new display shows an empty workspace nobody shows (the one it showed last, if free). An
unplugged display's workspace goes out of sight with its windows in it until you go to it; after
Hyprland hands the orphaned workspaces to another monitor, the daemon puts each remaining display
back on what it was showing. A display showing an empty, non-persistent workspace outside the nine
is given one of the nine; one showing something you keep (workspace 10 with the work dashboard) is
left alone, and a switch to 1-9 there simply takes over that display.

Switches are instant: the daemon turns the `workspaces` and `specialWorkspace` animations off
(`hl.animation`) at start and after every config reload, and the include does the same in config.

## The agent workspace

`baneyspaces agent open <app>` runs the app as its own process with `[workspace special:agent
silent]`, so it never appears on your workspace and never takes focus. The process carries a random
launch token in its environment (inherited by its children); the daemon reads it from
`/proc/<pid>/environ` when a window opens and registers the pid with its start time. That is the
isolation line, drawn by process:

- an agent acts only on a window that is on `special:agent` (Hyprland is asked every time) **and**
  whose process the daemon registered (pid and start time, so a reused pid fails);
- an app that hands the request to an instance already running opens no window of its own process:
  `single_instance`, and nothing of yours is touched;
- a window of yours that you park there (`agent move`) is guarded but not drivable (`needs_lend`);
- each ref is tied to the snapshot, window and process it came from (`stale_ref` otherwise).

The focus-follow guard ignores any activation of an agent window (and any activation caused by an
app rather than you): your previous window is put back and `guard.refused` counts it. If the agent
workspace appears without you asking, it is hidden again. Only `baneyspaces agent-workspace
show|hide|toggle` (Super+\`) shows it.

Every action appends one line to `$XDG_STATE_HOME/baneyspaces/actions.jsonl` (agent id, verb, pid,
window, ref, route, result, refusal; never content), 30 days, read with `baneyspaces agent log`.

## Agent hands

The engine is [vercel-labs/agent-desktop](https://github.com/vercel-labs/agent-desktop) at the commit
the Mac build pins (`engine.pin`, 5261b52), built from source with its own `Cargo.lock`
(`cargo build --locked`) by `scripts/build-engine.sh`, never through npm. Its Linux adapter reads and
acts through AT-SPI. The daemon runs it as a child process, headless (it is never given `--headed`,
so it posts no global input), after the scope guard, and maps its envelope onto ours. Results carry
the engine's own evidence: `verified` is true only when the engine read the outcome back from the
element. `press`, `key` and `pointer` are `not_supported` (phase 3-4). `shot` reports `not_supported`
because the engine cannot capture one window on Wayland.

## Install on an Omarchy seat (part 2 does this on Chapel1 and Parish1)

```sh
cargo build --release -p baneyspaces-linux && platforms/linux/scripts/build-engine.sh
platforms/linux/omarchy/install.sh --dry-run     # prints everything it would do
platforms/linux/omarchy/install.sh               # backs up hyprland.lua, appends one block, copies files
hyprctl reload && hyprctl configerrors
platforms/linux/omarchy/uninstall.sh             # puts hyprland.lua back byte for byte
```

Part 1 does not apply it to any seat.

## Tests

```sh
cargo test                                  # core, the 78 conformance cases, the daemon's pure parts
platforms/linux/tests/omarchy-scripts.sh    # install/uninstall against a throwaway HOME
platforms/linux/tests/nested.sh             # the integration test; prints PASS or FAIL with counts
```

`nested.sh` starts Hyprland inside its own headless host compositor (`build-host.sh`), its own D-Bus
session and AT-SPI bus, under `/tmp`, and records the real session's `hyprctl` state before and
after (it must be identical). It drives two virtual monitors, switches 1-9 on both (each shows one, never the same), opens windows,
opens apps on `special:agent`, runs the hands on a GTK4 app there, and after every agent step checks
that your front window, both monitors' workspaces, the pointer and the agent workspace's visibility
did not change.

Known limits: a key press itself is not simulated (the test runs the command each binding is bound
to, and checks the binding table); the pointer check excludes the step where the test forces
Hyprland to focus an agent window, because Hyprland warps the pointer to a window it is told to
focus; `shot` is not available on Wayland.
