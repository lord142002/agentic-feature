import XCTest
@testable import BibblesApp

final class CaptureCropPlannerTests: XCTestCase {
    func testRetinaCropUsesTopLeftCaptureCoordinates() throws {
        let display = DisplayGeometry(
            displayID: 1,
            frameInQuartzPoints: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            pixelSize: CGSize(width: 2_880, height: 1_800),
            backingScaleFactor: 2,
            rotationDegrees: 0
        )
        let crop = try CaptureCropPlanner.cursorCrop(
            cursor: CGPoint(x: 720, y: 450),
            display: display
        )
        XCTAssertEqual(crop.rectInCapturePixels, CGRect(x: 928, y: 388, width: 1_024, height: 1_024))
        XCTAssertEqual(crop.rectInQuartzPoints, CGRect(x: 464, y: 194, width: 512, height: 512))
    }

    func testNegativeOriginCropClampsInsideDisplay() throws {
        let display = DisplayGeometry(
            displayID: 2,
            frameInQuartzPoints: CGRect(x: -1_920, y: 100, width: 1_920, height: 1_080),
            pixelSize: CGSize(width: 1_920, height: 1_080),
            backingScaleFactor: 1,
            rotationDegrees: 0
        )
        let crop = try CaptureCropPlanner.cursorCrop(
            cursor: CGPoint(x: -1_900, y: 1_160),
            display: display
        )
        XCTAssertEqual(crop.rectInQuartzPoints.minX, -1_920)
        XCTAssertEqual(crop.rectInQuartzPoints.maxY, 1_180)
        XCTAssertEqual(crop.rectInCapturePixels.origin, .zero)
    }

    func testMixedDPIDisplaysUseEachDisplaysActualPixelRatio() throws {
        let retina = DisplayGeometry(
            displayID: 1,
            frameInQuartzPoints: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            pixelSize: CGSize(width: 3_024, height: 1_964),
            backingScaleFactor: 2,
            rotationDegrees: 0
        )
        let external = DisplayGeometry(
            displayID: 2,
            frameInQuartzPoints: CGRect(x: -1_920, y: -98, width: 1_920, height: 1_080),
            pixelSize: CGSize(width: 1_920, height: 1_080),
            backingScaleFactor: 1,
            rotationDegrees: 0
        )
        let retinaCrop = try CaptureCropPlanner.cursorCrop(cursor: CGPoint(x: 756, y: 491), display: retina)
        let externalCrop = try CaptureCropPlanner.cursorCrop(cursor: CGPoint(x: -960, y: 442), display: external)
        XCTAssertEqual(retinaCrop.rectInQuartzPoints.width, 512, accuracy: 0.001)
        XCTAssertEqual(externalCrop.rectInQuartzPoints.width, 1_024, accuracy: 0.001)
    }

    func testRotatedDisplayUsesCaptureDimensionsAsAuthoritative() throws {
        let portrait = DisplayGeometry(
            displayID: 3,
            frameInQuartzPoints: CGRect(x: 1_512, y: 0, width: 1_080, height: 1_920),
            pixelSize: CGSize(width: 1_080, height: 1_920),
            backingScaleFactor: 1,
            rotationDegrees: 90
        )
        let crop = try CaptureCropPlanner.cursorCrop(cursor: CGPoint(x: 2_052, y: 960), display: portrait)
        XCTAssertEqual(crop.rectInCapturePixels, CGRect(x: 28, y: 448, width: 1_024, height: 1_024))
        XCTAssertEqual(crop.rectInQuartzPoints, CGRect(x: 1_540, y: 448, width: 1_024, height: 1_024))
    }
}
