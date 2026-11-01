# Workspace rules

Nine workspaces on every display, plus one agent workspace. The model is pure: a platform feeds it
events (what you asked for, what the compositor reported) and carries out the effects it returns.
Rules marked *observed* mirror what the compositor already did and produce effects only to correct it.

Terms. **Monitor**: a display, named by the platform (`eDP-2`). **Slot**: a monitor's number, 0 for
the first, the lowest free one for a new monitor. **Current**: the workspace a monitor shows.
**Front**: the active window. **Agent window**: a window on the agent workspace or owned by a
process BaneySpaces started for an agent.

## Monitors

### R-M1 One set of nine per monitor
Every monitor has workspaces 1 to 9 of its own and shows one of them. A monitor you plug in shows an
empty workspace 1. The first monitor is the one you are on. (The macOS app shares nine workspaces
across displays, so ⌘n there can take you to a workspace the other display shows; per-monitor sets
are the Linux and Windows rule. See "Open" in the Linux part-1 PR.)

### R-M2 Unplugging
The windows of a monitor you unplug go to the lowest-slot monitor left, same workspace number, and
you are on that monitor if you were on the one that left. With no monitor left they wait out of
sight and come back to a monitor of the same name.

## Switching

### R-S1 Workspaces 1 to 9, instantly
`switch n` for n outside 1 to 9 is `invalid_args`. A switch never animates. A platform that cannot
turn its animation off for a switch does not ship.

### R-S2 Switch acts on the monitor you are on
The monitor you last clicked into, moved to, or switched to. The other monitors keep their
workspaces. A switch may name another monitor; then your focus does not change.

### R-S3 The workspace you are on is a no-op
No effects. (The one exception: the agent workspace is covering it, see R-A4.)

### R-S4 Switch puts back what you had
The window you had in front on that workspace, else its oldest window, else nothing.

## Empty means empty

### R-E1 Nothing in front on an empty workspace
Switching to an empty workspace, or closing the last window of the one you are on, leaves nothing in
front. Focus never falls to a window on another workspace. Typing goes nowhere until you open something.

## Placement

### R-P1 New windows land where you are
A window that opens goes to the current workspace of the monitor you are on, and takes the front.
A window the compositor put on a workspace you are not looking at is moved here, silently (no
focus change). A window the compositor opened on another monitor stays on that monitor's current workspace.

## Moving a window

### R-V1 Move sends the front window
`move n` sends the front window (or a named one) to workspace n. To the workspace it is already on
is a no-op. With nothing in front it is `not_found`.

### R-V2 A moved window keeps its monitor
It goes to workspace n of the monitor it is on.

### R-V3 You follow it
You go to workspace n of that monitor, onto that monitor if it is another one, with the window in front.

### R-V4 Move and stay
`move n --stay` sends the window and changes nothing else: not your workspace, not your front window.

## Following focus

### R-F1 Only a user-caused activation follows
When you activate a window on a workspace that is not showing (the launcher, a click, a focus
command), that monitor switches to its workspace and you are on that monitor.

### R-F2 An app asking does not move you
An activation caused by an app (a notification, an attention request) never changes the workspace or
the monitor you are on. If it already moved the compositor's focus, the front window you had is put back.
The result is `refuse_follow` with reason `not_user_caused`.

### R-F3 Windows outside the scheme are ignored
The model tracks only windows on BaneySpaces workspaces. Others (a platform's own scratchpad, a
workspace the user keeps outside the nine) are left alone.

## The agent workspace

### R-A1 Agents never take your screen
Nothing an agent does changes your workspaces, your front window or your focus.

### R-A2 Parked, not lost
`agent move` parks one of your windows on the agent workspace; `agent bring` returns it to the
workspace you are on. A window of a process started for an agent cannot be brought back or moved to
your workspaces (`agent_window`).

### R-A3 Agent processes open on the agent workspace
A window opened by an agent process joins the agent workspace, silently, in front of nothing. A
second window of that process joins the first. Windows of every other process never land there.
Registering a process moves any windows it already has off your workspaces. A process that exits is forgotten.

### R-A4 You show it
The agent workspace is shown only by your command (`agent show`, `agent toggle`). While it is up, a
switch closes it first, and a switch to the workspace under it uncovers it.

### R-A5 Hiding puts back your window
Hiding the agent workspace returns the front window you had when you showed it.

### R-G1 The guard
An activation of an agent window (by app, by agent, or even by a "user" event) is refused: the
result is `refuse_follow` with reason `agent_window`, the front window you had is put back, and
`guard.refused` counts it. The one exception is after you showed the agent workspace yourself and
the activation is user-caused: then focus is yours.

### R-G3 It does not appear on its own
If the compositor reports the agent workspace showing and you did not ask, it is hidden again and
counted in `guard.refused`.

## Agent scope (the hands)

Not workspace rules but part of the same contract; `crates/baneyspaces-core/src/agent.rs` implements
them and its tests are the cases. An agent action proceeds only when all hold:

1. The window is on the agent workspace (`not_in_scope` otherwise).
2. The window's process is one BaneySpaces started for an agent, identified by pid and process
   start time (`needs_lend` if not, `stale_ref` if the pid was reused or the window changed hands).
3. The snapshot the ref came from is of that same window and process (`stale_ref` otherwise).

An agent only drives a process BaneySpaces started for it as a new instance, verified by pid. An app
that forwards to a running instance (a single-instance app) opens no window of its own process: the
open fails with `single_instance` and nothing of yours is touched. Every action leaves a record
without content (agent id, verb, pid, window id, ref, route, result, refusal), kept 30 days.
