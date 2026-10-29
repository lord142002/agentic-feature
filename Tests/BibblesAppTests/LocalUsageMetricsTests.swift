import Foundation
import XCTest
@testable import BibblesApp

final class LocalUsageMetricsTests: XCTestCase {
    func testSavesOnlyPositiveEstimatedTimeInTheCurrentWeek() {
        let suite = "bibbles.usage.test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let metrics = LocalUsageMetrics(defaults: defaults)
        let monday = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!
        let nextMonday = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!

        XCTAssertEqual(metrics.recordDictation(characterCount: 400, spokenSeconds: 30, at: monday), 1.5)
        XCTAssertEqual(metrics.weeklyMinutesSaved(at: monday), 1.5)
        XCTAssertEqual(metrics.recordDictation(characterCount: 20, spokenSeconds: 90, at: monday), 0)
        XCTAssertEqual(metrics.weeklyMinutesSaved(at: nextMonday), 0)
    }
}
