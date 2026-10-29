import CoreGraphics
import XCTest
@testable import BibblesApp

/// Simple screen questions stay light on every plan; only charts and complex
/// analysis keep the 75% confidence hand-over.
final class ScreenHandOverTests: XCTestCase {
    func testWhereIsAFolderStaysLightInEveryLanguage() {
        for question in ["where is the DOCUMENT SEND folder on my screen",
                         "Wo ist der Ordner DOCUMENT SEND auf meinem Bildschirm?",
                         "Où est le dossier DOCUMENT SEND sur mon écran ?",
                         "¿Dónde está la carpeta DOCUMENT SEND en mi pantalla?",
                         "DOCUMENT SEND folder screen pe kahan hai?",
                         "what is this", "which app is open", "read this", "what does this say"] {
            let kind = ScreenQuestionKind.classify(question)
            XCTAssertEqual(ScreenHandOverPolicy.forQuestion(question, kind: kind), .onlyIfBroken, question)
        }
        for question in ["Explain this candle", "analyze this chart", "how do I export this file as PDF",
                         "compare the two tables on my screen"] {
            let kind = ScreenQuestionKind.classify(question)
            XCTAssertEqual(ScreenHandOverPolicy.forQuestion(question, kind: kind), .confidence, question)
        }
    }

    func testSimpleQuestionKeepsTheLightAnswer() async throws {
        let request = try makeRequest("where is the DOCUMENT SEND folder on my screen", kind: .findControl)
        // Low confidence and no mark: still a valid light answer.
        let light = GroundedAnswer(answer: "Not on screen: I can't find a DOCUMENT SEND folder.", confidence: 0.5,
                                   target: nil, model: ClaudeAPI.fastModel)
        let deep = CountingVision(GroundedAnswer(answer: "Deep answer", confidence: 0.95, target: nil, model: ClaudeAPI.smartModel))
        var report: ScreenHandOverReport?
        let result = try await GroundingCoordinator(primary: CountingVision(light), fallback: deep,
                                                    policy: .onlyIfBroken, onReport: { report = $0 }).ground(request)
        XCTAssertEqual(result.answer, light.answer)
        XCTAssertEqual(deep.calls, 0)
        XCTAssertEqual(report, ScreenHandOverReport(tier: "light", handOver: nil))
    }

    func testBrokenLightAnswerIsHandedOver() async throws {
        let request = try makeRequest("what is this", kind: .general)
        let empty = GroundedAnswer(answer: "  ", confidence: 0.9, target: nil, model: ClaudeAPI.fastModel)
        let deep = CountingVision(GroundedAnswer(answer: "It's Finder.", confidence: 0.95, target: nil, model: ClaudeAPI.smartModel))
        var report: ScreenHandOverReport?
        let result = try await GroundingCoordinator(primary: CountingVision(empty), fallback: deep,
                                                    policy: .onlyIfBroken, onReport: { report = $0 }).ground(request)
        XCTAssertEqual(result.answer, "It's Finder.")
        XCTAssertEqual(deep.calls, 1)
        XCTAssertEqual(report, ScreenHandOverReport(tier: "deep", handOver: "empty answer"))
    }

    func testChartsKeepTheConfidenceHandOver() async throws {
        let request = try makeRequest("analyze this chart", kind: .chartAnalysis)
        let unsure = GroundedAnswer(answer: "Maybe an uptrend.", confidence: 0.5, target: nil, model: ClaudeAPI.fastModel)
        let deep = CountingVision(GroundedAnswer(answer: "A clear uptrend.", confidence: 0.9, target: nil, model: ClaudeAPI.smartModel))
        var report: ScreenHandOverReport?
        _ = try await GroundingCoordinator(primary: CountingVision(unsure), fallback: deep,
                                           policy: .confidence, onReport: { report = $0 }).ground(request)
        XCTAssertEqual(deep.calls, 1)
        XCTAssertEqual(report?.handOver, "confidence below 75%")
    }

    private func makeRequest(_ question: String, kind: ScreenQuestionKind) throws -> VisionGroundingRequest {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        return VisionGroundingRequest(question: question, image: try XCTUnwrap(context.makeImage()), ocr: [],
            descriptor: CaptureDescriptor(displayID: 1, displayFrameInQuartzPoints: bounds, capturePixelSize: bounds.size,
                cropRectInCapturePixels: bounds, cropRectInQuartzPoints: bounds, backingScaleFactor: 1, rotationDegrees: 0,
                capturedAt: Date()),
            kind: kind)
    }
}

private final class CountingVision: VisionGroundingProviding {
    let answer: GroundedAnswer
    var calls = 0
    init(_ answer: GroundedAnswer) { self.answer = answer }
    func ground(_ request: VisionGroundingRequest) async throws -> GroundedAnswer {
        calls += 1
        return answer
    }
}
