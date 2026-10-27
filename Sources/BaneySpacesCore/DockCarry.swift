import CoreGraphics

/// Another app's window dragged by its title bar down to the Workspace Dock's edge: the dock
/// comes up, the tile under the pointer lights, and letting go there sends the window to that
/// workspace. The window server keeps the drag; the dock only follows the pointer.
public enum DockCarry {
    /// The top edge is the overview's: a window dragged up there opens it (`TopDrag`), so a top
    /// dock never comes up for one.
    public static func accepts(_ edge: DockEdge) -> Bool { edge != .top }

    /// The pointer, in AppKit screen coordinates, in the dock's own space: top-left origin at
    /// `origin`, the top-left of its tiles' stack inside a panel framed at `panel` (screen
    /// coordinates, bottom-left origin), as the tiles report their frames.
    public static func point(_ mouse: CGPoint, panel: CGRect, origin: CGPoint) -> CGPoint {
        CGPoint(x: mouse.x - panel.minX - origin.x, y: panel.maxY - mouse.y - origin.y)
    }
}
