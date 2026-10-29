import AppKit
import Foundation

/// Something Bibbles typed into an app (a story, mail, message…).
struct WrittenWork: Equatable {
    let text: String
    let request: String
    let appPID: pid_t
    let appName: String
    let date: Date
}

/// A short memory of what Bibbles wrote recently, kept only on this Mac and
/// only in memory, so "change it" or "make that mail shorter" know what
/// "it" is. Checking it takes well under a millisecond; it is sent to the AI
/// only for an edit request.
@MainActor
final class WorkMemory {
    static let shared = WorkMemory()
    /// How long a piece of writing can still be referred to as "it".
    static let lifetime: TimeInterval = 30 * 60
    private(set) var items: [WrittenWork] = []

    func remember(_ text: String, request: String, app: NSRunningApplication) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.insert(WrittenWork(text: trimmed, request: request, appPID: app.processIdentifier,
                                 appName: app.localizedName ?? "your app", date: Date()), at: 0)
        if items.count > 5 { items.removeLast(items.count - 5) }
    }

    /// The latest writing still in memory, preferring the given app.
    func latest(preferring app: NSRunningApplication?, now: Date = Date()) -> WrittenWork? {
        let fresh = items.filter { now.timeIntervalSince($0.date) < Self.lifetime }
        if let app, let match = fresh.first(where: { $0.appPID == app.processIdentifier }) { return match }
        return fresh.first
    }

    func clear() { items.removeAll() }
}

/// Requests to change something already written: "change it", "I don't like
/// this story", "replace the mail", "make it shorter", "isko badal do".
enum EditRequest {
    private static let things = "story|mail|email|e-mail|message|note|letter|text|paragraph|para|poem|reply|post|caption|draft|essay|ending|beginning|title|subject|answer|version|summary|tweet|bio|script|line|lines|sentence|application|speech|joke"

    static func isEdit(_ transcript: String) -> Bool {
        let text = normalized(transcript)
        guard !text.isEmpty else { return false }
        let reference = #"\b(?:it|this|that|these|those|the (?:"# + things + #")|my (?:"# + things + #")|your (?:"# + things + #"))\b"#
        let lead = #"^(?:(?:hey )?bibbles )?(?:ok |okay |no |nah |hmm )?(?:please )?(?:(?:can|could|would|will) (?:you|u) )?(?:please )?"#
        let rewriteVerb = #"(?:change|replace|rewrite|re write|redo|redraft|rework|edit|update|improve|shorten|lengthen|simplify|polish|rephrase|reword|revise|swap)\b"#
        // "change it", "rewrite this story", "replace the mail with a formal one"
        if matches(lead + rewriteVerb + ".*" + reference, text) || matches(lead + rewriteVerb + #"\s*$"#, text) { return true }
        // "make it shorter", "make the mail more formal"
        if matches(lead + #"make (?:it|this|that|the (?:"# + things + #")) (?:a bit |little |much |more |less |even )?(?:shorter|longer|better|simpler|formal|casual|funny|funnier|polite|professional|friendly|scarier|happier|sadder|short|long|crisp|clear|clearer|detailed|interesting|exciting|serious|emotional|romantic|simple|more|less)\b"#, text) { return true }
        // "I don't like it / this story", "not good, change", "this is boring"
        if matches(#"\bi (?:do not|dont|don t|didn t|didnt|did not) (?:like|love|want)\b"#, text), matches(reference + "|" + rewriteVerb, text) { return true }
        if matches(#"^(?:(?:this|that|it) is|its|it s) (?:not good|bad|boring|too long|too short|not nice|not right|wrong)\b"#, text) { return true }
        // "write another one", "give me a different story", "try again"
        if matches(lead + #"(?:write|give me|make|do) (?:another|a different|a new|one more|a better)(?: one| version| (?:"# + things + #"))?\b"#, text) { return true }
        if matches(#"^(?:try again|one more time|another one|different one|again please)$"#, text) { return true }
        // Hinglish / Hindi
        let hinglish = ["badal do", "badal de", "badlo", "badal ke", "dusri likho", "dusra likho", "doosri likho", "doosra likho",
                        "phir se likho", "fir se likho", "dobara likho", "chhota karo", "chota karo", "chhota kar do", "chota kar do",
                        "lamba karo", "lamba kar do", "acha nahi laga", "accha nahi laga", "pasand nahi aaya", "pasand nahi aayi",
                        "change karo", "change kar do", "replace karo", "replace kar do", "rewrite karo", "rewrite kar do",
                        "aur acha karo", "behtar karo"]
        if matches(#"\b(?:dusri|dusra|doosri|doosra|nayi|naya|alag) (?:\p{L}+ )?(?:likho|likh do|banao)\b"#, text) { return true }
        if hinglish.contains(where: text.contains) { return true }
        // Tool Gate: "mach es kürzer", "rends-le plus court", "hazlo más corto"…
        return ToolGate.isEnabled && ToolGate.isEditRequest(transcript)
    }

    /// The request names the kind of writing ("the mail", "this story").
    static func namesText(_ transcript: String) -> Bool {
        matches(#"\b(?:"# + things + #")\b"#, normalized(transcript))
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s-]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
