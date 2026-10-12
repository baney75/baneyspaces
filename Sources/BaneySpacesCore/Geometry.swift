import CoreGraphics

/// Screen math in Accessibility coordinates: the origin is the top-left corner of the primary
/// display and y grows downward.
public enum Geometry {
    /// AppKit screen frames have a bottom-left origin. `primaryHeight` is the primary display's height.
    public static func toAX(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Where hidden windows wait: their top-left corner sits on the last pixel of the screen that
    /// reaches furthest down and right, so the window hangs off every display. One pixel stays on
    /// screen because macOS pulls windows that are fully off-screen back into view.
    public static func hidingSpot(screens: [CGRect]) -> CGPoint {
        guard let s = screens.max(by: { ($0.maxX + $0.maxY) < ($1.maxX + $1.maxY) }) else { return .zero }
        return CGPoint(x: s.maxX - 1, y: s.maxY - 1)
    }

    /// How much of a frame shows on the screens, from 0 to 1.
    public static func visibleFraction(_ frame: CGRect, screens: [CGRect]) -> CGFloat {
        let area = frame.width * frame.height
        guard area > 0 else { return 0 }
        let shown = screens.reduce(CGFloat(0)) { sum, s in
            let i = s.intersection(frame)
            return i.isNull ? sum : sum + i.width * i.height
        }
        return min(1, shown / area)
    }

    /// True for a window a person could not reasonably find or grab: under a quarter of it shows.
    /// Catches windows parked by this app, by another window manager, or left by a display unplug.
    public static func isStranded(_ frame: CGRect, screens: [CGRect]) -> Bool {
        visibleFraction(frame, screens: screens) < 0.25
    }

    /// A frame to bring a window back to. The saved frame wins when at least half of it is on a
    /// screen; otherwise the window is centered on the first screen, shrunk to fit if needed.
    public static func restoreFrame(saved: CGRect?, size: CGSize, screens: [CGRect]) -> CGRect {
        if let saved, visibleFraction(saved, screens: screens) >= 0.5 { return saved }
        guard let s = screens.first else { return CGRect(origin: .zero, size: size) }
        let w = min(saved?.width ?? size.width, s.width), h = min(saved?.height ?? size.height, s.height)
        return CGRect(x: s.midX - w / 2, y: s.midY - h / 2, width: w, height: h).integral
    }

    /// Whether `rects` together leave no part of `area` showing, checked on a grid of points
    /// `step` apart plus the far edges. A window moving under them can't be seen.
    public static func covers(_ rects: [CGRect], area: CGRect, step: CGFloat = 8) -> Bool {
        guard !area.isEmpty else { return true }
        var xs = Array(stride(from: area.minX + 0.5, to: area.maxX, by: step)); xs.append(area.maxX - 0.5)
        var ys = Array(stride(from: area.minY + 0.5, to: area.maxY, by: step)); ys.append(area.maxY - 0.5)
        for y in ys {
            for x in xs where !rects.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { return false }
        }
        return true
    }
}
