// Local design fixture. Uses the production vector renderer; no screen capture or API calls.
import AppKit
import QuartzCore

@main
enum DoodlePreview {
    static func main() throws {
        let width = 1200, height = 820
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        func text(_ value: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 14, color: NSColor = DoodleArtwork.ink) {
            (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: size > 24 ? .semibold : .medium), .foregroundColor: color
            ])
        }
        func box(_ rect: CGRect, _ color: NSColor, radius: CGFloat = 18) {
            context.setFillColor(color.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        context.setFillColor(NSColor(srgbRed: 0.965, green: 0.962, blue: 0.941, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        text("Bibbles", 50, 750, size: 20)
        text("Point. Ask. Follow.", 50, 686, size: 38)
        text("Precise geometry, clear labels, and answers beside your work.", 52, 656, size: 16)
        text("DESIGN FIXTURE · PRODUCTION VECTOR RENDERER", 745, 754, size: 10, color: .secondaryLabelColor)

        let chart = CGRect(x: 45, y: 325, width: 535, height: 285)
        let navy = NSColor(srgbRed: 0.10, green: 0.16, blue: 0.20, alpha: 1)
        box(chart, navy)
        text("Your chart", 68, 570, size: 14, color: .white)
        text("Explain this candle", 68, 544, size: 12, color: .lightGray)
        for y in stride(from: CGFloat(355), through: 520, by: 40) {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
            context.move(to: CGPoint(x: 65, y: y)); context.addLine(to: CGPoint(x: 556, y: y)); context.strokePath()
        }
        for i in 0..<12 {
            let x = CGFloat(88 + i * 37), y = CGFloat(385 + (i * 13) % 75)
            let color = i.isMultiple(of: 3) ? DoodleTone.coral.color : DoodleTone.teal.color
            context.setStrokeColor(color.cgColor); context.setLineWidth(2)
            context.move(to: CGPoint(x: x + 6, y: y - 19)); context.addLine(to: CGPoint(x: x + 6, y: y + 45)); context.strokePath()
            box(CGRect(x: x, y: y, width: 12, height: 25), color, radius: 2)
        }
        box(CGRect(x: 610, y: 325, width: 545, height: 285), .white)
        text("Project overview", 637, 567, size: 18)
        text("How do I export this file?", 637, 540, size: 13, color: .secondaryLabelColor)
        box(CGRect(x: 640, y: 415, width: 294, height: 86), NSColor(srgbRed: 0.95, green: 0.96, blue: 0.95, alpha: 1), radius: 10)
        text("Q3 product notes", 655, 466, size: 14)
        text("Saved just now", 655, 441, size: 12, color: .secondaryLabelColor)
        box(CGRect(x: 980, y: 430, width: 128, height: 44), navy, radius: 9)
        text("Export  ↗", 1000, 443, size: 14, color: .white)
        text("LOCAL CANVAS", 52, 278, size: 11, color: .secondaryLabelColor)
        text("Draw it. Add another. Undo whenever you need.", 52, 243, size: 21)

        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let candle = CGRect(x: 342, y: 387, width: 31, height: 78)
        root.addSublayer(DoodleArtwork.stroke(DoodleArtwork.path(for: .rectangle, in: candle), tone: .teal, animated: false, dotted: true))
        root.addSublayer(DoodleArtwork.arrowStroke(from: CGPoint(x: 233, y: 493), to: CGPoint(x: 334, y: 468), tone: .teal, animated: false, dotted: true))
        root.addSublayer(DoodleArtwork.badge("1 · Body + wick", at: CGPoint(x: 360, y: 489), within: chart, tone: .amber, scale: 2))
        root.addSublayer(DoodleArtwork.companion(at: CGPoint(x: 399, y: 379), tone: .amber))
        root.addSublayer(DoodleArtwork.stroke(DoodleArtwork.path(for: .rectangle, in: CGRect(x: 972, y: 423, width: 144, height: 58)), tone: .teal, animated: false))
        root.addSublayer(DoodleArtwork.stroke(DoodleArtwork.arrow(from: CGPoint(x: 898, y: 373), to: CGPoint(x: 992, y: 420)), tone: .teal, animated: false))
        root.addSublayer(DoodleArtwork.badge("1 · Open Export", at: CGPoint(x: 963, y: 494), within: root.bounds.insetBy(dx: 20, dy: 20), tone: .teal, scale: 2))
        root.addSublayer(DoodleArtwork.companion(at: CGPoint(x: 1120, y: 407)))
        let tones: [DoodleTone] = [.teal, .coral, .violet, .amber]
        for (index, shape) in DoodleShape.allCases.enumerated() {
            let rect = CGRect(x: 56 + (index % 7) * 160, y: 165 - (index / 7) * 95, width: 105, height: 60)
            root.addSublayer(DoodleArtwork.stroke(DoodleArtwork.path(for: shape, in: rect), tone: tones[index % 4], animated: false))
            text(shape.rawValue.capitalized, rect.minX, rect.minY - 20, size: 11)
        }
        root.render(in: context)
        text("Try: “draw a coral circle here”   ·   “undo drawing”   ·   Escape clears the canvas", 52, 30, size: 12)
        let image = context.makeImage()!
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        let destination = CommandLine.arguments.dropFirst().first ?? ".build/doodle-preview.png"
        try png.write(to: URL(fileURLWithPath: destination))
        print(destination)
    }
}
