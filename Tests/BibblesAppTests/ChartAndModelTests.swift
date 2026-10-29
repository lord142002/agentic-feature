import CoreGraphics
import XCTest
@testable import BibblesApp

final class ChartAndModelTests: XCTestCase {
    /// Price-scale labels from a TradingView screenshot (2000 × 1247 px),
    /// including a current-price badge and an indicator pane's 0.0000.
    private var tradingViewOCR: [OCRObservation] {
        let labels: [(String, CGFloat)] = [
            ("1.3200", 160), ("1.3000", 235), ("1.2917", 265), ("1.2800", 309), ("1.2600", 383), ("1.2400", 456),
            ("1.2200", 530), ("1.2000", 604), ("1.1800", 678), ("1.1600", 752), ("1.1414", 820), ("03:05", 840),
            ("1.1200", 900), ("1.1000", 973), ("0.0000", 1100)
        ]
        return labels.map { text, y in
            OCRObservation(text: text, confidence: 1, normalizedRect: NormalizedRect(
                x: 1840 / 2000, y: (y - 10) / 1247, width: 60 / 2000, height: 20 / 1247))
        }
    }

    func testPriceAxisMapsPricesToScreenHeights() throws {
        let axis = try XCTUnwrap(PriceAxis.detect(in: tradingViewOCR))
        XCTAssertEqual(Double(axis.y(for: 1.14) * 1247), 824, accuracy: 4)
        XCTAssertEqual(Double(axis.y(for: 1.19) * 1247), 641, accuracy: 4)
        XCTAssertLessThan(axis.labelsLeftX, 0.93)
    }

    func testChartAnswerDrawsLevelsAndAddsDisclaimer() throws {
        let json = #"{"answer":"Price is 1.1414.","confidence":0.8,"priceLevels":[{"kind":"support","price":1.14,"label":"Support 1.1400"},{"kind":"resistance","price":"1.1900","label":"Resistance 1.1900"}]}"#
        let data = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": json]]])
        let answer = try MessagesVisionProvider.parseResponse(data, model: "test", ocr: tradingViewOCR,
                                                         question: "find the immediate support and resistance of this chart",
                                                         kind: .chartAnalysis)
        XCTAssertEqual(answer.priceLevels.map(\.kind), [.support, .resistance])
        XCTAssertEqual(Double(answer.priceLevels[1].y * 1247), 641, accuracy: 4)
        XCTAssertTrue(answer.answer.hasSuffix("Not financial advice."))
    }

    func testLevelsAreTakenFromTheAnswerTextWhenMissing() {
        let text = "- Immediate support, about 1.1370: the low of the base.\n- Immediate resistance, about 1.1900: the red line."
        let entries = MessagesVisionProvider.levelsMentioned(in: text)
        XCTAssertEqual(entries.compactMap { $0["price"] as? Double }, [1.137, 1.19])
    }

    func testModelEstimateIsUsedWhenThePriceScaleIsUnreadable() {
        let levels = MessagesVisionProvider.priceLevels(from: [["kind": "support", "price": 1.14, "y": 0.66]], ocr: [])
        XCTAssertEqual(levels.first?.y, 0.66)
    }

    func testChartQuestionsAreClassified() {
        XCTAssertEqual(ScreenQuestionKind.classify("find the immediate support and resistance of this chart"), .chartAnalysis)
        XCTAssertEqual(ScreenQuestionKind.classify("explain this candle"), .chartCandle)
        XCTAssertEqual(ScreenQuestionKind.classify("draw the immediate support and resistance of this chart visually"), .chartAnalysis)
        XCTAssertTrue(ScreenQuestionKind.chartAnalysis.isChart)
        XCTAssertTrue(ScreenQuestionKind.chartAnalysis.prefersDisplayOverview)
    }

    func testEscalationEventIsDetected() {
        XCTAssertTrue(ChatStreamParser.isEscalation(#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t","name":"ask_sonnet","input":{}}}"#))
        XCTAssertFalse(ChatStreamParser.isEscalation(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"ask_sonnet"}}"#))
    }

    func testScreenRequestToolIsDetected() {
        XCTAssertTrue(ChatStreamParser.isToolStart(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"look_at_screen","input":{}}}"#, named: "look_at_screen"))
        XCTAssertEqual(IntentRouter().route(transcript: "suggest which wallpaper suits my mac, I have opened wallpaper settings", mode: .command),
                       .screen(question: "suggest which wallpaper suits my mac, I have opened wallpaper settings"))
    }

    func testModelNames() {
        XCTAssertEqual(ClaudeAPI.displayName(for: ClaudeAPI.smartModel), "Sonnet")
        XCTAssertEqual(ClaudeAPI.displayName(for: ClaudeAPI.haikuModel), "Haiku")
        XCTAssertEqual(ClaudeAPI.displayName(for: ClaudeAPI.fastModel), "Fast")
    }

    func testOpenRouterToolCallsAreDetected() {
        let escalation = #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"ask_sonnet","arguments":""}}]}}]}"#
        XCTAssertTrue(ChatStreamParser.isEscalation(escalation))
        let screen = #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c2","type":"function","function":{"name":"look_at_screen","arguments":""}}]}}]}"#
        XCTAssertTrue(ChatStreamParser.isToolStart(screen, named: "look_at_screen"))
        XCTAssertFalse(ChatStreamParser.isEscalation(#"{"choices":[{"delta":{"content":"ask_sonnet"}}]}"#))
        XCTAssertEqual(ChatStreamParser.parse(#"{"choices":[{"delta":{"content":"Hi"}}]}"#), .text("Hi"))
    }
}
