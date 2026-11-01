#!/usr/bin/env bash
# The configuration, end to end, inside the NESTED Hyprland (spec/config.md). Sourced by nested.sh
# after the agent tests; `config.sh` alone runs it under nested.sh with nothing else.
#
# It never touches the session you are running in: it refuses to run unless the Hyprland and
# Wayland display it was handed are the nested ones under /tmp/bs-nested.*, and refuses outright when
# HYPRLAND_INSTANCE_SIGNATURE is the live session's.
#
# Known limit: the nested host compositor has no input device, so a key press cannot be delivered
# (wtype is accepted but its keyboard never produces events). "Pressing" a chord here runs the
# command the key is bound to, read out of the bind Hyprland holds, as `press` does in nested.sh.
# The 2 s hold of the recovery chord is Lua inside Hyprland and is not exercised by this test.

LIVE_SIG_PREFIX=efb50993780079460b0cbed1363e2166a2de1d9f_1792719671
refuse() { echo "config.sh: refusing to run: $1" >&2; exit 2; }
case "${HYPRLAND_INSTANCE_SIGNATURE:-}" in "$LIVE_SIG_PREFIX"*) refuse "HYPRLAND_INSTANCE_SIGNATURE is the live session's";; esac
case "${XDG_RUNTIME_DIR:-}" in /tmp/bs-nested.*/run) ;; *) refuse "XDG_RUNTIME_DIR is not a nested session's ($XDG_RUNTIME_DIR)";; esac
[ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] || refuse "WAYLAND_DISPLAY (${WAYLAND_DISPLAY:-unset}) is not a socket in the nested runtime dir"
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && [ -S "$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock" ] || refuse "no nested Hyprland socket for HYPRLAND_INSTANCE_SIGNATURE"

if ! declare -F ok >/dev/null; then
  # Run alone (NESTED_ONLY): the helpers nested.sh would have defined.
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO="$(cd "$HERE/../../.." && pwd)"; TMP="$(dirname "$XDG_RUNTIME_DIR")"; PIDS=()
  ctl() { echo "$1" | socat -t 60 - UNIX-CONNECT:"$XDG_RUNTIME_DIR/baneyspaces/ctl.sock"; }
  PASS=0; FAIL=0; STANDALONE=1
  ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
  bad() { FAIL=$((FAIL+1)); echo "  FAIL $1${2:+ -- $2}"; }
  check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
  eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
  H() { hyprctl -j "$@"; }
  wait_for() { local n="$1"; shift; for _ in $(seq 1 $((n*10))); do "$@" && return 0; sleep 0.1; done; return 1; }
fi
declare -F wait_for >/dev/null || wait_for() { local n="$1"; shift; for _ in $(seq 1 $((n*10))); do "$@" && return 0; sleep 0.1; done; return 1; }

echo "== config: keys, themes, animations and behavior (nested)"
CFG="$XDG_CONFIG_HOME/baneyspaces"
RTJ="$XDG_RUNTIME_DIR/baneyspaces/config.json"
KEYS_LUA="$XDG_STATE_HOME/baneyspaces/hyprland-keys.lua"
INCLUDE="$REPO/platforms/linux/omarchy/baneyspaces.lua"
declare -F special >/dev/null || special() { H monitors | jq -r '[.[]|.specialWorkspace.name]|map(select(.=="special:agent"))|length'; }
bs_binds() { H binds | jq -c "[.[]|select(.submap==\"\" and ((.description//\"\")|startswith(\"BaneySpaces\")))]|length"; }
has_bind() { H binds | jq -e "[.[]|select(.description==\"$1\")]|length > 0" >/dev/null; }
last_caller() { baneyspaces config history | jq -r '.data.versions[0].caller'; }
last_summary() { baneyspaces config history | jq -r '.data.versions[0].summary'; }
# The command a bind runs, read from the keys file the daemon wrote (its description is the key).
bound_cmd() { grep -F "\"$1\"" "$KEYS_LUA" | sed -n 's/.*exec_cmd("\(.*\)"), "BaneySpaces.*/\1/p' | head -1; }
press_cfg() { local c; c="$(bound_cmd "$1")"; [ -n "$c" ] && sh -c "$c" >/dev/null 2>&1; }

# --- no daemon needed: schema and validate
SCHEMA_CLI="$(env -u XDG_RUNTIME_DIR baneyspaces config schema 2>/dev/null | jq -S .data)"
eq "config schema (no daemon needed) is the committed spec/config.schema.json" "$SCHEMA_CLI" "$(jq -S . "$REPO/spec/config.schema.json")"
printf '[animation]\nspeed = 99\n' > "$TMP/bad.toml"
eq "validate names the exact path and reason" "$(baneyspaces config validate "$TMP/bad.toml" | jq -r '.error.code + " " + .error.data.issues[0].path + " " + .error.data.issues[0].code')" "config_invalid animation.speed range"
check "validate exits 1 on a refusal" sh -c "! baneyspaces config validate '$TMP/bad.toml' >/dev/null"
eq "validate of a good document is valid" "$(printf '[behavior]\nfollow_focus = false\n' | baneyspaces config validate - | jq -r .data.valid)" "true"

# --- the daemon applied the defaults at start
check "the daemon wrote the config the UIs read" test -s "$RTJ"
# On an Omarchy seat the default theme is omarchy (square corners); elsewhere baneyspaces.
if [ -d "${OMARCHY_PATH:-/usr/share/omarchy}" ]; then DEFTHEME=omarchy; DEFTILE=0; else DEFTHEME=baneyspaces; DEFTILE=16; fi
eq "config.json holds the effective config and the resolved theme" "$(jq -r '[.platform, .effective.keys.mod, (.resolved.theme.tokens.radius.tile|tostring), (.status.valid|tostring)]|join(" ")' "$RTJ")" "linux super $DEFTILE true"
eq "the recovery chord is bound by the include" "$(has_bind 'BaneySpaces: recovery (hold 2 s)' && echo yes)" "yes"
BASE_BINDS="$(bs_binds)"
eq "defaults: 29 key bindings and the recovery chord" "$BASE_BINDS" "30"

# --- an agent-token process sets a binding through the CLI
HDESC="BaneySpaces: agent-workspace show"   # a plain action: free for an agent, and a description of its own
EPRESS="$TMP/e-pressed"; rm -f "$EPRESS"
cat > "$TMP/agent-config.sh" <<EOF
baneyspaces config set 'keys.bindings."mod+h"' 'agent-workspace show' > "$TMP/agent-set.json" 2>&1
baneyspaces config set 'keys.bindings."mod+e"' 'exec touch $EPRESS' > "$TMP/agent-exec.json" 2>&1
baneyspaces config set 'keys.bindings."super+shift+escape"' 'exec true' > "$TMP/agent-rebind.json" 2>&1
baneyspaces config set 'keys.bindings."mod+shift+escape"' 'none' > "$TMP/agent-unbind.json" 2>&1
baneyspaces config set animation.dock.in.duration_ms 5000 > "$TMP/agent-long.json" 2>&1
baneyspaces config approve hooks.on_switch x > "$TMP/agent-approve.json" 2>&1
echo done > "$TMP/agent-done"
sleep 60
EOF
baneyspaces --agent-id tester agent run -- sh "$TMP/agent-config.sh" >/dev/null
check "(setup) the agent process ran its commands" wait_for 20 test -e "$TMP/agent-done"
eq "an agent may set a binding to a plain action" "$(jq -r '.ok' "$TMP/agent-set.json")" "true"
eq "the history records the caller from the peer's token, not from a flag" "$(baneyspaces config history | jq -r '[.data.versions[]|select(.summary|startswith("set keys.bindings"))]|last.caller')" "agent:tester"
eq "Hyprland's binds changed: the new binding is there" "$(has_bind "$HDESC" && echo yes)" "yes"
eq "and it is one more bind than before" "$(bs_binds)" "$((BASE_BINDS+1))"
check "config.toml holds the agent's settings" sh -c "grep -q 'mod+h' '$CFG/config.toml' && ! grep -q 'speed' '$CFG/config.toml'"
baneyspaces agent-workspace hide >/dev/null
press_cfg "$HDESC"; sleep 0.5
eq "pressing it ran the action (the agent workspace came up)" "$(special)" "1"
baneyspaces agent-workspace hide >/dev/null; sleep 0.3
eq "the same agent cannot press workspace keys (switch is still the user's)" "$(baneyspaces --agent-id tester agent run -- sh -c 'baneyspaces switch 3 > '"$TMP"'/agent-switch.json; sleep 20' >/dev/null; wait_for 10 test -s "$TMP/agent-switch.json"; jq -r .error.code "$TMP/agent-switch.json")" "not_in_scope"

# --- executable settings wait for a click
eq "an agent may set a binding that runs a command, but it is pending" "$(jq -r '.data.pending[0].path' "$TMP/agent-exec.json")" 'keys.bindings."mod+e"'
eq "it is not bound in Hyprland" "$(has_bind 'BaneySpaces: exec touch '"$EPRESS" && echo bound || echo inert)" "inert"
eq "config get shows it as pending, with who wrote it as a hint" "$(baneyspaces config get | jq -r '.data.pending[0]|[.path,.kind,.written_by_hint]|join(" ")')" 'keys.bindings."mod+e" exec binding agent:tester'
eq "config.json lists it for Settings" "$(jq -r '.pending[0].value' "$RTJ")" "exec touch $EPRESS"
eq "and keeps it out of what runs" "$(jq -r '.effective.keys.bindings["mod+e"] // "absent"' "$RTJ")" "absent"
eq "config approve is refused with a pointer to Settings" "$(jq -r '.error.code + " " + (.error.message|test("click in Settings")|tostring)' "$TMP/agent-approve.json")" "not_in_scope true"
eq "as is the socket op" "$(ctl '{"op":"config_approve","args":{"path":"keys.bindings.\"mod+e\"","value":"exec touch '"$EPRESS"'"}}' | jq -r .error.code)" "not_in_scope"
eq "and a user's CLI" "$(baneyspaces config approve 'keys.bindings."mod+e"' | jq -r .error.code)" "not_in_scope"
check "nothing wrote approvals.json" test ! -e "$XDG_STATE_HOME/baneyspaces/approvals.json"
eq "the test-only Settings click approves it" "$(ctl '{"op":"test_settings_approve","args":{"path":"keys.bindings.\"mod+e\"","value":"exec touch '"$EPRESS"'"}}' | jq -r '.data.live.keys')" "applied"
eq "now it is bound" "$(has_bind 'BaneySpaces: exec touch '"$EPRESS" && echo yes)" "yes"
check "approvals.json is private" test "$(stat -c %a "$XDG_STATE_HOME/baneyspaces/approvals.json")" = 600
press_cfg "BaneySpaces: exec touch $EPRESS"
check "and pressing it runs the command" wait_for 3 test -e "$EPRESS"
baneyspaces config set 'keys.bindings."mod+e"' "exec touch $EPRESS; true" >/dev/null
eq "any change to the value makes it pending again, and unbound" "$(has_bind 'BaneySpaces: exec touch '"$EPRESS; true" && echo bound || echo inert)" "inert"
baneyspaces config unset 'keys.bindings."mod+e"' >/dev/null
eq "Remove is an unset: free for anyone" "$(baneyspaces config get | jq -r '.data.pending|length')" "0"

eq "stop, lend and the like are pending too, not bound" "$(baneyspaces config set 'keys.bindings."mod+z"' 'stop' | jq -r '.data.pending[0].kind')" "privileged binding"
eq "(not bound)" "$(has_bind 'BaneySpaces: stop' && echo bound || echo inert)" "inert"
baneyspaces config unset 'keys.bindings."mod+z"' >/dev/null
# An approval written some other way still counts, is logged, and shows as made outside Settings.
OUTHOOK="echo outside"
baneyspaces config set hooks.on_switch "$OUTHOOK" >/dev/null
OID="$(printf 'hooks.on_switch\0%s' "$OUTHOOK" | sha256sum | cut -d' ' -f1)"
jq -n --arg id "$OID" --arg v "$OUTHOOK" '{format:1,approved:{($id):{path:"hooks.on_switch",value:$v,time:"2026-11-01T00:00:00Z"}}}' > "$XDG_STATE_HOME/baneyspaces/approvals.json"
check "(the daemon notices the file)" wait_for 5 sh -c "[ \"\$(jq -r '.approved[0].outside_settings' '$RTJ')\" = true ]"
eq "config.json marks it as approved outside Settings" "$(jq -r '.approved[]|select(.id=="'$OID'")|.outside_settings' "$RTJ")" "true"
check "the log says it did not come through the Settings handler" sh -c "grep '\"op\":\"approval\"' '$XDG_STATE_HOME/baneyspaces/config.log' | grep -q '\"outside_settings\":true'"
eq "the entry the Settings handler writes is marked as from Settings" "$(ctl '{"op":"test_settings_approve","args":{"path":"hooks.on_window_open","value":"x"}}' >/dev/null; jq -r '[.approved[]|select(.path=="hooks.on_window_open")|.outside_settings][0]' "$RTJ")" "false"
baneyspaces config reset hooks >/dev/null
rm -f "$XDG_STATE_HOME/baneyspaces/approvals.json"

# --- the recovery chord cannot be rebound or removed
eq "binding the recovery chord is refused" "$(jq -r '.error.data.issues[0].code' "$TMP/agent-rebind.json")" "reserved_chord"
eq "so is removing it" "$(jq -r '.error.data.issues[0].code' "$TMP/agent-unbind.json")" "reserved_chord"
eq "an animation over 1000 ms is refused with its path" "$(jq -r '.error.data.issues[0].path' "$TMP/agent-long.json")" "animation.dock.in.duration_ms"
eq "the recovery chord survived the attempts" "$(has_bind 'BaneySpaces: recovery (hold 2 s)' && echo yes)" "yes"
eq "exactly one recovery bind" "$(H binds | jq '[.[]|select(.description=="BaneySpaces: recovery (hold 2 s)")]|length')" "1"
check "the keys file does not bind it" sh -c "! grep -qi 'super + shift + escape' '$KEYS_LUA'"
printf '[keys.bindings]\n"super+shift+escape" = "exec true"\n' > "$TMP/rebind.toml"
eq "apply refuses it too" "$(baneyspaces config apply "$TMP/rebind.toml" | jq -r .error.data.issues[0].code)" "reserved_chord"
eq "the running config is unchanged by the refusals" "$(baneyspaces config get keys.bindings.mod+h | jq -r .data.value)" "agent-workspace show"

# --- undo removes the bind, and is recorded
baneyspaces config undo >/dev/null
eq "an agent cannot undo what the user did" "$(baneyspaces --agent-id tester agent run -- sh -c 'baneyspaces config undo 1 > '"$TMP"'/agent-undo.json; sleep 20' >/dev/null; wait_for 10 test -s "$TMP/agent-undo.json"; jq -r .error.code "$TMP/agent-undo.json")" "not_in_scope"
UNDONE=0
while has_bind "$HDESC" && [ $UNDONE -lt 12 ]; do baneyspaces config undo >/dev/null; UNDONE=$((UNDONE+1)); done
check "undo takes the bind out of Hyprland" wait_for 5 sh -c "! hyprctl -j binds | jq -e '[.[]|select(.description==\"$HDESC\")]|length > 0' >/dev/null"
eq "back to the defaults' count" "$(bs_binds)" "$BASE_BINDS"
check "and out of config.toml" sh -c "! grep -q 'mod+h' '$CFG/config.toml'"
check "undo is in the log" sh -c "grep -q '\"op\":\"config_undo\"' '$XDG_STATE_HOME/baneyspaces/config.log'"
eq "undo is a version in history, and nothing was deleted" "$(baneyspaces config history | jq -r '([.data.versions[]|select(.summary|startswith("undo"))]|length > 0) and ([.data.versions[]|select(.summary|startswith("set keys.bindings"))]|length > 0)')" "true"
eq "the workspace keys still work after all this" "$(baneyspaces switch 5 | jq -r .ok; baneyspaces switch 1 >/dev/null)" "true"

# --- keys: a rebind of a default, a mode, and the lockout
baneyspaces config set 'keys.bindings."mod+3"' 'move 7' >/dev/null
eq "a default can be rebound" "$(baneyspaces config get 'keys.bindings.mod+3' | jq -r .data.value)" "move 7"
baneyspaces config set keys.modes.resize.h 'window resize -40 0' >/dev/null
baneyspaces config set 'keys.bindings."mod+r"' 'mode resize' >/dev/null
check "a mode is a Hyprland submap" sh -c "hyprctl -j binds | jq -e '[.[]|select(.submap==\"resize\")]|length >= 2' >/dev/null"
check "the recovery chord is bound inside the mode too" sh -c "hyprctl -j binds | jq -e '[.[]|select(.submap==\"resize\" and .description==\"BaneySpaces: recovery (hold 2 s)\")]|length >= 1' >/dev/null"
eq "a mode with no way out is refused" "$(baneyspaces config set keys.modes.trap.escape 'switch 1' | jq -r '.error.data.issues[0].code')" "lockout"
ALLNONE="$(for n in 1 2 3 4 5 6 7 8 9; do printf '"mod+%s" = "none"\n' $n; done)"
printf '[keys.bindings]\n%s\n' "$ALLNONE" > "$TMP/lockout.toml"
eq "removing every workspace switch is refused" "$(baneyspaces config apply "$TMP/lockout.toml" | jq -r '.error.data.issues[0].code')" "lockout"
check "no workspace key was lost to the refusal" sh -c "hyprctl -j binds | jq -e '[.[]|select(.description==\"BaneySpaces: workspace 4\")]|length == 1' >/dev/null"
baneyspaces config reset keys >/dev/null
eq "reset keys restores the defaults in Hyprland" "$(bs_binds)" "$BASE_BINDS"

# --- a keys file whose binds cannot all be made installs nothing and leaves the defaults on
baneyspaces config set 'keys.bindings."mod+h"' 'agent-workspace hide' >/dev/null
check "(setup) a custom key is bound" has_bind 'BaneySpaces: agent-workspace hide'
cp "$KEYS_LUA" "$TMP/good-keys.lua"
sed 's|^  keys = {$|  keys = {\n    { "SUPER + nosuchkeysym", hl.dsp.exec_cmd("true"), "BaneySpaces: a bind Hyprland cannot make" },|' "$TMP/good-keys.lua" > "$TMP/bad-keys.lua"
check "(setup) the bad file has the failing bind" grep -q nosuchkeysym "$TMP/bad-keys.lua"
rm -f "$XDG_STATE_HOME/baneyspaces/keys-error.txt"
R="$(hyprctl eval "dofile(\"$TMP/bad-keys.lua\")")"
check "installing it is an error, not a success" test "$R" != ok
eq "the workspace keys are all still bound (the defaults went back on)" "$(bs_binds)" "$BASE_BINDS"
eq "the custom key was not installed" "$(has_bind 'BaneySpaces: agent-workspace hide' && echo yes || echo no)" "no"
eq "nothing of the bad file is bound" "$(has_bind 'BaneySpaces: a bind Hyprland cannot make' && echo yes || echo no)" "no"
eq "workspace 4's key is bound exactly once" "$(H binds | jq '[.[]|select(.description=="BaneySpaces: workspace 4")]|length')" "1"
eq "the recovery chord is still bound" "$(has_bind 'BaneySpaces: recovery (hold 2 s)' && echo yes)" "yes"
check "the failure is written down" sh -c "grep -q 'nosuchkeysym' '$XDG_STATE_HOME/baneyspaces/keys-error.txt'"
eq "a failing mode is the same: nothing installed" "$(hyprctl eval '__baneyspaces_install({ keys = { { "SUPER + code:12", hl.dsp.exec_cmd("true"), "BaneySpaces: should not stay" } }, modes = { { name = "m", binds = { { "NOPE + x", hl.dsp.exec_cmd("true"), "bad" } } } } })' | head -c 40 | grep -c ok)" "0"
eq "(and the key it was going to bind is not bound)" "$(has_bind 'BaneySpaces: should not stay' && echo yes || echo no)" "no"
eq "a good config installs again afterwards" "$(baneyspaces config set animation.speed 0.9 | jq -r '.data.live.keys')" "applied"
check "(and the custom key is back)" has_bind 'BaneySpaces: agent-workspace hide'
baneyspaces config reset >/dev/null

# --- the recovery chord's commands put the defaults back (what the hold runs)
baneyspaces config set 'keys.bindings."mod+h"' 'agent-workspace hide' >/dev/null
baneyspaces config set theme.name minimal >/dev/null
eq "(setup) a custom key and theme are in" "$(has_bind 'BaneySpaces: agent-workspace hide' && echo yes)" "yes"
RECOVERY_CMDS="$(sed -n 's/.*hl.exec_cmd("\(baneyspaces config reset [a-z]* --notify\)").*/\1/p' "$INCLUDE")"
eq "the include runs reset keys and reset theme" "$(echo "$RECOVERY_CMDS" | tr '\n' ';')" "baneyspaces config reset keys --notify;baneyspaces config reset theme --notify;"
echo "$RECOVERY_CMDS" | while read -r c; do sh -c "$c" >/dev/null 2>&1; done
eq "recovery restored the default keys" "$(has_bind 'BaneySpaces: agent-workspace hide' && echo yes || echo no)" "no"
eq "and the default theme" "$(jq -r .effective.theme.name "$RTJ")" "$DEFTHEME"
eq "recovery is recorded in history" "$(baneyspaces config history | jq -r '.data.versions[0].summary')" "reset theme"

# --- the hold itself: the include's Lua, driven directly (no input device in the nested host)
# hl.is_key_down is replaced by a table the test controls; the timers and the commands are real.
cat > "$TMP/hold-stub.lua" <<'EOF'
REAL_IS_KEY_DOWN = REAL_IS_KEY_DOWN or hl.is_key_down
ST = { Escape = true, Super_L = true, Shift_L = true }
hl.is_key_down = function(k) return ST[k] == true end
EOF
cat > "$TMP/hold-A.lua" <<'EOF'
ST = { Escape = true, Super_L = true, Shift_L = true }
__baneyspaces_recovery_press()
EOF
cat > "$TMP/hold-B.lua" <<'EOF'
ST = { Escape = true, Super_L = true, Shift_L = true }
__baneyspaces_recovery_press()
hl.timer(function() ST.Shift_L = false end, { timeout = 1000, type = "oneshot" })
EOF
cat > "$TMP/hold-C.lua" <<'EOF'
ST = { Escape = true, Super_L = true, Shift_L = true }
__baneyspaces_recovery_press()
hl.timer(function() ST = { Escape = false, Super_L = false, Shift_L = false } end, { timeout = 250, type = "oneshot" })
hl.timer(function() ST = { Escape = true, Super_L = false, Shift_L = false } end, { timeout = 900, type = "oneshot" })
EOF
cat > "$TMP/hold-D.lua" <<'EOF'
ST = { Escape = true, Super_L = true, Shift_L = true }
__baneyspaces_recovery_press()
hl.timer(function() ST.Escape = false end, { timeout = 700, type = "oneshot" })
hl.timer(function() ST.Escape = true; __baneyspaces_recovery_press() end, { timeout = 800, type = "oneshot" })
EOF
hold_prep() { baneyspaces config reset >/dev/null; baneyspaces config set 'keys.bindings."mod+g"' 'agent-workspace hide' >/dev/null; baneyspaces config set theme.name minimal >/dev/null; }
resets_in_history() { baneyspaces config history | jq '[.data.versions[]|select(.summary|test("^reset (keys|theme)$"))]|length'; }
hyprctl eval "dofile(\"$TMP/hold-stub.lua\")" >/dev/null
eq "the stub answers like the real function for the names the include uses" "$(hyprctl eval 'local f = io.open("'$TMP'/kd","w"); f:write(tostring(REAL_IS_KEY_DOWN("Escape")), tostring(REAL_IS_KEY_DOWN("Super_L")), tostring(REAL_IS_KEY_DOWN("Shift_L")), tostring((REAL_IS_KEY_DOWN("Nope_Key")))); f:close()' >/dev/null; sleep 0.2; cat "$TMP/kd")" "falsefalsefalsenil"
hold_prep; R0="$(resets_in_history)"
hyprctl eval "dofile(\"$TMP/hold-A.lua\")" >/dev/null; sleep 1.4
eq "held 1.4 s: nothing yet" "$(resets_in_history)" "$R0"
sleep 1.4
eq "held 2 s with all three keys: keys and theme are reset" "$(resets_in_history)" "$((R0+2))"
eq "(and the keys are the defaults)" "$(has_bind 'BaneySpaces: agent-workspace hide' && echo custom || echo default)" "default"
hold_prep; R0="$(resets_in_history)"
hyprctl eval "dofile(\"$TMP/hold-B.lua\")" >/dev/null; sleep 3.2
eq "Shift let go at 1 s: no reset" "$(resets_in_history)" "$R0"
eq "(the custom key is still there)" "$(has_bind 'BaneySpaces: agent-workspace hide' && echo custom || echo default)" "custom"
hyprctl eval "dofile(\"$TMP/hold-C.lua\")" >/dev/null; sleep 3.2
eq "a tap, then Escape alone at the 2 s mark: no reset" "$(resets_in_history)" "$R0"
hyprctl eval "dofile(\"$TMP/hold-D.lua\")" >/dev/null; sleep 1.5
eq "released and pressed again: the first press is void, the new one has not had 2 s" "$(resets_in_history)" "$R0"
sleep 1.8
eq "and the new press, held through, resets once" "$(resets_in_history)" "$((R0+2))"

# --- the chord works from inside a mode, and the reset leaves the mode
hold_prep
baneyspaces config set keys.modes.resize.h 'window resize -40 0' >/dev/null
baneyspaces config set 'keys.bindings."mod+r"' 'mode resize' >/dev/null
hyprctl dispatch 'hl.dsp.submap("resize")' >/dev/null; sleep 0.3
eq "(setup) Hyprland is in the resize mode" "$(hyprctl submap)" "resize"
eq "the chord is bound in the mode" "$(H binds | jq '[.[]|select(.submap=="resize" and .description=="BaneySpaces: recovery (hold 2 s)")]|length >= 1')" "true"
R0="$(resets_in_history)"
hyprctl eval "dofile(\"$TMP/hold-A.lua\")" >/dev/null; sleep 3.2
eq "held inside the mode: the reset ran" "$(resets_in_history)" "$((R0+2))"
eq "and the person is back in the default mode" "$(hyprctl submap)" "default"
eq "with the global keys active" "$(bs_binds)" "$BASE_BINDS"
# Removing a mode while in it (not by the chord) also leaves it.
hold_prep
baneyspaces config set keys.modes.resize.h 'window resize -40 0' >/dev/null
baneyspaces config set 'keys.bindings."mod+r"' 'mode resize' >/dev/null
hyprctl dispatch 'hl.dsp.submap("resize")' >/dev/null; sleep 0.3
baneyspaces config unset 'keys.bindings."mod+r"' >/dev/null
baneyspaces config unset keys.modes.resize >/dev/null; sleep 0.5
eq "removing the mode you are in leaves it" "$(hyprctl submap)" "default"
hyprctl eval 'hl.is_key_down = REAL_IS_KEY_DOWN' >/dev/null
baneyspaces config reset >/dev/null

# --- a reset waits for a slow daemon and never writes the files behind it
baneyspaces config set 'keys.bindings."mod+h"' 'agent-workspace hide' >/dev/null
SDP="$(ctl '{"op":"ping"}' | jq -r .data.pid)"; rm -f "$TMP/slow.json"
kill -STOP "$SDP"
( baneyspaces config reset keys > "$TMP/slow.json" 2>&1 & )
sleep 7
eq "after 7 s of a stopped daemon the reset has not written the files itself" "$(grep -c 'mod+h' "$CFG/config.toml")" "1"
check "and has printed nothing" test ! -s "$TMP/slow.json"
kill -CONT "$SDP"
check "once the daemon runs, it does the reset" wait_for 15 test -s "$TMP/slow.json"
eq "through the daemon" "$(jq -r '.ok, (.data.via // "daemon")' "$TMP/slow.json" | tr '\n' ' ')" "true daemon "
eq "the keys are the defaults in Hyprland" "$(has_bind 'BaneySpaces: agent-workspace hide' && echo custom || echo default)" "default"

# --- recovery works with the daemon down
DP="$(ctl '{"op":"ping"}' | jq -r .data.pid)"
baneyspaces config set 'keys.bindings."mod+h"' 'agent-workspace hide' >/dev/null
kill -TERM "$DP"; wait_for 6 sh -c '! baneyspaces state 2>/dev/null | jq -e .ok >/dev/null'
R="$(baneyspaces config reset keys)"
eq "reset keys works with no daemon" "$(echo "$R" | jq -r '.ok')" "true"
eq "and says it went through the local path" "$(echo "$R" | jq -r '.data.via')" "local (the daemon is not running)"
check "and Hyprland has the defaults again" wait_for 5 sh -c "! hyprctl -j binds | jq -e '[.[]|select(.description==\"BaneySpaces: agent-workspace hide\")]|length > 0' >/dev/null"
# A keys file that fails to run (a Hyprland update, an old binary) must not leave the session with no keys.
mkdir -p "$XDG_STATE_HOME/baneyspaces"; echo 'error("boom: keys file broken")' > "$KEYS_LUA"
hyprctl reload >/dev/null; sleep 1.5
eq "a broken keys file falls back to the default keys on a reload" "$(bs_binds)" "$BASE_BINDS"
check "and says why" sh -c "grep -q boom '$XDG_STATE_HOME/baneyspaces/keys-error.txt'"
eq "with the recovery chord bound" "$(has_bind 'BaneySpaces: recovery (hold 2 s)' && echo yes)" "yes"
baneyspaces daemon --trace >>"$TMP/daemon.log" 2>&1 & DPID=$!; PIDS+=($DPID)
check "(the daemon starts again)" wait_for 8 sh -c 'baneyspaces state 2>/dev/null | jq -e .ok >/dev/null'

# --- a hand edit is noticed (inotify), recorded as the user, and applied
cat > "$CFG/config.toml.new" <<'EOF'
# edited by hand
[keys.bindings]
"mod+y" = "agent-workspace hide"
EOF
mv "$CFG/config.toml.new" "$CFG/config.toml"
check "a hand edit reaches Hyprland within a few seconds" wait_for 5 has_bind 'BaneySpaces: agent-workspace hide'
eq "history says the user did it" "$(last_caller)" "user"
printf '[keys\nnot toml' > "$CFG/config.toml"
sleep 1
eq "a broken file leaves the last good keys running" "$(has_bind 'BaneySpaces: agent-workspace hide' && echo yes)" "yes"
eq "and the status says what is wrong" "$(jq -r '.status.valid|tostring' "$RTJ")" "false"
eq "a change through the CLI is refused until the file is fixed" "$(baneyspaces config set animation.speed 2 | jq -r .error.code)" "config_invalid"
baneyspaces config reset keys >/dev/null
eq "reset repairs it" "$(jq -r '.status.valid|tostring' "$RTJ")" "true"

# --- animation and theme go to the file the UIs read
baneyspaces config set animation.preset omarchy >/dev/null
eq "preset omarchy: dock.in is 400 ms" "$(jq -r '.resolved.animation["dock.in"].duration_ms' "$RTJ")" "400"
eq "preset omarchy: hud.in is 410 ms with easeOutQuint" "$(jq -c '.resolved.animation["hud.in"]|[.duration_ms,.points]' "$RTJ")" "[410,[0.23,1.0,0.32,1.0]]"
eq "the focus border follows it in Hyprland (539 ms)" "$(H animations | jq -r '[.[][]|select(.name=="border")|.speed]|first')" "5.39"
baneyspaces config set animation.speed 0.5 >/dev/null
eq "speed halves every duration" "$(jq -r '.resolved.animation["dock.in"].duration_ms' "$RTJ")" "200"
eq "workspace switches stay instant" "$(H animations | jq -r '[.[][]|select(.name=="workspaces")|.enabled]|first')" "false"
baneyspaces config reset animation >/dev/null
baneyspaces theme create mine --extends omarchy --tokens '{"radius":{"tile":3}}' >/dev/null
baneyspaces theme set mine >/dev/null
eq "a custom theme's token reaches config.json" "$(jq -r '.resolved.theme.tokens.radius.tile' "$RTJ")" "3"
eq "theme.override wins over it" "$(baneyspaces config set theme.override.radius.tile 9 >/dev/null; jq -r '.resolved.theme.tokens.radius.tile' "$RTJ")" "9"
eq "the active theme cannot be deleted" "$(baneyspaces theme delete mine | jq -r .error.code)" "config_invalid"
baneyspaces config reset theme >/dev/null
eq "reset theme goes back to the default theme" "$(jq -r '.effective.theme.name' "$RTJ")" "$DEFTHEME"

# --- behavior and rules go to the daemon's model
baneyspaces config set rules '[{"app":"foot","title":"^ruletest$","workspace":7,"float":true}]' >/dev/null
baneyspaces switch 2 >/dev/null; sleep 0.2
hyprctl dispatch "hl.dsp.exec_cmd(\"foot -T ruletest sleep 600\")" >/dev/null
RW=""; for _ in $(seq 1 60); do RW="$(H clients | jq -r '.[]|select(.title=="ruletest")|.address')"; [ -n "$RW" ] && break; sleep 0.1; done
sleep 0.5
eq "a rule sent the window to workspace 7" "$(H clients | jq -r ".[]|select(.address==\"$RW\")|.workspace.name")" "7"
eq "and floated it" "$(H clients | jq -r ".[]|select(.address==\"$RW\")|.floating")" "true"
eq "the model has it on 7" "$(baneyspaces state | jq -r ".data.windows[\"$RW\"].home")" "7"
baneyspaces config set behavior.follow_focus false >/dev/null
baneyspaces switch 2 >/dev/null; sleep 0.2
hyprctl dispatch "hl.dsp.focus({ window = \"address:$RW\" })" >/dev/null; sleep 0.4
eq "follow_focus = false: activating it yourself does not take you to 7" "$(H monitors | jq -r '.[]|select(.focused)|.activeWorkspace.id')" "2"
baneyspaces config set behavior.follow_focus true >/dev/null
baneyspaces config reset >/dev/null

# --- hooks are executable: pending until a click in Settings, then they run as you
open_hookwin() { hyprctl dispatch "hl.dsp.exec_cmd(\"foot -T $1 sleep 60\")" >/dev/null; for _ in $(seq 1 60); do H clients | jq -e ".[]|select(.title==\"$1\")" >/dev/null && break; sleep 0.1; done; sleep 0.8; }
HOOKOUT="$TMP/hook-out"; rm -f "$HOOKOUT"
HCMD="echo \$BANEYSPACES_WORKSPACE >> $HOOKOUT"
baneyspaces config set hooks.on_switch "$HCMD" >/dev/null
eq "a hook set by you is pending too" "$(baneyspaces config get hooks | jq -r '.data.pending[0].path')" "hooks.on_switch"
baneyspaces switch 8 >/dev/null; sleep 0.8
eq "so it does not run" "$(test -e "$HOOKOUT" && echo ran || echo inert)" "inert"
ctl "$(jq -nc --arg v "$HCMD" '{op:"test_settings_approve",args:{path:"hooks.on_switch",value:$v}}')" >/dev/null
baneyspaces switch 7 >/dev/null; sleep 0.8
check "once approved it runs, with the workspace in its environment" sh -c "grep -q '^7$' '$HOOKOUT'"
check "the hook is in the log" sh -c "grep -q '\"hook\":\"on_switch\"' '$XDG_STATE_HOME/baneyspaces/config.log'"
baneyspaces config set hooks.on_switch "$HCMD; true" >/dev/null
rm -f "$HOOKOUT"; baneyspaces switch 6 >/dev/null; sleep 0.8
eq "a changed hook is pending again and does not run" "$(test -e "$HOOKOUT" && echo ran || echo inert)" "inert"
baneyspaces config reset hooks >/dev/null
baneyspaces switch 1 >/dev/null

# An agent sets a hook that switches workspaces: it does not run, and no command makes it.
HOOKSW="$TMP/hook-switch.json"; rm -f "$HOOKSW" "$TMP/agent-hook-done"
cat > "$TMP/agent-hook.sh" <<EOF
baneyspaces config set hooks.on_window_open "baneyspaces switch 3 > $HOOKSW 2>&1" > "$TMP/agent-hook-set.json" 2>&1
echo done > "$TMP/agent-hook-done"
sleep 30
EOF
baneyspaces --agent-id hooker agent run -- sh "$TMP/agent-hook.sh" >/dev/null
check "(setup) the agent set a hook" wait_for 20 test -e "$TMP/agent-hook-done"
eq "an agent may set a hook" "$(jq -r .ok "$TMP/agent-hook-set.json")" "true"
eq "it is pending, with the agent as the hint" "$(baneyspaces config get hooks | jq -r '.data.pending[0]|[.path,.written_by_hint]|join(" ")')" "hooks.on_window_open agent:hooker"
baneyspaces switch 5 >/dev/null; sleep 0.3
open_hookwin hookwin1
eq "a window opens and the hook does not run" "$(test -e "$HOOKSW" && echo ran || echo inert)" "inert"
eq "the workspace did not change" "$(H monitors | jq -r '.[]|select(.focused)|.activeWorkspace.id')" "5"
ctl "$(jq -nc --arg v "baneyspaces switch 3 > $HOOKSW 2>&1" '{op:"test_settings_approve",args:{path:"hooks.on_window_open",value:$v}}')" >/dev/null
open_hookwin hookwin2
check "approved in Settings (the test op), it runs" wait_for 5 test -s "$HOOKSW"
baneyspaces config reset hooks >/dev/null
baneyspaces switch 1 >/dev/null

check "history keeps at most 50 versions" test "$(ls "$CFG/history" | wc -l)" -le 50
check "writes left no temp files behind" sh -c "! ls -a '$CFG' '$CFG/history' | grep -q '\\.tmp'"
check "the daemon logged no panic" sh -c "! grep -q panicked '$TMP/daemon.log'"

if [ -n "${STANDALONE:-}" ]; then
  echo; echo "passed $PASS, failed $FAIL"
  [ "$FAIL" -eq 0 ] && { echo "PASS: config.sh ($PASS checks)"; exit 0; } || { echo "FAIL: config.sh ($FAIL of $((PASS+FAIL)) checks)"; exit 1; }
fi
