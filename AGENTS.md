# BaneySpaces agent rules

BaneySpaces is a macOS workspace manager: ⌘1–9 switch workspaces, ⌘⇧1–9 move a window, plus
the ⌘Tab window bar, the Workspace Dock and the launcher. Donovan uses it all day, so a bug he
sees twice costs more than a slow release.

## Done

A change is done when all of these pass on the installed build (`make install`):

1. `swift test`
2. `scripts/bench.sh` (median no-op switch under 40 ms; p90 of your real switches in `timing.log` under 250 ms).
   Exit 3 means fewer than 20 real switches since the build started: make them, or report "real-use budget unchecked".
3. For anything that hides, parks, moves or restores windows: `swift scripts/motion-probe.swift <a> <b>`
   with Helium or Ghostty on one of the two workspaces. It must print "no window slid".
   For anything that decides which windows exist or where they live: `swift scripts/closed-window-probe.swift <empty n>`.
   For the drag to the top of the screen (`TopDrag`, `TopDragWatcher`, the viewer's carrying mode):
   `swift scripts/top-drag-probe.swift`. It takes the pointer for ten seconds; run it while Donovan is away.
   For a window dragged down to the dock (`DockCarry`, `WorkspaceDock.carryMoved`/`endCarry`, the watcher's
   `onCarry`): `swift scripts/dock-drag-probe.swift`, also while he's away.
   For anything that decides what each display shows (`Workspaces.shown`, `displays`, `carry`,
   `noteMovedAcrossDisplays`): `swift scripts/displays-probe.swift` with two displays (Sidecar counts).
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
| The dock's agent spinner stays on (T3 Code) after the agent stopped | 10-28 | Never guarded. Every session in an app with no terminal of its own (T3 runs many) competed for the app's one window, and the first to bind kept it; a turn stopped from T3 or with Esc sends no hook, so it stayed "working" until the 6-hour expiry. Fixed by sharing the window (`AgentSessions.outranks`) and `AgentSessions.activity` (15-minute stale limit where the title can't speak; Claude's idle title wins after staying idle 5 s). The SwiftUI `repeatForever` spinner also froze after the panel hid; it's a Core Animation layer now. | `SharedWindowTests` |
| The dock stays up with the pointer near it, not on it | 10-29, 10-31 (×3 recordings) | Never guarded. The keep zone came from the panel, which holds a 24 pt label row above a bottom dock and is at least 480 pt long, plus 24 pt of slack: the dock stayed up with the pointer ~50 pt above the bar or ~100 pt beside it, over the app underneath. #43 fixed a different hold (a stale menu flag). Fixed by `DockEdge.keepZone(bar:panel:sideOpen:screen:)`: the bar you see plus 12 pt, or the whole panel only while the window strip or "+N" list is open. `trace.log` (and the unified log, subsystem `com.baney.baneyspaces`) now says `dock up: <edge> edge, pointer …`, `dock down: pointer left at x,y after Ns up`, and `dock held 2s off the bar by strip|more|unmoved|menu|drag` (or `dock held 2s with the bar unmeasured`). A dock keeps the pointer that brought it up while it stays still on that edge (`DockEdge.openerHolds`), since the edge that opens it is sized from the bar as last measured; a still pointer anywhere else never holds it, and a rebuilt panel keeps the first point. Known limit: if the bar came up shorter and the pointer moves off the edge before reaching the new bar's zone, the dock goes down after the away delay. | `DockKeepZoneTests`; `swift scripts/dock-keep-zone-probe.swift` (takes the pointer; run while Donovan is away) |
| Dragging a window to the top no longer fills the screen | 10-28 | `4f7ea9c` (#25) switched macOS's `EnableTopTilingByEdgeDrag` off along with Mission Control when the overview took the drag. Fixed by leaving fill-the-screen to macOS and turning it back on once (`SystemTopDrag.giveFillBack`). | `TopDragTests.testTheDragToTheTopLeavesFillTheScreenOn`; `top-drag-probe.swift` case 5 |
| macOS Mission Control still opens from the trackpad swipe or a hot corner, next to the overview | 10-31 | Never guarded. Only the Mission Control key and ⌃↑ were caught (`MissionControlKeys`); the Dock opens Mission Control on its own from the trackpad and hot corners. Fixed by switching it off at the Dock (`com.apple.dock mcx-expose-disabled`) and answering each way in: `TrackpadSwipe` (private MultitouchSupport, loaded at run time; `FingerSwipe` decides) and `HotCornerWatcher` for corners that were set to 2, remapped to 1. `MissionControlTakeover` saves what was there and puts it back (switch off, quit, Accessibility lost, `--restore-dock`, `uninstall.sh`; only an update's quit leaves it for the new build). A launch agent (`MissionControlWatchdog`, `uninstall.sh --restore-mission-control`) restores it when no BaneySpaces has run for 60 s (30 s after an update's quit). Trackpads are listed once and on IOKit notices, by device id (`MTDeviceCreateList` returns new objects every call), and `TouchFrameReader` proves the private 96-byte layout before trusting it. It is the switch `MissionControlKeys.enabled` (`viewerReplacesMissionControl`). | `MissionControlTakeoverTests`, `FingerSwipeTests`, `TouchFrameTests`, `MissionControlWatchdogTests`, `MissionControlGuardTests`, `UninstallTests` (`testWithoutTheAppMissionControl…`); live: swipe up with 3 or 4 fingers, push the pointer into a former Mission Control corner, press Control-Up and F3, each must show the BaneySpaces overview and never the "Desktop" view; `defaults read com.apple.dock mcx-expose-disabled` is 1 while on; `trace.log` says `trackpad swipe up` / `hot corner` |
| ⌘Tab window bar glitches or comes up wrong | 10-12, 10-13 | #4, #5, #6, #8 | none yet; add one |
| Holding Tab lands on the wrong app | 10-12 | #6 | none yet; add one |

Never trade away a fix Donovan asked for to make agents' work easier (the `9512b94` mistake)
without asking him first. When the two conflict, his visible desktop wins.
