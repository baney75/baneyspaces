#!/usr/bin/env bash
# The live test of BaneySpaces for Windows, driven from Parish1 against the win11-bs VM.
# Needs: the VM up with the toolchain provisioned (platforms/windows/vm/provision-toolchain.ps1) and
# the engine built (platforms/windows/scripts/build-engine.ps1), the tree synced to C:\bs\baneyspaces
# and built in release. Prints PASS or FAIL with counts; screenshots go to $OUT.
# Usage: live.sh [outdir]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/live-lib.sh"
OUT="${1:-$HERE/evidence}"; SHOTS="$OUT"; mkdir -p "$OUT"
LOG="$OUT/live.log"; : > "$LOG"
TESTAPP='C:\bs\baneyspaces\target\release\bs-testapp.exe'
pass=0; fail=0
say()  { echo "$*" | tee -a "$LOG"; }
ok()   { pass=$((pass+1)); say "  ok:   $*"; }
bad()  { fail=$((fail+1)); say "  FAIL: $*"; }
seen_now() { readback | tee -a "$LOG" | grep '^SEEN:' | sed 's/^SEEN: //'; }
has()  { [[ "$1" == *"$2"* ]] && ok "$3" || bad "$3 (saw: $1)"; }
lacks(){ [[ "$1" != *"$2"* ]] && ok "$3" || bad "$3 (saw: $1)"; }
count(){ grep -o "$2" <<<"$1" | wc -l; }
cli()  { local o; o=$(bsx "$@"); echo "\$ baneyspaces $*  ->  ${o:0:240}" >> "$LOG"; echo "$o"; }
daemon_start() { scp "${SSH_OPTS[@]}" -q "$HERE/daemon-task.ps1" baney@192.168.122.50:C:/daemon-task.ps1; vmx 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\daemon-task.ps1 start' >> "$LOG"; }

say "== 0. clean start"
scp "${SSH_OPTS[@]}" -q "$HERE/readback.ps1" "$HERE/watch.ps1" baney@192.168.122.50:C:/
vmx 'C:\bs\baneyspaces\target\release\baneyspaces.exe stop | Out-Null; Start-Sleep 1; taskkill /F /IM baneyspaces.exe 2>&1 | Out-Null; Get-Process notepad,CalculatorApp,Calculator -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 1; Remove-Item -Recurse -Force $env:LOCALAPPDATA\BaneySpaces -ErrorAction SilentlyContinue; $n="$env:LOCALAPPDATA\Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState"; Remove-Item -Recurse -Force "$n\TabState","$n\WindowState" -ErrorAction SilentlyContinue; Remove-Item -Recurse -Force C:\bs\harness-state -ErrorAction SilentlyContinue' >/dev/null
sleep 2
daemon_start
cli doctor | grep -q '"healthy":true' && ok "doctor is healthy with the daemon up" || bad "doctor"

say "== 1. open Notepad, Explorer, Calculator"
vmu 'Start-Process notepad; Start-Sleep 3; Start-Process explorer.exe -ArgumentList "C:\Windows"; Start-Sleep 3; Start-Process calc; Start-Sleep 4' >/dev/null
S=$(seen_now); shot 01-opened >/dev/null
has "$S" "Notepad" "Notepad shows"; has "$S" "File Explorer" "Explorer shows"; has "$S" "Calculator" "Calculator shows"
RB=$(readback)
NOTEPADS=$(grep 'class=Notepad ' <<<"$RB" | grep 'SEEN=True' | sed 's/ .*//' | tr '\n' ' ')
CALC=$(grep 'title=.Calculator.' <<<"$RB" | sed 's/ .*//' | head -1)
say "notepad windows: $NOTEPADS  calculator: $CALC"

say "== 2. move Notepad to workspace 2 and Calculator to 3 (--stay)"
for w in $NOTEPADS; do cli move 2 --stay --window "$w" >/dev/null; done
cli move 3 --stay --window "$CALC" >/dev/null; sleep 1
S=$(seen_now); shot 02-moved >/dev/null
lacks "$S" "Notepad" "Notepad is hidden on workspace 1"; lacks "$S" "Calculator" "Calculator is hidden on workspace 1"; has "$S" "File Explorer" "Explorer stays on workspace 1"

say "== 3. switch 1 -> 2 -> 3 -> 1 with the CLI"
cli switch 2 >/dev/null; sleep 1; S=$(seen_now); shot 03-switch-2 >/dev/null
has "$S" "Notepad" "workspace 2 shows Notepad"; lacks "$S" "File Explorer" "workspace 2 hides Explorer"; lacks "$S" "Calculator" "workspace 2 hides Calculator"
cli switch 3 >/dev/null; sleep 1; S=$(seen_now); shot 03-switch-3 >/dev/null
has "$S" "Calculator" "workspace 3 shows Calculator"; lacks "$S" "Notepad" "workspace 3 hides Notepad"
cli switch 1 >/dev/null; sleep 1; S=$(seen_now); shot 03-switch-1 >/dev/null
has "$S" "File Explorer" "workspace 1 shows Explorer"; lacks "$S" "Notepad" "workspace 1 hides Notepad"; lacks "$S" "Calculator" "workspace 1 hides Calculator"

say "== 4. the real Win+2 key (virsh send-key), then Win+1"
virsh -c qemu:///system send-key win11-bs KEY_LEFTMETA KEY_2 >/dev/null; sleep 2; S=$(seen_now); shot 04-win-2 >/dev/null
has "$S" "Notepad" "Win+2 shows workspace 2 (Notepad)"; lacks "$S" "File Explorer" "Win+2 hid Explorer"
virsh -c qemu:///system send-key win11-bs KEY_LEFTMETA KEY_3 >/dev/null; sleep 2; S=$(seen_now); shot 04-win-3 >/dev/null
has "$S" "Calculator" "Win+3 shows workspace 3 (Calculator)"
virsh -c qemu:///system send-key win11-bs KEY_LEFTMETA KEY_1 >/dev/null; sleep 2; S=$(seen_now); shot 04-win-1 >/dev/null
has "$S" "File Explorer" "Win+1 is back on workspace 1"; lacks "$S" "Calculator" "Win+1 hid Calculator"
H2=$(cli state | grep -o '"home":"2"' | wc -l); vmu 'Add-Type -Name F -Namespace W -MemberDefinition "[System.Runtime.InteropServices.DllImport(\"user32.dll\")] public static extern bool SetForegroundWindow(System.IntPtr h);"; $e=(Get-Process explorer | ? { $_.MainWindowHandle -ne 0 } | select -First 1); if ($e) { [W.F]::SetForegroundWindow($e.MainWindowHandle) | Out-Null }' >/dev/null; sleep 1
virsh -c qemu:///system send-key win11-bs KEY_LEFTMETA KEY_LEFTSHIFT KEY_2 >/dev/null; sleep 2
H2b=$(cli state | grep -o '"home":"2"' | wc -l)
[[ "$H2b" -gt "$H2" ]] && ok "Win+Shift+2 sent the front window to workspace 2 ($H2 -> $H2b windows there)" || bad "Win+Shift+2 did not move a window ($H2 -> $H2b)"
cli switch 1 >/dev/null; sleep 1

say "== 5. taskkill /F the daemon while windows are hidden, start it again"
S=$(seen_now); lacks "$S" "Calculator" "before the kill Calculator is hidden"
vmx 'taskkill /F /IM baneyspaces.exe | Out-Null; Start-Sleep 1' >/dev/null
RB=$(readback); echo "$RB" >> "$LOG"; shot 05-killed >/dev/null
grep -q 'cloaked=2' <<<"$RB" && ok "after the kill the windows are still cloaked (nothing ran to put them back)" || bad "nothing cloaked after the kill"
daemon_start
sleep 2
S=$(seen_now); shot 06-restarted >/dev/null
has "$S" "Notepad" "restart: Notepad is back"; has "$S" "Calculator" "restart: Calculator is back"; has "$S" "File Explorer" "restart: Explorer is there"
RB=$(readback); grep -q 'cloaked=2' <<<"$RB" && bad "something is still cloaked after restart" || ok "nothing is left cloaked after restart"
cli switch 1 >/dev/null

say "== 5b. robustness: things that go wrong while windows are hidden"
BSP='C:\bs\baneyspaces\target\release\baneyspaces.exe'
vmu 'Start-Process C:\bs\baneyspaces\target\release\bs-testapp.exe; Start-Sleep 3' >/dev/null
UT=$(readbackall | grep 'class=BaneySpacesTestApp' | head -1 | sed 's/^w-\([0-9]*\) .*/\1/')
say "a window of yours, not started by the daemon: w-$UT"
cli switch 1 >/dev/null
cli move 2 --stay --window "w-$UT" >/dev/null; sleep 1
[[ "$(helper cloaked "$UT" | tr -d '\r\n ')" == 2 ]] && ok "it is cloaked on workspace 2" || bad "not cloaked"
# A hidden window that stops looking like an app window is still yours (title emptied, as terminals and browsers do).
helper settitle "$UT" "" >/dev/null; sleep 2
cli switch 2 >/dev/null; sleep 1
[[ "$(helper cloaked "$UT" | tr -d '\r\n ')" == 0 ]] && ok "its title became empty while it was hidden: switching to 2 still shows it" || bad "a hidden window with no title stayed cloaked"
cli switch 1 >/dev/null; sleep 1
# Something else drops the cloak (another tool, a virtual-desktop switch): the next poll hides it again.
helper uncloak "$UT" >/dev/null; sleep 2
[[ "$(helper cloaked "$UT" | tr -d '\r\n ')" == 2 ]] && ok "an outside uncloak was undone within two polls" || bad "an outside uncloak stuck"
# One daemon only: a second one must not put the first one's windows back.
O=$(vmx "& '$BSP' daemon --log C:\bs\second.log; \"exit=\$LASTEXITCODE\"")
grep -q 'exit=1' <<<"$O" && ok "a second daemon exits (1) without starting" || bad "second daemon: $O"
[[ "$(helper cloaked "$UT" | tr -d '\r\n ')" == 2 ]] && ok "and the first daemon's hidden window is still hidden" || bad "the second daemon uncloaked a window"
# A request that is JSON but not an object must not hurt the daemon.
scp "${SSH_OPTS[@]}" -q "$HERE/rawpipe.ps1" baney@192.168.122.50:C:/bs/rawpipe.ps1
PIPE=$(vmx 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\bs\rawpipe.ps1')
echo "$PIPE" >> "$LOG"
[[ "$(grep -c invalid_args <<<"$PIPE")" == 3 ]] && grep -q pong <<<"$PIPE" && ok "\"x\", [1] and 5 are refused (invalid_args) and a ping after them is answered" || bad "pipe: $PIPE"
[[ "$(helper cloaked "$UT" | tr -d '\r\n ')" == 2 ]] && ok "the daemon kept the window hidden through it" || bad "window state changed"
# The hidden-window record cannot be saved: nothing is hidden, the switch is refused, and it works again once it can.
vmx 'icacls "$env:LOCALAPPDATA\BaneySpaces" /deny "baney:(OI)(CI)(WD,AD)" | Out-Null' >/dev/null
O=$(cli switch 2); grep -q 'nothing was hidden' <<<"$O" && grep -q '"retry":"safe"' <<<"$O" && ok "with state.json unwritable, switch 2 is refused (nothing was hidden, retry safe)" || bad "expected a save error: ${O:0:300}"
S=$(seen_now); has "$S" "File Explorer" "and your windows are still showing"
vmx 'icacls "$env:LOCALAPPDATA\BaneySpaces" /remove:d "baney" | Out-Null' >/dev/null
cli switch 2 | grep -q '"ok":true' && ok "once the record can be saved, the same switch works" || bad "switch 2 after the fix"
# Sign-out: the daemon's hidden window hears WM_QUERYENDSESSION and puts everything back before apps are asked to save.
S=$(seen_now); lacks "$S" "File Explorer" "before: workspace 1 is hidden"
helper endsession query >/dev/null; sleep 2
S=$(seen_now); has "$S" "File Explorer" "WM_QUERYENDSESSION put the windows back"
helper endsession cancel >/dev/null; sleep 3
S=$(seen_now); lacks "$S" "File Explorer" "a cancelled sign-out: the next poll hides workspace 1 again"
cli switch 1 >/dev/null; sleep 1
# explorer.exe restarts while windows are hidden.
cli move 2 --stay --window "w-$UT" >/dev/null; sleep 1
vmx 'Stop-Process -Name explorer -Force; Start-Sleep 9' >/dev/null
[[ "$(helper cloaked "$UT" | tr -d '\r\n ')" == 2 ]] && ok "explorer.exe restarted: the hidden window is still hidden" || bad "lost the cloak across the restart"
cli switch 2 >/dev/null; sleep 2
[[ "$(helper cloaked "$UT" | tr -d '\r\n ')" == 0 ]] && ok "and it shows again when its workspace is shown" || bad "could not show it after the restart"
cli switch 1 >/dev/null
vmx 'Get-Process bs-testapp -ErrorAction SilentlyContinue | Stop-Process -Force' >/dev/null

say "== 6. production refuses every agent launch (no Windows sandbox yet)"
for app in notepad explorer "$TESTAPP"; do
  O=$(cli agent open "$app"); grep -q '"code":"needs_sandbox"' <<<"$O" && ok "agent open $(basename "$app") is refused (needs_sandbox) before anything starts" || bad "expected needs_sandbox for $app: ${O:0:200}"
done
sleep 1; S=$(seen_now); lacks "$S" "test app" "no test window appeared"
O=$(cli agent run -- cmd); grep -q '"code":"needs_sandbox"' <<<"$O" && ok "agent run is refused too" || bad "agent run: ${O:0:200}"

say "== 6b. the agent flow with the bundled test app (a test daemon, BANEYSPACES_TEST_OPS), your Notepad open at normal level"
cli stop >/dev/null; sleep 2
vmx 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\daemon-task.ps1 start-test' >> "$LOG"
cli switch 1 >/dev/null
(vmi 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\watch.ps1 -Seconds 14' > "$OUT/watch-open.txt" 2>&1) &
WATCH=$!
sleep 5
O=$(cli agent open "$TESTAPP"); echo "$O" | grep -q '"ok":true' && ok "agent open bs-testapp" || bad "agent open: $O"
AW=$(sed -n 's/.*"window":"\(w-[0-9]*\)".*/\1/p' <<<"$O")
wait $WATCH
grep -q 'NEW none' "$OUT/watch-open.txt" && bad "the watcher never saw the agent window" || { grep -q 'visible_polls=0' "$OUT/watch-open.txt" && ok "the agent window was never visible in $(sed -n 's/polls=\([0-9]*\).*/\1/p' "$OUT/watch-open.txt") polls while it opened" || bad "the agent window was visible: $(cat "$OUT/watch-open.txt")"; }
S=$(seen_now); shot 07-agent-open >/dev/null
SN=$(cli agent snapshot --window "$AW" -i); REF=$(python3 -c "
import sys,json
d=json.loads(sys.stdin.read()); 
def w(n):
    if n.get('role')=='textfield': return n['ref_id']
    for c in n.get('children',[]):
        r=w(c)
        if r: return r
print(w(d['data']['result']['tree']) or '')" <<<"$SN")
[[ -n "$REF" ]] && ok "agent snapshot found a text field ($REF)" || bad "agent snapshot: ${SN:0:300}"
echo "$SN" | grep -q '"screen_changed":false' && ok "snapshot changed nothing you can see" || bad "snapshot changed the screen"
S=$(seen_now); shot 08-agent-snapshot >/dev/null
T=$(cli agent type "'$REF'" "hello from the agent")
echo "$T" | grep -q '"verified":true' && ok "agent type landed and the engine read it back (verified)" || bad "agent type: ${T:0:300}"
echo "$T" | grep -q '"screen_changed":false' && ok "typing changed nothing you can see" || bad "typing changed the screen"
# A dialog the agent's app opens belongs on the agent workspace too, ghosted the moment it appears.
BTN=$(python3 -c "
import sys,json
d=json.loads(sys.stdin.read())
def w(n):
    if n.get('role')=='button' and n.get('name')=='Open dialog': return n['ref_id']
    for c in n.get('children',[]):
        r=w(c)
        if r: return r
print(w(d['data']['result']['tree']) or '')" <<<"$SN")
[[ -n "$BTN" ]] && ok "the snapshot has the test app's Open dialog button ($BTN)" || bad "no Open dialog button in the snapshot"
(vmi 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\watch.ps1 -Seconds 9 -All' > "$OUT/watch-dialog.txt" 2>&1) &
WATCH2=$!
sleep 5
C=$(cli agent click "'$BTN'"); echo "$C" | grep -q '"ok":true' && ok "agent click on Open dialog" || bad "click: ${C:0:300}"
wait $WATCH2
grep -q "Test dialog" "$OUT/watch-dialog.txt" && grep "Test dialog" "$OUT/watch-dialog.txt" | grep -q 'visible_polls=0' && ok "the dialog the app opened was never visible ($(sed -n 's/polls=\([0-9]*\).*/\1/p' "$OUT/watch-dialog.txt") polls)" || bad "the dialog was visible, or never seen: $(cat "$OUT/watch-dialog.txt")"
AS=$(cli agent status); [[ "$(grep -o '"window":"w-' <<<"$AS" | wc -l)" == 2 ]] && ok "the dialog is an agent window (agent status lists both)" || bad "agent status: ${AS:0:300}"
DW=$(python3 -c "
import sys,json
d=json.loads(sys.stdin.read())
for w in d['data']['windows']:
    if w['window']!='$AW': print(w['window'])" <<<"$AS")
DS=$(cli agent snapshot --window "$DW" -i)
OK=$(python3 -c "
import sys,json
d=json.loads(sys.stdin.read())
def w(n):
    if n.get('role')=='button' and n.get('name')=='OK': return n['ref_id']
    for c in n.get('children',[]):
        r=w(c)
        if r: return r
print(w(d['data']['result']['tree']) or '')" <<<"$DS")
[[ -n "$OK" ]] && cli agent click "'$OK'" | grep -q '"ok":true' && ok "the agent dismissed the dialog through its own window (OK)" || bad "could not click OK: ${DS:0:200}"
sleep 2; AS=$(cli agent status); [[ "$(grep -o '"window":"w-' <<<"$AS" | wc -l)" == 1 ]] && ok "the dialog is gone from the agent workspace" || bad "dialog still listed"
RB=$(readback); echo "$RB" >> "$LOG"; shot 09-agent-typed >/dev/null
grep "^$AW " <<<"$RB" | grep -q 'SEEN=False' && ok "the agent's window is still invisible after typing" || bad "agent window is visible"
[[ "$(grep 'class=Notepad ' <<<"$RB" | grep -c "title='\*")" == 0 ]] && ok "your Notepad windows still say 'Untitled' (not modified)" || bad "a Notepad title shows unsaved changes"
U=$(vmi '$env:AGENT_DESKTOP_HOME="C:\bs\harness-state"; $e="C:\bs\baneyspaces\platforms\windows\engine\agent-desktop.exe"; foreach($w in "'"${NOTEPADS// /\",\"}"'"){ if($w){ $s=(& $e snapshot --window-id $w | ConvertFrom-Json); $v=(& $e get "@$($s.data.snapshot_id):e1" --property value | ConvertFrom-Json).data.value; "[$w] value=[$v]" } }')
echo "$U" >> "$LOG"; grep -q 'agent' <<<"$U" && bad "your Notepad has the agent's text: $U" || ok "your Notepad windows hold none of the agent's text"
cli agent log --since 120 | grep -q '"verb":"type"' && ok "the action log recorded the type (no content)" || bad "no log record"

say "== 7. deny by default, settings, and agent peers"
cli get | grep -q '"dock.enabled":true' && ok "settings default: dock true, theme baneyspaces, palette auto" || bad "settings defaults"
cli set dock.enabled false | grep -q '"ok":true' && cli get dock.enabled | grep -q 'false' && ok "set/get round-trips dock.enabled" || bad "set dock.enabled"
cli set appearance.theme neon | grep -q invalid_args && ok "a bad theme is invalid_args" || bad "bad theme accepted"
cli set dock.enabled true >/dev/null
# An agent's own child process asking for a user op is refused. Only a test daemon (BANEYSPACES_TEST_OPS)
# may start a program that is not on the list: here cmd.exe, which runs baneyspaces from inside the agent's job.
cli stop >/dev/null; sleep 2
vmx 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\daemon-task.ps1 start-test' >> "$LOG"
BSX='C:\bs\baneyspaces\target\release\baneyspaces.exe'
vmx 'Remove-Item C:\bs\peer.txt -ErrorAction SilentlyContinue; Set-Content C:\bs\peer.cmd "@echo off`r`nC:\bs\baneyspaces\target\release\baneyspaces.exe set dock.enabled false > C:\bs\peer.txt 2>&1`r`nC:\bs\baneyspaces\target\release\baneyspaces.exe switch 2 >> C:\bs\peer.txt 2>&1"' >/dev/null
cli agent open cmd.exe /c 'C:\bs\peer.cmd' >/dev/null; sleep 2
PEER=$(vmx 'Get-Content C:\bs\peer.txt'); echo "$PEER" >> "$LOG"
[[ "$(grep -c not_in_scope <<<"$PEER")" == 1 ]] && grep -q '"dock.enabled":false' <<<"$PEER" && ok "from an agent's own process: switch is refused (not_in_scope), set dock.enabled is accepted" || bad "agent peer: $PEER"
cli get dock.enabled | grep -q false && ok "the agent's set took effect (agents may customize appearance)" || bad "dock.enabled did not change"
cli agent log --since 120 | grep -q '"verb":"set"' && ok "the set was logged with its caller (verb set, route settings:dock.enabled)" || bad "no log record for the agent's set"
cli set dock.enabled true >/dev/null
cli stop >/dev/null; sleep 2; daemon_start

say; say "RESULT: $([[ $fail == 0 ]] && echo PASS || echo FAIL)  passed=$pass failed=$fail   (log: $LOG, shots: $OUT)"
[[ $fail == 0 ]]
