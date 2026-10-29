import XCTest
@testable import BibblesApp

/// One Mac, several Bibbles accounts: nobody may see another account's chats.
@MainActor
final class AccountIsolationTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "bibbles.tests.account-isolation"
    private let alice = "aaaaaaaa-1111-4111-8111-111111111111"
    private let bob = "bbbbbbbb-2222-4222-8222-222222222222"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func texts(_ store: ChatConversationStore) -> [String] {
        store.conversations.flatMap { $0.messages.map(\.text) }
    }

    func testAnotherAccountNeverSeesYourChats() {
        let store = ChatConversationStore(userID: .some(alice), defaults: defaults)
        store.recordExchange(userText: "Alice's private question", assistantText: "Alice's answer")
        XCTAssertTrue(texts(store).contains("Alice's private question"))

        store.switchAccount(to: nil)            // Alice signs out
        XCTAssertFalse(texts(store).contains("Alice's private question"))

        store.switchAccount(to: bob)            // Bob signs in on the same Mac
        XCTAssertEqual(store.ownerID, bob)
        XCTAssertFalse(texts(store).contains("Alice's private question"))
        store.recordExchange(userText: "Bob's question", assistantText: "Bob's answer")

        store.switchAccount(to: alice)          // Alice comes back: her chats return, Bob's don't
        XCTAssertTrue(texts(store).contains("Alice's private question"))
        XCTAssertFalse(texts(store).contains("Bob's question"))

        // The notch task list is built from the same store.
        XCTAssertFalse(TaskHistory.items(from: store.conversations).contains { $0.question.contains("Bob") })
    }

    func testChatsSurviveRelaunchPerAccount() {
        let first = ChatConversationStore(userID: .some(alice), defaults: defaults)
        first.recordExchange(userText: "Kept for Alice", assistantText: "OK")
        let relaunchedAsBob = ChatConversationStore(userID: .some(bob), defaults: defaults)
        XCTAssertFalse(texts(relaunchedAsBob).contains("Kept for Alice"))
        let relaunchedAsAlice = ChatConversationStore(userID: .some(alice), defaults: defaults)
        XCTAssertTrue(texts(relaunchedAsAlice).contains("Kept for Alice"))
    }

    func testOldSharedHistoryMovesOnlyToTheAccountSignedInAtUpgrade() throws {
        let old = [ChatConversation(title: "Before accounts")]
        defaults.set(try JSONEncoder().encode(old), forKey: ChatConversationStore.legacyKey)

        let store = ChatConversationStore(userID: .some(alice), defaults: defaults)
        XCTAssertTrue(store.conversations.contains { $0.title == "Before accounts" })
        XCTAssertNil(defaults.data(forKey: ChatConversationStore.legacyKey), "the shared key is gone")

        store.switchAccount(to: bob)
        XCTAssertFalse(store.conversations.contains { $0.title == "Before accounts" })
    }

    func testOldSharedHistoryStaysSignedOutWhenNobodyIsSignedIn() throws {
        defaults.set(try JSONEncoder().encode([ChatConversation(title: "Before accounts")]),
                     forKey: ChatConversationStore.legacyKey)
        let store = ChatConversationStore(userID: .some(nil), defaults: defaults)
        store.switchAccount(to: bob)            // first person to sign in afterwards
        XCTAssertFalse(store.conversations.contains { $0.title == "Before accounts" })
    }

    func testDeletingAnAccountErasesItsChatsFromThisMac() {
        let store = ChatConversationStore(userID: .some(alice), defaults: defaults)
        store.recordExchange(userText: "Delete me", assistantText: "OK")
        store.switchAccount(to: nil, erasingPrevious: true)
        XCTAssertNil(defaults.data(forKey: ChatConversationStore.storageKey(for: alice)))
        store.switchAccount(to: alice)
        XCTAssertFalse(texts(store).contains("Delete me"))
    }
}
