// Generates Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset: CGFloat = 100
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.52, blue: 1.0, alpha: 1),
                        NSColor(srgbRed: 0.45, green: 0.33, blue: 0.95, alpha: 1)])!
        .draw(in: shape, angle: -60)

    // A note card sliding in from the right edge.
    let card = NSRect(x: rect.minX + 250, y: rect.minY + 150, width: rect.width - 250, height: rect.height - 300)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 60, yRadius: 60)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSColor.white.withAlphaComponent(0.95).setFill()
    cardPath.fill()
    NSColor(srgbRed: 0.4, green: 0.42, blue: 0.95, alpha: 0.35).setFill()
    for (i, w) in [0.62, 0.8, 0.5].enumerated() {
        let y = card.maxY - 130 - CGFloat(i) * 105
        NSBezierPath(roundedRect: NSRect(x: card.minX + 80, y: y, width: (card.width - 80) * w, height: 38),
                     xRadius: 19, yRadius: 19).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return true
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
