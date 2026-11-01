# Sourced by nested.sh after the agent-workspace section. Agent hands: AT-SPI through the pinned
# engine, on a GTK4 app that BaneySpaces itself started on the agent workspace.
echo "== agent hands (AT-SPI), scoped to the agent workspace"
APP="$HERE/gtk_test_app.py"
GA="$(baneyspaces agent open /usr/bin/python3 "$APP")"
GW="$(echo "$GA" | jq -r '.data.window // empty')"; GPID="$(echo "$GA" | jq -r '.data.pid // empty')"
check "the GTK test app opened on the agent workspace" test -n "$GW"
eq "its window is on special:agent" "$(client_ws ${GW:-x})" "special:agent"
same_screen "after opening the GTK app"
sleep 1.5
S="$(baneyspaces agent snapshot --window "$GW" -i)"
eq "snapshot works" "$(echo "$S" | jq -r .ok)" "true"
eq "snapshot has refs for the three controls" "$(echo "$S" | jq -r '.data.result.ref_count')" "3"
SID="$(echo "$S" | jq -r '.data.result.snapshot_id')"
ref_of() { echo "$S" | jq -r "[.. | objects | select(.name==\"$1\") | .ref_id][0]"; }
BTN="$(ref_of Count)"; ENT="$(ref_of 'Name field')"; TGL="$(ref_of Enabled)"
check "refs name their snapshot" test "${BTN%%:*}" = "@$SID"
eq "the snapshot reports no screen change" "$(echo "$S" | jq -r '.data.screen_changed')" "false"
same_screen "after snapshot"

F="$(baneyspaces agent find --window "$GW" --role button)"
eq "find by role returns the button" "$(echo "$F" | jq -r '.data.result.matches[0].name')" "Count"

C="$(baneyspaces agent click "$BTN")"
eq "click on a ref works" "$(echo "$C" | jq -r .ok)" "true"
eq "click says how it was delivered, and does not claim a readback it lacks" "$(echo "$C" | jq -r '.data.evidence | "\(.delivery) \(.verified)"')" "delivered_unverified false"
eq "click went through the accessibility API" "$(echo "$C" | jq -r '.data.evidence.route[0]')" "semantic_api"
sleep 0.4
eq "the app's own label shows the click (independent readback)" "$(baneyspaces agent snapshot --window "$GW" | jq '[.. | objects | select(.name=="count 1")] | length')" "1"
same_screen "after click"

SV="$(baneyspaces agent set-value "$ENT" "hello")"
eq "set-value works" "$(echo "$SV" | jq -r .ok)" "true"
eq "set-value read back from the element" "$(baneyspaces agent get "$ENT" value | jq -r '.data.result.value // .data.result.text')" "hello"
TY="$(baneyspaces agent type "$ENT" " there")"
eq "type works" "$(echo "$TY" | jq -r .ok)" "true"
# (the engine inserts at the caret, which set-value left at the start)
V="$(baneyspaces agent get "$ENT" value | jq -r '.data.result.value // .data.result.text')"
check "type read back from the element: '$V' holds both" sh -c "case '$V' in *hello*there*|*there*hello*) true;; *) false;; esac"
TG="$(baneyspaces agent toggle "$TGL")"
eq "toggle works" "$(echo "$TG" | jq -r .ok)" "true"
same_screen "after set-value, type and toggle"
eq "no key or pointer event reached the user's windows (cursor still)" "$(cursor)" "$USER_CURSOR"

echo "-- scope: only a process BaneySpaces started, only on the agent workspace"
eq "a user window is not_in_scope" "$(baneyspaces agent snapshot --window "$W2" | jq -r .error.code)" "not_in_scope"
baneyspaces agent move "$W3" >/dev/null; sleep 0.3
eq "a window you parked is needs_lend (not an agent process)" "$(baneyspaces agent snapshot --window "$W3" | jq -r .error.code)" "needs_lend"
baneyspaces agent bring "$W3" >/dev/null; sleep 0.3
eq "an unknown window is not_found" "$(baneyspaces agent snapshot --window 0xdead | jq -r .error.code)" "not_found"
eq "a bare ref is invalid_args" "$(baneyspaces agent click @e1 | jq -r .error.code)" "invalid_args"
eq "a ref from nowhere is stale_ref, retry after a snapshot" "$(baneyspaces agent click @sbogus:e1 | jq -r '"\(.error.code) \(.error.retry)"')" "stale_ref after_snapshot"
eq "a capture of one window is not_supported on Wayland, with a suggestion" "$(baneyspaces agent shot --window "$GW" | jq -r '"\(.error.code) \(.error.suggestion|length>0)"')" "not_supported true"
eq "keys are refused" "$(baneyspaces agent press @sa:e1 Return | jq -r .error.code)" "not_supported"
eq "lend is refused" "$(baneyspaces agent lend foot | jq -r .error.code)" "not_supported"
same_screen "after the refusals"
# The window closes: the old ref must not resolve to anything else.
kill "$GPID" 2>/dev/null; sleep 1
eq "after the app is gone its refs are stale or not found" "$(baneyspaces agent click "$BTN" | jq -r '.error.code' | grep -cE '^(stale_ref|not_found)$')" "1"
same_screen "after the app closed"

echo "-- the action record"
L="$(baneyspaces agent log)"
eq "every action left a record" "$(echo "$L" | jq '.data.records|length >= 12')" "true"
eq "records hold only who, what, which window, ref, route, result, refusal" "$(echo "$L" | jq '[.data.records[]|keys[]]|unique|map(select(IN("at","agent","verb","pid","window","ref","route","result","refusal")|not))|length')" "0"
eq "the record keeps no typed text or value" "$(grep -c -E 'hello|there' "$XDG_STATE_HOME/baneyspaces/actions.jsonl")" "0"
eq "refusals are recorded as refusals" "$(echo "$L" | jq '[.data.records[]|select(.refusal=="not_in_scope")]|length >= 1')" "true"
eq "the record names the agent" "$(echo "$L" | jq -r '[.data.records[].agent]|unique|first')" "agent"
eq "--agent-id names the caller" "$(baneyspaces --agent-id claude-test agent snapshot --window 0xdead >/dev/null; baneyspaces agent log | jq -r '.data.records[-1].agent')" "claude-test"
eq "the log file is private" "$(stat -c %a "$XDG_STATE_HOME/baneyspaces/actions.jsonl")" "600"

echo "-- MCP over stdio"
GA2="$(baneyspaces agent open /usr/bin/python3 "$APP")"; GW2="$(echo "$GA2" | jq -r '.data.window')"; sleep 1.5
MCP_OUT="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"agent_snapshot\",\"arguments\":{\"window\":\"$GW2\",\"interactive\":true}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"agent_snapshot\",\"arguments\":{\"window\":\"$W2\"}}}" \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"switch","arguments":{}}}' \
  | baneyspaces mcp)"
eq "MCP: 3 replies for 5 messages with ids (the notification gets none)" "$(echo "$MCP_OUT" | wc -l)" "5"
eq "MCP: initialize answers" "$(echo "$MCP_OUT" | sed -n 1p | jq -r .result.serverInfo.name)" "baneyspaces"
eq "MCP: tools/list has 13 agent tools" "$(echo "$MCP_OUT" | sed -n 2p | jq '.result.tools|length')" "13"
eq "MCP: no tool switches or moves your workspaces" "$(echo "$MCP_OUT" | sed -n 2p | jq '[.result.tools[].name|select(test("switch|move"))]|length')" "0"
eq "MCP: a snapshot of an agent window works" "$(echo "$MCP_OUT" | sed -n 3p | jq -r '.result.structuredContent.ok')" "true"
eq "MCP: a snapshot of your window is refused" "$(echo "$MCP_OUT" | sed -n 4p | jq -r '.result.structuredContent.error.code, .result.isError' | tr '\n' ' ')" "not_in_scope true "
eq "MCP: an unknown tool is a JSON-RPC error" "$(echo "$MCP_OUT" | sed -n 5p | jq -r .error.code)" "-32602"
same_screen "after MCP"
