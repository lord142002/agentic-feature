import Foundation

/// Developer-only: sends every `RouterTestSet` phrase (with its flags) to the
/// AI router ONLY. No answers, no Worker requests, nothing typed anywhere.
struct RouterTestRow: Equatable {
    let index: Int
    let language: String
    let expected: HybridRoute
    let route: HybridRoute?
    let confidence: Double?
    let milliseconds: Int
    let jsonParsed: Bool
    let failure: String?
    /// Old keywords: today's rules (with the always-on "here" fix), no router.
    let today: HybridRoute
    /// The improved keyword pass verdict ("keep", "clause → write", "unclear → router").
    let keyword: String
    /// The route the improved keyword pass decided on its own; nil = sent to the router.
    let keywordRoute: HybridRoute?
    /// New keywords (clauses, fillers), no router: unclear keeps today's behaviour.
    let newKeywords: HybridRoute
    /// New keywords + router: the router only when unclear, accepted at the
    /// default confidence bar.
    var hybrid: HybridRoute { hybrid(threshold: HybridRouter.acceptThreshold) }

    /// New keywords + router at any confidence bar (for tuning).
    func hybrid(threshold: Double) -> HybridRoute {
        if let keywordRoute { return keywordRoute }
        if let route, route != .unclear, (confidence ?? 0) >= threshold { return route }
        return today
    }

    /// The router's raw label matches.
    var correct: Bool { route == expected }
    /// What a live request would get: the label only counts when it clears
    /// the confidence bar; below it Bibbles falls back to today's behaviour.
    var accepted: Bool { HybridRouter.accept(route.map { RouterResult(route: $0, confidence: confidence ?? 0) }) != nil }
}

enum RouterTestRunner {
    /// Long enough to measure real latency; rows over the live 1,000 ms
    /// budget are counted separately.
    static let measurementTimeout: TimeInterval = 5

    static func run(client: RouterClient, cases: [RouterTestCase] = RouterTestSet.cases, concurrency: Int = 3,
                    progress: @escaping @Sendable (Int, Int) async -> Void) async -> [RouterTestRow] {
        var rows: [RouterTestRow] = []
        await withTaskGroup(of: RouterTestRow.self) { group in
            var next = 0
            while next < min(concurrency, cases.count) {
                let item = cases[next], index = next
                group.addTask { await row(for: item, index: index, client: client) }
                next += 1
            }
            while let finished = await group.next() {
                rows.append(finished)
                await progress(rows.count, cases.count)
                if next < cases.count {
                    let item = cases[next], index = next
                    group.addTask { await row(for: item, index: index, client: client) }
                    next += 1
                }
            }
        }
        return rows.sorted { $0.index < $1.index }
    }

    static func row(for item: RouterTestCase, index: Int, client: RouterClient) async -> RouterTestRow {
        let outcome = await client.classify(text: item.text, flags: item.flags, timeout: measurementTimeout)
        let local = localRoutes(for: item)
        let keywordRoute: HybridRoute?
        switch local.verdict {
        case .keep: keywordRoute = local.today
        case .clause(let route), .gate(let route): keywordRoute = route
        case .unclear: keywordRoute = nil
        }
        return RouterTestRow(index: index + 1, language: item.language, expected: item.expected,
                             route: outcome.result?.route, confidence: outcome.result?.confidence,
                             milliseconds: outcome.milliseconds, jsonParsed: outcome.jsonParsed,
                             failure: outcome.failure, today: local.today,
                             keyword: describe(local.verdict), keywordRoute: keywordRoute,
                             newKeywords: keywordRoute ?? local.today)
    }

    /// Today's route and the keyword verdict, computed locally (free, no network).
    static func localRoutes(for item: RouterTestCase) -> (today: HybridRoute, verdict: HybridRouter.KeywordVerdict) {
        let router = IntentRouter()
        let today = HybridRouter.baselineRoute(for: item.text, flags: item.flags, intentRouter: router)
        return (today, HybridRouter.keywordVerdict(for: item.text, flags: item.flags, intentRouter: router, improvements: true))
    }

    static func describe(_ verdict: HybridRouter.KeywordVerdict) -> String {
        switch verdict {
        case .keep(let strength): return "keep (\(strength.rawValue))"
        case .clause(let route): return "clause → \(route.rawValue)"
        case .gate(let route): return "gate → \(route.rawValue)"
        case .unclear: return "unclear → router"
        }
    }

    /// A Markdown report to paste into a chat.
    static func report(_ rows: [RouterTestRow], liveBudget: Int = Int(HybridRouter.liveTimeout * 1000)) -> String {
        func percent(_ part: Int, _ whole: Int) -> String {
            whole == 0 ? "—" : String(format: "%.0f%% (%d/%d)", Double(part) / Double(whole) * 100, part, whole)
        }
        var lines = ["# Router test results", "",
                     "Model: `\(HybridRouter.model)` · threshold \(HybridRouter.acceptThreshold) · live budget \(liveBudget) ms", ""]
        let answered = rows.filter { $0.route != nil }
        let times = rows.filter { $0.failure != "timeout" }.map(\.milliseconds).sorted()
        let average = times.isEmpty ? 0 : times.reduce(0, +) / times.count
        let median = times.isEmpty ? 0 : times[times.count / 2]
        let p90 = times.isEmpty ? 0 : times[min(times.count - 1, Int(Double(times.count) * 0.9))]
        let liveCorrect = rows.filter { row in
            row.accepted ? row.correct : row.expected == .unclear
        }.count
        lines += [
            "## Totals",
            "- **Old keywords** (today, with the \"here\" fix): \(percent(rows.filter { $0.today == $0.expected }.count, rows.count))",
            "- **New keywords** (clauses + fillers, no router): \(percent(rows.filter { $0.newKeywords == $0.expected }.count, rows.count))",
            "- **New keywords + Haiku router** (at \(HybridRouter.acceptThreshold)): \(percent(rows.filter { $0.hybrid == $0.expected }.count, rows.count))",
            "- Router label on every phrase: \(percent(rows.filter(\.correct).count, rows.count))",
            "- Sent to the router live (keyword pass unclear): \(rows.filter { $0.keyword.hasPrefix("unclear") }.count)/\(rows.count)",
            "- Live accuracy (label used only at ≥ \(HybridRouter.acceptThreshold) confidence, otherwise today's behaviour): \(percent(liveCorrect, rows.count))",
            "- Below threshold (would fall back): \(rows.filter { $0.route != nil && !$0.accepted }.count)",
            "- Wrong AND confident (would misroute live): \(rows.filter { $0.accepted && !$0.correct }.count)",
            "- Latency: average \(average) ms · median \(median) ms · p90 \(p90) ms · slowest \(times.last ?? 0) ms",
            "- Over the \(liveBudget) ms live budget: \(rows.filter { $0.milliseconds > liveBudget }.count) · timeouts: \(rows.filter { $0.failure == "timeout" }.count)",
            "- JSON failures: \(rows.filter { !$0.jsonParsed && $0.failure == "json" }.count) · other errors: \(rows.filter { $0.failure != nil && $0.failure != "json" && $0.failure != "timeout" }.count) \(Set(rows.compactMap(\.failure)).sorted().joined(separator: ", "))",
            "- Answered: \(answered.count)/\(rows.count)",
            ""
        ]
        // Confidence vs correctness, for tuning the threshold.
        let bar = HybridRouter.acceptThreshold
        let labelled = rows.filter { $0.route != nil }
        let correctAbove = labelled.filter { $0.correct && ($0.confidence ?? 0) >= bar }.count
        let correctBelow = labelled.filter { $0.correct && ($0.confidence ?? 0) < bar }.count
        let wrongAbove = labelled.filter { !$0.correct && ($0.confidence ?? 0) >= bar }.count
        let wrongBelow = labelled.filter { !$0.correct && ($0.confidence ?? 0) < bar }.count
        lines += [
            "## Router confidence vs correctness (all \(labelled.count) labelled phrases)",
            "| | ≥ \(bar) (used) | < \(bar) (falls back) |", "|---|---|---|",
            "| correct | \(correctAbove) | \(correctBelow) |",
            "| wrong | \(wrongAbove) | \(wrongBelow) |", "",
            "Same split for phrases the keyword pass actually sends to the router live:",
            "| | ≥ \(bar) | < \(bar) |", "|---|---|---|"
        ]
        let routed = labelled.filter { $0.keywordRoute == nil }
        lines += [
            "| correct | \(routed.filter { $0.correct && ($0.confidence ?? 0) >= bar }.count) | \(routed.filter { $0.correct && ($0.confidence ?? 0) < bar }.count) |",
            "| wrong | \(routed.filter { !$0.correct && ($0.confidence ?? 0) >= bar }.count) | \(routed.filter { !$0.correct && ($0.confidence ?? 0) < bar }.count) |", ""
        ]
        lines += ["## Threshold sweep (new keywords + router)",
                  "| threshold | router answers used | correct used | wrong used (misroutes) | fell back | overall accuracy |",
                  "|---|---|---|---|---|---|"]
        for threshold in [0.5, 0.6, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95] {
            let used = routed.filter { $0.route != .unclear && ($0.confidence ?? 0) >= threshold }
            let overall = rows.filter { $0.hybrid(threshold: threshold) == $0.expected }.count
            lines.append("| \(threshold)\(threshold == bar ? " (current)" : "") | \(used.count) | \(used.filter(\.correct).count) | \(used.filter { !$0.correct }.count) | \(routed.count - used.count) | \(percent(overall, rows.count)) |")
        }
        lines.append("")
        lines += ["## Per route", "| route | old keywords | new keywords | new + router | router label | router live | avg conf |", "|---|---|---|---|---|---|---|"]
        for route in HybridRoute.allCases {
            let group = rows.filter { $0.expected == route }
            guard !group.isEmpty else { continue }
            let live = group.filter { $0.accepted ? $0.correct : $0.expected == .unclear }.count
            let confidences = group.compactMap(\.confidence)
            let avg = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
            lines.append("| \(route.rawValue) | \(percent(group.filter { $0.today == $0.expected }.count, group.count)) | \(percent(group.filter { $0.newKeywords == $0.expected }.count, group.count)) | \(percent(group.filter { $0.hybrid == $0.expected }.count, group.count)) | \(percent(group.filter(\.correct).count, group.count)) | \(percent(live, group.count)) | \(String(format: "%.2f", avg)) |")
        }
        lines += ["", "## Per language", "| language | old keywords | new keywords | new + router | router label | avg ms |", "|---|---|---|---|---|---|"]
        for language in Array(Set(rows.map(\.language))).sorted() {
            let group = rows.filter { $0.language == language }
            let ms = group.map(\.milliseconds).reduce(0, +) / max(1, group.count)
            lines.append("| \(language) | \(percent(group.filter { $0.today == $0.expected }.count, group.count)) | \(percent(group.filter { $0.newKeywords == $0.expected }.count, group.count)) | \(percent(group.filter { $0.hybrid == $0.expected }.count, group.count)) | \(percent(group.filter(\.correct).count, group.count)) | \(ms) |")
        }
        lines += ["", "## Misroutes", "| # | language | expected | router | confidence |", "|---|---|---|---|---|"]
        for row in rows where !row.correct {
            lines.append("| \(row.index) | \(row.language) | \(row.expected.rawValue) | \(row.route?.rawValue ?? (row.failure ?? "—")) | \(row.confidence.map { String(format: "%.2f", $0) } ?? "—") |")
        }
        lines += ["", "## All rows", "| # | language | expected | router route | confidence | ms | correct | old keywords | keyword pass | new keywords | new + router |", "|---|---|---|---|---|---|---|---|---|---|---|"]
        for row in rows {
            lines.append("| \(row.index) | \(row.language) | \(row.expected.rawValue) | \(row.route?.rawValue ?? (row.failure ?? "—")) | \(row.confidence.map { String(format: "%.2f", $0) } ?? "—") | \(row.milliseconds) | \(row.correct ? "yes" : "no") | \(row.today.rawValue) | \(row.keyword) | \(row.newKeywords.rawValue) | \(row.hybrid.rawValue) |")
        }
        return lines.joined(separator: "\n")
    }
}
