# BaneySpaces agent rules

BaneySpaces is a macOS workspace manager: ⌘1–9 switch workspaces, ⌘⇧1–9 move a window, plus
the ⌘Tab window bar, the Workspace Dock and the launcher. Donovan uses it all day, so a bug he
sees twice costs more than a slow release.

## Done

A change is done when all of these pass on the installed build (`make install`):

1. `swift test`
2. `scripts/bench.sh` (median switch under 40 ms)
3. For anything that hides, parks, moves or restores windows: `swift scripts/motion-probe.swift <a> <b>`
   with Helium or Ghostty on one of the two workspaces. It must print "no window slid".
   For anything that decides which windows exist or where they live: `swift scripts/closed-window-probe.swift <empty n>`.
   For the drag to the top of the screen (`TopDrag`, `TopDragWatcher`, the viewer's carrying mode):
   `swift scripts/top-drag-probe.swift`. It takes the pointer for ten seconds; run it while Donovan is away.
4. The gesture Donovan reported, done live through cua-driver on his Mac (the real keys, the
   real hold, the real click), with the result read back from the screen, `trace.log` or
   `state.json`.

Unit tests and CI only prove the plan logic. They have never caught a visible bug here. If step 4
can't run, say "untested live" in the report and don't call the bug fixed.

## Regression ledger

These bugs came back after a reported fix. Read this before touching the code each one names.
When one returns, add the date and the commit that brought it back.

| Bug Donovan sees | Reported | Fixed, then broken by | Guard |
| --- | --- | --- | --- |
| Windows slide to and from the bottom-right corner | 10-10, 10-12 (×2), 10-13 | `9801f13` hid apps instead of parking. `9512b94` brought parking back for the Keep Usable by Automation list (Helium, Cua Spaces). `5d080f0` only hid the slide from view. Root cause (10-13): apps with `AXEnhancedUserInterface` on animate every Accessibility move; `Window.withoutAnimation` turns it off for each move. Every app split across workspaces (Ghostty) slid until then. | `motion-probe.swift` (10-13: 26–30 positions per window before, none after) |
| Going to an empty workspace pulls you back to another one | 10-13 | Never guarded. Hiding the app in front makes macOS activate the next app (Finder, Ghostty), and `followFocus` followed it. Only parked apps were ignored. | none automatic: switch to an empty workspace 5 times and read `current` in `state.json` |
| An app open elsewhere, opened again here, takes you to its old workspace | 10-13 | Never guarded. The app activates ~54 ms before its new window exists (Ghostty, measured). | none automatic: on an empty workspace press Ghostty's new-window key; the window must land there |
| An app doesn't come forward from ⌘Tab, the Dock or the launcher; a workspace shows an app that isn't there | 10-13, 10-14 | Never guarded. Ghostty keeps closed windows alive in the window server, and a background tab looks the same; `Workspaces.sync` kept every alive window, and `focusApp` picked the oldest. Fixed by `closedWindows` and `dormant` in `Spaces.swift`. | `closed-window-probe.swift` |
| BaneySpaces quits by itself (crash in `NSHostingView.updateConstraints`, `DockPanel` in the log) | 10-14 (×2) | Never guarded. The dock's NSHostingView kept SwiftUI's default sizing, which sets the panel's min/max size inside a layout pass while `resize()` also frames it; the label and strip measured over several passes until AppKit threw. Fixed by `sizingOptions = [.intrinsicContentSize]` plus `scheduleResize`. | `DockSizingTests` (source check); `/usr/bin/log show --predicate 'process == "BaneySpaces" AND eventMessage CONTAINS "Update Constraints"'` must stay empty |
| The dock shows the workspace you're on as empty (just a "+") with its windows in plain sight | 10-14, 10-16 | Never guarded. Accessibility answered with nothing for a while, the model dropped every window into `waiting`, and `refresh()` skipped every later scan because the window server's list hadn't changed. It healed only when some window opened or closed. Fixed by `ScanCheck` and `UnplacedWindows`: an on-screen app window with no workspace forces a scan, on its own timer too, backing off 3, 6, then every 12 s for a window that had a workspace, so it heals within 12 s of Accessibility coming back (one that never had one settles to a look a minute). A window that had a workspace is never treated as new when it comes back, so new-window rules can't send it elsewhere and hide it. | `ScanCheckTests`, `UnplacedWindowsTests`; `timing.log` shows `scan=unplaced` when a switch triggers it |
| Settings opens as an invisible window (0×0) | 10-16 (found by the live check, on main too) | Never guarded. `NSHostingView.sizingOptions = [.preferredContentSize]` reported a zero fitting size on macOS 27, so `setContentSize` made the window 0×0. Fixed with `.intrinsicContentSize` plus a resize on every model change. | `BaneySpaces --check-settings` (exit 1 on an empty or too-tall tab) |
| Dock tiles slide sideways over each other when hovered | 10-19 | Never guarded. `.animation(_, value: hovered)` on each tile, icon and button animated every change in that update, including the bar re-centering when the hover label changed the dock's width. Fixed by `HoverScale`, which springs only the scale. | `DockHoverMotionTests` (source check) |
| The dock never comes up from the edge | 10-25 | Never guarded. `otherMenuOpen()` held the dock back while any other app had a window at the pop-up menu level on screen, anywhere. macOS 27's MenuBarAgent left an empty one under the menu bar for hours. Fixed by `MenuWindows` (one on screen over 30 s isn't a menu) and `DockEdge.menuInTheWay` (only one within 48 pt of the pointer counts). | `DockEdgeTests.testOnlyAMenuNearThePointerHoldsTheDockBack`, `testAMenuWindowUpForLongIsNotAMenu` |
| ⌘Tab window bar glitches or comes up wrong | 10-12, 10-13 | #4, #5, #6, #8 | none yet; add one |
| Holding Tab lands on the wrong app | 10-12 | #6 | none yet; add one |

Never trade away a fix Donovan asked for to make agents' work easier (the `9512b94` mistake)
without asking him first. When the two conflict, his visible desktop wins.
