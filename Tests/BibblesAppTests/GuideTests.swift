import XCTest
@testable import BibblesApp

final class GuideTests: XCTestCase {
    func testHowToQuestionsBecomeOnScreenGuides() {
        let router = IntentRouter()
        let question = "How do I export this as PDF?"
        XCTAssertEqual(ScreenQuestionKind.classify(question.lowercased()), .howTo)
        XCTAssertEqual(router.route(transcript: question, mode: .command), .screen(question: question))
        XCTAssertEqual(router.route(transcript: "How do I change my wallpaper on Mac", mode: .command),
                       .screen(question: "How do I change my wallpaper on Mac"))
        // General how-to questions stay in chat.
        XCTAssertEqual(router.route(transcript: "How do I make pasta", mode: .command), .chat(message: "How do I make pasta"))
    }

    func testParsesStepsAndSnapsVisibleControlsOnly() throws {
        let ocr = [OCRObservation(text: "File", confidence: 1, normalizedRect: NormalizedRect(x: 0.05, y: 0.01, width: 0.02, height: 0.015))]
        let json = #"{"answer":"1. Open File 2. Export","confidence":0.9,"steps":[{"title":"Open the File menu","explanation":"Click File at the top-left.","ocrId":1},{"title":"Choose Export as PDF","explanation":"Click Export as PDF…"}]}"#
        let data = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": json]]])
        let answer = try MessagesVisionProvider.parseResponse(data, model: "test", ocr: ocr, question: "how do i export this as pdf", kind: .howTo)
        XCTAssertEqual(answer.guideSteps.count, 2)
        XCTAssertEqual(answer.guideSteps[0].target, MessagesVisionProvider.padded(ocr[0].normalizedRect))
        XCTAssertNil(answer.guideSteps[1].target)
        XCTAssertTrue(answer.annotations.isEmpty)
    }
}
