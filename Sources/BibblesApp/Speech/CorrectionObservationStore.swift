import Foundation

struct CorrectionObservation: Codable, Equatable {
    let heard: String
    let intended: String
    var count: Int
    var suggestionShown: Bool
}

struct CorrectionObservationResult: Equatable {
    let count: Int
    let suggestedTerm: String?
}

/// Keeps only explicitly reported term pairs on this Mac. No full transcript is saved.
struct CorrectionObservationStore {
    private let defaults: UserDefaults
    private let key = "bibbles.speech.correctionObservations.v1"
    private let suggestionThreshold = 3

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    @discardableResult
    func record(heard: String, intended: String) -> CorrectionObservationResult? {
        let source = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = intended.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !target.isEmpty,
              source.count <= 80, target.count <= 80,
              source.caseInsensitiveCompare(target) != .orderedSame else { return nil }

        var observations = load()
        let index = observations.firstIndex {
            $0.heard.caseInsensitiveCompare(source) == .orderedSame
                && $0.intended.caseInsensitiveCompare(target) == .orderedSame
        }
        let result: CorrectionObservationResult
        if let index {
            var observation = observations.remove(at: index)
            observation.count += 1
            let shouldSuggest = observation.count >= suggestionThreshold
                && !observation.suggestionShown
            if shouldSuggest { observation.suggestionShown = true }
            observations.append(observation)
            result = CorrectionObservationResult(
                count: observation.count,
                suggestedTerm: shouldSuggest ? observation.intended : nil
            )
        } else {
            observations.append(CorrectionObservation(
                heard: source,
                intended: target,
                count: 1,
                suggestionShown: false
            ))
            result = CorrectionObservationResult(count: 1, suggestedTerm: nil)
        }
        if let data = try? JSONEncoder().encode(Array(observations.suffix(100))) {
            defaults.set(data, forKey: key)
        }
        return result
    }

    private func load() -> [CorrectionObservation] {
        guard let data = defaults.data(forKey: key),
              let observations = try? JSONDecoder().decode([CorrectionObservation].self, from: data) else {
            return []
        }
        return observations
    }
}
