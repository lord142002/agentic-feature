import XCTest
@testable import BibblesApp

final class SpeechVocabularyStoreTests: XCTestCase {
    func testNormalizesWhitespaceAndDeduplicatesCaseInsensitively() {
        XCTAssertEqual(
            SpeechVocabularyStore.normalizedTerms([
                "  ScreenCaptureKit  ",
                "screenCaptureKit",
                "  React   Server   Component ",
                "",
                "ye pointer"
            ]),
            ["ScreenCaptureKit", "React Server Component", "ye pointer"]
        )
    }

    func testLimitsVocabularyToProviderMaximum() {
        let terms = (0..<120).map { "term-\($0)" }
        XCTAssertEqual(SpeechVocabularyStore.normalizedTerms(terms).count, 100)
    }

    func testLimitsIndividualTermLength() {
        let long = String(repeating: "a", count: 120)
        XCTAssertEqual(SpeechVocabularyStore.normalizedTerms([long]).first?.count, 80)
    }

    func testAddingSuggestedTermPreservesExistingVocabulary() {
        let suite = "bibbles.vocabulary.test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SpeechVocabularyStore(defaults: defaults)
        store.save(text: "ScreenCaptureKit")
        XCTAssertTrue(store.add("React.js"))
        XCTAssertEqual(store.terms, ["ScreenCaptureKit", "React.js"])
    }
}
