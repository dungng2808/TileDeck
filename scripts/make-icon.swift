// Renders Resources/AppIcon.icns: a blue rounded square with a white ⌘ and a
// faint 2×2 tile grid behind it. Run: swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    // macOS icon grid: the body is ~80% of the canvas with a continuous-corner radius of ~22%.
    let inset = size * 0.1
    let body = canvas.insetBy(dx: inset, dy: inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.shadowBlurRadius = size * 0.03
    shadow.set()
    NSColor(calibratedRed: 0.13, green: 0.42, blue: 0.98, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [NSColor(calibratedRed: 0.30, green: 0.62, blue: 1, alpha: 1),
                        NSColor(calibratedRed: 0.10, green: 0.33, blue: 0.92, alpha: 1)])!.draw(in: shape, angle: -90)

    // Tile grid hint.
    NSColor.white.withAlphaComponent(0.13).setFill()
    let gap = body.width * 0.05
    let cell = (body.width - gap * 3) / 2
    for row in 0..<2 {
        for column in 0..<2 {
            let tile = NSRect(x: body.minX + gap + CGFloat(column) * (cell + gap), y: body.minY + gap + CGFloat(row) * (cell + gap), width: cell, height: cell)
            NSBezierPath(roundedRect: tile, xRadius: cell * 0.18, yRadius: cell * 0.18).fill()
        }
    }

    // The ⌘ symbol.
    let configuration = NSImage.SymbolConfiguration(pointSize: body.width * 0.46, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "command", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
        let symbolSize = symbol.size
        symbol.draw(in: NSRect(x: body.midX - symbolSize.width / 2, y: body.midY - symbolSize.height / 2, width: symbolSize.width, height: symbolSize.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
try! render(size: 1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/AppIcon.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
