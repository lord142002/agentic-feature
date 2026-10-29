#if BIBBLES_DEVELOPER
import AppKit
import Foundation
import Security

/// The developer's own provider keys for local testing. Developer builds only.
enum DeveloperKeySlot: String, CaseIterable, Identifiable {
    case openrouter, anthropic, deepgram, openai, google

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openrouter: return "OpenRouter"
        case .anthropic: return "Anthropic"
        case .deepgram: return "Deepgram"
        case .openai: return "OpenAI (optional)"
        case .google: return "Google (optional)"
        }
    }

    /// What Local mode uses this key for.
    var usage: String {
        switch self {
        case .openrouter: return "Light tasks, web search, speech to text, spoken answers, agent planner, screen agents."
        case .anthropic: return "Deep tasks, light backup, AI router, agent backup."
        case .deepgram: return "Backup speech to text."
        case .openai: return "Optional, only to call OpenAI models directly."
        case .google: return "Optional, only to call Google models directly."
        }
    }

    var placeholder: String {
        switch self {
        case .openrouter: return "sk-or-…"
        case .anthropic: return "sk-ant-…"
        case .deepgram: return "Deepgram key"
        case .openai: return "sk-…"
        case .google: return "AIza…"
        }
    }
}

/// Provider keys, stored ONLY in this Mac's Keychain (one item per provider,
/// this device only, readable while unlocked). Never in code, files, logs,
/// UserDefaults, analytics or crash reports, and never sent to the Bibbles
/// server. A saved key is never shown again: only its last 4 characters.
enum DeveloperKeychain {
    static let defaultService = "com.bibbles.dev.keys"
    /// Tests use their own service name so real keys are never touched.
    static var service = defaultService
    /// The old router-only key, moved into the `anthropic` slot. A var only
    /// so tests can use their own name.
    static var legacyService = "com.bibbles.dev.router"
    static let legacyAccount = "anthropic-router-test-key"

    /// Self-test only: when set, the Keychain is never touched.
    static var testOverride: [DeveloperKeySlot: String]?

    private static let lock = NSLock()
    private static var cache: [DeveloperKeySlot: String?] = [:]

    static func read(_ slot: DeveloperKeySlot) -> String? {
        if let testOverride { return testOverride[slot] }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[slot] { return cached }
        let value = readItem(service: service, account: slot.rawValue)
        cache[slot] = .some(value)
        return value
    }

    static func has(_ slot: DeveloperKeySlot) -> Bool { read(slot)?.isEmpty == false }

    /// Trims and saves; an empty key saves nothing.
    @discardableResult
    static func save(_ key: String, for slot: DeveloperKeySlot) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if testOverride != nil {
            testOverride?[slot] = trimmed
            return true
        }
        lock.lock()
        defer { lock.unlock() }
        deleteItem(service: service, account: slot.rawValue)
        let ok = addItem(trimmed, service: service, account: slot.rawValue)
        cache[slot] = .some(ok ? trimmed : nil)
        return ok
    }

    static func remove(_ slot: DeveloperKeySlot) {
        if testOverride != nil {
            testOverride?[slot] = nil
            return
        }
        lock.lock()
        defer { lock.unlock() }
        deleteItem(service: service, account: slot.rawValue)
        cache[slot] = .some(nil)
    }

    /// "Not set" or "Set ✓ ····abcd" (last 4 characters only).
    static func status(_ slot: DeveloperKeySlot) -> String {
        guard let key = read(slot), !key.isEmpty else { return "Not set" }
        return "Set ✓ ····" + String(key.suffix(4))
    }

    /// Paste & Save: reads the clipboard, trims, saves, then clears the
    /// clipboard so the key doesn't stay there.
    @discardableResult
    static func pasteAndSave(_ slot: DeveloperKeySlot, pasteboard: NSPasteboard = .general) -> Bool {
        guard let pasted = pasteboard.string(forType: .string),
              !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let ok = save(pasted, for: slot)
        pasteboard.clearContents()
        return ok
    }

    /// First launch of a developer build: moves the old router key into the
    /// `anthropic` slot (unless one is already there), then deletes the old item.
    static func migrateLegacyRouterKey() {
        guard testOverride == nil,
              let legacy = readItem(service: legacyService, account: legacyAccount) else { return }
        if !has(.anthropic) { save(legacy, for: .anthropic) }
        if has(.anthropic) { deleteItem(service: legacyService, account: legacyAccount) }
    }

    /// Forgets cached values (tests switch services).
    static func resetCache() {
        lock.lock()
        cache = [:]
        lock.unlock()
    }

    // MARK: Keychain items

    static func readItem(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func addItem(_ value: String, service: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func deleteItem(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Key test (one tiny request)

enum DeveloperKeyTestResult: Equatable {
    case ok(String?)
    case invalidKey, noCredit, rateLimited, network
    case other(String)

    var text: String {
        switch self {
        case .ok(let detail): return detail.map { "OK · \($0)" } ?? "OK"
        case .invalidKey: return "invalid key"
        case .noCredit: return "no credit"
        case .rateLimited: return "rate limited"
        case .network: return "network"
        case .other(let problem): return problem
        }
    }

    var isOK: Bool { if case .ok = self { return true } else { return false } }
}

enum DeveloperKeyTester {
    /// The smallest request that proves the key works. The key always goes
    /// in a header, never in a URL.
    static func request(for slot: DeveloperKeySlot, key: String) -> URLRequest {
        var request: URLRequest
        switch slot {
        case .openrouter:
            // Also reports the remaining credit.
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": HybridRouter.model, "max_tokens": 1,
                "messages": [["role": "user", "content": "hi"]]
            ])
        case .deepgram:
            request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
            request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        case .openai:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .google:
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        request.timeoutInterval = 15
        return request
    }

    static func test(_ slot: DeveloperKeySlot, session: URLSession = .shared) async -> DeveloperKeyTestResult {
        guard let key = DeveloperKeychain.read(slot), !key.isEmpty else { return .other("not set") }
        do {
            let (data, response) = try await session.data(for: request(for: slot, key: key))
            return classify(slot: slot, status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            return .network
        }
    }

    /// Turns the reply into the exact problem, for every provider.
    static func classify(slot: DeveloperKeySlot, status: Int, body: Data) -> DeveloperKeyTestResult {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = (((object?["error"] as? [String: Any])?["message"] as? String)
            ?? (object?["error"] as? String) ?? (object?["err_msg"] as? String) ?? "").lowercased()
        switch status {
        case 200..<300:
            if slot == .openrouter, let info = object?["data"] as? [String: Any] {
                if let left = (info["limit_remaining"] as? NSNumber)?.doubleValue {
                    return left <= 0 ? .noCredit : .ok(String(format: "$%.2f credit left", left))
                }
                return .ok("no credit limit set")
            }
            return .ok(nil)
        case 401, 403:
            return .invalidKey
        case 402:
            return .noCredit
        case 429:
            return message.contains("quota") || message.contains("billing") ? .noCredit : .rateLimited
        case 400 where message.contains("credit") || message.contains("billing"):
            return .noCredit
        case 400 where slot == .google && message.contains("api key"):
            return .invalidKey
        default:
            return .other("http \(status)")
        }
    }
}
#endif
