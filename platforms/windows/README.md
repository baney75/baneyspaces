# BaneySpaces for Windows

Part 1: the workspace model on Windows 11, the keys, the agent workspace and the agent hands. No dock,
launcher or overview yet (part 2). The shared contract is `spec/`; the model, the scope guard and the
envelope are `crates/baneyspaces-core`, the same code the Linux daemon runs.

```
platforms/windows/baneyspaces/   the `baneyspaces` binary: CLI, `daemon`, `mcp`
platforms/windows/scripts/       build-engine.ps1: the pinned agent-desktop, built with --locked
platforms/windows/tests/         live.sh (the live test in the VM), readback.ps1, watch.ps1, evidence/
platforms/windows/vm/            provision-toolchain.ps1: Rust + the MSVC build tools inside the test VM
```

## Hiding windows: which way, and why

Three ways to take a window out of sight on Windows, measured on Windows 11 (build 26100) in the VM.
"Animation" was counted by sampling the window's pixels as fast as the VM could while the call ran.

| | Animation | Taskbar | Explorer restart | A window can be lost if the daemon dies |
| --- | --- | --- | --- | --- |
| `ShowWindow(SW_HIDE)` | **yes**: 6 distinct frames (a fade) | button disappears (churn) | fine | yes, nothing brings it back |
| Move off-screen | none | button stays | fine | yes, it sits at -32000 |
| `DwmSetWindowAttribute(DWMWA_CLOAK)` | none | n/a | n/a | **does not work across processes**: `E_ACCESSDENIED` |
| **Shell cloak**: `IApplicationView::SetCloak` through ImmersiveShell COM | none: one frame | button stays (no churn) | **survives**: cloaked at 2 before and after killing explorer.exe, and undone afterwards | recoverable (below) |

komorebi (`HidingBehaviour::Cloak`, its default) and GlazeWM (`set_cloaked`) both make the shell cloak
call, with the same undocumented interface ids. So did this daemon, after checking the numbers above.

**Your workspaces: the shell cloak, with a fallback.** The window stays where it is, un-drawn. The
interfaces are undocumented, so if the call is refused (a Windows build changes the ids) or does not
take (the window reads back as not cloaked), the window is **parked** at (-32000, -32000) instead, the
place Windows itself puts minimized windows. Nothing is ever hidden with `SW_HIDE`.

**The agent workspace: a ghost, not a cloak.** The hands engine (UI Automation) skips cloaked windows:
`list-windows` does not list them and `snapshot` returns `WINDOW_NOT_FOUND` (measured). An agent's window
must stay drivable, so it is made fully transparent (`WS_EX_LAYERED`, alpha 0), click-through
(`WS_EX_TRANSPARENT`) and unable to take focus (`WS_EX_NOACTIVATE`), and its taskbar button is removed.
It is still on screen and un-cloaked, and you cannot see or touch it. (`WS_EX_TOOLWINDOW` would also
hide it from the engine, so it is not used.)

**Never losing a window.** The daemon writes a window into `%LOCALAPPDATA%\BaneySpaces\state.json`
(`hidden`) *before* it hides it and removes it *after* it shows it again.

- On a clean exit (`baneyspaces stop`, Ctrl+C, closing the console, logoff, a panic) every window is shown.
- After a crash or `taskkill /F`, the next start reads the list and shows every window on it, before
  doing anything else. A window whose handle is gone is dropped.
- Safety net: a window the shell has cloaked that is *not* on the list, is on your current virtual
  desktop (`IVirtualDesktopManager`, documented) and looks like an app window is shown too.
- **Agent windows are the exception.** They belong off your screen, so after a restart they stay
  ghosted while their process (pid and start time) still runs. If it is gone they are shown, never lost.
  The daemon does not close an agent's app when it exits: use `agent-workspace show` after a restart.

Taskbar: a cloaked window keeps its taskbar button (as with komorebi and GlazeWM), so the taskbar shows
every workspace's windows. An agent's window has no button.

## Keys

Explorer owns Win+1 to Win+9, so `RegisterHotKey` fails for them. The daemon runs a `WH_KEYBOARD_LL` hook on its
own thread with its own message loop. The callback matches a small table and posts to the worker over a
channel; it takes no lock and never waits (Windows drops a hook whose callback is slow). It swallows only
the chords in the Windows column of `spec/keys.json`: **Win+1-9** switch, **Win+Shift+1-9** move,
**Win+`** show or hide the agent workspace. It keeps its own count of which modifiers are down (the
async key state can lag when two keys arrive in the same millisecond), swallows the digit's key-up too,
and presses an unassigned key (0xE8) so releasing Win does not open the Start menu.

Limit (by design): Windows keeps a normal-level hook from seeing keys typed into an **elevated** window
(UIPI), so **the Win chords do nothing while an elevated window has focus** (Task Manager, an elevated
terminal). The daemon is not elevated and does not ask for UI access.

## Focus

An activation reaches the daemon as `EVENT_SYSTEM_FOREGROUND`. Windows does not say who caused it, so
input in the last 300 ms (`GetLastInputInfo`) counts as yours (R-F1) and anything else as the app's
(R-F2): the model refuses to follow it and the daemon puts your previous window back. A window that
opens joins the workspace its display shows (R-P1). Focus never rests on a window that is out of sight.

## The agent workspace

`baneyspaces agent open <app>` starts the app as its own process, **in its own job object** (Linux
uses a launch token in the environment; a job answers "is this process one we started, or a child of
one?" directly), minimized and without focus, so a window that honors the show command is never drawn
on your screen. The model registers the pid and its start time before the first window can be seen.
Every action runs the scope guard first (`check_scope`: on the agent workspace, a registered process,
the same pid and start time), and the engine is run as a child process with no `--headed`: it sends
no `SendInput`, never moves the cursor and never draws the cursor overlay. The engine's own `type` is
`SendInput`, so **`agent type` is a UI Automation insert instead**: it reads the field's value and
sets it to value + text, and the engine reads that back (`verified` is true only then). `shot` passes
through to the engine. `press`, `key` and `pointer` are `not_supported` (phase 3-4).

- **In production, `agent open` on Windows refuses every app with `needs_sandbox`, before launch.** No
  Windows app is safe to hand an agent yet. Notepad restores your unsaved tabs into a new process, so an
  agent's Notepad could show text you never saved, and it also forwards a second launch into a copy you
  already run (seen live). Explorer, the Store apps and browsers forward too. Until there is a
  Windows sandbox, an agent can drive nothing on Windows except through a test daemon (below).
  **Follow-up: a Windows sandbox phase**, where the agent's apps run apart from your session
  (Windows Sandbox or a Hyper-V VM). Single-instance forwarding is handled there as well; the
  `single_instance` error, with `windows_that_appeared`, stays as the backstop if an app forwards anyway.
- **Tests only: `bs-testapp`** (`platforms/windows/testapp`) is a window with a text box: its own exe,
  its own process every time, nothing remembered, no forwarding. A daemon started with
  `BANEYSPACES_TEST_OPS` set may start it (and, for the live test's agent-peer check, any program);
  a normal daemon never does. `live.sh` starts a test daemon for the agent flow.
- `agent run` is `needs_sandbox`: a console window belongs to Windows Terminal, not to the process we
  would start, so it cannot be tied to the agent.
- An agent's own process (a pid in a job, or registered) is refused every user operation
  (`switch`, `move`, `set`, `stop`, the agent workspace toggles...) with `not_in_scope`. The pipe's
  client pid decides, never the request. The control pipe is `\\.\pipe\baneyspaces-<user>`, with an
  ACL for this user and SYSTEM only, and remote clients rejected.
- The engine keeps its snapshots in `%LOCALAPPDATA%\BaneySpaces\engine-state` (`AGENT_DESKTOP_HOME`),
  because it refuses a directory an elevated process created.

## Settings

`baneyspaces set|get` stores `appearance.theme` (`baneyspaces`, `omarchy`, `minimal`),
`appearance.palette` (`auto` or a palette name) and `dock.enabled` in `settings.json` and returns them
(`spec/themes.md`). Part 1 has no dock or themed UI, so they have no effect yet.

## Build and test

```powershell
cargo test -p baneyspaces-core -p baneyspaces-windows --locked   # the Linux crate is unix-only, so test by package
cargo build --release --locked -p baneyspaces-windows
platforms/windows/scripts/build-engine.ps1                       # the pinned agent-desktop (platforms/linux/engine.pin)
baneyspaces daemon --background                                  # no console window; --log FILE, --trace
```

On Parish1 the test VM is `/home/baney75/Projects/_work/win11-vm`. `vm/provision-toolchain.ps1` installs Rust,
the Build Tools and MinGit in it (about 10 minutes, redo after `reset`); the tree is built there. The
Windows crate also cross-checks on Linux with `cargo xwin check --target x86_64-pc-windows-msvc`.
`tests/live.sh` is the live test: it opens Notepad, Explorer and Calculator at normal level, moves
and switches with the CLI and with real Win+n keys (`virsh send-key`), kills the daemon with
`taskkill /F` and starts it again, and runs the agent flow with `bs-testapp` (after checking that production refuses every launch), reading back the windows (EnumWindows,
visibility, DWM cloak state, layered alpha) after every step. `tests/evidence/` has its log and screenshots.

Not done in part 1: multi-monitor placement (windows are not moved between displays; the model is, and
this is untested without a second display), the Startup shortcut, the overview, the dock and themed UI.
