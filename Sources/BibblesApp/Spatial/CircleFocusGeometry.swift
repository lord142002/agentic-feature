import CoreGraphics
import Foundation

struct CircleFocusSelection {
    let rect: CGRect
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect
    let scale: CGFloat
    let rotation: Int
}

struct FocusCurve {
    let start: CGPoint
    let control: CGPoint
    let end: CGPoint

    var path: CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }
}

/// Constant-size gesture storage. The curve's accumulated bounds survive trail decay.
struct CircleFocusGesture {
    private(set) var points: [CGPoint] = []
    private(set) var bounds = CGRect.null
    private(set) var displacement: CGFloat = 0
    private var origin: CGPoint?
    private var midpoint: CGPoint?
    private var frame = CGRect.zero

    mutating func begin(at point: CGPoint, in frame: CGRect) {
        clear()
        guard [point.x, point.y, frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { return }
        self.frame = frame
        let point = clamped(point)
        origin = point
        midpoint = point
        points = [point]
    }

    mutating func append(_ point: CGPoint) -> FocusCurve? {
        guard let previous = points.last, let origin, let start = midpoint,
              point.x.isFinite, point.y.isFinite else { return nil }
        let point = clamped(point)
        guard hypot(point.x - previous.x, point.y - previous.y) >= 1 else { return nil }
        displacement = max(displacement, hypot(point.x - origin.x, point.y - origin.y))
        let end = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
        let curve = FocusCurve(start: start, control: previous, end: end)
        bounds = bounds.union(curve.path.boundingBoxOfPath)
        midpoint = end
        points = [previous, point]
        return curve
    }

    mutating func finish() -> (curve: FocusCurve?, rect: CGRect?) {
        defer { clear() }
        guard let start = midpoint, let end = points.last else { return (nil, nil) }
        let curve = FocusCurve(start: start, control: end, end: end)
        bounds = bounds.union(curve.path.boundingBoxOfPath)
        let rect = bounds.insetBy(dx: -8, dy: -8).intersection(frame)
        // Displacement rejects noisy clicks; area rejects a straight accidental swipe.
        guard displacement >= 24, bounds.width >= 12, bounds.height >= 12,
              !rect.isNull, rect.width > 0, rect.height > 0 else { return (curve, nil) }
        return (curve, rect)
    }

    mutating func clear() {
        points.removeAll(keepingCapacity: false)
        bounds = .null
        displacement = 0
        origin = nil
        midpoint = nil
        frame = .zero
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, frame.minX), frame.maxX),
                y: min(max(point.y, frame.minY), frame.maxY))
    }
}
