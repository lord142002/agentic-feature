#if BIBBLES_DEVELOPER
import CryptoKit
import Foundation

/// Plans that finished a task with no problem, reused the next time the same
/// request is made in the same app (no AI call). A reused plan is checked
/// against the screen like any other and still shows its preview first.
///
/// Nothing personal is stored: the request only as a hash, and only steps
/// that name things on screen (menus, buttons, switches, pop-ups, saved-detail
/// placeholders, keys, Mac settings). A plan with typed text, an email, a
/// click by position, a website, a file or a final action is never kept.
enum ScreenPlanMemory {
    static let limit = 50
    static let storeKey = "ScreenAgent.rememberedPlans"
    /// Tests use their own defaults.
    static var defaults: UserDefaults = .standard

    struct Entry: Codable, Equatable {
        let key: String
        let plan: String
        let saved: Date
    }

    static func key(app bundleID: String?, request: String) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let words = ToolGateText.fold(request).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data((bundleID + "|" + words).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func recall(app bundleID: String?, request: String) -> ScreenPlan? {
        guard let key = key(app: bundleID, request: request),
              let entry = entries().first(where: { $0.key == key }) else { return nil }
        return ScreenPlanParser.parse(entry.plan).plan
    }

    /// Returns true when the plan could be kept.
    @discardableResult
    static func remember(_ plan: ScreenPlan, app bundleID: String?, request: String) -> Bool {
        guard let key = key(app: bundleID, request: request), let text = encode(plan, request: request) else { return false }
        var list = entries().filter { $0.key != key }
        list.insert(Entry(key: key, plan: text, saved: Date()), at: 0)
        store(Array(list.prefix(limit)))
        return true
    }

    static func forget(app bundleID: String?, request: String) {
        guard let key = key(app: bundleID, request: request) else { return }
        store(entries().filter { $0.key != key })
    }

    static func clear() { defaults.removeObject(forKey: storeKey) }

    static func entries() -> [Entry] {
        guard let data = defaults.data(forKey: storeKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private static func store(_ list: [Entry]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: storeKey)
    }

    // MARK: Encoding (the planner's own JSON format)

    static func encode(_ plan: ScreenPlan, request: String) -> String? {
        guard plan.done, !plan.steps.isEmpty else { return nil }
        let requestFolded = ToolGateText.fold(request)
        var steps: [[String: Any]] = []
        for step in plan.steps {
            guard let object = encode(step, request: requestFolded) else { return nil }
            steps.append(object)
        }
        let object: [String: Any] = ["summary": String(plan.summary.prefix(120)), "done": true, "steps": steps]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static let rememberedMacTools: Set<String> = ["set_dark_mode", "set_volume", "set_brightness"]

    static func encode(_ step: ScreenStep, request requestFolded: String) -> [String: Any]? {
        switch step {
        case .menu(let path):
            return ["action": "menu", "path": path]
        case .press(let title):
            return ScreenSafety.blockedWord(in: title) == nil ? ["action": "press", "target": title] : nil
        case .toggle(let title, let on):
            return ["action": "toggle", "target": title, "on": on]
        case .choose(let title, let option):
            // Only an option the user said in the request (not one of their saved details).
            return requestFolded.contains(ToolGateText.fold(option)) ? ["action": "choose", "target": title, "option": option] : nil
        case .fill(let field, let value):
            return isOnlyPlaceholders(value) ? ["action": "fill", "field": field, "value": value] : nil
        case .save(let folder, let name):
            var object: [String: Any] = ["action": "save"]
            if let folder { object["folder"] = folder }
            if let name { object["name"] = name }
            return object
        case .key(let keys, let final):
            return final ? nil : ["action": "key", "keys": keys]
        case .wait(let ms):
            return ["action": "wait", "ms": ms]
        case .mac(let call):
            guard rememberedMacTools.contains(call.name) else { return nil }
            var input: [String: Any] = [:]
            for (name, value) in call.input {
                switch value {
                case .string(let text): input[name] = text
                case .number(let number): input[name] = number
                case .bool(let flag): input[name] = flag
                case .other: return nil
                }
            }
            return ["action": "mac", "tool": call.name, "input": input]
        case .click, .clickItem, .type, .play, .drag, .scroll, .switchApp, .remember, .attach, .openFile, .composeEmail:
            return nil
        }
    }

    /// "{{firstName}} {{lastName}}": saved details only, no other words.
    static func isOnlyPlaceholders(_ value: String) -> Bool {
        let rest = value.replacingOccurrences(of: #"\{\{\s*[a-zA-Z]+\s*\}\}"#, with: "", options: .regularExpression)
        return value.contains("{{") && rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
#endif
