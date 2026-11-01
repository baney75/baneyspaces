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
vmx 'C:\bs\baneyspaces\target\release\baneyspaces.exe stop | Out-Null; Start-Sleep 1; taskkill /F /IM baneyspaces.exe 2>&1 | Out-Null; Get-Process notepad,CalculatorApp,Calculator -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 1; Remove-Item -Recurse -Force $env:LOCALAPPDATA\BaneySpaces -ErrorAction SilentlyContinue' >/dev/null
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

say "== 6. agent: open notepad, snapshot, type. It must never show on workspace 1"
(vmi 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\watch.ps1 -Seconds 14' > "$OUT/watch-open.txt" 2>&1) &
WATCH=$!
sleep 5
O=$(cli agent open notepad); echo "$O" | grep -q '"ok":true' && ok "agent open notepad" || bad "agent open: $O"
AW=$(sed -n 's/.*"window":"\(w-[0-9]*\)".*/\1/p' <<<"$O")
wait $WATCH
grep -q 'NEW none' "$OUT/watch-open.txt" && bad "the watcher never saw the agent window" || { grep -q 'visible_polls=0' "$OUT/watch-open.txt" && ok "the agent window was never visible in $(sed -n 's/polls=\([0-9]*\).*/\1/p' "$OUT/watch-open.txt") polls while it opened" || bad "the agent window was visible: $(cat "$OUT/watch-open.txt")"; }
S=$(seen_now); shot 07-agent-open >/dev/null
[[ "$(count "$S" Notepad)" == "$(grep -o 'Notepad' <<<"$NOTEPADS" | wc -l)" || true ]]
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
RB=$(readback); echo "$RB" >> "$LOG"; shot 09-agent-typed >/dev/null
grep -q "w-${AW#w-} .*alpha=0.*SEEN=False" <<<"$RB" || grep "$AW " <<<"$RB" | grep -q 'SEEN=False' && ok "the agent's window is still invisible after typing" || bad "agent window is visible"
grep -c "title='Untitled - Notepad'" <<<"$RB" | grep -q . && ok "your Notepad windows still say 'Untitled' (not modified)" 
U=$(vmi '$env:AGENT_DESKTOP_HOME="C:\bs\harness-state"; $e="C:\bs\baneyspaces\platforms\windows\engine\agent-desktop.exe"; foreach($w in "'"${NOTEPADS// /\",\"}"'"){ if($w){ $s=(& $e snapshot --window-id $w | ConvertFrom-Json); $v=(& $e get "@$($s.data.snapshot_id):e1" --property value | ConvertFrom-Json).data.value; "[$w] value=[$v]" } }')
echo "$U" >> "$LOG"; grep -q 'agent' <<<"$U" && bad "your Notepad has the agent's text: $U" || ok "your Notepad windows hold none of the agent's text"
cli agent log --since 120 | grep -q '"verb":"type"' && ok "the action log recorded the type (no content)" || bad "no log record"

say "== 7. deny by default, settings, and agent peers"
O=$(cli agent open explorer); grep -q '"code":"needs_sandbox"' <<<"$O" && ok "agent open explorer is refused (needs_sandbox) before it starts" || bad "explorer not refused: ${O:0:200}"
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
[[ "$(grep -c not_in_scope <<<"$PEER")" == 2 ]] && ok "set and switch from an agent's own process are refused (not_in_scope)" || bad "agent peer not refused: $PEER"
cli get dock.enabled | grep -q true && ok "the agent's refused set changed nothing" || bad "dock.enabled changed"
cli stop >/dev/null; sleep 2; daemon_start

say; say "RESULT: $([[ $fail == 0 ]] && echo PASS || echo FAIL)  passed=$pass failed=$fail   (log: $LOG, shots: $OUT)"
[[ $fail == 0 ]]
