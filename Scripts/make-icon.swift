import AppKit

// Usage: swift make-icon.swift <output.iconset>
// Draws a sea-blue rounded square with a segmented "wheel" glyph.
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: 824/1024 squircle with a soft drop shadow.
    let rect = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor(red: 0.20, green: 0.66, blue: 0.80, alpha: 1).setFill()
    bg.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.66, green: 0.90, blue: 0.95, alpha: 1), NSColor(red: 0.13, green: 0.58, blue: 0.74, alpha: 1)])!
        .draw(in: bg, angle: -90)
    // glass sheen on the upper half
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.55), NSColor(white: 1, alpha: 0.0)])!
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let c = NSPoint(x: s / 2, y: s / 2)
    let n = 8
    for i in 0..<n {
        let step = 360.0 / Double(n)
        let a0 = 90 - Double(i) * step - 3, a1 = 90 - Double(i + 1) * step + 3
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: s * 0.28, startAngle: a0, endAngle: a1, clockwise: true)
        p.appendArc(withCenter: c, radius: s * 0.105, startAngle: a1, endAngle: a0, clockwise: false)
        p.close()
        NSColor(white: 1, alpha: i == 1 ? 1.0 : 0.82).setFill()
        p.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("\(name).png"))
}
