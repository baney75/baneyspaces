---
name: baneyspaces
description: See and drive what's open on Donovan's Mac through BaneySpaces - the Deck (every terminal split, browser tab and agent app in one list, with the workspace each is on) and the hands (`baneyspaces agent snapshot|click|type|…`, which read and act on desktop apps on the agent workspace without touching his screen). Use to find which terminal or tab holds something, open a URL, type into another Ghostty terminal, flag a terminal as needing him, or to operate a desktop app (TextEdit, Calculator, Preview, Finder on a handoff folder) the way a person would. Faster and safer than screenshots or GUI clicks.
---

# BaneySpaces Deck

BaneySpaces is the workspace manager on Donovan's Mac. Its Deck wraps Donovan's terminals, browser and coding apps into one
list. `baneyspaces` is its command (`ghostdeck` still works as an alias). It answers in milliseconds and never moves the pointer or
takes focus unless the command is meant to (`focus`).

## Look before you act

```sh
baneyspaces ls            # one row per terminal split, browser tab and agent window
baneyspaces ls --json     # the same with window numbers, folders, ttys, agent state
```

Each row has an ID: `ghostty:<uuid>` (a Ghostty split), `tab:<bundle>:<window>:<tab>` (a browser
or Terminal tab), `win:<CGWindowID>` (any other window). `windowNumber` is the macOS window ID that
`baneyspaces agent windows` and `--window` use, so a row maps straight onto a window you can snapshot.
`activity` is `working`, `waiting` or `shell`. `workspace` > 0 means the row is on another
BaneySpaces workspace.

## Act

| Want | Command |
| --- | --- |
| Bring something forward | `baneyspaces focus <id or words>` (fuzzy: `baneyspaces focus helium github`) |
| Open a page | `baneyspaces open https://…` (default browser, stays in the deck) |
| Type into another Ghostty terminal | `baneyspaces send <id or words> "text"` (pasted, no Return unless you include a newline) |
| Tell Donovan this terminal needs him | `baneyspaces notify "Tests failed, need a decision"` |
| Report your own state (non-Claude agents) | `baneyspaces event --state working\|waiting\|idle\|end --agent <name>` (add `--started` with `working` when a prompt was just submitted in the window in front; `--at <unix seconds>` says when it happened, default now) |

## Rules

- `focus` changes what Donovan sees. Use it only when he asked to be taken somewhere, or when
  you're about to hand him that window. Never `focus` to drive an app: the hands work from behind.
- `send` types into a live terminal. Never send into a terminal running someone else's agent
  turn (`activity` is `working`) and never send commands that delete, push or spend.
- Read state with `ls`, not screenshots. If `baneyspaces` says BaneySpaces isn't running, say so; there is no
  fallback that raises windows or takes the pointer.
- Claude Code sessions report their own state through hooks (`baneyspaces hooks status`). Don't
  call `notify` for an ordinary end of turn; the hook already marks it.

## Drive an app: snapshot, act on a ref, check

`baneyspaces agent …` (or the MCP tools from `baneyspaces mcp`, same names) reads and acts on desktop apps
from behind. It never raises a window, moves the pointer, types into the front app or switches Donovan's
workspace. Every command prints one JSON envelope: `{"ok":true,"data":{…}}` or
`{"ok":false,"error":{"code","message","retry","suggestion"}}`. Branch on `error.code` and `error.retry`
(`safe`: send it again; `after_snapshot`: take a new snapshot first; `never`: don't repeat it).

```sh
baneyspaces agent open TextEdit notes.txt            # lands on the agent workspace; data.window is its id (files only from the handoff folder)
baneyspaces agent snapshot --window 4211 -i          # refs (@s8f3k2p9:e5) for what you can act on
baneyspaces agent type @s8f3k2p9:e2 "Hello"          # act on a ref; data.evidence says what it read back
baneyspaces agent get @s8f3k2p9:e2 value             # check, from the live element
baneyspaces agent click|set-value|toggle|scroll|select|press <ref> …
baneyspaces agent find --window 4211 --role button --name Save
baneyspaces agent shot --window 4211                 # a PNG of that window, even parked (data.path)
baneyspaces agent windows                            # the windows you may use now
```

The loop: **snapshot, act on a ref, check.** Read `data.verified` and `data.evidence` of every action
(`value_readback`, `state_readback` or `ax_diff`); if `verified` is false, `get` or snapshot again before you
go on. A ref belongs to the snapshot that printed it and fails closed when the UI changed: on `stale_ref` or
`unknown_ref` take a new snapshot, never guess a neighbor.

Scope rules, enforced by the app, not by your good behavior:

- You may act on a window only if it is on the agent workspace or its app is lent. Anything else returns
  `outside_agent_workspace`; reads (snapshot, get, find, shot) are refused the same way.
- You cannot lend. To use an app Donovan already has open, tell him (a `needs_lend` or
  `outside_agent_workspace` error says so). Running `baneyspaces agent lend <app>` only shows him a sheet; nothing lends
  until he clicks Lend, and one asked for by an agent he didn't expect is a nuisance, so ask in words first. A lend names that
  process and its windows as they were then, answers `in_use` while he is using the app, and ends after 30 minutes.
  Prefer `agent open`, which needs nobody's permission. `agent move` only moves windows of apps started for an agent.
- `agent open` is how you start work: the app and its windows land on the agent workspace and he stays
  where he is. Put files you want it to open in `~/Library/Application Support/BaneySpaces/hands/handoff/`; no other path is accepted,
  and URLs wait for the agent browser profiles. Only TextEdit, Calculator, Preview and Finder (on a handoff folder) start; every other
  app, every browser and password manager included, answers `needs_sandbox`. Each starts as a separate copy that restores nothing.
  Never ask him to switch workspaces or look at the screen.
- `press` always answers `not_supported` for now: keys reach only the app in front, and BaneySpaces never raises one for you.
  Use `type`, `set-value` or `click`.
- `shot --out name.png` writes only into BaneySpaces' own shots folder; pass a file name, not a path.
- Snapshots and shots can hold private content. They stay on this Mac; don't paste them into logs, issues
  or other agents' prompts unless asked.
