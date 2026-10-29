import AppKit
import SwiftUI
import XCTest
@testable import BibblesApp

final class VisualExplanationTests: XCTestCase {
    private func guide() -> VisualExplanation {
        VisualExplanation(title: "Export a file", steps: [
            VisualExplanationStep(title: "Open File", explanation: "Choose Export.",
                                  strokes: [ExplanationStroke(points: [ExplanationPoint(x: 0.2, y: 0.3),
                                                                              ExplanationPoint(x: 0.8, y: 0.3)], tone: "teal")],
                                  labels: [ExplanationLabel(text: "Export", position: ExplanationPoint(x: 0.8, y: 0.3))]),
            VisualExplanationStep(title: "Choose a format", explanation: "Select PDF, then confirm.", strokes: [], labels: [])
        ])
    }

    func testSceneValidationRejectsUnsafeGeometry() {
        XCTAssertTrue(guide().isValid)
        XCTAssertFalse(ExplanationPoint(x: .nan, y: 0).isValid)
        XCTAssertFalse(ExplanationPoint(x: 1.1, y: 0).isValid)
        XCTAssertFalse(ExplanationStroke(points: [ExplanationPoint(x: 0, y: 0)], tone: "teal").isValid)
        XCTAssertFalse(ExplanationStroke(points: Array(repeating: ExplanationPoint(x: 0, y: 0), count: 161), tone: "teal").isValid)
        XCTAssertFalse(ExplanationStroke(points: [ExplanationPoint(x: 0, y: 0), ExplanationPoint(x: 1, y: 1)], tone: "script").isValid)
    }

    func testMathAndGeometryRequestsDoNotOpenVisualLessons() {
        for question in ["Solve x² − 5x + 6 = 0 visually", "Explain Pythagoras visually",
                         "Draw a diagram of a triangle", "Explain fractions with a diagram"] {
            XCTAssertFalse(MessagesVisualExplanationProvider.isRequested(question), question)
        }
        XCTAssertTrue(MessagesVisualExplanationProvider.isRequested("Explain this workflow with a diagram"))
    }

    func testAIPlanValidationAndVisionFallback() throws {
        let scene = guide()
        let raw = try XCTUnwrap(String(data: JSONEncoder().encode(scene), encoding: .utf8))
        let envelope = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": raw]]]])
        XCTAssertEqual(try MessagesVisualExplanationProvider.parse(envelope), scene)
        let invalid = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "{\"title\":\"Bad\",\"steps\":[]}"]]]])
        XCTAssertThrowsError(try MessagesVisualExplanationProvider.parse(invalid))
        let visionPayload: [String: Any] = ["answer": "The Export button is visible.", "confidence": 0.9,
                                           "visualExplanation": ["title": "Bad", "steps": []]]
        let visionText = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: visionPayload), encoding: .utf8))
        let visionEnvelope = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": visionText]]]])
        let answer = try MessagesVisionProvider.parseResponse(visionEnvelope, model: "test")
        XCTAssertNil(answer.visualExplanation)
        XCTAssertEqual(answer.answer, "The Export button is visible.")

        let mathPayload: [String: Any] = ["answer": "The triangle has three sides.", "confidence": 0.9,
                                         "visualExplanation": try JSONSerialization.jsonObject(with: JSONEncoder().encode(scene))]
        let mathText = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: mathPayload), encoding: .utf8))
        let mathEnvelope = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": mathText]]]])
        XCTAssertNil(try MessagesVisionProvider.parseResponse(mathEnvelope, model: "test", question: "Explain this triangle visually").visualExplanation)
    }

    @MainActor
    func testGuideRendersAndCanBeDismissed() throws {
        let player = ExplanationPlayback()
        XCTAssertTrue(player.load(guide()))
        let view = VisualExplanationView(player: player, provenance: "Current screen", onClose: {}, animationsEnabled: false)
            .frame(width: 550, height: 650)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 550, height: 650)
        host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        player.move(to: 100)
        XCTAssertEqual(player.index, 0)
        player.togglePlayback()
        XCTAssertTrue(player.playing)
        player.dismiss()
        XCTAssertFalse(player.playing)
        XCTAssertNil(player.lesson)
    }

    @MainActor
    func testScreenChangePreventsOldGuideTargetsBeingRedrawn() {
        let player = ExplanationPlayback()
        XCTAssertTrue(player.load(guide()))
        var calls = 0
        player.onStep = { _ in calls += 1; return true }
        player.move(to: 0)
        player.invalidateScreenContext()
        player.move(to: 1)
        player.replay()
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(player.status)
    }
}
