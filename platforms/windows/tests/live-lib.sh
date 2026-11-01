#!/usr/bin/env bash
# Helpers for the live test in the Windows 11 VM (seat-a). Source, do not run.
VMDIR="${VMDIR:-/home/alex/Projects/_work/win11-vm}"
. "$VMDIR/lib.sh"
BS='C:\bs\baneyspaces\target\release\baneyspaces.exe'
vmx()  { "$VMDIR/exec" "$@" 2>&1 | sed 's/_x000D__x000A_//g; /^#< CLIXML/d'; }
vmi()  { "$VMDIR/exec" -i "$@" 2>&1 | sed 's/_x000D__x000A_//g; /^#< CLIXML/d'; }
bsx()  { vmx "& '$BS' $*"; }
# readback: the windows and what is seen, from the desktop session
readback() { scp "${SSH_OPTS[@]}" -q "$(dirname "${BASH_SOURCE[0]}")/readback.ps1" baney@192.168.122.50:C:/readback.ps1 2>/dev/null; vmi 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\readback.ps1'; }
shot() { "$VMDIR/shot" "$SHOTS/$1.png" >/dev/null && echo "shot: $SHOTS/$1.png"; }
# vmu: run PowerShell in the desktop session as the signed-in user at NORMAL integrity, like an app
# you start yourself. (exec -i runs elevated, and an elevated window in front hides keys from a
# normal-integrity keyboard hook: UIPI.) Output comes back through a file.
vmu() {
  printf '%s\n' "$1" > /tmp/bsw-work/u.ps1
  scp "${SSH_OPTS[@]}" -q /tmp/bsw-work/u.ps1 baney@192.168.122.50:C:/bs/u.ps1
  vmx 'Unregister-ScheduledTask -TaskName bs-user -Confirm:$false -ErrorAction SilentlyContinue; Remove-Item C:\bs\u.out -ErrorAction SilentlyContinue
$a = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"& C:\bs\u.ps1 *> C:\bs\u.out`""
$p = New-ScheduledTaskPrincipal -UserId baney -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName bs-user -Action $a -Principal $p -Force | Out-Null
Start-ScheduledTask -TaskName bs-user
for ($i=0; $i -lt 120; $i++) { Start-Sleep -Milliseconds 500; if ((Get-ScheduledTask bs-user).State -ne "Running") { break } }
Unregister-ScheduledTask -TaskName bs-user -Confirm:$false
if (Test-Path C:\bs\u.out) { Get-Content C:\bs\u.out }'
}
# readbackall: every visible top-level window, owned and untitled ones too.
readbackall() { scp "${SSH_OPTS[@]}" -q "$(dirname "${BASH_SOURCE[0]}")/readback.ps1" baney@192.168.122.50:C:/readback.ps1 2>/dev/null; vmi 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\readback.ps1 -All'; }
# helper: run helpers.ps1 in the desktop session at normal level
helper() { scp "${SSH_OPTS[@]}" -q "$(dirname "${BASH_SOURCE[0]}")/helpers.ps1" baney@192.168.122.50:C:/bs/helpers.ps1 2>/dev/null; vmu "& 'C:\\bs\\helpers.ps1' $*"; }
