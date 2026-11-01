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
- `error.retry`:
  - `safe`: nothing was delivered; the same call can be sent again.
  - `after_snapshot`: take a new snapshot first; refs from the old one no longer hold.
  - `never`: refused, or the action may already have landed. Do not repeat it.
- A hands result (`click`, `set-value`, ...) carries `data.evidence`: `{ "delivery", "verified",
  "readback" }` taken from the engine's own report. `verified` is true only when the engine read the
  result back from the element it targeted. A capture is never evidence by itself.
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
| `daemon_down` | `baneyspaces daemon` is not running. |
| `stale_ref` | The ref, window or process changed since the snapshot. |
| `single_instance` | The app forwarded to a running instance; it can't be driven as an agent process. `error.data.windows_that_appeared` lists windows that opened meanwhile (left where they are). |
| `needs_sandbox` | The app is not on the list of apps with a verified separate-process launch, so an agent may not start it (it could hand the request to your copy, or take over your launches). Refused before launch. |
| `window_unmatched` | The compositor window cannot be matched to exactly one accessible window (by title). |
| `timeout` | Waited and nothing arrived. From a client: the request was sent and no answer came, so it may have been carried out (`retry` never). A failure to connect is `daemon_down` instead. |
| `engine_missing` | The hands engine is not built or not found. |
| `engine_error` | The hands engine failed; `message` carries its code. |
| `agent_window` | A move of an agent window to your workspaces. |
| `no_monitor` | No monitor is connected. |
| `compositor_error` | The compositor refused a command or did not answer. `retry` is `safe` only for a clean refusal before anything moved, otherwise `never`; `error.data` says which. The daemon re-reads the compositor before the next command. |
| `internal` | A bug. |
