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
free_ws() { # a workspace no monitor shows now
  for n in 3 4 5 6 7 8 9; do H monitors | jq -e "[.[].activeWorkspace.id]|index($n) == null" >/dev/null && { echo $n; return; }; done
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
D1="$(test_open /usr/bin/foot -T dies sleep 600)"; D1PID="$(echo "$D1" | jq -r '.data.pid')"
eq "an agent process is registered" "$(agent_pids | jq "index($D1PID) != null")" "true"
kill "$D1PID"
check "its registration goes when it dies (no restart)" wait_for 8 not_in_pids "$D1PID"
same_screen "after the pid tests"

echo "== a restart keeps what it knew about an agent's terminal"
RT="$(baneyspaces agent run -- sh -c 'sleep 4; foot -T afterrestart sleep 600; sleep 600')"; RTPID="$(echo "$RT" | jq -r '.data.pid // empty')"
check "agent run opened a terminal" test -n "$RTPID"
eq "the issued tokens are kept private (0600)" "$(stat -c %a "$XDG_STATE_HOME/baneyspaces/tokens.json")" "600"
baneyspaces stop >/dev/null; check "the daemon stopped" wait_for 4 daemon_down
# With no daemon, an agent's shell still must not be able to switch your workspaces through the CLI fallback.
FWS="$(mon_ws $(H monitors | jq -r '.[]|select(.focused)|.name'))"
for AN in 3 4 5 6 7 8 9; do [ "$AN" != "$FWS" ] && break; done
AGENT_OUT="$(BANEYSPACES_AGENT_TOKEN=t baneyspaces switch $AN; BANEYSPACES_AGENT_TOKEN=t baneyspaces move $AN)"
eq "an agent's shell gets not_in_scope instead of the fallback" "$(echo "$AGENT_OUT" | jq -r .error.code | sort -u | tr '\n' ' ')" "not_in_scope "
eq "and your workspace did not change" "$(mon_ws $(H monitors | jq -r '.[]|select(.focused)|.name'))" "$FWS"
# Two daemons racing to start (the autostart fires on start and on reload): one wins, and it is reachable.
baneyspaces daemon --trace >>"$TMP/daemon.log" 2>&1 & RA=$!
baneyspaces daemon --trace >>"$TMP/daemon.log" 2>&1 & RB=$!
sleep 1.5
ALIVE=0; for r in $RA $RB; do kill -0 $r 2>/dev/null && { ALIVE=$((ALIVE+1)); DPID=$r; }; done
eq "of two daemons started together exactly one runs" "$ALIVE" "1"
PIDS+=($RA $RB)
eq "and it is the one answering on the socket" "$(ctl '{"op":"ping"}' | jq -r .data.pid)" "$DPID"
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

echo "== a window that opens while the daemon starts is not missed"
baneyspaces stop >/dev/null; wait_for 4 daemon_down
BANEYSPACES_TEST_EVENT_DELAY_MS=5000 baneyspaces daemon --trace >>"$TMP/daemon.log" 2>&1 & DPID=$!; PIDS+=($DPID)
sleep 1.5  # the state has been read; the events are not being read yet
EVW="$(user_window evgap)"
check "(setup) a window opened between the read and the first event" test -n "$EVW"
check "the daemon comes up" wait_for 12 daemon_up
sleep 1
eq "and it knows the window: the event that was queued was replayed" "$(baneyspaces state | jq -r ".data.windows|has(\"$EVW\")")" "true"
hyprctl dispatch "hl.dsp.window.close({ window = \"address:$EVW\" })" >/dev/null; sleep 0.5; rebase

echo "== workspace and focus changes you make yourself are never undone"
# A hidden workspace lives on monitor 2; you ask Hyprland (a waybar click does this) to show it.
baneyspaces focus-monitor $M2 >/dev/null; sleep 0.2
H2="$(mon_ws $M2)"
HW2="$(free_ws)"
baneyspaces switch $HW2 >/dev/null; sleep 0.3
baneyspaces focus-monitor $M1 >/dev/null; sleep 0.3
hyprctl dispatch "hl.dsp.focus({ workspace = \"$H2\" })" >/dev/null; sleep 0.8
eq "Hyprland's own workspace click on the other monitor leaves focus there" "$(H monitors | jq -r '.[]|select(.focused)|.name')" "$M2"
eq "and the daemon's model agrees" "$(baneyspaces state | jq -r .data.focused_monitor)" "$M2"
eq "monitor 2 shows the workspace you asked for" "$(mon_ws $M2)" "$H2"
# Focus another monitor and open a window in the same instant.
baneyspaces focus-monitor $M1 >/dev/null; sleep 0.3
hyprctl dispatch "hl.dsp.focus({ monitor = \"$M2\" })" >/dev/null
hyprctl dispatch "hl.dsp.exec_cmd(\"foot -T samemoment sleep 600\")" >/dev/null
sleep 1.5
eq "moving to monitor 2 as a window opens is not undone" "$(H monitors | jq -r '.[]|select(.focused)|.name')" "$M2"
eq "and the model agrees" "$(baneyspaces state | jq -r .data.focused_monitor)" "$M2"
SMW="$(H clients | jq -r '.[]|select(.title=="samemoment")|.address')"
hyprctl dispatch "hl.dsp.window.close({ window = \"address:$SMW\" })" >/dev/null; sleep 0.4
baneyspaces focus-monitor $M1 >/dev/null; sleep 0.3; rebase

echo "== a failing compositor is reported, never swallowed"
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

echo "== hiding the agent workspace never shows it on the display you are on"
baneyspaces focus-monitor $M2 >/dev/null; sleep 0.2
baneyspaces agent-workspace show >/dev/null; sleep 0.4
eq "(setup) it is showing on monitor 2" "$(H monitors | jq -r ".[]|select(.name==\"$M2\")|.specialWorkspace.name")" "special:agent"
baneyspaces focus-monitor $M1 >/dev/null; sleep 0.3
R0="$(baneyspaces state | jq .data.guard.refused)"
( while :; do hyprctl -j monitors | jq -r ".[]|select(.name==\"$M1\")|.specialWorkspace.name"; sleep 0.02; done > "$TMP/m1special.out" ) & SAMP=$!
HN="$(free_ws)"
baneyspaces switch $HN >/dev/null; sleep 0.6
kill $SAMP 2>/dev/null
eq "the agent workspace never appeared on monitor 1 while it was being hidden" "$(grep -c 'special:agent' "$TMP/m1special.out")" "0"
eq "it is hidden on monitor 2" "$(special)" "0"
eq "the guard counted nothing extra" "$(baneyspaces state | jq .data.guard.refused)" "$R0"
eq "you are still on monitor 1" "$(H monitors | jq -r '.[]|select(.focused)|.name')" "$M1"
rebase

echo "== R-F2 on Linux rests on focus_on_activate=false, and the daemon keeps it so"
eq "it is off" "$(hyprctl getoption misc:focus_on_activate | head -1)" "bool: false"
hyprctl eval 'hl.config({ misc = { focus_on_activate = true } })' >/dev/null
eq "(test) someone turns it on" "$(hyprctl getoption misc:focus_on_activate | head -1)" "bool: true"
check "the daemon turns it off again" wait_for 8 sh -c "[ \"\$(hyprctl getoption misc:focus_on_activate | head -1)\" = 'bool: false' ]"

echo "== deny by default: an app that is not on the allowlist is never started for an agent"
APP="$HERE/gtk_test_app.py"
ln -sf "$APP" "$TMP/linked_app.py"
addrs() { H clients | jq -r '.[].address' | sort; }
procs_with_token() { grep -l BANEYSPACES_AGENT_TOKEN /proc/[0-9]*/environ 2>/dev/null | wc -l; }
BEFORE="$(addrs)"; TOK0="$(procs_with_token)"
N0="$(baneyspaces agent open python3)"
eq "with no copy of yours running, an unlisted app is needs_sandbox" "$(echo "$N0" | jq -r '.error.code + " " + .error.retry')" "needs_sandbox never"
eq "the answer lists what is allowed" "$(echo "$N0" | jq -r '.error.data.allowed | index("foot") != null')" "true"
sleep 1.5
eq "nothing was started" "$(addrs | wc -l)-$(procs_with_token)" "$(echo "$BEFORE" | wc -l)-$TOK0"
eq "the refusal is logged as a refusal" "$(baneyspaces agent log | jq '[.data.records[]|select(.refusal=="needs_sandbox" and .route=="preflight")]|length >= 1')" "true"
same_screen "after the refused open"
# Your own single-instance copy is running.
hyprctl dispatch "hl.dsp.exec_cmd(\"/usr/bin/python3 $APP --unique\")" >/dev/null
wait_for 8 sh -c "[ \"\$(hyprctl -j clients | jq '[.[].address]|length')\" -gt $(echo "$BEFORE" | wc -l) ]"
sleep 1
UW="$(comm -13 <(echo "$BEFORE") <(addrs) | head -1)"; UPID="$(H clients | jq -r ".[]|select(.address==\"$UW\")|.pid")"
check "your own single-instance copy is running" test -n "$UW"
rebase
N="$(baneyspaces agent open python3 "$APP")"
eq "with a copy of yours running it is needs_sandbox too" "$(echo "$N" | jq -r '.error.code + " " + .error.retry')" "needs_sandbox never"
eq "nothing new appeared" "$(addrs | wc -l)" "$(echo "$BEFORE" | wc -l | awk '{print $1+1}')"
same_screen "after the second refused open"
# Every agent launch has a session bus of its own, so the same app under another path (which the
# allowlist skips: this is the test op) does NOT forward to your copy. It runs on its own.
ST="$(test_open /usr/bin/python3 "$TMP/linked_app.py" --unique)"
eq "with a bus of its own the same app opens its own window instead of forwarding" "$(echo "$ST" | jq -r .ok)" "true"
SPID="$(echo "$ST" | jq -r '.data.pid')"
check "it is another process than your copy" test "$SPID" != "$UPID"
eq "your copy did not get a second window" "$(H clients | jq "[.[]|select(.pid==$UPID)]|length")" "1"
kill "$SPID" 2>/dev/null
# The forward-and-report path still exists for a launch that shares your bus (test op only).
ST="$(TEST_PRIVATE_BUS=false test_open /usr/bin/python3 "$TMP/linked_app.py" --unique)"
eq "a launch that shares your bus forwards to your copy: single_instance" "$(echo "$ST" | jq -r .error.code)" "single_instance"
eq "and reports the window that appeared in your process" "$(echo "$ST" | jq -r '.error.data.windows_that_appeared|length >= 1')" "true"
SW="$(echo "$ST" | jq -r '.error.data.windows_that_appeared[0].window')"
check "that window was left where it is (not moved to the agent workspace)" test "$(client_ws ${SW:-x})" != "special:agent"
eq "the model treats it as yours" "$(baneyspaces state | jq -r ".data.windows[\"$SW\"].agent_owned")" "false"
kill "$UPID" 2>/dev/null; sleep 1; rebase

echo "== what an agent may pass to an allowlisted app"
HO="$XDG_STATE_HOME/baneyspaces/handoff"
procs_now() { ps -e -o pid= | wc -l; }
BEFORE="$(addrs | wc -l)"
for BAD in "-e nautilus" "--server" "-T x" "/etc/passwd" "https://example.com/" "../../etc/passwd" "nofile.txt"; do
  R="$(baneyspaces agent open foot $BAD)"
  eq "agent open foot $BAD is bad_arguments" "$(echo "$R" | jq -r .error.code)" "bad_arguments"
done
eq "an app is named, never a path (/usr/bin/foot)" "$(baneyspaces agent open /usr/bin/foot | jq -r .error.code)" "bad_arguments"
eq "nor a relative path (./foot)" "$(baneyspaces agent open ./foot | jq -r .error.code)" "bad_arguments"
eq "an unlisted app is still needs_sandbox, with a file" "$(baneyspaces agent open nautilus "$HO" | jq -r .error.code)" "needs_sandbox"
sleep 0.5
eq "none of them started anything" "$(addrs | wc -l)" "$BEFORE"
printf '#!/bin/sh\nsleep 600\n' > "$HO/hold.sh"; chmod +x "$HO/hold.sh"
FO="$(baneyspaces agent open foot "$HO/hold.sh")"
eq "foot with a file from the handoff folder starts, on the agent workspace" "$(echo "$FO" | jq -r '.ok')" "true"
FOW="$(echo "$FO" | jq -r '.data.window // empty')"
eq "(it is on special:agent)" "$(client_ws ${FOW:-x})" "special:agent"
FOPID="$(echo "$FO" | jq -r '.data.pid')"
ln -sf /etc/passwd "$HO/out.txt"
eq "a symlink out of the folder does not get through" "$(baneyspaces agent open foot "$HO/out.txt" | jq -r .error.code)" "bad_arguments"
same_screen "after the argument tests"

echo "== every agent launch has a session bus of its own"
hyprctl dispatch "hl.dsp.exec_cmd(\"env TEST_APP_TITLE=usercopy /usr/bin/python3 $APP --unique\")" >/dev/null
wait_for 8 sh -c "hyprctl -j clients | jq -e '.[]|select(.title==\"usercopy\")'"
sleep 1
UPID="$(H clients | jq -r '.[]|select(.title=="usercopy")|.pid')"
check "your own single-instance copy is running" test -n "$UPID"
rebase
BEFORE="$(addrs)"
baneyspaces agent run -- env TEST_APP_TITLE=agentcopy /usr/bin/python3 "$APP" --unique >/dev/null
wait_for 10 sh -c "hyprctl -j clients | jq -e '.[]|select(.title==\"agentcopy\")'"
sleep 1
AGW="$(H clients | jq -r '.[]|select(.title=="agentcopy")|.address')"; AGPID="$(H clients | jq -r '.[]|select(.title=="agentcopy")|.pid')"
check "the agent's copy opened its own window" test -n "$AGW"
check "in a process of its own, not yours" test "$AGPID" != "$UPID"
eq "it is on the agent workspace" "$(client_ws ${AGW:-x})" "special:agent"
eq "your copy still has exactly one window (nothing was forwarded into it)" "$(H clients | jq "[.[]|select(.pid==$UPID)]|length")" "1"
# Now you launch the same app: it must go to YOUR copy, not to the agent's.
hyprctl dispatch "hl.dsp.exec_cmd(\"env TEST_APP_TITLE=usercopy /usr/bin/python3 $APP --unique\")" >/dev/null
wait_for 8 sh -c "[ \"\$(hyprctl -j clients | jq '[.[]|select(.pid==$UPID)]|length')\" -ge 2 ]"
sleep 0.5
eq "your second launch opened a window in your copy" "$(H clients | jq "[.[]|select(.pid==$UPID)]|length")" "2"
UW2="$(H clients | jq -r "[.[]|select(.pid==$UPID)|.address]|sort|last")"
check "on a workspace of yours" test "$(client_ws ${UW2:-x})" != "special:agent"
eq "the model has it as yours, not the agent's" "$(baneyspaces state | jq -r ".data.windows[\"$UW2\"] | \"\(.home != \"agent\") \(.agent_owned)\"")" "true false"
eq "and the agent's window is still the only one the agent has" "$(H clients | jq "[.[]|select(.pid==$AGPID)]|length")" "1"
BUSPID="$(pgrep -f "address=unix:path=$XDG_RUNTIME_DIR/baneyspaces/bus-" | head -1)"
check "a private dbus-daemon is running for it" test -n "$BUSPID"
kill "$UPID" "$AGPID" 2>/dev/null; sleep 1; rebase
# Torn down with the token: once nothing runs under it, its bus and profile go.
baneyspaces agent run -- sh -c 'sleep 2' >/dev/null; sleep 4
NB_BEFORE="$(ls "$XDG_RUNTIME_DIR"/baneyspaces/bus-* 2>/dev/null | wc -l)"
ctl '{"op":"test_reap","args":{}}' >/dev/null
sleep 1
NB_AFTER="$(ls "$XDG_RUNTIME_DIR"/baneyspaces/bus-* 2>/dev/null | wc -l)"
check "a token's bus is torn down when its processes are gone (sockets $NB_BEFORE -> $NB_AFTER)" test "$NB_AFTER" -lt "$NB_BEFORE"
kill "$FOPID" 2>/dev/null
