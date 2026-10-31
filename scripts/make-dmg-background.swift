// Draws the disk image's background, at 1x and 2x for Retina:
//   swift scripts/make-dmg-background.swift build/dmg
// writes background.png (640x400) and background@2x.png (1280x800) there; package.sh combines
// them into one TIFF with `tiffutil -cathidpicheck`. The arrow runs between the two icon
// centers set in scripts/dmg-settings.py: (170, 190) and (470, 190) from the window's top left.
import AppKit

let out = CommandLine.arguments[1]
let ink = NSColor(srgbRed: 0.145, green: 0.165, blue: 0.231, alpha: 1)
let red = NSColor(srgbRed: 0.91, green: 0.26, blue: 0.29, alpha: 1)

func render(scale: Int, to name: String) {
    let w = 640 * scale, h = 400 * scale
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(scale)
    ctx.scaleBy(x: s, y: s)  // from here on, points; the origin is the bottom left
    let light = CGColor(srgbRed: 0.985, green: 0.985, blue: 0.99, alpha: 1)
    let shade = CGColor(srgbRed: 0.90, green: 0.91, blue: 0.93, alpha: 1)
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [light, shade] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: 400), end: CGPoint(x: 0, y: 0), options: [.drawsAfterEndLocation])

    // The arrow: a shaft and a head, at the icons' height (190 from the top).
    let y: CGFloat = 400 - 190
    ctx.setStrokeColor(red.cgColor)
    ctx.setFillColor(red.cgColor)
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 262, y: y))
    ctx.addLine(to: CGPoint(x: 360, y: y))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 384, y: y))
    ctx.addLine(to: CGPoint(x: 352, y: y + 20))
    ctx.addLine(to: CGPoint(x: 352, y: y - 20))
    ctx.closePath()
    ctx.fillPath()

    // Centered text; `top` is the baseline's distance from the window's top.
    func text(_ str: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: color]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (640 - width) / 2, y: 400 - top)
        CTLineDraw(line, ctx)
    }
    text("Drag BaneySpaces to Applications", size: 22, weight: .semibold, color: ink, top: 66)
    text("First open: System Settings › Privacy & Security › Open Anyway", size: 12.5, weight: .regular,
         color: ink.withAlphaComponent(0.6), top: 352)

    // Set the size in points so the 2x file carries 144 dpi, which tiffutil needs to pair them.
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: 640, height: 400)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
render(scale: 1, to: "background.png")
render(scale: 2, to: "background@2x.png")
