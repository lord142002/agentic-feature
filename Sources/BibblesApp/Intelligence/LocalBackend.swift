#if BIBBLES_DEVELOPER
import Foundation

/// Developer toggle "Local mode (use my keys, skip the server)", default OFF.
/// ON: every AI feature calls the providers directly with the developer's
/// Keychain keys, and the app makes ZERO requests to the Bibbles server
/// (no `/v1/*` at all, not even `/v1/me`). Sign-in state is untouched.
enum LocalMode {
    static let defaultsKey = "bibbles.dev.localMode"
    /// Tests only.
    static var testOverride: Bool?

    static var isOn: Bool {
        get { testOverride ?? UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

enum LocalBackendError: LocalizedError, Equatable {
    /// A key the request needs is not saved.
    case missingKey(DeveloperKeySlot)
    /// The provider refused the request.
    case provider(name: String, status: Int, problem: String)
    /// Something that only the Bibbles server can do (billing, account deletion).
    case serverOff
    case tooManyImages
    case payloadTooLarge
    case audioTooLarge
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let slot):
            let name = slot.title.replacingOccurrences(of: " (optional)", with: "")
            return "Add your \(name) key in Settings → Developer."
        case .provider(let name, let status, let problem):
            return "\(name) refused the request (\(problem), http \(status))."
        case .serverOff:
            return "Local mode is on, so Bibbles doesn't contact its server. Turn Local mode off in Settings → Developer to do this."
        case .tooManyImages: return "Local mode sends at most \(LocalBackend.maxImages) images per request."
        case .payloadTooLarge: return "This request is over \(LocalBackend.maxVisionBytes / 1_000_000) MB."
        case .audioTooLarge: return "This recording is over \(LocalBackend.maxAudioBytes / 1_000_000) MB."
        case .invalidResponse(let name): return "\(name) sent an unreadable reply."
        }
    }

    /// The exact problem for a provider's HTTP error (same words as the key Test).
    static func from(provider name: String, slot: DeveloperKeySlot, status: Int, body: Data) -> LocalBackendError {
        let problem = DeveloperKeyTester.classify(slot: slot, status: status, body: body)
        return .provider(name: name, status: status, problem: problem.isOK ? "http \(status)" : problem.text)
    }
}

/// Calls the providers directly, matching the live Worker's models, limits and
/// privacy settings. Developer builds only; keys come only from `DeveloperKeychain`.
struct LocalBackend: Backend {
    static let openRouterBase = URL(string: "https://openrouter.ai/api/v1/")!
    static let anthropicMessagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let deepgramListenURL = URL(string: "https://api.deepgram.com/v1/listen")!

    static let lightMaxTokens = 4_096
    static let deepMaxTokens = 8_192
    static let maxImages = 4
    static let maxVisionBytes = 10_000_000
    static let maxAudioBytes = 25_000_000
    static let timeout: TimeInterval = 90
    static let streamTimeout: TimeInterval = 180
    static let maxSpeechCharacters = 2_000

    /// Sent with every OpenRouter request: providers may not keep or train on the data.
    static let privacy: [String: Any] = ["data_collection": "deny"]

    /// Keys are checked per request, with a message naming the missing key.
    func ensureReady() async throws {}

    static func key(_ slot: DeveloperKeySlot) throws -> String {
        guard let key = DeveloperKeychain.read(slot), !key.isEmpty else { throw LocalBackendError.missingKey(slot) }
        return key
    }

    // MARK: Chat

    func chat(mode: WorkerAPI.Mode, messages: [[String: String]], maxTokens: Int?,
              session: URLSession) async throws -> String {
        let started = Date()
        if mode == .deep, ModelCatalog.selected(.deep).provider == .openrouter {
            // An OpenRouter deep model (GPT-6.1 Sol): the OpenRouter key, chat-completion format.
            let model = ModelCatalog.selected(.deep).id
            let request = try Self.openRouterChatRequest(model: model, messages: Self.chatMessages(messages),
                                                         maxTokens: Self.cap(maxTokens, Self.deepMaxTokens), stream: false,
                                                         search: false, key: Self.key(.openrouter))
            let data = try await Self.send(request, provider: "OpenRouter", slot: .openrouter, session: session)
            LocalCostLog.shared.record(feature: "chat deep", model: model, reply: data, started: started)
            return try WorkerAPI.parseChat(data, mode: mode)
        }
        if mode == .deep {
            let model = ModelCatalog.selected(.deep).id
            let body = Self.anthropicBody(model: model, messages: messages,
                                          maxTokens: Self.cap(maxTokens, Self.deepMaxTokens), stream: false, search: false)
            let data = try await Self.send(Self.anthropicRequest(body: body, key: Self.key(.anthropic)),
                                           provider: "Anthropic", slot: .anthropic, session: session)
            LocalCostLog.shared.record(feature: "chat deep", model: model, reply: data, started: started)
            return try WorkerAPI.parseChat(data, mode: mode)
        }
        let search = mode == .search
        let limit = Self.cap(maxTokens, Self.lightMaxTokens)
        return try await Self.withLightBackup(primary: {
            let model = ModelCatalog.selected(.light).id
            let request = try Self.openRouterChatRequest(model: model, messages: Self.chatMessages(messages),
                                                         maxTokens: limit, stream: false, search: search,
                                                         key: Self.key(.openrouter))
            let data = try await Self.send(request, provider: "OpenRouter", slot: .openrouter, session: session)
            LocalCostLog.shared.record(feature: search ? "search" : "chat light", model: model, reply: data, started: started)
            return try WorkerAPI.parseChat(data, mode: mode)
        }, backup: {
            let model = ModelCatalog.haiku45.id
            let body = Self.anthropicBody(model: model, messages: messages, maxTokens: limit, stream: false, search: search)
            let data = try await Self.send(Self.anthropicRequest(body: body, key: Self.key(.anthropic)),
                                           provider: "Anthropic", slot: .anthropic, session: session)
            LocalCostLog.shared.record(feature: (search ? "search" : "chat light") + " (backup)", model: model, reply: data, started: started)
            return try WorkerAPI.parseChat(data, mode: mode)
        })
    }

    func chatStream(mode: WorkerAPI.Mode, messages: [[String: String]], maxTokens: Int?,
                    session: URLSession, onUpdate: @MainActor (String) -> Void) async throws -> ChatStreamResult {
        let started = Date()
        if mode == .deep, ModelCatalog.selected(.deep).provider == .openrouter {
            let model = ModelCatalog.selected(.deep).id
            let request = try Self.openRouterChatRequest(model: model, messages: Self.chatMessages(messages),
                                                         maxTokens: Self.cap(maxTokens, Self.deepMaxTokens), stream: true,
                                                         search: false, key: Self.key(.openrouter))
            let result = try await Self.stream(request, provider: "OpenRouter", slot: .openrouter, session: session,
                                               onUpdate: onUpdate)
            LocalCostLog.shared.recordLastUsage(feature: "chat deep", model: model, started: started)
            return result
        }
        if mode == .deep {
            let model = ModelCatalog.selected(.deep).id
            let body = Self.anthropicBody(model: model, messages: messages,
                                          maxTokens: Self.cap(maxTokens, Self.deepMaxTokens), stream: true, search: false)
            let result = try await Self.stream(Self.anthropicRequest(body: body, key: Self.key(.anthropic), stream: true),
                                               provider: "Anthropic", slot: .anthropic, session: session, onUpdate: onUpdate)
            LocalCostLog.shared.recordLastUsage(feature: "chat deep", model: model, started: started)
            return result
        }
        let search = mode == .search
        let limit = Self.cap(maxTokens, Self.lightMaxTokens)
        // The backup runs only when nothing was shown yet.
        let shown = ShownFlag()
        return try await Self.withLightBackup(primary: {
            let model = ModelCatalog.selected(.light).id
            let request = try Self.openRouterChatRequest(model: model, messages: Self.chatMessages(messages),
                                                         maxTokens: limit, stream: true, search: search,
                                                         key: Self.key(.openrouter))
            let result = try await Self.stream(request, provider: "OpenRouter", slot: .openrouter, session: session,
                                               onUpdate: { text in
                                                   shown.value = true
                                                   onUpdate(text)
                                               })
            LocalCostLog.shared.recordLastUsage(feature: search ? "search" : "chat light", model: model, started: started)
            return result
        }, backup: {
            let model = ModelCatalog.haiku45.id
            let body = Self.anthropicBody(model: model, messages: messages, maxTokens: limit, stream: true, search: search)
            let result = try await Self.stream(Self.anthropicRequest(body: body, key: Self.key(.anthropic), stream: true),
                                               provider: "Anthropic", slot: .anthropic, session: session, onUpdate: onUpdate)
            LocalCostLog.shared.recordLastUsage(feature: (search ? "search" : "chat light") + " (backup)", model: model, started: started)
            return result
        }, mayUseBackup: { !shown.value })
    }

    // MARK: Vision

    func vision(body: [String: Any], tier: WorkerAPI.VisionTier, session: URLSession) async throws -> Data {
        let started = Date()
        var request = body
        request.removeValue(forKey: "model")
        request.removeValue(forKey: "tier")
        try Self.checkVisionLimits(request)
        if tier == .deep, ModelCatalog.selected(.deep).provider == .openrouter {
            let model = ModelCatalog.selected(.deep).id
            var openRouter = Self.openRouterVisionBody(request, model: model, cap: Self.deepMaxTokens)
            openRouter["provider"] = Self.privacy
            let data = try await Self.send(Self.openRouterRequest(path: "chat/completions", json: openRouter,
                                                                  key: Self.key(.openrouter)),
                                           provider: "OpenRouter", slot: .openrouter, session: session)
            LocalCostLog.shared.record(feature: "vision deep", model: model, reply: data, started: started)
            return data
        }
        if tier == .deep {
            let model = ModelCatalog.selected(.deep).id
            let anthropic = Self.anthropicVisionBody(request, model: model, cap: Self.deepMaxTokens)
            let data = try await Self.send(Self.anthropicRequest(body: anthropic, key: Self.key(.anthropic)),
                                           provider: "Anthropic", slot: .anthropic, session: session)
            LocalCostLog.shared.record(feature: "vision deep", model: model, reply: data, started: started)
            return data
        }
        return try await Self.withLightBackup(primary: {
            let model = ModelCatalog.selected(.light).id
            var openRouter = Self.openRouterVisionBody(request, model: model)
            openRouter["provider"] = Self.privacy
            let data = try await Self.send(Self.openRouterRequest(path: "chat/completions", json: openRouter,
                                                                  key: Self.key(.openrouter)),
                                           provider: "OpenRouter", slot: .openrouter, session: session)
            LocalCostLog.shared.record(feature: "vision light", model: model, reply: data, started: started)
            return data
        }, backup: {
            let model = ModelCatalog.haiku45.id
            let anthropic = Self.anthropicVisionBody(request, model: model, cap: Self.lightMaxTokens)
            let data = try await Self.send(Self.anthropicRequest(body: anthropic, key: Self.key(.anthropic)),
                                           provider: "Anthropic", slot: .anthropic, session: session)
            LocalCostLog.shared.record(feature: "vision light (backup)", model: model, reply: data, started: started)
            return data
        })
    }

    static func checkVisionLimits(_ body: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= maxVisionBytes else { throw LocalBackendError.payloadTooLarge }
        let messages = body["messages"] as? [[String: Any]] ?? []
        let images = messages.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .filter { $0["type"] as? String == "image" }.count
        guard images <= maxImages else { throw LocalBackendError.tooManyImages }
    }

    /// The app's Anthropic-shaped vision body, for Anthropic itself.
    static func anthropicVisionBody(_ body: [String: Any], model: String, cap: Int) -> [String: Any] {
        var anthropic = body
        anthropic["model"] = model
        anthropic["max_tokens"] = self.cap(body["max_tokens"] as? Int, cap)
        if ModelCatalog.choice(id: model)?.acceptsTemperature == false { anthropic.removeValue(forKey: "temperature") }
        return anthropic
    }

    /// The same request in chat-completion form: image blocks become data URLs.
    static func openRouterVisionBody(_ body: [String: Any], model: String, cap limit: Int = lightMaxTokens) -> [String: Any] {
        var messages: [[String: Any]] = []
        if let system = body["system"] as? String, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        for message in body["messages"] as? [[String: Any]] ?? [] {
            let role = message["role"] as? String ?? "user"
            if let text = message["content"] as? String {
                messages.append(["role": role, "content": text])
                continue
            }
            let parts: [[String: Any]] = ((message["content"] as? [[String: Any]]) ?? []).compactMap { block in
                switch block["type"] as? String {
                case "text":
                    return ["type": "text", "text": block["text"] as? String ?? ""]
                case "image":
                    guard let source = block["source"] as? [String: Any], let data = source["data"] as? String else { return nil }
                    let media = source["media_type"] as? String ?? "image/jpeg"
                    return ["type": "image_url", "image_url": ["url": "data:\(media);base64,\(data)"]]
                default:
                    return nil
                }
            }
            messages.append(["role": role, "content": parts])
        }
        var result: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": cap(body["max_tokens"] as? Int, limit)
        ]
        if let temperature = body["temperature"], ModelCatalog.choice(id: model)?.acceptsTemperature != false {
            result["temperature"] = temperature
        }
        return result
    }

    // MARK: Speech

    /// OpenRouter speech to text first; Deepgram nova-3 when that key is set.
    func transcribe(wav: Data, language: String?, session: URLSession) async throws -> String {
        guard wav.count <= Self.maxAudioBytes else { throw LocalBackendError.audioTooLarge }
        let started = Date()
        let seconds = Double(max(0, wav.count - 44)) / Double(PCMFrame.sampleRate * 2)
        let primary: () async throws -> String = {
            let request = try Self.transcriptionRequest(wav: wav, language: language, seconds: seconds,
                                                        key: Self.key(.openrouter))
            let data = try await Self.send(request, provider: "OpenRouter", slot: .openrouter, session: session)
            guard let text = WorkerAPI.transcript(from: data) else { throw LocalBackendError.invalidResponse("OpenRouter") }
            LocalCostLog.shared.record(feature: "speech to text", model: ModelCatalog.speechToText,
                                       cost: seconds * ModelCatalog.speechToTextPerSecond, started: started)
            return text
        }
        if DeveloperKeychain.has(.openrouter) {
            do { return try await primary() } catch {
                guard DeveloperKeychain.has(.deepgram), !(error is CancellationError) else { throw error }
            }
        } else if !DeveloperKeychain.has(.deepgram) {
            throw LocalBackendError.missingKey(.openrouter)
        }
        let data = try await Self.send(Self.deepgramRequest(wav: wav, language: language, key: Self.key(.deepgram)),
                                       provider: "Deepgram", slot: .deepgram, session: session)
        guard let text = WorkerAPI.transcript(from: data) else { throw LocalBackendError.invalidResponse("Deepgram") }
        LocalCostLog.shared.record(feature: "speech to text (backup)", model: ModelCatalog.deepgramModel, cost: nil, started: started)
        return text
    }

    /// The live Worker's wait: min(12 s, 5 s + 0.5 s × clip length).
    static func transcriptionTimeout(seconds: Double) -> TimeInterval {
        min(12, 5 + 0.5 * seconds)
    }

    static func transcriptionRequest(wav: Data, language: String?, seconds: Double, key: String) throws -> URLRequest {
        var body: [String: Any] = [
            "model": ModelCatalog.speechToText,
            "input_audio": ["data": wav.base64EncodedString(), "format": "wav"],
            "provider": privacy
        ]
        if let language { body["language"] = language }
        var request = try openRouterRequest(path: "audio/transcriptions", json: body, key: key)
        request.timeoutInterval = transcriptionTimeout(seconds: seconds)
        return request
    }

    static func deepgramRequest(wav: Data, language: String?, key: String) -> URLRequest {
        var components = URLComponents(url: deepgramListenURL, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "model", value: ModelCatalog.deepgramModel),
                     URLQueryItem(name: "smart_format", value: "true")]
        if let language { items.append(URLQueryItem(name: "language", value: language)) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = wav
        return request
    }

    /// Raw 24 kHz, 16-bit mono PCM, the same as the Worker returns.
    func speechPCM(text: String, voice: String, session: URLSession) async throws -> Data {
        let started = Date()
        let data = try await Self.send(Self.speechRequest(text: text, voice: voice, key: Self.key(.openrouter)),
                                       provider: "OpenRouter", slot: .openrouter, session: session)
        guard data.count > 64 else { throw LocalBackendError.invalidResponse("OpenRouter") }
        let characters = min(text.count, Self.maxSpeechCharacters)
        // About 4 characters per input token; output is billed as audio.
        LocalCostLog.shared.record(feature: "spoken answer", model: ModelCatalog.textToSpeech,
                                   cost: Double(characters) / 4 * ModelCatalog.textToSpeechInputPerMillion / 1_000_000,
                                   started: started)
        return data
    }

    static func speechRequest(text: String, voice: String, key: String) throws -> URLRequest {
        let body: [String: Any] = [
            "model": ModelCatalog.textToSpeech,
            "input": String(text.prefix(maxSpeechCharacters)),
            "voice": voice.isEmpty ? OpenRouterSpeech.defaultEnglishVoice : voice,
            "response_format": "pcm",
            "provider": privacy
        ]
        return try openRouterRequest(path: "audio/speech", json: body, key: key)
    }

    // MARK: Router, usage, account

    /// Haiku directly with the Anthropic key (same body as `HybridRouter.requestBody`).
    func routerClient() async -> RouterClient? {
        guard let key = DeveloperKeychain.read(.anthropic), !key.isEmpty else { return nil }
        return RouterClient(key: key)
    }

    /// The last usage synced in server mode; nothing is fetched.
    func me(session: URLSession) async throws -> [String: Any] {
        guard let cached = LocalUsageCache.load() else { throw LocalBackendError.serverOff }
        return cached.payload
    }

    func deleteAccount(session: URLSession) async throws {
        throw LocalBackendError.serverOff
    }

    // MARK: Request building

    static func cap(_ requested: Int?, _ limit: Int) -> Int {
        min(max(1, requested ?? limit), limit)
    }

    /// Worker-style messages ([role, content]) as chat-completion messages.
    static func chatMessages(_ messages: [[String: String]]) -> [[String: Any]] {
        messages.compactMap { message in
            guard let role = message["role"], let content = message["content"] else { return nil }
            return ["role": role, "content": content]
        }
    }

    static func anthropicBody(model: String, messages: [[String: String]], maxTokens: Int,
                              stream: Bool, search: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages.filter { $0["role"] != "system" },
            "stream": stream
        ]
        let system = messages.filter({ $0["role"] == "system" }).compactMap({ $0["content"] }).joined(separator: "\n")
        if !system.isEmpty { body["system"] = system }
        if search { body["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 5]] }
        return body
    }

    static func openRouterChatRequest(model: String, messages: [[String: Any]], maxTokens: Int,
                                      stream: Bool, search: Bool, key: String) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": maxTokens,
            "stream": stream,
            "provider": privacy,
            "usage": ["include": true]
        ]
        if search { body["plugins"] = [["id": "web", "max_results": 5]] }
        var request = try openRouterRequest(path: "chat/completions", json: body, key: key)
        if stream { request.timeoutInterval = streamTimeout }
        return request
    }

    static func openRouterRequest(path: String, json: [String: Any], key: String) throws -> URLRequest {
        var request = URLRequest(url: openRouterBase.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return request
    }

    static func anthropicRequest(body: [String: Any], key: String, stream: Bool = false) throws -> URLRequest {
        var request = URLRequest(url: anthropicMessagesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? streamTimeout : timeout
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Transport

    static func send(_ request: URLRequest, provider: String, slot: DeveloperKeySlot,
                     session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalBackendError.invalidResponse(provider) }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalBackendError.from(provider: provider, slot: slot, status: http.statusCode, body: data)
        }
        return data
    }

    static func stream(_ request: URLRequest, provider: String, slot: DeveloperKeySlot, session: URLSession,
                       onUpdate: @MainActor (String) -> Void) async throws -> ChatStreamResult {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalBackendError.invalidResponse(provider) }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                if data.count >= 4_096 { break }
                data.append(byte)
            }
            throw LocalBackendError.from(provider: provider, slot: slot, status: http.statusCode, body: data)
        }
        WorkerAPI.lastUsage = nil
        return try await WorkerAPI.collectStream(bytes.lines, onUpdate: onUpdate)
    }

    /// Light tasks: OpenRouter first; the Anthropic backup when OpenRouter fails
    /// (or has no key) and an Anthropic key is saved.
    static func withLightBackup<T>(primary: () async throws -> T, backup: () async throws -> T,
                                   mayUseBackup: () -> Bool = { true }) async throws -> T {
        if DeveloperKeychain.has(.openrouter) {
            do { return try await primary() } catch {
                guard DeveloperKeychain.has(.anthropic), !(error is CancellationError), mayUseBackup() else { throw error }
            }
        } else if !DeveloperKeychain.has(.anthropic) {
            throw LocalBackendError.missingKey(.openrouter)
        }
        return try await backup()
    }
}

/// Whether a streamed answer already showed text (then no backup may run).
private final class ShownFlag: @unchecked Sendable {
    var value = false
}

// MARK: - Usage shown in Local mode

/// The last `/v1/me` usage numbers from server mode, so Local mode can show
/// (not enforce) the plan. Only plan, month, usage and limits are kept: no
/// tokens, emails or IDs.
struct LocalUsageCache {
    static let defaultsKey = "bibbles.dev.lastSyncedUsage"
    static let keptFields = ["plan", "month", "usage", "limits"]

    let payload: [String: Any]
    let syncedAt: Date

    var snapshot: WorkerUsageSnapshot? { WorkerUsageSnapshot(payload) }

    static func save(_ payload: [String: Any], at date: Date = Date(), defaults: UserDefaults = .standard) {
        var kept: [String: Any] = [:]
        for field in keptFields { if let value = payload[field] { kept[field] = value } }
        guard JSONSerialization.isValidJSONObject(kept),
              let data = try? JSONSerialization.data(withJSONObject: kept) else { return }
        defaults.set(["payload": data, "syncedAt": date.timeIntervalSince1970], forKey: defaultsKey)
    }

    static func load(defaults: UserDefaults = .standard) -> LocalUsageCache? {
        guard let stored = defaults.dictionary(forKey: defaultsKey),
              let data = stored["payload"] as? Data,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let seconds = stored["syncedAt"] as? Double else { return nil }
        return LocalUsageCache(payload: payload, syncedAt: Date(timeIntervalSince1970: seconds))
    }

    /// "Last synced 29 Oct, 14:05 (Local mode — not counting)".
    var label: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Last synced \(formatter.string(from: syncedAt)) (Local mode — not counting)"
    }
}

// MARK: - Developer cost log

/// Estimated cost of each Local mode request (tokens × the ModelCatalog price
/// table). In memory only; never user text.
final class LocalCostLog {
    static let shared = LocalCostLog()

    struct Entry {
        let date: Date
        let feature: String
        let model: String
        let inputTokens: Int?
        let outputTokens: Int?
        let cost: Double?
        let milliseconds: Int
    }

    private let lock = NSLock()
    private var stored: [Entry] = []
    private let limit = 200

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var totalCost: Double { entries.compactMap(\.cost).reduce(0, +) }

    func record(_ entry: Entry) {
        lock.lock()
        stored.append(entry)
        if stored.count > limit { stored.removeFirst(stored.count - limit) }
        lock.unlock()
    }

    /// From a non-streamed reply's `usage` (Anthropic or chat-completion).
    func record(feature: String, model: String, reply: Data, started: Date) {
        let usage = Self.usage(in: reply)
        record(Entry(date: Date(), feature: feature, model: model, inputTokens: usage.input, outputTokens: usage.output,
                     cost: ModelCatalog.estimatedCost(model: model, inputTokens: usage.input, outputTokens: usage.output),
                     milliseconds: Int(Date().timeIntervalSince(started) * 1000)))
    }

    /// A router call through OpenRouter: the model that really answered and
    /// OpenRouter's own cost (usage.cost), since the router model's price varies.
    func recordRouter(model: String, reply: Data, milliseconds: Int) {
        let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
        let answered = object?["model"] as? String
        let usage = Self.usage(in: reply)
        let cost = ((object?["usage"] as? [String: Any])?["cost"] as? NSNumber)?.doubleValue
        // "typesafe/jev-1.14-20261014" is the dated snapshot of the same model, not another one.
        let label = answered.map { $0.hasPrefix(model) ? model : model + " → " + $0 } ?? model
        record(Entry(date: Date(), feature: "router", model: label, inputTokens: usage.input, outputTokens: usage.output,
                     cost: cost, milliseconds: milliseconds))
    }

    /// After a stream: the usage it reported.
    func recordLastUsage(feature: String, model: String, started: Date) {
        let usage = WorkerAPI.lastUsage
        record(Entry(date: Date(), feature: feature, model: model, inputTokens: usage?.input, outputTokens: usage?.output,
                     cost: ModelCatalog.estimatedCost(model: model, inputTokens: usage?.input, outputTokens: usage?.output),
                     milliseconds: Int(Date().timeIntervalSince(started) * 1000)))
    }

    /// Audio and other non-token prices.
    func record(feature: String, model: String, cost: Double?, started: Date) {
        record(Entry(date: Date(), feature: feature, model: model, inputTokens: nil, outputTokens: nil, cost: cost,
                     milliseconds: Int(Date().timeIntervalSince(started) * 1000)))
    }

    func clear() {
        lock.lock()
        stored = []
        lock.unlock()
    }

    static func usage(in reply: Data) -> (input: Int?, output: Int?) {
        guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else { return (nil, nil) }
        func number(_ key: String) -> Int? { (usage[key] as? NSNumber)?.intValue }
        return (number("input_tokens") ?? number("prompt_tokens"), number("output_tokens") ?? number("completion_tokens"))
    }

    /// A Markdown table for the clipboard.
    func table() -> String {
        var lines = ["| Time | Feature | Model | In | Out | Est. cost | ms |", "|---|---|---|---|---|---|---|"]
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        for entry in entries {
            lines.append("| \(formatter.string(from: entry.date)) | \(entry.feature) | \(entry.model) | "
                         + "\(entry.inputTokens.map(String.init) ?? "—") | \(entry.outputTokens.map(String.init) ?? "—") | "
                         + "\(ModelCatalog.formatted(entry.cost)) | \(entry.milliseconds) |")
        }
        lines.append("")
        lines.append("Total estimated: \(ModelCatalog.formatted(totalCost)) over \(entries.count) requests")
        return lines.joined(separator: "\n")
    }
}
#endif
