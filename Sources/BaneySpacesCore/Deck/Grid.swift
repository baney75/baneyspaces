import CoreGraphics

/// Where `count` windows go in `area`, row by row. Coordinates are whatever `area` uses; the app
/// passes Accessibility's top-left space, so row 0 is the top.
public enum Grid {
    /// A terminal reads best a bit wider than tall. Among every column count, the one whose
    /// cells come closest to this shape wins: 2 windows sit side by side, 3 or 4 make a 2×2.
    public static let idealAspect: CGFloat = 1.6

    public static func columns(for count: Int, in area: CGSize) -> Int {
        guard count > 1, area.width > 0, area.height > 0 else { return 1 }
        var best = 1
        var bestScore = CGFloat.infinity
        for cols in 1...count {
            let rows = (count + cols - 1) / cols
            let aspect = (area.width / CGFloat(cols)) / (area.height / CGFloat(rows))
            let score = abs(log(aspect / idealAspect))
            if score < bestScore - 0.0001 { best = cols; bestScore = score }
        }
        return best
    }

    /// One frame per window, in order. The last row's windows widen to fill it, so no hole is left.
    public static func frames(count: Int, in area: CGRect, gap: CGFloat = 6) -> [CGRect] {
        guard count > 0 else { return [] }
        let cols = columns(for: count, in: area.size)
        let rows = (count + cols - 1) / cols
        let h = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        var out: [CGRect] = []
        for row in 0..<rows {
            let inRow = min(cols, count - row * cols)
            let w = (area.width - gap * CGFloat(inRow - 1)) / CGFloat(inRow)
            for col in 0..<inRow {
                out.append(CGRect(x: (area.minX + CGFloat(col) * (w + gap)).rounded(),
                                  y: (area.minY + CGFloat(row) * (h + gap)).rounded(),
                                  width: w.rounded(), height: h.rounded()))
            }
        }
        return out
    }
}
