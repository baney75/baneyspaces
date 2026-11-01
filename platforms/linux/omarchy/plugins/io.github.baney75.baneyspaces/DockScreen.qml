import QtQuick
import Quickshell
import "Logic.js" as Logic

// One display's dock: the bar, its lists, and the drag ghost, plus the rules that tie them together.
// Rules that keep the Mac's regressions fixed (spec/ui.md R-D*): the keep zone is the bar (the daemon
// measures it from what this reports); a list is a window of its own, so the bar never moves when one
// opens; a list closes 250 ms after the pointer leaves it and its trigger; motion is scoped to one layer.
Scope {
  id: root
  required property var bs
  property var screen: null

  readonly property var spec: Logic.tileSpecFor(bs.theme.tok, bs.dockCfg.size || "medium")
  readonly property int edgeGap: 8
  property var barRect: ({ x: 0, y: 0, w: 0, h: 0 })
  property var listRect: null
  // { kind: "more" | "strip" | "menu", n, rows: [{ title, sub, icon, app, windows, ws, badge, act }], trigger: {x,y,w,h} }
  property var listState: null
  // { label, icon, windows, x, y, hot }  (x, y are screen-local)
  property var drag: null
  property bool triggerHover: false
  property bool listHover: false
  property var pending: null
  property string lastReport: ""

  DockBar { id: bar; host: root; bs: root.bs }
  DockList { id: list; host: root; bs: root.bs }
  DragGhost { host: root; bs: root.bs }

  Timer { id: grace; interval: 250; onTriggered: root.closeList() }
  Timer { id: opener; interval: 220; onTriggered: if (root.pending) root.openList(root.pending) }

  // ---- what the daemon needs to know to keep the dock up exactly as long as it should
  function reportGeometry() {
    if (!screen) return
    var up = bs.st.dock && bs.st.dock.up && bs.st.dock.monitor === screen.name
    var msg = { monitor: screen.name, bar: up ? barRect : null, list: up && listRect ? listRect : null }
    var key = JSON.stringify(msg)
    if (key === lastReport) return
    lastReport = key
    bs.call("dock_bar", msg)
  }
  onBarRectChanged: reportGeometry()
  onListRectChanged: reportGeometry()
  Connections { target: bs; function onStChanged() { root.reportGeometry() } }

  // ---- lists
  // Where the tile that opened a list is now (the bar may have re-laid out since). `dep` makes a binding re-run.
  function triggerRect(n, dep) {
    var t = bar.tileItems[n]
    return t ? bar.screenRect(t) : { x: barRect.x, y: barRect.y, w: 0, h: barRect.h }
  }
  function hoverTrigger(inside, spec) {
    triggerHover = inside
    if (inside) {
      grace.stop()
      pending = spec
      if (listState) openList(spec); else opener.restart()
    } else {
      opener.stop()
      if (listState && !listHover) grace.restart()
    }
  }
  function listHovered(inside) {
    listHover = inside
    if (inside) grace.stop(); else if (listState && !triggerHover) grace.restart()
  }
  function openList(state) { opener.stop(); listState = state }
  function closeList() { grace.stop(); opener.stop(); listState = null; listHover = false; listRect = null }

  function runRow(row) {
    closeList()
    var act = row.act || "focus"
    if (act === "focus" && row.windows && row.windows.length) bs.call("focus", { window: row.windows[0] })
    else if (act === "switch") bs.call("switch", { n: row.ws })
    else if (act === "move_front") bs.call("move_windows", { n: row.ws, windows: bs.st.active ? [bs.st.active] : [] })
    else if (act === "close") bs.call("window_close", { windows: row.windows || [] })
  }

  // ---- dragging an app (or one window out of a list) onto a tile
  function beginDrag(label, icon, windows, x, y) {
    bs.call("dock", { action: "hold", reason: "drag" })
    drag = { label: label, icon: icon, windows: windows, x: x, y: y, hot: null }
  }
  function moveDrag(x, y) {
    if (!drag) return
    var hit = bar.tileAt(x, y)
    drag = { label: drag.label, icon: drag.icon, windows: drag.windows, x: x, y: y, hot: hit }
  }
  function endDrag() {
    var d = drag
    drag = null
    bs.call("dock", { action: "release", reason: "drag" })
    if (d && d.hot !== null && d.hot !== undefined && d.windows.length)
      bs.call("move_windows", { n: d.hot === 0 ? "new" : d.hot, windows: d.windows })
  }

  function framesUsed() { return bar.framesUsed().concat(list.framesUsed()) }

  // ---- hooks the IPC handler (and tests) use: the pointer's paths without a pointer
  function describe() {
    return { screen: screen ? screen.name : "", visible: bar.visible, wanted: bar.wanted, bar: barRect,
      tiles: bar.describeTiles(), list: listState ? { kind: listState.kind, rows: listState.rows.map(function (r) { return r.title }), rect: listRect } : null,
      drag: drag ? { hot: drag.hot, windows: drag.windows } : null }
  }
  function clickTile(n) { bar.clickTile(n); return "ok" }
  function clickApp(n, app) { return bar.clickApp(n, app) }
  function openListFor(n, kind) { return bar.openListFor(n, kind) }
  function dragApp(n, app, to) {
    var from = bar.iconCenter(n, app)
    var dest = bar.tileCenter(to)
    if (!from || !dest) return "no such tile or app"
    var ws = bs.st.workspaces[n - 1]
    var a = ws.apps.filter(function (x) { return x.app === app })[0]
    beginDrag(app, bs.iconFor(app), a.windows.map(function (w) { return w.window }), from.x, from.y)
    moveDrag(dest.x, dest.y)
    var hot = drag ? drag.hot : null
    endDrag()
    return "dropped on " + hot
  }
  function dragRow(index, to) {
    if (!listState) return "no list"
    var row = listState.rows[index]
    var dest = bar.tileCenter(to)
    if (!row || !dest) return "no such row or tile"
    beginDrag(row.title, row.icon, row.windows || [], dest.x, dest.y)
    moveDrag(dest.x, dest.y)
    var hot = drag ? drag.hot : null
    endDrag()
    closeList()
    return "dropped on " + hot
  }
}
