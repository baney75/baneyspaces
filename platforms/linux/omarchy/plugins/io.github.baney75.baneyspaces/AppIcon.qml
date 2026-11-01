import QtQuick
import QtQuick.Shapes
import "Logic.js" as Logic

// One app on a tile: its icon, an agent status badge, hover scale, click, right-click and drag.
Item {
  id: root
  required property var bs
  property var app: ({})           // { app, count, windows:[{window,title,focused,badge}], focused, badge }
  property int size: 34
  property string label: ""         // "+3" for the overflow chip
  property bool chip: false
  property bool hot: false
  readonly property string iconName: bs.iconFor(app.app)

  signal clicked()
  signal rightClicked()
  signal hovered(bool inside)
  signal dragBegan(real x, real y)
  signal dragMoved(real x, real y)
  signal dragEnded(real x, real y)

  width: size
  height: size

  // Hover scales this item alone; nothing around it moves.
  scale: area.containsMouse || hot ? bs.motion.lift + 0.02 : 1
  Behavior on scale { enabled: !bs.reduceMotion; NumberAnimation { duration: bs.motion.row; easing.type: Easing.OutCubic } }
  transformOrigin: Item.Bottom

  Rectangle {
    visible: root.chip
    anchors.fill: parent
    radius: Math.min(bs.theme.tok.radius.row, width / 3)
    color: bs.theme.raisedHot
    Text {
      anchors.centerIn: parent
      text: root.label
      color: bs.theme.text
      font.family: bs.theme.fontFamily
      font.pixelSize: Math.round(root.size * 0.38)
      font.bold: true
    }
  }

  Image {
    id: img
    visible: !root.chip && status === Image.Ready
    anchors.fill: parent
    source: root.chip ? "" : bs.iconSource(root.iconName)
    sourceSize.width: root.size * 2
    sourceSize.height: root.size * 2
    fillMode: Image.PreserveAspectFit
    smooth: true
    asynchronous: true
  }
  // No icon in the theme: the first letter on the workspace color.
  Rectangle {
    visible: !root.chip && img.status !== Image.Ready
    anchors.fill: parent
    radius: Math.min(bs.theme.tok.radius.row, width / 4)
    color: Logic.alpha(bs.theme.accent, 0.35)
    Text {
      anchors.centerIn: parent
      text: (root.app.app || "?").charAt(0).toUpperCase()
      color: bs.theme.text
      font.family: bs.theme.fontFamily
      font.pixelSize: Math.round(root.size * 0.5)
      font.bold: true
    }
  }

  // Agent status: a turning ring while it works; ? asking, ! stopped on an error, a count when finished.
  Shape {
    id: ring
    visible: root.app.badge === "working" && !root.chip
    anchors.fill: parent
    anchors.margins: -3
    layer.enabled: true
    layer.samples: 4
    ShapePath {
      strokeColor: bs.theme.accent
      strokeWidth: 2.5
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathAngleArc { centerX: ring.width / 2; centerY: ring.height / 2; radiusX: ring.width / 2 - 1.5; radiusY: ring.height / 2 - 1.5; startAngle: -90; sweepAngle: 100 }
    }
    // structural: the agent spinner keeps its own pace
    RotationAnimator on rotation { running: ring.visible && !bs.reduceMotion; from: 0; to: 360; duration: 1100; loops: Animation.Infinite } // structural
  }
  Rectangle {
    id: badge
    readonly property string glyph: Logic.badgeGlyph(root.app.badge, root.app.badgeCount || 1)
    visible: glyph !== "" && !root.chip && bs.dockCfg.badges !== false
    width: Math.max(14, root.size * 0.42)
    height: width
    radius: width / 2
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: -width * 0.25
    anchors.topMargin: -width * 0.25
    color: root.app.badge === "asking" ? bs.theme.warn : root.app.badge === "error" ? bs.theme.urgent : bs.theme.orange
    Text {
      anchors.centerIn: parent
      text: badge.glyph
      color: bs.theme.bg
      font.family: bs.theme.fontFamily
      font.pixelSize: Math.round(badge.width * 0.7)
      font.bold: true
    }
  }
  // The app has the front window.
  Rectangle {
    visible: root.app.focused === true && !root.chip
    width: 4; height: 4; radius: 2 // structural: a dot
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.bottom
    anchors.topMargin: 1
    color: bs.theme.accent
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    property real px: 0
    property real py: 0
    property bool dragging: false
    property bool wasDrag: false
    onEntered: root.hovered(true)
    onExited: root.hovered(false)
    onPressed: function (m) { px = m.x; py = m.y; dragging = false; wasDrag = false }
    onPositionChanged: function (m) {
      if (!(m.buttons & Qt.LeftButton) || root.chip) return
      if (!dragging && Math.abs(m.x - px) + Math.abs(m.y - py) > 8) { dragging = true; root.dragBegan(m.x, m.y) }
      if (dragging) root.dragMoved(m.x, m.y)
    }
    onReleased: function (m) {
      if (dragging) { dragging = false; wasDrag = true; root.dragEnded(m.x, m.y) }
    }
    onClicked: function (m) {
      if (m.button === Qt.RightButton) root.rightClicked()
      else if (!wasDrag) root.clicked()
    }
  }
}
