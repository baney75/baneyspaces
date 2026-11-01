import QtQuick

// A row of choices, one picked: [{ value, label }].
Item {
  id: root
  required property var bs
  property var options: []
  property string current: ""
  signal picked(string value)
  implicitWidth: row.width
  implicitHeight: 26
  Row {
    id: row
    spacing: 4
    Repeater {
      model: root.options
      delegate: Rectangle {
        required property var modelData
        readonly property bool on: String(modelData.value) === root.current
        readonly property bool plain: root.bs.theme.chipStyle === "text"   // omarchy: plain text, the active one in the accent, underlined
        width: label.implicitWidth + (plain ? 8 : 20)
        height: 26
        radius: plain ? 0 : root.bs.theme.tok.radius.row
        color: plain ? "transparent" : (on ? root.bs.theme.accent : (ma.containsMouse ? root.bs.theme.raisedHot : root.bs.theme.raised))
        border.width: root.bs.theme.chipStyle === "none" ? root.bs.theme.tok.border.width : 0
        border.color: on ? root.bs.theme.accent : root.bs.theme.tok.border.color
        Rectangle { visible: parent.plain && parent.on; anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter; width: label.implicitWidth; height: root.bs.theme.tok.border.width; color: root.bs.theme.accent }
        Text {
          id: label
          anchors.centerIn: parent
          text: modelData.label
          color: parent.plain ? (parent.on ? root.bs.theme.accent : root.bs.theme.dim) : (parent.on && root.bs.theme.chipStyle === "pill" ? root.bs.theme.bg : (parent.on ? root.bs.theme.accent : root.bs.theme.text))
          font.family: root.bs.theme.fontFamily
          font.pixelSize: root.bs.theme.fs(12)
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.picked(String(modelData.value)) }
      }
    }
  }
}
