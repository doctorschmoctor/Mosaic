import AppKit

// Original vector artwork rendered by AppKit. Regenerate with `swift scripts/make-icon.swift`.
let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/Mosaic.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, size) in [("16x16",16), ("16x16@2x",32), ("32x32",32), ("32x32@2x",64), ("128x128",128), ("128x128@2x",256), ("256x256",256), ("256x256@2x",512), ("512x512",512), ("512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(size) / 1024)
    (transform as NSAffineTransform).concat()
    let base = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190)
    // Logo green #39FF5A, with a slightly deeper shade of the same hue at the bottom edge.
    NSGradient(colors: [NSColor(red: 0x39 / 255, green: 0xFF / 255, blue: 0x5A / 255, alpha: 1), NSColor(red: 0x2B / 255, green: 0xE8 / 255, blue: 0x4B / 255, alpha: 1)])!.draw(in: base, angle: -80)
    for (x,y,alpha) in [(210.0,540.0,1.0),(535.0,540.0,0.85),(210.0,220.0,0.85),(535.0,220.0,1.0)] {
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 280, height: 255), xRadius: 58, yRadius: 58).fill()
        let tail = NSBezierPath(); tail.move(to: NSPoint(x: x + 48, y: y + 25)); tail.line(to: NSPoint(x: x + 48, y: y - 25)); tail.line(to: NSPoint(x: x + 115, y: y + 25)); tail.close(); tail.fill()
        NSColor(red: 0x1C / 255, green: 0xB8 / 255, blue: 0x3D / 255, alpha: 0.7).setFill()
        for dot in 0..<3 { NSBezierPath(ovalIn: NSRect(x: x + 66 + Double(dot) * 55, y: y + 112, width: 30, height: 30)).fill() }
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(name).png"))
}
