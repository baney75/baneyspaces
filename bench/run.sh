#!/bin/bash
# Head-to-head benchmark: BaneySpaces vs agent-desktop vs ChatGPT computer use.
#
#   bench/run.sh --tool baneyspaces|agent-desktop|chatgpt|all [--level scripted|agent|micro|all]
#   bench/run.sh --dry-run --tool all          list the tasks and check every runner resolves
#   bench/run.sh --help                        every option
#
# A real run acts on a live Mac, so it starts only when Donovan has been away for 10 minutes
# (HIDIdleTime >= 600 s) and the harness stops the moment real input shows up (idle under 5 s).
# It only touches the BaneySpaces agent workspace.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IDLE_REQUIRED=600   # fixed: no flag or variable lowers it

dry=0
for a in "$@"; do
  case "$a" in
    --dry-run|--help|-h) dry=1 ;;
  esac
done

if [ "$dry" = 0 ]; then
  # not `ioreg | awk ... exit`: awk quitting early gives ioreg a SIGPIPE, which pipefail turns into exit 141
  hid=$(ioreg -c IOHIDSystem)
  idle=$(printf '%s\n' "$hid" | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; found=1} END {if (!found) exit 1}' || true)
  if [ -z "${idle:-}" ]; then echo "bench: could not read HIDIdleTime from ioreg" >&2; exit 1; fi
  if [ "$idle" -lt "$IDLE_REQUIRED" ]; then
    echo "not run: user active (HIDIdleTime ${idle} s, need ${IDLE_REQUIRED} s). The bench acts on a live Mac and runs only while Donovan is away."
    exit 3
  fi
  # the read-back and the clean-up use the pinned agent-desktop, so it is built for every run
  "$HERE/build-agent-desktop.sh" >/dev/null
fi

exec python3 -I "$HERE/harness.py" "$@"
