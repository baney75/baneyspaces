# Devices and virtual machines

Donovan, 2026-11-01: "work on for the simulators. and such for devices like android ios, ipad, and
ect. for virtual machines and such." Simulators, emulators and VMs are windows like any other, with
four habits that break a workspace manager: a device has several windows that belong together, some
of them tools; the app resizes its own window (a device rotates, a guest changes resolution); the
app grabs the keyboard while it has focus, so the workspace keys never arrive; and an agent that
starts one starts a tree of processes, not one.

`devices.json` is the table of apps and what each of their windows is for. The macOS app embeds it
(`scripts/gen-device-data.sh` writes `DeviceData.swift`; a test fails when the two differ), the Rust
core includes it. Cases are in `conformance/devices.json` (model, replayed by every platform's
model) and `conformance/devices/*.json` (classification, geometry, keys, process trees).
`docs/devices-and-vms.md` is the survey: each app, what breaks, the fix and how it was verified.

## The table

An app is matched by what the platform knows: macOS `bundle` (exact) or `process` (the executable's
name), Linux `class` or `process`, Windows `exe`. A name is exact, or a prefix when it ends in `*`;
case does not matter. Each app lists its window rules in order, and the first one that hits wins.
A rule can test the title (`title_prefix`, `title_contains`, `title_is`, `title_empty`) and gives the
window a `role`, and optionally `"home": "agent"`.

| Field | Meaning |
| --- | --- |
| `windows[].role` | `main`, `companion` or `ignore` (below) |
| `resizes_itself` | The app changes its window's size on its own (rotation, guest resolution): `R-D6` |
| `float` | A fixed aspect ratio: floats on a compositor that tiles: `R-D10` |
| `keys.<platform>.capture` | `none`, `tap` (macOS event tap), `hook` (Windows keyboard hook), `inhibit` (Wayland keyboard-shortcuts-inhibit) |
| `keys.<platform>.release` | The app's own chord that gives the keyboard back |

## Rules

### R-D1 What a window is for

`main` is an application window: it has a workspace, a tile, a place in the switcher. `companion` is
a toolbar, extended controls or a mini bar: it lives with the main window of its process (`R-D2`)
and is never counted as a window of its own (`R-D3`). `ignore` is not tracked at all. The first
rule that hits decides. A window the platform does not call a standard application window (macOS:
subrole other than `AXStandardWindow`) is never `main`: a rule that says `main` gives it `ignore`,
which is what every app's panels and sheets get today. An app that is not in the table is plain: a
standard window is `main`, anything else `ignore`. A rule list for an emulator ends in a catch-all
`companion`, so a side window nobody listed still follows its window.

### R-D2 A companion lives where its main window lives

A companion opens on the workspace of the newest main window of its process, whichever workspace the
compositor put it on (the effect is a silent `move_window`). One that opens before its main window
goes to it when the main window opens, and one already open when BaneySpaces started is put back
with its main window. When the main window moves (a command, the compositor, a drag), its companions
move after it, in the order they opened, before any focus effect. Parking the main window on the
agent workspace parks its companions.

### R-D3 A companion is not a window

A workspace that holds only companions is empty: it is a free workspace for a new display and
`state.json` lists no window on it. A companion is never the window a workspace focuses next, never
a tile or a row. Using a companion is using its main window: a user activation of the toolbar on a
workspace out of sight brings that workspace up and focuses the main window, and an activation the
app caused (`cause: app`) follows no one, with the same refusal as for the main window.

### R-D4 Moving a companion moves its window

`move` aimed at a companion (it has the focus) moves its main window, and the companions follow.

### R-D5 A companion cannot be left behind

A companion the user or the compositor moved alone is put back with its main window (a silent
`move_window`).

### R-D6 A window that resizes itself keeps the size it has

When a window of an app with `resizes_itself` comes back from where it was parked, the restore
keeps the window's *current* size and the saved *origin*, then slides the frame into the display
that held the saved frame if the new size would hang off it. The saved size is not put back: the
device rotated while the window was parked, and putting the portrait size back un-rotates it.
Every other window comes back with its saved frame as before. A saved frame that is mostly off
screen is centered, as before. (`conformance/devices/geometry.json`. macOS only: Linux and Windows
compositors keep a window's size when it changes workspace.)

### R-D7 Workspace keys work inside an app that grabs the keyboard

Where the table says an app captures the keyboard, the workspace chords (the platform modifier plus a
digit, with or without Shift) still run the workspace actions while that app has focus, and the
guest never sees them. macOS: a key bridge, an event tap that sits ahead of the app's own while
such an app is in front (`DeviceKeys` decides; `conformance/devices/keys.json`). Linux: every
BaneySpaces bind carries `dont_inhibit`, so Hyprland ignores the viewer's keyboard-shortcuts-inhibit
request. Windows: `windows/part1` owns it. Anything else goes to the guest. A setting turns the
bridge off for someone who wants those chords in the guest.

These always work, whatever the app does with keys: `baneyspaces switch <n>` from a terminal, an ssh
session or a hook; the menu bar item, the Workspace Dock and the overview with the pointer; and the
app's own release chord from the table (`keys.<platform>.release`). The recovery chord in
`config.md` is not touched by any of this.

### R-D8 An agent's device is its whole process tree

Every process descended from a process BaneySpaces started for an agent is that agent's process. The
emulator starts `qemu-system-*` and a Simulator host starts services: the window belongs to a
grandchild. macOS decides by parent pid (`conformance/devices/placement.json`); Linux by the launch
token every descendant inherits. A pid that was reused by an unrelated process is not a descendant.

### R-D9 The sandbox view lives on the agent workspace

A Tart window whose title starts with `bsx-` (the BaneySpaces sandbox) goes to the agent workspace
whichever process opened it, and never takes the focus or a workspace (`R-G1`).

### R-D10 A fixed aspect ratio floats

On a compositor that tiles, an app with `float` opens floating. Tiling stretches an emulator's
window out of its aspect ratio and fights the app every time the device rotates. Linux: a Hyprland
window rule generated from the table into the include.

## Full screen

A VM or emulator in macOS full screen is a window on its own Space; everything above stops at the
edge of what Accessibility can see from the current Space. That is the separate fix on branch
`fix/fullscreen`; this change adds nothing to it and depends on it for the cases listed in
`docs/devices-and-vms.md`.
