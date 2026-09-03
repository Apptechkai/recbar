// Renders the RecBar app icon (rounded dark tile, red record dot) into a
// .iconset and packs it with iconutil. Usage: swift scripts/make-icon.swift
import AppKit

let base = 1024.0
let out = URL(fileURLWithPath: "Resources", isDirectory: true)
let iconset = out.appendingPathComponent("RecBar.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Double) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = size / base
    // macOS icon grid: the tile fills ~ 82% of the canvas.
    let inset = 92.0 * s
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.15, alpha: 1).setFill()
    tilePath.fill()

    // Outer ring
    let center = NSPoint(x: size / 2, y: size / 2)
    let ringRadius = 300.0 * s
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                           width: ringRadius * 2, height: ringRadius * 2))
    ring.lineWidth = 44 * s
    NSColor(calibratedWhite: 0.92, alpha: 1).setStroke()
    ring.stroke()

    // Red record dot
    let dotRadius = 190.0 * s
    let dot = NSBezierPath(ovalIn: NSRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                          width: dotRadius * 2, height: dotRadius * 2))
    NSColor(calibratedRed: 0.93, green: 0.23, blue: 0.21, alpha: 1).setFill()
    dot.fill()
    image.unlockFocus()
    return image
}

func write(_ image: NSImage, pixels: Int, name: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent(name))
}

for points in [16, 32, 128, 256, 512] {
    try write(render(size: Double(points)), pixels: points, name: "icon_\(points)x\(points).png")
    try write(render(size: Double(points * 2)), pixels: points * 2, name: "icon_\(points)x\(points)@2x.png")
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("RecBar.icns").path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "wrote Resources/RecBar.icns" : "iconutil failed")
