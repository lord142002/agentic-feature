import Foundation

enum AnnotationGeometry {
    static func isValid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.size.width > 0 && rect.size.height > 0
    }

    static func arrow(to target: CGRect, from requested: CGPoint?, within bounds: CGRect) -> (CGPoint, CGPoint)? {
        guard isValid(target), bounds.contains(target) else { return nil }
        let padded = target.insetBy(dx: -8, dy: -8)
        let candidates = [requested,
                          CGPoint(x: padded.minX - 60, y: padded.midY),
                          CGPoint(x: padded.maxX + 60, y: padded.midY),
                          CGPoint(x: padded.midX, y: padded.maxY + 60),
                          CGPoint(x: padded.midX, y: padded.minY - 60)].compactMap { $0 }
        guard let start = candidates.first(where: { $0.x.isFinite && $0.y.isFinite && bounds.contains($0) && !padded.contains($0) }) else { return nil }
        let dx = start.x - target.midX, dy = start.y - target.midY
        let t = min(dx == 0 ? .infinity : padded.width / (2 * abs(dx)),
                    dy == 0 ? .infinity : padded.height / (2 * abs(dy)))
        return (start, CGPoint(x: target.midX + dx * t, y: target.midY + dy * t))
    }

    static func relativePoint(in bounds: CGRect, request: String, pointer: CGPoint) -> CGPoint {
        let text = request.lowercased()
        if text.contains("center-screen") || text.contains("center of the screen") { return CGPoint(x: bounds.midX, y: bounds.midY) }
        if text.contains("top-right-quadrant") { return CGPoint(x: bounds.minX + bounds.width * 0.75, y: bounds.minY + bounds.height * 0.75) }
        return pointer
    }
}
