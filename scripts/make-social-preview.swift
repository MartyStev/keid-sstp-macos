// Renders the GitHub social preview (1280×640) shown when the repository link
// is shared. Upload it in the repository's Settings → Social preview.
//   swift scripts/make-social-preview.swift <icon-512.png> docs/social-preview.png
import AppKit

let args = CommandLine.arguments.dropFirst()
guard args.count == 2, let icon = NSImage(contentsOfFile: args.first!) else {
    FileHandle.standardError.write(Data("usage: make-social-preview.swift <icon.png> <output.png>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: args.last!)

let width = 1280, height = 640
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let canvas = NSRect(x: 0, y: 0, width: width, height: height)

// the same night sky as the icon
NSGradient(colors: [
    NSColor(calibratedRed: 0.03, green: 0.09, blue: 0.32, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.80, alpha: 1),
])!.draw(in: canvas, angle: 20)

// scattered stars, fixed positions so the image is reproducible
var seed: UInt64 = 7
func next() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
}
for _ in 0..<90 {
    let r = 0.6 + next() * 1.8
    NSColor.white.withAlphaComponent(0.25 + next() * 0.5).setFill()
    NSBezierPath(ovalIn: NSRect(x: next() * CGFloat(width), y: next() * CGFloat(height), width: r * 2, height: r * 2)).fill()
}

icon.draw(in: NSRect(x: 70, y: 150, width: 340, height: 340))

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
    ]
    NSAttributedString(string: string, attributes: attributes).draw(at: NSPoint(x: 450, y: y))
}
text("Keid", size: 82, weight: .bold, alpha: 1, y: 380)
text("SSTP VPN for macOS in the menu bar", size: 36, weight: .medium, alpha: 0.92, y: 320)
text("Keenetic · KeenDNS · MikroTik · Windows RRAS · SoftEther", size: 26, weight: .regular, alpha: 0.75, y: 255)
text("Apple Silicon & Intel · free · open source", size: 26, weight: .regular, alpha: 0.75, y: 215)

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: output)
