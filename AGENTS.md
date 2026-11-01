# BaneySpaces agent rules

BaneySpaces is a macOS workspace manager: ⌘1–9 switch workspaces, ⌘⇧1–9 move a window, plus
the ⌘Tab window bar, the Workspace Dock and the launcher. Donovan uses it all day, so a bug he
sees twice costs more than a slow release.

## Done

A change is done when steps 1–3 pass on its branch and step 4 passes on `main` right after merge (only `main` is installed on Donovan's Mac). If step 4 fails after merge, revert the merge first, then fix:

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
   For the dock's own motion or the "+N" list/strip panel (`DockSide`, `DockMotion`, `WorkspaceDock.show/hide/syncSide`):
   `swift scripts/dock-motion-probe.swift` (no pointer; it shows the dock for about four seconds, so run it
   when Donovan has been idle 10 minutes; it needs `dockURLCommands` on and a tile with more than four apps).
   For anything that posts keys or pointer events to agent windows (`BackgroundPoster`, `HandsRouter+Background`,
   `BackgroundPlanner`): `swift scripts/agent-keys-probe.swift`, only when Donovan has been idle 10 minutes (it prints
   "untested live" and exits 3 otherwise); it needs the build under test installed, so it runs on `main` right after merge.
   For the agent cursor (`Sources/BaneySpacesCursor`, `CursorDirector`, `CursorVisibility`, `GlidePlan`):
   `swift run -c release cursor-probe` (100 glides on the display, frame times, the real pointer; the cursor is visible
   while it runs, so run it when Donovan has been idle 10 minutes; it refuses to start otherwise and fails if nothing drew).
   For anything that decides what each display shows (`Workspaces.shown`, `displays`, `carry`,
   `noteMovedAcrossDisplays`): `swift scripts/displays-probe.swift` with two displays (Sidecar counts).
   For anything under `Sources/BaneySpacesCore/Sandbox/`: `swift scripts/sandbox-probe.swift` (headless, no window; needs
   Tart, Softnet and the pinned image per `sandbox/PIN`, and the sandbox must not be in use by the app: if it is on in
   Settings > Agents the probe says SKIPPED and exits 2, so turn it off there first). It must print "sandbox-probe PASS". `view` and Settings > Agents
   put a window on screen: try them only when he has been idle 10 minutes.
4. The gesture Donovan reported, done live on his Mac (the real keys, the real hold, the real
   click), with the result read back from the screen, `trace.log` or `state.json`. Pointer and key
   probes run only when he has been idle 10 minutes (`ioreg -c IOHIDSystem` HIDIdleTime); otherwise
   the PR lists the exact steps for him to try and says "untested live". Agent tools
   (`baneyspaces agent`) act only on the agent workspace or the sandbox, so they can't stand in for
   a gesture on his own workspaces. Only `main` is installed on his Mac: branches build and test,
   and never run `make install` there.

Unit tests and CI only prove the plan logic. They have never caught a visible bug here. If step 4
can't run, say "untested live" in the report and don't call the bug fixed.

## Run and check

Crash-loop guard (`CrashLoopGuard`, checked in `main.swift` before the delegate exists): a launch
whose run is still in `~/Library/Application Support/BaneySpaces/crash-ledger.json` (no clean quit)
counts as a crash. After 3 within 5 minutes the next launch puts Mission Control, the macOS Dock and
the drag to the top back, says so in an alert (Quit, or Start Anyway, which clears the crashes) and
doesn't start. `--render` keeps its own `crash-ledger-render.json` and exits 75 instead. Knobs:
`defaults write com.baney.baneyspaces crashLoopLimit -int N` (0 never stops) and
`crashLoopWindowMinutes -float M`.

Logs: every guarded launch writes `launch: BaneySpaces <version> (<commit>), normal|setup|render, pid N`,
then `crash loop: start|stop (<mode>), N of 3 crashes in 5 minutes, ledger ~/…/crash-ledger.json`. A stop
adds `crash loop: Dock and drag to the top restored, Mission Control saved settings restored|no saved settings changed` (its time is
when Mission Control came back), then `Quit, staying stopped` or `Start Anyway, N crashes forgiven`; a clean
quit writes `crash loop: clean quit (<mode>), pid N cleared from the ledger`. The text lives in
`CrashLoopReport` (pinned by `CrashLoopReportTests`). Read it back from the file
(`grep -E 'launch:|crash loop:' ~/Library/Application\ Support/BaneySpaces/trace.log`, epoch seconds first;
the file rotates at 200 KB into `trace.log.1` and `trace.log.2`) or the unified log, which survives rotation:
`/usr/bin/log show --last 1h --predicate 'subsystem == "com.baney.baneyspaces"' | grep -E 'launch:|crash loop:'`.
The crash itself is in `~/Library/Logs/DiagnosticReports/BaneySpaces-*.ips`. These lines hold counts, pids,
the build and `~` paths, never window titles or the user name; keep it that way.

## Linux (`platforms/linux`, `crates/`, `spec/`)

A change there is done when `cargo test`, `platforms/linux/tests/omarchy-scripts.sh` and
`platforms/linux/tests/nested.sh` pass (nested.sh runs its own headless Hyprland and prints PASS or
FAIL with counts and whether the real session changed). Never edit or reload the live Hyprland config
or session to test: use nested.sh. A rule that is not in `spec/` does not ship on one platform alone.

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
| The "+N" list and the dock stay up for seconds with the pointer far to the side of the list; the dock pops in and out, and jumps or draws the list clipped when the list opens | 10-31 (23:31 recording) | Never guarded. While the list or window strip was open `DockEdge.keepZone` counted the whole dock panel (480 pt or more) again, so the pointer 100 pt beside the list held both, and the list was part of the dock's own SwiftUI stack: opening it resized the panel a run-loop turn after the content had moved. Fixed by giving the list and strip a panel of their own (`DockSide`, a child of the dock's), so the dock panel's size and bar never change for them, and by `DockEdge.keeps(_:bar:panel:side:screen:)`: the bar plus the list's own frame, each with 12 pt, and nothing else. A list closes 250 ms after the pointer leaves it and its tile (`DockSideGrace`); Esc and a click outside close it at once. `trace.log` says `dock list closed (more\|strip): pointer left it at x,y\|Esc\|click outside\|…` and `dock list open: …`. Motion (`DockMotion`): the dock 8 pt in and fade 180 ms, the list from 96% and fade 140 ms in / 100 ms out, rows 80 ms, drag lift 1.04; each scoped to its own view or panel, all instant under Reduce Motion. | `DockKeepZoneTests.testAnOpenListKeepsTheDockOnlyWhileThePointerIsOnTheBarOrTheList` (fails on the whole-panel zone), `DockSideTests`; `swift scripts/dock-motion-probe.swift` (no pointer; shows the dock for ~4 s) |
| Dragging a window to the top no longer fills the screen | 10-28 | `4f7ea9c` (#25) switched macOS's `EnableTopTilingByEdgeDrag` off along with Mission Control when the overview took the drag. Fixed by leaving fill-the-screen to macOS and turning it back on once (`SystemTopDrag.giveFillBack`). | `TopDragTests.testTheDragToTheTopLeavesFillTheScreenOn`; `top-drag-probe.swift` case 5 |
| (Linux) An agent opens an app that forwards to your running copy, and a window appears in your own process on your workspace | 11-01 (review of #110) | Not preventable after launch: the forwarded window belongs to a process BaneySpaces did not start. Mitigated by deny by default: an app not on the allowlist in `apps.rs` is `needs_sandbox` before launch whether or not you run a copy; the app is a name resolving to the system binary, the only arguments are handoff files, and every agent process has a private session bus (so an agent copy cannot absorb your launches). When an allowed app forwards anyway, by leaving the window where it is and reporting it in `error.data.windows_that_appeared`. | `platforms/linux/tests/hardening.sh` (unlisted app with and without your copy running; bad arguments; `agent run` of a unique app next to yours; the forwarded-window report via the test-only `test_open`) |
| macOS Mission Control still opens from the trackpad swipe or a hot corner, next to the overview | 10-31 | Never guarded. Only the Mission Control key and ⌃↑ were caught (`MissionControlKeys`); the Dock opens Mission Control on its own from the trackpad and hot corners. Fixed by switching it off at the Dock (`com.apple.dock mcx-expose-disabled`) and answering each way in: `TrackpadSwipe` (private MultitouchSupport, loaded at run time; `FingerSwipe` decides) and `HotCornerWatcher` for corners that were set to 2, remapped to 1. `MissionControlTakeover` saves what was there and puts it back (switch off, quit, Accessibility lost, `--restore-dock`, `uninstall.sh`; only an update's quit leaves it for the new build). A launch agent (`MissionControlWatchdog`, `uninstall.sh --restore-mission-control`) restores it when no BaneySpaces has run for 60 s (30 s after an update's quit). Trackpads are listed once and on IOKit notices, by device id (`MTDeviceCreateList` returns new objects every call), and `TouchFrameReader` proves the private 96-byte layout before trusting it, never reading past `SafeBuffer.length`. Mission Control is switched off only after the launch agent is loaded (`MissionControlSetup`); the heartbeat holds BaneySpaces' pid and `mission-control=1`, so a renamed bundle still counts as running and an older build never does (no `pgrep`); the record is also a flushed file (`DurableRecord`, `mc-record.plist`) written before any Dock setting, which the agent and `uninstall.sh` read; the 10 s tick gives Mission Control back if the agent is unloaded or the Dock's switch was turned off by hand. `TrackpadRegistry` releases a device list only after its devices are unregistered (`TrackpadRegistryTests` fails on the old order). It is the switch `MissionControlKeys.enabled` (`viewerReplacesMissionControl`). | `MissionControlTakeoverTests`, `FingerSwipeTests`, `TouchFrameTests`, `MissionControlWatchdogTests`, `MissionControlGuardTests`, `UninstallTests` (`testWithoutTheAppMissionControl…`); live: swipe up with 3 or 4 fingers, push the pointer into a former Mission Control corner, press Control-Up and F3, each must show the BaneySpaces overview and never the "Desktop" view; `defaults read com.apple.dock mcx-expose-disabled` is 1 while on; `trace.log` says `trackpad swipe up` / `hot corner` |
| `agent open` leaves the app's launch window on your workspace | 10-31 (found live: TextEdit "Untitled", then Calculator) | Never guarded. For an app that wasn't running, `agent open` started it and only pressed New Window 1.5 s later; whatever the app opened at launch ("restored" in the old comment) stayed on the current workspace, in plain sight. Fixed in `DeckController.agent("open")`: the launch is claimed with `newProcess: true` at once, so every window the process makes in the next 8 s goes to the agent workspace, the bundle is marked in `AgentActivity` before there is a pid (10 s) and the pid for 8 s so the activation a launch causes is never followed, and New Window is pressed only if the app opened no window and no file was given. Round 2: the app starts as a new instance told not to restore state (`-ApplePersistenceIgnoreState YES`), and only apps on `AgentAppPolicy`'s list start at all. Series 2: the claim is made on the process this launch request returned, never on a launch notification for the bundle; every window of an agent process is inspected on each use (a document outside the handoff folder, or an Open/Save panel, is off limits); and every later window of that process goes to the agent workspace too. | `AgentOpenLaunchTests` (source check); `scripts/agent-hands-probe.swift` fails on any "stray window" it sees on a non-agent workspace. Live check: with a quiet Mac, `agent open Calculator` for an app that isn't running; `state.json` must list its window under the agent workspace only |
| ⌘Tab window bar glitches or comes up wrong | 10-12, 10-13 | #4, #5, #6, #8 | none yet; add one |
| Holding Tab lands on the wrong app | 10-12 | #6 | none yet; add one |

Never trade away a fix Donovan asked for to make agents' work easier (the `9512b94` mistake)
without asking him first. When the two conflict, his visible desktop wins.
