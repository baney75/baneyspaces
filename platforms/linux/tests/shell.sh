# Sourced by nested.sh: the Omarchy shell plugin (dock, switcher, launcher, overview, settings) in the
# nested session. Needs the helpers and variables nested.sh defines ($TMP, $REPO, eq, check, H, M1, M2 ...).

PLUGIN="$REPO/platforms/linux/omarchy/plugins/io.github.baney75.baneyspaces"
QSD="$TMP/qs"; mkdir -p "$QSD" "$TMP/shots"
cat >"$QSD/shell.qml" <<QML
import QtQuick
import Quickshell
ShellRoot { Loader { source: "file://$PLUGIN/Service.qml" } }
QML
# the user's active Omarchy theme (read only), so the shots look like the real thing
THEME_SRC="${OMARCHY_THEME_DIR:-$(readlink -f "$(getent passwd "$(id -un)" | cut -d: -f6)/.local/state/omarchy/current/theme" 2>/dev/null)}"
mkdir -p "$TMP/theme"; [ -f "$THEME_SRC/colors.toml" ] && cp "$THEME_SRC/colors.toml" "$TMP/theme/colors.toml"
export BANEYSPACES_THEME_DIR="$TMP/theme"
export QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-software}" QS_NO_RELOAD_POPUP=1
guard_nested   # a GUI process starts below: only ever inside the nested session
quickshell -p "$QSD/shell.qml" >"$TMP/quickshell.log" 2>&1 & QSPID=$!; PIDS+=($QSPID)
for _ in $(seq 1 100); do qs ipc -p "$QSD/shell.qml" call baneyspaces ping 2>/dev/null | grep -q ok && break; sleep 0.2; done
QI() { qs ipc -p "$QSD/shell.qml" call "$@" 2>&1; }

echo "== shell plugin: connected, themed, quiet"
client_ws() { H clients | jq -r ".[]|select(.address==\"$1\")|.workspace.name"; }
# An agent window the daemon accepts: a terminal it starts for an agent.
open_agent_window() { baneyspaces agent run -- sleep 600 | jq -r '.data.window // empty'; }
wait_for() { local t="$1"; shift; for _ in $(seq 1 $((t*10))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
qs_state() { QI baneyspaces state | jq -r "$1"; }
check "the plugin reached the daemon's socket" wait_for 8 sh -c "qs ipc -p '$QSD/shell.qml' call baneyspaces state | jq -e .connected"
eq "it reads the Omarchy theme file" "$(qs_state .theme.accent)" "$(sed -n 's/^accent *= *"\(#[0-9a-fA-F]*\)".*/\1/p' "$TMP/theme/colors.toml" | head -1)"
check "the daemon counts a subscriber (state pushes work)" sh -c "baneyspaces ui | jq -e '.data.version==1 and (.data.workspaces|length)==9'"

# A clean, known set of windows: close yours, then open one workspace at a time the way a launcher does.
for a in $(H clients | jq -r '.[]|select(.workspace.name!="special:agent")|.address'); do hyprctl dispatch "hl.dsp.window.close({ window = \"address:$a\" })" >/dev/null; done; sleep 0.5
baneyspaces focus-monitor $M1 >/dev/null
goto() { # goto <monitor> <n>: be on that monitor, showing n, and wait until Hyprland agrees
  baneyspaces focus-monitor "$1" >/dev/null; baneyspaces switch "$2" >/dev/null
  for _ in $(seq 1 40); do [ "$(mon_ws "$1")" = "$2" ] && [ "$(H monitors | jq -r '.[]|select(.focused)|.name')" = "$1" ] && break; sleep 0.1; done; sleep 0.15
}
mkwin() { # mkwin <app-id> <title>: a window of an app, opened where you are
  hyprctl dispatch "hl.dsp.exec_cmd(\"foot -a '$1' -T '$2' sleep 600\")" >/dev/null
  for _ in $(seq 1 60); do H clients | jq -e ".[]|select(.title==\"$2\")" >/dev/null && break; sleep 0.1; done; sleep 0.15
}
addr_of() { H clients | jq -r ".[]|select(.title==\"$1\")|.address"; }
goto $M1 1
mkwin foot "claude — baneyspaces"; mkwin foot "build log"; mkwin chromium "Docs"; mkwin obsidian "Notes"; mkwin libreoffice-writer "Letter"; mkwin libreoffice-calc "Budget"
goto $M2 2
mkwin blender "Scene"; mkwin mpv "Video"
goto $M1 4
mkwin foot "⠂ Fix the dock"
goto $M1 6
mkwin foot "agent question"
goto $M1 1; sleep 0.3
eq "the snapshot has a tile for 1, 2, 4 and 6 and offers 3 as the new one" "$(baneyspaces ui | jq -c '[.data.dock.tiles,.data.dock.new_target]')" "[[1,2,4,6],3]"
eq "workspace 1 has five apps: three shown and a +2" "$(baneyspaces ui | jq -c '.data.workspaces[0]|[(.apps|length),(.shown_apps|length),(.more|length)]')" "[5,3,2]"
eq "two foot windows are one app on a tile" "$(baneyspaces ui | jq '.data.workspaces[0].apps[0].count')" "2"

echo "== agent status badges"
eq "a terminal title with Claude's spinner shows as working" "$(baneyspaces ui | jq -r '.data.workspaces[3].badge')" "working"
AQ="$(addr_of 'agent question')"
eq "a hook can say an agent is asking" "$(baneyspaces agent-status set asking --window "$AQ" | jq -r .data.state)" "asking"
eq "it reaches the tile" "$(baneyspaces ui | jq -r '.data.workspaces[5].badge')" "asking"
eq "an unknown state is refused" "$(baneyspaces agent-status set sleepy --window "$AQ" | jq -r .error.code)" "invalid_args"
eq "a window that is not there is not_found" "$(baneyspaces agent-status set working --window 0xdead | jq -r .error.code)" "not_found"
CL="$(addr_of 'claude — baneyspaces')"
baneyspaces agent-status set finished --window "$CL" >/dev/null
eq "finished shows on the app and counts" "$(baneyspaces ui | jq -c '[.data.workspaces[0].apps[0].badge,.data.agent.finished]')" '["finished",1]'
hyprctl dispatch "hl.dsp.focus({ window = \"address:$CL\" })" >/dev/null; sleep 0.3
eq "looking at it clears finished" "$(baneyspaces ui | jq -r '.data.workspaces[0].apps[0].badge')" "null"
baneyspaces agent-status set asking --window "$CL" >/dev/null; sleep 0.2
eq "hooks print is valid JSON with four hooks" "$(baneyspaces hooks print | jq '.hooks|length')" "4"

echo "== workspace dock"
D() { QI baneyspaces.dock "$@"; }
eq "auto-hide: the dock is down until the pointer rests on the edge" "$(D state | jq -r .wanted)" "false"
baneyspaces dock show >/dev/null; sleep 0.8
eq "dock show brings it up on the display you are on" "$(D state | jq -r '[.wanted,.screen]|join(",")')" "true,$M1"
eq "tiles: 1, 2, 4, 6 and the dashed one" "$(D state | jq -c '[.tiles[]|.n]|sort')" "[0,1,2,4,6]"
eq "each tile has its own apps" "$(D state | jq -c '[.tiles[]|select(.n==1)|.apps[]]')" '["foot","chromium","obsidian","libreoffice-writer","libreoffice-calc"]'
check "the tiles sit inside the bar and the bar on screen" sh -c "qs ipc -p '$QSD/shell.qml' call baneyspaces.dock state | jq -e '.bar as \$b | .tiles | all(.x >= \$b.x and .x + .w <= \$b.x + \$b.w and .y >= \$b.y and .y + .h <= \$b.y + \$b.h)'"
grim -g "$((960-480)),$((1080-170)) 960x170" "$TMP/shots/dock.png"
eq "clicking tile 4 goes there" "$(D clickTile 4 >/dev/null; sleep 0.3; mon_ws $M1)" "4"
D clickTile 1 >/dev/null; sleep 0.3
eq "clicking the dashed tile goes to the first empty workspace" "$(D clickTile 0 >/dev/null; sleep 0.3; mon_ws $M1)" "3"
D clickTile 1 >/dev/null; sleep 0.3
D clickApp 1 chromium >/dev/null; sleep 0.3
eq "clicking an app puts its window in front" "$(active)" "$(addr_of Docs)"
D clickApp 1 foot >/dev/null; sleep 0.3; F1="$(active)"; D clickApp 1 foot >/dev/null; sleep 0.3
check "clicking the app again goes to its next window" test "$(active)" != "$F1"

echo "== dock: the +N list, drag to a tile, the dashed tile"
eq "the +2 list holds the apps the tile cannot show (by their names)" "$(D openList 1 more >/dev/null; sleep 0.5; D state | jq -c '.list|[.kind,.rows]')" '["more",["LibreOffice Writer","LibreOffice Calc"]]'
eq "an open list is part of the dock's keep zone (the daemon knows its rect)" "$(sleep 0.3; baneyspaces ui | jq -r '.data.dock.list_open')" "true"
grim -g "$((960-480)),$((1080-350)) 960x350" "$TMP/shots/dock-overflow.png"
LW="$(addr_of Letter)"
eq "dragging a row from the list onto tile 2 moves that window there" "$(D dragRow 0 2 >/dev/null; sleep 0.4; client_ws $LW)" "2"
eq "and you stay where you are" "$(mon_ws $M1)" "1"
D closeList >/dev/null; sleep 0.3
eq "the list is gone" "$(D state | jq -r '.list')" "null"
OB="$(addr_of Notes)"
eq "dragging an app's icon onto tile 4 moves its windows there" "$(D dragApp 1 obsidian 4 >/dev/null; sleep 0.4; client_ws $OB)" "4"
eq "dropping on the dashed tile starts a new workspace (3) with it" "$(D dragApp 2 mpv 0 >/dev/null; sleep 0.4; client_ws "$(addr_of Video)")" "3"
eq "move-windows refuses a workspace number outside 1-9" "$(baneyspaces move-windows 12 $OB | jq -r .error.code)" "invalid_args"
eq "the model agrees with Hyprland" "$(baneyspaces state | jq -r ".data.windows[\"$OB\"].home")" "$(client_ws $OB)"

echo "== dock: the pointer decides when it is up (a real pointer in the nested session)"
baneyspaces dock hide >/dev/null; sleep 0.5
warp() { hyprctl dispatch "hl.dsp.cursor.move({ x = $1, y = $2 })" >/dev/null; }
warp 400 500; sleep 0.3
eq "pointer in the middle of the screen: the dock is down" "$(baneyspaces ui | jq -r .data.dock.up)" "false"
warp 960 1079; sleep 0.6
eq "pointer resting on the bottom edge: it comes up on that display" "$(baneyspaces ui | jq -r '[.data.dock.up,.data.dock.monitor]|join(",")')" "true,$M1"
sleep 0.8
eq "still resting where it opened it: it stays up" "$(baneyspaces ui | jq -r .data.dock.up)" "true"
BAR="$(D state | jq -c .bar)"; BY="$(echo "$BAR" | jq '.y|floor')"; BX="$(echo "$BAR" | jq '(.x+.w/2)|floor')"
warp "$BX" "$((BY + 20))"; sleep 0.9
eq "pointer on the bar: it stays up" "$(baneyspaces ui | jq -r .data.dock.up)" "true"
warp "$BX" "$((BY - 8))"; sleep 0.9
eq "8 pt above the bar (inside the 12 pt zone): it stays up" "$(baneyspaces ui | jq -r .data.dock.up)" "true"
warp "$BX" "$((BY - 30))"; sleep 0.9
eq "30 pt above the bar (outside the zone): it goes down" "$(baneyspaces ui | jq -r .data.dock.up)" "false"
check "the bar is invisible again after its fade" wait_for 2 sh -c "[ \"\$(qs ipc -p '$QSD/shell.qml' call baneyspaces.dock state | jq -r .visible)\" = false ]"
warp 960 1079; sleep 0.6; warp "$BX" "$((BY + 20))"; sleep 0.3
BAR="$(D state | jq -c .bar)"; BY="$(echo "$BAR" | jq '.y|floor')"; BARX="$(echo "$BAR" | jq '.x|floor')"   # the bar grew when tiles moved
warp "$((BARX + 4))" "$((BY + 20))"; sleep 0.3
D openList 1 foot >/dev/null; sleep 0.15
LRECT="$(D state | jq -c .list.rect)"; LX="$(echo "$LRECT" | jq '(.x+.w/2)|floor')"; LY="$(echo "$LRECT" | jq '(.y+.h/2)|floor')"; LW2="$(echo "$LRECT" | jq '(.w/2)|floor')"
warp "$LX" "$LY"; sleep 1.0
eq "with a list open, the pointer on the list keeps the dock up (and the list open)" "$(baneyspaces ui | jq -r '[.data.dock.up,.data.dock.list_open]|join(",")')" "true,true"
warp "$((LX + LW2 + 100))" "$LY"; sleep 1.2
eq "100 pt beside the list does not hold it: the list closes, then the dock goes down" "$(baneyspaces ui | jq -r '[.data.dock.up,.data.dock.list_open]|join(",")')" "false,false"
D closeList >/dev/null; warp 400 500; sleep 0.9
eq "everything goes down once the pointer leaves" "$(baneyspaces ui | jq -r .data.dock.up)" "false"
baneyspaces focus-monitor $M1 >/dev/null

echo "== Alt+Tab switcher"
SWI() { QI baneyspaces.switcher state; }
baneyspaces switch 1 >/dev/null; sleep 0.3; D clickApp 1 chromium >/dev/null; sleep 0.3
eq "the switcher is closed" "$(SWI | jq -r .open)" "false"
SW="$(baneyspaces switcher next)"
eq "the first press selects the window you used before" "$(echo "$SW" | jq -r '.data.index')" "1"
sleep 0.5
eq "the plugin shows it" "$(SWI | jq -r .open)" "true"
check "it lists windows from every workspace" test "$(echo "$SW" | jq '[.data.items[].workspace]|unique|length')" -ge 4
SWA="$(open_agent_window)"
check "an agent window is open" test -n "$SWA"
eq "an agent's window cannot be sent anywhere by a drag" "$(baneyspaces move-windows 5 "$SWA" | jq -r .error.code)" "agent_window"
eq "the agent workspace is never offered by the switcher" "$(baneyspaces switcher cancel >/dev/null; baneyspaces switcher next | jq --arg w "$SWA" '[.data.items[].window]|index($w)')" "null"
grim -o $M1 "$TMP/shots/switcher-full.png"; grim -g "$((960-800)),$((540-110)) 1600x220" "$TMP/shots/switcher.png"; rm -f "$TMP/shots/switcher-full.png"
baneyspaces switcher next >/dev/null; WANT="$(baneyspaces ui | jq -r '.data.switcher.items[.data.switcher.index].window')"; WANTWS="$(baneyspaces ui | jq -r '.data.switcher.items[.data.switcher.index].workspace')"
CM="$(baneyspaces switcher commit)"
eq "letting go goes to the selected window" "$(echo "$CM" | jq -r .data.window)" "$WANT"
sleep 0.4
sleep 0.3
eq "wherever it is: its workspace is now on the display you are on" "$(mon_ws $M1)" "$WANTWS"
eq "it is in front" "$(active)" "$WANT"
eq "the switcher is closed again" "$(baneyspaces ui | jq -r .data.switcher.open)" "false"
eq "Shift+Alt+Tab opens on the oldest window" "$(baneyspaces switcher prev | jq -r '.data.index == (.data.items|length-1)')" "true"
baneyspaces switcher cancel >/dev/null
eq "cancel changes nothing" "$(active)" "$WANT"

echo "== launcher"
LQ() { QI baneyspaces.launcher "$@"; }
baneyspaces launcher show >/dev/null; sleep 0.5
LQ type "foot" >/dev/null; sleep 0.6
check "typing finds the app" sh -c "qs ipc -p '$QSD/shell.qml' call baneyspaces.launcher state | jq -e '.titles|index(\"Foot\") != null'"
LQ type "libre" >/dev/null; sleep 0.7; grim -g "$((960-360)),150 720x480" "$TMP/shots/launcher.png"
baneyspaces launcher hide >/dev/null; sleep 0.4
eq "an app that is open takes you to its window (workspace shown in the row)" "$(baneyspaces launcher search chromium | jq -r '.data.results[0]|[.title,.section]|join(",")')" "Chromium,Apps"
check "the open app's row says which workspace it is on" sh -c "baneyspaces launcher search chromium | jq -e '.data.results[0].subtitle|test(\"workspace\")'"
R="$(baneyspaces launcher search chromium | jq -r '.data.results[0].id')"
baneyspaces switch 4 >/dev/null; sleep 0.2
baneyspaces launcher search chromium >/dev/null; baneyspaces launcher run "$R" >/dev/null; sleep 0.4
eq "Return on an open app goes to its window, on the display you are on" "$(active)" "$(addr_of Docs)"
eq "workspaces are searchable by number" "$(baneyspaces launcher search 5 | jq -r '.data.results[0].id')" "ws:5"
eq "a bang goes to its site" "$(baneyspaces launcher search '!yt lofi & chill' | jq -r '.data.results[0].id')" "bang:yt"
baneyspaces launcher search '!yt lofi & chill' >/dev/null
eq "…as a web address, words encoded" "$(baneyspaces launcher run bang:yt --dry-run | jq -r '.data.would_run[1]')" "https://www.youtube.com/results?search_query=lofi%20%26%20chill"
baneyspaces launcher search '?why is the sky blue' >/dev/null
eq "? asks your agent in a new chat" "$(baneyspaces launcher run ask:claude --dry-run | jq -r '.data.would_run[1]')" "https://claude.ai/new?q=why%20is%20the%20sky%20blue"
baneyspaces launcher search "Pinta" >/dev/null
eq "an app that is not open is started with its Exec line, field codes dropped" "$(baneyspaces launcher run app:com.github.PintaProject.Pinta --dry-run | jq -r '.data.would_run|join(" ")')" "pinta"
mkdir -p "$HOME/Documents"; : > "$HOME/Documents/2025 Tax Return.pdf"; : > "$HOME/Documents/taxidermy.txt"
eq "files: every word must start a word of the name" "$(baneyspaces launcher search 'tax 2025' | jq -r '[.data.results[]|select(.section=="Files")|.title]|join(",")')" "2025 Tax Return.pdf"
eq "install searches the package database" "$(baneyspaces launcher search firefox --mode install | jq -r '[.data.results[]|select(.title=="firefox")]|length')" "1"
baneyspaces launcher search firefox --mode install >/dev/null
INST="$(baneyspaces launcher run pkg:firefox)"
eq "install asks first" "$(echo "$INST" | jq -r '.data.needs_confirm')" "true"
eq "…and says what will run" "$(echo "$INST" | jq -r '.data.command')" "omarchy pkg add firefox"
eq "confirmed, it would run omarchy pkg add in a terminal (dry run: nothing installed)" "$(baneyspaces launcher run pkg:firefox --confirm --dry-run | jq -r '.data.would_run[1]')" "omarchy pkg add firefox"
eq "a package name with shell characters is never offered" "$(baneyspaces launcher search 'x;touch' --mode install | jq '[.data.results[]|select(.id|test(";"))]|length')" "0"
eq "remove lists what you installed and asks first" "$(baneyspaces launcher search '' --mode remove | jq -r '.data.results[0].confirm')" "true"
eq "an unknown result id is not_found" "$(baneyspaces launcher run nonsense | jq -r .error.code)" "not_found"

echo "== overview"
OQ() { QI baneyspaces.overview "$@"; }
baneyspaces overview show >/dev/null; sleep 0.9
eq "all nine workspaces are drawn" "$(OQ describe | jq '.cards|length')" "9"
eq "workspace 1 shows its windows" "$(OQ describe | jq '.cards[0].windows|length')" "$(baneyspaces ui | jq '.data.workspaces[0].windows|length')"
grim -o $M1 "$TMP/shots/overview.png"
CW="$(addr_of Budget)"
eq "dragging a window card onto workspace 7 moves it" "$(OQ dragWindow "$CW" 7 >/dev/null; sleep 0.5; client_ws $CW)" "7"
eq "the overview stays open while you tidy" "$(baneyspaces ui | jq -r .data.overview.shown)" "true"
OQ clickCard 6 >/dev/null; sleep 0.5
eq "clicking a workspace goes there and closes the overview" "$(mon_ws $M1)-$(baneyspaces ui | jq -r .data.overview.shown)" "6-false"
baneyspaces switch 1 >/dev/null
eq "Super+Tab again closes it (toggle)" "$(baneyspaces overview >/dev/null; baneyspaces overview | jq -r .data.shown)" "false"

echo "== settings and config"
CFG="$XDG_CONFIG_HOME/baneyspaces/config.toml"
baneyspaces settings show >/dev/null; sleep 0.8; grim -g "$((960-290)),0 580x1080" "$TMP/shots/settings.png"
baneyspaces settings hide >/dev/null
eq "a bad value is refused" "$(baneyspaces config set behavior.dock.size huge | jq -r .error.code)" "invalid_args"
eq "an unknown key is refused" "$(baneyspaces config set behavior.dock.nope 1 | jq -r .error.code)" "invalid_args"
eq "a good value is stored" "$(baneyspaces config set behavior.dock.size large | jq -r .data.value)" "large"
check "…in config.toml" grep -q 'size = "large"' "$CFG"
sleep 0.5
eq "…and the dock changed at once (tiles are bigger)" "$(baneyspaces dock show >/dev/null; sleep 0.6; D state | jq '.tiles[0].h > 69')" "true"
baneyspaces config set behavior.dock.size medium >/dev/null; baneyspaces dock hide >/dev/null
echo '# hand edit' >> "$CFG"; printf '[behavior.switcher]\nmode = "apps"\n' >> "$CFG"; sleep 1.6
eq "a hand edit of the file is picked up" "$(baneyspaces config | jq -r .data.settings.switcher.items)" "apps"
eq "…and keeps your comment" "$(grep -c '# hand edit' "$CFG")" "1"
baneyspaces config set behavior.switcher.mode windows >/dev/null
baneyspaces set animation.preset off >/dev/null; sleep 0.5
eq "animation.preset off makes every surface instant" "$(qs_state '[.motion.dockIn,.motion.dockOut,.motion.listIn,.motion.listOut,.motion.row]|join(",")')" "0,0,0,0,0"
baneyspaces set animation.preset omarchy >/dev/null; sleep 0.5
eq "the omarchy preset is Omarchy's own curves in ms (pop-in 410, pop-out 149, layers 400 and 150)" "$(qs_state '[.motion.dockIn,.motion.dockOut,.motion.listIn,.motion.listOut]|join(",")')" "410,149,400,150"
baneyspaces set animation.preset baneyspaces >/dev/null; baneyspaces set animation.dock.in.duration_ms 90 >/dev/null; sleep 0.5
eq "a time of your own for one surface wins" "$(qs_state .motion.dockIn)" "90"
eq "…and the others keep the theme's (the omarchy theme: 100)" "$(qs_state .motion.dockOut)" "100"
eq "over 1000 ms is refused with the path" "$(baneyspaces set animation.dock.in.duration_ms 5000 | jq -r .error.message | grep -c 'animation.dock.in.duration_ms')" "1"
baneyspaces set animation.speed 0.5 >/dev/null; sleep 0.5
eq "speed multiplies every duration" "$(qs_state .motion.dockOut)" "50"
baneyspaces set animation.speed 1.0 >/dev/null; baneyspaces set animation.dock.in.duration_ms -1 >/dev/null
baneyspaces set theme.override.fill.opacity 0.5 >/dev/null; sleep 0.5
QI baneyspaces.theme frames > "$TMP/frames.json"
eq "a theme.override token reaches the surfaces (panels drew opacity 0.5 under the omarchy theme)" "$(jq -r '[.frames[]|select(.frame.customFill==false)|.frame.fill[1:3]]|unique|join(",")' "$TMP/frames.json")" "80"
/usr/bin/python3 -I "$HERE/cfg-drop.py" "$CFG" theme.override; sleep 1.6
eq "taking the override out of the file puts the theme's own value back" "$(baneyspaces config | jq -c '.data.settings.appearance.override')" "{}"
baneyspaces config set behavior.launcher.enabled false >/dev/null
eq "a switched-off launcher falls back to Omarchy's menu" "$(baneyspaces launcher show | jq -r .data.fallback)" "omarchy-menu toggle"
baneyspaces config set behavior.launcher.enabled true >/dev/null
baneyspaces config set behavior.switcher.enabled false >/dev/null
eq "a switched-off switcher falls back to Omarchy's cycle" "$(baneyspaces switcher next | jq -r .data.fallback)" "omarchy: cycle_next"
baneyspaces config set behavior.switcher.enabled true >/dev/null

echo "== dock off (dock.enabled = false): no dock surface, no edge reveal, everything else keeps working"
layer_dock() { H layers | grep -c '"namespace": *"baneyspaces-dock"'; }
baneyspaces dock hide >/dev/null; baneyspaces set behavior.dock.enabled false | jq -e .ok >/dev/null; sleep 0.8
check "no dock layer surface exists in the compositor" wait_for 3 sh -c "[ \"\$(hyprctl -j layers | grep -c 'baneyspaces-dock')\" = 0 ]"
eq "dock show is refused" "$(baneyspaces dock show | jq -r .error.code)" "not_supported"
warp 960 1079; sleep 1.0
eq "the pointer resting on the edge reveals nothing" "$(baneyspaces ui | jq -r .data.dock.up)" "false"
eq "…and still no layer surface" "$(hyprctl -j layers | grep -c 'baneyspaces-dock')" "0"
eq "the settings say so" "$(baneyspaces config | jq -r .data.settings.dock.enabled)" "false"
warp 400 500
eq "the switcher still works" "$(baneyspaces switcher next | jq -r .ok)" "true"
baneyspaces switcher cancel >/dev/null
eq "the launcher still works" "$(baneyspaces launcher show | jq -r .ok)" "true"
baneyspaces launcher hide >/dev/null
eq "the overview still works" "$(baneyspaces overview show | jq -r .data.shown)" "true"
baneyspaces overview hide >/dev/null
eq "switching workspaces still works" "$(baneyspaces switch 3 >/dev/null; sleep 0.3; mon_ws $M1)" "3"
baneyspaces switch 1 >/dev/null
baneyspaces set behavior.dock.enabled true >/dev/null; sleep 0.5
warp 960 1079; sleep 0.8
eq "turned back on, the next edge reveal brings the dock back (no restart)" "$(baneyspaces ui | jq -r .data.dock.up)" "true"
check "…and its surface exists again" wait_for 3 sh -c "[ \"\$(hyprctl -j layers | grep -c 'baneyspaces-dock')\" -ge 1 ]"
warp 400 500; sleep 0.8

echo "== themes: every surface in every theme and palette matches spec/themes.json"
baneyspaces dock hide >/dev/null
for theme in omarchy baneyspaces minimal; do
  baneyspaces set theme.name $theme >/dev/null
  for pal in auto $(jq -r '.palettes|keys[]' "$REPO/spec/palettes.json"); do
    baneyspaces set theme.palette $pal >/dev/null; sleep 0.3
    QI baneyspaces.theme frames > "$TMP/frames.json"
    arg="$pal"; [ "$pal" = auto ] && arg="auto:$TMP/theme/colors.toml"
    OUT="$(/usr/bin/python3 -I "$HERE/theme-check.py" "$TMP/frames.json" "$theme" "$arg" 2>&1)"
    eq "theme $theme, palette $pal: every surface drew the spec's tokens" "$OUT" ""
  done
done
# the look of each theme, for the record
baneyspaces set theme.palette auto >/dev/null
for theme in omarchy baneyspaces minimal; do
  baneyspaces set theme.name $theme >/dev/null; baneyspaces dock show >/dev/null; sleep 0.9
  grim -g "$((960-480)),$((1080-170)) 960x170" "$TMP/shots/dock-$theme.png"; baneyspaces dock hide >/dev/null; sleep 0.3
done
baneyspaces set theme.name baneyspaces >/dev/null; sleep 0.4
baneyspaces launcher show >/dev/null; sleep 0.5; LQ type "libre" >/dev/null; sleep 0.7; grim -g "$((960-360)),150 720x480" "$TMP/shots/launcher-baneyspaces.png"; baneyspaces launcher hide >/dev/null; sleep 0.3
baneyspaces set theme.palette nord >/dev/null; sleep 0.4
baneyspaces overview show >/dev/null; sleep 0.9; grim -o $M1 "$TMP/shots/overview-baneyspaces-nord.png"; baneyspaces overview hide >/dev/null
baneyspaces set theme.name omarchy >/dev/null; baneyspaces set theme.palette auto >/dev/null; sleep 0.3
eq "the theme can be switched without a restart (the plugin reports it)" "$(qs_state .theme.name)" "omarchy"
eq "a bad theme is refused" "$(baneyspaces set theme.name glass | jq -r .error.code)" "invalid_args"
eq "a bad palette is refused" "$(baneyspaces set theme.palette nonsense | jq -r .error.code)" "invalid_args"

echo "== theme: live Omarchy colors, no restart"
cp "$TMP/theme/colors.toml" "$TMP/theme/colors.toml.bak"
sed -i 's/^accent = .*/accent = "#12ab34"/' "$TMP/theme/colors.toml"
check "a theme switch reaches the plugin without a restart" wait_for 6 sh -c "[ \"\$(qs ipc -p '$QSD/shell.qml' call baneyspaces state | jq -r .theme.accent)\" = '#12ab34' ]"
mv "$TMP/theme/colors.toml.bak" "$TMP/theme/colors.toml"
check "and back" wait_for 6 sh -c "[ \"\$(qs ipc -p '$QSD/shell.qml' call baneyspaces state | jq -r .theme.accent)\" != '#12ab34' ]"

echo "== agents may change anything in config.toml (and are logged); pressing your keys stays yours"
AOUT="$TMP/agent-set.out"; rm -f "$AOUT"
AR="$(baneyspaces agent run --agent-id looks -- sh -c "for kv in 'theme.name minimal' 'theme.palette nord' 'behavior.dock.enabled false' 'behavior.dock.enabled true' 'behavior.launcher.files false' 'animation.preset snappy'; do baneyspaces set \$kv; done > '$AOUT' 2>&1; baneyspaces switch 3 >> '$AOUT' 2>&1; baneyspaces ui >> '$AOUT' 2>&1; baneyspaces launcher search x >> '$AOUT' 2>&1; baneyspaces config >> '$AOUT' 2>&1; baneyspaces agent-status set working --window '$CL' >> '$AOUT' 2>&1; sleep 600")"
check "an agent process started" test -n "$(echo "$AR" | jq -r '.data.pid // empty')"
wait_for 8 test "$(wc -l < "$AOUT" 2>/dev/null || echo 0)" -ge 11
eq "an agent may set the theme, the palette, the dock switch, behavior and animation" "$(head -6 "$AOUT" | jq -r '.ok' | tr '\n' ' ')" "true true true true true true "
eq "…and workspace operations stay yours" "$(sed -n 7p "$AOUT" | jq -r '.error.code')" "not_in_scope"
eq "an agent does not get your window titles (ui)" "$(sed -n 8p "$AOUT" | jq -r '.error.code')" "not_in_scope"
eq "…or your files and packages (launcher search)" "$(sed -n 9p "$AOUT" | jq -r '.error.code')" "not_in_scope"
eq "…and reads the settings without the path of your config folder" "$(sed -n 10p "$AOUT" | jq -r '[.ok, (.data|has("path")), (.data.settings|has("path"))]|map(tostring)|join(",")')" "true,false,false"
eq "…and cannot put a status badge on your window" "$(sed -n 11p "$AOUT" | jq -r '.error.code')" "not_in_scope"
eq "the settings it made are in use" "$(baneyspaces config | jq -r '.data.settings.appearance.theme + "/" + .data.settings.appearance.palette + "/" + (.data.settings.launcher.files|tostring) + "/" + .data.settings.motion.preset')" "minimal/nord/false/snappy"
eq "the action log has a record for each change, with the caller's process" "$(baneyspaces agent log | jq '[.data.records[]|select(.verb=="config_set" and .pid != null)]|length')" "6"
baneyspaces set theme.name omarchy >/dev/null; baneyspaces set theme.palette auto >/dev/null; baneyspaces set behavior.launcher.files true >/dev/null; baneyspaces set animation.preset baneyspaces >/dev/null; baneyspaces agent-workspace hide >/dev/null

echo "== frame timing: the scene graph's own frameSwapped, 12 transitions per surface (spec/config.md quality bar)"
PQ() { QI baneyspaces.probe "$@"; }
probe_surface() { # probe_surface <name> <show command> <hide command>
  PQ start "$1" >/dev/null
  for _ in $(seq 1 12); do eval "$2" >/dev/null; sleep 0.35; eval "$3" >/dev/null; sleep 0.3; done
  PQ stop
}
FP="{}"
baneyspaces set animation.preset baneyspaces >/dev/null; baneyspaces set theme.name baneyspaces >/dev/null; sleep 0.3
for spec in "dock|baneyspaces dock show|baneyspaces dock hide" "overview|baneyspaces overview show|baneyspaces overview hide" "launcher|baneyspaces launcher show|baneyspaces launcher hide" "switcher|baneyspaces switcher next|baneyspaces switcher cancel"; do
  IFS='|' read -r nm sh hd <<<"$spec"
  R="$(probe_surface "$nm" "$sh" "$hd")"; echo "  $R"
  check "the probe saw frames of the $nm (a frameSwapped per frame drawn)" test "$(echo "$R" | jq -r '.intervals // 0')" -ge 10
  FP="$(jq -c --arg n "$nm" --argjson r "$R" '.[$n]=$r' <<<"$FP")"
done
baneyspaces set theme.name omarchy >/dev/null
echo "  (the nested session draws with Qt's software renderer on a headless 60 Hz output, so these numbers are the probe working, not a verdict on a GPU: untested live)"
echo "$FP" > "$TMP/frame-probe.json"

echo "== a tap of Alt+Tab or Super+Tab never needs the overlay; a hold shows it; the compositor sees the release"
check "the releases of Alt and Super are bound in the compositor" test "$(H binds | jq '[.[]|select(.release==true and ((.description//"")|startswith("BaneySpaces")))]|length')" = 8
baneyspaces focus-monitor $M1 >/dev/null; baneyspaces switch 1 >/dev/null; sleep 0.4
layer_up() { H layers | grep -c 'baneyspaces-switcher\|baneyspaces-overview'; }
watch_layers() { # watch_layers <seconds> <outfile>: the overlay layers present, sampled every 20 ms
  ( end=$(( $(date +%s%N) + $1 * 1000000000 )); : > "$2"; while [ "$(date +%s%N)" -lt "$end" ]; do layer_up >> "$2"; sleep 0.02; done ) &
}
expected_target() { baneyspaces switcher next >/dev/null; baneyspaces ui | jq -r '.data.switcher.items[1].window'; baneyspaces switcher cancel >/dev/null; }
tap() { # tap <ms>: Alt+Tab pressed and let go after <ms>
  hyprctl eval 'baneyspaces_press("alt", "switcher next")' >/dev/null; sleep "0.$(printf '%03d' $1)"; hyprctl eval 'baneyspaces_release("alt", "switcher commit")' >/dev/null
}
for ms in 30 120; do
  sleep 0.4; WANT="$(expected_target)"; sleep 0.3
  watch_layers 1.2 "$TMP/layers.txt"; tap $ms; sleep 0.7; wait
  eq "a ${ms} ms tap of Alt+Tab goes to the window you used before" "$(active)" "$WANT"
  eq "…with no overlay on screen at any moment" "$(sort -u "$TMP/layers.txt" | tr -d '\n')" "0"
  eq "…and nothing left open" "$(baneyspaces ui | jq -r .data.switcher.open)" "false"
done
sleep 0.4; WANT="$(expected_target)"; sleep 0.3
hyprctl eval 'baneyspaces_press("alt", "switcher next")' >/dev/null; sleep 0.5
eq "held past the threshold, the overlay is drawn" "$(baneyspaces ui | jq -r .data.switcher.visible)" "true"
check "…its layer is mapped" test "$(layer_up)" -ge 1
hyprctl eval 'baneyspaces_release("alt", "switcher commit")' >/dev/null; sleep 0.8
eq "letting go of Alt goes to the window" "$(active)" "$WANT"
eq "…and the overlay is gone" "$(layer_up)" "0"
sleep 0.4; WANT="$(expected_target)"; sleep 0.3
baneyspaces switcher commit >/dev/null; baneyspaces switcher next >/dev/null; sleep 0.6
eq "a release that overtook its press (two processes) still lands on the window" "$(active)" "$WANT"
hyprctl eval 'baneyspaces_release("alt", "switcher commit")' >/dev/null; sleep 0.2
eq "a release with no press of ours does nothing" "$(baneyspaces ui | jq -r .data.switcher.open)" "false"
baneyspaces switch 1 >/dev/null; sleep 0.4
watch_layers 1.0 "$TMP/layers.txt"; hyprctl eval 'baneyspaces_press("super", "overview next")' >/dev/null; sleep 0.04; hyprctl eval 'baneyspaces_release("super", "overview go")' >/dev/null; sleep 0.6; wait
eq "a 40 ms tap of Super+Tab goes to the next workspace, as Omarchy's did" "$(mon_ws $M1)" "2"
eq "…with no overview drawn" "$(sort -u "$TMP/layers.txt" | tr -d '\n')" "0"
baneyspaces switch 1 >/dev/null; sleep 0.4
hyprctl eval 'baneyspaces_press("super", "overview next")' >/dev/null; sleep 0.5
eq "held, the overview is drawn on the next workspace" "$(baneyspaces ui | jq -c '[.data.overview.visible,.data.overview.cursor]')" "[true,1]"
hyprctl eval 'baneyspaces_press("super", "overview next")' >/dev/null; sleep 0.3
eq "Tab again steps to the one after" "$(baneyspaces ui | jq -r .data.overview.cursor)" "2"
hyprctl eval 'baneyspaces_release("super", "overview go")' >/dev/null; sleep 0.8
eq "letting go of Super goes there" "$(mon_ws $M1)-$(baneyspaces ui | jq -r .data.overview.shown)" "3-false"
baneyspaces switch 1 >/dev/null; sleep 0.4
baneyspaces overview go >/dev/null; baneyspaces overview next >/dev/null; sleep 0.5
eq "a Super release that overtook its press lands on the next workspace" "$(mon_ws $M1)" "2"
baneyspaces switch 1 >/dev/null; sleep 0.3
baneyspaces overview next >/dev/null; sleep 0.3
eq "a peek overview nobody finishes is on screen until it times out (15 s), never forever" "$(baneyspaces ui | jq -r .data.overview.peek)" "true"
baneyspaces overview hide >/dev/null

echo "== a surface that is switched off gives its keys back to Omarchy"
baneyspaces focus-monitor $M1 >/dev/null; baneyspaces switch 1 >/dev/null; sleep 0.3
baneyspaces set behavior.switcher.enabled false >/dev/null; sleep 0.4
B4="$(active)"; SWF="$(baneyspaces switcher next)"
eq "Alt+Tab with the switcher off runs Omarchy's own cycle (no dead key)" "$(echo "$SWF" | jq -r '.ok,.data.fallback' | tr '\n' ' ')" "true omarchy: cycle_next "
sleep 0.4; check "…and the focused window changed" test "$(active)" != "$B4"
baneyspaces set behavior.switcher.enabled true >/dev/null
baneyspaces set behavior.launcher.enabled false >/dev/null; sleep 0.4
eq "Super+Space with the launcher off runs Omarchy's menu" "$(baneyspaces launcher toggle | jq -r '.ok,.data.fallback' | tr '\n' ' ')" "true omarchy-menu toggle "
baneyspaces set behavior.launcher.enabled true >/dev/null
baneyspaces set behavior.overview.enabled false >/dev/null; sleep 0.4
OVF="$(baneyspaces overview next)"
eq "Super+Tab with the overview off runs Omarchy's next workspace" "$(echo "$OVF" | jq -r '.ok,.data.fallback' | tr '\n' ' ')" "true omarchy: next workspace "
baneyspaces set behavior.overview.enabled true >/dev/null
baneyspaces focus-monitor $M1 >/dev/null; baneyspaces switch 1 >/dev/null; sleep 0.3

echo "== config.toml: a hand edit is kept, a broken file is never overwritten, a hand edit applies live"
CFG="$XDG_CONFIG_HOME/baneyspaces/config.toml"
printf '\n# my edit\n[behavior.launcher]\nfiles = false\n' >> "$CFG"
baneyspaces set behavior.dock.size small >/dev/null
eq "set right after a hand edit keeps the edit" "$(baneyspaces config | jq -r '[.data.settings.launcher.files,.data.settings.dock.size]|map(tostring)|join(",")')" "false,small"
check "…and its comment" grep -q '# my edit' "$CFG"
baneyspaces set behavior.launcher.files true >/dev/null; baneyspaces set behavior.dock.size medium >/dev/null
cp "$CFG" "$TMP/config.good"
printf '[behavior.dock\nsize = "large\n# my notes\n' > "$CFG"; cp "$CFG" "$TMP/config.broken"; sleep 1.3
BR="$(baneyspaces set behavior.dock.size large)"
eq "a file with a syntax error refuses set, naming the problem" "$(echo "$BR" | jq -r '.error.code')" "config_invalid"
check "…with the parse error" sh -c "echo '$(echo "$BR" | jq -r .error.message | tr "'" ' ')' | grep -q 'syntax error'"
check "…and the file is as the person left it" cmp -s "$CFG" "$TMP/config.broken"
eq "the daemon keeps running on the last good settings" "$(baneyspaces config | jq -r '.data.settings.dock.size')" "medium"
printf 'behavior = false\n' > "$CFG"; sleep 1.3
SC="$(baneyspaces set behavior.dock.size large)"
eq "a value where a table belongs is a typed error, not a crash" "$(echo "$SC" | jq -r '.error.code')" "config_invalid"
check "…and the daemon answers afterwards" sh -c "baneyspaces ping 2>/dev/null; baneyspaces state | jq -e .ok"
cp "$TMP/config.good" "$CFG"; sleep 1.3
printf '\n[animation.workspace]\nstyle = "fade"\n' >> "$CFG"
check "animation.workspace.style = fade, written by hand, reaches Hyprland within two seconds" wait_for 3 sh -c "[ \"\$(hyprctl -j animations | jq -r '[.[0][]|select(.name==\"workspaces\")|.enabled]|first')\" = true ]"
/usr/bin/python3 -I "$HERE/cfg-drop.py" "$CFG" animation.workspace
check "…and taking it out of the file puts it back" wait_for 3 sh -c "[ \"\$(hyprctl -j animations | jq -r '[.[0][]|select(.name==\"workspaces\")|.enabled]|first')\" = false ]"

echo "== anything opened from a workspace lands on that workspace"
APPS="$HOME/.local/share/applications"; mkdir -p "$APPS"
cat > "$APPS/bs-newapp.desktop" <<EOT
[Desktop Entry]
Name=BS Fresh Test App
Exec=foot -a bs-fresh -T freshwin sleep 600
StartupWMClass=bs-fresh
EOT
cat > "$APPS/bs-multi.desktop" <<EOT
[Desktop Entry]
Name=BS Multi Test App
Exec=foot -a bs-multi -T multiwin sleep 600
StartupWMClass=bs-multi
[Desktop Action new-window]
Name=New Window
Exec=foot -a bs-multi -T multinew sleep 600
EOT
cat > "$APPS/bs-single.desktop" <<EOT
[Desktop Entry]
Name=BS Single Test App
Exec=/bin/true
StartupWMClass=bs-single
EOT
sleep 3.2
goto $M1 8; mkdir -p "$TMP/hold"
nwin() { H clients | jq "[.[]|select(.class==\"$1\" and .workspace.name==\"$2\")]|length"; }
run_app() { baneyspaces launcher search "$1" --mode apps >/dev/null; baneyspaces launcher run "app:$2" "${@:3}"; }
run_app "BS Fresh" bs-newapp >/dev/null; sleep 1.2
eq "an app that is not running starts on the workspace you are on" "$(nwin bs-fresh 8)" "1"
goto $M1 2; mkwin bs-multi multiwin; mkwin bs-single singlewin; SING="$(addr_of singlewin)"
goto $M1 8
run_app "BS Multi" bs-multi >/dev/null; sleep 1.2
eq "a running app that can make another window gets a new one here (its new-window action)" "$(nwin bs-multi 8)" "1"
eq "…and the one it had stays where it was" "$(nwin bs-multi 2)" "1"
eq "you stay on the workspace you opened it from" "$(mon_ws $M1)" "8"
run_app "BS Single" bs-single >/dev/null; sleep 2.0
eq "an app with a single window has that window moved here" "$(client_ws $SING)" "8"
eq "…and you stay on the target" "$(mon_ws $M1)" "8"
run_app "BS Multi" bs-multi >/dev/null; sleep 0.8
eq "an app that already has a window here just brings it forward (no second one)" "$(nwin bs-multi 8)" "1"
goto $M1 2; mkwin bs-single singlewin2; SING2="$(addr_of singlewin2)"; goto $M1 7
run_app "BS Single" bs-single --alt >/dev/null; sleep 1.0
eq "the modifier goes to where the app already is" "$(mon_ws $M1)" "2"
goto $M1 7; baneyspaces set behavior.launcher.open go >/dev/null; sleep 0.4
run_app "BS Single" bs-single >/dev/null; sleep 1.0
eq "with behavior.launcher.open = go the plain key goes there" "$(mon_ws $M1)" "2"
goto $M1 7; run_app "BS Single" bs-single --alt >/dev/null; sleep 2.0
eq "…and the modifier then opens here" "$(nwin bs-single 7)" "1"
baneyspaces set behavior.launcher.open here >/dev/null
check "a dry run says what would happen (a new window here)" test "$(baneyspaces launcher search 'BS Multi' --mode apps >/dev/null; baneyspaces launcher run app:bs-multi --dry-run | jq -r '.data.would_run|join(" ")')" = "foot -a bs-multi -T multinew sleep 600"
rm -f "$APPS"/bs-*.desktop
goto $M1 1

echo "== launcher results belong to the search that made them"
S1="$(baneyspaces launcher search foot --mode apps | jq -r '.data.seq')"; S2="$(baneyspaces launcher search chrom --mode apps | jq -r '.data.seq')"
check "each search has its own number, rising" test "$S2" -gt "$S1"
eq "a result of the older search is refused once a newer one exists" "$(baneyspaces launcher run app:foot --dry-run --seq "$S1" 2>&1 | jq -r '.error.code // "ran"')" "not_found"

echo "== the shell stayed healthy"
check "quickshell is still running" kill -0 $QSPID
check "no QML errors in its log" sh -c "! sed 's/\x1b\[[0-9;]*m//g' '$TMP/quickshell.log' | grep -E 'ReferenceError|TypeError|is not a type|unavailable|Binding loop|Cannot ' "
check "the daemon logged no panic" sh -c "! grep -q panicked '$TMP/daemon.log'"
if [ -n "${SAVE_SHOTS:-}" ]; then mkdir -p "$HERE/shots"; cp "$TMP"/shots/*.png "$HERE/shots/"; echo "  shots saved to platforms/linux/tests/shots/"; fi

# put the session back: close the windows, one workspace on each display
for a in $(H clients | jq -r '.[]|select(.workspace.name!="special:agent")|.address'); do hyprctl dispatch "hl.dsp.window.close({ window = \"address:$a\" })" >/dev/null; done
baneyspaces focus-monitor $M1 >/dev/null; baneyspaces switch 1 >/dev/null; baneyspaces focus-monitor $M2 >/dev/null; baneyspaces switch 2 >/dev/null; baneyspaces focus-monitor $M1 >/dev/null; sleep 0.3
