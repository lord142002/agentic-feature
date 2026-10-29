import XCTest
@testable import BibblesApp

final class ClaudeAPITests: XCTestCase {
    func testParsesClaudeStreamEvents() {
        XCTAssertEqual(ChatStreamParser.parse(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#), .text("Hi"))
        XCTAssertEqual(ChatStreamParser.parse(#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#), .finished("length"))
        XCTAssertEqual(ChatStreamParser.parse(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#), .error("Overloaded"))
        XCTAssertEqual(ChatStreamParser.parse(#"{"type":"ping"}"#), .other)
    }

    func testParsesClaudeWebSearchSources() {
        let payload = #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","content":[{"type":"web_search_result","url":"https://example.com/a","title":"Example"}]}}"#
        XCTAssertEqual(ChatStreamParser.sources(from: payload).first?.title, "Example")
    }

    func testParsesClaudeGroundingResponse() throws {
        let data = #"{"content":[{"type":"text","text":"Here you go: {\"answer\":\"Click Settings\",\"confidence\":0.9}"}]}"#.data(using: .utf8)!
        let answer = try MessagesVisionProvider.parseResponse(data, model: "claude-test")
        XCTAssertEqual(answer.answer, "Click Settings")
    }

    func testVisionRequestUsesClaudeImageFormat() throws {
        let body = MessagesVisionProvider.requestBody(model: "claude-test", question: "What is this?", imageData: Data([0x01]),
                                                  ocr: [], pointerInImage: nil, kind: .general)
        XCTAssertNotNil(body["system"] as? String)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["type"] as? String, "image")
    }
}
