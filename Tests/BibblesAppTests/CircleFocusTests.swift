import AppKit
import XCTest
@testable import BibblesApp

final class CircleFocusTests: XCTestCase {
    private let frame = CGRect(x: -500, y: -200, width: 500, height: 400)

    func testTrailUsesContinuousQuadraticCurvesAndBoundedStorage() {
        var gesture = CircleFocusGesture()
        gesture.begin(at: CGPoint(x: -400, y: 0), in: frame)
        var previous: FocusCurve?
        for index in 1...1000 {
            let angle = CGFloat(index) * 0.02
            if let curve = gesture.append(CGPoint(x: -300 + 100 * cos(angle), y: 80 * sin(angle))) {
                if let previous { XCTAssertEqual(previous.end, curve.start) }
                var elements: [CGPathElementType] = []
                curve.path.applyWithBlock { elements.append($0.pointee.type) }
                XCTAssertEqual(elements, [.moveToPoint, .addQuadCurveToPoint])
                XCTAssertLessThanOrEqual(gesture.points.count, 2)
                previous = curve
            }
        }
        XCTAssertNotNil(gesture.finish().rect)
        XCTAssertTrue(gesture.points.isEmpty)
        XCTAssertTrue(gesture.bounds.isNull)
        XCTAssertEqual(gesture.displacement, 0)
    }

    func testClickSmallDragAndStraightSwipeDoNotCapture() {
        for end in [CGPoint(x: -399, y: 1), CGPoint(x: -390, y: 10), CGPoint(x: -250, y: 0)] {
            var gesture = CircleFocusGesture()
            gesture.begin(at: CGPoint(x: -400, y: 0), in: frame)
            _ = gesture.append(end)
            XCTAssertNil(gesture.finish().rect)
            XCTAssertTrue(gesture.points.isEmpty)
        }
    }

    func testSelectionClampsToStartingDisplayAndNextGestureIsClean() {
        var gesture = CircleFocusGesture()
        gesture.begin(at: CGPoint(x: -490, y: -190), in: frame)
        _ = gesture.append(CGPoint(x: 100, y: 300))
        _ = gesture.append(CGPoint(x: -600, y: 400))
        let rect = gesture.finish().rect
        XCTAssertNotNil(rect)
        XCTAssertEqual(rect?.intersection(frame), rect)
        gesture.begin(at: CGPoint(x: -300, y: 0), in: frame)
        XCTAssertNil(gesture.finish().rect)
        gesture.begin(at: CGPoint(x: -300, y: 0), in: frame)
        _ = gesture.append(CGPoint(x: -250, y: 50))
        gesture.clear()
        XCTAssertTrue(gesture.points.isEmpty)
        XCTAssertNil(gesture.finish().rect)
    }

    func testNonFiniteInputIsIgnored() {
        var gesture = CircleFocusGesture()
        gesture.begin(at: CGPoint(x: CGFloat.nan, y: 0), in: frame)
        XCTAssertTrue(gesture.points.isEmpty)
        gesture.begin(at: CGPoint(x: -300, y: 0), in: frame)
        XCTAssertNil(gesture.append(CGPoint(x: CGFloat.infinity, y: 20)))
        XCTAssertNil(gesture.finish().rect)
    }

    @MainActor
    func testPointerInterceptionChordIsExclusive() {
        XCTAssertTrue(CircleFocusController.chordHeld([.control, .option]))
        XCTAssertTrue(CircleFocusController.chordHeld([.control, .option, .capsLock]))
        for flags: NSEvent.ModifierFlags in [[], [.control], [.option], [.control, .option, .command],
                                             [.control, .option, .shift], [.control, .option, .function]] {
            XCTAssertFalse(CircleFocusController.chordHeld(flags))
        }
    }

    func testRegionCropUsesExactRetinaPixelsAndClampsNegativeOrigin() throws {
        let display = DisplayGeometry(displayID: 1, frameInQuartzPoints: frame,
            pixelSize: CGSize(width: 1000, height: 800), backingScaleFactor: 2, rotationDegrees: 0)
        let crop = try CaptureCropPlanner.regionCrop(
            rect: CGRect(x: -600, y: 100, width: 200, height: 200), display: display)
        XCTAssertEqual(crop.rectInCapturePixels, CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(crop.rectInQuartzPoints, CGRect(x: -500, y: 100, width: 100, height: 100))
    }

    func testRotatedRegionUsesActualFramebufferRatio() throws {
        let display = DisplayGeometry(displayID: 2,
            frameInQuartzPoints: CGRect(x: 1000, y: -400, width: 600, height: 1000),
            pixelSize: CGSize(width: 900, height: 1500), backingScaleFactor: 2, rotationDegrees: 90)
        let crop = try CaptureCropPlanner.regionCrop(
            rect: CGRect(x: 1100, y: 0, width: 200, height: 200), display: display)
        XCTAssertEqual(crop.rectInCapturePixels, CGRect(x: 150, y: 600, width: 300, height: 300))
        XCTAssertEqual(crop.rectInQuartzPoints, CGRect(x: 1100, y: 0, width: 200, height: 200))
    }

    func testOutsideOrInvalidCropCannotReachCapture() {
        let display = DisplayGeometry(displayID: 1, frameInQuartzPoints: frame,
            pixelSize: CGSize(width: 500, height: 400), backingScaleFactor: 1, rotationDegrees: 0)
        for rect in [CGRect.zero, CGRect(x: 100, y: 100, width: 20, height: 20),
                     CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20)] {
            XCTAssertThrowsError(try CaptureCropPlanner.regionCrop(rect: rect, display: display))
        }
    }
}
