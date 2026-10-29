import CoreGraphics
import XCTest
@testable import BibblesApp

final class GroundingCoordinatorTests: XCTestCase {
    func testMalformedPrimaryUsesFallbackButAuthenticationFailureDoesNot() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let request = VisionGroundingRequest(question: "Circle this button", image: try XCTUnwrap(context.makeImage()), ocr: [],
            descriptor: CaptureDescriptor(displayID: 1, displayFrameInQuartzPoints: bounds, capturePixelSize: bounds.size,
                cropRectInCapturePixels: bounds, cropRectInQuartzPoints: bounds, backingScaleFactor: 1, rotationDegrees: 0, capturedAt: Date()))
        let expected = GroundedAnswer(answer: "This is Export.", confidence: 0.95, target: nil, model: "fallback")
        let fallback = StubVision(result: .success(expected))
        let recovered = try await GroundingCoordinator(primary: StubVision(result: .failure(.invalidResponse)), fallback: fallback).ground(request)
        XCTAssertEqual(recovered, expected)
        XCTAssertEqual(fallback.calls, 1)
        do {
            _ = try await GroundingCoordinator(primary: StubVision(result: .failure(.server(status: 401, message: "Unauthorized"))), fallback: fallback).ground(request)
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(fallback.calls, 1)
        }
    }

    func testDeepLimitKeepsPaidForLightAnswer() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let request = VisionGroundingRequest(question: "What is this?", image: try XCTUnwrap(context.makeImage()), ocr: [],
            descriptor: CaptureDescriptor(displayID: 1, displayFrameInQuartzPoints: bounds, capturePixelSize: bounds.size,
                cropRectInCapturePixels: bounds, cropRectInQuartzPoints: bounds, backingScaleFactor: 1, rotationDegrees: 0, capturedAt: Date()))
        let unverifiedTarget = NormalizedRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1)
        let light = GroundedAnswer(answer: "It may be Export.", confidence: 0.5,
                                   target: unverifiedTarget, model: "light",
                                   annotations: [GroundedAnnotation(shape: .rectangle, target: unverifiedTarget,
                                                                    confidence: 0.8, label: nil)])
        let result = try await GroundingCoordinator(primary: StubVision(result: .success(light)),
                                                    fallback: LimitedVision()).ground(request)
        XCTAssertEqual(result.answer, light.answer)
        XCTAssertNil(result.target)
        XCTAssertTrue(result.annotations.isEmpty)
    }
}

private final class LimitedVision: VisionGroundingProviding {
    func ground(_ request: VisionGroundingRequest) async throws -> GroundedAnswer {
        throw WorkerError.limitReached("deep_tasks")
    }
}

private final class StubVision: VisionGroundingProviding {
    let result: Result<GroundedAnswer, VisionGroundingError>
    var calls = 0
    init(result: Result<GroundedAnswer, VisionGroundingError>) { self.result = result }
    func ground(_ request: VisionGroundingRequest) async throws -> GroundedAnswer {
        calls += 1
        return try result.get()
    }
}
