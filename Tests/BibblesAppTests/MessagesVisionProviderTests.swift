import Foundation
import XCTest
@testable import BibblesApp

final class MessagesVisionProviderTests: XCTestCase {
    func testAnnotationsDiscardUnsafeMarksWithoutLosingAnswer() throws {
        let rect: [String: Any] = ["x": 0.2, "y": 0.3, "width": 0.1, "height": 0.1]
        let payload: [String: Any] = ["answer": "Open Export.", "confidence": 0.9, "annotations": [
            ["kind": "circle", "target": ["x": -0.1, "y": 0.2, "width": 0.2, "height": 0.2], "confidence": 0.99],
            ["kind": "arrow", "target": rect, "confidence": 0.93, "label": "Open Export"],
            ["kind": "rectangle", "target": rect, "confidence": 0.2],
            ["kind": "unsupported", "target": rect, "confidence": 0.9]
        ]]
        let content = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        let answer = try MessagesVisionProvider.parseResponse(data, model: "test")
        XCTAssertEqual(answer.answer, "Open Export.")
        XCTAssertEqual(answer.annotations.count, 1)
        XCTAssertEqual(answer.annotations.first?.shape, .arrow)
        XCTAssertEqual(answer.annotations.first?.label, "Open Export")
        XCTAssertEqual(answer.annotations.first?.step, 2)
    }

    func testChartPromptIncludesCapturedPointerAndVisibleEvidenceLimit() throws {
        let body = MessagesVisionProvider.requestBody(
            model: "test-model",
            question: "Explain this candle",
            imageData: Data([0x01]),
            ocr: [],
            pointerInImage: CGPoint(x: 0.42, y: 0.61),
            kind: .chartCandle
        )
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let prompt = try XCTUnwrap(parts.last?["text"] as? String)
        XCTAssertTrue(prompt.contains("[0.4200,0.6100]"))
        XCTAssertTrue(prompt.contains("body and wick"))
        XCTAssertTrue(prompt.contains("do not invent values"))
    }

    func testParsesValidGroundingResponse() throws {
        let data = #"{"choices":[{"message":{"content":"{\"answer\":\"Click Settings\",\"confidence\":0.91,\"target\":{\"x\":0.1,\"y\":0.2,\"width\":0.3,\"height\":0.1}}"}}]}"#.data(using: .utf8)!
        let answer = try MessagesVisionProvider.parseResponse(data, model: "test-model")
        XCTAssertEqual(answer.answer, "Click Settings")
        XCTAssertEqual(answer.confidence, 0.91)
        XCTAssertEqual(Double(answer.target?.x ?? 0), 0.1, accuracy: 0.0001)
        XCTAssertEqual(Double(answer.target?.y ?? 0), 0.2, accuracy: 0.0001)
        XCTAssertEqual(Double(answer.target?.width ?? 0), 0.3, accuracy: 0.0001)
        XCTAssertEqual(Double(answer.target?.height ?? 0), 0.1, accuracy: 0.0001)
        XCTAssertFalse(answer.needsFallback)
    }

    func testRepairsOutOfBoundsTargetInsteadOfFailing() throws {
        let data = #"{"choices":[{"message":{"content":"{\"answer\":\"There\",\"confidence\":0.9,\"target\":{\"x\":0.9,\"y\":0.2,\"width\":0.2,\"height\":0.1}}"}}]}"#.data(using: .utf8)!
        let answer = try MessagesVisionProvider.parseResponse(data, model: "test")
        XCTAssertEqual(answer.answer, "There")
        XCTAssertEqual(answer.target?.x, 0.9)
        XCTAssertEqual(Double(answer.target?.width ?? 0), 0.1, accuracy: 0.0001)
    }

    func testPixelTargetIsNormalized() {
        let rect = MessagesVisionProvider.repairedRect(x: 100, y: 50, width: 200, height: 100,
                                                   imageSize: CGSize(width: 1000, height: 500))
        XCTAssertEqual(Double(rect?.x ?? 0), 0.1, accuracy: 0.0001)
        XCTAssertEqual(Double(rect?.y ?? 0), 0.1, accuracy: 0.0001)
        XCTAssertEqual(Double(rect?.width ?? 0), 0.2, accuracy: 0.0001)
        XCTAssertEqual(Double(rect?.height ?? 0), 0.2, accuracy: 0.0001)
    }

    func testPlainTextAnswerIsKept() throws {
        let data = #"{"content":[{"type":"text","text":"You are looking at a Gmail draft."}]}"#.data(using: .utf8)!
        XCTAssertEqual(try MessagesVisionProvider.parseResponse(data, model: "test").answer, "You are looking at a Gmail draft.")
    }

    func testLowConfidenceRequestsFallback() throws {
        let data = #"{"choices":[{"message":{"content":"```json\n{\"answer\":\"Maybe\",\"confidence\":0.4}\n```"}}]}"#.data(using: .utf8)!
        XCTAssertTrue(try MessagesVisionProvider.parseResponse(data, model: "test-model").needsFallback)
    }

    func testScreenAccessRefusalRequestsFallbackEvenWithHighConfidence() {
        let answer = GroundedAnswer(
            answer: "I still can’t see your screen. Share a screenshot.",
            confidence: 0.95,
            target: nil,
            model: "test"
        )
        XCTAssertTrue(answer.refusesScreenAccess)
        XCTAssertTrue(answer.needsFallback)
    }
}
