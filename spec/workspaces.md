# Workspace rules

One shared pool of nine workspaces, plus one agent workspace. Each display shows one of the nine at
a time, never the same one as another display. The model is pure: a platform feeds it events (what
you asked for, what the compositor reported) and carries out the effects it returns. Rules marked
*observed* mirror what the compositor already did and produce effects only to correct it.

This is the macOS app's model (`Workspaces.swift`: `shown`, `switchTo`, `displays`) on every
platform: workspace n is the same workspace whichever display shows it.

Terms. **Display** (monitor): named by the platform (`eDP-2`). **Slot**: a display's place in the
order, 0 for the main one, the lowest free number for a new one. **Shown**: the workspace a display
is showing. **Front**: the active window. **Agent window**: a window on the agent workspace or
owned by a process BaneySpaces started for an agent.

## Displays

### R-M1 One pool, one workspace per display
Windows belong to workspaces 1 to 9, not to displays. Each display shows exactly one workspace, and
no workspace is shown on two displays at once. The first display shows workspace 1 and is the one
you are on.

### R-M2 A display you plug in shows an empty workspace
It shows the workspace it showed when it was last here, if nobody shows that now; else the first
empty workspace nobody shows; else the first nobody shows. The other displays do not change.

### R-M3 A display you unplug lets go of its workspace
The workspace goes out of sight with its windows in it, until you go to it. Nothing is moved. If
you were on that display, you are on the first one left. With no display left the windows wait, and
a display that comes back shows what it showed.

## Switching

### R-S1 Workspaces 1 to 9, instantly
`switch n` for n outside 1 to 9 is `invalid_args`. A switch never animates. A platform that cannot
turn its animation off for a switch does not ship.

### R-S2 Switch shows the workspace on the display you are on
The display you last clicked into, moved to, or switched to. The other displays keep what they show.

### R-S3 If another display shows it, you go to that display
Pressing the number of a workspace another display is already showing takes you to that display and
brings its front window forward. Nothing else changes (as in AeroSpace).

### R-S4 The workspace you are on is a no-op
No effects. (The one exception: the agent workspace is covering it, see R-A4.)

### R-S5 Switch puts back what you had
The window you had in front on that workspace, else the last one opened there, else nothing.

### R-S6 Outside the nine
A display may show something that is not one of the nine (observed as workspace 0): a platform's
own, or one you keep elsewhere. A switch to 1 to 9 then always acts, even to 1.

## Empty means empty

### R-E1 Nothing in front on an empty workspace
Switching to an empty workspace, or closing the last window of the one you are on, leaves nothing in
front. Focus never falls to a window on another workspace. Typing goes nowhere until you open something.

## Placement

### R-P1 New windows land where you are
A window that opens joins the workspace shown on the display it appeared on (the one you are on, by
default) and takes the front. A window the compositor put on a workspace you are not looking at is
moved to that one, silently (no focus change).

### R-P2 Windows that were already open
When the daemon starts it mirrors every window exactly where it is, even out of sight. A window
already parked on the agent workspace stays parked and is not drivable. A window of an agent process
found on your workspaces is moved off them.

## Moving a window

### R-V1 Move sends the front window
`move n` sends the front window (or a named one) to workspace n. To the workspace it is already on
is a no-op. With nothing in front it is `not_found`.

### R-V2 You follow it
Like a switch (R-S2, R-S3): you go to the display showing n, or n comes up on the display you are on,
with the window in front.

### R-V3 Move and stay
`move n --stay` sends the window and changes nothing else: not what any display shows, not your
front window (unless the front window itself left, then the front falls back to this workspace).

### R-V4 Moves you make are kept
A window you move with the compositor's own tools (a drag, a command) is mirrored where it lands. It
is never moved back. If it was the front window and left the workspace you are looking at, the front
falls back to that workspace.

## Following focus

### R-F1 Only a user-caused activation follows
When you activate a window on a workspace that is not showing (the launcher, a click, a focus
command), it comes up on the display you are on. A window on a workspace another display shows
takes you to that display.

### R-F2 An app asking does not move you
An activation caused by an app (a notification, an attention request) never changes the workspace or
the display you are on. If it already moved the compositor's focus, the front window you had is put back.
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

An agent only drives a process BaneySpaces started for it as a new instance, verified by pid and
start time. Every pid check is start-time aware, and a registered process that dies or whose pid is
reused is forgotten (a window of a reused pid is never an agent window; conformance cases in
`agent.json`). An app that would forward to a copy you already run is refused before launch
(`needs_sandbox`) unless it is known to start a separate process. If one forwards anyway, its window
opens in your process on your workspace; it is left where it is and the `single_instance` error
reports it in `error.data`. Every action leaves a record without content (agent id, verb, pid,
window id, ref, route, result, refusal, screen_changed), kept 30 days.

Callers: a caller of the control socket that carries a launch token BaneySpaces issued, or is a
registered agent process, is refused the operations that belong to the user (switch, move, focus
monitor, show or hide the agent workspace, park or bring a window, overview, stop) with
`not_in_scope`. This is accident-proofing, not a boundary against a hostile process of your own
user (the Mac's threat model is the same).
