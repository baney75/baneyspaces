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
- every pid check is start-time aware: the daemon forgets an agent process when it dies or its pid
  is reused (on each window that opens and every 2 s), so a recycled pid is never an agent;
- **deny by default, and the app is a name.** `agent open <app> [file...]` takes the *name* of an app
  on the short allowlist (terminals and viewers; Chromium and Firefox with a private profile under
  BaneySpaces' own folder; Ghostty with `--gtk-single-instance=false`), never a path (`/` is
  `bad_arguments`). The name is resolved through PATH and its realpath must equal the system binary
  of that name (`/usr/bin`, `/bin`, `/usr/local/bin`), so a wrapper script or a symlink earlier on PATH
  or in a project does not pass. A terminal (foot, kitty, alacritty, xterm, ghostty) and the dialog
  tools take **no file at all**: a terminal would run the file as a command, and `agent run` is the
  way to run one. Only viewers (mpv, imv, swayimg) and browsers take files, and every one must resolve
  (realpath) inside the handoff folder (`$XDG_STATE_HOME/baneyspaces/handoff`); a flag, a URL, `..` or a symlink
  out of the folder is `bad_arguments`. The isolation flags are the only flags, and BaneySpaces
  adds them. Anything off the list, such as nautilus or a GApplication, is `needs_sandbox` before
  launch, whether or not you run a copy;
- **every agent process (`open` and `run`) has a session bus of its own.** One `dbus-daemon
  --session` per launch, with its own runtime directory, so GApplication and D-Bus single-instance
  forwarding cannot cross between the agent's copy and yours in either direction. It comes with its
  own accessibility bus (`at-spi-bus-launcher` and `at-spi2-registryd` under that runtime
  directory): GTK4 asks the session bus where the accessibility bus is and ignores
  `AT_SPI_BUS_ADDRESS`, so an app on a private session bus would otherwise start a launcher that takes
  over the socket of *your* accessibility bus. The hands engine is pointed at the launch's session
  bus when it works on that launch's windows. The stack is a process group, a child of the daemon:
  it is torn down when the token's last process exits, when the daemon exits (`stop`, `SIGTERM`,
  `SIGINT`, `SIGHUP`, the include being removed). If the daemon is killed outright or crashes, the
  kernel kills the three processes it started (`PR_SET_PDEATHSIG`); what those started in turn (the
  accessibility bus daemon, an activated service) is swept by the next daemon, which also removes any
  stack whose directory is gone or which no live token owns. What does not carry over: your notification daemon, tray and portal backends. The
  private bus is configured to **refuse** (AccessDenied) any call to xdg-desktop-portal, its
  backends, the document portal and notification daemons, so none is activated there: a dialog such
  a portal would raise carries no launch token and would open on *your* workspace. GTK and Qt fall
  back to their own dialogs. The clipboard and display are Wayland and untouched; GSettings reads
  work. **A daemon restart ends these buses.** A GApplication quits when its bus goes; an app that
  keeps running (an agent's terminal) holds a dead bus address and has no accessibility, so `agent
  snapshot` on it answers `stale_ref` ("this app's session bus ended") and `agent status` marks it
  not drivable until it is started again. The daemon does not kill the agent's processes. The agent's
  environment also lacks `HYPRLAND_INSTANCE_SIGNATURE` and `HYPRLAND_CMD`, so `hyprctl` from an
  agent's shell has no instance to talk to (accident-proofing: the socket under
  `$XDG_RUNTIME_DIR/hypr/` can still be found by a process that looks for it)
  `agent run` is a shell with your uid, so this is accident-proofing, not a boundary (the host threat
  model; a process of yours can still find your bus address);
- an app that is on the list but forwards anyway (the allowlist does not see every wrapper) or a
  launch with the allowlist skipped (the test-only `test_open`) has its forwarded window left where
  it is, and the `single_instance` error lists it (`error.data.windows_that_appeared`). A known limit,
  in the ledger in `AGENTS.md`;
- an accessible window is matched to the compositor window by its title, and exactly one must carry
  it (`window_unmatched` otherwise): there is no fallback to "the only window of the process";
- scope is checked again right before the engine's command: window, pid, start time and workspace
  must be what they were, or the call is refused `not_in_scope` and nothing is sent;
- a window of yours that you park there (`agent move`) is guarded but not drivable (`needs_lend`);
- each ref is tied to the snapshot, window and process it came from (`stale_ref` otherwise).

**A known limit.** The exec rule that keeps a window off your screen applies to the app BaneySpaces
launches. A window that a process *inside* an agent's shell opens later (a GUI app started from
`agent run -- claude`) is adopted by its launch token and moved to the agent workspace, but Hyprland
has already shown it for a moment, and warped the pointer to it. Your front window and workspaces are
put back by the guard; the pointer is not. `hardening.sh` excludes the pointer from that one check.

**Agents cannot run your commands.** The control socket reads the caller's pid (`SO_PEERCRED`). A
caller that carries a launch token the daemon issued (an agent's shell, anything it started) or is a
registered agent process is refused `switch`, `move`, `focus-monitor`, `agent-workspace`,
`agent move|bring`, `overview` and `stop` with `not_in_scope`, and the attempt is logged. This
guards against accidents, such as an agent shell running `baneyspaces switch 3`; it is not a
boundary against a hostile process of your own user, which could unset its environment. The same
threat model as the Mac app. The launch tokens are kept in `tokens.json` (0600) so a restart still
recognises a terminal an agent left running.

**The focus-follow guard.** Any activation of an agent window is undone: your previous window is put
back and `guard.refused` counts it. If the agent workspace appears without you asking, it is hidden
again. Only `baneyspaces agent-workspace show|hide|toggle` (Super+\`) shows it.

**R-F2 (an app asking does not move you) rests on one Hyprland setting here.** Hyprland's events do
not say who caused a focus change, so the daemon treats every activation it sees as yours and does
not try to guess otherwise. What keeps an app from pulling you to another workspace is
`misc:focus_on_activate = false`. The include sets it, the daemon sets it again on every config
reload, and every 2 seconds the daemon reads it back and turns it off if something turned it on
(`nested.sh` flips it and watches the daemon put it back). If that setting is lost for a moment, an
app's request can follow until the next check.

Every action appends one line to `$XDG_STATE_HOME/baneyspaces/actions.jsonl` (agent id, verb, pid,
window, ref, route, result, refusal, `screen_changed`; never content), read with `baneyspaces agent
log`. Records older than 30 days are dropped when a line is appended (looked for at most once an
hour) and at start. `screen_changed` is its own field: the outcome stays in `result`, and the pointer
is not part of the comparison.

## Agents manage their own workspace

An agent opens its apps in the background on `special:agent` and arranges them there, so you never
have to. The verbs, argument names and result fields are the Mac's (`HandsRouter+Workspaces.swift`
in PR #106), so an agent's script written for the Mac works on Omarchy. Window ids differ: on Linux
a window is its Hyprland address (`0x5da0...`), on the Mac a number. Take ids from results, never
type them.

| Verb | macOS | Linux (Omarchy, Hyprland) | Windows |
| --- | --- | --- | --- |
| `agent workspaces` | yes | yes: the nine and `special:agent` (`number`, `shown`, `current`, `agent`, `windows`), `agent_workspace_shown`, `your_windows` | not supported yet |
| `agent open <app> [file...] [--new_window=false] [--wait S]` | yes | yes: `reused`, `focus: {changed, returned}`, the window recorded for your session, also when it comes after `open` answered (`window: null, pending: true`) | not supported yet (plain `agent open` only) |
| `agent arrange full\|halves\|thirds\|grid [window...]`, `frames 0xADDR=x,y,w,h ...` | yes | yes: the Mac's frames, applied at once while the workspace stays hidden (`applied: "now"`) | not supported yet |
| `agent move --window W [--frame x,y,w,h]` | yes, including a lent window or one under Full Access | yes for the agent's own windows; your windows, including one you parked on the agent workspace, and anything that needs a lend or Full Access are `not_supported` (no lend sheet on Linux yet) | not supported yet |
| `agent close --window W` | yes: only windows this session opened | yes: only windows this session opened, by address, `stableId`, pid and start time (another window that later gets the same address is not the session's) | not supported yet |
| Child windows (dialogs) | usable under the child window rules | usable when its process is an agent process: floating, on `special:agent` or on no workspace yet; a dialog of any other process is not | not supported yet |

`agent move <window>` (no `--window`) is still yours: it parks one of your windows there and stays
refused to agents. The Mac tells the two apart the same way.

How each verb reaches Hyprland. Every dispatch names its window (`window = "address:0x..."`; an
address is checked to be `0x` and hex digits first, because a dispatcher with no window acts on the
focused one), and none shows a workspace or moves focus. `agentws::loud` lists what is never sent,
the verbs refuse their own dispatch if it matches, and the unit tests check every string sent.

| Verb | Dispatches (Hyprland's Lua API) | Why focus stays where it is |
| --- | --- | --- |
| `workspaces` | none (`j/workspaces`, `j/monitors`, `j/clients`) | read only; counts, never titles of your windows |
| `open` | `hl.dsp.exec_cmd(cmd, { workspace = "special:agent silent" })` (unchanged) | the exec rule places the window silently; the guard undoes any activation |
| `arrange`, `move --frame` | `hl.dsp.window.float({ action = "enable", ... })`, `hl.dsp.window.resize({ x = W, y = H, ... })`, `hl.dsp.window.move({ x = X, y = Y, ... })` | these change the layout target only; float raises the window within `special:agent`, it does not focus it |
| `move` of an agent window Hyprland has not placed on any workspace yet | `hl.dsp.window.move({ workspace = "special:agent", follow = false, ... })` | `follow = false` is the silent move: the target is not shown |
| `close` | `hl.dsp.window.close({ ... })` | a close request, as Super+W sends; the app may ask to save first, and that dialog comes back as `opened` |

Frames are in logical pixels from the top-left of the usable area (bars excluded) of the monitor that
holds `special:agent`, at least 240 by 160, kept inside the area: the Mac's points, the same numbers.

Where Linux differs from the Mac, and why:

- **No lend, no Full Access.** Linux has no lend sheet yet, so a window on your workspaces is never
  moved or laid out for an agent: `not_supported`, with a message that says so. A window you park on
  the agent workspace yourself (`agent move <window>`) is still yours: no frame, no move, no close.
- **Checked right before each dispatch.** Hyprland is asked again before every float, resize, move
  and close: the window must still be on `special:agent` and belong to the same agent process (pid
  and start time). If you took one back meanwhile, the call stops there, sends nothing more, and
  answers `not_in_scope` with `changed` and `not_changed` lists. An agent's window you move to one of
  your workspaces is yours from then on: every verb refuses it (`not_in_scope`), and `workspaces`
  lists it as `moved_out_by_user` until you move it back.
- **A slow start.** `open` records its session with the launch, before the window exists. With a
  `--wait` shorter than the app's start it answers `window: null, pending: true` (`pid` is `null`
  while Hyprland has not started the process yet), never an error, and the first window
  of the process that launch started is still recorded for that session when it comes (for 120 s);
  two sessions opening the same app each get only their own.
- **Workspace names.** `agent_workspace` is `"special:agent"` and its row in `workspaces` has
  `number: null` and `name: "special:agent"`; `from` and `to` in `move` are Hyprland workspace names.
- **Error codes.** A refusal the Mac answers `permission_denied` or `outside_agent_workspace` is
  `not_in_scope` here, the code `spec/envelope.md` already has for it.
- **`access`** is always `"default"`: there are no access modes on Linux.
- **Sessions** are the Mac's: `--session S`, else `$BANEYSPACES_SESSION`, else your terminal, else
  `default`. The record is kept in memory, so after a daemon restart `close` refuses what was opened
  before it (it fails closed). Like the agent id, the session is the caller's word: accident-proofing.
- **A dialog** is a floating window of an agent process on `special:agent` that is not the first of
  its process to arrive there (so a process always keeps a window of its own; a window `arrange`
  floated does not count), or one Hyprland has not placed on any
  workspace. Hyprland does not report a parent, so `parent` is the oldest other window of the process.
- **MCP.** The verbs are on the CLI. The shared MCP catalog (`spec/mcp-tools.json`) is unchanged:
  its test refuses any tool named `move` and `spec/cli.md` says no tool lists your workspaces, so
  adding `agent_workspaces`, `agent_arrange`, `agent_move` and `agent_close` there is a spec decision
  of its own.

### Try it on Omarchy

None of this has run on a live Hyprland yet. On a real session, with the daemon running and a
terminal of yours in front on workspace 1, check after each step that your window still has focus
and `special:agent` stays hidden (`hyprctl -j monitors | jq '.[].specialWorkspace.name'` prints `""`):

```sh
baneyspaces agent workspaces | jq '.data | {agent_workspace_shown, rows: [.workspaces[] | {number, shown, windows}]}'
A=$(baneyspaces agent open foot --session try | jq -r .data.window); echo "$A"
B=$(baneyspaces agent open foot --session try | jq -r .data.window)
baneyspaces agent open foot --new_window=false --session try | jq .data.reused     # true, nothing started
baneyspaces agent arrange halves --session try | jq '.data.windows[] | {window, applied, frame}'
hyprctl -j clients | jq ".[] | select(.address==\"$A\") | {floating, at, size}"     # the frame from arrange
baneyspaces agent move --window "$A" --frame 0,0,800,600 --session try | jq .data
baneyspaces agent move --window "$(hyprctl -j activewindow | jq -r .address)" | jq .error.code   # not_supported: yours
baneyspaces agent close --window "$B" --session other | jq .error.code              # not_in_scope: not this session's
baneyspaces agent close --window "$B" --session try | jq .data.closed               # true
baneyspaces agent-workspace show                                                   # you: see the two windows laid out
```

## When the compositor says no, or the daemon is slow

A switch or move whose Hyprland dispatch fails comes back `compositor_error`, never `ok`, and the
daemon re-reads Hyprland before the next command. `retry` is `safe` only when Hyprland refused
cleanly before anything moved; a timeout, or a failure after an earlier step went through, is
`never`. The CLI waits 90 s for the daemon; one hands call has a 50 s budget inside that. A
connection failure is `daemon_down` (safe); silence after the request was sent is `timeout` with
retry `never`.

The daemon holds no lock while an agent app is being launched (starting its bus takes a second or
two) or taken down, so your keys never wait for one; `nested.sh` times a switch during a launch.
If Hyprland refuses the settings the daemon relies on (instant switching, the focus rule), the model
stays dirty and commands are refused (`compositor_error`, retry `after`) until they can be applied.
`move` with no window named acts on the window Hyprland says is in front right now: an empty desktop
is `not_found`, a failed query `compositor_error`, and a window the model remembers is never used.
If the daemon cannot re-read Hyprland after a failure, it does not act on a guess: the next command
is refused `compositor_error` with retry `after` until it can. The daemon connects to Hyprland's
event socket before it reads the state, so a window that opens during start-up is replayed, not lost,
and every few seconds it reconciles its windows against Hyprland's. Changes you make yourself, such
as a click on an Omarchy waybar workspace button on the other monitor or Super+scroll, are mirrored
and never undone: the daemon corrects focus only after a command it ran itself. A caller whose pid
cannot be read is treated as an agent for the operations that belong to you.

With no daemon running (a reload before it started, a crash) the bound workspace keys fall back to
Hyprland's own dispatch for `switch` and `move`, so they never go dead. The autostart file starts the
daemon on `hyprland.start` and on every `config.reloaded`; the daemon exits on a reload once the
BaneySpaces block is gone from `hyprland.lua`, and `uninstall.sh` stops it first.

## Agent hands

The engine is [vercel-labs/agent-desktop](https://github.com/vercel-labs/agent-desktop) at the commit
the Mac build pins (`engine.pin`, 5261b52), built from source with its own `Cargo.lock`
(`cargo build --locked`) by `scripts/build-engine.sh`, never through npm. Its Linux adapter reads and
acts through AT-SPI. The daemon runs it as a child process, headless (it is never given `--headed`,
so it posts no global input), after the scope guard, and maps its envelope onto ours. Results carry
the engine's own evidence: `verified` is true only when the engine read the outcome back from the
element. `press`, `key` and `pointer` are `not_supported` (phase 3-4).

### `agent shot`: one window, captured while it stays hidden

`baneyspaces agent shot --window W [--out NAME]` writes a PNG of one agent window into
`$XDG_STATE_HOME/baneyspaces/shots/` (folder 0700, file 0600, written whole and renamed, so a reader
never sees half a file). `NAME` is a plain file name (no `/`, no leading `.`); without it the file is
`window-<address>-<unix time>.png`. The result has the Mac's shape: `path`, `width`, `height`,
`cursor` (always false: Linux draws no agent cursor), `evidence` (`kind: "capture_hash"`, the PNG's
`sha256`, plus `frames` and `settled`, below) and `target`.

The engine is not used. The daemon runs `grim -T <stableId>` (grim 1.5 or later, the system binary),
which asks Hyprland for that one window through `ext-foreign-toplevel-list-v1` and
`ext-image-copy-capture-v1`. Hyprland names each window in that list by the `stableId` that `hyprctl
clients` reports, so the window is picked by its identity, never by its place on a screen, and grim
is never given `-o` or `-g`. The window stays on `special:agent`: nothing is shown, focused or moved.

The scope guard is the one every verb uses (on `special:agent` by Hyprland's word, a process the
daemon registered, pid and start time), and it runs again before every capture and once more before
the file is written, with the window's `stableId` compared too. A window that leaves the agent
workspace mid-call is refused `not_in_scope` and no picture is kept. A window you parked is
`needs_lend`.

**A hidden window does not repaint on its own.** Hyprland sends no frame callbacks to a window on a
hidden special workspace, so the app keeps showing its last frame and the first capture after an
action shows the window as it was before it (measured on Hyprland 0.56.2: the label read "count 0"
after the click that made it "count 1"). A capture is a frame for the app, and it repaints after it.
So the daemon captures until two captures in a row are the same picture, at most five, 120 ms
apart, and answers with the last; `evidence.settled` is true when two agreed and `evidence.frames`
is how many were taken. An app that never stops animating does not settle; its picture is then the
newest frame it drew, at most one frame old, and `settled` is false. (Hyprland's `render_unfocused`
window rule, applied when the window maps, also keeps a hidden window current; it is not used because
it makes every agent window keep drawing in the background, and `set_prop` after the window has
mapped did not have that effect.) Without grim, or with a grim that has no `-T`, `shot` answers
`not_supported` and says what is missing.

## Install on an Omarchy seat (part 2 does this on seat-b and seat-a)

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
cargo test                                  # core, the 89 conformance cases, the daemon's pure parts and the agent workspace verbs (against a fake Hyprland socket)
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
focus. The `shot` checks read the test app's background colour, which flips with every click, so a
capture that showed the frame before the last click would fail them.
