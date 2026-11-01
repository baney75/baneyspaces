# Sourced by nested.sh. Simulators, emulators and VMs (spec/devices.md): a toolbar travels with its
# window and is not counted, a toolbar dragged off alone comes back, the emulator floats, and the
# workspace keys ignore a VM's request to take the keyboard.
echo "== devices and VMs (R-D2 to R-D5, R-D7, R-D10)"
APP="$HERE/gtk_test_app.py"
# Hyprland's `binds` JSON does not show the flag, so load the include again with hl.bind wrapped and
# read dont_inhibit off every Keybind it returns.
DCOUNT="$TMP/dont-inhibit.txt"; rm -f "$DCOUNT"
hyprctl eval "local real, n, total = hl.bind, 0, 0; hl.bind = function(k, d, o) local r = real(k, d, o); total = total + 1; if r.dont_inhibit then n = n + 1 end; return r end; dofile('$REPO/platforms/linux/omarchy/baneyspaces.lua'); hl.bind = real; local f = io.open('$DCOUNT', 'w'); f:write(n, '/', total); f:close()" >/dev/null
wait_for 5 test -s "$DCOUNT"
eq "every BaneySpaces bind ignores a keyboard-shortcuts-inhibit request (dont_inhibit)" "$(cat "$DCOUNT" 2>/dev/null)" "29/29"
empty_ws() { # an empty workspace nobody shows, not the ones in "$@"
  for n in 9 8 7 6 5 4 3; do
    case " $* " in *" $n "*) continue;; esac
    baneyspaces state | jq -e "(.data.workspaces[\"$n\"]|length // 0) == 0" >/dev/null && H monitors | jq -e "[.[].activeWorkspace.id]|index($n) == null" >/dev/null && { echo $n; return; }
  done
}
DW1="$(empty_ws)"; DW2="$(empty_ws $DW1)"
baneyspaces switch $DW1 >/dev/null; sleep 0.3
DOUT="$TMP/device-app.out"; rm -f "$DOUT"
TEST_APP_ID=Emulator TEST_APP_TITLE="Android Emulator - Test:5554" TEST_APP_SECOND_TITLE="Extended Controls - Test:5554" \
  /usr/bin/python3 "$APP" >"$DOUT" 2>&1 & DEVPID=$!; PIDS+=($DEVPID)
wait_for 15 grep -q ready "$DOUT"
sleep 0.5
DEVWIN="$(H clients | jq -r '[.[]|select(.class=="Emulator")]|sort_by(.address)')"
eq "(setup) the emulator opened two windows in one process" "$(echo "$DEVWIN" | jq 'length')" "2"
DMAIN="$(echo "$DEVWIN" | jq -r '.[]|select(.title|startswith("Android Emulator"))|.address')"
DCOMP="$(echo "$DEVWIN" | jq -r '.[]|select(.title|startswith("Extended Controls"))|.address')"
eq "the main window floats (R-D10)" "$(H clients | jq -r ".[]|select(.address==\"$DMAIN\")|.floating")" "true"
eq "both are on workspace $DW1" "$(H clients | jq -r "[.[]|select(.address==\"$DMAIN\" or .address==\"$DCOMP\")|.workspace.id]|unique|join(\",\")")" "$DW1"
eq "the model counts one window on the workspace, the main one (R-D3)" "$(baneyspaces state | jq -r '.data.workspaces["'"$DW1"'"]|length')" "1"
eq "and calls the other a companion" "$(baneyspaces state | jq -r ".data.windows[\"$DCOMP\"].role")" "companion"
echo "-- moving the window takes its toolbar along (R-D2)"
hyprctl dispatch "hl.dsp.focus({ window = \"address:$DMAIN\" })" >/dev/null; sleep 0.3
baneyspaces move $DW2 --stay >/dev/null; sleep 0.5
eq "both are on workspace $DW2" "$(H clients | jq -r "[.[]|select(.address==\"$DMAIN\" or .address==\"$DCOMP\")|.workspace.id]|unique|join(\",\")")" "$DW2"
echo "-- a toolbar dragged off alone comes back (R-D5)"
hyprctl dispatch "hl.dsp.window.move({ workspace = \"$DW1\", follow = false, window = \"address:$DCOMP\" })" >/dev/null
wait_for 5 sh -c "[ \"\$(hyprctl -j clients | jq -r '.[]|select(.address==\"$DCOMP\")|.workspace.id')\" = \"$DW2\" ]"
eq "the toolbar is back with its window" "$(H clients | jq -r "[.[]|select(.address==\"$DMAIN\" or .address==\"$DCOMP\")|.workspace.id]|unique|join(\",\")")" "$DW2"
kill "$DEVPID" 2>/dev/null
baneyspaces switch 1 >/dev/null; sleep 0.2

echo "-- a main window that opens untitled is not a toolbar once its title arrives (R-D1)"
LOUT="$TMP/device-late.out"; rm -f "$LOUT"
baneyspaces switch $DW1 >/dev/null; sleep 0.3
TEST_APP_ID=Emulator TEST_APP_LATE_TITLE="Android Emulator - Late:5556" /usr/bin/python3 "$APP" >"$LOUT" 2>&1 & LPID=$!; PIDS+=($LPID)
wait_for 15 grep -q ready "$LOUT"; sleep 1.2
LADDR="$(H clients | jq -r '[.[]|select(.class=="Emulator" and (.title|startswith("Android Emulator - Late")))]|first|.address // empty')"
check "(setup) the untitled window got its title" test -n "$LADDR"
eq "it is a main window now" "$(baneyspaces state | jq -r ".data.windows[\"$LADDR\"].role")" "main"
eq "and the workspace counts it" "$(baneyspaces state | jq -r '.data.workspaces["'"$DW1"'"]|map(select(.=="'"$LADDR"'"))|length')" "1"
kill "$LPID" 2>/dev/null

echo "-- QEMU: a plain one is an ordinary window, the emulator's is found by -avd and floats (R-D1, R-D10)"
# Real QEMU needs a display backend this machine's build lacks, so a process named qemu-system-x86_64
# (a copy of the interpreter under that name) opens the windows. The daemon reads the name and command line.
mkdir -p "$TMP/bin"; ln -sf /usr/bin/python3 "$TMP/bin/qemu-system-x86_64"
baneyspaces switch $DW1 >/dev/null; sleep 0.3
QOUT="$TMP/qemu-plain.out"; rm -f "$QOUT"
TEST_APP_ID=qemu-system-x86_64 TEST_APP_TITLE="QEMU" "$TMP/bin/qemu-system-x86_64" "$APP" -display gtk -m 512 >"$QOUT" 2>&1 & QPID=$!; PIDS+=($QPID)
wait_for 15 grep -q ready "$QOUT"; sleep 0.5
QADDR="$(H clients | jq -r "[.[]|select(.pid == $QPID)]|first|.address // empty")"
check "(setup) the plain QEMU stand-in opened a window" test -n "$QADDR"
eq "plain QEMU is a main window" "$(baneyspaces state | jq -r ".data.windows[\"$QADDR\"].role")" "main"
eq "the workspace counts it" "$(baneyspaces state | jq -r '.data.workspaces["'"$DW1"'"]|map(select(.=="'"$QADDR"'"))|length')" "1"
eq "it does not float" "$(H clients | jq -r ".[]|select(.address==\"$QADDR\")|.floating")" "false"
kill "$QPID" 2>/dev/null
EOUT="$TMP/qemu-avd.out"; rm -f "$EOUT"
TEST_APP_ID=qemu-system-x86_64 TEST_APP_TITLE="Android Emulator - Q:5558" "$TMP/bin/qemu-system-x86_64" "$APP" -avd Pixel_9 >"$EOUT" 2>&1 & EPID=$!; PIDS+=($EPID)
wait_for 15 grep -q ready "$EOUT"; sleep 0.8
EADDR="$(H clients | jq -r "[.[]|select(.pid == $EPID)]|first|.address // empty")"
check "(setup) the emulator stand-in opened a window" test -n "$EADDR"
eq "the emulator is a main window" "$(baneyspaces state | jq -r ".data.windows[\"$EADDR\"].role")" "main"
eq "the daemon floated it although no window rule knew its class" "$(H clients | jq -r ".[]|select(.address==\"$EADDR\")|.floating")" "true"
kill "$EPID" 2>/dev/null
baneyspaces switch 1 >/dev/null; sleep 0.2
