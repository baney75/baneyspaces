# Sourced by nested.sh after hardening.sh. An agent's Chromium is the agent's own window: Chromium writes
# its command line over its environ (setproctitle), so the daemon finds the browser under the anchor shell
# its launch runs it in, never by its crash handler, and never takes your Chromium for it.
if ! command -v chromium >/dev/null 2>&1; then
  echo "== an agent's Chromium: skipped (chromium is not installed)"
else
echo "== an agent's Chromium is its own window"
rebase
CS="chromium-check-$$"
COPEN="$(baneyspaces agent open chromium --wait 15 --session "$CS")"
echo "  open: $(echo "$COPEN" | jq -c '{ok, error: .error.code, window: .data.window, pid: .data.pid, pending: .data.pending}')"
CW="$(echo "$COPEN" | jq -r '.data.window // empty')"; CPID="$(echo "$COPEN" | jq -r '.data.pid // empty')"
check "agent open chromium answers ok with its window" test -n "$CW"
eq "the window is on special:agent" "$(client_ws "${CW:-x}")" "special:agent"
eq "the pid it reports is the window's (the browser)" "$(H clients | jq -r ".[]|select(.address==\"${CW:-x}\")|.pid")" "$CPID"
eq "the pid it reports is not the crash handler" "$(cat "/proc/${CPID:-0}/comm" 2>/dev/null)" "chromium"
check "the browser's own environ has no token (the case this covers)" sh -c "! tr '\\0' '\\n' </proc/${CPID:-0}/environ | grep -q BANEYSPACES_AGENT_TOKEN"
eq "the browser is a registered agent process" "$(baneyspaces state | jq -r ".data.agent.pids|index(${CPID:-0}) != null")" "true"
same_screen "after agent open chromium" nopointer
if [ -n "${DEBUG:-}" ]; then # the browser's ancestry, up to the reaper
  p="${CPID:-0}"; while [ "$p" -gt 1 ]; do echo "       tree: $p $(cat /proc/$p/comm) token=$(tr '\0' '\n' </proc/$p/environ 2>/dev/null | grep -c BANEYSPACES_AGENT_TOKEN)"; p="$(sed 's/.*) //' /proc/$p/stat | awk '{print $2}')"; done
fi
# A window shot within a moment of mapping can have no frame yet (grim fails): that is not scope, so it is tried again.
for _ in $(seq 1 10); do
  CSHOT="$(baneyspaces agent shot --window "${CW:-x}" --out agent-chromium.png)"
  [ "$(echo "$CSHOT" | jq -r '.ok or (.error.code != "engine_error")')" = true ] && break; sleep 0.5
done
echo "  shot: $(echo "$CSHOT" | jq -c '{ok, error: .error.code, message: .error.message, width: .data.width, height: .data.height}')"
eq "agent shot of it works" "$(echo "$CSHOT" | jq -r .ok)" "true"
# Its first moments it may not be on the accessibility bus yet (window_unmatched, retry safe).
for _ in $(seq 1 10); do
  CSNAP="$(baneyspaces agent snapshot --window "${CW:-x}" -i --compact)"
  [ "$(echo "$CSNAP" | jq -r '.ok or (.error.retry != "safe")')" = true ] && break; sleep 0.5
done
echo "  snapshot: $(echo "$CSNAP" | jq -c '{ok, error: .error.code, refs: .data.result.ref_count}')"
eq "agent snapshot of it reads its tree" "$(echo "$CSNAP" | jq -r .ok)" "true"
check "with controls to act on" sh -c "[ '$(echo "$CSNAP" | jq -r '.data.result.ref_count // 0')' -gt 0 ]"

# Your Chromium, put on the agent workspace: guarded, never the agent's.
UPROF="$TMP/home/user-chromium"
hyprctl dispatch "hl.dsp.exec_cmd(\"chromium --user-data-dir=$UPROF --no-first-run --no-default-browser-check --class=user-chromium\", { workspace = \"special:agent silent\" })" >/dev/null
UW=""; for _ in $(seq 1 150); do UW="$(H clients | jq -r '.[]|select(.class=="user-chromium")|.address' | head -1)"; [ -n "$UW" ] && break; sleep 0.1; done
check "(setup) your Chromium has a window on special:agent" sh -c "[ -n '$UW' ] && [ \"\$(hyprctl -j clients | jq -r '.[]|select(.address==\"$UW\")|.workspace.name')\" = special:agent ]"
UPID="$(H clients | jq -r ".[]|select(.address==\"${UW:-x}\")|.pid")"
eq "your Chromium is not an agent process" "$(baneyspaces state | jq -r ".data.agent.pids|index(${UPID:-0}) != null")" "false"
eq "agent close refuses your Chromium" "$(baneyspaces agent close --window "${UW:-x}" --session "$CS" | jq -r .error.code)" "not_in_scope"
check "agent shot refuses your Chromium" sh -c "baneyspaces agent shot --window '${UW:-x}' | jq -e '.ok == false'"
eq "your Chromium is still open" "$(H clients | jq -r "[.[]|select(.address==\"${UW:-x}\")]|length")" "1"
[ -n "$UPID" ] && kill "$UPID" 2>/dev/null

CCLOSE="$(baneyspaces agent close --window "${CW:-x}" --session "$CS")"
echo "  close: $(echo "$CCLOSE" | jq -c '{ok, error: .error.code, closed: .data.closed}')"
eq "agent close of the agent's Chromium works" "$(echo "$CCLOSE" | jq -r .ok)" "true"
check "its window is gone" wait_for 10 sh -c "[ \"\$(hyprctl -j clients | jq '[.[]|select(.address==\"${CW:-x}\")]|length')\" = 0 ]"
CDIR="$(echo "$COPEN" | jq -r '.data.polycarp_socket_dir // empty')"
check "its processes exit" wait_for 10 sh -c "! kill -0 ${CPID:-0} 2>/dev/null"
if wait_for 10 sh -c "[ -n '$CDIR' ] && [ ! -e '$CDIR' ]"; then ok "its launch is dropped with its bridge folder once they are gone"; else
  bad "its launch is dropped with its bridge folder once they are gone" "folder '$CDIR'; tokens: $(jq -c 'to_entries|map({k: .key[:8], app: .value.app, seen: .value.seen})' "$XDG_STATE_HOME/baneyspaces/tokens.json" 2>/dev/null)"
  for d in $(pgrep -f "^baneyspaces daemon"); do for t in /proc/$d/task/*; do echo "       daemon $d thread $(cat $t/comm) $(cat $t/wchan) $(cat $t/stat | awk '{print $3}')"; done; done
  for p in $(pgrep -f .); do tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | grep -q "^BANEYSPACES_AGENT_TOKEN=${CDIR##*/}" && echo "       still carries the token: $p $(tr '\0' ' ' <"/proc/$p/cmdline" | cut -c1-120)"; done
fi
wait_for 10 sh -c "[ \"\$(hyprctl -j clients | jq '[.[]|select(.class==\"user-chromium\")]|length')\" = 0 ]"
same_screen "after the Chromium checks" nopointer
rebase
fi
