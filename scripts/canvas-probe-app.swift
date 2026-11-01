// A window that draws where the mouse is pressed and dragged, and exposes nothing to accessibility but its
// frame: a stand-in for a canvas app, for scripts/agent-keys-probe.swift. It reads no files and writes none.
// The probe compiles it with swiftc into BaneySpaces' own probe-apps folder, the only place the agent policy
// starts it from (AgentAppPolicy.canvasProbeBundle).
import AppKit

final class Canvas: NSView {
    var strokes: [[NSPoint]] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        strokes.append([convert(event.locationInWindow, from: nil)])
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func draw(_ dirty: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        NSColor.black.setStroke()
        NSColor.black.setFill()
        for s in strokes {
            if s.count == 1, let p = s.first {
                NSBezierPath(ovalIn: NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)).fill()
                continue
            }
            let path = NSBezierPath()
            path.lineWidth = 6
            path.lineCapStyle = .round
            path.move(to: s[0])
            for p in s.dropFirst() { path.line(to: p) }
            path.stroke()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Canvas Probe"
window.contentView = Canvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
window.isReleasedWhenClosed = false
window.makeKeyAndOrderFront(nil)
app.run()
