import Foundation

/// An estimate, not a claim of measured productivity: 40 WPM typing versus speaking time.
struct LocalUsageMetrics {
    private let defaults: UserDefaults
    private let key = "bibbles.usage.dictationMinutesSaved.v1"
    private let typingWordsPerMinute = 40.0
    private let charactersPerWord = 5.0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    @discardableResult
    func recordDictation(
        characterCount: Int,
        spokenSeconds: TimeInterval,
        at date: Date = Date()
    ) -> Double {
        guard characterCount > 0, spokenSeconds.isFinite, spokenSeconds >= 0 else { return 0 }
        let typingMinutes = Double(characterCount) / (charactersPerWord * typingWordsPerMinute)
        let saved = max(0, typingMinutes - spokenSeconds / 60)
        guard saved > 0 else { return 0 }

        var weeks = storedWeeks()
        weeks[weekKey(for: date), default: 0] += saved
        if weeks.count > 26 {
            let newest = weeks.keys.sorted().suffix(26)
            weeks = weeks.filter { newest.contains($0.key) }
        }
        defaults.set(weeks, forKey: key)
        return saved
    }

    func weeklyMinutesSaved(at date: Date = Date()) -> Double {
        storedWeeks()[weekKey(for: date), default: 0]
    }

    private func storedWeeks() -> [String: Double] {
        defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    private func weekKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
