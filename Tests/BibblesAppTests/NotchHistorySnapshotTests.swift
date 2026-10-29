import AppKit
import XCTest
@testable import BibblesApp

@MainActor
final class NotchHistorySnapshotTests: XCTestCase {
    private func conversation(_ question: String) -> ChatConversation {
        var chat = ChatConversation(title: question)
        chat.messages = [ChatMessage(role: .user, text: question),
                         ChatMessage(role: .assistant, text: "Finished.")]
        return chat
    }

    func testClearingAccountCannotBeUndoneByPendingHistoryWork() async {
        let snapshot = TaskHistorySnapshot()
        let old = snapshot.update(from: [conversation("Old account")])
        snapshot.clear()
        await old.value
        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testLatestAccountSnapshotWinsOverOlderCalculation() async {
        let snapshot = TaskHistorySnapshot()
        let previous = snapshot.update(from: [conversation("Old account")])
        snapshot.clear()
        let next = conversation("New account")
        await snapshot.update(from: [next]).value
        await previous.value
        XCTAssertEqual(snapshot.items.map(\.conversationID), [next.id])
        XCTAssertEqual(snapshot.items.first?.question, "New account")
    }

    func testUnchangedHistoryDoesNotRepublishForUnrelatedChatUpdates() async {
        let snapshot = TaskHistorySnapshot()
        let chat = conversation("Completed question")
        await snapshot.update(from: [chat]).value
        var notifications = 0
        let subscription = snapshot.$items.dropFirst().sink { _ in notifications += 1 }
        await snapshot.update(from: [chat]).value
        var withUnansweredQuestion = chat
        withUnansweredQuestion.messages.append(ChatMessage(role: .user, text: "Still thinking"))
        await snapshot.update(from: [withUnansweredQuestion]).value
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(snapshot.items.count, 1)
        withExtendedLifetime(subscription) {}
    }

    func testRapidHideAndReopenCannotBeHiddenByAnOldAnimation() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("A window-server session is required") }
        let defaults = UserDefaults(suiteName: "NotchPanelTests-\(UUID())")!
        let store = ChatConversationStore(userID: .some(nil), defaults: defaults)
        let panel = TaskHistoryPanelController(store: store, pointerIsNearNotch: { true },
            onOpenItem: { _ in }, onOpenChat: {}, onNewChat: {}, onOpenSettings: {},
            onShowHelp: {}, onQuit: {}, onVisibilityChanged: {})
        defer { panel.hideImmediately() }
        let anchor = CGRect(x: screen.frame.midX - 100, y: screen.frame.maxY - 40, width: 200, height: 30)
        panel.showBelowNotch(anchor: anchor)
        XCTAssertTrue(panel.isVisible)
        for _ in 0..<4 {
            panel.hide()
            XCTAssertFalse(panel.isVisible, "Closing must allow a new hover before its fade finishes")
            panel.showBelowNotch(anchor: anchor)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(panel.isVisible, "A stale hide completion must not dismiss the reopened panel")
        panel.hideImmediately()
        XCTAssertFalse(panel.isVisible)
    }
}
