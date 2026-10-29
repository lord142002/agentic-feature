import Foundation

enum WorkerError: LocalizedError, Equatable {
    case signInRequired
    /// The plan's monthly allowance for this counter is used up.
    case limitReached(String)
    /// Too many requests in a short time; not a quota. Seconds to wait, if the Worker said.
    case rateLimited(retryAfter: Int?)
    case temporarilyUnavailable
    case server
    case unsupportedImage
    case payloadTooLarge
    case invalidResponse
    /// The Worker rejected the request itself (400/422), before doing any paid work.
    case badRequest
    /// The answer stream stopped before the AI said it was finished.
    case incompleteResponse
    /// Another free account already used this Mac's free credits.
    case deviceLimit
    /// The question (text or images) is over the Worker's size cap.
    case inputTooLarge
    /// Account deletion stopped because the paid subscription couldn't be cancelled first.
    case subscriptionCancelFailed

    var errorDescription: String? {
        switch self {
        case .signInRequired: return "Please sign in to Bibbles to continue."
        case .limitReached(let counter):
            let name = counter.replacingOccurrences(of: "_", with: " ")
            return "Your monthly \(name) limit has been reached. Check Account for remaining usage."
        case .rateLimited(let seconds):
            if let seconds, (1...120).contains(seconds) {
                return "Bibbles is getting too many requests right now. Please try again in \(seconds) second\(seconds == 1 ? "" : "s")."
            }
            return "Bibbles is getting too many requests right now. Please wait a few seconds and try again."
        case .temporarilyUnavailable: return "This feature is temporarily unavailable. Please try again later."
        case .server: return "Bibbles had a server problem. Please retry."
        case .unsupportedImage: return "Bibbles could not prepare this image request for screen help. No screenshot was sent."
        case .payloadTooLarge: return "This screen capture is too large to analyze. Try a smaller window or crop."
        case .invalidResponse: return "Bibbles received an unreadable response. Please retry."
        case .badRequest: return "Bibbles couldn't process that request. Please try again."
        case .incompleteResponse: return "The answer was cut off before it finished. Please retry."
        case .deviceLimit:
            return "The free plan on this Mac is already used by another Bibbles account. Sign in with that account or upgrade in Settings → Account."
        case .inputTooLarge: return "This request is too long. Shorten it or attach less text, then try again."
        case .subscriptionCancelFailed:
            return "Your account was not deleted because your subscription couldn't be cancelled. Try again in a minute, or cancel your plan in Manage billing first."
        }
    }

    /// `retryAfter`: the response's `Retry-After` header, when there is one.
    static func from(status: Int, data: Data, retryAfter: String? = nil) -> WorkerError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = object?["error"] as? String ?? ""
        let counter = object?["counter"] as? String
        let wait = retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            ?? (object?["retry_after"] as? NSNumber)?.intValue
        switch (status, code) {
        case (_, "device_limit"): return .deviceLimit
        case (_, "input_too_large"): return .inputTooLarge
        case (_, "subscription_cancel_failed"): return .subscriptionCancelFailed
        case (401, _), (_, "unauthorized"): return .signInRequired
        // Only an explicit quota answer means the monthly allowance is gone.
        case (_, "limit_reached"), (_, "quota_exceeded"), (_, "monthly_limit_reached"):
            return .limitReached(counter ?? "usage")
        case (_, "rate_limited"), (_, "too_many_requests"):
            return .rateLimited(retryAfter: wait)
        case (429, _):
            // A 429 that names a usage counter is a quota; any other 429 is a short rate limit.
            if let counter { return .limitReached(counter) }
            return .rateLimited(retryAfter: wait)
        case (503, _), (_, "maintenance"), (_, "mode_disabled"): return .temporarilyUnavailable
        case (413, _), (_, "payload_too_large"): return .payloadTooLarge
        case (400, _), (422, _), (_, "bad_request"), (_, "invalid_request"), (_, "unsupported_language"): return .badRequest
        default: return .server
        }
    }
}

/// Entry point for metered AI operations. Every call goes through
/// `Backends.current`: the Bibbles Worker for customers (the app contains no
/// provider credential and never retries an authenticated request
/// anonymously); developer builds can switch to Local mode.
enum WorkerAPI {
    static let baseURL = URL(string: "https://bibbles-api.bibbles.workers.dev")!

    enum Mode: String { case ask, nemotron, search, deep }

    /// Token counts of the latest streamed chat reply, when the stream
    /// reports them (developer Tool Gate log only).
    static var lastUsage: (input: Int?, output: Int?)?
    enum VisionTier: String { case light, deep }

    static func mode(for model: String, search: Bool = false) -> Mode {
        if search { return .search }
        return model.contains("sonnet") || model.contains("opus") ? .deep : .ask
    }

    static func mode(forPrompt prompt: String, search: Bool = false, forceDeep: Bool = false,
                     forceFast: Bool = false) -> Mode {
        if search { return .search }
        if forceDeep { return .deep }
        if forceFast { return .ask }
        let normalized = prompt.lowercased()
        let hardTaskSignals = ["analyze this architecture", "review this code", "debug this", "derive", "prove that",
                               "research in depth", "compare in detail", "step-by-step solution", "multi-step analysis"]
        return prompt.count > 1_200 || hardTaskSignals.contains(where: normalized.contains) ? .deep : .ask
    }

    /// `idempotencyKey`: one fresh key per user action, sent with every
    /// metered request so the Worker can recognise a duplicate delivery and
    /// charge it only once.
    static func request(path: String, method: String, contentType: String? = nil,
                        body: Data? = nil, token: String, query: [URLQueryItem]? = nil,
                        idempotencyKey: String = UUID().uuidString) -> URLRequest {
        var url = baseURL.appendingPathComponent(path)
        if let query, !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if method != "GET" { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let device = DeviceIdentity.hashedID { request.setValue(device, forHTTPHeaderField: DeviceIdentity.headerName) }
        request.httpBody = body
        return request
    }

    #if BIBBLES_DEVELOPER
    /// Tests only: a stand-in sign-in token, so Worker requests can be checked without an account.
    static var testAccessToken: String?
    #endif

    /// The signed-in user's token for Worker requests.
    static func accessToken() async throws -> String {
        #if BIBBLES_DEVELOPER
        if let testAccessToken { return testAccessToken }
        #endif
        return try await AccountSession.shared.workerAccessToken()
    }

    static func send(path: String, method: String, contentType: String? = nil,
                     body: Data? = nil, session: URLSession = .shared,
                     query: [URLQueryItem]? = nil) async throws -> Data {
        let token = try await accessToken()
        return try await perform(request(path: path, method: method, contentType: contentType,
                                         body: body, token: token, query: query), session: session)
    }

    /// Sends a metered request exactly once. Bibbles never retries on its
    /// own: the Worker counts usage before it calls the AI provider, so an
    /// automatic retry could charge the user twice for one question. Errors
    /// go to the user, who can choose to try again.
    static func perform(_ request: URLRequest, session: URLSession = .shared) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkerError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw WorkerError.from(status: http.statusCode, data: data,
                                   retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }
        return data
    }

    static func chat(mode: Mode, messages: [[String: String]], maxTokens: Int? = nil,
                     session: URLSession = .shared) async throws -> String {
        try await Backends.current.chat(mode: mode, messages: messages, maxTokens: maxTokens, session: session)
    }

    static func chatBody(mode: Mode, messages: [[String: String]], maxTokens: Int?, stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "mode": mode.rawValue,
            "messages": messages.filter { $0["role"] != "system" },
            "stream": stream
        ]
        let system = messages.filter({ $0["role"] == "system" }).compactMap({ $0["content"] }).joined(separator: "\n")
        if !system.isEmpty { body["system"] = system }
        if let maxTokens { body["max_tokens"] = maxTokens }
        return body
    }

    static func chatStream(mode: Mode, messages: [[String: String]], maxTokens: Int? = nil,
                           session: URLSession = .shared,
                           onUpdate: @MainActor (String) -> Void) async throws -> ChatStreamResult {
        try await Backends.current.chatStream(mode: mode, messages: messages, maxTokens: maxTokens,
                                              session: session, onUpdate: onUpdate)
    }

    /// Reads server-sent events (Anthropic or chat-completion chunks) into one answer.
    static func collectStream<Lines: AsyncSequence>(_ lines: Lines,
                                                    onUpdate: @MainActor (String) -> Void) async throws -> ChatStreamResult
        where Lines.Element == String {
        var collector = ChatStreamCollector()
        for try await line in lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if let usage = ChatStreamParser.usage(from: payload) {
                lastUsage = (input: usage.input ?? lastUsage?.input, output: usage.output ?? lastUsage?.output)
            }
            if try collector.consume(payload) { await onUpdate(collector.text) }
            if collector.sawDone { break }
        }
        try Task.checkCancellation()
        return try collector.result()
    }

    static func parseChat(_ data: Data, mode: Mode) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WorkerError.invalidResponse
        }
        let blocks = object["content"] as? [[String: Any]]
        let anthropicText = blocks?.filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }.joined()
        let text = (anthropicText?.isEmpty == false ? anthropicText : nil)
            ?? ((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkerError.invalidResponse
        }
        return text
    }

    /// `language`: an ISO-639-1 code from Settings → Dictation → I speak;
    /// nil lets the service detect it.
    static func transcribe(wav: Data, language: String? = nil, session: URLSession = .shared) async throws -> String {
        try await Backends.current.transcribe(wav: wav, language: language, session: session)
    }

    /// The transcript in the Worker's reply: Deepgram JSON
    /// (`results.channels[0].alternatives[0].transcript`), or a plain
    /// `text` / `transcript` field. Nil when there is no text.
    static func transcript(from data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var candidates: [Any?] = []
        if let results = object["results"] as? [String: Any],
           let channel = (results["channels"] as? [[String: Any]])?.first,
           let alternative = (channel["alternatives"] as? [[String: Any]])?.first {
            candidates.append(alternative["transcript"])
        }
        candidates.append(object["text"])
        candidates.append(object["transcript"])
        if let result = object["result"] as? [String: Any] {
            candidates.append(result["text"])
            candidates.append(result["transcript"])
        }
        for candidate in candidates {
            if let text = (candidate as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// Raw 16-bit mono PCM at 24 kHz; this is not a WAV body.
    static func speechPCM(text: String, voice: String, session: URLSession = .shared) async throws -> Data {
        try await Backends.current.speechPCM(text: text, voice: voice, session: session)
    }

    static func vision(body: [String: Any], tier: VisionTier,
                       session: URLSession = .shared) async throws -> Data {
        try await Backends.current.vision(body: body, tier: tier, session: session)
    }

    static func visionPayload(body: [String: Any], tier: VisionTier) throws -> Data {
        var payload = body
        payload.removeValue(forKey: "model")
        payload["tier"] = tier.rawValue
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard data.count <= 10_000_000 else { throw WorkerError.payloadTooLarge }
        return data
    }

    static func me(session: URLSession = .shared) async throws -> [String: Any] {
        try await Backends.current.me(session: session)
    }

    static func deleteAccount(session: URLSession = .shared) async throws {
        try await Backends.current.deleteAccount(session: session)
    }
}

struct WorkerUsageSnapshot: Equatable {
    /// Authoritative account entitlement dates, never inferred from `month`.
    struct CurrentPlan: Equatable {
        let plan: String
        let status: String
        let startedAt: Date
        let accessEndsAt: Date?
        let renewsAt: Date?

        init?(_ value: Any, expectedPlan: String) {
            guard let object = value as? [String: Any],
                  let plan = object["plan"] as? String,
                  plan.caseInsensitiveCompare(expectedPlan) == .orderedSame,
                  let status = object["status"] as? String, !status.isEmpty,
                  let startedAt = WorkerUsageSnapshot.date(object["started_at"]),
                  let rawEnd = object["access_ends_at"],
                  let rawRenewal = object["renews_at"] else { return nil }
            let accessEndsAt = rawEnd is NSNull ? nil : WorkerUsageSnapshot.date(rawEnd)
            let renewsAt = rawRenewal is NSNull ? nil : WorkerUsageSnapshot.date(rawRenewal)
            guard (rawEnd is NSNull || accessEndsAt != nil),
                  (rawRenewal is NSNull || renewsAt != nil),
                  accessEndsAt.map({ $0 >= startedAt }) ?? true,
                  renewsAt.map({ $0 >= startedAt }) ?? true else { return nil }
            self.plan = plan
            self.status = status
            self.startedAt = startedAt
            self.accessEndsAt = accessEndsAt
            self.renewsAt = renewsAt
        }
    }

    struct PastPlan: Equatable {
        let plan: String
        let startedAt: Date
        let endedAt: Date
        let endReason: String

        init?(_ value: Any) {
            guard let object = value as? [String: Any],
                  let plan = object["plan"] as? String, !plan.isEmpty,
                  let startedAt = WorkerUsageSnapshot.date(object["started_at"]),
                  let endedAt = WorkerUsageSnapshot.date(object["ended_at"]), endedAt >= startedAt,
                  let endReason = object["end_reason"] as? String, !endReason.isEmpty else { return nil }
            self.plan = plan
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.endReason = endReason
        }
    }

    struct Counter: Equatable, Identifiable {
        let id: String
        let used: Int
        let limit: Int
        var remaining: Int { max(0, limit - used) }
        var title: String { id.replacingOccurrences(of: "_", with: " ").capitalized }
    }

    let plan: String
    let month: String
    let counters: [Counter]
    let minimumAppVersion: String?
    let currentPlan: CurrentPlan?
    /// Nil means the backend has not supplied history; [] means no past plans.
    let planHistory: [PastPlan]?
    /// Expiry/renewal read leniently from whatever shape the Worker returns.
    let entitlement: PlanEntitlement?

    init?(_ payload: [String: Any]) {
        guard let plan = payload["plan"] as? String,
              let month = payload["month"] as? String,
              let usage = payload["usage"] as? [String: Any],
              let limits = payload["limits"] as? [String: Any] else { return nil }
        self.plan = plan
        self.month = month
        self.minimumAppVersion = payload["min_app_version"] as? String
        // A subscription block that doesn't match the strict contract must not
        // hide usage; the lenient `entitlement` below still reads its dates.
        currentPlan = payload["subscription"].flatMap { CurrentPlan($0, expectedPlan: plan) }
        if let items = payload["plan_history"] as? [Any] {
            planHistory = items.prefix(100).compactMap(PastPlan.init).sorted { $0.endedAt > $1.endedAt }
        } else {
            planHistory = nil
        }
        entitlement = PlanEntitlement(payload: payload, fallbackPlan: plan)
        counters = limits.keys.sorted().compactMap { key in
            guard let limit = (limits[key] as? NSNumber)?.intValue,
                  let used = (usage[key] as? NSNumber)?.intValue else { return nil }
            return Counter(id: key, used: used, limit: limit)
        }
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, !(value is Bool) {
            let seconds = number.doubleValue
            guard seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let raw = value as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = iso.date(from: value) { return result }
        iso.formatOptions = [.withInternetDateTime]
        if let result = iso.date(from: value) { return result }
        // Postgres text output, e.g. "2026-11-08 10:30:00.123+00" or a plain date.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX", "yyyy-MM-dd HH:mm:ss.SSSSSSX", "yyyy-MM-dd HH:mm:ss.SSSX",
                       "yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ssX", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
                       "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let result = formatter.date(from: value) { return result }
        }
        return nil
    }
}

/// The user's paid-plan dates, wherever they live (Worker `/v1/me` or a
/// Supabase table). Field names are matched loosely so either source works.
struct PlanEntitlement: Equatable {
    static let expiryKeys = ["access_ends_at", "expires_at", "expiry_date", "expiry", "expiration_date",
                             "plan_expires_at", "plan_expiry", "plan_expiry_date", "premium_expires_at",
                             "premium_until", "subscription_expires_at", "current_period_end",
                             "period_end", "valid_until", "valid_till", "ends_at", "end_date", "end_at"]
    static let renewalKeys = ["renews_at", "renewal_date", "next_billing_date", "next_renewal_at"]
    static let startKeys = ["started_at", "start_date", "starts_at", "current_period_start", "purchased_at"]
    static let planKeys = ["plan", "plan_name", "tier", "plan_id", "product", "subscription_plan"]
    static let statusKeys = ["status", "subscription_status", "plan_status"]

    var plan: String?
    var status: String?
    var startedAt: Date?
    var expiresAt: Date?
    var renewsAt: Date?

    var hasDates: Bool { expiresAt != nil || renewsAt != nil }

    /// Reads a row/object; returns nil when it carries no plan dates at all.
    init?(row: [String: Any], fallbackPlan: String? = nil) {
        func first(_ keys: [String]) -> Any? {
            for key in keys {
                if let value = row[key], !(value is NSNull) { return value }
            }
            return nil
        }
        expiresAt = WorkerUsageSnapshot.date(first(Self.expiryKeys))
        renewsAt = WorkerUsageSnapshot.date(first(Self.renewalKeys))
        startedAt = WorkerUsageSnapshot.date(first(Self.startKeys))
        plan = (first(Self.planKeys) as? String) ?? fallbackPlan
        status = first(Self.statusKeys) as? String
        guard hasDates else { return nil }
    }

    /// Checks the Worker payload's `subscription` object first, then top-level keys.
    init?(payload: [String: Any], fallbackPlan: String) {
        for candidate in [payload["subscription"], payload["entitlement"], payload["plan_details"], payload] {
            if let object = candidate as? [String: Any],
               let parsed = PlanEntitlement(row: object, fallbackPlan: fallbackPlan) {
                self = parsed
                return
            }
        }
        return nil
    }

    static func isPremium(plan: String?) -> Bool {
        guard let plan = plan?.trimmingCharacters(in: .whitespaces).lowercased(), !plan.isEmpty else { return false }
        // Alpha is the free tier; Sigma and Omega are paid.
        return !["alpha", "free", "none"].contains(plan)
    }
}

/// A finished streamed answer: its text, the web pages it cited, and why it stopped.
struct ChatStreamResult: Equatable {
    let text: String
    let sources: [WebSearchSource]
    /// "end_turn"/"stop" normally; "length" when it hit the length limit.
    let stopReason: String?
}

/// Reads the Worker's server-sent events one `data:` payload at a time. It
/// keeps the text, collects cited sources (https only, no duplicates), and
/// only accepts the answer if the stream actually said it was finished, so a
/// dropped connection is never shown as a complete answer.
struct ChatStreamCollector {
    private(set) var text = ""
    private(set) var sources: [WebSearchSource] = []
    private(set) var stopReason: String?
    /// The stream sent `[DONE]` or `message_stop`.
    private(set) var sawDone = false
    static let maxSources = 8
    static let lengthNotice = "(This answer reached its length limit and may be incomplete.)"

    /// Returns true when the visible text changed.
    mutating func consume(_ payload: String) throws -> Bool {
        if payload == "[DONE]" { sawDone = true; return false }
        if payload.contains("\"message_stop\"") { sawDone = true }
        for source in ChatStreamParser.sources(from: payload)
        where sources.count < Self.maxSources && !sources.contains(where: { $0.url == source.url }) {
            sources.append(source)
        }
        switch ChatStreamParser.parse(payload) {
        case .text(let delta):
            text += delta
            return true
        case .finished(let reason):
            stopReason = reason ?? "stop"
            return false
        case .error:
            throw WorkerError.server
        default:
            return false
        }
    }

    func result() throws -> ChatStreamResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkerError.invalidResponse }
        // No "finished" signal at all: the connection dropped mid-answer.
        guard stopReason != nil || sawDone else { throw WorkerError.incompleteResponse }
        let shown = stopReason == "length" ? text + "\n\n" + Self.lengthNotice : text
        return ChatStreamResult(text: shown, sources: sources, stopReason: stopReason)
    }
}
