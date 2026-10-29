import Foundation

/// Compatibility adapter for older Messages-shaped planners. All transport
/// goes through the authenticated Bibbles Worker.
enum ClaudeAPI {
    static let baseURL = WorkerAPI.baseURL.absoluteString
    static let version = "2023-06-01"
    /// Legacy model labels are retained for local task/UI classification only.
    static let fastModel = "deepseek/deepseek-v4.1-flash"
    /// Legacy fast-model label.
    static let haikuModel = "claude-haiku-4-5-20251001"
    /// Fast, low-cost model for everyday requests.
    static var defaultModel: String { fastModel }
    /// Below this self-rated confidence (75%), the fast model hands over to Sonnet.
    static let handOverConfidence = 0.75
    /// Stronger model for charts and genuinely complex requests.
    static let smartModel = "claude-sonnet-5-5"
    /// Used when the fast model is unsure about a screen question.
    static let screenFallbackModel = smartModel

    /// Which model(s) Bibbles may use, chosen in the menu.
    enum ModelPreference: String, CaseIterable {
        case auto, haiku, sonnet

        var title: String {
            switch self {
            case .auto: return "Auto (fast, advanced when needed)"
            case .haiku: return "Always fast"
            case .sonnet: return "Always advanced"
            }
        }
    }

    private static let preferenceKey = "bibbles.modelPreference"

    /// AI quality is fixed on Auto: the other options are shown in Settings
    /// but can't be chosen. A choice saved by an older version is ignored.
    static var preference: ModelPreference {
        get { .auto }
        set { UserDefaults.standard.removeObject(forKey: preferenceKey) }
    }

    /// Model for everyday requests. Override with BIBBLES_CLAUDE_MODEL.
    static var model: String {
        if let value = ProcessInfo.processInfo.environment["BIBBLES_CLAUDE_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           value.hasPrefix("claude-") {
            return value
        }
        return preference == .sonnet ? smartModel : defaultModel
    }

    /// Chart analysis always uses the stronger model unless "Always Haiku" is chosen.
    static var chartModel: String {
        preference == .haiku ? model : smartModel
    }

    /// Whether Haiku may hand a hard request to Sonnet.
    static var allowsEscalation: Bool {
        preference == .auto && model != smartModel
    }

    static func displayName(for model: String) -> String {
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        if model == fastModel { return "Fast" }
        if model.contains("opus") { return "Opus" }
        return model
    }

    static var messagesURL: URL { WorkerAPI.baseURL.appendingPathComponent("v1/chat") }

    static func apiKey(fallback: String? = nil) -> String? {
        // Legacy call sites still take this parameter; it is never sent to a
        // provider. WorkerAPI obtains a refreshed Supabase session per request.
        "worker"
    }

    static func request(url: URL = messagesURL, apiKey: String, timeout: TimeInterval? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    // MARK: Which model answered (testing aid)

    /// Testing aid: the answer card shows which model answered.
    /// Set to false before launch so users don't see model names.
    static let showsModelOnAnswers = true
    /// The model that actually answered the latest request.
    static var lastUsedModel: String?
    /// True when DeepSeek failed and Haiku answered instead.
    static var lastUsedWasBackup = false

    /// The answer card label, e.g. "DeepSeek V4.1 Flash". Nil when no AI model
    /// answered (the answer was made on the Mac).
    /// Shows the kind of task, never the model's name: "Light Task" for the
    /// fast model (and its backup), "Deep Task" for the advanced one.
    static func answeredByLabel() -> String? {
        guard let model = lastUsedModel else { return nil }
        return taskLabel(for: model)
    }

    static func taskLabel(for model: String) -> String {
        if model == fastModel || model.contains("haiku") { return "Light Task" }
        if model.contains("sonnet") || model.contains("opus") { return "Deep Task" }
        return model // "Live weather" and similar, which name no model
    }

    static func fullName(for model: String) -> String {
        if model == fastModel { return "DeepSeek V4.1 Flash" }
        if model.contains("sonnet") { return "Sonnet 5.5" }
        if model.contains("haiku") { return "Haiku 4.5" }
        if model.contains("opus") { return "Opus" }
        return model
    }

    private static func record(_ model: String?, backup: Bool = false) {
        lastUsedModel = model
        lastUsedWasBackup = backup
    }

    private static func requestedModel(of request: URLRequest) -> String? {
        guard let data = request.httpBody,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return body["model"] as? String
    }

    /// Adapts legacy text-only Messages-shaped call sites to the authenticated
    /// Worker. Multimodal call sites use WorkerAPI.vision directly.
    static func data(for request: URLRequest, session: URLSession = .shared) async throws -> (Data, URLResponse) {
        _ = try await AccountSession.shared.workerAccessToken()
        guard let raw = request.httpBody,
              let body = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let items = body["messages"] as? [[String: Any]] else { throw WorkerError.invalidResponse }
        var messages: [[String: String]] = []
        if let system = body["system"] as? String { messages.append(["role": "system", "content": system]) }
        for item in items {
            guard let role = item["role"] as? String, ["user", "assistant", "system"].contains(role),
                  let content = item["content"] as? String else { throw WorkerError.unsupportedImage }
            messages.append(["role": role, "content": content])
        }
        let model = requestedModel(of: request) ?? Self.model
        let mode = WorkerAPI.mode(for: model)
        let text = try await WorkerAPI.chat(mode: mode, messages: messages,
                                            maxTokens: body["max_tokens"] as? Int, session: session)
        record(model)
        let response = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]]])
        return (response, HTTPURLResponse(url: WorkerAPI.baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    /// Joins the text blocks of a non-streaming Messages API response.
    /// Also accepts an OpenAI-style chat completion envelope.
    static func responseText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let content = object["content"] as? [[String: Any]] {
            let text = content
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            return text.isEmpty ? nil : text
        }
        if let choice = (object["choices"] as? [[String: Any]])?.first,
           let message = choice["message"] as? [String: Any],
           let text = message["content"] as? String {
            return text
        }
        return nil
    }

    /// Strips code fences and any prose around the outermost JSON object.
    static func jsonObjectText(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        if !text.hasPrefix("{"),
           let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        return text
    }
}
