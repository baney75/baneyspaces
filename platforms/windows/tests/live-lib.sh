#!/usr/bin/env bash
# Helpers for the live test in the Windows 11 VM (Parish1). Source, do not run.
VMDIR="${VMDIR:-/home/baney75/Projects/_work/win11-vm}"
. "$VMDIR/lib.sh"
BS='C:\bs\baneyspaces\target\release\baneyspaces.exe'
vmx()  { "$VMDIR/exec" "$@" 2>&1 | sed 's/_x000D__x000A_//g; /^#< CLIXML/d'; }
vmi()  { "$VMDIR/exec" -i "$@" 2>&1 | sed 's/_x000D__x000A_//g; /^#< CLIXML/d'; }
bsx()  { vmx "& '$BS' $*"; }
# readback: the windows and what is seen, from the desktop session
readback() { scp "${SSH_OPTS[@]}" -q "$(dirname "${BASH_SOURCE[0]}")/readback.ps1" baney@192.168.122.50:C:/readback.ps1 2>/dev/null; vmi 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\readback.ps1'; }
shot() { "$VMDIR/shot" "$SHOTS/$1.png" >/dev/null && echo "shot: $SHOTS/$1.png"; }
