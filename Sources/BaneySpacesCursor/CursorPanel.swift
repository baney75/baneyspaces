import AppKit

/// The window the agent cursors are drawn in: one per display, covering it. It is never the pointer and
/// never takes one: it ignores the mouse, is never key or main, and `.nonactivatingPanel` keeps the app that owns it
/// from being activated when it is shown (it is shown with `orderFrontRegardless`, which activates nothing).
final class CursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = true
        // Above app windows (and the dock's panels), below menus.
        level = .statusBar
        // Out of screenshots and recordings of the display unless `agent shot --cursor` asks for it.
        sharingType = .none
        // Not joined to every Space until something is shown (`setShown`).
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
        let host = NSView(frame: CGRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        contentView = host
    }

    /// Joins all Spaces only while a cursor is on it; off screen it is ordered out and belongs to none.
    func setShown(_ shown: Bool) {
        if shown {
            collectionBehavior.insert(.canJoinAllSpaces)
            orderFrontRegardless()
        } else {
            orderOut(nil)
            collectionBehavior.remove(.canJoinAllSpaces)
        }
    }
}

/// A display the cursors can be drawn on: its frame in the hands' coordinates (global, y down) and the panel's
/// frame in AppKit's (global, y up).
public struct CursorDisplaySpec: Equatable {
    public var globalFrame: CGRect
    public var panelFrame: CGRect
    public var scale: CGFloat
    public init(globalFrame: CGRect, panelFrame: CGRect, scale: CGFloat) {
        self.globalFrame = globalFrame; self.panelFrame = panelFrame; self.scale = scale
    }

    /// The Mac's displays.
    public static func screens() -> [CursorDisplaySpec] {
        guard let primary = NSScreen.screens.first else { return [] }
        let top = primary.frame.maxY
        return NSScreen.screens.map {
            CursorDisplaySpec(globalFrame: CGRect(x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height),
                              panelFrame: $0.frame, scale: $0.backingScaleFactor)
        }
    }
}

/// One display's overlay: the panel, its root layer, and the maths from the hands' coordinates to layer ones.
final class CursorDisplay {
    let spec: CursorDisplaySpec
    let panel: CursorPanel
    let root: CALayer
    private(set) var shownCount = 0

    init(_ spec: CursorDisplaySpec) {
        self.spec = spec
        panel = CursorPanel(frame: spec.panelFrame)
        root = panel.contentView!.layer!
    }

    /// A point of the hands (global, y down) in this overlay's layers (y up).
    func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - spec.globalFrame.minX, y: spec.globalFrame.maxY - p.y) }

    func local(_ r: CGRect) -> CGRect {
        let o = local(CGPoint(x: r.minX, y: r.maxY))
        return CGRect(x: o.x, y: o.y, width: r.width, height: r.height)
    }

    func contains(_ p: CGPoint) -> Bool { spec.globalFrame.contains(p) }

    func cursorShown() {
        shownCount += 1
        if shownCount == 1 { panel.setShown(true) }
    }

    func cursorHidden() {
        shownCount = max(0, shownCount - 1)
        // After the cursor's fade-out has played.
        if shownCount == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.shownCount == 0 else { return }
                self.panel.setShown(false)
            }
        }
    }

    func close() { panel.orderOut(nil); panel.close() }
}
