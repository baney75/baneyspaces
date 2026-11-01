import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Logic.js" as Logic

// Alt+Tab across every workspace, most recently used first, each window marked with its workspace. Let go
// of Alt and you are on that window, wherever it is. (The bind runs `baneyspaces switcher next`; the
// daemon keeps the list and the selection; this draws it and sends the release back.)
Item {
  id: root
  visible: false
  required property var bs

  Variants {
    id: vs
    model: Quickshell.screens
    PanelWindow {
      id: win
      required property var modelData
      readonly property var th: root.bs.theme
      readonly property var sw: root.bs.st.switcher || ({})
      readonly property bool wanted: root.bs.cfg.switcher !== undefined && root.bs.cfg.switcher.enabled !== false
        && sw.open === true && root.bs.st.focused_monitor === modelData.name
      readonly property var items: sw.items || []
      readonly property int cell: 124

      screen: modelData
      visible: wanted || card.opacity > 0.01
      color: "transparent"
      readonly property int sp: th.shadowPad
      implicitWidth: card.width + sp * 2
      implicitHeight: card.height + sp * 2
      Connections { target: win.backingWindow; function onFrameSwapped() { root.bs.probeTick("switcher") } }
      function framesUsed() { return [{ surface: "switcher", frame: card.used }] }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "baneyspaces-switcher"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: wanted ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      onWantedChanged: if (wanted) keys.forceActiveFocus()

      FocusScope {
        id: keys
        anchors.fill: parent
        focus: win.wanted
        // Alt let go: that is the choice. (Meta too, for a switcher bound to Super.)
        Keys.onReleased: function (e) {
          if (e.key === Qt.Key_Alt || e.key === Qt.Key_Meta || e.key === Qt.Key_Super_L) { root.bs.call("switcher", { action: "commit" }); e.accepted = true }
        }
        Keys.onPressed: function (e) {
          if (e.key === Qt.Key_Escape) root.bs.call("switcher", { action: "cancel" })
          else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) root.bs.call("switcher", { action: "commit" })
          else if (e.key === Qt.Key_Right || (e.key === Qt.Key_Tab && !(e.modifiers & Qt.ShiftModifier))) root.bs.call("switcher", { action: "next" })
          else if (e.key === Qt.Key_Left || e.key === Qt.Key_Backtab) root.bs.call("switcher", { action: "prev" })
          e.accepted = true
        }

        PanelFrame {
          id: card
          th: win.th
          kind: "list"
          shadowed: true
          x: win.sp; y: win.sp
          opacity: win.wanted ? 1 : 0
          scale: win.wanted ? 1 : root.bs.motion.listFrom
          Behavior on opacity { NumberAnimation { duration: win.wanted ? 100 * (root.bs.reduceMotion ? 0 : 1) : 80 * (root.bs.reduceMotion ? 0 : 1) } }
          Behavior on scale { NumberAnimation { duration: win.wanted ? root.bs.motion.listIn : root.bs.motion.listOut; easing.type: Easing.OutCubic } }
          width: flow.width + 28
          height: flow.height + title.height + 40

          Flow {
            id: flow
            x: 14; y: 14
            width: Math.min(win.items.length * win.cell, Math.floor((win.modelData.width * 0.82) / win.cell) * win.cell)
            Repeater {
              model: win.items
              delegate: PanelFrame {
                id: cellItem
                required property var modelData
                required property int index
                readonly property bool sel: index === win.sw.index
                th: win.th
                kind: "tile"
                focused: sel
                framed: sel
                width: win.cell
                height: 104
                fillColor: sel ? Logic.alpha(win.th.accent, 0.28) : "transparent"
                Image {
                  id: ic
                  anchors.horizontalCenter: parent.horizontalCenter
                  y: 12
                  width: 52; height: 52
                  source: root.bs.iconSource(root.bs.iconFor(modelData.app))
                  sourceSize.width: 104; sourceSize.height: 104
                  asynchronous: true
                  visible: status === Image.Ready
                }
                Rectangle {
                  visible: ic.status !== Image.Ready
                  anchors.horizontalCenter: parent.horizontalCenter
                  y: 12; width: 52; height: 52; radius: Math.min(win.th.tok.radius.row * 1.5, 12)
                  color: Logic.alpha(win.th.accent, 0.35)
                  Text { anchors.centerIn: parent; text: (modelData.app || "?").charAt(0).toUpperCase(); color: win.th.text; font.pixelSize: 26; font.bold: true; font.family: win.th.fontFamily }
                }
                // the workspace this window is on
                Rectangle {
                  width: 22; height: 22; radius: win.th.tok.radius.row > 0 ? 11 : 0 // structural: a round chip, square in the blocky theme
                  anchors.right: ic.right; anchors.top: ic.top
                  anchors.rightMargin: -8; anchors.topMargin: -6
                  color: win.th.palette[(modelData.workspace - 1) % 9]
                  Text { anchors.centerIn: parent; text: modelData.workspace; color: win.th.bg; font.bold: true; font.pixelSize: win.th.fs(12); font.family: win.th.fontFamily }
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  y: 74
                  width: parent.width - 14
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  text: root.bs.cfg.switcher.items === "apps" ? root.bs.nameFor(modelData.app) + (modelData.count > 1 ? "  ×" + modelData.count : "") : Logic.rowTitle(modelData)
                  color: win.th.text
                  font.family: win.th.fontFamily
                  font.pixelSize: win.th.fs(12)
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: { root.bs.call("switcher", { action: "select", index: cellItem.index }, function () { root.bs.call("switcher", { action: "commit" }) }) }
                }
              }
            }
          }
          Text {
            id: title
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            width: Math.min(parent.width - 40, 520)
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideMiddle
            text: win.items.length > win.sw.index ? Logic.rowTitle(win.items[win.sw.index]) : ""
            color: win.th.dim
            font.family: win.th.fontFamily
            font.pixelSize: win.th.fs(12)
          }
        }
      }
    }
  }

  function framesUsed() { return vs.instances.length ? vs.instances[0].framesUsed() : [] }

  IpcHandler {
    target: "baneyspaces.switcher"
    function state(): string {
      var s = root.bs.st.switcher || {}
      return JSON.stringify({ open: s.open === true, index: s.index, items: (s.items || []).length })
    }
  }
}
