import XCTest
@testable import BibblesApp

final class FriendlyErrorTests: XCTestCase {
    func testCommonClaudeFailuresReadPlainly() {
        XCTAssertTrue(ChatHTTPError.friendly(status: 401, body: "").contains("sign in"))
        XCTAssertTrue(ChatHTTPError.friendly(status: 429, body: "").contains("Too many requests"))
        XCTAssertTrue(ChatHTTPError.friendly(status: 529, body: "").contains("busy"))
        let overloaded = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertTrue(ChatHTTPError.friendly(status: 500, body: overloaded).contains("busy"))
        let credit = #"{"error":{"message":"Your credit balance is too low to access the Anthropic API."}}"#
        XCTAssertTrue(ChatHTTPError.friendly(status: 400, body: credit).contains("out of credit"))
    }

    func testOtherErrorsKeepTheProviderReason() {
        let body = #"{"error":{"message":"messages: text content blocks must be non-empty"}}"#
        XCTAssertEqual(ChatHTTPError.friendly(status: 400, body: body), "messages: text content blocks must be non-empty")
        XCTAssertTrue(ChatHTTPError.friendly(status: 418, body: "").contains("418"))
    }
}
