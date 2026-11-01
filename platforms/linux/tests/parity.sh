# Sourced by nested.sh after shell.sh: BaneySpaces against Omarchy's own navigation (see PARITY.md).
# Everything here runs in the nested session; numbers go to $TMP/parity-numbers.json (and, with SAVE_SHOTS=1, to
# platforms/linux/tests/parity-numbers.json, which scripts/gen-parity.py reads).
guard_nested
PY=/usr/bin/python3
NUM="$TMP/parity-numbers.json"; echo '{}' > "$NUM"
addnum() { jq --argjson v "$2" ".$1 = \$v" "$NUM" > "$NUM.tmp" && mv "$NUM.tmp" "$NUM"; }
reload_wait() { hyprctl reload >/dev/null; sleep 1.2; }

echo "== parity: every Omarchy binding that BaneySpaces does not replace is untouched"
export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
REAL_BINDINGS="$(getent passwd "$(id -un)" | cut -d: -f6)/.config/hypr/bindings.lua"   # read only: your own bindings join the comparison
mkdir -p "$XDG_CONFIG_HOME/hypr"; [ -f "$REAL_BINDINGS" ] && cp "$REAL_BINDINGS" "$XDG_CONFIG_HOME/hypr/bindings.lua" || : > "$XDG_CONFIG_HOME/hypr/bindings.lua"
cp "$TMP/hypr.lua" "$TMP/hypr.lua.keep"
cfg_a() {
  cat <<LUA
hl.config({ debug = { enable_stdout_logs = true }, misc = { disable_hyprland_logo = true } })
hl.monitor({ output = "HEADLESS-1", mode = "1920x1080@60", position = "0x0", scale = 1 })
hl.monitor({ output = "HEADLESS-2", mode = "1920x1080@60", position = "1920x0", scale = 1 })
dofile("$OMARCHY_PATH/default/hypr/bootstrap.lua")
require("default.hypr.helpers")
require("default.hypr.bindings.media")
require("default.hypr.bindings.clipboard")
require("default.hypr.bindings.tiling")
require("default.hypr.bindings.utilities")
pcall(require, "default.hypr.bindings.voxtype")
pcall(require, "default.hypr.bindings.applications")
pcall(require, "hypr.bindings")
pcall(require, "default.hypr.looknfeel")
LUA
}
{ cfg_a; } > "$TMP/hypr.lua"; reload_wait
ERR_A="$(hyprctl configerrors | grep -v '^$' | head -3)"
hyprctl -j binds > "$TMP/binds-a.json"; hyprctl -j animations > "$TMP/anim-a.json"
{ cfg_a; echo "dofile(\"$REPO/platforms/linux/omarchy/baneyspaces.lua\")"; } > "$TMP/hypr.lua"; reload_wait
ERR_B="$(hyprctl configerrors | grep -v '^$' | head -3)"
hyprctl -j binds > "$TMP/binds-b.json"; sleep 0.8; hyprctl -j animations > "$TMP/anim-b.json"
eq "Omarchy's real default and your own bindings load without errors" "$ERR_A" ""
eq "…and so does the include on top of them" "$ERR_B" ""
check "Omarchy's own bindings are loaded (more than 100)" test "$(jq length "$TMP/binds-a.json")" -gt 100
BD="$($PY -I "$HERE/bind-diff.py" "$TMP/binds-a.json" "$TMP/binds-b.json" "$REPO/spec/keys.json" 2>&1)"; BDRC=$?
echo "  $(echo "$BD" | head -1)"
eq "no Omarchy binding changed or vanished except the ones BaneySpaces replaces (spec/keys.json)" "$BDRC" "0"
[ "$BDRC" != 0 ] && echo "$BD" | head -12
[ -f "$TMP/frame-probe.json" ] && addnum frame_probe "$(cat "$TMP/frame-probe.json")"
addnum bindings "$(echo "$BD" | head -1 | $PY -I -c 'import re,sys,json; t=sys.stdin.read(); m=re.match(r"before (\d+) bindings, after (\d+): (\d+) untouched, (\d+) replaced by BaneySpaces, (\d+) BaneySpaces", t); print(json.dumps(dict(zip(["before","after","untouched","replaced","added"], map(int, m.groups())))))')"
cp "$TMP/hypr.lua.keep" "$TMP/hypr.lua"; reload_wait
check "the daemon is back on the test config" wait_for 6 sh -c "baneyspaces state | jq -e .ok"

echo "== parity: the bar's workspace module (omarchy.workspaces) agrees with BaneySpaces"
# Its click is `hyprctl dispatch hl.dsp.focus({ workspace = "N" })` (plugins/bar/widgets/Workspaces.qml).
BARCLICK() { hyprctl dispatch "hl.dsp.focus({ workspace = \"$1\" })" >/dev/null; sleep 0.5; }
baneyspaces focus-monitor $M1 >/dev/null; baneyspaces switch 1 >/dev/null; baneyspaces focus-monitor $M2 >/dev/null; baneyspaces switch 2 >/dev/null; baneyspaces focus-monitor $M1 >/dev/null; sleep 0.4
BARCLICK 5
eq "clicking an unshown workspace on the bar shows it on the display you are on" "$(mon_ws $M1),$(mon_ws $M2)" "5,2"
eq "the model saw it" "$(baneyspaces state | jq -r '[.data.monitors["'$M1'"].current,.data.monitors["'$M2'"].current]|join(",")')" "5,2"
BARCLICK 2
eq "clicking a workspace another display shows goes to that display (R-S3), nothing else changes" "$(H monitors | jq -r '.[]|select(.focused)|.name'),$(mon_ws $M1),$(mon_ws $M2)" "$M2,5,2"
eq "the model agrees" "$(baneyspaces state | jq -r '.data.focused_monitor')" "$M2"
baneyspaces focus-monitor $M1 >/dev/null; baneyspaces switch 1 >/dev/null; sleep 0.3
eq "workspace occupancy is one list: what the bar reads (Hyprland) equals what BaneySpaces holds" "$(H workspaces | jq -r '[.[]|select(.id>=1 and .id<=9 and .windows>0)|.id]|sort|join(",")')" "$(baneyspaces state | jq -r '[.data.workspaces|to_entries[]|select(.value|length>0)|.key|tonumber]|sort|join(",")')"
eq "scrolling the bar's workspaces (relative, e+1) lands on a real workspace of the nine" "$(hyprctl dispatch 'hl.dsp.focus({ workspace = "e+1" })' >/dev/null; sleep 0.4; mon_ws $M1 | awk '$1>=1 && $1<=9 {print "ok"}')" "ok"
baneyspaces switch 1 >/dev/null; sleep 0.3

echo "== parity: Super+N runs in the compositor when that is what BaneySpaces would do, and asks the daemon when it is not"
SW() { hyprctl eval "baneyspaces_switch($1)" >/dev/null; sleep 0.5; }
baneyspaces focus-monitor $M1 >/dev/null; baneyspaces switch 1 >/dev/null; baneyspaces focus-monitor $M2 >/dev/null; baneyspaces switch 2 >/dev/null; baneyspaces focus-monitor $M1 >/dev/null; sleep 0.4
SW 4
eq "a workspace that is not made yet opens on the display you are on" "$(mon_ws $M1),$(mon_ws $M2)" "4,2"
eq "the model heard of it" "$(baneyspaces state | jq -r '[.data.monitors["'$M1'"].current,.data.monitors["'$M2'"].current]|join(",")')" "4,2"
SW 2
eq "a workspace another display shows takes you to that display, nothing else changes (R-S3)" "$(H monitors | jq -r '.[]|select(.focused)|.name'),$(mon_ws $M1),$(mon_ws $M2)" "$M2,4,2"
baneyspaces focus-monitor $M2 >/dev/null; baneyspaces switch 5 >/dev/null; baneyspaces switch 2 >/dev/null; baneyspaces focus-monitor $M1 >/dev/null; sleep 0.4
SW 5
eq "a workspace hidden on the other display is brought to this one by the daemon (R-S2), the other display keeps what it shows" "$(mon_ws $M1),$(mon_ws $M2)" "5,2"
open_agent_window >/dev/null; baneyspaces agent-workspace show >/dev/null; sleep 0.5
SW 3
eq "with the agent workspace up the daemon closes it first, then switches" "$(mon_ws $M1)-$(special)" "3-0"
baneyspaces switch 1 >/dev/null; sleep 0.3

echo "== parity: animations. Omarchy's own are untouched, workspace switches are as instant as Omarchy's, and nothing glitches with special:agent"
leaf() { jq -c --arg n "$2" '[.[0][]|select(.name==$n)|{enabled,style,speed,bezier}]|first' "$1"; }
eq "Omarchy's looknfeel loaded in the test: workspaces animation is off (Omarchy's own choice)" "$(jq -r '[.[0][]|select(.name=="workspaces")|.enabled]|first' "$TMP/anim-a.json")" "false"
eq "…and the scratchpad's special-workspace slide is on" "$(jq -r '[.[0][]|select(.name=="specialWorkspace")|.enabled]|first' "$TMP/anim-a.json")" "true"
for n in workspaces specialWorkspace windows windowsIn windowsOut layers layersIn layersOut fade fadeIn fadeOut border; do
  eq "after the include and the daemon, Omarchy's $n animation is as it was" "$(leaf "$TMP/anim-b.json" $n)" "$(leaf "$TMP/anim-a.json" $n)"
done
eq "animation.workspace.style is off by default" "$(baneyspaces config | jq -r '.data.settings.motion.workspace_style')" "off"
baneyspaces switch 1 >/dev/null; sleep 0.5
TR="$($PY -I "$HERE/anim-trace.py" '/dispatch hl.dsp.exec_raw("baneyspaces switch 3")' '/dispatch hl.dsp.exec_raw("baneyspaces switch 1")')"
eq "a switch passes through no third workspace (1 to 3, 3 to 1)" "$(echo "$TR" | jq -c '[.[]|[.[]|.[0]]]')" "[[1,3],[3,1]]"
eq "…and is one step: the compositor shows the new workspace at once" "$(echo "$TR" | jq -c '[.[]|length]')" "[2,2]"
open_agent_window >/dev/null; sleep 0.4
TR="$($PY -I "$HERE/anim-trace.py" '/dispatch hl.dsp.exec_raw("baneyspaces agent-workspace show")' '/dispatch hl.dsp.exec_raw("baneyspaces switch 3")' '/dispatch hl.dsp.exec_raw("baneyspaces switch 1")')"
eq "showing the agent workspace changes only the special workspace (Omarchy's slide stays on)" "$(echo "$TR" | jq -c '.[0]|map(.[0])|unique')" "[1]"
eq "a switch while it is up closes it first and ends on 3 with no agent workspace" "$(echo "$TR" | jq -c '.[1]|[(map(.[0])|unique), (.[-1][1])]')" '[[1,3],""]'
eq "it never comes back by itself while you switch away" "$(echo "$TR" | jq -c '[.[2][]|select(.[1]=="special:agent")]|length')" "0"
eq "after all of it nothing of the agent's is showing" "$(special)" "0"
addnum animation '{"workspaces":"instant by default (Omarchy turns it off too)","omarchy_animations":"untouched: windows, layers, fade, border and the scratchpad slide are identical before and after","switch_states":[[1,3],[3,1]],"special_agent_states":"no third workspace, agent never returns","method":"hyprctl j/monitors polled every 2 ms for 1.4 s per command"}'
baneyspaces set animation.workspace.style fade >/dev/null; sleep 0.8
eq "animation.workspace.style = fade turns Hyprland's workspace animation on" "$(H animations | jq -r '[.[0][]|select(.name=="workspaces")|.enabled]|first')" "true"
eq "…as a fade" "$(H animations | jq -r '[.[0][]|select(.name=="workspaces")|.style]|first')" "fade"
TR="$($PY -I "$HERE/anim-trace.py" '/dispatch hl.dsp.exec_raw("baneyspaces switch 4")' '/dispatch hl.dsp.exec_raw("baneyspaces switch 1")')"
eq "a fading switch still passes through no third workspace" "$(echo "$TR" | jq -c '[.[]|[.[]|.[0]]]')" "[[1,4],[4,1]]"
baneyspaces set animation.workspace.style off >/dev/null; sleep 0.8
eq "back to instant" "$(H animations | jq -r '[.[0][]|select(.name=="workspaces")|.enabled]|first')" "false"
baneyspaces agent move "$(baneyspaces agent status | jq -r '.data.windows[0].window')" >/dev/null 2>&1

echo "== parity: switch latency, native bind versus BaneySpaces bind"
LAT="$($PY -I "$HERE/latency.py" "${LAT_SAMPLES:-40}" baneyspaces)"
echo "  $LAT"
addnum switch_latency_ms "$LAT"
NP50="$(echo "$LAT" | jq .native.p50)"; OP50="$(echo "$LAT" | jq .ours.p50)"; NP90="$(echo "$LAT" | jq .native.p90)"; OP90="$(echo "$LAT" | jq .ours.p90)"
if [ -n "${BS_RELEASE:-}" ]; then
  eq "BaneySpaces' bind (a function in the compositor) is within 5 ms of the native bind at p50 ($OP50 vs $NP50 ms)" "$(jq -n "$OP50 <= $NP50 + 5")" "true"
  eq "…and p90 ($OP90 vs $NP90 ms)" "$(jq -n "$OP90 <= $NP90 + 5")" "true"
else
  echo "  (debug build: the budget is asserted with BS_RELEASE=1)"
fi

echo "== parity: the launcher against Omarchy's own app search"
QJ="{}"
while IFS= read -r q; do
  ids="$(baneyspaces launcher search "$q" --mode apps | jq -c '[.data.results[]|select(.id|startswith("app:"))|.id[4:]]')"
  QJ="$(jq -c --arg q "$q" --argjson ids "$ids" '.[$q]=$ids' <<<"$QJ")"
done < <(node "$HERE/launcher-quality.js" --queries)
echo "$QJ" > "$TMP/ours.json"
QOUT="$(node "$HERE/launcher-quality.js" "$TMP/ours.json")"; QRC=$?
echo "  $QOUT" | cut -c1-400
addnum launcher_quality "$QOUT"
eq "BaneySpaces' fuzzy match is at least Omarchy's on precision@1, @3 and MRR (same apps, same queries)" "$QRC" "0"
LT0=$(date +%s%N); for i in 1 2 3 4 5 6 7 8 9 10; do baneyspaces launcher search chrom --mode apps >/dev/null; done; LT1=$(date +%s%N)
SEARCH_MS=$(( (LT1-LT0)/10000000 )); echo "  launcher search round trip (CLI + daemon): ~$SEARCH_MS ms each"
baneyspaces launcher show >/dev/null; sleep 0.6; LQ type chrom >/dev/null; sleep 0.8
TIM="$(LQ timing)"; echo "  launcher in the shell: $TIM"
addnum launcher_timing "$(jq -c --argjson s "$SEARCH_MS" '. + {cli_search_ms:$s}' <<<"$TIM")"
baneyspaces launcher hide >/dev/null; sleep 0.3
eq "the calculator answers in the launcher" "$(baneyspaces launcher search '12*(3+4)' | jq -r '.data.results[0].title')" "= 84"
eq "Omarchy's menus are reachable from the launcher (Style, Setup, ...)" "$(baneyspaces launcher search style --mode system | jq -r '[.data.results[]|select(.id=="omenu:style")]|length')" "1"
if [ -n "${SAVE_SHOTS:-}" ]; then cp "$NUM" "$HERE/parity-numbers.json"; fi
