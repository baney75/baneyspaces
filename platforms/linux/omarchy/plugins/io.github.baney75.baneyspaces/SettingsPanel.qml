import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Logic.js" as Logic

// BaneySpaces settings: the Mac's switches that make sense here. Each one writes ~/.config/baneyspaces/config.toml
// through the daemon, which reads the file again at once; the file stays hand-editable.
Item {
  id: root
  visible: false
  required property var bs

  // key: where the plugin reads it from the snapshot; path: where it lives in config.toml (spec/config.md)
  readonly property var sections: [
    { title: "Workspace Dock", rows: [
      { key: "dock.enabled", path: "behavior.dock.enabled", label: "Workspace Dock", type: "bool" },
      { key: "dock.auto_hide", path: "behavior.dock.auto_hide", label: "Hide until the pointer rests on the bottom edge", type: "bool" },
      { key: "dock.size", path: "behavior.dock.size", label: "Size", type: "enum", options: ["small", "medium", "large"] },
      { key: "dock.badges", path: "behavior.dock.badges", label: "Show agent status on app icons", type: "bool" },
      { key: "dock.in_fullscreen", path: "behavior.dock.in_fullscreen", label: "Come up over full-screen windows", type: "bool" } ] },
    { title: "Alt+Tab", rows: [
      { key: "switcher.enabled", path: "behavior.switcher.enabled", label: "Switch across every workspace", type: "bool" },
      { key: "switcher.items", path: "behavior.switcher.mode", label: "Step through", type: "enum", options: ["windows", "apps"] } ] },
    { title: "Launcher  (Super+Space)", rows: [
      { key: "launcher.enabled", path: "behavior.launcher.enabled", label: "Use the BaneySpaces launcher", type: "bool" },
      { key: "launcher.files", path: "behavior.launcher.files", label: "Search files and folders", type: "bool" },
      { key: "launcher.install", path: "behavior.launcher.install", label: "Install and remove apps", type: "bool" } ] },
    { title: "Overview  (Super+Tab)", rows: [
      { key: "overview.enabled", path: "behavior.overview.enabled", label: "Show all nine workspaces", type: "bool" },
      { key: "overview.thumbnails", path: "behavior.overview.previews", label: "Window previews", type: "enum", options: ["live", "icons"] } ] },
    { title: "Appearance", rows: [
      { key: "appearance.theme", path: "theme.name", label: "Theme", type: "enum", options: ["omarchy", "baneyspaces", "minimal"] },
      { key: "appearance.palette", path: "theme.palette", label: "Colors", type: "palette" },
      { key: "opacity", path: "theme.override.fill.opacity", label: "Opacity (where the theme allows)", type: "enum", options: ["0.6", "0.75", "0.88", "1.0"] } ] },
    { title: "Animation", rows: [
      { key: "motion.preset", path: "animation.preset", label: "Preset", type: "enum", options: ["baneyspaces", "omarchy", "snappy", "smooth", "off"] },
      { key: "motion.speed", path: "animation.speed", label: "Speed", type: "enum", options: ["0.5", "1.0", "1.5", "2.0"] },
      { key: "motion.workspace_style", path: "animation.workspace.style", label: "Workspace switch (instant by default)", type: "enum", options: ["off", "fade", "slide"] },
      { key: "motion.respect_reduce", path: "animation.respect_reduce_motion", label: "Follow the desktop's reduce-motion setting", type: "bool" } ] }
  ]

  // What a row shows now.
  function shown(row) {
    if (row.key === "overview.thumbnails") return value(row.key) === false ? "icons" : "live"
    if (row.key === "opacity") { var o = (bs.cfg.appearance || {}).override; var v = o && o.fill && o.fill.opacity !== undefined ? o.fill.opacity : bs.theme.tok.fill.opacity; var n = Math.round(Number(v) * 100) / 100; return n === 1 ? "1.0" : (n === 0.6 ? "0.6" : String(n)) }
    if (row.key === "motion.speed") { var sp = value(row.key); return Number(sp) === Math.floor(sp) ? Number(sp).toFixed(1) : String(sp) }
    return String(value(row.key))
  }
  function value(key) {
    var p = key.split(".")
    var sec = bs.cfg[p[0]]
    return sec === undefined ? undefined : sec[p[1]]
  }
  function setKey(path, v) { bs.call("config_set", { key: path, value: v }) }

  Variants {
    id: vs
    model: Quickshell.screens
    PanelWindow {
      id: win
      required property var modelData
      readonly property var th: root.bs.theme
      readonly property bool wanted: root.bs.st.settings !== undefined && root.bs.st.settings.open === true && root.bs.st.focused_monitor === modelData.name
      screen: modelData
      visible: wanted || scrim.opacity > 0.01
      color: "transparent"
      anchors { left: true; right: true; top: true; bottom: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "baneyspaces-settings"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: wanted ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      function framesUsed() { return [{ surface: "settings", frame: card.used }] }
      onWantedChanged: if (wanted) keys.forceActiveFocus()

      FocusScope {
        id: keys
        anchors.fill: parent
        focus: win.wanted
        Keys.onEscapePressed: root.bs.call("settings", { action: "hide" })

        Rectangle {
          id: scrim
          anchors.fill: parent
          color: Logic.alpha(win.th.roles.sunken, 0.62)
          opacity: win.wanted ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: win.wanted ? root.bs.motion.listIn : root.bs.motion.listOut } }
          MouseArea { anchors.fill: parent; onClicked: root.bs.call("settings", { action: "hide" }) }

          PanelFrame {
            id: card
            th: win.th
            kind: "list"
            shadowed: true
            width: Math.min(560, parent.width - 40)
            height: Math.min(parent.height - 60, col.height + 36)
            anchors.centerIn: parent
            transformOrigin: Item.Center
            scale: win.wanted ? 1 : root.bs.motion.listFrom
            Behavior on scale { NumberAnimation { duration: win.wanted ? root.bs.motion.listIn : root.bs.motion.listOut; easing.type: Easing.OutCubic } }
            MouseArea { anchors.fill: parent }

            Flickable {
              anchors.fill: parent
              anchors.margins: 18
              contentHeight: col.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              Column {
                id: col
                width: parent.width
                spacing: 14
                Row {
                  width: parent.width
                  Text { text: "BaneySpaces"; color: win.th.text; font.family: win.th.fontFamily; font.pixelSize: win.th.fs(20); font.bold: true }
                }
                Repeater {
                  model: root.sections
                  delegate: Column {
                    id: sec
                    required property var modelData
                    width: col.width
                    spacing: 8
                    Text { text: modelData.title.toUpperCase(); color: win.th.dim; font.family: win.th.fontFamily; font.pixelSize: win.th.fs(11); font.letterSpacing: 1 }
                    Repeater {
                      model: sec.modelData.rows
                      delegate: Item {
                        id: line
                        required property var modelData
                        width: sec.width
                        height: line.modelData.type === "palette" ? 30 + pal.height + 6 : 30
                        Text {
                          anchors.verticalCenter: line.modelData.type === "palette" ? undefined : parent.verticalCenter
                          y: line.modelData.type === "palette" ? 6 : 0
                          width: parent.width - (line.modelData.type === "palette" ? 0 : ctl.width + 16)
                          text: line.modelData.label
                          elide: Text.ElideRight
                          color: win.th.text
                          font.family: win.th.fontFamily
                          font.pixelSize: win.th.fs(13)
                        }
                        // the palette: auto (the live Omarchy theme) or one of the bundled ones
                        Flow {
                          id: pal
                          visible: line.modelData.type === "palette"
                          y: 32
                          width: parent.width
                          spacing: 5
                          Repeater {
                            model: line.modelData.type === "palette" ? ["auto"].concat(Object.keys(root.bs.theme.spec.palettes.palettes)) : []
                            delegate: Rectangle {
                              required property string modelData
                              readonly property bool on: modelData === String(root.value("appearance.palette"))
                              width: pn.implicitWidth + 14
                              height: 22
                              radius: win.th.tok.radius.row
                              color: on ? win.th.accent : (pm.containsMouse ? win.th.raisedHot : win.th.raised)
                              Text { id: pn; anchors.centerIn: parent; text: parent.modelData; color: parent.on ? win.th.bg : win.th.text; font.family: win.th.fontFamily; font.pixelSize: win.th.fs(11) }
                              MouseArea { id: pm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setKey("theme.palette", parent.modelData) }
                            }
                          }
                        }
                        Item {
                          id: ctl
                          visible: line.modelData.type !== "palette"
                          anchors.right: parent.right
                          anchors.verticalCenter: line.modelData.type === "palette" ? undefined : parent.verticalCenter
                          width: line.modelData.type === "bool" ? tog.width : seg.width
                          height: 26
                          Toggle {
                            id: tog
                            bs: root.bs
                            visible: line.modelData.type === "bool"
                            checked: root.value(line.modelData.key) === true
                            onToggled: function (v) { root.setKey(line.modelData.path, v ? "true" : "false") }
                          }
                          Segmented {
                            id: seg
                            bs: root.bs
                            visible: line.modelData.type === "enum"
                            options: (line.modelData.options || []).map(function (o) { return { value: o, label: o } })
                            current: root.shown(line.modelData)
                            onPicked: function (v) { root.setKey(line.modelData.path, v) }
                          }
                        }
                      }
                    }
                  }
                }
                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "These switches write " + (root.bs.cfg.path || "~/.config/baneyspaces/config.toml") + ". Colors follow the active Omarchy theme."
                  color: win.th.dim; font.family: win.th.fontFamily; font.pixelSize: win.th.fs(11)
                }
              }
            }
          }
        }
      }
    }
  }

  function framesUsed() { return vs.instances.length ? vs.instances[0].framesUsed() : [] }

  IpcHandler {
    target: "baneyspaces.settings"
    function state(): string { return JSON.stringify({ open: (root.bs.st.settings || {}).open === true }) }
  }
}
