# Sourced by nested.sh after the hands section. Things an agent, a reused pid, a failing compositor
# or a single-instance app must not be able to do to you.
rebase() { # take the current screen as the baseline for same_screen
  USER_ACTIVE="$(active)"; USER_WS1="$(mon_ws $M1)"; USER_WS2="$(mon_ws $M2)"; USER_CURSOR="$(cursor)"
}
agent_pids() { baneyspaces state | jq -c '.data.agent.pids'; }
wait_for() { # wait_for <seconds> <command...>: poll until the command succeeds
  local t="$1"; shift
  for _ in $(seq 1 $((t*10))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1
}
daemon_up() { baneyspaces state 2>/dev/null | jq -e .ok >/dev/null; }
daemon_down() { ! daemon_up; }
not_in_pids() { ! agent_pids | jq -e "index($1) != null" >/dev/null; }

echo "== an agent cannot run your commands (control socket peers)"
OUT="$TMP/agent-ops.out"; rm -f "$OUT"
INNER="for c in 'agent-workspace show' 'switch 3' 'move 5' 'agent move $W2' 'overview' 'focus-monitor $M2'; do baneyspaces \$c; done > $OUT 2>&1; sleep 600"
AR="$(baneyspaces agent run -- sh -c "$INNER")"
ARPID="$(echo "$AR" | jq -r '.data.pid // empty')"
check "agent run opened a terminal on the agent workspace" test -n "$ARPID"
wait_for 6 test "$(wc -l < "$OUT" 2>/dev/null || echo 0)" -ge 6
eq "the agent's shell got six answers" "$(wc -l < "$OUT")" "6"
eq "every one of them was refused as not_in_scope" "$(jq -r '.error.code' "$OUT" | sort -u | tr '\n' ' ')" "not_in_scope "
same_screen "after an agent shell tried the user's commands"
check "the refusals are in the action log" sh -c "baneyspaces agent log | jq -e '[.data.records[]|select(.route==\"ctl\" and .result==\"not_in_scope\")]|length >= 6'"
kill "$ARPID" 2>/dev/null

echo "== a reused pid is not an agent"
# A process registered as an agent with a start time that is not its own: what a recycled pid looks like.
sh -c 'sleep 1.5; exec foot -T reusedpid sleep 600' & RP=$!; PIDS+=($RP)
sleep 0.3
eq "(test) register the pid with a stale start time" "$(ctl "{\"op\":\"test_register_pid\",\"args\":{\"pid\":$RP,\"start\":1}}" | jq -r .ok)" "true"
eq "it is in the model's agent list" "$(agent_pids | jq "index($RP) != null")" "true"
wait_for 6 sh -c "hyprctl -j clients | jq -e '.[]|select(.title==\"reusedpid\")'"
sleep 0.5
RW="$(H clients | jq -r '.[]|select(.title=="reusedpid")|.address')"
check "the reused pid's window opened" test -n "$RW"
check "it is on your workspace, not special:agent" test "$(client_ws ${RW:-x})" != "special:agent"
eq "the model has it as your window" "$(baneyspaces state | jq -r ".data.windows[\"$RW\"] | \"\(.home != \"agent\") \(.agent_owned)\"")" "true false"
check "and forgot the stale registration" not_in_pids $RP
kill $RP 2>/dev/null; sleep 0.5; rebase
# Death: an agent process that exits is forgotten without a restart.
D1="$(baneyspaces agent open foot -T dies sleep 600)"; D1PID="$(echo "$D1" | jq -r '.data.pid')"
eq "an agent process is registered" "$(agent_pids | jq "index($D1PID) != null")" "true"
kill "$D1PID"
check "its registration goes when it dies (no restart)" wait_for 8 not_in_pids "$D1PID"
same_screen "after the pid tests"

echo "== a restart keeps what it knew about an agent's terminal"
RT="$(baneyspaces agent run -- sh -c 'sleep 4; foot -T afterrestart sleep 600; sleep 600')"; RTPID="$(echo "$RT" | jq -r '.data.pid // empty')"
check "agent run opened a terminal" test -n "$RTPID"
eq "the issued tokens are kept private (0600)" "$(stat -c %a "$XDG_STATE_HOME/baneyspaces/tokens.json")" "600"
baneyspaces stop >/dev/null; check "the daemon stopped" wait_for 4 daemon_down
baneyspaces daemon --trace >>"$TMP/daemon.log" 2>&1 & DPID=$!; PIDS+=($DPID)
check "a new daemon is up" wait_for 6 daemon_up
check "the agent's shell opens a window after the restart" wait_for 12 sh -c "hyprctl -j clients | jq -e '.[]|select(.title==\"afterrestart\")'"
sleep 1
ARW="$(H clients | jq -r '.[]|select(.title=="afterrestart")|.address')"
eq "that window is on the agent workspace" "$(client_ws ${ARW:-x})" "special:agent"
eq "and drivable: the new daemon still knew the token" "$(baneyspaces agent status | jq -r ".data.windows[]|select(.window==\"$ARW\")|.drivable")" "true"
# (A window opened later by a process inside an agent's shell is not under an exec rule, so Hyprland
# shows it for a moment before the daemon moves it; Hyprland warps the pointer to it. Documented limit.)
same_screen "after a daemon restart and a window from an agent's shell" nopointer
USER_CURSOR="$(cursor)"
kill "$RTPID" 2>/dev/null; sleep 0.5

echo "== a failing compositor is reported, never swallowed"
free_ws() { # a workspace no monitor shows now
  for n in 3 4 5 6 7 8 9; do H monitors | jq -e "[.[].activeWorkspace.id]|index($n) == null" >/dev/null && { echo $n; return; }; done
}
FOC="$(H monitors | jq -r '.[]|select(.focused)|.name')"
N1="$(free_ws)"
ctl '{"op":"test_fail_next","args":{"io":false}}' >/dev/null
F1="$(baneyspaces switch $N1)"
eq "a refused dispatch is compositor_error" "$(echo "$F1" | jq -r .error.code)" "compositor_error"
eq "and safe to repeat when nothing went through" "$(echo "$F1" | jq -r .error.retry)" "safe"
eq "the model was re-read from Hyprland" "$(baneyspaces state | jq -r ".data.monitors[\"$FOC\"].current")" "$(mon_ws $FOC)"
eq "the same command then works (it is not swallowed as a no-op)" "$(baneyspaces switch $N1 | jq -r .ok)-$(mon_ws $FOC)" "true-$N1"
N2="$(free_ws)"
ctl '{"op":"test_fail_next","args":{"io":true}}' >/dev/null
F2="$(baneyspaces switch $N2)"
eq "a timeout is compositor_error with retry never (delivery is uncertain)" "$(echo "$F2" | jq -r '"\(.error.code) \(.error.retry) \(.error.data.uncertain)"')" "compositor_error never true"
eq "the model agrees with Hyprland again" "$(baneyspaces state | jq -r ".data.monitors[\"$FOC\"].current")" "$(mon_ws $FOC)"
baneyspaces switch $N1 >/dev/null; sleep 0.2; rebase

echo "== R-F2 on Linux rests on focus_on_activate=false, and the daemon keeps it so"
eq "it is off" "$(hyprctl getoption misc:focus_on_activate | head -1)" "bool: false"
hyprctl eval 'hl.config({ misc = { focus_on_activate = true } })' >/dev/null
eq "(test) someone turns it on" "$(hyprctl getoption misc:focus_on_activate | head -1)" "bool: true"
check "the daemon turns it off again" wait_for 8 sh -c "[ \"\$(hyprctl getoption misc:focus_on_activate | head -1)\" = 'bool: false' ]"

echo "== an app that forwards to your copy is refused before it starts"
APP="$HERE/gtk_test_app.py"
ln -sf "$APP" "$TMP/linked_app.py"
addrs() { H clients | jq -r '.[].address' | sort; }
BEFORE="$(addrs)"
hyprctl dispatch "hl.dsp.exec_cmd(\"/usr/bin/python3 $APP --unique\")" >/dev/null
wait_for 8 sh -c "[ \"\$(hyprctl -j clients | jq '[.[].address]|length')\" -gt $(echo "$BEFORE" | wc -l) ]"
sleep 1
UW="$(comm -13 <(echo "$BEFORE") <(addrs) | head -1)"; UPID="$(H clients | jq -r ".[]|select(.address==\"$UW\")|.pid")"
check "your own single-instance copy is running" test -n "$UW"
eq "it is on your workspace" "$(client_ws ${UW:-x} | grep -c special)" "0"
rebase
N="$(baneyspaces agent open /usr/bin/python3 "$APP" --unique)"
eq "agent open of the same app is needs_sandbox" "$(echo "$N" | jq -r '.error.code + " " + .error.retry')" "needs_sandbox never"
eq "it names your copy, not a window of the agent's" "$(echo "$N" | jq -r '.error.data.user_pid')" "$UPID"
eq "nothing new appeared" "$(addrs | wc -l)" "$(echo "$BEFORE" | wc -l | awk '{print $1+1}')"
same_screen "after the refused open"
# What cannot be seen before launch: the same app under another path. The launch is allowed, the app
# forwards to your copy, and its window opens in YOUR process. The window is left where it is and
# the error says so.
ST="$(baneyspaces agent open /usr/bin/python3 "$TMP/linked_app.py" --unique)"
eq "a forwarded launch is single_instance" "$(echo "$ST" | jq -r .error.code)" "single_instance"
eq "and reports the window that appeared in your process" "$(echo "$ST" | jq -r '.error.data.windows_that_appeared|length >= 1')" "true"
SW="$(echo "$ST" | jq -r '.error.data.windows_that_appeared[0].window')"
check "that window was left where it is (not moved to the agent workspace)" test "$(client_ws ${SW:-x})" != "special:agent"
eq "the model treats it as yours" "$(baneyspaces state | jq -r ".data.windows[\"$SW\"].agent_owned")" "false"
kill "$UPID" 2>/dev/null; sleep 1; rebase
