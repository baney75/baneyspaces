import QtQuick

// How a workspace shows itself (the theme's `indicator`): a dot, a bar, or its number in a block. Used by the
// dock's tiles, the overview and the bar module.
Item {
  id: root
  required property var th
  property int n: 1
  property bool current: false
  property string tint: th.palette[(n - 1) % 9]
  property int size: 11
  readonly property string kind: th.tok.indicator
  readonly property color ink: current ? th.accent : tint

  implicitWidth: row.width
  implicitHeight: Math.max(row.height, size + 4)

  Row {
    id: row
    spacing: 4
    anchors.centerIn: parent
    Rectangle {
      visible: root.kind === "dot"
      width: root.current ? 8 : 6; height: width; radius: width / 2
      anchors.verticalCenter: parent.verticalCenter
      color: root.ink
    }
    Rectangle {
      visible: root.kind === "bar"
      width: root.current ? 16 : 10; height: 3
      anchors.verticalCenter: parent.verticalCenter
      color: root.ink
    }
    Rectangle {
      visible: root.kind === "number-block"
      width: root.size + 9; height: root.size + 7
      radius: root.th.tok.radius.tile > 0 ? 3 : 0
      color: root.current ? root.th.accent : root.th.raised
      border.width: 1
      border.color: root.current ? root.th.accent : root.th.tok.roles.border
      Text {
        anchors.centerIn: parent
        text: String(root.n)
        color: root.current ? root.th.bg : root.tint
        font.family: root.th.fontFamily
        font.pixelSize: root.size
        font.bold: true
      }
    }
    Text {
      visible: root.kind !== "number-block"
      text: String(root.n)
      color: root.current ? root.th.accent : root.th.dim
      font.family: root.th.fontFamily
      font.pixelSize: root.size + 1
      font.bold: true
    }
  }
}
