// Renders the app icon into an .iconset (then `iconutil -c icns`).
//   swift scripts/make-icon.swift build/AppIcon.iconset
//
// A shield with a lock on a night-sky tile, ringed by a constellation: the
// tunnel guarding your traffic on its way home. Below 64 px the stars would
// turn into noise, so small sizes show the shield alone, a little larger.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// A star of the constellation, in fractions of the icon size (origin bottom left).
struct Star {
    let x: CGFloat, y: CGFloat
    /// Radius of the sparkle, in fractions of the icon size.
    let r: CGFloat
}

// Clockwise around the shield, irregular like a real constellation.
let ring: [Star] = [
    Star(x: 0.205, y: 0.585, r: 0.020),
    Star(x: 0.255, y: 0.735, r: 0.014),
    Star(x: 0.385, y: 0.815, r: 0.024),
    Star(x: 0.565, y: 0.825, r: 0.013),
    Star(x: 0.715, y: 0.755, r: 0.021),
    Star(x: 0.800, y: 0.600, r: 0.015),
    Star(x: 0.785, y: 0.395, r: 0.025),
    Star(x: 0.675, y: 0.235, r: 0.014),
    Star(x: 0.495, y: 0.180, r: 0.019),
    Star(x: 0.320, y: 0.225, r: 0.013),
    Star(x: 0.215, y: 0.380, r: 0.017),
]
// Lines between consecutive stars; one gap keeps it from reading as a circle.
let gapAfter = 9
// Faint background stars for depth.
let dust: [Star] = [
    Star(x: 0.170, y: 0.820, r: 0.004), Star(x: 0.470, y: 0.885, r: 0.003),
    Star(x: 0.840, y: 0.830, r: 0.005), Star(x: 0.855, y: 0.215, r: 0.004),
    Star(x: 0.165, y: 0.175, r: 0.003), Star(x: 0.600, y: 0.130, r: 0.003),
    Star(x: 0.880, y: 0.480, r: 0.003), Star(x: 0.135, y: 0.470, r: 0.004),
]

let skyTop = NSColor(calibratedRed: 0.13, green: 0.40, blue: 0.93, alpha: 1)
let skyBottom = NSColor(calibratedRed: 0.03, green: 0.09, blue: 0.32, alpha: 1)
let shieldInk = NSColor(calibratedRed: 0.08, green: 0.24, blue: 0.66, alpha: 1)
let starlight = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.86, alpha: 1)

func point(_ s: Star, _ size: CGFloat) -> NSPoint { NSPoint(x: s.x * size, y: s.y * size) }

/// A four-pointed sparkle with a soft glow.
func drawStar(_ s: Star, size: CGFloat) {
    let c = point(s, size)
    let r = s.r * size
    NSGradient(colors: [starlight.withAlphaComponent(0.55), starlight.withAlphaComponent(0)])!
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: r * 2.6, options: [])
    let inner = r * 0.28
    let path = NSBezierPath()
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4 + .pi / 2
        let len = i.isMultiple(of: 2) ? r : inner
        let p = NSPoint(x: c.x + cos(angle) * len, y: c.y + sin(angle) * len)
        if i == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    path.close()
    starlight.setFill()
    path.fill()
}

func drawConstellation(size: CGFloat) {
    for s in dust {
        let c = point(s, size), r = s.r * size
        starlight.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
    }
    let lines = NSBezierPath()
    lines.lineWidth = max(1, size * 0.0045)
    lines.lineCapStyle = .round
    for i in ring.indices where i != gapAfter {
        lines.move(to: point(ring[i], size))
        lines.line(to: point(ring[(i + 1) % ring.count], size))
    }
    starlight.withAlphaComponent(0.38).setStroke()
    lines.stroke()
    ring.forEach { drawStar($0, size: size) }
}

func drawShield(size: CGFloat, scale: CGFloat) {
    let config = NSImage.SymbolConfiguration(pointSize: size * scale, weight: .semibold)
        .applying(.init(paletteColors: [shieldInk, .white]))
    guard let symbol = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return }
    let s = symbol.size
    // whole pixels: a fractional origin softens every edge of the shield
    let rect = NSRect(x: ((size - s.width) / 2).rounded(), y: ((size - s.height) / 2).rounded(),
                      width: s.width.rounded(), height: s.height.rounded())
    // a tight shadow below lifts the shield off the sky without blurring its edge
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.shadowBlurRadius = size * 0.018
    shadow.set()
    symbol.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body with ~185/1024 corner radius
    let inset = size * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: size * 185 / 1024, yRadius: size * 185 / 1024)
    NSGradient(colors: [skyTop, skyBottom])!.draw(in: shape, angle: -90)

    if pixels >= 64 {
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        drawConstellation(size: size)
        NSGraphicsContext.restoreGraphicsState()
        drawShield(size: size, scale: 0.34)
    } else {
        drawShield(size: size, scale: 0.46)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(points * scale).write(to: output.appendingPathComponent(name))
    }
}
