import AppKit

// Render the editable SVG into exact pixel sizes, independent of display scale.
let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets/AppIcon.svg")
guard let artwork = NSImage(contentsOf: source) else {
    fatalError("Cannot load icon SVG: \(source.path)")
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
            pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                     from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        if pixels == 1024 {
            try data.write(to: source.deletingLastPathComponent().appendingPathComponent("AppIcon.png"))
        }
    }
}
