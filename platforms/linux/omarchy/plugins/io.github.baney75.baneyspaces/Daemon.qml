import QtQuick
import Quickshell
import Quickshell.Io

// The connection to `baneyspaces daemon`: one Unix socket, JSON lines. `subscribe` makes the daemon push a
// full snapshot whenever anything changes; requests ride the same socket and are answered with their id.
Item {
  id: root
  visible: false

  property string socketPath: (Quickshell.env("BANEYSPACES_SOCKET") || "") !== ""
    ? Quickshell.env("BANEYSPACES_SOCKET")
    : (Quickshell.env("XDG_RUNTIME_DIR") + "/baneyspaces/ctl.sock")
  property var state: ({})
  property bool connected: false
  property int nextId: 1
  property var pending: ({})
  signal snapshot(var s)

  // call("switch", {n: 3}, function (reply) { ... })
  function call(op, args, done) {
    var id = nextId++
    if (done) pending[id] = done
    if (!connected) {
      if (done) { delete pending[id]; done({ ok: false, error: { code: "daemon_down", message: "baneyspaces daemon is not running" } }) }
      return
    }
    sock.write(JSON.stringify({ op: op, args: args || {}, id: id }) + "\n")
    sock.flush()
  }

  function onLine(line) {
    var m
    try { m = JSON.parse(line) } catch (e) { return }
    if (m.event === "ui") {
      state = m.data
      snapshot(m.data)
    } else if (m.id !== undefined && pending[m.id]) {
      var cb = pending[m.id]
      delete pending[m.id]
      cb(m)
    }
  }

  Socket {
    id: sock
    path: root.socketPath
    connected: true
    parser: SplitParser { splitMarker: "\n"; onRead: function (data) { root.onLine(data) } }
    onConnectedChanged: {
      root.connected = connected
      if (connected) { write('{"op":"subscribe"}\n'); flush() }
    }
  }

  // The daemon may start after the shell, or restart: keep trying.
  Timer {
    interval: 1000
    repeat: true
    running: !root.connected
    onTriggered: { sock.connected = false; sock.connected = true }
  }
}
