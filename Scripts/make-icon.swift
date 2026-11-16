import AppKit
import Foundation

func drawIcon(size: CGFloat, url: URL) throws {
    let scale: CGFloat = 1
    let pixels = Int(size * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw NSError(domain: "IconRenderer", code: 1) }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS 11+ rounded-square app tile with a soft gradient.
    let inset = size * 0.085
    let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = tile.width * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let colors = [
        CGColor(red: 0.10, green: 0.64, blue: 1.0, alpha: 1.0),
        CGColor(red: 0.16, green: 0.25, blue: 0.82, alpha: 1.0),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: tile.minX, y: tile.maxY),
            end: CGPoint(x: tile.maxX, y: tile.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // Monitor body: a wide 4:3 frame illustrates the stretched signal.
    let screenW = tile.width * 0.62
    let screenH = screenW * 0.64   // Wide monitor silhouette
    let screenRect = CGRect(
        x: tile.midX - screenW / 2,
        y: tile.midY - screenH / 2 + tile.height * 0.045,
        width: screenW,
        height: screenH
    )
    let screenRadius = screenW * 0.055
    let bodyPath = CGPath(
        roundedRect: screenRect.insetBy(dx: -screenW * 0.035, dy: -screenW * 0.035),
        cornerWidth: screenRadius * 1.5,
        cornerHeight: screenRadius * 1.5,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.setFillColor(CGColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Screen surface with a light-blue gradient.
    let screenPath = CGPath(
        roundedRect: screenRect, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil
    )
    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    let screenColors = [
        CGColor(red: 0.36, green: 0.60, blue: 0.95, alpha: 1.0),
        CGColor(red: 0.18, green: 0.36, blue: 0.78, alpha: 1.0),
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: screenColors, locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: screenRect.minX, y: screenRect.maxY),
            end: CGPoint(x: screenRect.maxX, y: screenRect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // Stretch arrows: horizontal expansion marks the 4:3 → full-panel concept.
    let arrowY = screenRect.midY
    let arrowInset = screenRect.width * 0.16
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(max(1.0, screenW * 0.045))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let left = CGPoint(x: screenRect.minX + arrowInset, y: arrowY)
    let right = CGPoint(x: screenRect.maxX - arrowInset, y: arrowY)
    ctx.move(to: left)
    ctx.addLine(to: right)
    ctx.strokePath()

    let head = screenW * 0.11
    ctx.move(to: CGPoint(x: right.x - head, y: right.y + head * 0.7))
    ctx.addLine(to: right)
    ctx.addLine(to: CGPoint(x: right.x - head, y: right.y - head * 0.7))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: left.x + head, y: left.y + head * 0.7))
    ctx.addLine(to: left)
    ctx.addLine(to: CGPoint(x: left.x + head, y: left.y - head * 0.7))
    ctx.strokePath()

    // Stand.
    ctx.setFillColor(CGColor(red: 0.92, green: 0.94, blue: 0.98, alpha: 1.0))
    let standW = screenW * 0.13
    let standH = screenH * 0.11
    ctx.fill(CGRect(
        x: tile.midX - standW / 2,
        y: screenRect.minY - standH * 1.9,
        width: standW,
        height: standH
    ))
    let baseW = screenW * 0.40
    let baseH = standH * 0.55
    let basePath = CGPath(
        roundedRect: CGRect(
            x: tile.midX - baseW / 2,
            y: screenRect.minY - standH * 2.5,
            width: baseW,
            height: baseH
        ),
        cornerWidth: baseH / 2, cornerHeight: baseH / 2, transform: nil
    )
    ctx.addPath(basePath)
    ctx.setFillColor(CGColor(red: 0.92, green: 0.94, blue: 0.98, alpha: 1.0))
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconRenderer", code: 2)
    }
    try png.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift Scripts/make-icon.swift OUTPUT.iconset\n", stderr)
    exit(64)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Modern icon: one 1024px master, then the standard scale ladder.
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (size, name) in sizes {
    try drawIcon(size: CGFloat(size), url: outDir.appendingPathComponent(name))
}
print("icons written")
