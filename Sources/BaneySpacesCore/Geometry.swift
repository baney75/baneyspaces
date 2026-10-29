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

    /// The display a window is on: the one holding most of it. Nil for a window on none (one
    /// parked off every display).
    public static func display<Key>(of frame: CGRect, in displays: [Key: CGRect]) -> Key? {
        var best: (Key, CGFloat)?
        for (key, rect) in displays {
            let i = rect.intersection(frame)
            guard !i.isNull, i.width * i.height > 0 else { continue }
            let area = i.width * i.height
            if best.map({ area > $0.1 }) ?? true { best = (key, area) }
        }
        guard let best, best.1 >= frame.width * frame.height * 0.25 else { return nil }
        return best.0
    }

    /// A window's frame carried from one display to another: the same place relative to the
    /// display's visible area, shrunk to fit if the new display is smaller.
    public static func carry(_ frame: CGRect, from a: CGRect, to b: CGRect) -> CGRect {
        let w = min(frame.width, b.width), h = min(frame.height, b.height)
        // Where the window's middle sat, as a fraction of the old display, placed the same on
        // the new one and kept inside it.
        let fx = a.width > 0 ? (frame.midX - a.minX) / a.width : 0.5
        let fy = a.height > 0 ? (frame.midY - a.minY) / a.height : 0.5
        let x = min(max(b.minX + fx * b.width - w / 2, b.minX), b.maxX - w)
        let y = min(max(b.minY + fy * b.height - h / 2, b.minY), b.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h).integral
    }

    /// Whether `rects` together leave no part of `area` showing. Exact: the rects' edges cut
    /// the area into cells, and the middle of every cell must be inside some rect, so even a
    /// one-point gap between two windows counts as showing.
    public static func covers(_ rects: [CGRect], area: CGRect) -> Bool {
        guard !area.isNull, !area.isEmpty else { return true }
        let clipped = rects.map { $0.intersection(area) }.filter { !$0.isNull && !$0.isEmpty }
        func cuts(_ edges: [CGFloat], _ lo: CGFloat, _ hi: CGFloat) -> [CGFloat] {
            Array(Set(edges.filter { $0 > lo && $0 < hi } + [lo, hi])).sorted()
        }
        let xs = cuts(clipped.flatMap { [$0.minX, $0.maxX] }, area.minX, area.maxX)
        let ys = cuts(clipped.flatMap { [$0.minY, $0.maxY] }, area.minY, area.maxY)
        for (y0, y1) in zip(ys, ys.dropFirst()) {
            for (x0, x1) in zip(xs, xs.dropFirst()) {
                let mid = CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2)
                if !clipped.contains(where: { $0.contains(mid) }) { return false }
            }
        }
        return true
    }
}
