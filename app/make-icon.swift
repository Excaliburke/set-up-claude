// Draws the Set Up Claude app icon into an .iconset folder, which build-app.sh
// turns into AppIcon.icns.
//
//   make-icon <output.iconset>

import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <output.iconset>\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let size = CGFloat(pixels)
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons leave a margin around a rounded square.
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.27, green: 0.30, blue: 0.37, alpha: 1),
        ending: NSColor(srgbRed: 0.12, green: 0.13, blue: 0.17, alpha: 1))
    gradient?.draw(in: shape, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.46, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let box = symbol.size
        symbol.draw(in: NSRect(x: tile.midX - box.width / 2, y: tile.midY - box.height / 2,
                               width: box.width, height: box.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
