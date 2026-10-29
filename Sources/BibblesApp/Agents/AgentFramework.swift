#if BIBBLES_DEVELOPER
import Foundation

// The reusable agent pipeline (developer builds only):
// scan → summarize → plan → apply + validate → preview → execute → undo → summary.
// AI is used for exactly one step, the plan. Everything else is local code.

/// Developer toggle "AI Agents (Files)", default OFF. OFF = today's behaviour everywhere.
enum AgentSettings {
    static let filesKey = "bibbles.dev.agents.files"
    /// Tests only.
    static var testOverride: Bool?

    static var filesEnabled: Bool {
        get { testOverride ?? UserDefaults.standard.bool(forKey: filesKey) }
        set { UserDefaults.standard.set(newValue, forKey: filesKey) }
    }

    static let screenKey = "bibbles.dev.agents.screen"
    /// Tests only.
    static var screenTestOverride: Bool?

    /// "AI Agents (Screen)", default OFF.
    static var screenEnabled: Bool {
        get { screenTestOverride ?? UserDefaults.standard.bool(forKey: screenKey) }
        set { UserDefaults.standard.set(newValue, forKey: screenKey) }
    }
}

/// What the user asked, in their own words and language.
struct AgentRequest: Equatable {
    let text: String
    let language: ToolGate.DetectedLanguage
    let date: Date

    init(text: String, date: Date = Date()) {
        self.text = text
        self.language = ToolGate.detectLanguage(text)
        self.date = date
    }
}

enum AgentError: LocalizedError, Equatable {
    /// Agents use the developer's keys for now (server mode comes later).
    case needsLocalMode
    case planFailed(String)
    case tooBig(String)
    case permission(String)
    case folder(String)

    var errorDescription: String? {
        switch self {
        case .needsLocalMode:
            return "Agents run in Local mode for now. Turn on Local mode in Settings → Developer."
        case .planFailed(let detail): return "Bibbles couldn't make a plan for that (\(detail)). Nothing was changed."
        case .tooBig(let message), .permission(let message), .folder(let message): return message
        }
    }
}

// MARK: - Plan (rules, not file lists)

enum AgentAction: String, CaseIterable {
    case createFolder, move, rename, trash
}

/// Which files a step applies to. Every field that is set must match.
struct AgentMatch: Equatable {
    var ext: [String] = []
    var kind: [String] = []
    var nameStarts: String?
    var nameContains: String?
    var olderThanDays: Int?
    var newerThanDays: Int?
    var minSize: Int64?
    var maxSize: Int64?

    static let fields = ["ext", "kind", "name_starts", "name_contains", "older_than_days", "newer_than_days",
                         "min_size", "max_size"]

    var isEmpty: Bool {
        ext.isEmpty && kind.isEmpty && nameStarts == nil && nameContains == nil && olderThanDays == nil
            && newerThanDays == nil && minSize == nil && maxSize == nil
    }
}

struct AgentStep: Equatable {
    var action: AgentAction
    /// createFolder: the folder to make.
    var path: String?
    var match = AgentMatch()
    /// move: the destination folder; rename: the new name. May contain
    /// {year} {month} {day} {ext} {kind}, and for rename {name} {n}.
    var to: String?
}

/// The planner's answer.
struct AgentRulePlan: Equatable {
    var summary: String
    var steps: [AgentStep]
}

/// A step that was not used, and why (shown to the user).
struct AgentDroppedStep: Equatable {
    let index: Int
    let reason: String
}

struct AgentParseResult: Equatable {
    var plan: AgentRulePlan?
    var dropped: [AgentDroppedStep] = []
    var error: String?

    var isValid: Bool { plan != nil && error == nil }
}

/// Strict JSON plan format, plus a forgiving parser (clean, fenced,
/// prose-wrapped, or the continuation of a `{` prefill).
enum AgentPlanParser {
    static let maxSteps = 20

    /// JSON schema for providers that support structured output.
    static var schema: [String: Any] {
        let match: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "ext": ["type": "array", "items": ["type": "string"]],
                "kind": ["type": "array", "items": ["type": "string"]],
                "name_starts": ["type": "string"],
                "name_contains": ["type": "string"],
                "older_than_days": ["type": "integer", "minimum": 0],
                "newer_than_days": ["type": "integer", "minimum": 0],
                "min_size": ["type": "integer", "minimum": 0],
                "max_size": ["type": "integer", "minimum": 0]
            ]
        ]
        let step: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["action"],
            "properties": [
                "action": ["type": "string", "enum": AgentAction.allCases.map(\.rawValue)],
                "path": ["type": "string"],
                "match": match,
                "to": ["type": "string"]
            ]
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["summary", "steps"],
            "properties": [
                "summary": ["type": "string"],
                "steps": ["type": "array", "maxItems": maxSteps, "items": step]
            ]
        ]
    }

    static func parse(_ raw: String) -> AgentParseResult {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The continuation of a `{` prefill.
        if !text.hasPrefix("{"), !text.hasPrefix("```"), text.hasPrefix("\"") { text = "{" + text }
        let json = ClaudeAPI.jsonObjectText(text)
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return AgentParseResult(error: "not JSON")
        }
        guard let rawSteps = object["steps"] as? [Any] else { return AgentParseResult(error: "no steps") }
        guard rawSteps.count <= maxSteps else { return AgentParseResult(error: "more than \(maxSteps) steps") }
        var steps: [AgentStep] = []
        var dropped: [AgentDroppedStep] = []
        for (index, value) in rawSteps.enumerated() {
            guard let stepObject = value as? [String: Any] else {
                dropped.append(AgentDroppedStep(index: index, reason: "not a step"))
                continue
            }
            switch step(from: stepObject) {
            case .success(let step): steps.append(step)
            case .failure(let problem): dropped.append(AgentDroppedStep(index: index, reason: problem.reason))
            }
        }
        let summary = (object["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentParseResult(plan: AgentRulePlan(summary: String(summary.prefix(300)), steps: steps), dropped: dropped)
    }

    struct StepProblem: Error, Equatable { let reason: String }

    static func step(from object: [String: Any]) -> Result<AgentStep, StepProblem> {
        func fail(_ reason: String) -> Result<AgentStep, StepProblem> { .failure(StepProblem(reason: reason)) }
        let name = (object["action"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        // Only these four actions exist; anything else ("delete", "run"…) is rejected.
        guard let action = AgentAction(rawValue: name) else {
            return fail(name.isEmpty ? "no action" : "action “\(String(name.prefix(30)))” is not allowed")
        }
        var step = AgentStep(action: action)
        step.path = (object["path"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }
        step.to = (object["to"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }
        if let rawMatch = object["match"] {
            guard let matchObject = rawMatch as? [String: Any] else { return fail("match is not an object") }
            if let unknown = matchObject.keys.first(where: { !AgentMatch.fields.contains($0) }) {
                // An ignored field could make the rule match far more files than meant.
                return fail("unknown match field “\(String(unknown.prefix(30)))”")
            }
            step.match.ext = strings(matchObject["ext"]).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
                .filter { !$0.isEmpty }
            step.match.kind = strings(matchObject["kind"]).map { $0.lowercased() }
            step.match.nameStarts = nonEmpty(matchObject["name_starts"])
            step.match.nameContains = nonEmpty(matchObject["name_contains"])
            step.match.olderThanDays = number(matchObject["older_than_days"]).map { Int($0) }
            step.match.newerThanDays = number(matchObject["newer_than_days"]).map { Int($0) }
            step.match.minSize = size(matchObject["min_size"])
            step.match.maxSize = size(matchObject["max_size"])
            if [step.match.olderThanDays, step.match.newerThanDays].contains(where: { ($0 ?? 0) < 0 }) {
                return fail("negative days")
            }
        }
        switch action {
        case .createFolder:
            guard step.path?.isEmpty == false else { return fail("createFolder needs a path") }
        case .move:
            guard step.to?.isEmpty == false else { return fail("move needs a destination") }
            guard !step.match.isEmpty else { return fail("move needs a match") }
        case .rename:
            guard step.to?.isEmpty == false else { return fail("rename needs a new name") }
            guard !step.match.isEmpty else { return fail("rename needs a match") }
        case .trash:
            guard !step.match.isEmpty else { return fail("trash needs a match") }
        }
        return .success(step)
    }

    private static func strings(_ value: Any?) -> [String] {
        if let single = value as? String { return [single] }
        return (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        return (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Bytes; also "100MB", "1.5 GB", "200kb".
    static func size(_ value: Any?) -> Int64? {
        if let bytes = number(value) { return bytes >= 0 ? Int64(bytes) : nil }
        guard let text = (value as? String)?.lowercased().replacingOccurrences(of: " ", with: "") else { return nil }
        let units: [(String, Double)] = [("gb", 1_000_000_000), ("mb", 1_000_000), ("kb", 1_000), ("b", 1)]
        for (unit, scale) in units where text.hasSuffix(unit) {
            guard let amount = Double(text.dropLast(unit.count)), amount >= 0 else { return nil }
            return Int64(amount * scale)
        }
        return nil
    }
}

// MARK: - Operations, undo, results

/// One concrete change on disk, made only after the user pressed Start.
enum AgentOperation: Equatable {
    case createFolder(URL)
    case move(from: URL, to: URL)
    case rename(from: URL, to: URL)
    /// Never a permanent delete: always the Trash.
    case trash(URL)

    var isTrash: Bool { if case .trash = self { return true } else { return false } }
}

/// Everything an agent changed, newest last, so it can all be put back.
struct UndoLog: Equatable {
    enum Entry: Equatable {
        case createdFolder(URL)
        case moved(from: URL, to: URL)
        case trashed(original: URL, trashURL: URL)
    }

    /// Undo stays available this long.
    static let lifetime: TimeInterval = 30 * 60

    private(set) var entries: [Entry] = []
    let createdAt: Date

    init(createdAt: Date = Date()) { self.createdAt = createdAt }

    mutating func append(_ entry: Entry) { entries.append(entry) }

    var isEmpty: Bool { entries.isEmpty }

    func isAvailable(at date: Date = Date()) -> Bool {
        !entries.isEmpty && date.timeIntervalSince(createdAt) < Self.lifetime
    }
}

struct AgentResult: Equatable {
    var foldersCreated = 0
    var moved = 0
    var renamed = 0
    var trashed = 0
    var failed = 0
    var stopped = false
    var timedOut = false
    var completed = 0
    var total = 0
    var undo = UndoLog()
    /// The first problem, in plain words (a permission, a missing file…).
    var firstError: String?
    var milliseconds = 0
    /// Folders the moved files went into.
    var destinationFolders: Set<URL> = []
}

struct UndoOutcome: Equatable {
    var restored = 0
    var removedFolders = 0
    var failed = 0
}

/// Runs operations with FileManager, one file at a time, with progress and
/// a clean Stop (the current file finishes, then it halts). Call `run` off
/// the main thread.
final class AgentExecutor: @unchecked Sendable {
    static let maxDuration: TimeInterval = 10 * 60

    private let fileManager: FileManager
    private let lock = NSLock()
    private var stopRequested = false
    private let maxDuration: TimeInterval

    init(fileManager: FileManager = .default, maxDuration: TimeInterval = AgentExecutor.maxDuration) {
        self.fileManager = fileManager
        self.maxDuration = maxDuration
    }

    func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    var isStopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    /// `progress(done, total, operation)` after each operation.
    func run(_ operations: [AgentOperation], progress: (Int, Int, AgentOperation) -> Void = { _, _, _ in }) -> AgentResult {
        let started = Date()
        var result = AgentResult(total: operations.count, undo: UndoLog(createdAt: started))
        for operation in operations {
            if isStopRequested { result.stopped = true; break }
            if Date().timeIntervalSince(started) > maxDuration { result.timedOut = true; break }
            do {
                try perform(operation, into: &result)
            } catch {
                result.failed += 1
                if result.firstError == nil { result.firstError = Self.describe(error) }
                // Without permission every later file fails the same way.
                if Self.isPermission(error) { result.stopped = true; break }
            }
            result.completed += 1
            progress(result.completed, operations.count, operation)
        }
        result.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        return result
    }

    private func perform(_ operation: AgentOperation, into result: inout AgentResult) throws {
        switch operation {
        case .createFolder(let url):
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
                return
            }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            result.undo.append(.createdFolder(url))
            result.foldersCreated += 1
        case .move(let from, let to), .rename(let from, let to):
            guard fileManager.fileExists(atPath: from.path) else { throw CocoaError(.fileNoSuchFile) }
            // Never overwrite: if something appeared there since the preview, use "name 2".
            let destination = Self.freeURL(for: to, fileManager: fileManager)
            try fileManager.moveItem(at: from, to: destination)
            result.undo.append(.moved(from: from, to: destination))
            if case .rename = operation {
                result.renamed += 1
            } else {
                result.moved += 1
                result.destinationFolders.insert(destination.deletingLastPathComponent().standardizedFileURL)
            }
        case .trash(let url):
            guard fileManager.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
            var resulting: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resulting)
            if let trashURL = resulting as URL? { result.undo.append(.trashed(original: url, trashURL: trashURL)) }
            result.trashed += 1
        }
    }

    /// Puts everything back, newest first: moved and renamed items return,
    /// Trash items come back out, and folders the agent made are removed if
    /// they are empty.
    static func undo(_ log: UndoLog, fileManager: FileManager = .default) -> UndoOutcome {
        var outcome = UndoOutcome()
        for entry in log.entries.reversed() {
            do {
                switch entry {
                case .moved(let from, let to):
                    try fileManager.moveItem(at: to, to: freeURL(for: from, fileManager: fileManager))
                    outcome.restored += 1
                case .trashed(let original, let trashURL):
                    try fileManager.moveItem(at: trashURL, to: freeURL(for: original, fileManager: fileManager))
                    outcome.restored += 1
                case .createdFolder(let url):
                    let contents = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
                    // Finder may have left a .DS_Store; anything else means it's in use.
                    guard contents.allSatisfy({ $0 == ".DS_Store" }) else { continue }
                    try fileManager.removeItem(at: url)
                    outcome.removedFolders += 1
                }
            } catch {
                outcome.failed += 1
            }
        }
        return outcome
    }

    /// `url`, or "name 2.ext", "name 3.ext"… when it is taken on disk or reserved.
    static func freeURL(for url: URL, reserved: Set<String> = [], fileManager: FileManager = .default) -> URL {
        func taken(_ candidate: URL) -> Bool {
            fileManager.fileExists(atPath: candidate.path) || reserved.contains(candidate.standardizedFileURL.path.lowercased())
        }
        guard taken(url) else { return url }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        for number in 2...10_000 {
            let name = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !taken(candidate) { return candidate }
        }
        return folder.appendingPathComponent("\(stem) \(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)"))
    }

    static func isPermission(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, [1, 13].contains(underlying.code) { return true }
        return ns.domain == NSPOSIXErrorDomain && [1, 13].contains(ns.code)
    }

    static func describe(_ error: Error) -> String {
        if isPermission(error) { return "permission" }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileNoSuchFileError { return "a file was moved or deleted meanwhile" }
        return ns.localizedDescription
    }
}

// MARK: - Planner (the one AI call)

struct AgentPlannerReply {
    let text: String
    let model: ModelChoice
    let milliseconds: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let usedBackup: Bool

    var estimatedCost: Double? {
        ModelCatalog.estimatedCost(model: model.id, inputTokens: inputTokens, outputTokens: outputTokens)
    }
}

/// One planning call to the agent planner model (Settings → Developer →
/// Models), with the agent backup model when the plan is invalid or slower
/// than 5 seconds. Local mode only for now.
enum AgentPlanner {
    static let timeout: TimeInterval = 5
    static let maxOutputTokens = 400

    struct Attempt {
        let reply: AgentPlannerReply
        let parsed: AgentParseResult
    }

    static func plan(system: String, user: String, session: URLSession = .shared) async throws -> Attempt {
        let (reply, parsed) = try await planned(system: system, user: user,
                                                models: [ModelCatalog.selected(.agentPlanner), ModelCatalog.selected(.agentBackup)],
                                                session: session) { text -> AgentParseResult? in
            let parsed = AgentPlanParser.parse(text)
            return parsed.isValid ? parsed : nil
        }
        return Attempt(reply: reply, parsed: parsed)
    }

    /// One planning call per model in order (planner, then backup) until one
    /// returns a plan `parse` accepts; each call is limited to 5 seconds.
    static func planned<Parsed>(system: String, user: String, models: [ModelChoice],
                                schema: [String: Any] = AgentPlanParser.schema, schemaName: String = "agent_plan",
                                maxTokens: Int = maxOutputTokens, timeLimit: TimeInterval = timeout, image: Data? = nil,
                                session: URLSession,
                                parse: (String) -> Parsed?) async throws -> (AgentPlannerReply, Parsed) {
        guard LocalMode.isOn else { throw AgentError.needsLocalMode }
        var lastProblem = "no reply"
        for (index, model) in models.enumerated() {
            do {
                let reply = try await withTimeout(timeLimit) {
                    try await ask(model: model, system: system, user: user, backup: index > 0, session: session,
                                  schema: schema, schemaName: schemaName, maxTokens: maxTokens, image: image)
                }
                if let parsed = parse(reply.text) { return (reply, parsed) }
                lastProblem = "invalid plan"
            } catch is CancellationError {
                throw CancellationError()
            } catch AgentError.needsLocalMode {
                throw AgentError.needsLocalMode
            } catch let error as LocalBackendError {
                lastProblem = error.localizedDescription
            } catch PlannerTimeout.timedOut {
                lastProblem = "timed out"
            } catch {
                lastProblem = "network"
            }
        }
        throw AgentError.planFailed(lastProblem)
    }

    static func ask(model: ModelChoice, system: String, user: String, backup: Bool,
                    session: URLSession, schema: [String: Any] = AgentPlanParser.schema,
                    schemaName: String = "agent_plan", maxTokens: Int = maxOutputTokens,
                    image: Data? = nil) async throws -> AgentPlannerReply {
        let started = Date()
        let request = try request(model: model, system: system, user: user, schema: schema, schemaName: schemaName,
                                  maxTokens: maxTokens, image: image)
        let data = try await LocalBackend.send(request, provider: model.provider == .anthropic ? "Anthropic" : "OpenRouter",
                                               slot: model.provider.keySlot, session: session)
        guard var text = ClaudeAPI.responseText(from: data) else {
            throw LocalBackendError.invalidResponse(model.provider == .anthropic ? "Anthropic" : "OpenRouter")
        }
        if prefills(model), !text.trimmingCharacters(in: .whitespaces).hasPrefix("{") { text = "{" + text }
        let usage = LocalCostLog.usage(in: data)
        let reply = AgentPlannerReply(text: text, model: model, milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                                      inputTokens: usage.input, outputTokens: usage.output, usedBackup: backup)
        LocalCostLog.shared.record(LocalCostLog.Entry(date: Date(), feature: schemaName.replacingOccurrences(of: "_", with: " ") + (backup ? " (backup)" : ""),
                                                      model: model.id, inputTokens: usage.input, outputTokens: usage.output,
                                                      cost: reply.estimatedCost, milliseconds: reply.milliseconds))
        return reply
    }

    /// Anthropic models without adaptive thinking get a `{` prefill; the
    /// others answer the JSON schema (OpenRouter) or are parsed forgivingly.
    static func prefills(_ model: ModelChoice) -> Bool {
        model.provider == .anthropic && model.acceptsTemperature
    }

    static func request(model: ModelChoice, system: String, user: String,
                        schema: [String: Any] = AgentPlanParser.schema, schemaName: String = "agent_plan",
                        maxTokens: Int = maxOutputTokens, image: Data? = nil) throws -> URLRequest {
        switch model.provider {
        case .openrouter:
            // A screenshot, when there is one, goes with the text as a data URL.
            let userContent: Any
            if let image {
                userContent = [["type": "text", "text": user],
                               ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.base64EncodedString()]]]
                    as [[String: Any]]
            } else {
                userContent = user
            }
            var body: [String: Any] = [
                "model": model.id,
                "messages": [["role": "system", "content": system], ["role": "user", "content": userContent]],
                "max_tokens": maxTokens,
                "provider": LocalBackend.privacy,
                "reasoning": ["effort": "low"],
                "response_format": ["type": "json_schema",
                                    "json_schema": ["name": schemaName, "strict": false, "schema": schema]],
                "usage": ["include": true]
            ]
            if model.acceptsTemperature { body["temperature"] = 0 }
            return try LocalBackend.openRouterRequest(path: "chat/completions", json: body, key: LocalBackend.key(.openrouter))
        case .anthropic:
            let userContent: Any
            if let image {
                userContent = [["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]],
                               ["type": "text", "text": user]] as [[String: Any]]
            } else {
                userContent = user
            }
            var messages: [[String: Any]] = [["role": "user", "content": userContent]]
            if prefills(model) { messages.append(["role": "assistant", "content": "{"]) }
            var body: [String: Any] = [
                "model": model.id,
                "max_tokens": maxTokens,
                "system": system,
                "messages": messages
            ]
            if model.acceptsTemperature { body["temperature"] = 0 }
            return try LocalBackend.anthropicRequest(body: body, key: LocalBackend.key(.anthropic))
        }
    }

    enum PlannerTimeout: Error { case timedOut }

    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PlannerTimeout.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PlannerTimeout.timedOut }
            return first
        }
    }
}

// MARK: - Developer log (no file names, no user text)

/// One agent run for the developer Tool Gate log.
struct AgentLogEntry: Equatable {
    var date = Date()
    var route = "agent_files"
    /// keyword / router
    var layer = "keyword"
    var plannerModel = "—"
    var filesScanned = 0
    var stepsPlanned = 0
    var stepsValid = 0
    var stepsDropped = 0
    var planMilliseconds: Int?
    var executeMilliseconds: Int?
    var stopped = false
    var undone = false
    var estimatedCost: Double?
}

@MainActor
final class AgentLog {
    static let shared = AgentLog()
    private(set) var entries: [AgentLogEntry] = []

    /// Records only while "Record Tool Gate Log" is on, like the Tool Gate log.
    func record(_ entry: AgentLogEntry) {
        guard ToolGateLog.shared.isRecording else { return }
        entries.append(entry)
        if entries.count > 50 { entries.removeFirst(entries.count - 50) }
    }

    func markUndone(at date: Date) {
        guard let index = entries.lastIndex(where: { $0.date == date }) else { return }
        entries[index].undone = true
    }

    func clear() { entries.removeAll() }

    func table() -> String {
        func value(_ number: Int?) -> String { number.map(String.init) ?? "—" }
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        var lines = ["| # | time | route | layer | planner model | files scanned | steps planned | valid | dropped | plan ms | execute ms | stopped | undone | est. cost |",
                     "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for (index, entry) in entries.enumerated() {
            lines.append("| \(index + 1) | \(time.string(from: entry.date)) | \(entry.route) | \(entry.layer) | \(entry.plannerModel) | "
                         + "\(entry.filesScanned) | \(entry.stepsPlanned) | \(entry.stepsValid) | \(entry.stepsDropped) | "
                         + "\(value(entry.planMilliseconds)) | \(value(entry.executeMilliseconds)) | \(entry.stopped ? "yes" : "no") | "
                         + "\(entry.undone ? "yes" : "no") | \(ModelCatalog.formatted(entry.estimatedCost)) |")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
