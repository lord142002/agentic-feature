import XCTest
@testable import BibblesApp

final class ChatStreamParserTests: XCTestCase {
    func testReadsTextAndIgnoresReasoningOnlyFrames() {
        XCTAssertEqual(ChatStreamParser.parse(#"{"choices":[{"delta":{"reasoning":"thinking"}}]}"#), .other)
        XCTAssertEqual(ChatStreamParser.parse(#"{"choices":[{"delta":{"content":"Hello"}}]}"#), .text("Hello"))
    }

    func testExposesProviderErrorInsteadOfCallingItEmpty() {
        XCTAssertEqual(ChatStreamParser.parse(#"{"error":{"message":"Provider unavailable"},"choices":[]}"#), .error("Provider unavailable"))
    }

    func testDetectsOutputLimit() {
        XCTAssertEqual(ChatStreamParser.parse(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#), .finished("length"))
    }

    func testReadsHTTPErrorReason() {
        XCTAssertEqual(ChatHTTPError.message(from: #"{"error":{"message":"No endpoints found matching your privacy settings"}}"#),
                       "No endpoints found matching your privacy settings")
        XCTAssertNil(ChatHTTPError.message(from: "<html>error</html>"))
    }

    func testReadsOnlySecureCitationAnnotations() {
        let payload = #"{"choices":[{"delta":{"annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/story","title":"Example story"}},{"type":"url_citation","url_citation":{"url":"http://example.com/insecure","title":"Insecure"}},{"type":"other","url_citation":{"url":"https://example.com/ignored"}}]}}]}"#
        XCTAssertEqual(ChatStreamParser.sources(from: payload), [
            WebSearchSource(title: "Example story", url: URL(string: "https://example.com/story")!)
        ])
    }

    func testReadsMessageAnnotationsWhenDeltaIsPresent() {
        let payload = #"{"choices":[{"delta":{},"message":{"annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/result"}}]}}]}"#
        XCTAssertEqual(ChatStreamParser.sources(from: payload).first?.title, "example.com")
    }

    func testOldChatMessageWithoutSourcesStillDecodes() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = ChatMessage(id: id, role: .assistant, text: "Hello", createdAt: date)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "sources")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.text, "Hello")
        XCTAssertNil(decoded.sources)
    }

    func testDetectsWebSearchCallsAndErrors() {
        let call = #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"s","name":"web_search","input":{}}}"#
        XCTAssertTrue(ChatStreamParser.isServerToolStart(call, named: "web_search"))
        let failed = #"{"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"s","content":{"type":"web_search_tool_result_error","error_code":"unavailable"}}}"#
        XCTAssertEqual(ChatStreamParser.webSearchError(from: failed), "unavailable")
        XCTAssertTrue(ChatStreamParser.sources(from: failed).isEmpty)
        let results = #"{"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"s","content":[{"type":"web_search_result","url":"https://en.wikipedia.org/wiki/Akbar","title":"Akbar - Wikipedia","encrypted_content":"x"}]}}"#
        XCTAssertNil(ChatStreamParser.webSearchError(from: results))
        XCTAssertEqual(ChatStreamParser.sources(from: results).first?.url.host, "en.wikipedia.org")
    }
}
