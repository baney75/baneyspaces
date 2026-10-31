---
name: baneyspaces
description: See and drive what's open on Donovan's Mac through BaneySpaces' Deck - every terminal split, browser tab and agent app (Claude, ChatGPT, T3 Code, Grok Bot) in one list, with the workspace each is on. Use to find which terminal or tab holds something, bring it forward, open a URL in the default browser, type into another Ghostty terminal, or flag a terminal as needing him. Faster and safer than screenshots or GUI clicks.
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
cua-driver's `list_windows` reports, so a row maps straight onto a cua-driver window.
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
  you're about to drive that window with cua-driver.
- `send` types into a live terminal. Never send into a terminal running someone else's agent
  turn (`activity` is `working`) and never send commands that delete, push or spend.
- Read state with `ls`, not screenshots. If `baneyspaces` says BaneySpaces isn't running, fall back to
  cua-driver `list_windows`.
- Claude Code sessions report their own state through hooks (`baneyspaces hooks status`). Don't
  call `notify` for an ordinary end of turn; the hook already marks it.
