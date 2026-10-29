import XCTest
@testable import BibblesApp

@MainActor
final class SpeechBufferingTests: XCTestCase {
    func testSlowConnectionKeepsAFullMinuteOfAudio() {
        // The old limit was 250 frames (5 s): speech after that was silently lost.
        XCTAssertTrue(SpeechPipeline.canQueue(pendingCount: 250))
        XCTAssertTrue(SpeechPipeline.canQueue(pendingCount: 2_999))
        XCTAssertEqual(SpeechPipeline.maximumPendingFrames * 20 / 1000, 60, "60 seconds at 20 ms per frame")
    }

    func testPastTheLimitTheTurnStopsWithAClearMessage() {
        XCTAssertFalse(SpeechPipeline.canQueue(pendingCount: SpeechPipeline.maximumPendingFrames))
        let message = TranscriptionStreamError.audioBacklog.errorDescription ?? ""
        XCTAssertTrue(message.lowercased().contains("connection"))
    }
}
