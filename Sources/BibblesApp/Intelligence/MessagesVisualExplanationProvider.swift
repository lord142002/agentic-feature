import Foundation

struct MessagesVisualExplanationProvider {
    let apiKey: String?

    static func isRequested(_ question: String) -> Bool {
        guard !VisualExplanation.isMathLessonQuestion(question) else { return false }
        let text = question.lowercased()
        return ["visually", "with a diagram", "draw a diagram", "animated explanation", "doodle explanation"].contains(where: text.contains)
    }

    @MainActor func explain(_ question: String) async throws -> VisualExplanation {
        guard let apiKey, !apiKey.isEmpty else { throw VisualExplanationError.missingKey }
        var request = ClaudeAPI.request(apiKey: apiKey, timeout: 90)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": ChatConversationStore.model,
            "max_tokens": 4_096,
            "system": """
                You are Bibbles, a concise visual teacher. Return only a JSON explanation with this schema:
                {"title":"Short title","steps":[{"title":"Step title","explanation":"Brief explanation","strokes":[{"points":[{"x":0.2,"y":0.3},{"x":0.8,"y":0.7}],"tone":"teal"}],"labels":[{"text":"Label","position":{"x":0.5,"y":0.5}}]}]}.
                Use 2–4 steps. Each step is a complete scene on a square canvas, top-left origin. All coordinates must be in [0,1], preferably [0.1,0.9]. Strokes are polylines; use at most 10 strokes, 40 points per stroke and 6 labels per step. Allowed tones: teal, violet, coral, amber. Labels must be under 40 characters. Do not draw graphs, equations, geometry lessons, or invented UI locations. You cannot see the screen in this request. Do not emit executable code, HTML or SVG. \(ToolGate.languageRule(legacy: "Match the user's language.")) Prefer one useful diagram per step over decoration. Reply with the JSON object only, with no text before or after it.
                """,
            "messages": [
                ["role": "user", "content": String(question.prefix(8_000))]
            ]
        ] as [String: Any])
        let (data, response) = try await ClaudeAPI.data(for: request)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw VisualExplanationError.server(status)
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> VisualExplanation {
        guard data.count <= 300_000,
              let text = ClaudeAPI.responseText(from: data) else { throw VisualExplanationError.invalidPlan }
        let content = ClaudeAPI.jsonObjectText(text)
        guard let payload = content.data(using: .utf8),
              let scene = try? JSONDecoder().decode(VisualExplanation.self, from: payload), scene.isValid else {
            throw VisualExplanationError.invalidPlan
        }
        return scene
    }
}

enum VisualExplanationError: LocalizedError {
    case missingKey, invalidPlan, server(Int)
    var errorDescription: String? {
        switch self {
        case .missingKey: return "Please sign in to Bibbles to create an AI visual explanation."
        case .invalidPlan: return "Bibbles couldn't build a complete visual explanation. Try a shorter question or tap Retry."
        case .server(let status): return "The visual explanation service could not complete the request (HTTP \(status)). Tap Retry."
        }
    }
}
