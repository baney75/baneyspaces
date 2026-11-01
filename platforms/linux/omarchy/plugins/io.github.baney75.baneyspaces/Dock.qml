import QtQuick
import Quickshell
import Quickshell.Io

// The Workspace Dock: one DockScreen per display. The pointer is watched by the daemon (a Wayland client
// cannot see it), which says when and on which display the dock is up; this draws it.
Item {
  id: root
  visible: false
  required property var bs

  Variants {
    id: screens
    // dock.enabled = false: every dock window stays unmapped, so no layer surface exists (hyprctl layers shows none)
    model: Quickshell.screens
    DockScreen { required property var modelData; screen: modelData; bs: root.bs }
  }

  function framesUsed() { var out = []; for (var i = 0; i < screens.instances.length; i++) out = out.concat(screens.instances[i].framesUsed()); return out.slice(0, 80) }
  function scopeFor(name) {
    for (var i = 0; i < screens.instances.length; i++) if (screens.instances[i].screen && screens.instances[i].screen.name === name) return screens.instances[i]
    return screens.instances.length ? screens.instances[0] : null
  }
  function target() {
    var m = bs.st.dock ? bs.st.dock.monitor : null
    return scopeFor(m || bs.st.focused_monitor)
  }

  // Test and scripting hooks: the same code paths the pointer takes, without a pointer.
  IpcHandler {
    target: "baneyspaces.dock"
    function state(): string { var s = root.target(); return s ? JSON.stringify(s.describe()) : "{}" }
    function clickTile(n: int): string { var s = root.target(); return s ? s.clickTile(n) : "no dock" }
    function clickApp(n: int, app: string): string { var s = root.target(); return s ? s.clickApp(n, app) : "no dock" }
    function openList(n: int, kind: string): string { var s = root.target(); return s ? s.openListFor(n, kind) : "no dock" }
    function closeList(): string { var s = root.target(); if (s) s.closeList(); return "ok" }
    function dragApp(n: int, app: string, to: int): string { var s = root.target(); return s ? s.dragApp(n, app, to) : "no dock" }
    function dragRow(row: int, to: int): string { var s = root.target(); return s ? s.dragRow(row, to) : "no dock" }
  }
}
