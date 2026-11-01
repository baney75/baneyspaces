import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "Logic.js" as Logic

// "Show All Workspaces": the nine workspaces in the same 3 x 3 grid as the number keys, every window as a
// preview (a live-ish capture where Hyprland offers one, else its icon and title). Click a workspace or press
// its number to go there, click a window to go to it, drag a window onto another workspace to move it.
Item {
  id: root
  visible: false
  required property var bs

  // The daemon keeps the highlight (0-based) so Super+Tab, Tab and the arrow keys agree.
  readonly property int cursor: (bs.st.overview || {}).cursor || 0
  readonly property bool peek: (bs.st.overview || {}).peek === true
  property var drag: null            // { window, title, icon, x, y, hot }
  readonly property var ocfg: bs.cfg.overview || ({})

  // The capture handle of a window, if the compositor will give one.
  function toplevelFor(addr) {
    if (ocfg.thumbnails === false) return null
    try {
      var list = Hyprland.toplevels.values
      for (var i = 0; i < list.length; i++) if ("0x" + list[i].address === addr) return list[i].wayland
    } catch (e) {}
    return null
  }
  function framesUsed() { return screensV.instances.length ? screensV.instances[0].framesUsed() : [] }
  function close() { bs.call("overview", { action: "hide" }) }
  // The overview holds the keyboard; let it go first, then act (Hyprland refocuses your old window when a
  // surface lets go, which would undo the switch if it came first).
  property var afterClose: null
  Timer { id: settle; interval: 140; onTriggered: { var f = root.afterClose; root.afterClose = null; if (f) f() } }
  function closeThen(fn) { afterClose = fn; close(); settle.restart() }
  function go(n) { closeThen(function () { bs.call("switch", { n: n }) }) }
  function dropOn(n) {
    var d = drag
    drag = null
    if (d && n !== null && n >= 1) bs.call("move_windows", { n: n, windows: [d.window] })
  }

  Variants {
    id: screensV
    model: Quickshell.screens
    PanelWindow {
      id: win
      required property var modelData
      readonly property var th: root.bs.theme
      readonly property bool wanted: root.bs.st.overview !== undefined && root.bs.st.overview.shown === true
        && root.ocfg.enabled !== false && root.bs.st.focused_monitor === modelData.name
      property var cards: ({})
      screen: modelData
      visible: wanted || scrim.opacity > 0.01
      color: "transparent"
      anchors { left: true; right: true; top: true; bottom: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "baneyspaces-overview"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: wanted ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      Connections { target: keys.Window.window; function onFrameSwapped() { root.bs.probeTick("overview") } }
      onWantedChanged: if (wanted) keys.forceActiveFocus()

      function cardRects() {
        var out = []
        for (var n in cards) if (cards[n]) { var c = cards[n]; out.push({ x: c.x + grid.x, y: c.y + grid.y, w: c.width, h: c.height, n: Number(n) }) }
        return out
      }
      function framesUsed() { var out = []; for (var n in cards) if (cards[n]) out.push({ surface: n === "1" ? "overview" : "overview-card", frame: cards[n].used }); return out }
      function cardAt(x, y) { var r = cardRects(); var i = Logic.pickRect(r, x, y); return i < 0 ? null : r[i].n }
      function describe() {
        return { wanted: wanted, visible: visible, cards: cardRects().map(function (r) { var ws = root.bs.st.workspaces[r.n - 1]; return { n: r.n, x: r.x, y: r.y, w: r.w, h: r.h, windows: ws.windows.map(function (w) { return w.window }) } }), cursor: root.cursor, drag: root.drag ? { hot: root.drag.hot } : null }
      }

      FocusScope {
        id: keys
        anchors.fill: parent
        focus: win.wanted
        // Opened with Super+Tab: Tab and Shift+Tab step through the workspaces, and letting go of Super goes to the one lit.
        Keys.onReleased: function (e) {
          if (root.peek && (e.key === Qt.Key_Super_L || e.key === Qt.Key_Super_R || e.key === Qt.Key_Meta)) { root.bs.call("overview", { action: "go" }); e.accepted = true }
        }
        Keys.onPressed: function (e) {
          if (e.key === Qt.Key_Escape) root.close()
          else if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) root.go(e.key - Qt.Key_0)
          else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) root.bs.call("overview", { action: "go" })
          else if (e.key === Qt.Key_Tab) root.bs.call("overview", { action: "next" })
          else if (e.key === Qt.Key_Backtab) root.bs.call("overview", { action: "prev" })
          else if (e.key === Qt.Key_Left) root.bs.call("overview", { action: "step", key: "left" })
          else if (e.key === Qt.Key_Right) root.bs.call("overview", { action: "step", key: "right" })
          else if (e.key === Qt.Key_Up) root.bs.call("overview", { action: "step", key: "up" })
          else if (e.key === Qt.Key_Down) root.bs.call("overview", { action: "step", key: "down" })
          else return
          e.accepted = true
        }

        Rectangle {
          id: scrim
          anchors.fill: parent
          color: Logic.alpha(win.th.bg, 0.9)
          opacity: win.wanted ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: win.wanted ? root.bs.motion.listIn : root.bs.motion.listOut } }
          MouseArea { anchors.fill: parent; onClicked: root.close() }

          Item {
            id: grid
            anchors.fill: parent
            anchors.margins: 36
            Repeater {
              model: 9
              delegate: PanelFrame {
                id: card
                th: win.th
                kind: "tile"
                required property int index
                readonly property int n: index + 1
                readonly property var ws: root.bs.st.workspaces ? root.bs.st.workspaces[index] : null
                readonly property var r: Logic.gridRect(index, grid.width, grid.height, 14)
                readonly property bool current: ws ? ws.current === true : false
                readonly property bool hot: root.drag !== null && root.drag.hot === n
                readonly property bool lit: root.cursor === index
                x: r.x; y: r.y; width: r.w; height: r.h
                focused: hot || current || lit
                tint: win.th.palette[index]
                fillColor: hot ? Logic.alpha(win.th.accent, 0.26) : win.th.panel
                Component.onCompleted: { var c = win.cards; c[n] = card; win.cards = c }
                Component.onDestruction: { var c = win.cards; delete c[n]; win.cards = c }

                MouseArea { anchors.fill: parent; onClicked: root.go(card.n) }

                Row {
                  x: 12; y: 8
                  spacing: 8
                  Indicator { th: win.th; n: card.n; current: card.current; tint: win.th.palette[index]; size: win.th.fs(18) }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: card.ws && card.ws.shown_on.length ? "on " + card.ws.shown_on.join(", ") : (card.ws && card.ws.empty ? "empty" : "")
                    color: win.th.dim; font.family: win.th.fontFamily; font.pixelSize: 11
                  }
                }

                Flow {
                  id: thumbs
                  x: 10; y: 40
                  width: parent.width - 20
                  height: parent.height - 50
                  spacing: 8
                  clip: true
                  readonly property int count: card.ws ? card.ws.windows.length : 0
                  readonly property int cols: count <= 1 ? 1 : count <= 4 ? 2 : 3
                  readonly property int rowsN: Math.ceil(Math.max(1, count) / cols)
                  readonly property real tw: (width - spacing * (cols - 1)) / cols
                  readonly property real th: Math.min(tw * 0.62, (height - spacing * (rowsN - 1)) / rowsN)
                  Repeater {
                    model: card.ws ? card.ws.windows.slice(0, 9) : []
                    delegate: PanelFrame {
                      id: wcard
                      required property var modelData
                      th: win.th
                      kind: "row"
                      focused: modelData.focused
                      width: thumbs.tw; height: thumbs.th
                      fillColor: win.th.raised
                      clip: true
                      opacity: root.drag !== null && root.drag.window === modelData.window ? 0.35 : 1
                      Image {
                        id: appIcon
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: -8
                        width: Math.min(48, parent.height * 0.5); height: width
                        source: root.bs.iconSource(root.bs.iconFor(modelData.app))
                        sourceSize.width: 96; sourceSize.height: 96
                        asynchronous: true
                        visible: status === Image.Ready
                      }
                      ScreencopyView {
                        id: shot
                        anchors.fill: parent
                        captureSource: root.toplevelFor(modelData.window)
                        live: false
                        paintCursor: false
                        visible: hasContent
                      }
                      Rectangle {
                        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                        height: 20
                        color: Logic.alpha(win.th.bg, 0.78)
                        Text { anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 6; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; text: Logic.rowTitle(modelData); color: win.th.text; font.family: win.th.fontFamily; font.pixelSize: 11 }
                      }
                      Rectangle {
                        visible: modelData.badge !== null && modelData.badge !== undefined
                        anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 6
                        width: 12; height: 12; radius: 6 // structural: a dot
                        color: modelData.badge === "error" ? win.th.urgent : modelData.badge === "asking" ? win.th.warn : modelData.badge === "working" ? win.th.accent : win.th.orange
                      }
                      MouseArea {
                        anchors.fill: parent
                        property real px: 0
                        property real py: 0
                        property bool dragging: false
                        onPressed: function (m) { px = m.x; py = m.y; dragging = false }
                        onPositionChanged: function (m) {
                          if (!(m.buttons & Qt.LeftButton)) return
                          var p = wcard.mapToItem(scrim, m.x, m.y)
                          if (!dragging && Math.abs(m.x - px) + Math.abs(m.y - py) > 8) { dragging = true; root.drag = { window: modelData.window, title: Logic.rowTitle(modelData), icon: root.bs.iconFor(modelData.app), x: p.x, y: p.y, hot: null } }
                          if (dragging) root.drag = { window: root.drag.window, title: root.drag.title, icon: root.drag.icon, x: p.x, y: p.y, hot: win.cardAt(p.x, p.y) }
                        }
                        onReleased: if (dragging) { dragging = false; var h = root.drag ? root.drag.hot : null; root.dropOn(h) }
                        onClicked: if (!dragging) { var w = modelData.window; root.closeThen(function () { root.bs.call("focus", { window: w }) }) }
                      }
                    }
                  }
                }
                Text {
                  visible: card.ws !== null && card.ws.windows.length > 9
                  anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 10
                  text: "+" + (card.ws ? card.ws.windows.length - 9 : 0)
                  color: win.th.dim; font.family: win.th.fontFamily; font.pixelSize: 12
                }
                Text {
                  visible: card.ws !== null && card.ws.windows.length === 0
                  anchors.centerIn: parent
                  text: "nothing here"
                  color: Logic.alpha(win.th.fg, 0.35)
                  font.family: win.th.fontFamily; font.pixelSize: 13
                }
              }
            }
          }

          // the window card that follows the pointer
          PanelFrame {
            th: win.th
            kind: "row"
            focused: true
            fillColor: win.th.panel
            visible: root.drag !== null
            x: root.drag ? root.drag.x - width / 2 : 0
            y: root.drag ? root.drag.y - height / 2 : 0
            width: gl.width + 24; height: 44
            
            scale: root.bs.motion.lift
            Row {
              id: gl; anchors.centerIn: parent; spacing: 8
              Image { width: 26; height: 26; source: root.drag ? root.bs.iconSource(root.drag.icon) : ""; sourceSize.width: 52; sourceSize.height: 52 }
              Text { anchors.verticalCenter: parent.verticalCenter; text: root.drag ? root.drag.title : ""; color: win.th.text; font.family: win.th.fontFamily; font.pixelSize: 13 }
            }
          }
        }
      }
    }
  }

  IpcHandler {
    target: "baneyspaces.overview"
    function state(): string {
      var v = root.bs.st.overview || {}
      return JSON.stringify({ shown: v.shown === true, cursor: root.cursor, peek: root.peek })
    }
    function clickCard(n: int): string { root.go(n); return "ok" }
    function clickWindow(addr: string): string { root.closeThen(function () { root.bs.call("focus", { window: addr }) }); return "ok" }
    // The drag path without a pointer: pick the card under the target's center, drop there.
    function dragWindow(addr: string, to: int): string {
      var w = null
      for (var i = 0; i < screensV.instances.length; i++) if (screensV.instances[i].wanted) w = screensV.instances[i]
      if (!w) return "overview is not showing"
      var rects = w.cardRects().filter(function (r) { return r.n === to })
      if (!rects.length) return "no such card"
      root.drag = { window: addr, title: addr, icon: "", x: rects[0].x + rects[0].w / 2, y: rects[0].y + rects[0].h / 2, hot: null }
      var hot = w.cardAt(root.drag.x, root.drag.y)
      root.drag = { window: addr, title: addr, icon: "", x: root.drag.x, y: root.drag.y, hot: hot }
      root.dropOn(hot)
      return "dropped on " + hot
    }
    function describe(): string {
      for (var i = 0; i < screensV.instances.length; i++) if (screensV.instances[i].wanted) return JSON.stringify(screensV.instances[i].describe())
      return "{}"
    }
  }
}
