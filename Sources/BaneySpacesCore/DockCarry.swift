import CoreGraphics

/// Another app's window dragged by its title bar down to the Workspace Dock's edge: the dock
/// comes up, the tile under the pointer lights, and letting go there sends the window to that
/// workspace. The window server keeps the drag; the dock only follows the pointer.
public enum DockCarry {
    /// Only a dock on the bottom edge. The top edge is the overview's (`TopDrag`), and at the
    /// left and right edges macOS tiles the window to half the screen for the same drag.
    public static func accepts(_ edge: DockEdge) -> Bool { edge == .bottom }

    /// The pointer, in AppKit screen coordinates, in the dock's own space: top-left origin at
    /// `origin`, the top-left of its tiles' stack inside a panel framed at `panel` (screen
    /// coordinates, bottom-left origin), as the tiles report their frames.
    public static func point(_ mouse: CGPoint, panel: CGRect, origin: CGPoint) -> CGPoint {
        CGPoint(x: mouse.x - panel.minX - origin.x, y: panel.maxY - mouse.y - origin.y)
    }
}
