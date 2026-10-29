import Foundation

struct SpeechVocabularyStore {
    static let maximumTerms = 100
    static let maximumCharactersPerTerm = 80

    private let defaults: UserDefaults
    private let key = "bibbles.speech.vocabulary.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var terms: [String] {
        Self.normalizedTerms(defaults.stringArray(forKey: key) ?? [])
    }

    @discardableResult
    func save(text: String) -> [String] {
        let values = text.components(separatedBy: .newlines)
        let normalized = Self.normalizedTerms(values)
        defaults.set(normalized, forKey: key)
        return normalized
    }

    @discardableResult
    func add(_ term: String) -> Bool {
        let normalized = Self.normalizedTerms(terms + [term])
        let candidate = Self.normalizedTerms([term]).first
        guard let candidate,
              normalized.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) else {
            return false
        }
        defaults.set(normalized, forKey: key)
        return true
    }

    func merged(with configuredTerms: [String]) -> [String] {
        Self.normalizedTerms(configuredTerms + terms)
    }

    static func normalizedTerms(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let collapsed = value
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !collapsed.isEmpty else { continue }
            let term = String(collapsed.prefix(maximumCharactersPerTerm))
            let identity = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(identity).inserted else { continue }
            result.append(term)
            if result.count == maximumTerms { break }
        }
        return result
    }
}
