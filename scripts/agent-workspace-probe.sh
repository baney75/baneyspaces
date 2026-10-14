#!/bin/bash
# Proves agents can work on the agent workspace without touching yours. While it runs, it watches
# what you'd notice: which workspace you're on, which app is in front, where the pointer is.
#   1. A command runs in a Ghostty window that `baneyspaces agent run` opens there.
#   2. TextEdit opens a scratch file there, and cua-driver types into it from behind, through
#      the text view's own element, then reads the text back.
# It fails if either piece of work doesn't land, or if anything you'd see changed.
# Run with BaneySpaces installed, Ghostty open, and cua-driver on the PATH.
#   scripts/agent-workspace-probe.sh
set -euo pipefail
DIR="$HOME/Library/Application Support/BaneySpaces"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bs-agent-probe.XXXXXX")
trap 'kill $WATCH 2>/dev/null || true; osascript -e "tell application id \"com.apple.TextEdit\" to close (every document whose path contains \"bs-agent-probe\") saving no" >/dev/null 2>&1 || true' EXIT

was_on=$(baneyspaces agent status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["workspace"])')
[ "$was_on" = off ] && baneyspaces agent on >/dev/null
AGENT=$(baneyspaces agent status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["workspace"])')
current() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["current"])' "$DIR/state.json"; }
HERE=$(current)
[ "$HERE" = "$AGENT" ] && { echo "You're on the agent workspace ($AGENT); go to another one first." >&2; exit 2; }

# What you'd notice, sampled every 50 ms until the probe ends.
cat > "$WORK/watch.swift" <<'SWIFT'
import AppKit
// A change that comes with real keyboard or mouse input in the last 0.3 s is you. One that
// comes with none was made by software: that's what this probe fails on. The HID clock
// doesn't count synthesized events, so an agent can't pass for you.
let state = CommandLine.arguments[1], out = CommandLine.arguments[2]
func current() -> String {
    guard let d = FileManager.default.contents(atPath: state), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "?" }
    return "\(o["current"] ?? "?")"
}
func look() -> String {
    let p = NSEvent.mouseLocation
    return "\(current()) \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") \(Int(p.x)),\(Int(p.y))"
}
func userIdle() -> Double { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!) }
var last = look()
FileManager.default.createFile(atPath: out, contents: Data((last + "\n").utf8))
let h = FileHandle(forWritingAtPath: out)!
h.seekToEndOfFile()
while true {
    let now = look()
    if now != last {
        let who = userIdle() < 0.3 ? "you" : "changed"
        h.write(Data(("\(who): \(last) -> \(now)\n").utf8))
        last = now
    }
    usleep(50_000)
}
SWIFT
swiftc -O "$WORK/watch.swift" -o "$WORK/watch" 2>/dev/null
"$WORK/watch" "$DIR/state.json" "$WORK/seen.txt" &
WATCH=$!
sleep 0.5

fail=0
# 1. A command in Ghostty, there. It leaves a file and closes its own window.
baneyspaces agent run --dir "$WORK" -- "touch ghostty-ran && exit" >/dev/null
for _ in $(seq 1 50); do [ -f "$WORK/ghostty-ran" ] && break; sleep 0.1; done
if [ -f "$WORK/ghostty-ran" ]; then echo "ok   Ghostty ran a command on workspace $AGENT"; else echo "FAIL Ghostty's command never ran"; fail=1; fi

# 2. TextEdit there, typed into by cua-driver from behind.
printf 'agent probe\n' > "$WORK/bs-agent-probe.txt"
baneyspaces agent open TextEdit "$WORK/bs-agent-probe.txt" >/dev/null
PID=""; WID=""
for _ in $(seq 1 50); do
  read -r PID WID < <(cua-driver call list_windows '{}' 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin); ws=d.get("windows",d)
w=[w for w in ws if w.get("app_name")=="TextEdit" and "bs-agent-probe" in (w.get("title") or "")]
print(w[0]["pid"], w[0]["window_id"]) if w else print("", "")') || true
  [ -n "$WID" ] && break; sleep 0.1
done
if [ -z "$WID" ]; then
  echo "FAIL TextEdit's window never showed up"; fail=1
else
  on=$(baneyspaces agent status --json | python3 -c "import json,sys; d=json.load(sys.stdin)['info']; print(any(v.split('\t')[0]=='$WID' for k,v in d.items() if k.startswith('window.')))")
  [ "$on" = True ] && echo "ok   TextEdit's window is on workspace $AGENT" || { echo "FAIL TextEdit's window isn't on the agent workspace"; fail=1; }
  TOKEN=$(cua-driver call get_window_state "{\"pid\":$PID,\"window_id\":$WID,\"include_screenshot\":false,\"timeout_ms\":4000}" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
t=[e for e in d.get("elements",[]) if e.get("role")=="AXTextArea"]
print(t[0]["element_token"] if t else "")')
  cua-driver call type_text "{\"pid\":$PID,\"window_id\":$WID,\"element_token\":\"$TOKEN\",\"text\":\"typed from behind\"}" >/dev/null 2>&1 || true
  got=$(cua-driver call get_window_state "{\"pid\":$PID,\"window_id\":$WID,\"include_screenshot\":false,\"timeout_ms\":4000}" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(any("typed from behind" in str(e.get("value","")) for e in d.get("elements",[])))')
  [ "$got" = True ] && echo "ok   cua-driver typed into TextEdit from behind" || { echo "FAIL the typed text isn't in TextEdit"; fail=1; }
fi

sleep 0.3
kill $WATCH 2>/dev/null || true
changes=$(grep -c '^changed' "$WORK/seen.txt" || true)
yours=$(grep -c '^you' "$WORK/seen.txt" || true)
if [ "$changes" = 0 ]; then
  echo "ok   nothing but you changed your screen: workspace, front app and pointer ($yours changes were your own input)"
else
  echo "FAIL your screen changed $changes times:"; grep '^changed' "$WORK/seen.txt" | sort -u | head -5; fail=1
fi
[ "$was_on" = off ] && baneyspaces agent off >/dev/null
exit $fail
