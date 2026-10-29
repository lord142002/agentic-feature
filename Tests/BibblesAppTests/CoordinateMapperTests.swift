import CoreGraphics
import XCTest
@testable import BibblesApp

final class CoordinateMapperTests: XCTestCase {
    func testPointerUsesCapturedCropOnNegativeOriginDisplay() throws {
        let descriptor = makeDescriptor(
            display: CGRect(x: -1440, y: 120, width: 1440, height: 900),
            crop: CGRect(x: -1340, y: 220, width: 1000, height: 600)
        )
        let pointer = try XCTUnwrap(CoordinateMapper.normalizedPoint(
            for: CGPoint(x: -840, y: 520),
            descriptor: descriptor
        ))
        XCTAssertEqual(pointer.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(pointer.y, 0.5, accuracy: 0.001)
        XCTAssertNil(CoordinateMapper.normalizedPoint(
            for: CGPoint(x: -100, y: 520),
            descriptor: descriptor
        ))
    }

    func testMapsTopLeftVisionCoordinatesIntoQuartzSpace() throws {
        let descriptor = makeDescriptor(
            display: CGRect(x: 0, y: 0, width: 1512, height: 982),
            crop: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        let result = try CoordinateMapper.globalQuartzRect(
            for: NormalizedRect(x: 0.25, y: 0.10, width: 0.20, height: 0.10),
            descriptor: descriptor
        )
        XCTAssertEqual(result.origin.x, 300, accuracy: 0.001)
        XCTAssertEqual(result.origin.y, 580, accuracy: 0.001)
        XCTAssertEqual(result.width, 160, accuracy: 0.001)
        XCTAssertEqual(result.height, 60, accuracy: 0.001)
    }

    func testMapsNegativeOriginSecondaryDisplayWithoutPrimaryDisplayConversion() throws {
        let descriptor = makeDescriptor(
            display: CGRect(x: -1440, y: 120, width: 1440, height: 900),
            crop: CGRect(x: -1340, y: 220, width: 1000, height: 600)
        )
        let result = try CoordinateMapper.globalQuartzRect(
            for: NormalizedRect(x: 0.10, y: 0.25, width: 0.20, height: 0.25),
            descriptor: descriptor
        )
        XCTAssertEqual(result.origin.x, -1240, accuracy: 0.001)
        XCTAssertEqual(result.origin.y, 520, accuracy: 0.001)
        XCTAssertEqual(result.width, 200, accuracy: 0.001)
        XCTAssertEqual(result.height, 150, accuracy: 0.001)
    }

    func testRejectsStaleCaptureDescriptor() {
        let now = Date()
        let descriptor = makeDescriptor(
            display: CGRect(x: 0, y: 0, width: 1000, height: 800),
            crop: CGRect(x: 0, y: 0, width: 1000, height: 800),
            capturedAt: now.addingTimeInterval(-3)
        )
        XCTAssertThrowsError(try CoordinateMapper.globalQuartzRect(
            for: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1),
            descriptor: descriptor,
            now: now,
            maximumAge: 2
        )) { error in
            XCTAssertEqual(error as? CoordinateMappingError, .staleDescriptor)
        }
    }

    func testRejectsOutOfRangeVisionTarget() {
        let descriptor = makeDescriptor(
            display: CGRect(x: 0, y: 0, width: 1000, height: 800),
            crop: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        XCTAssertThrowsError(try CoordinateMapper.globalQuartzRect(
            for: NormalizedRect(x: 0.95, y: 0.2, width: 0.2, height: 0.1),
            descriptor: descriptor
        )) { error in
            XCTAssertEqual(error as? CoordinateMappingError, .invalidNormalizedRect)
        }
    }

    func testMapsTargetOnRotatedPortraitDisplayFromAuthoritativeCrop() throws {
        let descriptor = CaptureDescriptor(
            displayID: 3,
            displayFrameInQuartzPoints: CGRect(x: 1_512, y: -300, width: 1_080, height: 1_920),
            capturePixelSize: CGSize(width: 1_080, height: 1_920),
            cropRectInCapturePixels: CGRect(x: 28, y: 448, width: 1_024, height: 1_024),
            cropRectInQuartzPoints: CGRect(x: 1_540, y: 148, width: 1_024, height: 1_024),
            backingScaleFactor: 1,
            rotationDegrees: 90,
            capturedAt: Date()
        )
        let result = try CoordinateMapper.globalQuartzRect(
            for: NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            descriptor: descriptor
        )
        XCTAssertEqual(result.midX, 2_052, accuracy: 0.001)
        XCTAssertEqual(result.midY, 660, accuracy: 0.001)
    }

    private func makeDescriptor(
        display: CGRect,
        crop: CGRect,
        capturedAt: Date = Date()
    ) -> CaptureDescriptor {
        CaptureDescriptor(
            displayID: 1,
            displayFrameInQuartzPoints: display,
            capturePixelSize: CGSize(width: display.width * 2, height: display.height * 2),
            cropRectInCapturePixels: CGRect(x: 0, y: 0, width: crop.width * 2, height: crop.height * 2),
            cropRectInQuartzPoints: crop,
            backingScaleFactor: 2,
            rotationDegrees: 0,
            capturedAt: capturedAt
        )
    }
}
