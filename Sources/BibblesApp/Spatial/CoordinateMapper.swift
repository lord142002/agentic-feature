import CoreGraphics
import Foundation

struct NormalizedRect: Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1 && y + height <= 1
    }
}

struct CaptureDescriptor: Equatable {
    let displayID: CGDirectDisplayID
    let displayFrameInQuartzPoints: CGRect
    let capturePixelSize: CGSize
    let cropRectInCapturePixels: CGRect
    let cropRectInQuartzPoints: CGRect
    let backingScaleFactor: CGFloat
    let rotationDegrees: Int
    let capturedAt: Date
}

enum CoordinateMappingError: Error, Equatable {
    case invalidNormalizedRect
    case invalidDescriptor
    case staleDescriptor
    case outsideDisplay
}

enum CoordinateMapper {
    static func normalizedPoint(for cursor: CGPoint, descriptor: CaptureDescriptor) -> CGPoint? {
        let crop = descriptor.cropRectInQuartzPoints
        guard crop.width > 0, crop.height > 0, crop.contains(cursor) else { return nil }
        return CGPoint(
            x: (cursor.x - crop.minX) / crop.width,
            y: (crop.maxY - cursor.y) / crop.height
        )
    }

    /// Vision rectangles use a top-left origin. Quartz global screen rectangles use a bottom-left origin.
    static func globalQuartzRect(
        for target: NormalizedRect,
        descriptor: CaptureDescriptor,
        now: Date = Date(),
        maximumAge: TimeInterval = 2
    ) throws -> CGRect {
        guard target.isValid else { throw CoordinateMappingError.invalidNormalizedRect }
        guard descriptor.displayFrameInQuartzPoints.width > 0,
              descriptor.displayFrameInQuartzPoints.height > 0,
              descriptor.capturePixelSize.width > 0,
              descriptor.capturePixelSize.height > 0,
              descriptor.cropRectInCapturePixels.width > 0,
              descriptor.cropRectInCapturePixels.height > 0,
              descriptor.cropRectInQuartzPoints.width > 0,
              descriptor.cropRectInQuartzPoints.height > 0,
              descriptor.backingScaleFactor > 0,
              [0, 90, 180, 270].contains(descriptor.rotationDegrees)
        else { throw CoordinateMappingError.invalidDescriptor }

        guard now.timeIntervalSince(descriptor.capturedAt) <= maximumAge else {
            throw CoordinateMappingError.staleDescriptor
        }

        // cropRectInQuartzPoints is captured with the frame and is authoritative. This avoids
        // accidentally converting through the primary display or a different screen's scale.
        let crop = descriptor.cropRectInQuartzPoints
        let mapped = CGRect(
            x: crop.minX + target.x * crop.width,
            y: crop.maxY - (target.y + target.height) * crop.height,
            width: target.width * crop.width,
            height: target.height * crop.height
        )

        guard descriptor.displayFrameInQuartzPoints.contains(mapped) else {
            throw CoordinateMappingError.outsideDisplay
        }
        return mapped
    }
}
