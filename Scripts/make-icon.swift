// Draws the AlwaysDock app icon (two displays, each with its own dock) and writes Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Draws in a 1024×1024 canvas following Apple's macOS icon grid (824×824 body, room for the drop shadow).
/// `scale` is the canvas-to-pixel factor, needed because shadows ignore the context transform.
func drawIcon(scale: CGFloat) {
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.set()
    rgb(40, 40, 120).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: rgb(84, 128, 255), ending: rgb(52, 38, 168))!.draw(in: body, angle: -90)

    for x: CGFloat in [170, 524] {
        drawDisplay(x: x, scale: scale)
    }
}

func drawDisplay(x: CGFloat, scale: CGFloat) {
    let bezel = NSRect(x: x, y: 432, width: 330, height: 228)

    // Stand.
    rgb(222, 226, 240).setFill()
    NSBezierPath(rect: NSRect(x: bezel.midX - 26, y: bezel.minY - 56, width: 52, height: 60)).fill()
    NSBezierPath(roundedRect: NSRect(x: bezel.midX - 78, y: bezel.minY - 72, width: 156, height: 20),
                 xRadius: 10, yRadius: 10).fill()

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 16 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -6 * scale)
    shadow.set()
    rgb(24, 26, 40).setFill()
    NSBezierPath(roundedRect: bezel, xRadius: 26, yRadius: 26).fill()
    NSGraphicsContext.restoreGraphicsState()

    let screen = bezel.insetBy(dx: 12, dy: 12)
    NSGradient(starting: rgb(150, 214, 255), ending: rgb(255, 178, 214))!
        .draw(in: NSBezierPath(roundedRect: screen, xRadius: 15, yRadius: 15), angle: -90)

    // The dock, always present on this display.
    let dock = NSRect(x: screen.midX - 106, y: screen.minY + 14, width: 212, height: 46)
    rgb(255, 255, 255, 0.92).setFill()
    NSBezierPath(roundedRect: dock, xRadius: 17, yRadius: 17).fill()
    let apps = [rgb(255, 92, 92), rgb(255, 176, 46), rgb(52, 199, 89), rgb(64, 120, 255)]
    for (index, color) in apps.enumerated() {
        color.setFill()
        let tile = NSRect(x: dock.minX + 14 + CGFloat(index) * 50, y: dock.minY + 7, width: 32, height: 32)
        NSBezierPath(roundedRect: tile, xRadius: 9, yRadius: 9).fill()
    }
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let pixels = points * factor
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let scale = CGFloat(pixels) / 1024
        NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
        drawIcon(scale: scale)
        NSGraphicsContext.restoreGraphicsState()
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
