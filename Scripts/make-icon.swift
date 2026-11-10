// Draws the Lid Awake icon: a night-sky squircle with a closed laptop whose
// seam still glows green. Run Scripts/make-icon.sh to rebuild the assets.
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 1024
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }

        // Background: macOS squircle, deep night gradient.
        let tile = NSBezierPath(roundedRect: rect(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 28 * s
        shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
        shadow.set()
        NSColor(red: 0.07, green: 0.09, blue: 0.22, alpha: 1).setFill()
        tile.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSGraphicsContext.current?.saveGraphicsState()
        tile.addClip()
        NSGradient(colors: [NSColor(red: 0.20, green: 0.22, blue: 0.52, alpha: 1),
                            NSColor(red: 0.06, green: 0.08, blue: 0.20, alpha: 1)])!
            .draw(in: tile, angle: -90)

        // Stars and moon.
        NSColor.white.withAlphaComponent(0.85).setFill()
        for (x, y, r) in [(250.0, 760.0, 9.0), (340, 840, 6), (430, 720, 5), (205, 640, 5), (560, 830, 7), (800, 560, 5)] {
            NSBezierPath(ovalIn: rect(x - r, y - r, r * 2, r * 2)).fill()
        }
        // Crescent: the moon disk minus an offset disk.
        let context = NSGraphicsContext.current!.cgContext
        context.addPath(CGPath(ellipseIn: rect(640, 660, 170, 170), transform: nil)
            .subtracting(CGPath(ellipseIn: rect(690, 700, 160, 160), transform: nil)))
        context.setFillColor(NSColor(red: 1.0, green: 0.86, blue: 0.55, alpha: 1).cgColor)
        context.fillPath()

        // Green glow leaking from the laptop seam.
        let glowCenter = NSPoint(x: 512 * s, y: 395 * s)
        NSGradient(colors: [NSColor(red: 0.30, green: 0.95, blue: 0.55, alpha: 0.55),
                            NSColor(red: 0.30, green: 0.95, blue: 0.55, alpha: 0)])!
            .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 330 * s, options: [])

        // Closed laptop: lid on top of the base, seen slightly from the front.
        let silver = NSGradient(colors: [NSColor(white: 0.97, alpha: 1), NSColor(white: 0.74, alpha: 1)])!
        let base = NSBezierPath(roundedRect: rect(232, 300, 560, 74), xRadius: 30 * s, yRadius: 30 * s)
        silver.draw(in: base, angle: -90)
        let lid = NSBezierPath(roundedRect: rect(262, 404, 500, 54), xRadius: 26 * s, yRadius: 26 * s)
        silver.draw(in: lid, angle: -90)
        // Notch on the base front edge.
        NSColor(white: 0.62, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect(462, 300, 100, 14), xRadius: 7 * s, yRadius: 7 * s).fill()

        // Seam light: the work keeps running inside.
        let seam = NSBezierPath(roundedRect: rect(282, 378, 460, 22), xRadius: 11 * s, yRadius: 11 * s)
        NSColor(red: 0.36, green: 1.0, blue: 0.60, alpha: 1).setFill()
        seam.fill()

        // Status dot, the same signal the menu bar shows.
        let dot = rect(706, 196, 92, 92)
        NSColor(red: 0.07, green: 0.09, blue: 0.22, alpha: 1).setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -14 * s, dy: -14 * s)).fill()
        NSColor(red: 0.20, green: 0.84, blue: 0.40, alpha: 1).setFill()
        NSBezierPath(ovalIn: dot).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        return true
    }
}

func writePNG(_ image: NSImage, pixels: Int, to path: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// Usage: make-icon <iconset dir> <logo.png>
let arguments = CommandLine.arguments
let iconset = arguments[1]
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try writePNG(drawIcon(size: CGFloat(points)), pixels: points, to: "\(iconset)/icon_\(points)x\(points).png")
    try writePNG(drawIcon(size: CGFloat(points * 2)), pixels: points * 2, to: "\(iconset)/icon_\(points)x\(points)@2x.png")
}
try writePNG(drawIcon(size: 512), pixels: 512, to: arguments[2])
