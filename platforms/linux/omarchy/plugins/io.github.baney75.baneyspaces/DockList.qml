import QtQuick
import Quickshell
import Quickshell.Wayland
import "Logic.js" as Logic

// The "+N" list, the strip of an app's windows and the right-click menus. A window of its own, standing
// on the bar: opening one never resizes or moves the dock (the Mac's DockSide).
PanelWindow {
  id: win
  required property var host
  required property var bs
  readonly property var th: bs.theme
  readonly property var ls: host.listState
  property var shown: null           // kept while fading out
  readonly property int rowH: 34
  readonly property int pad: 6
  readonly property int listW: 270
  readonly property int rowCount: shown ? shown.rows.length : 0
  readonly property var place: shown && screen ? Logic.listPlacement(host.triggerRect(shown.n, host.barRect), { w: listW, h: panelH }, { w: screen.width }, 8) : { x: 0, y: 0 }

  screen: host.screen
  visible: ls !== null || content.opacity > 0.01
  color: "transparent"
  anchors { left: true; bottom: true }
  readonly property int sp: th.shadowPad
  readonly property int panelH: pad * 2 + rowCount * rowH
  margins.left: place.x - sp
  margins.bottom: screen && shown ? screen.height - (host.barRect.y - 8) - sp : 0
  implicitWidth: listW + sp * 2
  implicitHeight: panelH + sp * 2
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "baneyspaces-dock-list"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  mask: Region { item: card }
  function framesUsed() { return [{ surface: "dock-list", frame: card.used }] }

  onLsChanged: { if (ls) shown = ls }
  Connections { target: content.Window.window; function onFrameSwapped() { bs.probeTick("list") } }
  function publish() {
    host.listRect = ls ? { x: place.x, y: host.barRect.y - 8 - panelH, w: listW, h: panelH } : null
  }
  onPlaceChanged: publish()
  onPanelHChanged: publish()
  Connections { target: host; function onListStateChanged() { win.publish() } function onBarRectChanged() { win.publish() } }

  Item {
    id: content
    anchors.fill: parent
    opacity: win.ls ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: win.ls ? bs.motion.listIn : bs.motion.listOut; easing.type: Easing.OutCubic } }

    PanelFrame {
      id: card
      th: win.th
      kind: "list"
      shadowed: true
      x: win.sp; y: win.sp; width: win.listW; height: win.panelH
      transformOrigin: Item.Bottom
      scale: win.ls ? 1 : bs.motion.listFrom
      Behavior on scale { NumberAnimation { duration: win.ls ? bs.motion.listIn : bs.motion.listOut; easing.type: Easing.OutCubic } }

      HoverHandler { onHoveredChanged: host.listHovered(hovered) }

      Column {
        anchors.fill: parent
        anchors.margins: win.pad
        Repeater {
          model: win.shown ? win.shown.rows : []
          delegate: PanelFrame {
            id: rowItem
            required property var modelData
            required property int index
            th: win.th
            kind: "row"
            framed: false
            width: parent.width
            height: win.rowH
            fillColor: ma.containsMouse ? th.raisedHot : "transparent"
            Image {
              id: ic
              visible: modelData.icon !== "" && status === Image.Ready
              x: 8; anchors.verticalCenter: parent.verticalCenter
              width: 22; height: 22
              source: modelData.icon ? bs.iconSource(modelData.icon) : ""
              sourceSize.width: 44; sourceSize.height: 44
              asynchronous: true
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              x: modelData.icon !== "" ? 38 : 10
              width: parent.width - x - (sub.visible ? sub.width + 14 : 10)
              text: modelData.title
              elide: Text.ElideRight
              color: th.text
              font.family: th.fontFamily
              font.pixelSize: th.fs(12)
            }
            Text {
              id: sub
              visible: modelData.sub !== ""
              anchors.right: parent.right; anchors.rightMargin: 10
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.sub
              color: th.dim
              font.family: th.fontFamily
              font.pixelSize: 11
            }
            MouseArea {
              id: ma
              anchors.fill: parent
              hoverEnabled: true
              property real px: 0
              property real py: 0
              property bool dragging: false
              onPressed: function (m) { px = m.x; py = m.y; dragging = false }
              onPositionChanged: function (m) {
                if (!(m.buttons & Qt.LeftButton) || !modelData.windows || !modelData.windows.length) return
                var p = rowItem.mapToItem(null, m.x, m.y)
                var gx = win.place.x - win.sp + p.x
                var gy = host.barRect.y - 8 - win.panelH + p.y
                if (!dragging && Math.abs(m.x - px) + Math.abs(m.y - py) > 8) { dragging = true; host.beginDrag(modelData.title, modelData.icon, modelData.windows, gx, gy) }
                if (dragging) host.moveDrag(gx, gy)
              }
              onReleased: if (dragging) { dragging = false; host.endDrag(); host.closeList() }
              onClicked: if (!dragging) host.runRow(modelData)
            }
          }
        }
      }
    }
  }
}
