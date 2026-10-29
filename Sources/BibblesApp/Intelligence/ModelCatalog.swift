#if BIBBLES_DEVELOPER
import Foundation

/// Who serves a model in Local mode (which developer key it needs).
enum ModelProvider: String {
    case openrouter, anthropic

    var keySlot: DeveloperKeySlot {
        switch self {
        case .openrouter: return .openrouter
        case .anthropic: return .anthropic
        }
    }
}

/// One pinned model ID and its price (US dollars per million tokens).
struct ModelChoice: Identifiable, Equatable {
    let id: String
    let provider: ModelProvider
    let name: String
    let inputPerMillion: Double
    let outputPerMillion: Double
    /// Whether the provider accepts `temperature` for this model.
    var acceptsTemperature = true
}

/// What a model is used for. Developer builds only; customers never see model names.
enum ModelFeature: String, CaseIterable, Identifiable {
    case light, deep, router, agentPlanner, agentBackup, screenAgent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .deep: return "Deep"
        case .router: return "Router"
        case .agentPlanner: return "Agent planner"
        case .agentBackup: return "Agent backup"
        case .screenAgent: return "Screen agent"
        }
    }
}

/// Feature → model for Local mode, plus the price table for cost estimates.
/// IDs and prices verified live on 2026-10-29 (docs/MODELS.md). Pinned IDs
/// only: never a `latest` alias.
enum ModelCatalog {
    static let verifiedOn = "2026-10-29"

    // MARK: Pinned models

    static let deepSeekFlash = ModelChoice(id: "deepseek/deepseek-v4.1-flash", provider: .openrouter,
                                           name: "DeepSeek V4.1 Flash", inputPerMillion: 0.045, outputPerMillion: 0.50)
    static let haiku45 = ModelChoice(id: "claude-haiku-4-5-20251001", provider: .anthropic,
                                     name: "Haiku 4.5", inputPerMillion: 1.00, outputPerMillion: 5.00)
    static let haiku55 = ModelChoice(id: "claude-haiku-5-5", provider: .anthropic,
                                     name: "Haiku 5.5", inputPerMillion: 0.10, outputPerMillion: 0.50,
                                     acceptsTemperature: false)
    static let sonnet55 = ModelChoice(id: "claude-sonnet-5-5", provider: .anthropic,
                                      name: "Sonnet 5.5", inputPerMillion: 2.00, outputPerMillion: 10.00,
                                      acceptsTemperature: false)
    static let gpt5Mini = ModelChoice(id: "openai/gpt-5-mini", provider: .openrouter,
                                      name: "GPT-5 mini", inputPerMillion: 0.25, outputPerMillion: 2.00,
                                      acceptsTemperature: false)
    static let gemini38Flash = ModelChoice(id: "google/gemini-3.8-flash", provider: .openrouter,
                                           name: "Gemini 3.8 Flash", inputPerMillion: 0.825, outputPerMillion: 4.125)

    /// Speech (OpenRouter), and Deepgram as the speech-to-text backup.
    static let speechToText = "nvidia/nemotron-3.5-asr-streaming-multilingual-0.6b"
    /// OpenRouter lists this per second of audio.
    static let speechToTextPerSecond = 0.00000333
    static let textToSpeech = OpenRouterSpeech.model
    static let textToSpeechInputPerMillion = 0.50
    static let textToSpeechOutputPerMillion = 6.00
    static let deepgramModel = "nova-3"

    static let all: [ModelChoice] = [deepSeekFlash, haiku45, haiku55, sonnet55, gpt5Mini, gemini38Flash]

    // MARK: Choices

    static func choices(for feature: ModelFeature) -> [ModelChoice] {
        switch feature {
        case .light: return [deepSeekFlash]
        case .deep: return [sonnet55]
        case .router: return [haiku45]
        case .agentPlanner: return [gpt5Mini, haiku55, gemini38Flash, haiku45, sonnet55]
        case .agentBackup: return [haiku45, haiku55]
        // GPT-5 mini: cheapest reliable screen planner in testing (2026-10-29).
        case .screenAgent: return [gpt5Mini, gemini38Flash, haiku55, sonnet55]
        }
    }

    static func defaultChoice(for feature: ModelFeature) -> ModelChoice {
        choices(for: feature)[0]
    }

    static func defaultsKey(for feature: ModelFeature) -> String { "bibbles.dev.model." + feature.rawValue }

    /// The picked model (model choices are not secrets, so UserDefaults is fine;
    /// keys never go there). An unknown saved ID falls back to the default.
    static func selected(_ feature: ModelFeature, defaults: UserDefaults = .standard) -> ModelChoice {
        let saved = defaults.string(forKey: defaultsKey(for: feature))
        return choices(for: feature).first { $0.id == saved } ?? defaultChoice(for: feature)
    }

    static func select(_ choice: ModelChoice, for feature: ModelFeature, defaults: UserDefaults = .standard) {
        guard choices(for: feature).contains(choice) else { return }
        defaults.set(choice.id, forKey: defaultsKey(for: feature))
    }

    // MARK: Prices

    static func choice(id: String) -> ModelChoice? {
        all.first { $0.id == id }
    }

    /// Estimated US dollars for one request; nil for an unknown model.
    static func estimatedCost(model: String, inputTokens: Int?, outputTokens: Int?) -> Double? {
        guard let choice = choice(id: model) else { return nil }
        return (Double(inputTokens ?? 0) * choice.inputPerMillion + Double(outputTokens ?? 0) * choice.outputPerMillion)
            / 1_000_000
    }

    static func formatted(_ cost: Double?) -> String {
        guard let cost else { return "—" }
        return cost < 0.01 ? String(format: "$%.5f", cost) : String(format: "$%.3f", cost)
    }
}
#endif
