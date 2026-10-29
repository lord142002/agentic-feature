import Foundation

struct BibblesConfiguration: Equatable {
    let deepgramAPIKey: String?
    let deepgramModel: String
    let deepgramLanguage: String
    let deepgramKeyterms: [String]
    let anthropicAPIKey: String?
    let visionBaseURL: String
    let visionPrimaryModel: String
    let visionFallbackModel: String

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> BibblesConfiguration {
        BibblesConfiguration(
            deepgramAPIKey: nil,
            deepgramModel: environment["BIBBLES_STT_MODEL"]?.nilIfBlank ?? "nova-3",
            deepgramLanguage: environment["BIBBLES_STT_LANGUAGE"]?.nilIfBlank ?? "multi",
            deepgramKeyterms: environment["BIBBLES_STT_KEYTERMS"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? [],
            anthropicAPIKey: nil,
            visionBaseURL: environment["BIBBLES_VISION_BASE_URL"]?.nilIfBlank
                ?? ClaudeAPI.baseURL,
            visionPrimaryModel: environment["BIBBLES_VISION_PRIMARY_MODEL"]?.claudeModel
                ?? ClaudeAPI.model,
            visionFallbackModel: environment["BIBBLES_VISION_FALLBACK_MODEL"]?.claudeModel
                ?? ClaudeAPI.screenFallbackModel
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }

    var claudeModel: String? {
        guard let value = nilIfBlank, value.hasPrefix("claude-") else { return nil }
        return value
    }
}
