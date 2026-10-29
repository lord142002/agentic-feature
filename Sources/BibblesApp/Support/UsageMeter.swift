import Foundation

// Plans and limits come from the server (`GET /v1/me`); nothing here enforces them.

/// Counts AI asks and deep tasks per calendar month, on this Mac.
struct UsageMeter {
    private let defaults: UserDefaults
    private let asksKey = "bibbles.usage.asks.v1"
    private let deepKey = "bibbles.usage.deepTasks.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func recordAsk(at date: Date = Date()) { add(to: asksKey, at: date) }
    func recordDeepTask(at date: Date = Date()) { add(to: deepKey, at: date) }

    func asks(in date: Date = Date()) -> Int { count(asksKey, at: date) }
    func deepTasks(in date: Date = Date()) -> Int { count(deepKey, at: date) }

    /// The first day of next month, when the counts start again.
    static func resetDate(after date: Date = Date(), calendar: Calendar = .current) -> Date {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        return calendar.date(byAdding: .month, value: 1, to: start) ?? date
    }

    static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private func count(_ key: String, at date: Date) -> Int {
        (defaults.dictionary(forKey: key) as? [String: Int])?[Self.monthKey(for: date)] ?? 0
    }

    private func add(to key: String, at date: Date) {
        var months = (defaults.dictionary(forKey: key) as? [String: Int]) ?? [:]
        months[Self.monthKey(for: date), default: 0] += 1
        // Keep a year of history.
        if months.count > 12 {
            let keep = Set(months.keys.sorted().suffix(12))
            months = months.filter { keep.contains($0.key) }
        }
        defaults.set(months, forKey: key)
    }
}
