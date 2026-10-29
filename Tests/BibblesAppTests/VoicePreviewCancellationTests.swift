import XCTest
@testable import BibblesApp

final class VoicePreviewCancellationTests: XCTestCase {
    @MainActor func testStoppingVoiceReplyClearsPlaybackState() {
        let controller = VoiceReplyController()
        controller.speak("Preview this voice.")
        controller.stop()
        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.errorMessage)
    }
}
