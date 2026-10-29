import Foundation

enum DictationOutputMode: String, CaseIterable, Codable {
    case verbatim
    case clean

    var title: String { self == .verbatim ? "Verbatim" : "Clean" }
}

struct SpeechCorrection: Codable, Equatable, Identifiable {
    var id: String { heard.lowercased() }
    let heard: String
    let replacement: String
}

struct DictationPreferences {
    private let defaults: UserDefaults
    private let key = "bibbles.dictation.outputMode.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var mode: DictationOutputMode {
        get { DictationOutputMode(rawValue: defaults.string(forKey: key) ?? "") ?? .clean }
        nonmutating set { defaults.set(newValue.rawValue, forKey: key) }
    }
}

struct SpeechCorrectionStore {
    private let key = "bibbles.speech.approvedCorrections.v1"

    var corrections: [SpeechCorrection] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode([SpeechCorrection].self, from: data) else { return [] }
        return values
    }

    /// The caller must obtain explicit approval before invoking this method.
    @discardableResult
    func approve(heard: String, replacement: String) -> [SpeechCorrection] {
        let source = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !target.isEmpty, source.count <= 120, target.count <= 120 else {
            return corrections
        }
        var values = corrections.filter { $0.heard.caseInsensitiveCompare(source) != .orderedSame }
        values.append(SpeechCorrection(heard: source, replacement: target))
        values.sort { $0.heard.count > $1.heard.count }
        if let data = try? JSONEncoder().encode(Array(values.prefix(100))) {
            UserDefaults.standard.set(data, forKey: key)
        }
        return Array(values.prefix(100))
    }
}

enum DictationProcessor {
    static func process(
        _ transcript: String,
        mode: DictationOutputMode,
        corrections: [SpeechCorrection]
    ) -> String {
        var result = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        for correction in corrections.sorted(by: { $0.heard.count > $1.heard.count }) {
            result = result.replacingOccurrences(
                of: correction.heard,
                with: correction.replacement,
                options: [.caseInsensitive],
                range: result.startIndex..<result.endIndex
            )
        }
        guard mode == .clean else { return result }

        let fillers = ["um", "uh", "erm", "you know"]
        for filler in fillers {
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            result = result.replacingOccurrences(
                of: "(?i)(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])[, ]*",
                with: "",
                options: .regularExpression
            )
        }
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = result.first, first.isLowercase {
            result.replaceSubrange(result.startIndex...result.startIndex, with: String(first).uppercased())
        }
        if let last = result.last, !".!?।".contains(last) { result.append(".") }
        return result
    }
}
