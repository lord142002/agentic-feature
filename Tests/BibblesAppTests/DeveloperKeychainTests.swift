#if BIBBLES_DEVELOPER
import AppKit
import XCTest
@testable import BibblesApp

/// Uses its own Keychain service names: the developer's real keys are never touched.
final class DeveloperKeychainTests: XCTestCase {
    private let testService = "com.bibbles.dev.keys.tests"
    private let testLegacyService = "com.bibbles.dev.router.tests"

    override func setUp() {
        super.setUp()
        DeveloperKeychain.testOverride = nil
        DeveloperKeychain.service = testService
        DeveloperKeychain.legacyService = testLegacyService
        DeveloperKeychain.resetCache()
        clean()
    }

    override func tearDown() {
        clean()
        DeveloperKeychain.service = DeveloperKeychain.defaultService
        DeveloperKeychain.legacyService = "com.bibbles.dev.router"
        DeveloperKeychain.resetCache()
        super.tearDown()
    }

    private func clean() {
        for slot in DeveloperKeySlot.allCases { DeveloperKeychain.deleteItem(service: testService, account: slot.rawValue) }
        DeveloperKeychain.deleteItem(service: testLegacyService, account: DeveloperKeychain.legacyAccount)
        DeveloperKeychain.resetCache()
    }

    func testSaveReadRemove() {
        XCTAssertNil(DeveloperKeychain.read(.openrouter))
        XCTAssertEqual(DeveloperKeychain.status(.openrouter), "Not set")
        XCTAssertTrue(DeveloperKeychain.save("  sk-or-test-1234abcd \n", for: .openrouter))
        XCTAssertEqual(DeveloperKeychain.read(.openrouter), "sk-or-test-1234abcd")
        // Read straight from the Keychain, not the cache.
        DeveloperKeychain.resetCache()
        XCTAssertEqual(DeveloperKeychain.read(.openrouter), "sk-or-test-1234abcd")
        XCTAssertEqual(DeveloperKeychain.status(.openrouter), "Set ✓ ····abcd")
        XCTAssertNil(DeveloperKeychain.read(.anthropic), "one item per provider")
        DeveloperKeychain.remove(.openrouter)
        DeveloperKeychain.resetCache()
        XCTAssertNil(DeveloperKeychain.read(.openrouter))
    }

    func testEmptyKeyIsNotSaved() {
        XCTAssertFalse(DeveloperKeychain.save("   ", for: .deepgram))
        XCTAssertFalse(DeveloperKeychain.has(.deepgram))
    }

    func testStatusShowsOnlyTheLastFourCharacters() {
        DeveloperKeychain.save("sk-ant-secret-value-wxyz", for: .anthropic)
        let status = DeveloperKeychain.status(.anthropic)
        XCTAssertFalse(status.contains("secret"))
        XCTAssertTrue(status.hasSuffix("wxyz"))
    }

    func testMigratesTheOldRouterKeyIntoTheAnthropicSlot() {
        XCTAssertTrue(DeveloperKeychain.addItem("sk-ant-old-router-9876", service: testLegacyService,
                                                account: DeveloperKeychain.legacyAccount))
        DeveloperKeychain.migrateLegacyRouterKey()
        DeveloperKeychain.resetCache()
        XCTAssertEqual(DeveloperKeychain.read(.anthropic), "sk-ant-old-router-9876")
        XCTAssertNil(DeveloperKeychain.readItem(service: testLegacyService, account: DeveloperKeychain.legacyAccount),
                     "the old item is deleted")
    }

    func testMigrationKeepsANewerAnthropicKey() {
        DeveloperKeychain.save("sk-ant-new-1111", for: .anthropic)
        DeveloperKeychain.addItem("sk-ant-old-2222", service: testLegacyService, account: DeveloperKeychain.legacyAccount)
        DeveloperKeychain.migrateLegacyRouterKey()
        XCTAssertEqual(DeveloperKeychain.read(.anthropic), "sk-ant-new-1111")
    }

    func testKeysAreNeverWrittenToUserDefaults() {
        let secret = "sk-or-never-in-defaults-5555"
        DeveloperKeychain.save(secret, for: .openrouter)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("bibbles.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("sk-ant-pasted-6666", forType: .string)
        DeveloperKeychain.pasteAndSave(.anthropic, pasteboard: pasteboard)
        UserDefaults.standard.synchronize()
        let everything = UserDefaults.standard.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined()
        XCTAssertFalse(everything.contains(secret))
        XCTAssertFalse(everything.contains("sk-ant-pasted-6666"))
        if let domain = Bundle.main.bundleIdentifier, let persistent = UserDefaults.standard.persistentDomain(forName: domain) {
            XCTAssertFalse("\(persistent)".contains(secret))
        }
    }

    func testPasteAndSaveClearsTheClipboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("bibbles.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("  dg-test-key-7777\n", forType: .string)
        XCTAssertTrue(DeveloperKeychain.pasteAndSave(.deepgram, pasteboard: pasteboard))
        XCTAssertEqual(DeveloperKeychain.read(.deepgram), "dg-test-key-7777")
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testPasteAndSaveWithAnEmptyClipboardSavesNothing() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("bibbles.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertFalse(DeveloperKeychain.pasteAndSave(.google, pasteboard: pasteboard))
        XCTAssertFalse(DeveloperKeychain.has(.google))
    }

    // MARK: Key tests

    func testKeysGoInHeadersNeverInURLs() {
        for slot in DeveloperKeySlot.allCases {
            let request = DeveloperKeyTester.request(for: slot, key: "SECRET-KEY")
            XCTAssertFalse(request.url?.absoluteString.contains("SECRET-KEY") ?? true, slot.rawValue)
            XCTAssertTrue((request.allHTTPHeaderFields ?? [:]).values.contains { $0.contains("SECRET-KEY") }, slot.rawValue)
            XCTAssertFalse(request.url?.host?.contains("bibbles") ?? true, "never the Bibbles server")
        }
        XCTAssertEqual(DeveloperKeyTester.request(for: .google, key: "k").value(forHTTPHeaderField: "x-goog-api-key"), "k")
    }

    func testKeyTestResultsNameTheExactProblem() {
        let empty = Data()
        XCTAssertEqual(DeveloperKeyTester.classify(slot: .anthropic, status: 200, body: empty), .ok(nil))
        XCTAssertEqual(DeveloperKeyTester.classify(slot: .anthropic, status: 401, body: empty), .invalidKey)
        XCTAssertEqual(DeveloperKeyTester.classify(slot: .openrouter, status: 402, body: empty), .noCredit)
        XCTAssertEqual(DeveloperKeyTester.classify(slot: .deepgram, status: 429, body: empty), .rateLimited)
        let credit = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low"}}"#.utf8)
        XCTAssertEqual(DeveloperKeyTester.classify(slot: .anthropic, status: 400, body: credit), .noCredit)
        let remaining = Data(#"{"data":{"label":"x","usage":1.5,"limit":10,"limit_remaining":8.5}}"#.utf8)
        XCTAssertEqual(DeveloperKeyTester.classify(slot: .openrouter, status: 200, body: remaining), .ok("$8.50 credit left"))
        let spent = Data(#"{"data":{"limit":10,"limit_remaining":0}}"#.utf8)
        XCTAssertEqual(DeveloperKeyTester.classify(slot: .openrouter, status: 200, body: spent), .noCredit)
        XCTAssertEqual(DeveloperKeyTestResult.network.text, "network")
    }
}
#endif
