import Foundation
import SwiftUI

enum InteractionState: Equatable {
    case idle
    case listening
    case dictating
    case composing
    case transcript(String, isFinal: Bool)
    case answer(String)
    case working(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .dictating: return "Dictating…"
        case .composing: return "Type to Bibbles"
        case let .transcript(text, _): return text
        case let .answer(text): return text
        case let .working(text): return text
        case let .failed(text): return text
        }
    }

    var headline: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening to your question"
        case .dictating: return "Dictating into your app"
        case .composing: return "Type a question"
        case let .transcript(_, isFinal): return isFinal ? "Heard you" : "Listening…"
        case .answer: return "Answer"
        case .working: return "Working on it"
        case .failed: return "Needs attention"
        }
    }

    var supportingText: String? {
        switch self {
        case .listening, .dictating: return "Release the shortcut when you're done"
        case .working(let detail): return detail
        case .transcript(let text, _): return text
        default: return nil
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "sparkles"
        case .listening: return "waveform"
        case .dictating: return "text.cursor"
        case .composing: return "keyboard"
        case .transcript: return "quote.bubble"
        case .answer: return "sparkles"
        case .working: return "ellipsis"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var isBusy: Bool {
        switch self {
        case .listening, .dictating, .working: return true
        default: return false
        }
    }

    var accentColor: Color {
        switch self {
        case .listening, .dictating: return .cyan
        case .working: return .yellow
        case .failed: return .red
        case .transcript: return .green
        case .answer: return .cyan
        default: return .primary
        }
    }

    var answerText: String? {
        guard case let .answer(text) = self else { return nil }
        return text
    }

    var failureText: String? {
        guard case let .failed(text) = self else { return nil }
        return text
    }

    var usesInteractiveCard: Bool {
        answerText != nil || failureText != nil
    }
}

@MainActor
final class InteractionModel: ObservableObject {
    @Published private(set) var state: InteractionState = .idle
    @Published private(set) var lastAnswer: String?
    @Published private(set) var lastTransition = ContinuousClock.now
    @Published private(set) var canCancel = false
    @Published private(set) var canRetry = false
    @Published private(set) var canUseTranscriptAnyway = false
    @Published private(set) var recoveryText: String?
    /// Which AI model wrote the visible answer, e.g. "Sonnet".
    @Published var modelLabel: String?

    func transition(to next: InteractionState) {
        state = next
        recoveryText = nil
        if next.answerText == nil {
            modelLabel = nil
            ClaudeAPI.lastUsedModel = nil
        } else if modelLabel == nil {
            modelLabel = ClaudeAPI.answeredByLabel() ?? "On this Mac"
        }
        if let answer = next.answerText, !answer.isEmpty { lastAnswer = answer }
        lastTransition = .now
    }

    /// Forgets the last answer (used when the signed-in account changes).
    func forgetLastAnswer() {
        lastAnswer = nil
        modelLabel = nil
    }

    func rememberAnswer(_ answer: String) {
        guard !answer.isEmpty else { return }
        lastAnswer = answer
    }

    func offerRecoveryText(_ text: String) {
        recoveryText = text.isEmpty ? nil : text
    }

    func showAgain() -> Bool {
        guard let lastAnswer else { return false }
        transition(to: .answer(lastAnswer))
        setActions()
        return true
    }

    func setActions(cancel: Bool = false, retry: Bool = false, useTranscriptAnyway: Bool = false) {
        canCancel = cancel
        canRetry = retry
        canUseTranscriptAnyway = useTranscriptAnyway
    }

    func cancel() {
        setActions()
        transition(to: .idle)
    }
}
