import AppKit
import BaneySpacesCore

/// `agent shot --cursor`: draws an agent's cursor into a window capture. The capture itself never contains the
/// overlay (it is a capture of the app's window alone), so the evidence is the app unless this is asked for.
public enum ShotComposite {
    /// `image` is a capture of `windowFrame` (hands' coordinates) at `scale` pixels per point. Nil when nothing was
    /// drawn: the mark falls outside the capture, or the picture's format can't be drawn on without converting it.
    /// The result keeps the capture's color space and pixel format.
    public static func draw(_ mark: CursorMark, onto image: CGImage, windowFrame: CGRect, scale: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        // The mark's point in the capture's pixels (y up in the context).
        let px = (mark.point.x - windowFrame.minX) * scale
        let py = CGFloat(h) - (mark.point.y - windowFrame.minY) * scale
        guard px >= 0, py >= 0, px <= CGFloat(w), py <= CGFloat(h) else { return nil }
        guard let space = image.colorSpace,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0,
                                  space: space, bitmapInfo: image.bitmapInfo.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let t = mark.look.theme
        ctx.saveGState()
        ctx.translateBy(x: px, y: py)
        ctx.scaleBy(x: scale, y: -scale)   // glyph paths are y down
        ctx.addPath(CursorGlyphs.path(t.glyph, size: t.size))
        switch t.fill {
        case .status:
            ctx.setFillColor(AgentCursor.color(mark.look.statusColor))
            ctx.setStrokeColor(AgentCursor.color(mark.look.identity))
            ctx.setLineWidth(max(t.ringWidth, 1))
        case .light:
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(1.3)
        }
        ctx.setLineJoin(t.glyph == .block ? .miter : .round)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}
