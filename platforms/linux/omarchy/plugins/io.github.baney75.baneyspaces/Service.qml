import QtQuick
import Quickshell
import Quickshell.Io
import "Logic.js" as Logic

// BaneySpaces on the Omarchy shell: the Workspace Dock, the Alt+Tab switcher, the launcher, the overview
// and the settings panel. Everything they show comes from `baneyspaces daemon` (see Daemon.qml); every
// action goes back to it. Nothing here decides a workspace rule.
Item {
  id: root
  visible: false

  // Injected by omarchy-shell; not needed.
  property var shell: null

  readonly property var st: daemon.state || ({})
  readonly property var cfg: st.config || ({})
  readonly property var dockCfg: cfg.dock || ({})
  readonly property bool connected: daemon.connected
  property bool systemReducesMotion: false
  // animation.respect_reduce_motion: instant when the desktop asks for it.
  readonly property bool reduceMotion: cfg.motion ? (cfg.motion.respect_reduce !== false && systemReducesMotion) : false
  readonly property var motion: theme.motion
  property alias daemon: daemon
  property alias theme: theme

  function call(op, args, done) { daemon.call(op, args || {}, done) }

  // ---- the frame-timing probe (spec/config.md, animation quality bar): the scene graph's own frameSwapped, per surface.
  // Frames of one transition are close together; a gap over 120 ms is idle time between transitions and is not counted.
  property string probeName: ""
  property var probeStamps: []
  function probeTick(name) { if (probeName === name) probeStamps.push(Date.now()) }
  function probeStats() {
    var iv = []
    for (var i = 1; i < probeStamps.length; i++) { var d = probeStamps[i] - probeStamps[i - 1]; if (d <= 120) iv.push(d) }
    if (iv.length < 3) return { surface: probeName, frames: probeStamps.length, intervals: iv.length }
    var sorted = iv.slice().sort(function (a, b) { return a - b })
    var med = sorted[Math.floor(sorted.length / 2)]
    var late = 0, very = 0
    iv.forEach(function (d) { if (d > 1.5 * med) late++; if (d > 2 * med) very++ })
    return { surface: probeName, frames: probeStamps.length, intervals: iv.length, median_ms: med, late_1_5x: late, late_2x: very, late_per_200: Math.round(late / iv.length * 200 * 10) / 10 }
  }


  // The icon a window's app would have in the launcher.
  function iconFor(appClass) {
    if (!appClass) return "application-x-executable"
    var e = DesktopEntries.heuristicLookup(appClass)
    return e && e.icon ? e.icon : appClass.toLowerCase()
  }
  // The name a person knows an app by (its launcher entry), else its window class.
  function nameFor(appClass) {
    var e = appClass ? DesktopEntries.heuristicLookup(appClass) : null
    return e && e.name ? e.name : (appClass || "")
  }
  function iconSource(name) {
    if (name && name.indexOf("/") === 0) return "file://" + name
    // check = true: an icon the theme does not have is "" (the caller draws a letter or a glyph), never the checker pattern
    return Quickshell.iconPath(name || "application-x-executable", true)
  }

  Daemon { id: daemon }
  Theme { id: theme; appearance: root.cfg.appearance || ({}); motionCfg: root.cfg.motion || ({}); reduce: root.reduceMotion }

  // `auto` follows the desktop's own animation switch.
  Process {
    id: anim
    command: ["gsettings", "get", "org.gnome.desktop.interface", "enable-animations"]
    stdout: StdioCollector { onStreamFinished: root.systemReducesMotion = text.trim() === "false" }
  }
  Timer { interval: 30000; repeat: true; running: true; triggeredOnStart: true; onTriggered: anim.running = true }

  Dock { id: dock; bs: root }
  Switcher { id: switcher; bs: root }
  Launcher { id: launcher; bs: root }
  Overview { id: overview; bs: root }
  SettingsPanel { id: settings; bs: root }

  // The theme check: what every surface drew, next to what the theme says (platforms/linux/tests/shell.sh).
  IpcHandler {
    target: "baneyspaces.probe"
    function start(name: string): string { root.probeStamps = []; root.probeName = name; return "ok" }
    function stop(): string { var r = root.probeStats(); root.probeName = ""; return JSON.stringify(r) }
  }

  IpcHandler {
    target: "baneyspaces.theme"
    function frames(): string {
      var all = [].concat(dock.framesUsed(), switcher.framesUsed(), launcher.framesUsed(), overview.framesUsed(), settings.framesUsed())
      return JSON.stringify({ theme: theme.tok.theme, palette: theme.tok.palette, mode: theme.tok.mode, roles: theme.roles, tints: theme.tok.tints,
        font: theme.fontFamily, fontSize: theme.fs(12), indicator: theme.tok.indicator, motion: theme.tok.motion, frames: all })
    }
  }

  IpcHandler {
    target: "baneyspaces"
    function state(): string { return JSON.stringify({ connected: root.connected, reduceMotion: root.reduceMotion, theme: { name: theme.tok.theme, palette: theme.tok.palette, bg: theme.bg, fg: theme.fg, accent: theme.accent, font: theme.fontFamily }, ws: root.st.workspaces ? root.st.workspaces.length : 0, motion: theme.motion }) }
    function ping(): string { return "ok" }
  }
}
