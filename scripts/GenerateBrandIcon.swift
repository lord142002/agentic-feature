import AppKit
import Foundation

@main
enum GenerateBrandIcon {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/Bibbles.iconset")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.imageInterpolation = .high
                let unit = CGFloat(pixels) / 1024
                context.cgContext.scaleBy(x: unit, y: unit)
                draw()
                context.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
                let suffix = scale == 2 ? "@2x" : ""
                let url = directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
                guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
                try data.write(to: url)
            }
        }
        let representations: [(String, String)] = [
            ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
            ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
            ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
            ("ic10", "icon_512x512@2x.png")
        ]
        var elements = Data()
        for (type, name) in representations {
            let png = try Data(contentsOf: directory.appendingPathComponent(name))
            elements.append(contentsOf: type.utf8)
            elements.append(bigEndian: UInt32(png.count + 8))
            elements.append(png)
        }
        var icon = Data("icns".utf8)
        icon.append(bigEndian: UInt32(elements.count + 8))
        icon.append(elements)
        try icon.write(to: directory.deletingLastPathComponent().appendingPathComponent("Bibbles.icns"))
    }

    private static func draw() {
        let background = NSBezierPath(roundedRect: NSRect(x: 26, y: 26, width: 972, height: 972),
                                      xRadius: 240, yRadius: 240)
        NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.17, blue: 0.35, alpha: 1),
                   ending: NSColor(srgbRed: 0.055, green: 0.085, blue: 0.19, alpha: 1))?
            .draw(in: background, angle: -64)
        NSColor.white.withAlphaComponent(0.16).setStroke()
        background.lineWidth = 8
        background.stroke()

        let colors: [(NSColor, CGFloat)] = [
            (NSColor(srgbRed: 0.28, green: 0.91, blue: 0.96, alpha: 1), 250),
            (NSColor(srgbRed: 0.36, green: 0.68, blue: 1, alpha: 1), 410),
            (NSColor(srgbRed: 0.58, green: 0.50, blue: 0.98, alpha: 1), 334),
            (NSColor(srgbRed: 0.82, green: 0.56, blue: 0.96, alpha: 1), 200)
        ]
        for (index, item) in colors.enumerated() {
            let x = CGFloat(224 + index * 144)
            let rect = NSRect(x: x, y: 512 - item.1 / 2, width: 86, height: item.1)
            let bar = NSBezierPath(roundedRect: rect, xRadius: 43, yRadius: 43)
            let shadow = NSShadow()
            shadow.shadowColor = item.0.withAlphaComponent(0.50)
            shadow.shadowBlurRadius = 30
            shadow.set()
            NSGradient(starting: NSColor.white.withAlphaComponent(0.96), ending: item.0)?
                .draw(in: bar, angle: 90)
            NSShadow().set()
        }
    }
}

private extension Data {
    mutating func append(bigEndian number: UInt32) {
        var value = number.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
