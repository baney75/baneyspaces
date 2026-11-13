# The envelope

Every `baneyspaces` command and every MCP tool result is one JSON object.

```json
{ "ok": true,  "data": { } }
{ "ok": false, "error": { "code": "not_in_scope", "message": "...", "retry": "never", "suggestion": "..." } }
```

- `ok` is a boolean. `data` is present when `ok` is true; `error` when it is false. Never both.
- `error.data` (optional): extra facts about the failure, never content.
- `error.code`: one of the codes below. `error.message`: for a person. `error.suggestion`: what to
  do next, always present (may be empty only for `internal`).
- `error.next_call` (macOS for now, MCP and CLI alike): the one call to make next, `{ "tool", "arguments" }`, always a read
  or the same safe verb with a fixed argument, never a foreground action. `null` when there is none.
- `error.retry`:
  - `safe`: nothing was delivered; the same call can be sent again.
  - `after_snapshot`: take a new snapshot first; refs from the old one no longer hold.
  - `after`: nothing was delivered, but not yet: wait, then send it again (the daemon is re-reading
    the compositor).
  - `never`: refused, or the action may already have landed. Do not repeat it.
- A hands result (`click`, `set-value`, ...) carries `data.evidence`: `{ "delivery", "verified",
  "readback" }` taken from the engine's own report. `verified` is true only when the engine read the
  result back from the element it targeted. A capture is never evidence by itself.
- macOS, `click` on a row, cell or item of an outline, table or list: when the press leaves it unselected, the click
  writes the selection on the container in the same transaction. `data.landed` is `press`, `selection_write`,
  `already_selected` or `none`, and `data.evidence` (`kind: selection_readback`) holds the selection read before, after
  the press and after the write. The write is never made after a press that selected the row. A press that failed is
  named in `data.press_error` (`code`, `message`). A refused write is the error only when the press failed too;
  after a press that ran it is reported in `data.selection_write` (`code`, `error`) and its code decides `data.next_call`. The
  readbacks read in the view of the snapshot the row number came from. Linux and Windows: the press only.
- MCP and CLI, macOS: every error carries `error.next_call`, a read or `null` for none, and an unverified result carries
  `data.next_call`. Linux and Windows: not yet.
- Exit status of the CLI: 0 for `ok`, 1 for an error, 2 for `invalid_args`.

## Codes

| Code | Meaning |
| --- | --- |
| `invalid_args` | A bad argument (workspace 10, a malformed ref). |
| `not_found` | No such window, monitor or ref target. |
| `ambiguous` | More than one match. `error.message` lists the candidates. |
| `not_in_scope` | The window is not on the agent workspace. |
| `needs_lend` | The process was not started by BaneySpaces for an agent; only the user can lend it. |
| `in_use` | A lent app the user is using right now. |
| `not_supported` | Not on this platform or phase (keys and pointer on Linux part 1). |
| `unverified` | macOS phase 4 only: keys or pointer events were posted to the one process and nothing read back from the window shows they landed. `retry` is `never`. Other platforms answer `not_supported` for keys and pointer. |
| `daemon_down` | `baneyspaces daemon` is not running. |
| `stale_bare_row` | macOS: a bare row number (`"ref":"5"`) that could mean a row from an older read: the session's recent snapshots disagree on row 5, or its last read was a `since` or `query` read, which doesn't list every row. Nothing was sent; `retry` is `after_snapshot` and `error.next_call` is a full `snapshot` of the window. |
| `stale_ref` | The ref, window or process changed since the snapshot. |
| `single_instance` | The app forwarded to a running instance; it can't be driven as an agent process. `error.data.windows_that_appeared` lists windows that opened meanwhile (left where they are). |
| `needs_sandbox` | The app is not on the list of apps with a verified separate-process launch, so an agent may not start it (it could hand the request to your copy, or take over your launches). Refused before launch. |
| `bad_arguments` | `agent open` takes the name of an allowlisted app and files inside the handoff folder, nothing else: no flags, no paths to programs, no URLs. |
| `window_unmatched` | The compositor window cannot be matched to exactly one accessible window (by title). |
| `timeout` | Waited and nothing arrived. From a client: the request was sent and no answer came, so it may have been carried out (`retry` never). A failure to connect is `daemon_down` instead. |
| `engine_missing` | The hands engine is not built or not found. |
| `engine_error` | The hands engine failed; `message` carries its code. |
| `agent_window` | A move of an agent window to your workspaces. |
| `no_monitor` | No monitor is connected. |
| `compositor_error` | The compositor refused a command or did not answer. `retry` is `safe` only for a clean refusal before anything moved, otherwise `never`; `error.data` says which. The daemon re-reads the compositor before the next command. |
| `internal` | A bug. |
