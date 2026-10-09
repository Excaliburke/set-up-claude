// Draws the Origami app icon into an .iconset folder, which build-app.sh turns
// into AppIcon.icns: the startup's last frame (see Fold.swift), a page of
// notebook paper folded into the start of a dart, on the family's coral sky.
//
//   make-icon <output.iconset>

import AppKit

@main
enum MakeIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: make-icon <output.iconset>\n".utf8))
            exit(1)
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            try render(pixels: points).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
            try render(pixels: points * 2).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
        }
    }

    static func render(pixels: Int) -> Data {
        let size = CGFloat(pixels)
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Fold draws with y pointing down.
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: 1, y: -1)

        // macOS icons leave a margin around a rounded square.
        let inset = size * 0.1
        let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil))
        ctx.clip()
        Fold.sky(ctx, top: tile.minY, bottom: tile.maxY)
        let m = Fold.moment(Fold.end)
        let cam = Fold.camera(width: Double(size), height: Double(size), dist: 44)
        Fold.draw(ctx, cam: cam, corner: m.corner, cornerRight: m.cornerRight, keel: m.keel,
                  lift: m.lift, yaw: Fold.yaw, scale: Double(size) / 512)
        ctx.restoreGState()

        return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    }
}
