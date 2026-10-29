import AppKit

enum LockScreenCommand {
    /// Only complete, immediate commands bypass the model and confirmation.
    /// Anchoring keeps quoted text, questions, negations and delayed requests out.
    static func isImmediate(_ command: String) -> Bool {
        let text = command.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let prefix = #"(?:(?:hey |hi )?bibbles[, ]+)?(?:(?:can|could|would|will) you )?(?:please )?(?:just )?"#
        let target = #"(?:(?:my|the|this) )?(?:mac(?:book)?|screen|computer|laptop|display)"#
        let english = #"lock "# + target
        let hinglish = #"(?:mera |meri |mere |ye )?(?:mac(?:book)?|screen|computer|laptop) (?:ko )?lock (?:kar do|kardo|karo|kar de)"#
        return text.range(of: "^" + prefix + "(?:" + english + "|" + hinglish + #")(?: (?:now|right now|please|abhi))?$"#,
                          options: .regularExpression) != nil
    }

    static func localPlan(for command: String) -> AgentPlan? {
        guard isImmediate(command) else { return nil }
        return AgentPlan(calls: [AgentToolCall(name: "lock_screen", input: [:])], text: "")
    }

    /// Broader imperative wording goes through the existing model planner.
    static func isRequest(_ command: String) -> Bool {
        if isImmediate(command) { return true }
        let text = command.lowercased()
        return text.range(of: #"^(?:(?:hey )?bibbles[, ]+)?(?:(?:can|could|would|will) you )?(?:please )?(?:lock|secure|protect)\b.*\b(?:mac|macbook|screen|computer|laptop|display)\b"#,
                          options: .regularExpression) != nil
    }
}

enum LockScreenAction {
    struct KeyStroke: Equatable {
        let keyCode: CGKeyCode
        let isDown: Bool
        let flags: CGEventFlags
    }

    private static let shortcut = [
        KeyStroke(keyCode: 12, isDown: true, flags: [.maskControl, .maskCommand]),
        KeyStroke(keyCode: 12, isDown: false, flags: [.maskControl, .maskCommand])
    ]

    /// Uses Apple's Control–Command–Q shortcut, never sleep or logout.
    /// Dependencies are injectable so tests cannot lock the developer's Mac.
    @MainActor
    static func run(
        isTrusted: () -> Bool = { AXIsProcessTrusted() },
        modifiers: () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) },
        send: ([KeyStroke]) throws -> Void = post
    ) async throws -> MacActionResult {
        try Task.checkCancellation()
        guard isTrusted() else {
            throw MacActionError.failed("Enable Bibbles in System Settings → Privacy & Security → Accessibility to lock your screen, then try again.")
        }
        // A voice shortcut or confirmation click can leave physical modifiers held.
        // Wait briefly instead of sending an unintended key combination.
        let held: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]
        for _ in 0..<40 {
            if modifiers().intersection(held).isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try Task.checkCancellation()
        guard modifiers().intersection(held).isEmpty else {
            throw MacActionError.failed("Release the shortcut keys, then ask Bibbles to lock your screen again.")
        }
        try send(shortcut)
        // Posting a shortcut is not proof that the OS completed the lock.
        return MacActionResult(message: "Lock requested. If your screen stays open, press Control–Command–Q.")
    }

    private static func post(_ strokes: [KeyStroke]) throws {
        guard let source = CGEventSource(stateID: .privateState) else {
            throw MacActionError.failed("Couldn't create the Mac lock-screen shortcut. Try Control–Command–Q.")
        }
        let events = strokes.map { stroke -> CGEvent? in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode,
                                      keyDown: stroke.isDown) else { return nil }
            event.flags = stroke.flags
            return event
        }
        guard events.allSatisfy({ $0 != nil }) else {
            throw MacActionError.failed("Couldn't create the Mac lock-screen shortcut. Try Control–Command–Q.")
        }
        events.compactMap { $0 }.forEach { $0.post(tap: .cghidEventTap) }
    }
}
