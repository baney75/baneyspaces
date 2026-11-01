# Devices and virtual machines

Donovan, 2026-11-01: "work on for the simulators. and such for devices like android ios, ipad, and
ect. for virtual machines and such." Simulators, emulators and VMs are windows like any other, with
four habits that break a workspace manager: a device has several windows that belong together, some
of them tools; the app resizes its own window (a device rotates, a guest changes resolution); the
app grabs the keyboard while it has focus, so the workspace keys never arrive; and an agent that
starts one starts a tree of processes, not one.

`devices.json` is the table of apps and what each of their windows is for. The macOS app embeds it
(`scripts/gen-device-data.sh` writes `DeviceData.swift`; a test fails when the two differ), the Rust
core includes it. Cases are in `conformance/devices.json` (the model: the Rust core replays every
one; the Mac's window model has hand-written tests for R-D2 to R-D5 in `DevicesTests`) and
`conformance/devices/*.json` (classification, geometry, keys, process trees: both implementations
replay all of them).
`docs/devices-and-vms.md` is the survey: each app, what breaks, the fix and how it was verified.

## The table

An app is matched by what the platform knows: macOS `bundle` (exact) or `process` (the executable's
name), Linux `class` or `process`, Windows `exe`. A name is exact, or a prefix when it ends in `*`;
case does not matter. A name that is also used by other programs (`qemu-system-*` is every QEMU, not
only the Android emulator's) matches only together with a marker of the app: `process_arg` (the
process was started with that argument; the emulator's QEMU has `-avd`, a plain QEMU never does) or
`process_title` (the window's title starts with it). Each app lists its window rules in order, and
the first one that hits wins. A rule can test the title (`title_prefix`, `title_contains`,
`title_is`, `title_empty`), whether the window is a standard one (`standard`), and the `platform`;
it gives the window a `role`, and optionally `"home": "agent"` (with `"only_if": "sandbox_process"`,
below).

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
standard window is `main`, anything else `ignore`. A window of a device app that no rule names is
plain too: a standard one is `main`. There is no catch-all companion, so a dialog the table does not
know stays an ordinary window; a companion is a window that matches a companion rule (the Android
emulator's "Extended Controls", its toolbar titled "Emulator", any of its non-standard panels, and on
Linux an untitled window). A plain QEMU VM, which shares the `qemu-system-*` name, is not the
Android emulator and is untouched.

The role is decided again when the title changes (an emulator opens untitled): Linux on Hyprland's
`windowtitlev2`, the Mac on every scan, which it repeats 1, 3 and 5 seconds after a device window
opens. A companion that turns out to be a window is counted from then on (`reclassify`).

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
guest never sees them. macOS: a key bridge, an event tap at the head of the HID list while such an app is in front
(`DeviceKeys` decides, `KeyBridgeState` holds what the tap thread and the main thread share behind one
lock; `conformance/devices/keys.json`). The order of `CGGetEventTapList` is not documented, so the bridge
makes its tap again only when a key-taking tap from another process appears that was not there when
ours was made, and at most every 5 seconds. Linux: every
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
grandchild. macOS records every descendant with its start time twice a second while its parent is alive, so a
child that is reparented to launchd afterwards (`sh -c 'emulator ... &'` exits) stays the agent's; Linux
uses the launch token every descendant inherits. A process that was reparented before the next
recording, or was never recorded, is not the agent's (`conformance/devices/placement.json` states both).
A pid that was reused by an unrelated process is not a descendant.

### R-D9 The sandbox view lives on the agent workspace

A Tart window whose title starts with `bsx-` (the BaneySpaces sandbox) goes to the agent workspace,
and never takes the focus or a workspace (`R-G1`), but only when its process is one the sandbox
started (`only_if: sandbox_process`; the Mac sandbox registers the VM processes it launches by pid and
start time). A stranger's window that happens to be titled `bsx-...` is left alone. Linux has no
such process yet. A platform passes the model's `pin` only for a window of a process it started itself.

### R-D10 A fixed aspect ratio floats

On a compositor that tiles, an app with `float` opens floating. Tiling stretches an emulator's
window out of its aspect ratio and fights the app every time the device rotates. Linux: a Hyprland
window rule generated from the table's window classes into the include (never a title: a browser tab can
be titled "Android Emulator"), and the daemon floats a window the table identifies by its command line
when it opens.

## Full screen

A VM or emulator in macOS full screen is a window on its own Space; everything above stops at the
edge of what Accessibility can see from the current Space. That is the separate fix on branch
`fix/fullscreen`; this change adds nothing to it and depends on it for the cases listed in
`docs/devices-and-vms.md`.
