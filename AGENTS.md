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
| Windows slide to and from the bottom-right corner | 10-10, 10-12 (×2), 10-13 | `9801f13` hid apps instead of parking. `9512b94` brought parking back for the Keep Usable by Automation list (Helium, Cua Spaces). `5d080f0` only hid the slide from view. | `motion-probe.swift` |
| ⌘Tab window bar glitches or comes up wrong | 10-12, 10-13 | #4, #5, #6, #8 | none yet; add one |
| Holding Tab lands on the wrong app | 10-12 | #6 | none yet; add one |

Never trade away a fix Donovan asked for to make agents' work easier (the `9512b94` mistake)
without asking him first. When the two conflict, his visible desktop wins.
