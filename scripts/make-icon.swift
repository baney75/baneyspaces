// Draws the BaneySpaces icon: nine tiles on a dark squircle, one lit.
//   swift scripts/make-icon.swift build/BaneySpaces.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: the shape fills about 80% of the canvas.
    let inset = s * 0.1, body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.15, blue: 0.20, alpha: 1),
               ending: NSColor(srgbRed: 0.06, green: 0.07, blue: 0.10, alpha: 1))!.draw(in: bg, angle: -90)
    let pad = body.width * 0.16, gap = body.width * 0.05
    let tile = (body.width - 2 * pad - 2 * gap) / 3
    for row in 0..<3 {
        for col in 0..<3 {
            let r = CGRect(x: body.minX + pad + CGFloat(col) * (tile + gap),
                           y: body.maxY - pad - tile - CGFloat(row) * (tile + gap), width: tile, height: tile)
            let lit = row == 0 && col == 1   // workspace 2
            (lit ? NSColor(srgbRed: 0.91, green: 0.26, blue: 0.29, alpha: 1)
                 : NSColor(white: 1, alpha: 0.14)).setFill()
            NSBezierPath(roundedRect: r, xRadius: tile * 0.22, yRadius: tile * 0.22).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
