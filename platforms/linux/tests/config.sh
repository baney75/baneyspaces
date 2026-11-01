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
HPRESS="$TMP/h-pressed"; rm -f "$HPRESS"
cat > "$TMP/agent-config.sh" <<EOF
baneyspaces config set 'keys.bindings."mod+h"' 'exec touch $HPRESS' > "$TMP/agent-set.json" 2>&1
baneyspaces config set 'keys.bindings."super+shift+escape"' 'exec true' > "$TMP/agent-rebind.json" 2>&1
baneyspaces config set 'keys.bindings."mod+shift+escape"' 'none' > "$TMP/agent-unbind.json" 2>&1
baneyspaces config set animation.dock.in.duration_ms 5000 > "$TMP/agent-long.json" 2>&1
echo done > "$TMP/agent-done"
sleep 60
EOF
baneyspaces --agent-id tester agent run -- sh "$TMP/agent-config.sh" >/dev/null
check "(setup) the agent process ran its commands" wait_for 20 test -e "$TMP/agent-done"
eq "an agent may set a binding" "$(jq -r '.ok' "$TMP/agent-set.json")" "true"
eq "the history records the caller from the peer's token, not from a flag" "$(baneyspaces config history | jq -r '[.data.versions[]|select(.summary|startswith("set keys.bindings"))][0].caller')" "agent:tester"
eq "Hyprland's binds changed: the new binding is there" "$(has_bind 'BaneySpaces: exec touch '"$HPRESS" && echo yes)" "yes"
eq "and it is one more bind than before" "$(bs_binds)" "$((BASE_BINDS+1))"
check "config.toml holds only that" sh -c "grep -q 'mod+h' '$CFG/config.toml' && ! grep -q 'speed' '$CFG/config.toml'"
press_cfg "BaneySpaces: exec touch $HPRESS"
check "pressing it ran the action" test -e "$HPRESS"
eq "the same agent cannot press workspace keys (switch is still the user's)" "$(baneyspaces --agent-id tester agent run -- sh -c 'baneyspaces switch 3 > '"$TMP"'/agent-switch.json; sleep 20' >/dev/null; wait_for 10 test -s "$TMP/agent-switch.json"; jq -r .error.code "$TMP/agent-switch.json")" "not_in_scope"

# --- the recovery chord cannot be rebound or removed
eq "binding the recovery chord is refused" "$(jq -r '.error.data.issues[0].code' "$TMP/agent-rebind.json")" "reserved_chord"
eq "so is removing it" "$(jq -r '.error.data.issues[0].code' "$TMP/agent-unbind.json")" "reserved_chord"
eq "an animation over 1000 ms is refused with its path" "$(jq -r '.error.data.issues[0].path' "$TMP/agent-long.json")" "animation.dock.in.duration_ms"
eq "the recovery chord survived the attempts" "$(has_bind 'BaneySpaces: recovery (hold 2 s)' && echo yes)" "yes"
eq "exactly one recovery bind" "$(H binds | jq '[.[]|select(.description=="BaneySpaces: recovery (hold 2 s)")]|length')" "1"
check "the keys file does not bind it" sh -c "! grep -qi 'super + shift + escape' '$KEYS_LUA'"
printf '[keys.bindings]\n"super+shift+escape" = "exec true"\n' > "$TMP/rebind.toml"
eq "apply refuses it too" "$(baneyspaces config apply "$TMP/rebind.toml" | jq -r .error.data.issues[0].code)" "reserved_chord"
eq "the running config is unchanged by the refusals" "$(baneyspaces config get keys.bindings.mod+h | jq -r .data.value)" "exec touch $HPRESS"

# --- undo removes the bind
baneyspaces config undo >/dev/null
check "undo takes the bind out of Hyprland" wait_for 5 sh -c "! hyprctl -j binds | jq -e '[.[]|select(.description==\"BaneySpaces: exec touch $HPRESS\")]|length > 0' >/dev/null"
eq "back to the defaults' count" "$(bs_binds)" "$BASE_BINDS"
check "and out of config.toml" sh -c "! grep -q 'mod+h' '$CFG/config.toml'"
eq "undo is recorded in the log" "$(grep -c '"op":"config_undo"' "$XDG_STATE_HOME/baneyspaces/config.log")" "1"
eq "the workspace keys still work after all this" "$(baneyspaces switch 5 | jq -r .ok; baneyspaces switch 1 >/dev/null)" "true"

# --- keys: a rebind of a default, a mode, and the lockout
baneyspaces config set 'keys.bindings."mod+3"' 'exec true' >/dev/null
eq "a default can be rebound" "$(baneyspaces config get 'keys.bindings.mod+3' | jq -r .data.value)" "exec true"
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

# --- the recovery chord's commands put the defaults back (what the hold runs)
baneyspaces config set 'keys.bindings."mod+h"' 'exec true' >/dev/null
baneyspaces config set theme.name minimal >/dev/null
eq "(setup) a custom key and theme are in" "$(has_bind 'BaneySpaces: exec true' && echo yes)" "yes"
RECOVERY_CMDS="$(sed -n 's/.*hl.exec_cmd("\(baneyspaces config reset [a-z]* --notify\)").*/\1/p' "$INCLUDE")"
eq "the include runs reset keys and reset theme" "$(echo "$RECOVERY_CMDS" | tr '\n' ';')" "baneyspaces config reset keys --notify;baneyspaces config reset theme --notify;"
echo "$RECOVERY_CMDS" | while read -r c; do sh -c "$c" >/dev/null 2>&1; done
eq "recovery restored the default keys" "$(has_bind 'BaneySpaces: exec true' && echo yes || echo no)" "no"
eq "and the default theme" "$(jq -r .effective.theme.name "$RTJ")" "$DEFTHEME"
eq "recovery is recorded in history" "$(baneyspaces config history | jq -r '.data.versions[0].summary')" "reset theme"

# --- recovery works with the daemon down
DP="$(ctl '{"op":"ping"}' | jq -r .data.pid)"
baneyspaces config set 'keys.bindings."mod+h"' 'exec true' >/dev/null
kill -TERM "$DP"; wait_for 6 sh -c '! baneyspaces state 2>/dev/null | jq -e .ok >/dev/null'
R="$(baneyspaces config reset keys)"
eq "reset keys works with no daemon" "$(echo "$R" | jq -r '.ok')" "true"
eq "and says it went through the local path" "$(echo "$R" | jq -r '.data.via')" "local (the daemon is not running)"
check "and Hyprland has the defaults again" wait_for 5 sh -c "! hyprctl -j binds | jq -e '[.[]|select(.description==\"BaneySpaces: exec true\")]|length > 0' >/dev/null"
baneyspaces daemon --trace >>"$TMP/daemon.log" 2>&1 & DPID=$!; PIDS+=($DPID)
check "(the daemon starts again)" wait_for 8 sh -c 'baneyspaces state 2>/dev/null | jq -e .ok >/dev/null'

# --- a hand edit is noticed (inotify), recorded as the user, and applied
cat > "$CFG/config.toml.new" <<'EOF'
# edited by hand
[keys.bindings]
"mod+y" = "exec true"
EOF
mv "$CFG/config.toml.new" "$CFG/config.toml"
check "a hand edit reaches Hyprland within a few seconds" wait_for 5 has_bind 'BaneySpaces: exec true'
eq "history says the user did it" "$(last_caller)" "user"
printf '[keys\nnot toml' > "$CFG/config.toml"
sleep 1
eq "a broken file leaves the last good keys running" "$(has_bind 'BaneySpaces: exec true' && echo yes)" "yes"
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

# --- hooks run as you, are logged, and are in history
HOOKOUT="$TMP/hook-out"; rm -f "$HOOKOUT"
baneyspaces config set hooks.on_switch "echo \$BANEYSPACES_WORKSPACE >> $HOOKOUT" >/dev/null
baneyspaces switch 8 >/dev/null; sleep 0.8
check "on_switch ran with the workspace in its environment" sh -c "grep -q '^8$' '$HOOKOUT'"
check "the hook is in the log" sh -c "grep -q '\"hook\":\"on_switch\"' '$XDG_STATE_HOME/baneyspaces/config.log'"
eq "and in history" "$(last_summary | cut -c1-15)" "set hooks.on_sw"
eq "config get hooks says who set each one" "$(baneyspaces config get hooks | jq -r '.data.hooks_set_by.on_switch')" "user"
baneyspaces config reset hooks >/dev/null
baneyspaces switch 1 >/dev/null

# --- a hook runs with the identity of whoever set it
open_hookwin() { hyprctl dispatch "hl.dsp.exec_cmd(\"foot -T $1 sleep 60\")" >/dev/null; for _ in $(seq 1 60); do H clients | jq -e ".[]|select(.title==\"$1\")" >/dev/null && break; sleep 0.1; done; sleep 0.6; }
HOOKSW="$TMP/hook-switch.json"; rm -f "$HOOKSW" "$TMP/agent-hook-release"
cat > "$TMP/agent-hook.sh" <<EOF
baneyspaces config set hooks.on_window_open "baneyspaces switch 3 > $HOOKSW 2>&1" > "$TMP/agent-hook-set.json" 2>&1
echo done > "$TMP/agent-hook-done"
while [ ! -e "$TMP/agent-hook-release" ]; do sleep 0.2; done
EOF
baneyspaces --agent-id hooker agent run -- sh "$TMP/agent-hook.sh" >/dev/null
check "(setup) the agent set a hook" wait_for 20 test -e "$TMP/agent-hook-done"
eq "an agent may set a hook" "$(jq -r .ok "$TMP/agent-hook-set.json")" "true"
eq "config get says the agent set it" "$(baneyspaces config get hooks | jq -r '.data.hooks_set_by.on_window_open')" "agent:hooker"
baneyspaces switch 5 >/dev/null; sleep 0.3
open_hookwin hookwin1
check "the hook ran" wait_for 5 test -s "$HOOKSW"
eq "its switch was refused like the agent's own: not_in_scope" "$(jq -r '.error.code' "$HOOKSW" 2>/dev/null)" "not_in_scope"
eq "and the workspace did not change" "$(H monitors | jq -r '.[]|select(.focused)|.activeWorkspace.id')" "5"
eq "the log names who it ran as" "$(grep -c '"set_by":"agent:hooker"' "$XDG_STATE_HOME/baneyspaces/config.log")" "1"
# The agent's process is gone: its hook has no identity to run as, so it does not run.
touch "$TMP/agent-hook-release"; sleep 2; rm -f "$HOOKSW"
open_hookwin hookwin2
eq "with no live process of the agent the hook does not run" "$(test -e "$HOOKSW" && echo ran || echo skipped)" "skipped"
check "and a line says so" sh -c "grep -q 'has no running process to run it as' '$XDG_STATE_HOME/baneyspaces/config.log'"
eq "the workspace still did not change" "$(H monitors | jq -r '.[]|select(.focused)|.activeWorkspace.id')" "5"
baneyspaces config reset hooks >/dev/null
baneyspaces switch 1 >/dev/null

check "history keeps at most 50 versions" test "$(ls "$CFG/history" | wc -l)" -le 50
check "writes left no temp files behind" sh -c "! ls -a '$CFG' '$CFG/history' | grep -q '\\.tmp'"
check "the daemon logged no panic" sh -c "! grep -q panicked '$TMP/daemon.log'"

if [ -n "${STANDALONE:-}" ]; then
  echo; echo "passed $PASS, failed $FAIL"
  [ "$FAIL" -eq 0 ] && { echo "PASS: config.sh ($PASS checks)"; exit 0; } || { echo "FAIL: config.sh ($FAIL of $((PASS+FAIL)) checks)"; exit 1; }
fi
