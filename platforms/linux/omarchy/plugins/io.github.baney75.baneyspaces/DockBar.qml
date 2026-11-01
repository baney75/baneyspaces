import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import "Logic.js" as Logic

// The bar itself: a tile for each workspace in use (plus the one you are on), the dashed tile for a new
// workspace, and two small buttons for the launcher and the overview.
PanelWindow {
  id: win
  required property var host
  required property var bs
  readonly property var dock: bs.st.dock || ({})
  readonly property bool autoHide: bs.dockCfg.auto_hide !== false
  readonly property bool wanted: bs.connected && bs.dockCfg.enabled !== false && host.screen !== null
    && (autoHide ? (dock.up === true && host.screen && dock.monitor === host.screen.name) : true)
  readonly property var spec: host.spec
  readonly property var th: bs.theme
  readonly property real originX: screen ? (screen.width - barBg.width) / 2 : 0
  readonly property real originY: screen ? screen.height - host.edgeGap - barBg.height : 0
  property var tileItems: ({})

  screen: host.screen
  visible: wanted || layer.opacity > 0.01
  color: "transparent"
  anchors.bottom: true
  implicitWidth: barBg.width + th.shadowPad * 2
  implicitHeight: barBg.height + host.edgeGap + th.shadowPad
  exclusionMode: autoHide ? ExclusionMode.Ignore : ExclusionMode.Auto
  WlrLayershell.namespace: "baneyspaces-dock"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  mask: Region { item: barBg }

  onWantedChanged: if (!wanted) host.closeList()
  Connections { target: layer.Window.window; function onFrameSwapped() { bs.probeTick("dock") } }
  function publish() { host.barRect = { x: originX, y: originY, w: barBg.width, h: barBg.height } }
  onOriginXChanged: publish()
  onOriginYChanged: publish()
  Component.onCompleted: publish()

  // ---- geometry for the drag and for tests, in screen-local points
  function screenRect(item) {
    var p = item.mapToItem(barBg, 0, 0)
    return { x: originX + p.x, y: originY + p.y, w: item.width, h: item.height }
  }
  function tileRects() {
    var out = []
    for (var n in tileItems) if (tileItems[n]) { var r = screenRect(tileItems[n]); r.n = Number(n); out.push(r) }
    return out
  }
  function tileAt(x, y) {
    var rects = tileRects()
    var i = Logic.pickRect(rects, x, y)
    return i < 0 ? null : rects[i].n
  }
  function tileCenter(n) { var t = tileItems[n]; if (!t) return null; var r = screenRect(t); return { x: r.x + r.w / 2, y: r.y + r.h / 2 } }
  function iconCenter(n, app) {
    var t = tileItems[n]
    var it = t ? t.iconFor(app) : null
    if (!it) return null
    var r = screenRect(it)
    return { x: r.x + r.w / 2, y: r.y + r.h / 2 }
  }
  // What the bar and its tiles drew, for the theme check.
  function framesUsed() {
    var out = [{ surface: "dock", frame: barBg.used }]
    for (var n in tileItems) if (tileItems[n] && tileItems[n].frame) out.push({ surface: "dock-tile", frame: tileItems[n].frame.used })
    return out
  }
  function describeTiles() {
    return tileRects().map(function (r) {
      var ws = bs.st.workspaces[r.n - 1]
      return { n: r.n, x: r.x, y: r.y, w: r.w, h: r.h, apps: r.n > 0 ? ws.apps.map(function (a) { return a.app }) : [] }
    })
  }
  function clickTile(n) { bs.call("switch", { n: n > 0 ? n : (dock.new_target || 1) }) }
  function clickApp(n, app) {
    var ws = bs.st.workspaces[n - 1]
    var a = ws ? ws.apps.filter(function (x) { return x.app === app })[0] : null
    if (!a) return "no such app"
    bs.call("focus", { window: Logic.nextWindow(a.windows, bs.st.active) })
    return "ok"
  }
  function openListFor(n, kind) {
    var t = tileItems[n]
    return t ? t.openList(kind) : "no such tile"
  }

  Item {
    id: layer
    anchors.fill: parent
    opacity: win.wanted ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: win.wanted ? bs.motion.dockIn : bs.motion.dockOut; easing.type: Easing.OutCubic } }

    Item {
      id: slider
      width: parent.width
      height: parent.height
      y: win.wanted ? 0 : bs.motion.slide
      Behavior on y { NumberAnimation { duration: win.wanted ? bs.motion.dockIn : bs.motion.dockOut; easing.type: Easing.OutCubic } }

      PanelFrame {
        id: barBg
        th: win.th
        kind: "bar"
        shadowed: true
        anchors.bottom: parent.bottom
        anchors.bottomMargin: host.edgeGap
        anchors.horizontalCenter: parent.horizontalCenter
        width: row.width + th.tok.space.padding * 2
        height: row.height + th.tok.space.padding * 2

        Row {
          id: row
          anchors.centerIn: parent
          spacing: spec.gap

          Repeater {
            model: win.dock.tiles || []
            delegate: Item {
              id: tile
              required property int modelData
              readonly property int n: modelData
              readonly property var ws: bs.st.workspaces ? bs.st.workspaces[n - 1] : null
              readonly property bool current: ws ? ws.current === true : false
              readonly property bool otherScreen: ws ? (ws.shown_on || []).length > 0 && !current : false
              readonly property bool hot: host.drag !== null && host.drag.hot === n
              readonly property color wsColor: th.palette[(n - 1) % 9]
              width: Math.max(spec.icon + spec.pad * 2, icons.width + spec.pad * 2)
              height: spec.height
              readonly property var frame: tileFrame
              Component.onCompleted: { var t = win.tileItems; t[n] = tile; win.tileItems = t }
              Component.onDestruction: { var t = win.tileItems; delete t[n]; win.tileItems = t }

              function iconFor(app) {
                for (var i = 0; i < repIcons.count; i++) { var it = repIcons.itemAt(i); if (it && it.app.app === app) return it }
                return null
              }
              function openList(kind) {
                if (!ws) return "no workspace"
                if (kind === "more") {
                  if (!ws.more.length) return "nothing to list"
                  host.openList(win.moreList(tile, ws))
                  return "ok"
                }
                var a = ws.apps.filter(function (x) { return x.app === kind })[0]
                if (!a) return "no such app"
                host.openList(win.stripList(tile, ws, a))
                return "ok"
              }

              PanelFrame {
                id: tileFrame
                th: win.th
                kind: "tile"
                anchors.fill: parent
                focused: tile.hot || tile.current
                tint: tile.wsColor
                fillColor: tile.hot ? Logic.alpha(th.accent, 0.34) : tile.current ? Logic.alpha(th.accent, 0.20) : th.raised
              }
              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function (m) {
                  if (m.button === Qt.RightButton) host.openList(win.menuList(tile, ws))
                  else bs.call("switch", { n: tile.n })
                }
              }
              Column {
                anchors.centerIn: parent
                spacing: 4
                Row {
                  id: icons
                  spacing: 4
                  anchors.horizontalCenter: parent.horizontalCenter
                  height: spec.icon
                  Repeater {
                    id: repIcons
                    model: tile.ws ? tile.ws.shown_apps : []
                    delegate: AppIcon {
                      id: ai
                      required property var modelData
                      bs: win.bs
                      app: modelData
                      size: spec.icon
                      onClicked: bs.call("focus", { window: Logic.nextWindow(modelData.windows, bs.st.active) })
                      onRightClicked: host.openList(win.appMenu(tile, tile.ws, modelData))
                      onHovered: function (inside) {
                        if (modelData.count > 1) host.hoverTrigger(inside, win.stripList(tile, tile.ws, modelData))
                        else host.hoverTrigger(false, null)
                      }
                      onDragBegan: function (x, y) { var p = ai.mapToItem(barBg, x, y); host.beginDrag(modelData.app, bs.iconFor(modelData.app), modelData.windows.map(function (w) { return w.window }), win.originX + p.x, win.originY + p.y) }
                      onDragMoved: function (x, y) { var p = ai.mapToItem(barBg, x, y); host.moveDrag(win.originX + p.x, win.originY + p.y) }
                      onDragEnded: host.endDrag()
                    }
                  }
                  AppIcon {
                    id: moreChip
                    visible: tile.ws !== null && tile.ws.more.length > 0
                    bs: win.bs
                    chip: true
                    size: spec.icon
                    label: Logic.moreLabel(tile.ws ? tile.ws.more.length : 0)
                    onHovered: function (inside) { host.hoverTrigger(inside, inside ? win.moreList(tile, tile.ws) : null) }
                  }
                  // an empty workspace you are on or that a display shows
                  Text {
                    visible: tile.ws !== null && tile.ws.apps.length === 0
                    height: spec.icon
                    verticalAlignment: Text.AlignVCenter
                    text: "empty"
                    color: th.dim
                    font.family: th.fontFamily
                    font.pixelSize: spec.num
                  }
                }
                Indicator {
                  anchors.horizontalCenter: parent.horizontalCenter
                  th: win.th
                  n: tile.n
                  current: tile.current
                  tint: tile.wsColor
                  size: spec.num
                }
              }
            }
          }

          // The dashed tile: drop here to start a new workspace with the window; click to go to the first empty one.
          Item {
            id: newTile
            readonly property bool hot: host.drag !== null && host.drag.hot === 0
            visible: win.dock.new_target !== null && win.dock.new_target !== undefined
            width: spec.icon + spec.pad * 2
            height: spec.height
            Component.onCompleted: { var t = win.tileItems; t[0] = newTile; win.tileItems = t }
            Rectangle { anchors.fill: parent; radius: spec.radius; color: newTile.hot ? Logic.alpha(th.accent, 0.30) : "transparent" }
            Shape {
              anchors.fill: parent
              layer.enabled: true
              layer.samples: 4
              ShapePath {
                strokeColor: newTile.hot ? th.accent : Logic.alpha(th.fg, 0.45)
                strokeWidth: 1.5
                strokeStyle: ShapePath.DashLine
                dashPattern: [3, 3]
                fillColor: "transparent"
                startX: spec.radius; startY: 1
                PathLine { x: newTile.width - spec.radius; y: 1 }
                PathArc { x: newTile.width - 1; y: spec.radius; radiusX: spec.radius - 1; radiusY: spec.radius - 1 }
                PathLine { x: newTile.width - 1; y: newTile.height - spec.radius }
                PathArc { x: newTile.width - spec.radius; y: newTile.height - 1; radiusX: spec.radius - 1; radiusY: spec.radius - 1 }
                PathLine { x: spec.radius; y: newTile.height - 1 }
                PathArc { x: 1; y: newTile.height - spec.radius; radiusX: spec.radius - 1; radiusY: spec.radius - 1 }
                PathLine { x: 1; y: spec.radius }
                PathArc { x: spec.radius; y: 1; radiusX: spec.radius - 1; radiusY: spec.radius - 1 }
              }
            }
            Text {
              anchors.centerIn: parent
              text: "+"
              color: newTile.hot ? th.accent : th.dim
              font.family: th.fontFamily
              font.pixelSize: spec.icon * 0.7
            }
            // Opening the new workspace: you are on it, and what you open next lands on it
            MouseArea { anchors.fill: parent; onClicked: { bs.call("switch", { n: win.dock.new_target }); openLauncher.restart() } }
            Timer { id: openLauncher; interval: 160; onTriggered: bs.call("launcher", { action: "show" }) }
          }

          Rectangle { width: 1; height: spec.height * 0.6; anchors.verticalCenter: parent.verticalCenter; color: th.tok.roles.border }

          // Launcher and overview.
          Column {
            spacing: 6
            anchors.verticalCenter: parent.verticalCenter
            Repeater {
              model: [{ id: "launcher", tip: "Launcher" }, { id: "overview", tip: "All workspaces" }]
              delegate: Rectangle {
                id: btn
                required property var modelData
                width: spec.height / 2 - 3
                height: width
                radius: th.tok.radius.row
                color: ma.containsMouse ? th.raisedHot : th.raised
                // magnifier / 2x2 grid, drawn so it needs no icon font
                Rectangle { visible: btn.modelData.id === "launcher"; x: width * 0.0 + btn.width * 0.26; y: btn.height * 0.24; width: btn.width * 0.38; height: width; radius: width / 2; color: "transparent"; border.color: th.text; border.width: 1.6 }
                Rectangle { visible: btn.modelData.id === "launcher"; x: btn.width * 0.58; y: btn.height * 0.6; width: btn.width * 0.26; height: 1.8; radius: 1; /* structural */ color: th.text; rotation: 45; transformOrigin: Item.Left }
                Grid {
                  visible: btn.modelData.id === "overview"
                  anchors.centerIn: parent
                  columns: 2
                  spacing: 2
                  Repeater { model: 4; Rectangle { width: btn.width * 0.26; height: width; radius: 2; /* structural */ color: th.text } }
                }
                MouseArea {
                  id: ma
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: bs.call(btn.modelData.id, { action: "toggle" })
                }
              }
            }
          }
        }
      }
    }
  }

  // ---- list contents
  function appRow(a) {
    return { title: bs.nameFor(a.app), sub: a.count > 1 ? a.count + " windows" : "", icon: bs.iconFor(a.app), app: a.app, windows: a.windows.map(function (w) { return w.window }), badge: a.badge, act: "focus" }
  }
  function moreList(tile, ws) {
    return { kind: "more", n: tile.n, trigger: screenRect(tile), rows: ws.more.map(appRow) }
  }
  function stripList(tile, ws, a) {
    return { kind: "strip", n: tile.n, trigger: screenRect(tile), rows: a.windows.map(function (w) {
      return { title: Logic.rowTitle({ title: w.title, app: a.app }), sub: "workspace " + tile.n, icon: bs.iconFor(a.app), app: a.app, windows: [w.window], badge: w.badge, act: "focus" } }) }
  }
  function menuList(tile, ws) {
    return { kind: "menu", n: tile.n, trigger: screenRect(tile), rows: [
      { title: "Go to workspace " + tile.n, sub: "", icon: "", ws: tile.n, act: "switch" },
      { title: "Move the front window here", sub: "", icon: "", ws: tile.n, act: "move_front" } ] }
  }
  function appMenu(tile, ws, a) {
    var ids = a.windows.map(function (w) { return w.window })
    return { kind: "menu", n: tile.n, trigger: screenRect(tile), rows: [
      { title: "Show " + bs.nameFor(a.app), sub: "", icon: bs.iconFor(a.app), windows: ids, act: "focus" },
      { title: a.count > 1 ? "Close all " + a.count + " windows" : "Close window", sub: "", icon: "", windows: ids, act: "close" } ] }
  }
}
