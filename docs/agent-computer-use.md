# BaneySpaces agent computer use

Decided 2026-10-31 (Donovan): BaneySpaces is the fleet's computer-use layer on the Mac. Cua's driver
and Cua Spaces are removed from every machine. Tabkyra stays the way agents read and act on pages in
Donovan's own Helium tabs. Everything else an agent does in a desktop app, any browser included, goes
through BaneySpaces.

## Why ours can beat both

Every other computer-use tool is a guest on the desktop. It has to guess which window is safe to touch,
and it fights whatever manages the windows. On 2026-10-31 that fight was visible: Cua's stock driver
(0.34.1) raised apps on Donovan's workspaces, BaneySpaces followed each activation, and the screen
jumped. BaneySpaces owns workspaces, window placement and focus following, so it can make guarantees
a guest can't:

1. **Agents never take your screen.** Agent windows live on the agent workspace, parked out of view
   but still drivable. An activation BaneySpaces caused for an agent is never followed. Nothing an
   agent does changes your workspace, your front app, your pointer or your keyboard focus.
2. **Your workspaces are off limits by default.** An agent acts only on windows on the agent
   workspace, or on an app you lend it for a task (`agent lend Excel`), and you get it back when the
   task ends.
3. **Every action is checked.** Each action returns evidence from the exact window it targeted (an
   accessibility diff, a value read back, a window capture hash), never "sent, probably worked".
4. **It refuses instead of guessing.** If no safe route reaches the exact window, the action fails
   with a reason and a suggestion. There is no fallback to global keyboard or mouse input, no app
   activation and no Space change.

## What we take from whom

| From | What | License |
| --- | --- | --- |
| agent-desktop (Vercel Labs) | The observation and semantic-action engine through its C library (`libagent_desktop_ffi`): accessibility snapshots with refs, strict fail-closed ref resolution, the evidence tri-state, partial observation, web-wrapper collapsing, 56 commands. Built from source at a pinned commit with its `Cargo.lock`, never through npm's postinstall. | Apache-2.0, NOTICE kept |
| cua-driver (trycua) | The background-input rules from its `macos-background-input-v1-plan`: every action carries an exact `(pid, CGWindowID)`; routes in order semantic AX, exact browser target, window-local pointer, per-process keys with delivery proof; SkyLight per-process event posting for canvas apps; per-process AX enablement for Electron. Ported to Swift where we need them. | MIT, attributed |
| BaneySpaces | Workspaces, parking, the focus watcher, the agent workspace, the deck, remote (tailnet) and the dock. The part neither of them has. | MIT |

Before the engine goes in, `tools/vet_supply.py` from BaneyFleet runs on the pinned source. Its first
run (2026-10-31, commit 5261b52) came back `ask`: new to the fleet, no release attestations, and three
RustSec advisories with unknown severity in Linux-only D-Bus crates the macOS build does not link.
Donovan's direction to build on it is the decision; the pin and the advisory check go in the build.

## Interface

One command family and one MCP server, the same verbs either way:

```sh
baneyspaces agent snapshot --app TextEdit -i        # refs for what an agent can act on
baneyspaces agent click @s1:e8                      # act on a ref; prints the evidence
baneyspaces agent type @s1:e3 "Hello"               # set-value when safe, keys when not
baneyspaces agent open Safari https://example.com   # on the agent workspace, you stay put
baneyspaces agent shot --window 4211                # one window, even while parked
baneyspaces agent lend Excel / agent return Excel   # borrow an app from your workspaces
baneyspaces mcp                                     # stdio MCP server with the same tools
```

Output is one JSON envelope per command: `ok`, `data` or `error` with `code`, `retry` (`safe`,
`after_snapshot`, `never`) and a `suggestion`. `remote` (tailnet, token) exposes the same tools to
other machines, look-and-act on the agent workspace only.

## Browsers

All of them, without taking the screen:

- **Chromium family** (Helium, Chrome, Edge, Brave, Arc, Electron apps): per-process
  `AXManualAccessibility` so the page tree is real, refs into page content, and for a browser
  BaneySpaces starts on the agent workspace, an isolated profile with a DevTools endpoint bound to
  localhost so page actions are exact. Donovan's signed-in profiles are never opened with DevTools.
- **Safari**: accessibility tree of the page; navigation through the address field ref.
- **Firefox**: `accessibility.force_enabled` in the agent profile, then the same tree.
- **Helium tabs Donovan is using**: Tabkyra, as today.

## Phases

| Phase | Ships | Done when |
| --- | --- | --- |
| 1 | Engine linked in; `agent snapshot/find/get/click/type/set-value/press/scroll/select/toggle/shot/open/lend/return`; MCP server; focus-watcher tag so agent activations are never followed. | `scripts/agent-hands-probe.swift`: 200 actions in TextEdit, Finder and Notes on the agent workspace while the probe records the front app, the current workspace, the pointer and the key window every 50 ms; zero changes. Plus `swift test`. |
| 2 | Browsers and Electron as above. | The probe passes on Helium (agent profile), Safari, Firefox, Chrome and Obsidian, with a page form filled and read back in each. |
| 3 | Window-local pointer and per-process keys (SkyLight) for apps without a usable tree; the refusal contract. | Canvas app drawn on from behind with zero changes on the probe; every refused route returns a suggestion. |
| 4 | Head-to-head: the same 30 tasks through agent-desktop, Cua's driver (in a VM, not on Donovan's Mac) and BaneySpaces, scored on success, screen changes and time. Fleet routing (skills, ROUTING.md, the live-checker agent) switches to BaneySpaces. | BaneySpaces wins or ties every column; the numbers are committed under `evidence/`. |

## Rules that do not bend

- No global HID events from agent actions, ever.
- No `activate`, `SetFrontProcess` or Space change on behalf of an agent.
- No action on a window outside the agent workspace unless that app is lent.
- Snapshots and captures can hold private content: they stay on the Mac unless the caller asks, and
  never go into logs.
