import QtQuick

// A switch.
Item {
  id: root
  required property var bs
  property bool checked: false
  signal toggled(bool value)
  implicitWidth: 42
  implicitHeight: 24
  Rectangle {
    anchors.fill: parent
    radius: Math.min(root.bs.theme.tok.radius.row * 3, height / 2)
    color: root.checked ? root.bs.theme.accent : root.bs.theme.raisedHot
    Behavior on color { enabled: !root.bs.reduceMotion; ColorAnimation { duration: root.bs.motion.row } }
    Rectangle {
      width: parent.height - 6
      height: width
      radius: parent.radius > 0 ? width / 2 : 0
      y: 3
      x: root.checked ? parent.width - width - 3 : 3
      color: root.checked ? root.bs.theme.bg : root.bs.theme.text
      Behavior on x { enabled: !root.bs.reduceMotion; NumberAnimation { duration: root.bs.motion.row; easing.type: Easing.OutCubic } }
    }
  }
  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggled(!root.checked) }
}
