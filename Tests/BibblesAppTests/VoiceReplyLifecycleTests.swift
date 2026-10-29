import Foundation
import XCTest
@testable import BibblesApp

@MainActor
private final class SilentPlayback: VoicePlayback {
    var enableRate = false
    var rate: Float = 1
    let duration: TimeInterval = 1
    var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var playCount = 0
    var allowsPlayback = true

    func prepareToPlay() -> Bool { true }
    func play() -> Bool { playCount += 1; isPlaying = allowsPlayback; return allowsPlayback }
    func stop() { isPlaying = false }
}

private actor SpeechRequests {
    private(set) var texts: [String] = []
    private var suspended: CheckedContinuation<Data, Never>?

    func record(_ text: String) { texts.append(text) }
    func suspend(_ text: String) async -> Data {
        texts.append(text)
        // Deliberately ignores cancellation to model a late provider callback.
        return await withCheckedContinuation { suspended = $0 }
    }
    func finish() { suspended?.resume(returning: Data(repeating: 0, count: 100)); suspended = nil }
}

final class VoiceReplyLifecycleTests: XCTestCase {
    @MainActor
    private func waitUntil(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await predicate()) {
            guard Date() < deadline else { XCTFail("Timed out waiting for deterministic playback state"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor
    func testFailedMeteredSpeechIsSentOnce() async {
        let requests = SpeechRequests()
        let controller = VoiceReplyController(synthesize: { text, _ in
            await requests.record(text)
            throw WorkerError.server
        }, makePlayback: { _ in SilentPlayback() })
        let result = await controller.speakAndWait("A short answer.")
        if case .success = result { XCTFail("The synthesis failure must be reported") }
        let texts = await requests.texts
        XCTAssertEqual(texts, ["A short answer."])
        XCTAssertFalse(controller.isActive)
        XCTAssertNotNil(controller.errorMessage)
    }

    @MainActor
    func testLiveFailureIsVisibleAndNotRetried() async throws {
        let requests = SpeechRequests()
        let controller = VoiceReplyController(synthesize: { text, _ in
            await requests.record(text)
            throw WorkerError.server
        }, makePlayback: { _ in SilentPlayback() })
        controller.accept("A short answer.", final: true)
        try await waitUntil { !controller.isActive }
        let texts = await requests.texts
        XCTAssertEqual(texts.count, 1)
        XCTAssertNotNil(controller.errorMessage)
    }

    @MainActor
    func testEscapeDiscardsQueuedSpeechBeforeItStarts() async throws {
        let requests = SpeechRequests()
        let controller = VoiceReplyController(synthesize: { text, _ in
            await requests.record(text)
            return Data(repeating: 0, count: 100)
        }, makePlayback: { _ in SilentPlayback() })
        controller.accept("First sentence. Second sentence. Third sentence.", final: true)
        controller.stop()
        try await Task.sleep(nanoseconds: 30_000_000)
        let texts = await requests.texts
        XCTAssertTrue(texts.isEmpty)
        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func testLateSynthesisAfterEscapeCannotStartPlayback() async throws {
        let requests = SpeechRequests()
        let playback = SilentPlayback()
        let controller = VoiceReplyController(synthesize: { text, _ in await requests.suspend(text) },
                                              makePlayback: { _ in playback })
        controller.speak("A short answer.")
        try await waitUntil { await requests.texts.count == 1 }
        controller.stop()
        await requests.finish()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(playback.playCount, 0)
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testOldLiveLoopCannotClearANewerPlayersState() async throws {
        let first = SilentPlayback()
        let second = SilentPlayback()
        var players = [first, second]
        let controller = VoiceReplyController(synthesize: { _, _ in Data(repeating: 0, count: 100) },
                                              makePlayback: { _ in players.removeFirst() })
        defer { controller.stop() }
        controller.accept("The original answer.", final: true)
        try await waitUntil { first.isPlaying }
        controller.speak("The replacement answer.")
        try await waitUntil { second.isPlaying }
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(first.isPlaying)
        XCTAssertTrue(second.isPlaying)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertTrue(controller.isActive)
    }

    @MainActor
    func testLiveLookaheadNeverRequestsThePlayingPieceAgain() async throws {
        let requests = SpeechRequests()
        let playback = SilentPlayback()
        let controller = VoiceReplyController(synthesize: { text, _ in
            await requests.record(text)
            return Data(repeating: 0, count: 100)
        }, makePlayback: { _ in playback })
        defer { controller.stop() }
        let sentence = String(repeating: "word ", count: 45) + "end. "
        controller.accept(String(repeating: sentence, count: 10), final: true)
        try await waitUntil { playback.isPlaying }
        try await Task.sleep(nanoseconds: 80_000_000)
        let texts = await requests.texts
        XCTAssertEqual(texts.count, 3, "Only the playing piece and two lookahead pieces may be requested")
    }

    @MainActor
    func testPlaybackRejectionSurfacesAnError() async throws {
        let playback = SilentPlayback()
        playback.allowsPlayback = false
        let controller = VoiceReplyController(synthesize: { _, _ in Data(repeating: 0, count: 100) },
                                              makePlayback: { _ in playback })
        controller.accept("A short answer.", final: true)
        try await waitUntil { !controller.isActive }
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func testDuplicateFinalUpdateDoesNotSpeakAnAnswerTwice() async throws {
        let requests = SpeechRequests()
        let playback = SilentPlayback()
        let controller = VoiceReplyController(synthesize: { text, _ in
            await requests.record(text)
            return Data(repeating: 0, count: 100)
        }, makePlayback: { _ in playback })
        controller.accept("A short answer.", final: true)
        try await waitUntil { playback.isPlaying }
        playback.stop()
        try await waitUntil { !controller.isActive }
        controller.accept("A short answer.", final: true)
        XCTAssertFalse(controller.isActive)
        let texts = await requests.texts
        XCTAssertEqual(texts.count, 1)
    }

    @MainActor
    func testEscapedWalkthroughDoesNotFireLaterStepCallbacks() async throws {
        let playback = SilentPlayback()
        var shown: [Int] = []
        let controller = VoiceReplyController(synthesize: { _, _ in Data(repeating: 0, count: 100) },
                                              makePlayback: { _ in playback })
        controller.speakSteps(["The first step.", "The next step."]) { shown.append($0) }
        try await waitUntil { playback.isPlaying }
        XCTAssertEqual(shown, [0])
        controller.stop()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(shown, [0])
        XCTAssertFalse(controller.isActive)
    }
}
