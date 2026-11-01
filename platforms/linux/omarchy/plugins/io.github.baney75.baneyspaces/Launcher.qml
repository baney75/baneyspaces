import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Logic.js" as Logic

// Super+Space: one box to open, find, install and remove apps, find files, windows and workspaces, search
// the web with bangs and ask your agent. The daemon searches (launcher.rs); this types and draws.
Item {
  id: root
  visible: false
  required property var bs

  property string mode: "all"
  property string query: ""
  property var results: []
  property int sel: 0
  property int resultSeq: 0
  property int seq: 0
  property var confirm: null       // { id, message, command }
  property string note: ""
  signal scrollRequest(int row)
  // The list's own height from its rows (a header is 26, a result 46): the ListView's contentHeight depends on its height.
  readonly property int rowsHeight: Logic.sectionRows(results).reduce(function (h, r) { return h + (r.header !== undefined ? 26 : 46) }, 0)
  // Timestamps for the parity numbers (ms since epoch): opened, first answer from the daemon, a typed query's first answer.
  property double tOpen: 0
  property double tReady: 0
  property double tType: 0
  property double tTyped: 0

  readonly property var lcfg: bs.cfg.launcher || ({})
  readonly property var modeEnabled: ({ files: lcfg.files !== false, install: lcfg.install !== false, remove: lcfg.install !== false })

  function search() {
    var my = ++seq
    bs.call("launcher_search", { query: query, mode: mode }, function (r) {
      if (my !== seq || !r.ok) return
      if (root.tReady === 0) root.tReady = Date.now()
      if (root.tType > 0 && root.tTyped === 0 && r.data.results.length > 0) root.tTyped = Date.now()
      results = r.data.results
      resultSeq = r.data.seq
      sel = Math.min(sel, Math.max(0, results.length - 1))
      scrollRequest(rowIndexOf(sel))
    })
  }
  property var listRef: null
  function listItem(i) { return listRef ? listRef.itemAtIndex(i) : null }
  function rowIndexOf(flat) {
    var rows = Logic.sectionRows(results)
    for (var i = 0; i < rows.length; i++) if (rows[i].index === flat) return i
    return 0
  }
  function run(i, confirmed, alt) {
    var r = results[i]
    if (!r) return
    bs.call("launcher_run", { id: r.id, seq: resultSeq, confirm: confirmed === true, alt: alt === true }, function (rep) {
      if (!rep.ok) { note = rep.error ? rep.error.message : "failed"; return }
      if (rep.data.needs_confirm) confirm = { id: r.id, message: rep.data.message, command: rep.data.command }
      else { confirm = null; bs.call("launcher", { action: "hide" }) }
    })
  }
  function setMode(m) { mode = m; sel = 0; search() }
  function reset() { tOpen = Date.now(); tReady = 0; tType = 0; tTyped = 0; query = ""; mode = "all"; sel = 0; confirm = null; note = ""; results = []; search() }

  Timer { id: debounce; interval: 60; onTriggered: root.search() }

  Variants {
    id: vs
    model: Quickshell.screens
    PanelWindow {
      id: win
      required property var modelData
      readonly property var th: root.bs.theme
      readonly property bool wanted: root.bs.st.launcher !== undefined && root.bs.st.launcher.open === true
        && root.lcfg.enabled !== false && root.bs.st.focused_monitor === modelData.name
      screen: modelData
      visible: wanted || scrim.opacity > 0.01
      color: "transparent"
      anchors { left: true; right: true; top: true; bottom: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "baneyspaces-launcher"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: wanted ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      Connections { target: scrim.Window.window; function onFrameSwapped() { root.bs.probeTick("launcher") } }
      function framesUsed() { return [{ surface: "launcher", frame: card.used }] }
      onWantedChanged: if (wanted) { root.reset(); input.forceActiveFocus() }

      Rectangle {
        id: scrim
        anchors.fill: parent
        color: Logic.alpha(win.th.roles.sunken, 0.62)
        opacity: win.wanted ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: win.wanted ? root.bs.motion.listIn : root.bs.motion.listOut } }
        MouseArea { anchors.fill: parent; onClicked: root.bs.call("launcher", { action: "hide" }) }

        PanelFrame {
          id: card
          th: win.th
          kind: "list"
          shadowed: true
          width: Math.min(700, parent.width - 40)
          height: lay.height + 32
          x: (parent.width - width) / 2
          y: Math.max(40, parent.height * 0.16)
          transformOrigin: Item.Top
          scale: win.wanted ? 1 : root.bs.motion.listFrom
          Behavior on scale { NumberAnimation { duration: win.wanted ? root.bs.motion.listIn : root.bs.motion.listOut; easing.type: Easing.OutCubic } }
          MouseArea { anchors.fill: parent }   // clicks on the card do not reach the scrim
          readonly property var frameUsed: card.used

          Column {
            id: lay
            x: 16; y: 16
            width: parent.width - 32
            spacing: 10

            Item {
              id: header
              width: parent.width
              height: 40
              PanelFrame { th: win.th; kind: "row"; framed: false; anchors.fill: parent; fillColor: win.th.raised }
              // the magnifier, drawn
              Rectangle { x: 14; y: 11; width: 14; height: 14; radius: 7; /* structural */ color: "transparent"; border.color: win.th.dim; border.width: 2 }
              Rectangle { x: 26; y: 25; width: 8; height: 2; radius: 1; /* structural */ color: win.th.dim; rotation: 45; transformOrigin: Item.Left }
              TextInput {
                id: input
                x: 44; anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 60
                color: win.th.text
                selectionColor: win.th.accent
                selectedTextColor: win.th.bg
                font.family: win.th.fontFamily
                font.pixelSize: win.th.fs(17)
                clip: true
                text: root.query
                onTextEdited: { root.query = text; debounce.restart() }
                Text {
                  visible: root.query === ""
                  text: "Search apps, files, windows and the web"
                  color: win.th.dim
                  font: input.font
                }
                Keys.onPressed: function (e) {
                  var n = root.results.length
                  if (e.key === Qt.Key_Escape) { if (root.confirm) root.confirm = null; else root.bs.call("launcher", { action: "hide" }) }
                  else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { if (root.confirm) root.run(root.results.findIndex(function (r) { return r.id === root.confirm.id }), true); else root.run(root.sel, false, (e.modifiers & Qt.AltModifier) !== 0) }
                  else if (e.key === Qt.Key_Down || (e.key === Qt.Key_N && (e.modifiers & Qt.ControlModifier))) { root.sel = Logic.stepIndex(root.sel, n, 1); list.positionViewAtIndex(root.rowIndexOf(root.sel), ListView.Contain) }
                  else if (e.key === Qt.Key_Up || (e.key === Qt.Key_P && (e.modifiers & Qt.ControlModifier))) { root.sel = Logic.stepIndex(root.sel, n, -1); list.positionViewAtIndex(root.rowIndexOf(root.sel), ListView.Contain) }
                  else if (e.key === Qt.Key_Tab) root.setMode(Logic.nextMode(root.mode, 1, root.modeEnabled))
                  else if (e.key === Qt.Key_Backtab) root.setMode(Logic.nextMode(root.mode, -1, root.modeEnabled))
                  else if (e.key === Qt.Key_Backspace && root.query === "" && root.mode !== "all") root.setMode("all")
                  else return
                  e.accepted = true
                }
              }
            }

            // Tab goes into a menu; Backspace on an empty search comes back. Pills in the baneyspaces theme, plain text with the
            // active one underlined in omarchy, and no row at all in minimal (the menus are `!apps`, `!files` ... and Tab).
            Flow {
              id: chips
              visible: win.th.chipStyle !== "none"
              height: visible ? implicitHeight : 0
              width: parent.width
              spacing: win.th.chipStyle === "pill" ? 6 : 14
              Repeater {
                model: Logic.MODES.filter(function (m) { return root.modeEnabled[m] !== false })
                delegate: Item {
                  required property string modelData
                  readonly property bool on: modelData === root.mode
                  readonly property bool pill: win.th.chipStyle === "pill"
                  width: label.implicitWidth + (pill ? 18 : 0)
                  height: 24
                  Rectangle {
                    visible: parent.pill
                    anchors.fill: parent
                    radius: Math.min(win.th.tok.radius.row * 2, height / 2)
                    color: parent.on ? win.th.accent : (ma.containsMouse ? win.th.raisedHot : win.th.raised)
                  }
                  Text {
                    id: label
                    anchors.centerIn: parent
                    text: Logic.MODE_LABELS[modelData]
                    color: parent.pill ? (parent.on ? win.th.bg : win.th.text) : (parent.on ? win.th.accent : (ma.containsMouse ? win.th.text : win.th.dim))
                    font.family: win.th.fontFamily
                    font.pixelSize: win.th.fs(12)
                    font.bold: !parent.pill && parent.on
                  }
                  Rectangle { visible: !parent.pill && parent.on; anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; width: label.implicitWidth; height: win.th.tok.border.width; color: win.th.accent }
                  MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: root.setMode(modelData) }
                }
              }
            }

            ListView {
              id: list
              Component.onCompleted: root.listRef = list
              Connections { target: root; function onScrollRequest(row) { list.positionViewAtIndex(row, ListView.Contain) } }
              width: parent.width
              height: root.results.length === 0 ? 0 : Math.min(root.rowsHeight, scrim.height * 0.5)
              visible: height > 0
              clip: true
              model: Logic.sectionRows(root.results)
              boundsBehavior: Flickable.StopAtBounds
              delegate: Item {
                id: row
                required property var modelData
                readonly property string glyph: modelData.icon ? Logic.glyphFor(modelData.icon) : ""
                // what this row draws for its icon, for the test that no row shows a missing image
                readonly property string iconState: modelData.header !== undefined ? "header" : (glyph !== "" ? "glyph" : (ic.status === Image.Ready ? "image" : "letter"))
                width: list.width
                height: modelData.header !== undefined ? 26 : 46
                Text {
                  visible: row.modelData.header !== undefined
                  anchors.verticalCenter: parent.verticalCenter
                  x: 6
                  text: row.modelData.header !== undefined ? row.modelData.header.toUpperCase() : ""
                  color: win.th.dim
                  font.family: win.th.fontFamily
                  font.pixelSize: win.th.fs(11)
                  font.letterSpacing: 1
                }
                PanelFrame {
                  visible: row.modelData.header === undefined
                  th: win.th
                  kind: "row"
                  anchors.fill: parent
                  anchors.margins: 1
                  readonly property bool on: row.modelData.index === root.sel
                  // omarchy: the selection fill and the label in the accent, no border and no filled block; baneyspaces: a tinted
                  // rounded row with an accent border; minimal: a thin accent bar at the left and no fill.
                  readonly property string style: win.th.selectStyle
                  focused: on && style === "pill"
                  framed: on && style === "pill"
                  fillColor: on ? (style === "pill" ? Logic.alpha(win.th.accent, 0.26) : (style === "text" ? win.th.raisedHot : "transparent")) : (rowArea.containsMouse ? win.th.raised : "transparent")
                  Rectangle { visible: parent.on && parent.style === "line"; x: 0; y: 4; width: win.th.tok.border.width + 1; height: parent.height - 8; color: win.th.accent }
                  Text {
                    id: glyph
                    visible: row.glyph !== ""
                    x: 10; anchors.verticalCenter: parent.verticalCenter
                    width: 28
                    horizontalAlignment: Text.AlignHCenter
                    text: row.glyph
                    color: parent.on ? win.th.accent : win.th.fg
                    font.family: win.th.glyphFont
                    font.pixelSize: win.th.fs(20)
                  }
                  Image {
                    id: ic
                    x: 10; anchors.verticalCenter: parent.verticalCenter
                    width: 28; height: 28
                    visible: row.glyph === "" && status === Image.Ready
                    source: row.glyph === "" && row.modelData.icon ? root.bs.iconSource(row.modelData.icon) : ""
                    sourceSize.width: 56; sourceSize.height: 56
                    asynchronous: true
                  }
                  Rectangle {
                    visible: row.glyph === "" && ic.status !== Image.Ready && row.modelData.header === undefined
                    x: 10; anchors.verticalCenter: parent.verticalCenter
                    width: 28; height: 28; radius: Math.min(win.th.tok.radius.row, 8)
                    color: Logic.alpha(win.th.accent, 0.3)
                    Text { anchors.centerIn: parent; text: (row.modelData.title || "?").charAt(0).toUpperCase(); color: win.th.text; font.bold: true; font.pixelSize: win.th.fs(14); font.family: win.th.fontFamily }
                  }
                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 48
                    width: parent.width - 48 - 40
                    Text { width: parent.width; text: row.modelData.title || ""; elide: Text.ElideRight; color: (row.modelData.index === root.sel && win.th.selectStyle === "text") ? win.th.accent : win.th.text; font.family: win.th.fontFamily; font.pixelSize: win.th.fs(14) }
                    Text { width: parent.width; text: row.modelData.subtitle || ""; elide: Text.ElideRight; color: win.th.dim; font.family: win.th.fontFamily; font.pixelSize: win.th.fs(11); visible: text !== "" }
                  }
                  Rectangle {
                    visible: row.modelData.badge !== null && row.modelData.badge !== undefined
                    anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                    width: 10; height: 10; radius: 5 // structural: a dot
                    color: row.modelData.badge === "error" ? win.th.urgent : row.modelData.badge === "asking" ? win.th.warn : win.th.orange
                  }
                  MouseArea {
                    id: rowArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.sel = row.modelData.index
                    onClicked: root.run(row.modelData.index)
                  }
                }
              }
            }

            // Install and remove ask first.
            Rectangle {
              visible: root.confirm !== null
              width: parent.width
              height: 52
              radius: win.th.tok.radius.row
              color: Logic.alpha(win.th.warn, 0.18)
              border.color: win.th.warn
              border.width: 1
              Column {
                anchors.verticalCenter: parent.verticalCenter
                x: 14
                Text { text: root.confirm ? root.confirm.message : ""; color: win.th.text; font.family: win.th.fontFamily; font.pixelSize: win.th.fs(14); font.bold: true }
                Text { text: root.confirm ? "Return runs  " + root.confirm.command + "  in a terminal (it may ask for your password). Esc cancels." : ""; color: win.th.dim; font.family: win.th.fontFamily; font.pixelSize: win.th.fs(11) }
              }
            }

            Text {
              id: footer
              width: parent.width
              text: root.note !== "" ? root.note : "↵ open   ·   ⇥ actions   ·   ? help"
              color: root.note !== "" ? win.th.urgent : win.th.dim
              font.family: win.th.fontFamily
              font.pixelSize: win.th.fs(11)
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }

  function framesUsed() { return vs.instances.length ? vs.instances[0].framesUsed() : [] }

  IpcHandler {
    target: "baneyspaces.launcher"
    function state(): string { return JSON.stringify({ mode: root.mode, count: root.results.length, sel: root.sel, titles: root.results.slice(0, 12).map(function (r) { return r.title }), confirm: root.confirm }) }
    function type(text: string): string { root.tType = Date.now(); root.tTyped = 0; root.query = text; root.search(); return "ok" }
    // the icon of every row now drawn: glyph, image or letter (never a missing image)
    function icons(): string {
      var out = []
      for (var i = 0; i < 40; i++) { var it = root.listItem(i); if (it === null) break; if (it.iconState !== undefined && it.iconState !== "header") out.push({ title: it.modelData.title, state: it.iconState }) }
      return JSON.stringify(out)
    }
    function timing(): string { return JSON.stringify({ open_to_ready_ms: root.tReady - root.tOpen, type_to_first_result_ms: root.tTyped > 0 ? root.tTyped - root.tType : -1 }) }
    function mode(m: string): string { root.setMode(m); return "ok" }
    function select(i: int): string { root.sel = i; return "ok" }
    function run(i: int): string { root.run(i, false); return "ok" }
    function confirmRun(): string { if (!root.confirm) return "nothing to confirm"; root.run(root.results.findIndex(function (r) { return r.id === root.confirm.id }), true); return "ok" }
  }
}
