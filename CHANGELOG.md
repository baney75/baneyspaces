# Changelog

## Unreleased

Fixes from a second adversarial review, focused on apps that are slow to answer.

- **A busy app no longer stalls a switch.** Raising a window waits at most 0.1 s per call and
  stops at the first timeout, instead of up to 0.75 s; a missed raise is retried a moment later.
- **Closing or minimizing a window keeps you where you are,** even when the app's next window
  lives on another workspace, and even when the app only hid the window it "closed".
- **⌘Q and ⌘W can't reach the app in front while the ⌘Tab switcher is open.**
- **Two windows of one app on different workspaces:** opening the app's other workspace no longer
  bounces you back when the app comes forward late.
- **No window is left parked off screen** after a permission hiccup; Bring Every Window Back also
  rescues windows another tool stranded.
- Saved windows only come back to the app that owned them, a late window doesn't steal a
  workspace's remembered focus, and frozen apps aren't asked again on every scan.
- `state.json` lists apps that aren't answering (`unsure`) and saved windows still waiting for
  theirs (`waiting`).

## 0.2.0 (2026-10-10)

Faster switching, an easier first run, and fixes from an adversarial review.

- **Switching is about six times faster.** A switch that changes nothing on screen dropped from a
  91 ms median to about 15 ms; a real switch takes 20–50 ms. Background apps hide at once, only
  the app in front waits for focus to move (checked every 10 ms), the window scan is skipped when
  no window opened or closed, apps are asked in parallel, and apps with no windows aren't asked
  at all. `make bench` fails if the median goes over 40 ms.
- **Workspaces survive restarts.** Which window lives on which workspace is saved on every
  change and restored when BaneySpaces starts again (an update, a crash, logging back in), so
  nothing gets sent back to workspace 1.
- **⌘Tab can switch workspaces** (optional, in setup): hold ⌘ and tap Tab to step through the
  workspaces that have windows, most recent first; release to go there.
- **A small HUD** shows the workspace grid for half a second on every keyboard switch, and the
  menu bar number changes the moment you press the key.
- **Setup is one button.** Allow BaneySpaces puts it in the Accessibility list and opens the
  right page; setup notices the switch within a quarter second, confirms, and closes itself.
  Fix Permission repairs a permission macOS kept from an older copy.
- **Losing permission is safe.** BaneySpaces gives your keys back, shows every window and app,
  and starts again when permission returns.
- Typing can no longer land in a hidden window after ⌘W or ⌘` moves focus inside an app.
- Rapid presses land on the last workspace pressed instead of replaying each one.
- A hung app is skipped for 5 seconds instead of stalling every switch; a window that refuses to
  leave full screen is no longer asked again on every desktop change.
- Display changes keep focus where it is. Restores move a window without resizing it.
- AeroSpace, Login Items approval and freed screenshot shortcuts are handled in setup, and the
  uninstaller turns the shortcuts back on and clears the permission.

## 0.1.0 · 2026-10-10

The first release.

- Nine workspaces on ⌘1–⌘9. ⌘⇧1–⌘⇧9 sends the front window to a workspace and follows it.
  Pick ⌃, ⌥ or ⌃⌥ instead of ⌘ in setup.
- Windows on other workspaces are hidden by hiding their app, as ⌘H does, so nothing is moved,
  minimized or shown in Mission Control. An app split across workspaces parks its other windows
  just off screen and puts them back exactly.
- The overview: the Mission Control key or ⌃↑ shows all nine workspaces in a 3×3 grid. Click a
  workspace or a window to go there, press 1–9, or drag a window onto another workspace.
- Full screen fills the screen instead of creating a separate macOS desktop, so every window
  stays on a workspace.
- The Dock and ⌘Tab take you to the workspace a window lives on.
- A setup window checks Accessibility access, shortcut conflicts, the overview keys, the number
  of macOS desktops and Open at Login, and fixes what it can in one click.
- Quitting brings every window back; after a crash, the next launch does.
- `baneyspaces://` URLs for scripts: switch, move, restore and viewer.
