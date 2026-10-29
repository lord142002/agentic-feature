import Foundation

/// Everything Bibbles asks an AI service for. `WorkerBackend` is the Bibbles
/// Worker (every customer). Developer builds add `LocalBackend`, which calls
/// the providers directly with the developer's own Keychain keys.
protocol Backend {
    /// Throws when AI features can't run right now (for example: not signed in).
    func ensureReady() async throws
    func chat(mode: WorkerAPI.Mode, messages: [[String: String]], maxTokens: Int?,
              session: URLSession) async throws -> String
    func chatStream(mode: WorkerAPI.Mode, messages: [[String: String]], maxTokens: Int?,
                    session: URLSession, onUpdate: @MainActor (String) -> Void) async throws -> ChatStreamResult
    /// An Anthropic-shaped (or chat-completion) reply body.
    func vision(body: [String: Any], tier: WorkerAPI.VisionTier, session: URLSession) async throws -> Data
    func transcribe(wav: Data, language: String?, session: URLSession) async throws -> String
    /// Raw 16-bit mono PCM at 24 kHz.
    func speechPCM(text: String, voice: String, session: URLSession) async throws -> Data
    /// The AI router's transport; nil means "skip the router".
    func routerClient() async -> RouterClient?
    /// Plan and usage (`/v1/me` shape).
    func me(session: URLSession) async throws -> [String: Any]
    func deleteAccount(session: URLSession) async throws
}

/// The one switch that decides which backend every feature uses.
enum Backends {
    static var current: Backend {
        #if BIBBLES_DEVELOPER
        if LocalMode.isOn { return LocalBackend() }
        #endif
        return WorkerBackend()
    }

    /// True while Local mode is on (developer builds only; always false for customers).
    static var isLocal: Bool {
        #if BIBBLES_DEVELOPER
        return LocalMode.isOn
        #else
        return false
        #endif
    }
}

/// The Bibbles Worker: today's behaviour, unchanged.
struct WorkerBackend: Backend {
    func ensureReady() async throws {
        _ = try await WorkerAPI.accessToken()
    }

    func chat(mode: WorkerAPI.Mode, messages: [[String: String]], maxTokens: Int?,
              session: URLSession) async throws -> String {
        let body = WorkerAPI.chatBody(mode: mode, messages: messages, maxTokens: maxTokens, stream: false)
        let data = try await WorkerAPI.send(path: "v1/chat", method: "POST", contentType: "application/json",
                                            body: JSONSerialization.data(withJSONObject: body), session: session)
        return try WorkerAPI.parseChat(data, mode: mode)
    }

    func chatStream(mode: WorkerAPI.Mode, messages: [[String: String]], maxTokens: Int?,
                    session: URLSession, onUpdate: @MainActor (String) -> Void) async throws -> ChatStreamResult {
        let token = try await WorkerAPI.accessToken()
        let body = WorkerAPI.chatBody(mode: mode, messages: messages, maxTokens: maxTokens, stream: true)
        let request = WorkerAPI.request(path: "v1/chat", method: "POST", contentType: "application/json",
                                        body: try JSONSerialization.data(withJSONObject: body), token: token)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkerError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                if data.count >= 4_096 { break }
                data.append(byte)
            }
            throw WorkerError.from(status: http.statusCode, data: data,
                                   retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }
        return try await WorkerAPI.collectStream(bytes.lines, onUpdate: onUpdate)
    }

    func vision(body: [String: Any], tier: WorkerAPI.VisionTier, session: URLSession) async throws -> Data {
        let data = try WorkerAPI.visionPayload(body: body, tier: tier)
        return try await WorkerAPI.send(path: "v1/vision", method: "POST", contentType: "application/json",
                                        body: data, session: session)
    }

    /// `language`: an ISO-639-1 code from Settings → Dictation → I speak;
    /// nil lets the service detect it (sent exactly as before). If a request
    /// with a language comes back without a readable transcript, it is sent
    /// once more without the language, the way Bibbles always sent it.
    func transcribe(wav: Data, language: String?, session: URLSession) async throws -> String {
        if let language {
            do {
                let data = try await WorkerAPI.send(path: "v1/transcribe", method: "POST", contentType: "audio/wav",
                                                    body: wav, session: session,
                                                    query: [URLQueryItem(name: "language", value: language)])
                guard let text = WorkerAPI.transcript(from: data) else { throw WorkerError.invalidResponse }
                return text
            } catch WorkerError.badRequest {
                // Only when the Worker refused the language setting itself
                // (nothing was transcribed or charged) is the recording sent
                // again without it. Any other failure is reported, so one
                // recording is never paid for twice.
            }
        }
        let data = try await WorkerAPI.send(path: "v1/transcribe", method: "POST", contentType: "audio/wav",
                                            body: wav, session: session)
        guard let text = WorkerAPI.transcript(from: data) else { throw WorkerError.invalidResponse }
        return text
    }

    func speechPCM(text: String, voice: String, session: URLSession) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["text": text, "voice": voice])
        let data = try await WorkerAPI.send(path: "v1/tts", method: "POST", contentType: "application/json",
                                            body: body, session: session)
        guard data.count > 64 else { throw WorkerError.invalidResponse }
        return data
    }

    func routerClient() async -> RouterClient? {
        guard RouterClient.serverAllowed, let token = try? await WorkerAPI.accessToken() else { return nil }
        return RouterClient(serverToken: token)
    }

    func me(session: URLSession) async throws -> [String: Any] {
        let data = try await WorkerAPI.send(path: "v1/me", method: "GET", session: session)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WorkerError.invalidResponse
        }
        return object
    }

    func deleteAccount(session: URLSession) async throws {
        _ = try await WorkerAPI.send(path: "v1/account", method: "DELETE", session: session)
    }
}
