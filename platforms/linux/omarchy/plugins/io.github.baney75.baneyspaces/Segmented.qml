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
        width: label.implicitWidth + 20
        height: 26
        radius: root.bs.theme.tok.radius.row
        color: on ? root.bs.theme.accent : (ma.containsMouse ? root.bs.theme.raisedHot : root.bs.theme.raised)
        Text {
          id: label
          anchors.centerIn: parent
          text: modelData.label
          color: parent.on ? root.bs.theme.bg : root.bs.theme.text
          font.family: root.bs.theme.fontFamily
          font.pixelSize: root.bs.theme.fs(12)
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.picked(String(modelData.value)) }
      }
    }
  }
}
