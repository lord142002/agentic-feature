import CoreGraphics
import Foundation

struct DisplayGeometry: Equatable {
    let displayID: CGDirectDisplayID
    let frameInQuartzPoints: CGRect
    let pixelSize: CGSize
    let backingScaleFactor: CGFloat
    let rotationDegrees: Int
}

struct PlannedCaptureCrop: Equatable {
    let display: DisplayGeometry
    let rectInCapturePixels: CGRect
    let rectInQuartzPoints: CGRect
}

enum CaptureCropPlanningError: Error, Equatable {
    case invalidDisplay
    case cursorOutsideDisplay
    case invalidRegion
}

enum CaptureCropPlanner {
    static func regionCrop(rect: CGRect, display: DisplayGeometry) throws -> PlannedCaptureCrop {
        let frame = display.frameInQuartzPoints
        let pixels = display.pixelSize
        guard [frame.minX, frame.minY, frame.width, frame.height, pixels.width, pixels.height,
               display.backingScaleFactor].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0, pixels.width >= 1, pixels.height >= 1,
              display.backingScaleFactor > 0 else { throw CaptureCropPlanningError.invalidDisplay }
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0 else { throw CaptureCropPlanningError.invalidRegion }
        let region = rect.intersection(frame)
        guard !region.isNull, region.width > 0, region.height > 0 else { throw CaptureCropPlanningError.invalidRegion }
        let sx = pixels.width / frame.width, sy = pixels.height / frame.height
        let x = max(0, floor((region.minX - frame.minX) * sx))
        let y = max(0, floor((frame.maxY - region.maxY) * sy))
        let maxX = min(pixels.width, ceil((region.maxX - frame.minX) * sx))
        let maxY = min(pixels.height, ceil((frame.maxY - region.minY) * sy))
        guard maxX > x, maxY > y else { throw CaptureCropPlanningError.invalidRegion }
        let crop = CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
        return PlannedCaptureCrop(display: display, rectInCapturePixels: crop,
            rectInQuartzPoints: CGRect(x: frame.minX + x / sx, y: frame.maxY - maxY / sy,
                                      width: crop.width / sx, height: crop.height / sy))
    }

    static func cursorCrop(
        cursor: CGPoint,
        display: DisplayGeometry,
        maximumLongEdgePixels: CGFloat = 1_024
    ) throws -> PlannedCaptureCrop {
        let frame = display.frameInQuartzPoints
        let pixels = display.pixelSize
        guard frame.width > 0, frame.height > 0,
              pixels.width > 0, pixels.height > 0,
              display.backingScaleFactor > 0,
              maximumLongEdgePixels > 0 else {
            throw CaptureCropPlanningError.invalidDisplay
        }
        guard frame.contains(cursor) else {
            throw CaptureCropPlanningError.cursorOutsideDisplay
        }

        let pixelsPerPointX = pixels.width / frame.width
        let pixelsPerPointY = pixels.height / frame.height
        let cropWidthPixels = min(pixels.width, floor(maximumLongEdgePixels))
        let cropHeightPixels = min(pixels.height, floor(maximumLongEdgePixels))
        let cursorPixelX = (cursor.x - frame.minX) * pixelsPerPointX
        let cursorPixelY = (frame.maxY - cursor.y) * pixelsPerPointY
        let pixelX = min(max(floor(cursorPixelX - cropWidthPixels / 2), 0), pixels.width - cropWidthPixels)
        let pixelY = min(max(floor(cursorPixelY - cropHeightPixels / 2), 0), pixels.height - cropHeightPixels)
        let pixelCrop = CGRect(
            x: pixelX,
            y: pixelY,
            width: cropWidthPixels,
            height: cropHeightPixels
        )

        // Derive the authoritative point rectangle from the exact integer pixel crop.
        let cropWidthPoints = cropWidthPixels / pixelsPerPointX
        let cropHeightPoints = cropHeightPixels / pixelsPerPointY
        let originX = frame.minX + pixelX / pixelsPerPointX
        let maxY = frame.maxY - pixelY / pixelsPerPointY
        let quartzCrop = CGRect(
            x: originX,
            y: maxY - cropHeightPoints,
            width: cropWidthPoints,
            height: cropHeightPoints
        )

        return PlannedCaptureCrop(
            display: display,
            rectInCapturePixels: pixelCrop,
            rectInQuartzPoints: quartzCrop
        )
    }
}
