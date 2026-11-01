import QtQuick
import QtQuick.Shapes

// The one box every surface is built from: fill, border and (for panels) shadow, all from the theme's
// tokens. `kind` picks the radius (bar, tile, row, list). `used` says what was drawn, for the theme check.
Item {
  id: root
  required property var th
  property string kind: "list"
  property bool focused: false          // the workspace you are on, the selected row, the hovered tile
  property string tint: ""              // the workspace's own tint (a theme may color a focused border with it)
  property string fillColor: ""         // overrides the panel fill (tiles and rows use quiet fills)
  property bool framed: true
  property bool shadowed: false
  default property alias content: holder.data

  readonly property var tk: th.tok
  readonly property real r: Math.min(tk.radius[kind], Math.min(width, height) / 2)
  readonly property real bw: framed ? (focused ? tk.border.focusedWidth : tk.border.width) : 0
  readonly property string focusColor: tk.border.focusedColor !== null ? tk.border.focusedColor : (tint !== "" ? tint : tk.roles.accent)
  readonly property string edge: focused ? focusColor : tk.border.color
  // A gradient border is only the resting one; a focused border is solid.
  readonly property bool gradient: framed && !focused && tk.border.gradient !== null
  readonly property real edgeOpacity: focused ? 1 : (tk.border.opacity === null ? 1 : tk.border.opacity)
  readonly property string fill: fillColor !== "" ? fillColor : th.panel
  readonly property var used: ({ kind: kind, radiusToken: tk.radius[kind], focused: focused, framed: framed, customFill: fillColor !== "", radius: r, borderWidth: bw, borderColor: edge, borderOpacity: gradient ? null : edgeOpacity,
    gradient: gradient ? tk.border.gradient : null, fill: fill, shadow: shadowed ? tk.shadow : null })

  // A soft shadow from stacked rounded rectangles (Qt Quick has no blur without a GPU effect).
  Repeater {
    model: root.shadowed && root.tk.shadow ? 6 : 0
    delegate: Rectangle {
      required property int index
      readonly property real grow: root.tk.shadow.radius * (index + 1) / 6
      x: -grow; y: root.tk.shadow.y - grow
      width: root.width + grow * 2; height: root.height + grow * 2
      radius: root.r + grow
      color: Qt.rgba(0, 0, 0, root.tk.shadow.opacity / 9 * (1 - index / 7))
      z: -2
    }
  }
  Rectangle { id: body; anchors.fill: parent; radius: root.r; color: root.fill; z: -1 }
  Shape {
    anchors.fill: parent
    visible: root.bw > 0
    preferredRendererType: Shape.GeometryRenderer
    ShapePath {
      fillRule: ShapePath.OddEvenFill
      strokeWidth: -1
      fillColor: root.gradient ? "transparent" : Qt.rgba(Qt.color(root.edge).r, Qt.color(root.edge).g, Qt.color(root.edge).b, root.edgeOpacity)
      fillGradient: root.gradient ? grad : null
      PathRectangle { x: 0; y: 0; width: root.width; height: root.height; radius: root.r }
      PathRectangle { x: root.bw; y: root.bw; width: Math.max(0, root.width - 2 * root.bw); height: Math.max(0, root.height - 2 * root.bw); radius: Math.max(0, root.r - root.bw) }
    }
    LinearGradient {
      id: grad
      x1: 0; y1: 0; x2: 0; y2: root.height
      GradientStop { position: 0; color: Qt.rgba(Qt.color(root.edge).r, Qt.color(root.edge).g, Qt.color(root.edge).b, root.tk.border.gradient ? root.tk.border.gradient.top : 0) }
      GradientStop { position: 1; color: Qt.rgba(Qt.color(root.edge).r, Qt.color(root.edge).g, Qt.color(root.edge).b, root.tk.border.gradient ? root.tk.border.gradient.bottom : 0) }
    }
  }
  Item { id: holder; anchors.fill: parent }
}
