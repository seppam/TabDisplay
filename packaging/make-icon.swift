// Renders the app icon into an .iconset folder; build-app.sh turns it into AppIcon.icns.
// Usage: swift packaging/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: ~80% artwork inside the canvas, rounded square.
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.98, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.62, alpha: 1))!.draw(in: tile, angle: -90)

    // Tablet in landscape: white bezel, dark screen showing two small "windows".
    let w = rect.width
    let body = NSRect(x: rect.midX - w * 0.34, y: rect.midY - w * 0.22, width: w * 0.68, height: w * 0.44)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: body, xRadius: w * 0.05, yRadius: w * 0.05).fill()
    let screen = body.insetBy(dx: w * 0.03, dy: w * 0.03)
    NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.40, alpha: 1).setFill()
    NSBezierPath(roundedRect: screen, xRadius: w * 0.025, yRadius: w * 0.025).fill()
    let win1 = NSRect(x: screen.minX + screen.width * 0.08, y: screen.minY + screen.height * 0.18, width: screen.width * 0.5, height: screen.height * 0.6)
    let win2 = NSRect(x: screen.minX + screen.width * 0.45, y: screen.minY + screen.height * 0.3, width: screen.width * 0.45, height: screen.height * 0.55)
    NSColor(calibratedRed: 0.55, green: 0.75, blue: 1, alpha: 1).setFill()
    NSBezierPath(roundedRect: win1, xRadius: w * 0.012, yRadius: w * 0.012).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: win2, xRadius: w * 0.012, yRadius: w * 0.012).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
