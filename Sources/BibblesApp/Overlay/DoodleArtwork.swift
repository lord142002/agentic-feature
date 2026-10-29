import AppKit
import QuartzCore

enum DoodleTone: String {
    case teal, coral, violet, amber

    var color: NSColor {
        switch self {
        case .teal: return .systemCyan
        case .coral: return .systemRed
        case .violet: return .systemBlue
        case .amber: return .systemPink
        }
    }

    static func requested(in text: String) -> DoodleTone {
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        if !words.isDisjoint(with: ["coral", "red", "pink"]) { return .coral }
        if !words.isDisjoint(with: ["violet", "purple"]) { return .violet }
        if !words.isDisjoint(with: ["amber", "yellow", "orange"]) { return .amber }
        return .violet
    }
}

struct DoodleMark {
    let shape: DoodleShape
    let rect: CGRect
    var from: CGPoint? = nil
    var tone: DoodleTone = .violet
    var label: String? = nil
    var step: Int? = nil
    var dotted = false
    /// Walkthrough tracing: when set (2+ points, global screen points), the
    /// mark is drawn as a line through these points instead of `shape`.
    var points: [CGPoint]? = nil
}

/// Deterministic native geometry. Coordinates are logical screen points.
enum DoodleArtwork {
    static let ink = NSColor(srgbRed: 0.051, green: 0.047, blue: 0.086, alpha: 1) // #0D0C16
    static let paper = NSColor.white

    static func path(for shape: DoodleShape, in rect: CGRect, from origin: CGPoint? = nil) -> CGPath {
        let p = CGMutablePath()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        switch shape {
        case .circle:
            let diameter = min(rect.width, rect.height)
            p.addEllipse(in: CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter))
        case .rectangle, .spotlight:
            p.addRoundedRect(in: rect, cornerWidth: 8, cornerHeight: 8)
        case .triangle:
            p.move(to: point(0.5, 1))
            p.addLine(to: point(1, 0))
            p.addLine(to: point(0, 0))
            p.closeSubpath()
        case .line, .underline:
            p.move(to: point(0, shape == .underline ? 0 : 0.5))
            p.addLine(to: point(1, shape == .underline ? 0 : 0.5))
        case .arrow:
            let end = point(0.94, 0.62)
            let start = origin ?? point(0.04, 0.25)
            return arrow(from: start, to: end)
        case .star:
            for i in 0..<10 {
                let angle = CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / 5
                let radius: CGFloat = i.isMultiple(of: 2) ? 0.48 : 0.22
                let vertex = point(0.5 + cos(angle) * radius, 0.5 + sin(angle) * radius)
                if i == 0 { p.move(to: vertex) } else { p.addLine(to: vertex) }
            }
            p.closeSubpath()
        case .happyFace, .sadFace, .surprisedFace:
            let side = min(rect.width, rect.height)
            let face = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            p.addEllipse(in: face)
            for x: CGFloat in [0.32, 0.68] {
                p.addEllipse(in: CGRect(x: face.minX + side * (x - 0.025), y: face.minY + side * 0.6, width: side * 0.05, height: side * 0.05))
            }
            if shape == .surprisedFace {
                p.addEllipse(in: CGRect(x: face.midX - side * 0.09, y: face.minY + side * 0.22, width: side * 0.18, height: side * 0.18))
            } else {
                let center = CGPoint(x: face.midX, y: face.minY + side * (shape == .happyFace ? 0.46 : 0.22))
                p.move(to: CGPoint(x: center.x - side * 0.2, y: center.y))
                p.addArc(center: center, radius: side * 0.2, startAngle: .pi, endAngle: shape == .happyFace ? 2 * .pi : 0, clockwise: shape == .sadFace)
            }
        case .house:
            p.move(to: point(0, 0.55)); p.addLine(to: point(0.5, 1)); p.addLine(to: point(1, 0.55))
            p.addRect(CGRect(x: rect.minX + rect.width * 0.15, y: rect.minY, width: rect.width * 0.7, height: rect.height * 0.55))
            p.addRect(CGRect(x: rect.minX + rect.width * 0.4, y: rect.minY, width: rect.width * 0.2, height: rect.height * 0.3))
        case .sun:
            let radius = min(rect.width, rect.height) / 2
            p.addEllipse(in: CGRect(x: rect.midX - radius * 0.5, y: rect.midY - radius * 0.5, width: radius, height: radius))
            for i in 0..<8 {
                let angle = CGFloat(i) * .pi / 4
                p.move(to: CGPoint(x: rect.midX + cos(angle) * radius * 0.72, y: rect.midY + sin(angle) * radius * 0.72))
                p.addLine(to: CGPoint(x: rect.midX + cos(angle) * radius, y: rect.midY + sin(angle) * radius))
            }
        case .cube:
            p.addLines(between: [point(0.5, 1), point(1, 0.75), point(1, 0.25), point(0.5, 0), point(0, 0.25), point(0, 0.75), point(0.5, 1)])
            p.move(to: point(0, 0.75)); p.addLine(to: point(0.5, 0.5)); p.addLine(to: point(1, 0.75))
            p.move(to: point(0.5, 0.5)); p.addLine(to: point(0.5, 0))
        }
        return p
    }

    static func arrow(from start: CGPoint, to end: CGPoint, includeShaft: Bool = true) -> CGPath {
        let p = CGMutablePath()
        let dx = end.x - start.x, dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { return p }
        if includeShaft { p.move(to: start); p.addLine(to: end) }
        let angle = atan2(dy, dx)
        let head = min(15, distance * 0.4)
        p.move(to: CGPoint(x: end.x - head * cos(angle - .pi / 4), y: end.y - head * sin(angle - .pi / 4)))
        p.addLine(to: end)
        p.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 4), y: end.y - head * sin(angle + .pi / 4)))
        return p
    }

    static func arrowStroke(from start: CGPoint, to end: CGPoint, tone: DoodleTone, animated: Bool, dotted: Bool) -> CALayer {
        guard dotted else { return stroke(arrow(from: start, to: end), tone: tone, animated: animated) }
        let group = CALayer()
        let shaft = CGMutablePath()
        shaft.move(to: start); shaft.addLine(to: end)
        group.addSublayer(stroke(shaft, tone: tone, animated: animated, dotted: true))
        group.addSublayer(stroke(arrow(from: start, to: end, includeShaft: false), tone: tone, animated: animated))
        return group
    }

    static func stroke(_ path: CGPath, tone: DoodleTone, filled: Bool = false, animated: Bool, dotted: Bool = false) -> CALayer {
        let group = CALayer()
        group.shadowColor = NSColor.black.cgColor
        group.shadowOpacity = 0.3
        group.shadowRadius = 3
        group.shadowOffset = CGSize(width: 0, height: -1)
        for (width, color) in [(CGFloat(6), paper.withAlphaComponent(0.95)), (CGFloat(3.5), tone.color)] {
            let pen = CAShapeLayer()
            pen.path = path
            pen.strokeColor = color.cgColor
            pen.fillColor = nil
            pen.lineWidth = width
            pen.lineCap = .round
            pen.lineJoin = .miter
            if dotted { pen.lineDashPattern = [0, 9] }
            group.addSublayer(pen)
            if animated {
                let draw = CABasicAnimation(keyPath: "strokeEnd")
                draw.fromValue = 0
                draw.toValue = 1
                draw.duration = 0.38
                draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
                pen.add(draw, forKey: "pen")
            }
        }
        return group
    }

    static func badge(_ text: String, at point: CGPoint, within bounds: CGRect, tone: DoodleTone, scale: CGFloat) -> CALayer {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let title = String(text.prefix(48))
        let width = min(bounds.width, max(28, (title as NSString).size(withAttributes: [.font: font]).width + 22))
        let box = CALayer()
        box.frame = CGRect(x: min(max(point.x, bounds.minX), bounds.maxX - width),
                           y: min(max(point.y, bounds.minY), bounds.maxY - 28), width: width, height: 28)
        box.backgroundColor = paper.withAlphaComponent(0.94).cgColor
        box.cornerRadius = 8
        box.shadowColor = NSColor.black.cgColor
        box.shadowOpacity = 0.3
        box.shadowRadius = 3
        box.shadowOffset = CGSize(width: 0, height: -1)
        box.borderColor = tone.color.cgColor
        box.borderWidth = 1.5
        let label = CATextLayer()
        label.frame = CGRect(x: 9, y: 5, width: width - 18, height: 17)
        label.contentsScale = scale
        label.string = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ink])
        label.truncationMode = .end
        box.addSublayer(label)
        return box
    }

    static func companion(at point: CGPoint, tone: DoodleTone = .violet) -> CALayer {
        let body = CALayer()
        body.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
        body.position = point
        body.cornerRadius = 12
        body.backgroundColor = paper.cgColor
        body.borderColor = tone.color.cgColor
        body.borderWidth = 2
        body.shadowColor = ink.cgColor
        body.shadowOpacity = 0.15
        body.shadowRadius = 5
        body.shadowOffset = CGSize(width: 0, height: -2)
        for x: CGFloat in [9, 19] {
            let eye = CALayer()
            eye.frame = CGRect(x: x, y: 16, width: 3, height: 4)
            eye.cornerRadius = 1.5
            eye.backgroundColor = ink.cgColor
            body.addSublayer(eye)
        }
        let smile = CGMutablePath()
        smile.move(to: CGPoint(x: 11, y: 11))
        smile.addQuadCurve(to: CGPoint(x: 21, y: 11), control: CGPoint(x: 16, y: 6))
        let mouth = CAShapeLayer()
        mouth.path = smile
        mouth.strokeColor = ink.cgColor
        mouth.fillColor = nil
        mouth.lineWidth = 1.5
        mouth.lineCap = .round
        body.addSublayer(mouth)
        return body
    }

    static func localRect(around point: CGPoint, within bounds: CGRect, shape: DoodleShape = .rectangle) -> CGRect {
        let safe = bounds.insetBy(dx: 24, dy: 24)
        let preferredWidth: CGFloat = [.circle, .star].contains(shape) ? 120 : 150
        let preferredHeight: CGFloat = [.line, .underline].contains(shape) ? 16 : 120
        let width = min(preferredWidth, safe.width), height = min(preferredHeight, safe.height)
        return CGRect(x: min(max(point.x - width / 2, safe.minX), safe.maxX - width),
                      y: min(max(point.y - height / 2, safe.minY), safe.maxY - height), width: width, height: height)
    }
}
