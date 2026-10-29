import XCTest
@testable import BibblesApp

final class ChatStreamCollectorTests: XCTestCase {
    private func feed(_ payloads: [String]) throws -> ChatStreamCollector {
        var collector = ChatStreamCollector()
        for payload in payloads { _ = try collector.consume(payload) }
        return collector
    }

    private let searchResult = #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","content":[{"type":"web_search_result","url":"https://www.bbc.com/news/1","title":"BBC News"},{"type":"web_search_result","url":"http://insecure.example/x","title":"Insecure"}]}}"#
    private let citation = #"{"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://www.bbc.com/news/1","title":"BBC News"}}}"#
    private let citation2 = #"{"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://reuters.com/a","title":"Reuters"}}}"#
    private func text(_ value: String) -> String { #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(value)"}}"# }
    private let endTurn = #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#
    private let stop = #"{"type":"message_stop"}"#

    func testSearchAnswerKeepsItsSourcesOnceEachHttpsOnly() throws {
        let result = try feed([searchResult, text("Here is the news."), citation, citation2, endTurn, stop]).result()
        XCTAssertEqual(result.text, "Here is the news.")
        XCTAssertEqual(result.sources.map(\.url.absoluteString), ["https://www.bbc.com/news/1", "https://reuters.com/a"])
    }

    func testDroppedConnectionIsNotACompleteAnswer() throws {
        let collector = try feed([text("The first half of an answer")])
        XCTAssertThrowsError(try collector.result()) { error in
            XCTAssertEqual(error as? WorkerError, .incompleteResponse)
        }
    }

    func testFinishedStreamsAreAccepted() throws {
        XCTAssertNoThrow(try feed([text("Done"), endTurn]).result())
        XCTAssertNoThrow(try feed([text("Done"), stop]).result())
        XCTAssertNoThrow(try feed([#"{"choices":[{"delta":{"content":"Hi"}}]}"#, "[DONE]"]).result())
    }

    func testLengthLimitIsSaidOutLoud() throws {
        let result = try feed([text("A long essay"), #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#]).result()
        XCTAssertEqual(result.stopReason, "length")
        XCTAssertTrue(result.text.hasSuffix(ChatStreamCollector.lengthNotice))
    }

    func testProviderErrorMidStreamFails() {
        XCTAssertThrowsError(try feed([text("Par"), #"{"type":"error","error":{"message":"overloaded"}}"#]))
    }
}
