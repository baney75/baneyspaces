import QtQuick
import Quickshell
import Quickshell.Wayland

// What follows the pointer while an app or window is dragged: a full-screen window that draws and takes
// no input, so the dock window underneath keeps the pointer (and the dock is never clipped).
PanelWindow {
  id: win
  required property var host
  required property var bs
  readonly property var d: host.drag
  screen: host.screen
  visible: d !== null
  color: "transparent"
  anchors { left: true; right: true; top: true; bottom: true }
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "baneyspaces-drag"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  mask: Region {}

  PanelFrame {
    th: bs.theme
    kind: "row"
    focused: true
    fillColor: bs.theme.panel
    visible: win.d !== null
    x: win.d ? win.d.x - width / 2 : 0
    y: win.d ? win.d.y - height / 2 : 0
    width: row.width + 20
    height: 46
    scale: bs.motion.lift
    Row {
      id: row
      anchors.centerIn: parent
      spacing: 8
      Image {
        visible: status === Image.Ready
        width: 28; height: 28
        source: win.d && win.d.icon ? bs.iconSource(win.d.icon) : ""
        sourceSize.width: 56; sourceSize.height: 56
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: win.d ? win.d.label : ""
        color: bs.theme.text
        font.family: bs.theme.fontFamily
        font.pixelSize: bs.theme.fs(12)
      }
    }
  }
}
