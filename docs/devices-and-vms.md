# Simulators, emulators and virtual machines

Donovan, 2026-11-01: "work on for the simulators. and such for devices like android ios, ipad, and
ect. for virtual machines and such." This is the survey for part A (window management): each app,
what breaks a workspace manager, the fix, and how the fix was checked. The rules are in
[spec/devices.md](../spec/devices.md); the table of apps is [spec/devices.json](../spec/devices.json).
Part B (agents driving devices through `simctl`, `adb` and friends) is separate.

## What was checked, and where

| Check | Where | Result |
| --- | --- | --- |
| Spec cases (model, classification, geometry, keys, process trees) | `cargo test --workspace --locked` | 41 core tests, 52 Linux daemon tests |
| The same cases, the macOS window model, and the app builds | `swift test` on rectory1 (Mac, macOS 27.2) | 743 tests |
| A two-window emulator in a nested Hyprland: toolbar follows, is not counted, comes back when dragged off, window floats, 29 binds ignore a keyboard grab | `platforms/linux/tests/nested.sh` | 374 checks, real session unchanged |
| Real apps on a real desktop | rectory1, only when Donovan has been idle 10 minutes | **Not run.** He was at the keyboard on every check (HID idle 0.3 to 0.4 s). Every row below says what is untested live and the steps. |

Installed on rectory1 (read-only look, nothing installed): Xcode 27 with iOS 26.5/27.0, tvOS,
watchOS and visionOS runtimes and `simctl`, **but no Simulator.app** (Xcode 27 here ships none, so
the Simulator rows can only be checked with a machine that has it); Android SDK with `emulator` and
the `Pixel_9_API_35` AVD, and `adb`; Tart 2.41.1 (two sandbox VMs run headless, owned by another
job, untouched). Not installed: UTM, Parallels, VMware Fusion, VirtualBox. On the Linux machine used
for the nested test: `qemu-system-x86_64`; no virt-manager, virt-viewer, GNOME Boxes or Android
emulator.

## Survey

The titles and process names in the table come from each app's documentation and from what the
Android emulator's Qt build is known to do. None of them has been read off a live window yet, which
is why the emulator's rule list ends in a catch-all `companion` instead of naming its windows: a
title that is different from what is listed still follows its window.

| App | Problem | Fix | Verified how |
| --- | --- | --- | --- |
| **Simulator.app** (iPhone, iPad, Watch, TV, Vision), macOS | A device is a window with the bezel drawn inside it, one window per device, one process for all. Rotating a device swaps the window's width and height. A window parked on another workspace and restored put the old size back, which un-rotates it. | `resizes_itself`: restore keeps the current size and the saved origin, slid into the display (R-D6). Device windows stay ordinary `main` windows, so each moves on its own. | Geometry cases in `swift test`. **Untested live**: Simulator.app is not on rectory1. Steps: boot an iPhone, put its window on workspace 3, leave it with ⌘4, rotate the device (Device > Rotate) while it is away, come back; the window must be landscape and fully on screen. |
| **Android Emulator**, macOS (Qt, `qemu-system-*`) | The toolbar and "Extended controls" are separate windows, usually panels (not `AXStandardWindow`), so BaneySpaces ignored them: they stayed on screen when the device moved to another workspace. The window is aspect locked and rotates itself. `qemu-system-*` is also every plain QEMU, which must not be taken for the emulator. | The emulator is found by its own markers: the `emulator` launcher, or a `qemu-system-*` started with `-avd` (read from the process's command line), or one whose window is titled "Android Emulator". Companions are named by rules: "Extended Controls", the toolbar titled "Emulator", any non-standard panel; there is no catch-all, so every other window of the process (a crash dialog) is an ordinary window. A companion joins its window's workspace, is hidden, parked and restored with it from its own saved frame, and is never counted (R-D2, R-D3). Rotation: R-D6. A toolbar at window level 3 also triggers a rescan; titles are read again 1, 3 and 5 s after a window opens. | Classification cases, including a plain QEMU Cocoa VM and an oddly titled dialog; `Workspaces` tests; the suite builds and passes on the Mac. **Untested live** (SDK and AVD are there): start `~/Library/Android/sdk/emulator/emulator -avd Pixel_9_API_35`, open Extended controls, press the move key for another workspace, then come back: toolbar and controls must leave and come back with the device; `state.json` must list one window for the app. |
| **QEMU** (Homebrew `qemu-system-*`, Cocoa display), macOS and Linux | Shares the Android emulator's process name. | Not the emulator without `-avd` or an "Android Emulator" title (R-D1): an ordinary window, not floated. | Classification cases on both platforms; `nested.sh` runs a process named `qemu-system-x86_64` with and without `-avd` (this machine's QEMU has no window backend). |
| **Android Emulator**, Linux (X11 through XWayland, Hyprland) | Same toolbar problem. Hyprland tiles the window and stretches it out of its aspect ratio. | The daemon classifies by window class, process name, command line and title (re-read when the title changes, `windowtitlev2`); companions are gathered (R-D2, R-D4, R-D5). The generated Hyprland include floats the emulator's classes, and the daemon floats one it identifies by `-avd` (R-D10). | `nested.sh` with a two-window test app of class `Emulator`: toolbar on the same workspace, one window counted, `move` takes both, a toolbar moved alone comes back, the main window floats; a window that opens untitled and is titled 0.8 s later ends up a counted main window; a stand-in process named `qemu-system-x86_64` with `-avd` is floated by the daemon. Not run against the real emulator (not installed here). |
| **Android Emulator**, Windows | Same as Linux. | In the table (`qemu-system-*`, `emulator.exe`); the Windows daemon is `windows/part1`'s. Follow-up: feed `classify` from `EnumWindows` and the exe name. | Table case only. |
| **UTM** (QEMU, Apple Virtualization), macOS | Takes system keys with an event tap while a VM window has focus: ⌘1-9 never reach BaneySpaces. The guest resizes the window when its resolution changes. | Key bridge (R-D7) and R-D6. The bridge's shared state is behind one lock and has a stress test. Always-works escapes: `baneyspaces switch N`, the dock, menu bar and overview, and UTM's own release chord, Control+Option. | Key and geometry cases; the bridge compiles and is covered by `DeviceKeys` tests. **Untested live** (UTM is not installed): see "Keys" below. |
| **Parallels Desktop**, macOS | Same key grab (it also takes ⌘ shortcuts for the guest). Coherence shows guest windows as host windows. | Key bridge. Release: Control+Option. Coherence windows are ordinary windows of Parallels' VM process and are managed like any other. | Cases only. **Untested live** (not installed). |
| **VMware Fusion**, macOS | Same key grab. | Key bridge. Release: Control+Command. | Cases only. **Untested live** (not installed). |
| **VirtualBox**, macOS | Auto-captures the keyboard; the Host key (Left ⌘ by default) releases it. | Key bridge. Release: the Host key. | Cases only. **Untested live** (not installed). |
| **Tart** VM window, macOS | Captures system keys only with `--capture-system-keys`; the window follows the guest's resolution. | `resizes_itself`. No bridge (nothing is captured by default). | Cases. Tart is installed but its two VMs run headless (no window to look at), so **untested live**. |
| **The BaneySpaces sandbox view** (a Tart window named `bsx-...`) | It must be on the agent workspace and must never take focus. A stranger's window with a `bsx-` title must not be moved. | `home: agent, only_if: sandbox_process` (R-D9): the scan pins the window only when its process is one the sandbox registered (pid and start time, recorded when the sandbox claims its VM window), and the focus guard (R-G1) applies. Mac only: Linux has no such process. | Classification case; `DevicePlacement` driven with the real `Workspaces` (an owned and a foreign window); a source check that the scan, `Windows.all` and the app wire it. **Untested live** (no sandbox VM window was up). The sandbox itself is #111. |
| **virt-manager, virt-viewer, remote-viewer, GNOME Boxes**, Linux | Ask the compositor to stop handling shortcuts while they have focus (keyboard-shortcuts-inhibit), so Super+N did nothing inside the guest. | Every BaneySpaces bind in the generated include carries `dont_inhibit` (Hyprland's bindp), R-D7. Release chord: Control+Alt. | `nested.sh` loads the include with `hl.bind` wrapped and reads `dont_inhibit` off all 29 binds. **Untested with a real viewer** (none installed): in virt-viewer press Super+3. |
| **Hyper-V vmconnect, VMware, VirtualBox**, Windows | Windows key combinations go to the guest or the host depending on the viewer's setting; the full screen connection bar is a separate window. | Table entries and the release chords. The shell is `windows/part1`'s: it must feed `classify` and keep the `Alt+N` default, which a guest does not take from vmconnect unless the Local resources option says so. | Table cases only. Follow-up. |

## Keys

Where a VM takes the keyboard, the workspace chords still work:

- **macOS**: while UTM, Parallels, VMware Fusion or VirtualBox is in front, BaneySpaces holds an event
  tap at the head of the HID list (`DeviceKeyBridge`). It takes only the workspace modifier with 1-9
  (switch) and with ⇧ 1-9 (move), and swallows the key up too. Every other key goes to the guest.
  Every 2 s it reads `CGGetEventTapList`; if an app's tap that can swallow keys has got ahead of it,
  it makes its own again (`DeviceKeys.shouldRearm`). Turn it off with
  `defaults write <bundle id> deviceKeysInVMs -bool false`. It is on by default because ⌘1-9 in a
  guest is rarely what the person wants while they use workspaces.
- **Linux**: `dont_inhibit` on every bind.
- **Windows**: not in this change.

Escapes that always work, per app, because they need no key the VM can take: `baneyspaces switch N`
(from a terminal, ssh or a hook), the menu bar item, the Workspace Dock and the overview with the
pointer, and the app's own release chord (UTM and Parallels Control+Option, Fusion Control+Command,
VirtualBox its Host key, virt-viewer Control+Alt). With the pointer captured, release it first.

Live steps (needs Donovan away): with UTM or VirtualBox in front and a guest running, press ⌘3; the
workspace must change, the guest must not see the key, and `trace.log` must say
`device keys: watching workspace keys while utm is in front`.

## Full screen

A VM or an emulator in macOS full screen is a window on its own Space, which Accessibility cannot
list from another Space. That is the separate fix on `fix/fullscreen` (the worktree
`bs-fullscreen` on rectory1 has no commits yet). This change does not touch full screen and depends
on that one for: a companion of a full screen emulator (its toolbar is on the same Space, so it is
unreachable until the window leaves full screen), and a VM viewer's own full screen mode (VMware,
VirtualBox and Parallels draw their own, which is not a macOS Space and needs no fix). Once the
full screen fix lands, re-run the rows above with the device in full screen.

## Agent workspace placement

An emulator is `emulator` which starts `qemu-system-*`: the window belongs to a grandchild. A claim
made on the process BaneySpaces started now also covers its descendants (R-D8), and a later window of
any descendant goes to the agent workspace. A pid that was reused by another process is never a
descendant (start times are compared). Linux already tracks descendants through the launch token
every child inherits. Whether an agent may start a simulator at all is part B.
