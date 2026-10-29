import AppKit
import XCTest
@testable import BibblesApp

final class LockScreenActionTests: XCTestCase {
    func testExplicitCommandsRouteLocally() {
        let router = IntentRouter()
        for command in ["Lock my Mac", "lock my screen", "Please lock this computer.",
                        "Could you lock my MacBook please?", "Hey Bibbles, lock my laptop now",
                        "mera screen lock kar do", "screen ko lock kardo"] {
            XCTAssertTrue(LockScreenCommand.isImmediate(command), command)
            XCTAssertEqual(LockScreenCommand.localPlan(for: command)?.calls.map(\.name), ["lock_screen"])
            XCTAssertTrue(router.isCommandRequest(command), command)
            XCTAssertEqual(router.route(transcript: command, mode: .command), .chat(message: command))
            XCTAssertEqual(router.route(transcript: command, mode: .dictation), .dictate)
            XCTAssertFalse(CommandAgent.needsConfirmation(AgentToolCall(name: "lock_screen", input: [:]), command: command))
        }
    }

    func testNonImmediateRequestsCannotBypassConfirmation() {
        for command in ["How do I lock my screen?", "Don't lock my Mac", "\"lock my Mac\"",
                        "‘lock my Mac’", "lock my Mac in five minutes", "lock my screen if I leave",
                        "Type lock my Mac", "Explain screen lock", "Secure my Mac while I step away"] {
            XCTAssertNil(LockScreenCommand.localPlan(for: command), command)
            XCTAssertTrue(CommandAgent.needsConfirmation(AgentToolCall(name: "lock_screen", input: [:]), command: command))
        }
        XCTAssertTrue(LockScreenCommand.isRequest("Secure my Mac while I step away"))
    }

    @MainActor
    func testShortcutUsesOnlyCommandControlQWithoutPosting() async throws {
        var sent: [LockScreenAction.KeyStroke] = []
        _ = try await LockScreenAction.run(isTrusted: { true }, modifiers: { [] }, send: { sent = $0 })
        XCTAssertEqual(sent.map(\.isDown), [true, false])
        XCTAssertEqual(sent.map(\.keyCode), [12, 12])
        for stroke in sent { XCTAssertEqual(stroke.flags, [.maskControl, .maskCommand]) }
    }

    @MainActor
    func testMissingPermissionNeverPosts() async {
        do {
            _ = try await LockScreenAction.run(isTrusted: { false }, modifiers: { [] }, send: { _ in XCTFail("Must not post") })
            XCTFail("Expected permission error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Accessibility")) }
    }

    @MainActor
    func testCancellationWhileModifiersHeldNeverPosts() async {
        let task = Task { @MainActor in
            try await LockScreenAction.run(isTrusted: { true }, modifiers: { .maskAlternate }, send: { _ in XCTFail("Must not post") })
        }
        await Task.yield()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
