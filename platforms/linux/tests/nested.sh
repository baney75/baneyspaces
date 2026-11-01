#!/usr/bin/env bash
# Integration test for BaneySpaces on Linux, in a NESTED headless Hyprland. It never touches the
# Hyprland session you are running in:
#   - it runs inside its own D-Bus session (dbus-run-session), its own XDG_RUNTIME_DIR under /tmp,
#     its own HOME and its own AT-SPI bus;
#   - Hyprland runs as a client of a headless "cage" compositor (see build-host.sh), so no window
#     ever appears on a real display;
#   - before and after, it records `hyprctl -j activeworkspace/activewindow/monitors` of the REAL
#     instance (the one in the environment it was started from) and fails if they differ.
# Prints PASS or FAIL with counts. Needs: Hyprland, foot, jq, python-gobject (GTK4), at-spi2-core.
#
#   platforms/linux/tests/nested.sh            # builds first if needed
#   KEEP=1 platforms/linux/tests/nested.sh     # keep the temp dir (logs) afterwards
set -uo pipefail
# Noise from the nested D-Bus session and portals is not test output.
export G_MESSAGES_DEBUG=

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

if [ "${1:-}" != "--inner" ]; then
  # ---- outer: build, snapshot the real session, run the inner script in a private D-Bus session ----
  (cd "$REPO" && cargo build -q -p baneyspaces-linux) || { echo "FAIL: cargo build"; exit 1; }
  [ -x "$REPO/platforms/linux/engine/agent-desktop" ] || "$REPO/platforms/linux/scripts/build-engine.sh" --profile ci >/dev/null || { echo "FAIL: engine build"; exit 1; }
  HOST="$("$HERE/build-host.sh")" || { echo "FAIL: host compositor build"; exit 1; }
  real() { hyprctl -j "$1" 2>/dev/null | jq -S -c "$2" 2>/dev/null || echo "none"; }
  snap() { echo "ws=$(real activeworkspace '{id,name,monitor}') win=$(real activewindow '.address') mons=$(real monitors '[.[]|{name,id,aw:.activeWorkspace.id,sp:.specialWorkspace.name,focused}]')"; }
  REAL_BEFORE="$(snap)"
  echo "real session before: $REAL_BEFORE"
  # The inner run gets a clean environment: nothing that names the real Hyprland or Wayland display.
  env -i HOME="$HOME" PATH="$PATH" USER="${USER:-}" TERM="${TERM:-dumb}" LANG="${LANG:-C.UTF-8}" KEEP="${KEEP:-}" DEBUG="${DEBUG:-}" HOST="$HOST" \
    dbus-run-session -- bash "$HERE/nested.sh" --inner
  RC=$?
  REAL_AFTER="$(snap)"
  echo "real session after:  $REAL_AFTER"
  if [ "$REAL_BEFORE" = "$REAL_AFTER" ]; then
    echo "real session unchanged: yes"
  else
    echo "real session unchanged: NO"
    echo "FAIL: the real session changed"
    exit 1
  fi
  exit $RC
fi

# ------------------------------------ inner ------------------------------------
TMP="$(mktemp -d /tmp/bs-nested.XXXXXX)"; chmod 700 "$TMP"
mkdir -p "$TMP/run" "$TMP/home" "$TMP/state" "$TMP/config"; chmod 700 "$TMP/run"
export XDG_RUNTIME_DIR="$TMP/run" HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" XDG_CONFIG_HOME="$TMP/config"
BIN="$REPO/target/debug"
export PATH="$BIN:$PATH" BANEYSPACES_ENGINE="$REPO/platforms/linux/engine/agent-desktop"
unset HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY DISPLAY

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() {
  FAIL=$((FAIL+1)); echo "  FAIL $1${2:+ -- $2}"
  if [ -n "${DEBUG:-}" ]; then
    echo "       model: $(baneyspaces state 2>/dev/null | jq -c '.data|{fm:.focused_monitor,act:.active,cur:(.monitors|map_values(.current)),ws:.workspaces,agent:.agent.windows}' 2>/dev/null)"
    echo "       hypr:  $(hyprctl -j monitors 2>/dev/null | jq -c '[.[]|{n:.name,w:.activeWorkspace.id,f:.focused}]' 2>/dev/null) active=$(hyprctl -j activewindow 2>/dev/null | jq -c '.title' 2>/dev/null)"
  fi
}
check() { # check "description" <command...>: passes when the command succeeds
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

PIDS=()
cleanup() {
  # Children first: the host compositor's child is the nested Hyprland, and it must not outlive the test.
  for p in "${PIDS[@]}"; do pkill -TERM -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  sleep 0.3
  [ -n "${KEEP:-}" ] && echo "kept $TMP" || rm -rf "$TMP"
}
trap cleanup EXIT

# --- the at-spi bus (dbus-run-session's systemd activation does not work here)
/usr/lib/at-spi-bus-launcher --launch-immediately >"$TMP/atspi.log" 2>&1 & PIDS+=($!)
sleep 0.5
/usr/lib/at-spi2-registryd --use-gnome-session >"$TMP/registry.log" 2>&1 & PIDS+=($!)

# --- the test Hyprland config: Omarchy-like default bindings first, then BaneySpaces' include
cat >"$TMP/hypr.lua" <<EOF
hl.config({ debug = { enable_stdout_logs = true }, misc = { disable_hyprland_logo = true } })
hl.monitor({ output = "HEADLESS-1", mode = "1920x1080@60", position = "0x0", scale = 1 })
hl.monitor({ output = "HEADLESS-2", mode = "1920x1080@60", position = "1920x0", scale = 1 })
-- what Omarchy binds before BaneySpaces replaces it
for n = 1, 9 do
  local k = "code:" .. tostring(n + 9)
  hl.bind("SUPER + " .. k, hl.dsp.focus({ workspace = tostring(n) }), { description = "Omarchy: workspace " .. n })
  hl.bind("SUPER + SHIFT + " .. k, hl.dsp.window.move({ workspace = tostring(n) }), { description = "Omarchy: move " .. n })
  hl.bind("SUPER + SHIFT + ALT + " .. k, hl.dsp.window.move({ workspace = tostring(n), follow = false }), { description = "Omarchy: move silently " .. n })
end
hl.bind("SUPER + TAB", hl.dsp.focus({ workspace = "e+1" }), { description = "Omarchy: next workspace" })
dofile("$REPO/platforms/linux/omarchy/baneyspaces.lua")
EOF

# --- host compositor (headless cage) and Hyprland inside it
export WLR_BACKENDS=headless WLR_RENDERER=gles2 WLR_LIBINPUT_NO_DEVICES=1
for d in /dev/dri/renderD*; do # an integrated GPU's render node: never the discrete one
  drv="$(basename "$(readlink "/sys/class/drm/$(basename "$d")/device/driver")")"
  case "$drv" in nvidia) ;; *) export WLR_RENDER_DRM_DEVICE="$d"; break;; esac
done
"$HOST" -- Hyprland --config "$TMP/hypr.lua" >"$TMP/hyprland.out" 2>&1 & PIDS+=($!)
for _ in $(seq 1 100); do
  SIG="$(ls "$TMP/run/hypr" 2>/dev/null | head -1)"
  [ -n "$SIG" ] && [ -S "$TMP/run/hypr/$SIG/.socket.sock" ] && break; sleep 0.1
done
[ -n "${SIG:-}" ] || { echo "FAIL: nested Hyprland did not start"; tail -5 "$TMP/hyprland.out"; exit 1; }
export HYPRLAND_INSTANCE_SIGNATURE="$SIG" WAYLAND_DISPLAY=wayland-1 GDK_BACKEND=wayland GSK_RENDERER=cairo
case "$XDG_RUNTIME_DIR" in /tmp/bs-nested.*) ;; *) echo "FAIL: refusing to run outside the temp runtime dir"; exit 1;; esac
sleep 0.5
hyprctl output create headless >/dev/null; hyprctl output create headless >/dev/null
sleep 0.5

H() { hyprctl -j "$@"; }
mon_ws() { H monitors | jq -r ".[]|select(.name==\"$1\")|.activeWorkspace.id"; }
active() { H activewindow | jq -r '.address // "none"'; }
special() { H monitors | jq -r '[.[]|.specialWorkspace.name]|map(select(.=="special:agent"))|length'; }
cursor() { H cursorpos | jq -c .; }
cfg_errors() { hyprctl configerrors | grep -v '^$' | head -5; }
M1=HEADLESS-1; M2=HEADLESS-2

echo "== nested Hyprland up: $(hyprctl version | head -1)"
eq "test config has no errors" "$(cfg_errors)" ""
eq "two monitors" "$(H monitors | jq length)" "2"
eq "monitors are 1920 wide (a real mode)" "$(H monitors | jq -r '.[0].width')" "1920"

# --- the daemon
baneyspaces daemon --trace >"$TMP/daemon.log" 2>&1 & DPID=$!; PIDS+=($DPID)
for _ in $(seq 1 100); do baneyspaces state 2>/dev/null | jq -e .ok >/dev/null 2>&1 && break; sleep 0.1; done
check "daemon answers" sh -c 'baneyspaces state | jq -e .ok'
eq "daemon knows both monitors" "$(baneyspaces state | jq -r '.data.monitors|keys|join(",")')" "$M1,$M2"
eq "first monitor is slot 0, second slot 1" "$(baneyspaces state | jq -r ".data.monitors[\"$M1\"].slot,.data.monitors[\"$M2\"].slot" | tr '\n' ,)" "0,1,"
eq "workspace animations are off" "$(H animations | jq -r '[.[0][]|select(.name=="workspaces")|.enabled]|first')" "false"
eq "apps cannot take focus by asking" "$(hyprctl getoption misc:focus_on_activate | head -1)" "bool: false"

echo "== key bindings (Omarchy defaults replaced)"
BINDS="$(H binds)"
[ -n "${DEBUG:-}" ] && echo "$BINDS" | jq -c '[.[]|select((.description//"")|startswith("BaneySpaces"))]|first'
eq "29 BaneySpaces bindings" "$(echo "$BINDS" | jq '[.[]|select((.description//"")|startswith("BaneySpaces"))]|length')" "29"
eq "no Omarchy workspace binding is left for 1-9" "$(echo "$BINDS" | jq '[.[]|select((.description//"")|startswith("Omarchy: workspace") or startswith("Omarchy: move"))]|length')" "0"
eq "the overview key is BaneySpaces'" "$(echo "$BINDS" | jq -r '[.[]|select(.key=="TAB" and .modmask==64)|.description]|first')" "BaneySpaces: overview"
# Run the command a key is bound to, as the key would.
press() { # press "<description>": runs the command the include binds to that key's description
  local cmd; cmd="$(grep -F "description = \"$1\"" "$REPO/platforms/linux/omarchy/baneyspaces.lua" | sed -n 's/.*exec_cmd("\([^"]*\)").*/\1/p')"
  [ -n "$cmd" ] && sh -c "$cmd" >/dev/null 2>&1
}
press "BaneySpaces: workspace 3"; sleep 0.2
eq "pressing Super+3 goes to workspace 3" "$(mon_ws $M1)" "3"
press "BaneySpaces: workspace 1"; sleep 0.2

echo "== switching 1-9 on each monitor, instantly"
LAT=()
for n in 1 2 3 4 5 6 7 8 9; do
  t0=$(date +%s%N); baneyspaces switch $n >/dev/null; t1=$(date +%s%N); LAT+=($(( (t1-t0)/1000000 )))
  eq "monitor 1 shows workspace $n" "$(mon_ws $M1)" "$n"
done
eq "monitor 2 untouched by monitor 1 switches" "$(mon_ws $M2)" "$(mon_ws $M2)"
baneyspaces focus-monitor $M2 >/dev/null; sleep 0.2
eq "focus-monitor goes to monitor 2" "$(H monitors | jq -r '.[]|select(.focused)|.name')" "$M2"
for n in 1 2 3 4 5 6 7 8 9; do
  t0=$(date +%s%N); baneyspaces switch $n >/dev/null; t1=$(date +%s%N); LAT+=($(( (t1-t0)/1000000 )))
  eq "monitor 2 shows workspace 10$n -> $((100+n))" "$(mon_ws $M2)" "$((100+n))"
done
eq "monitor 1 stayed on 9 while monitor 2 switched" "$(mon_ws $M1)" "9"
SORTED=($(printf '%s\n' "${LAT[@]}" | sort -n)); echo "  switch round trip (CLI spawn + daemon + Hyprland), ms: median ${SORTED[$(( ${#SORTED[@]}/2 ))]}, max ${SORTED[-1]}"
baneyspaces focus-monitor $M1 >/dev/null; baneyspaces switch 1 >/dev/null; baneyspaces switch 1 --monitor $M2 >/dev/null; sleep 0.2
eq "back on workspace 1 of monitor 1" "$(mon_ws $M1)" "1"
eq "switch --monitor changes the other monitor without focusing it" "$(mon_ws $M2)-$(H monitors | jq -r '.[]|select(.focused)|.name')" "101-$M1"
eq "workspace 10 is refused" "$(baneyspaces switch 10 | jq -r .error.code)" "invalid_args"
eq "workspace 0 is refused" "$(baneyspaces switch 0 | jq -r .error.code)" "invalid_args"

echo "== windows land where you are, move, empty means empty"
user_window() { # user_window <title> -> address, opened the way a user's launcher does
  local before; before="$(H clients | jq -r '.[].address' | sort)"
  hyprctl dispatch "hl.dsp.exec_cmd(\"foot -T $1 sleep 600\")" >/dev/null
  for _ in $(seq 1 60); do
    local a; a="$(H clients | jq -r ".[]|select(.title==\"$1\")|.address")"
    [ -n "$a" ] && { echo "$a"; return; }; sleep 0.1
  done
}
client_ws() { H clients | jq -r ".[]|select(.address==\"$1\")|.workspace.name"; }
baneyspaces switch 4 >/dev/null; sleep 0.2
W1="$(user_window w1)"; sleep 0.3
eq "new window lands on workspace 4 (where you are)" "$(client_ws $W1)" "4"
eq "the model has it on $M1:4" "$(baneyspaces state | jq -r ".data.workspaces[\"$M1:4\"]|join(\",\")")" "$W1"
eq "it is in front" "$(active)" "$W1"
baneyspaces switch 2 >/dev/null; sleep 0.2
W2="$(user_window w2)"; sleep 0.3
eq "next window lands on workspace 2" "$(client_ws $W2)" "2"
baneyspaces focus-monitor $M2 >/dev/null; baneyspaces switch 3 >/dev/null; sleep 0.2
W3="$(user_window w3)"; sleep 0.3
eq "a window opened while on monitor 2 lands on 103" "$(client_ws $W3)" "103"
baneyspaces focus-monitor $M1 >/dev/null; sleep 0.2
eq "monitor 1 shows 2 again" "$(mon_ws $M1)" "2"
baneyspaces switch 7 >/dev/null; sleep 0.2
eq "an empty workspace has nothing in front" "$(active)" "none"
eq "the model agrees" "$(baneyspaces state | jq -r '.data.active')" "null"
baneyspaces switch 4 >/dev/null; sleep 0.2
eq "switching back puts w1 in front" "$(active)" "$W1"
baneyspaces move 6 >/dev/null; sleep 0.3
eq "move sends the front window to 6" "$(client_ws $W1)" "6"
eq "and follows it" "$(mon_ws $M1)" "6"
eq "w1 is in front" "$(active)" "$W1"
baneyspaces switch 2 >/dev/null; sleep 0.2
baneyspaces move 8 --stay --window "$W1" >/dev/null; sleep 0.3
eq "move --stay sends it to 8" "$(client_ws $W1)" "8"
eq "move --stay leaves you on 2" "$(mon_ws $M1)" "2"
eq "move --stay leaves w2 in front" "$(active)" "$W2"
press "BaneySpaces: send window to workspace 5"; sleep 0.3
eq "Super+Shift+5 moves the front window to 5 and follows" "$(client_ws $W2)-$(mon_ws $M1)" "5-5"
hyprctl dispatch "hl.dsp.window.move({ workspace = \"1\", follow = false, window = \"address:$W1\" })" >/dev/null; sleep 0.3
eq "a window moved by Hyprland itself is mirrored, not undone" "$(baneyspaces state | jq -r ".data.windows[\"$W1\"].home")" "$M1:1"
eq "a window moved by Hyprland itself stays where it went" "$(client_ws $W1)" "1"
eq "a window outside the scheme is left alone (workspace 10)" "$(hyprctl dispatch "hl.dsp.window.move({ workspace = \"10\", follow = false, window = \"address:$W1\" })" >/dev/null; sleep 0.3; baneyspaces state | jq -r ".data.windows|has(\"$W1\")")" "false"
hyprctl dispatch "hl.dsp.window.move({ workspace = \"1\", follow = false, window = \"address:$W1\" })" >/dev/null; sleep 0.3

echo "== focus following: only a user's activation follows"
baneyspaces switch 1 >/dev/null; sleep 0.2
hyprctl dispatch "hl.dsp.focus({ window = \"address:$W2\" })" >/dev/null; sleep 0.4
eq "a user's focus of a window on another workspace takes you there" "$(mon_ws $M1)" "5"
eq "w2 is in front" "$(active)" "$W2"

echo "== the agent workspace"
baneyspaces switch 5 >/dev/null; baneyspaces switch 2 >/dev/null; sleep 0.2
W4="$(active)"
USER_ACTIVE="$(active)"; USER_WS1="$(mon_ws $M1)"; USER_WS2="$(mon_ws $M2)"; USER_CURSOR="$(cursor)"
same_screen() { # same_screen "<desc>"
  eq "$1: your front window" "$(active)" "$USER_ACTIVE"
  eq "$1: monitor 1 workspace" "$(mon_ws $M1)" "$USER_WS1"
  eq "$1: monitor 2 workspace" "$(mon_ws $M2)" "$USER_WS2"
  [ "${2:-}" = nopointer ] || eq "$1: the pointer" "$(cursor)" "$USER_CURSOR"
  eq "$1: the agent workspace is not showing" "$(special)" "0"
}
OPEN="$(baneyspaces agent open foot -T agentfoot sleep 600)"
echo "$OPEN" | jq -c '{ok,error}'
AW="$(echo "$OPEN" | jq -r '.data.window // empty')"; APID="$(echo "$OPEN" | jq -r '.data.pid // empty')"
check "agent open returns a window" test -n "$AW"
eq "the agent's window is on special:agent" "$(client_ws ${AW:-x})" "special:agent"
same_screen "after agent open"
eq "agent status lists it as drivable" "$(baneyspaces agent status | jq -r ".data.windows[0].drivable")" "true"
eq "your windows are not listed in agent status" "$(baneyspaces agent status | jq -r '.data.windows|length')" "1"
eq "the process is registered by pid" "$(baneyspaces state | jq -r ".data.agent.pids|index($APID) != null")" "true"
# An activation of the agent window, by anything, is undone.
hyprctl dispatch "hl.dsp.focus({ window = \"address:${AW}\" })" >/dev/null; sleep 0.6
# (Hyprland itself warps the pointer to a window it is told to focus; that is the forced focus,
# not an agent action, so the pointer is excluded here and re-read after.)
same_screen "after something focused the agent window" nopointer
USER_CURSOR="$(cursor)"
check "the guard counted it" sh -c "[ \"\$(baneyspaces state | jq .data.guard.refused)\" -ge 1 ]"
# An app that hands the request to a running instance has no window of its own process.
eq "an app that opens no window of its own is refused as single_instance" "$(baneyspaces agent open /usr/bin/true | jq -r .error.code)" "single_instance"
same_screen "after the refused open"
eq "an unknown program is not_found" "$(baneyspaces agent open /nonexistent/x | jq -r .error.code)" "not_found"
# Showing and hiding is yours.
baneyspaces agent-workspace show >/dev/null; sleep 0.4
eq "agent-workspace show opens it" "$(special)" "1"
baneyspaces agent-workspace hide >/dev/null; sleep 0.4
same_screen "after show then hide"
press "BaneySpaces: show or hide the agent workspace"; sleep 0.4
eq "the agent key shows it" "$(special)" "1"
press "BaneySpaces: show or hide the agent workspace"; sleep 0.4
same_screen "after the key twice"
# A user window parked there is guarded but not drivable.
baneyspaces agent move "$W3" >/dev/null; sleep 0.3
eq "agent move parks your window" "$(client_ws $W3)" "special:agent"
eq "parked windows are not drivable" "$(baneyspaces agent status | jq -r ".data.windows[]|select(.window==\"$W3\")|.drivable")" "false"
same_screen "after parking a window"
baneyspaces agent bring "$W3" >/dev/null; sleep 0.3
eq "agent bring returns it to the workspace you are on" "$(client_ws $W3)" "2"
eq "an agent window cannot be moved to your workspaces" "$(baneyspaces move 3 --window "$AW" | jq -r .error.code)" "agent_window"
eq "keys are not supported in part 1" "$(baneyspaces agent press @sa:e1 Return | jq -r .error.code)" "not_supported"

if [ -x "$BANEYSPACES_ENGINE" ] && [ -f "$HERE/hands.sh" ]; then
  . "$HERE/hands.sh"
fi

echo "== monitors come and go"
baneyspaces focus-monitor $M2 >/dev/null; baneyspaces switch 5 >/dev/null; sleep 0.2
W5="$(user_window w5)"; sleep 0.3
eq "a window opened on monitor 2 workspace 5 is on 105" "$(client_ws $W5)" "105"
hyprctl output remove $M2 >/dev/null; sleep 0.8
eq "unplugging monitor 2 leaves one monitor" "$(baneyspaces state | jq -r '.data.monitors|keys|join(",")')" "$M1"
eq "its window moved to monitor 1, same workspace number" "$(client_ws $W5)" "5"
eq "you are on monitor 1" "$(H monitors | jq -r '.[]|select(.focused)|.name')" "$M1"
hyprctl output create headless >/dev/null; sleep 0.8
NEW="$(H monitors | jq -r '[.[]|select(.name!="'$M1'")|.name]|first')"
eq "a monitor plugged in takes the free slot 1" "$(baneyspaces state | jq -r ".data.monitors[\"$NEW\"].slot")" "1"
check "its workspaces are pinned to it (switch lands on 10x)" sh -c "baneyspaces switch 4 --monitor $NEW >/dev/null; sleep 0.3; [ \"\$(hyprctl -j monitors | jq -r '.[]|select(.name==\"$NEW\")|.activeWorkspace.id')\" = 104 ]"

echo "== state.json"
check "state.json exists and is the model" sh -c "jq -e '.version==1 and .platform==\"linux\" and (.monitors|length)>=1' '$XDG_STATE_HOME/baneyspaces/state.json'"
check "the daemon is still alive" kill -0 $DPID
check "the daemon logged no panic" sh -c "! grep -q panicked '$TMP/daemon.log'"

echo
echo "passed $PASS, failed $FAIL"
if [ "$FAIL" -eq 0 ]; then echo "PASS: nested.sh ($PASS checks)"; exit 0; else echo "FAIL: nested.sh ($FAIL of $((PASS+FAIL)) checks)"; [ -z "${KEEP:-}" ] && { echo "--- daemon log tail"; tail -15 "$TMP/daemon.log"; }; exit 1; fi
