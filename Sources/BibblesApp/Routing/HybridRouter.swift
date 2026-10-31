import AppKit
import ApplicationServices
import Foundation
import Security

// MARK: - Routes and flags

/// Every task Bibbles can route a request to. Raw values are what the AI
/// router returns, so they must match `RouterPrompt`.
enum HybridRoute: String, CaseIterable, Codable {
    case simple, write, edit
    case fixText = "fix_text"
    case fixCode = "fix_code"
    case translate, screen, search, deep, command
    case formFill = "form_fill"
    case fileAction = "file_action"
    #if BIBBLES_DEVELOPER
    /// The Files agent (developer builds, only with "AI Agents (Files)" on).
    case agentFiles = "agent_files"
    /// The Screen agent (developer builds, only with "AI Agents (Screen)" on).
    case agentScreen = "agent_screen"
    #endif
    case unclear
}

/// What the router may know besides the user's words. Only booleans and the
/// front app's NAME: never selected text, file contents or screenshots.
struct RouterFlags: Equatable {
    var hasSelectedText = false
    var selectionLooksLikeCode = false
    var recentBibblesWriting = false
    var textFieldFocused = false
    var frontmostApp: String?
    var filesAttached = false
    var screenHotkeyUsed = false

    /// Compact JSON for the router prompt (stable key order).
    var json: String {
        let fields: [String: Any] = [
            "hasSelectedText": hasSelectedText, "selectionLooksLikeCode": selectionLooksLikeCode,
            "recentBibblesWriting": recentBibblesWriting, "textFieldFocused": textFieldFocused,
            "frontmostApp": String((frontmostApp ?? "unknown").prefix(40)),
            "filesAttached": filesAttached, "screenHotkeyUsed": screenHotkeyUsed
        ]
        // App names can contain quotes, backslashes and control characters.
        // Let the serializer escape them rather than assembling JSON by hand.
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

/// The router's answer.
struct RouterResult: Equatable {
    let route: HybridRoute
    let confidence: Double
    /// How hard a deep task should think (Local mode routers only; nil = not given or unsure).
    var effort: DeepEffort? = nil
}

/// The thinking level for deep tasks, chosen per request by the router (Local
/// mode). Only "low" and "medium"; anything unsure stays "medium". Used only by
/// deep requests: light tasks, agents and the router ignore it.
enum DeepEffort: String, CaseIterable {
    case low, medium

    private static let lock = NSLock()
    private static var stored = DeepEffort.medium

    /// The level for the next deep request. Every new request resets it first.
    static var current: DeepEffort {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    /// The router's level is used only when the router was sure enough of it.
    static func from(_ name: String?, probability: Double = 1) -> DeepEffort? {
        guard let name, let effort = DeepEffort(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased()),
              probability >= HybridRouter.acceptThreshold else { return nil }
        return effort
    }
}

/// Where the final route came from (developer log).
enum RouteSource: String {
    /// Today's keyword rules decided; nothing changed.
    case keyword
    /// The new "intent anywhere" clause rules decided.
    case keywordClause = "keyword-clause"
    /// The AI router decided.
    case router
    /// Unclear, and the router was skipped, failed, timed out or unsure:
    /// today's behaviour.
    case fallback
}

/// One routing decision, for dispatch and the developer log. Never holds
/// the user's words.
struct RoutingDecision: Equatable {
    var source: RouteSource
    /// nil = keep today's intent exactly.
    var override: HybridRoute?
    var keywordStrength: IntentRouter.Strength
    var routerRoute: HybridRoute?
    var routerConfidence: Double?
    /// The router's deep-task effort (Local mode), nil when not given or unsure.
    var routerEffort: DeepEffort?
    var routerMilliseconds: Int?
    var jsonParsed: Bool?
    /// Developer-only reason, never the user's words.
    var reason: String
    var decisionMilliseconds = 0
}

// MARK: - Hybrid router

/// Hybrid routing: keywords first, Claude Haiku only for
/// requests the keywords can't decide. On by default; when off, Bibbles
/// takes exactly today's code path.
enum HybridRouter {
    static let enabledKey = "bibbles.aiRouterEnabled"
    static let model = "claude-haiku-4-5-20251001"
    #if BIBBLES_DEVELOPER
    /// Developer builds only: Haiku called directly with the developer's key.
    static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let modelsURL = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
    #endif
    /// The router's answer is used only at or above this confidence.
    static let acceptThreshold = 0.75
    /// Live requests wait at most this long for the router.
    static let liveTimeout: TimeInterval = 1.0
    /// Through the Bibbles server there is one more hop, so a little longer.
    static let serverTimeout: TimeInterval = 1.5
    #if BIBBLES_DEVELOPER
    /// While an agent is on, the router decides every request.
    static let agentsTimeout: TimeInterval = 2.5
    /// Router through OpenRouter (Jev Router, Local mode only).
    static let openRouterTimeout: TimeInterval = 8
    static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    static let decisionsURL = URL(string: "https://openrouter.ai/api/alpha/decisions")!

    /// Jev (OpenRouter's Decisions API): one Choice question whose options are the
    /// routes, described exactly as in the router prompt (agent routes included when on).
    static func decisionsBody(model: String, text: String, flags: RouterFlags) -> [String: Any] {
        let prompt = RouterPrompt.system
        var routes: [String: String] = [:]
        var rules: [String] = []
        for line in prompt.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") { rules.append(String(trimmed.dropFirst(2))); continue }
            guard let colon = trimmed.firstIndex(of: ":"),
                  let route = HybridRoute(rawValue: String(trimmed[..<colon])) else { continue }
            routes[route.rawValue] = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let flagFacts: Any = flags.json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            ?? ([:] as [String: Any])
        return [
            "model": model,
            "state": ["request": String(text.prefix(4_000)), "mac": flagFacts] as [String: Any],
            "questions": [
                // Asked in the same call; Jev answers each question on its own.
                "effort": [
                    "type": "choice",
                    "instructions": "If this request needs a careful written answer, how much thinking does it need? "
                        + "Pick low only when the answer is clearly simple.",
                    "criteria": [
                        "low": "Simple: describe or explain what is visible on screen, a definition, a short fact, a summary, "
                            + "a straightforward explanation or rewrite.",
                        "medium": "Needs careful reasoning: multi-step maths or logic, debugging code, comparisons, analysis, "
                            + "planning, or anything where a mistake is likely without thinking."
                    ]
                ] as [String: Any],
                "route": [
                    "type": "choice",
                    "instructions": "Bibbles is a voice and text assistant for Mac. Which single task does the user want Bibbles to do NOW? "
                        + "The request is often transcribed speech, in any language, and the real request is often at the end. "
                        + "`mac` holds true/false facts about the user's Mac. Rules: " + rules.joined(separator: " "),
                    "criteria": routes
                ] as [String: Any]
            ]
        ]
    }

    /// Jev's answer: the chosen route and its probability (not Jev's "confidence",
    /// which measures how spread out all the options are).
    static func parseDecision(_ data: Data) -> RouterResult? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let answer = (object["answers"] as? [String: Any])?["route"] as? [String: Any],
              let name = answer["choice"] as? String,
              let route = HybridRoute(rawValue: name) else { return nil }
        let probability = ((answer["probabilities"] as? [String: Any])?[name] as? NSNumber)?.doubleValue
            ?? (answer["confidence"] as? NSNumber)?.doubleValue ?? 0
        guard probability.isFinite else { return nil }
        let answers = object["answers"] as? [String: Any]
        let effortAnswer = answers?["effort"] as? [String: Any]
        let effortName = effortAnswer?["choice"] as? String
        let effortProbability = effortName.flatMap { ((effortAnswer?["probabilities"] as? [String: Any])?[$0] as? NSNumber)?.doubleValue }
            ?? (effortAnswer?["confidence"] as? NSNumber)?.doubleValue ?? 0
        return RouterResult(route: route, confidence: min(1, max(0, probability)),
                            effort: DeepEffort.from(effortName, probability: effortProbability))
    }

    /// OpenRouter's chat format: no pre-filled answer, so the JSON is asked for instead.
    static func openRouterBody(model: String, text: String, flags: RouterFlags) -> [String: Any] {
        [
            "model": model,
            // Room for a model that thinks first; the answer itself is tiny.
            "max_tokens": 1_000,
            "messages": [
                ["role": "system", "content": RouterPrompt.system
                    + "\nReply with the JSON object only: {\"route\":\"…\",\"confidence\":0.0-1.0}."],
                ["role": "user", "content": RouterPrompt.userMessage(text: text, flags: flags)]
            ],
            "response_format": ["type": "json_object"],
            "usage": ["include": true]
        ]
    }
    #endif

    /// Developer toggle, default ON.
    static var isEnabled: Bool {
        // Always on for everyone (no longer a setting).
        get { true }
        set { UserDefaults.standard.removeObject(forKey: enabledKey) }
    }

    /// The hybrid path runs only with both the router toggle and the Tool Gate on.
    static var isActive: Bool { isEnabled && ToolGate.isEnabled }

    static let keywordImprovementsKey = "bibbles.keywordImprovementsEnabled"

    /// Developer toggle, default OFF: clause splitting ("intent anywhere"),
    /// filler removal and negation checks in the keyword pass. Compare
    /// old keywords / new keywords / new keywords + router.
    static var keywordImprovementsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: keywordImprovementsKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: keywordImprovementsKey) }
    }

    /// Whether requests take the hybrid path at all (either developer toggle on).
    static var pathActive: Bool { ToolGate.isEnabled && (isEnabled || keywordImprovementsEnabled) }

    // MARK: Keyword pass

    enum KeywordVerdict: Equatable {
        /// Keywords are confident: keep today's intent.
        case keep(IntentRouter.Strength)
        /// The new clause rules found one clear task.
        case clause(HybridRoute)
        /// A Tool Gate keyword route that today's dispatch would miss.
        case gate(HybridRoute)
        /// Ask the router.
        case unclear(String)
    }

    /// The first pass: instant, free, offline. Uses a filler-free copy of the
    /// text for decisions only.
    static func keywordVerdict(for text: String, flags: RouterFlags,
                               intentRouter: IntentRouter = IntentRouter(),
                               improvements: Bool = keywordImprovementsEnabled) -> KeywordVerdict {
        let decision = intentRouter.decide(transcript: text, mode: .command)
        if decision.intent == .dictate { return .keep(.strong) }
        // Without the improvements: raw text, no clauses, no filler removal.
        let words = improvements ? RoutingText.wordCount(text) : text.split(whereSeparator: { $0.isWhitespace }).count
        let clauses = improvements ? clauseRoutes(for: text, flags: flags, intentRouter: intentRouter) : []
        let today = baselineRoute(for: text, flags: flags, intentRouter: intentRouter)
        #if BIBBLES_DEVELOPER
        // With an agent on, the AI router decides every request (however it is
        // phrased). Keywords keep only the trivial ones: the time and date,
        // and greetings.
        if AgentSettings.filesEnabled || AgentSettings.screenEnabled {
            let gate = ToolGate.classify(text)
            if gate.route == .localAnswer { return .keep(decision.strength) }
            if gate.route == .simple, gate.reason == "greeting" { return .keep(.none) }
            return .unclear("agents on: router decides")
        }
        #endif

        switch decision.strength {
        case .strong:
            // "Ich schreibe heute keine Mails": a matched task word that is negated.
            if improvements, [.write, .command, .fixText, .fixCode, .formFill, .fileAction].contains(today),
               RoutingText.isNegated(RoutingText.stripFillers(text)) {
                return .unclear("negated keyword")
            }
            // Short requests, or long ones whose clauses agree: trust today's rule.
            if clauses.isEmpty || clauses == [today] || words <= 12 { return .keep(.strong) }
            return .unclear("clause disagrees with keyword")
        case .weak, .none:
            if clauses.count == 1, let only = clauses.first { return .clause(only) }
            if clauses.count > 1 { return .unclear("conflicting clauses") }
            // Short screen-word requests ("what is this?") are reliable;
            // short search hints from keyword tables are checked by the router.
            if decision.strength == .weak, words <= 8, today == .screen { return .keep(.weak) }
            let stripped = improvements ? RoutingText.stripFillers(text) : text
            let gate = ToolGate.classify(stripped, context: ToolGate.Context(
                hasSelection: flags.hasSelectedText, hasRecentWriting: flags.recentBibblesWriting))
            switch gate.route {
            case .localAnswer:
                return .keep(decision.strength)
            case .simple where gate.reason == "greeting" && decision.strength == .none:
                // "hi", "thanks": nothing to route.
                return .keep(.none)
            case .deep:
                // Structural signals (long code, stack traces, maths), not words.
                // Today's chat already answers these on the deep tier.
                return improvements ? .gate(.deep) : .keep(decision.strength)
            case .edit where flags.recentBibblesWriting && improvements:
                return .gate(.edit)
            default:
                // Short questions, keyword-only hints and everything else: the
                // router decides (accuracy first).
                return .unclear(gate.reason)
            }
        }
    }

    /// "Intent anywhere": today's anchored rules applied to every clause of
    /// the request, after fillers are removed. Negated clauses ("I can't
    /// write today") never count.
    static func clauseRoutes(for text: String, flags: RouterFlags,
                             intentRouter: IntentRouter = IntentRouter()) -> Set<HybridRoute> {
        var routes: Set<HybridRoute> = []
        for clause in RoutingText.clauses(text) where !RoutingText.isNegated(clause) {
            if let route = clauseRoute(clause, flags: flags, intentRouter: intentRouter) { routes.insert(route) }
        }
        // A fix of code and of text in the same request is one task.
        if routes.contains(.fixCode) { routes.remove(.fixText) }
        return routes
    }

    static func clauseRoute(_ clause: String, flags: RouterFlags, intentRouter: IntentRouter) -> HybridRoute? {
        let language = ToolGate.detectLanguage(clause)
        let padded = ToolGateText.padded(clause)
        if (EditRequest.isEdit(clause) || ToolGate.isEditRequest(clause, folded: padded, language: language)),
           flags.recentBibblesWriting || flags.hasSelectedText {
            return .edit
        }
        if intentRouter.isFixRequest(clause) {
            return flags.selectionLooksLikeCode || mentionsCode(clause) ? .fixCode : .fixText
        }
        if startsWithTranslate(clause) { return .translate }
        if intentRouter.isFileRequest(clause) { return .fileAction }
        if intentRouter.isCommandRequest(clause) { return .command }
        if intentRouter.isFillRequest(clause) { return .formFill }
        if intentRouter.isWriteRequest(clause) { return .write }
        if IntentRouter.isLocateRequest(clause), !IntentRouter.isMacWideSearch(clause) { return .screen }
        let lowered = clause.lowercased()
        if ["search the web for ", "search online for ", "look up ", "google ", "web search "].contains(where: lowered.hasPrefix) {
            return .search
        }
        return nil
    }

    static func mentionsCode(_ text: String) -> Bool {
        text.lowercased().range(of: #"\b(?:code|bug|crash(?:es|ing)?|compile|function|script|error|exception|stack ?trace|build)\b"#,
                                options: .regularExpression) != nil
    }

    static func startsWithTranslate(_ clause: String) -> Bool {
        let folded = ToolGateText.fold(clause)
        let prefixes = ["translate", "can you translate", "please translate", "traduce", "traduceme", "traducir",
                        "ubersetz", "uebersetz", "traduis", "traduire", "traduza", "traduz", "traduci", "tradurre",
                        "vertaal", "anuvad", "translate karo"]
        if prefixes.contains(where: folded.hasPrefix) { return true }
        return ["翻訳して", "訳して", "अनुवाद कर"].contains(where: clause.contains)
    }

    /// Today's keyword behaviour as a route, including the always-on "here"
    /// fix (old keywords in the developer comparison).
    static func baselineRoute(for text: String, flags: RouterFlags, intentRouter: IntentRouter) -> HybridRoute {
        let decided = intentRouter.decide(transcript: text, mode: .command)
        if IntentRouter.hereScreenCorrection(for: text, decided: decided, textFieldFocused: flags.textFieldFocused) != nil {
            return IntentRouter.clearlyAsksToWrite(text) ? .write : route(for: .chat(message: text), text: text,
                                                                         flags: flags, intentRouter: intentRouter)
        }
        return route(for: decided.intent, text: text, flags: flags, intentRouter: intentRouter)
    }

    /// Today's intent expressed as a route (to compare with clause routes).
    static func route(for intent: BibblesIntent, text: String, flags: RouterFlags,
                      intentRouter: IntentRouter) -> HybridRoute {
        // Today's dispatch checks edits of recent writing before anything else.
        if intent != .dictate, !intentRouter.isCommandRequest(text), EditRequest.isEdit(text),
           flags.recentBibblesWriting || EditRequest.namesText(text) || intentRouter.shouldUseFocusedText(for: text) {
            return .edit
        }
        switch intent {
        case .dictate: return .unclear
        case .screen: return .screen
        case .search: return .search
        case .chat:
            if intentRouter.isFileRequest(text) { return .fileAction }
            if intentRouter.isCommandRequest(text) { return .command }
            if intentRouter.isFixRequest(text) { return flags.selectionLooksLikeCode || mentionsCode(text) ? .fixCode : .fixText }
            if intentRouter.isWriteRequest(text) { return .write }
            if intentRouter.isFillRequest(text) { return .formFill }
            if intentRouter.shouldUseFocusedText(for: text) { return startsWithTranslate(text) ? .translate : .simple }
            return .simple
        }
    }

    // MARK: Full decision

    /// Keywords first; the router only when they can't decide. Never throws:
    /// any problem keeps today's behaviour.
    static func decide(text: String, flags: RouterFlags, intentRouter: IntentRouter = IntentRouter(),
                       client: RouterClient? = nil, timeout: TimeInterval = liveTimeout,
                       useRouter: Bool = true,
                       improvements: Bool = keywordImprovementsEnabled) async -> RoutingDecision {
        let started = Date()
        var timeout = timeout
        #if BIBBLES_DEVELOPER
        // Every request depends on the router while an agent is on: give it time.
        if AgentSettings.filesEnabled || AgentSettings.screenEnabled { timeout = max(timeout, agentsTimeout) }
        #endif
        let strength = intentRouter.decide(transcript: text, mode: .command).strength
        var decision: RoutingDecision
        switch keywordVerdict(for: text, flags: flags, intentRouter: intentRouter, improvements: improvements) {
        case .keep(let kept):
            decision = RoutingDecision(source: .keyword, override: nil, keywordStrength: kept, reason: "keywords confident")
        case .clause(let route):
            decision = RoutingDecision(source: .keywordClause, override: route, keywordStrength: strength, reason: "one clause task")
        case .gate(let route):
            decision = RoutingDecision(source: .keyword, override: route, keywordStrength: strength, reason: "tool gate keyword")
        case .unclear(let why):
            decision = RoutingDecision(source: .fallback, override: nil, keywordStrength: strength, reason: why)
            if !useRouter {
                decision.reason = "router off"
            } else if let client = await RouterClient.resolve(client) {
                let base = client.viaServer ? max(timeout, serverTimeout) : timeout
                #if BIBBLES_DEVELOPER
                // Jev Router passes the request on to the model it picks: give it longer.
                // (Jev itself decides directly and keeps the normal limit.)
                let limit = client.openRouterModel != nil && !client.usesDecisionsAPI ? max(base, openRouterTimeout) : base
                #else
                let limit = base
                #endif
                let outcome = await client.classify(text: text, flags: flags, timeout: limit)
                decision.routerMilliseconds = outcome.milliseconds
                decision.jsonParsed = outcome.jsonParsed
                decision.routerRoute = outcome.result?.route
                decision.routerConfidence = outcome.result?.confidence
                decision.routerEffort = outcome.result?.effort
                if let accepted = accept(outcome.result) {
                    decision.source = .router
                    decision.override = accepted
                    decision.reason = "router"
                } else {
                    decision.reason = outcome.failure ?? "router unsure"
                }
            } else {
                decision.reason = "no router key"
            }
        }
        decision.decisionMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
        return decision
    }

    /// The router's route, or nil when it isn't confident enough.
    static func accept(_ result: RouterResult?) -> HybridRoute? {
        guard let result, result.route != .unclear, result.confidence.isFinite,
              (acceptThreshold...1).contains(result.confidence) else { return nil }
        #if BIBBLES_DEVELOPER
        // The Files agent route exists only while its developer toggle is on.
        if result.route == .agentFiles, !AgentSettings.filesEnabled { return nil }
        if result.route == .agentScreen, !AgentSettings.screenEnabled { return nil }
        #endif
        return result.route
    }

    // MARK: Parsing

    /// Forgiving: accepts clean JSON, fenced JSON, JSON inside other text, or
    /// the continuation of the `{"route":"` prefill.
    static func parse(_ raw: String) -> RouterResult? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The request pre-fills `{"route":"`; the reply continues from there.
        if !text.contains("{"), !text.hasPrefix("```") { text = "{\"route\":\"" + text }
        let json = ClaudeAPI.jsonObjectText(text)
        if let data = json.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let routeName = object["route"] as? String,
           let route = HybridRoute(rawValue: routeName.trimmingCharacters(in: .whitespaces).lowercased()) {
            // JSON booleans bridge to NSNumber too; true is not confidence 1.
            if let number = object["confidence"] as? NSNumber,
               CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let confidence = (object["confidence"] as? NSNumber)?.doubleValue
                ?? Double(object["confidence"] as? String ?? "") ?? 0
            guard confidence.isFinite else { return nil }
            return RouterResult(route: route, confidence: min(1, max(0, confidence)),
                                effort: DeepEffort.from(object["effort"] as? String))
        }
        // Last resort: pull both fields out with patterns (broken JSON).
        guard let routeMatch = text.range(of: #"(?i)"?route"?\s*[:=]\s*"?([a-z_]+)"#, options: .regularExpression) else { return nil }
        let routeText = String(text[routeMatch]).replacingOccurrences(of: #"(?i)"?route"?\s*[:=]\s*"?"#, with: "", options: .regularExpression)
        guard let route = HybridRoute(rawValue: routeText.lowercased()) else { return nil }
        var confidence = 0.0
        if let match = text.range(of: #"(?i)confidence"?\s*[:=]\s*([0-9.]+)"#, options: .regularExpression) {
            let number = String(text[match]).replacingOccurrences(of: #"(?i)confidence"?\s*[:=]\s*"#, with: "", options: .regularExpression)
            confidence = Double(number) ?? 0
        }
        return RouterResult(route: route, confidence: min(1, max(0, confidence)))
    }

    // MARK: Request

    /// The exact body sent to the router: the user's words unchanged plus
    /// flags. No images, files or selected text, ever.
    static func requestBody(text: String, flags: RouterFlags) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 40,
            "temperature": 0,
            "system": [["type": "text", "text": RouterPrompt.system, "cache_control": ["type": "ephemeral"]]],
            "messages": [
                ["role": "user", "content": RouterPrompt.userMessage(text: text, flags: flags)],
                ["role": "assistant", "content": "{\"route\":\""]
            ]
        ]
    }
}

// MARK: - Router client

/// Sends one request to Anthropic. Injectable for tests.
protocol RouterTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionRouterTransport: RouterTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await Self.session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

struct RouterOutcome: Equatable {
    var result: RouterResult?
    var milliseconds: Int
    var jsonParsed: Bool
    /// Developer-only failure label ("timeout", "offline", "http 401"…).
    var failure: String?
}

struct RouterClient {
    var transport: RouterTransport = URLSessionRouterTransport()
    /// Set: the request goes to the Bibbles server's /v1/route with the
    /// user's sign-in token, and the server calls Haiku with its own key.
    var serverToken: String?
    #if BIBBLES_DEVELOPER
    /// Developer builds only: the developer's own Anthropic key (empty when
    /// the request goes to the server).
    var key = ""
    /// Local mode with an OpenRouter router model (Jev or Jev Router): `key` is the OpenRouter key.
    var openRouterModel: String?
    /// Jev itself: OpenRouter's Decisions API (Jev picks the route, no other model involved).
    var usesDecisionsAPI: Bool { openRouterModel.map { $0.hasPrefix("typesafe/jev-1") || $0 == "~typesafe/jev-latest" } ?? false }
    #endif

    /// Customer builds always go through the Bibbles server.
    init(serverToken: String, transport: RouterTransport = URLSessionRouterTransport()) {
        self.serverToken = serverToken
        self.transport = transport
    }

    #if BIBBLES_DEVELOPER
    init(key: String, transport: RouterTransport = URLSessionRouterTransport()) {
        self.key = key
        self.serverToken = nil
        self.transport = transport
    }
    #endif

    var viaServer: Bool { serverToken != nil }

    /// Self-test only: never call the server.
    static var serverAllowed = true

    #if BIBBLES_DEVELOPER
    /// The developer's own Anthropic key (Settings → Developer → API keys);
    /// nil without one.
    static func developer() -> RouterClient? {
        // Local mode with Jev or Jev Router picked (Settings → Developer → Models): the OpenRouter key.
        let choice = ModelCatalog.selected(.router)
        if LocalMode.isOn, choice.provider == .openrouter {
            guard let key = DeveloperKeychain.read(.openrouter), !key.isEmpty else { return nil }
            var client = RouterClient(key: key)
            client.openRouterModel = choice.id
            return client
        }
        guard let key = DeveloperKeychain.read(.anthropic), !key.isEmpty else { return nil }
        return RouterClient(key: key)
    }
    #endif

    /// Developer builds: the developer key when one is saved. Otherwise the
    /// current backend: the Bibbles server for any signed-in user (Local
    /// mode never contacts it). nil (not signed in, no key) means "skip the
    /// router".
    static func live() async -> RouterClient? {
        #if BIBBLES_DEVELOPER
        if let developer = developer() { return developer }
        #endif
        return await Backends.current.routerClient()
    }

    static func resolve(_ given: RouterClient?) async -> RouterClient? {
        if let given { return given }
        return await live()
    }

    func urlRequest(text: String, flags: RouterFlags) throws -> URLRequest {
        #if BIBBLES_DEVELOPER
        if serverToken == nil, let model = openRouterModel {
            var request = URLRequest(url: usesDecisionsAPI ? HybridRouter.decisionsURL : HybridRouter.openRouterURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer " + key, forHTTPHeaderField: "authorization")
            let body = usesDecisionsAPI ? HybridRouter.decisionsBody(model: model, text: text, flags: flags)
                : HybridRouter.openRouterBody(model: model, text: text, flags: flags)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }
        #endif
        let body = try JSONSerialization.data(withJSONObject: HybridRouter.requestBody(text: text, flags: flags))
        #if BIBBLES_DEVELOPER
        if serverToken == nil {
            var request = URLRequest(url: HybridRouter.messagesURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = body
            return request
        }
        #endif
        var request = WorkerAPI.request(path: "v1/route", method: "POST", contentType: "application/json",
                                        body: body, token: serverToken ?? "")
        request.timeoutInterval = 10
        return request
    }

    /// One classification, raced against `timeout`.
    func classify(text: String, flags: RouterFlags, timeout: TimeInterval) async -> RouterOutcome {
        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        guard let request = try? urlRequest(text: text, flags: flags) else {
            return RouterOutcome(result: nil, milliseconds: 0, jsonParsed: false, failure: "request")
        }
        let transport = self.transport
        do {
            let (data, status) = try await withThrowingTaskGroup(of: (Data, Int).self) { group in
                group.addTask { try await transport.send(request) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw RouterError.timeout
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw RouterError.timeout }
                return first
            }
            guard (200..<300).contains(status) else {
                return RouterOutcome(result: nil, milliseconds: elapsed(), jsonParsed: false, failure: "http \(status)")
            }
            #if BIBBLES_DEVELOPER
            // Cost log: which model Jev Router picked, and what it cost.
            if let model = openRouterModel {
                LocalCostLog.shared.recordRouter(model: model, reply: data, milliseconds: elapsed())
            } else if serverToken == nil {
                // Haiku with the developer's Anthropic key: logged too (log only, nothing else changes).
                LocalCostLog.shared.recordAnthropicRouter(model: HybridRouter.model, reply: data, milliseconds: elapsed())
            }
            #endif
            #if BIBBLES_DEVELOPER
            let decided = usesDecisionsAPI ? HybridRouter.parseDecision(data)
                : ClaudeAPI.responseText(from: data).flatMap(HybridRouter.parse)
            #else
            let decided = ClaudeAPI.responseText(from: data).flatMap(HybridRouter.parse)
            #endif
            guard let result = decided else {
                return RouterOutcome(result: nil, milliseconds: elapsed(), jsonParsed: false, failure: "json")
            }
            return RouterOutcome(result: result, milliseconds: elapsed(), jsonParsed: true, failure: nil)
        } catch RouterError.timeout {
            return RouterOutcome(result: nil, milliseconds: elapsed(), jsonParsed: false, failure: "timeout")
        } catch {
            let offline = (error as? URLError).map { [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                                       .cannotConnectToHost, .dnsLookupFailed].contains($0.code) } ?? false
            return RouterOutcome(result: nil, milliseconds: elapsed(), jsonParsed: false,
                                 failure: offline ? "offline" : "network")
        }
    }

    #if BIBBLES_DEVELOPER
    /// Opens the connection early (free endpoint) so the first real request
    /// doesn't pay for the TLS handshake.
    func warmUp() async {
        // OpenRouter: no free endpoint worth calling; the first request opens the connection.
        guard openRouterModel == nil else { return }
        var request = URLRequest(url: HybridRouter.modelsURL)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        _ = try? await transport.send(request)
    }
    #endif
}

enum RouterError: Error { case timeout }

#if BIBBLES_DEVELOPER
/// Keeps the connection warm while the router is in use, at most once a minute.
@MainActor
enum RouterWarmUp {
    private static var last = Date.distantPast
    static func ifNeeded() {
        guard HybridRouter.isActive, Date().timeIntervalSince(last) > 60, let client = RouterClient.developer() else { return }
        last = Date()
        Task.detached(priority: .utility) { await client.warmUp() }
    }
}
#endif

// MARK: - Context flags (Accessibility only, no text leaves the Mac)

@MainActor
enum RouterFlagsProbe {
    /// Reads booleans about the user's app. The selected text is looked at
    /// locally (to tell code from prose) and immediately discarded.
    /// Only whether a text box has the keyboard (Accessibility, no text read).
    static func textFieldFocused(app: NSRunningApplication?) -> Bool {
        guard let app, !app.isTerminated, AXIsProcessTrusted() else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return false }
        let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleValue)
        var settable = DarwinBoolean(false)
        let canTakeText = AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success
            && settable.boolValue
        return canTakeText || ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(roleValue as? String ?? "")
    }

    static func flags(app: NSRunningApplication?, filesAttached: Bool = false,
                      screenHotkeyUsed: Bool = false) -> RouterFlags {
        var flags = RouterFlags()
        flags.frontmostApp = app?.localizedName
        flags.filesAttached = filesAttached
        flags.screenHotkeyUsed = screenHotkeyUsed
        flags.recentBibblesWriting = WorkMemory.shared.latest(preferring: app) != nil
        guard let app, !app.isTerminated, AXIsProcessTrusted() else { return flags }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return flags }
        let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        var settable = DarwinBoolean(false)
        let canTakeText = AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success
            && settable.boolValue
        flags.textFieldFocused = canTakeText
            || ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
        var selectedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selectedValue) == .success,
           let selected = selectedValue as? String {
            let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
            flags.hasSelectedText = !trimmed.isEmpty
            flags.selectionLooksLikeCode = !trimmed.isEmpty && ClaudeFixer.looksLikeCode(String(trimmed.prefix(6_000)))
        }
        return flags
    }
}
