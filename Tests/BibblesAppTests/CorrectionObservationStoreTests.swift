import Foundation
import XCTest
@testable import BibblesApp

final class CorrectionObservationStoreTests: XCTestCase {
    func testSuggestsOnlyAfterThirdExplicitReportAndOnlyOnce() {
        let suite = "bibbles.correction.test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CorrectionObservationStore(defaults: defaults)

        XCTAssertEqual(store.record(heard: "react jay ess", intended: "React.js"),
                       CorrectionObservationResult(count: 1, suggestedTerm: nil))
        XCTAssertEqual(store.record(heard: "React Jay Ess", intended: "react.js"),
                       CorrectionObservationResult(count: 2, suggestedTerm: nil))
        XCTAssertEqual(store.record(heard: "react jay ess", intended: "React.js"),
                       CorrectionObservationResult(count: 3, suggestedTerm: "React.js"))
        XCTAssertEqual(store.record(heard: "react jay ess", intended: "React.js"),
                       CorrectionObservationResult(count: 4, suggestedTerm: nil))
    }

    func testRejectsEmptyAndIdenticalTerms() {
        let suite = "bibbles.correction.test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CorrectionObservationStore(defaults: defaults)
        XCTAssertNil(store.record(heard: "", intended: "React.js"))
        XCTAssertNil(store.record(heard: "React.js", intended: "react.js"))
    }
}
