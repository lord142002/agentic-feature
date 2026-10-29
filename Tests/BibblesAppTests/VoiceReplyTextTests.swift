import XCTest
@testable import BibblesApp

final class VoiceReplyTextTests: XCTestCase {
    func testHoldsUnfinishedSentenceUntilFinalUpdate() {
        let partial = VoiceReplyText.readyChunks(in: "First point. Second point is still", final: false)
        XCTAssertEqual(partial.0, ["First point."])
        XCTAssertEqual(partial.1, "Second point is still")
        let complete = VoiceReplyText.readyChunks(in: partial.1 + " coming", final: true)
        XCTAssertEqual(complete.0, ["Second point is still coming"])
        XCTAssertTrue(complete.1.isEmpty)
    }

    func testMarkdownIsNotSpoken() {
        XCTAssertEqual(VoiceReplyText.spoken("See [export](https://example.com) in `File`."), "See export in File.")
    }

    func testEmojiAreNotSentToSpeechButNumbersRemain() {
        XCTAssertEqual(VoiceReplyText.spoken("Done ✅ 😄 Export 2026 at 3:30. 1️⃣"), "Done Export 2026 at 3:30.")
    }

    func testLongChunkDoesNotLoseRawMarkdownCharacters() {
        let text = "**bold** " + String(repeating: "word ", count: 25)
        let (chunks, tail) = VoiceReplyText.readyChunks(in: text, final: true, limit: 40)
        XCTAssertEqual(chunks.joined(separator: " "), VoiceReplyText.spoken(text))
        XCTAssertTrue(tail.isEmpty)
    }

    func testSelectedVoiceIsUsedForEveryLanguage() {
        let original = OpenRouterSpeech.englishVoice
        defer { OpenRouterSpeech.englishVoice = original }
        OpenRouterSpeech.englishVoice = "Charon"
        XCTAssertEqual(OpenRouterSpeech.requestBody(text: "यह candle bullish है")["voice"] as? String, "Charon")
        XCTAssertEqual(OpenRouterSpeech.requestBody(text: "Hello there")["voice"] as? String, "Charon")
    }

    func testFirstChunkIsShortSoSpeechStartsSooner() {
        let text = "Sure, here's how it works, step by step: first open the File menu and choose Export as PDF."
        let quick = VoiceReplyText.readyChunks(in: text, final: true, quickStart: true).0
        XCTAssertEqual(quick.first, "Sure, here's how it works,")
        XCTAssertEqual(quick.joined(separator: " "), VoiceReplyText.spoken(text))
        // Numbers like 1,000 are never split.
        let numbers = VoiceReplyText.readyChunks(in: "Sigma includes 1,000 asks each month for everyday work and more", final: false, quickStart: true)
        XCTAssertTrue(numbers.0.isEmpty)
        // Without quickStart, chunks stay whole sentences.
        XCTAssertEqual(VoiceReplyText.readyChunks(in: text, final: true).0.count, 1)
    }

}

final class VoiceDecimalTests: XCTestCase {
    func testDecimalsAndDomainsAreNotSplit() {
        let (chunks, tail) = VoiceReplyText.readyChunks(in: "Gold is at 4,150.5 now. Next level 3.5 is support.", final: true)
        XCTAssertEqual(chunks, ["Gold is at 4,150.5 now.", "Next level 3.5 is support."])
        XCTAssertTrue(tail.isEmpty)
        // A full stop at the end of a streaming update waits for more text.
        XCTAssertTrue(VoiceReplyText.readyChunks(in: "It costs 3.", final: false).0.isEmpty)
    }
}
