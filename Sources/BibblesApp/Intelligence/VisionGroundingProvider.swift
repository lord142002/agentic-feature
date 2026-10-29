import CoreGraphics
import Foundation

struct VisionGroundingRequest {
    let question: String
    let image: CGImage
    let ocr: [OCRObservation]
    let descriptor: CaptureDescriptor
    var pointerInImage: CGPoint? = nil
    var kind: ScreenQuestionKind = .general
}

struct GroundedAnswer: Equatable {
    let answer: String
    let confidence: Double
    let target: NormalizedRect?
    let model: String
    var annotations: [GroundedAnnotation] = []
    var visualExplanation: VisualExplanation? = nil
    var priceLevels: [PriceLevel] = []
    var guideSteps: [GuideStep] = []
    /// A tutor-style explanation: each step is spoken while its mark is drawn
    /// on the real screen (parts first, then the whole).
    var walkthrough: [WalkthroughStep] = []

    var needsFallback: Bool {
        confidence < ClaudeAPI.handOverConfidence || (target != nil && target?.isValid != true) || refusesScreenAccess
    }

    var refusesScreenAccess: Bool {
        let normalized = answer.lowercased().replacingOccurrences(of: "’", with: "'")
        let missingAccess = normalized.contains("can't see")
            || normalized.contains("cannot see")
            || normalized.contains("don't have access")
            || normalized.contains("do not have access")
        return missingAccess && (normalized.contains("screen") || normalized.contains("screenshot"))
    }
}

/// One step of an on-screen how-to guide. `target` is set only when the
/// control for this step is visible in the captured screen.
struct GuideStep: Equatable {
    let title: String
    let explanation: String
    let target: NormalizedRect?
}

extension GroundedAnswer {
    /// The same answer with no on-screen marks.
    var withoutMarks: GroundedAnswer {
        GroundedAnswer(answer: answer, confidence: confidence, target: nil, model: model, annotations: [],
                       visualExplanation: visualExplanation,
                       priceLevels: priceLevels, guideSteps: guideSteps, walkthrough: walkthrough)
    }
}

/// One step of a screen walkthrough: what to say, and what to draw.
struct WalkthroughStep: Equatable {
    let say: String
    var mark: WalkthroughMark?
}

/// A mark on the captured image (normalized, top-left origin). `.line`
/// traces `points` (a side, edge or curve); other shapes use `target`.
struct WalkthroughMark: Equatable {
    let shape: DoodleShape
    var points: [CGPoint] = []
    var target: NormalizedRect?
    var label: String?
}

struct GroundedAnnotation: Equatable {
    let shape: DoodleShape
    let target: NormalizedRect
    let confidence: Double
    let label: String?
    var step: Int? = nil

    var isRenderable: Bool {
        [.circle, .rectangle, .arrow, .underline, .spotlight].contains(shape)
            && target.isValid && target.width * target.height <= 0.20
            && confidence.isFinite && (0.72...1).contains(confidence)
    }
}

protocol VisionGroundingProviding {
    func ground(_ request: VisionGroundingRequest) async throws -> GroundedAnswer
}

enum VisionGroundingError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidBaseURL
    case imageEncodingFailed
    case invalidResponse
    case invalidTarget
    case screenNotAnalyzed
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Please sign in to Bibbles to use screen help."
        case .invalidBaseURL: return "The vision API base URL is invalid."
        case .imageEncodingFailed: return "The screen crop could not be encoded."
        case .invalidResponse: return "The vision model returned an invalid grounding response."
        case .invalidTarget: return "The vision model returned an unsafe target rectangle."
        case .screenNotAnalyzed: return "Bibbles captured the screen, but the vision model could not analyze it. Try again."
        case let .server(_, message): return message
        }
    }
}

/// When screen help may hand a question from the light model to the deep one.
/// The same rule for every plan: plans change limits, never the model choice.
enum ScreenHandOverPolicy: Equatable {
    /// Simple screen questions (where is X, what is this, which app is open,
    /// read this, what does this say): stay light; hand over only when the
    /// light answer is empty, unreadable or refuses to look at the screen.
    case onlyIfBroken
    /// Charts, graphs, step-by-step guides and complex analysis: hand over
    /// below 75% confidence or when an expected mark is missing.
    case confidence

    static func forQuestion(_ question: String, kind: ScreenQuestionKind) -> ScreenHandOverPolicy {
        if kind.isChart || kind == .howTo { return .confidence }
        if kind == .findControl { return .onlyIfBroken }
        let text = question.lowercased()
        let words = text.split(whereSeparator: \.isWhitespace).count
        let complex = ["analy", "compare", "comparison", "review", "evaluate", "debug", "in detail", "step by step",
                       "summari", "diagram", "graph", "chart", "spreadsheet", "table", "stack trace",
                       "vergleich", "grafik", "diagramm", "tabelle", "graphique", "tableau", "gráfico", "grafico",
                       "tabla", "tabella", "grafiek", "tabel", "चार्ट", "ग्राफ", "विश्लेषण"]
        if words > 25 || complex.contains(where: text.contains)
            || ToolGate.deepScore(question, language: ToolGate.detectLanguage(question)) > 0 {
            return .confidence
        }
        return .onlyIfBroken
    }
}

/// What screen help did, for the developer Tool Gate log (no user text).
struct ScreenHandOverReport: Equatable {
    var tier: String
    var handOver: String?
}

struct GroundingCoordinator {
    let primary: VisionGroundingProviding
    let fallback: VisionGroundingProviding?
    var policy: ScreenHandOverPolicy = .confidence
    var onReport: ((ScreenHandOverReport) -> Void)? = nil

    private func tier(of answer: GroundedAnswer, _ request: VisionGroundingRequest) -> String {
        request.kind.isChart || answer.model == ClaudeAPI.smartModel ? "deep" : "light"
    }

    func ground(_ request: VisionGroundingRequest) async throws -> GroundedAnswer {
        guard let fallback else {
            let answer = try await primary.ground(request)
            if answer.refusesScreenAccess { throw VisionGroundingError.screenNotAnalyzed }
            onReport?(ScreenHandOverReport(tier: tier(of: answer, request), handOver: nil))
            return answer
        }
        var firstAnswer: GroundedAnswer?
        var reason = "unreadable answer"
        do {
            let first = try await primary.ground(request)
            firstAnswer = first
            switch policy {
            case .confidence:
                // Below 75% confidence the stronger model answers instead.
                let unsure = first.needsFallback
                let missingMark = request.kind.expectsTarget && first.target == nil && first.annotations.isEmpty
                if !unsure && !missingMark {
                    onReport?(ScreenHandOverReport(tier: tier(of: first, request), handOver: nil))
                    return first
                }
                reason = first.refusesScreenAccess ? "refused screen"
                    : first.confidence < ClaudeAPI.handOverConfidence ? "confidence below 75%"
                    : missingMark ? "missing mark" : "invalid mark"
            case .onlyIfBroken:
                let empty = first.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !empty && !first.refusesScreenAccess {
                    // A doubtful mark is dropped rather than paid for twice.
                    let kept = first.target.map { $0.isValid } ?? true ? first : first.withoutMarks
                    onReport?(ScreenHandOverReport(tier: tier(of: kept, request), handOver: nil))
                    return kept
                }
                reason = empty ? "empty answer" : "refused screen"
            }
        } catch VisionGroundingError.invalidResponse {
            // A malformed visual response can be retried with the fallback.
            reason = "unreadable answer"
        } catch VisionGroundingError.invalidTarget {
            reason = "invalid mark"
        }
        try Task.checkCancellation()
        let second: GroundedAnswer
        do { second = try await fallback.ground(request) }
        catch WorkerError.limitReached {
            // Alpha may have no deep-task allowance. Keep the paid-for light
            // answer instead of discarding it after a failed hand-over.
            if let firstAnswer {
                if firstAnswer.refusesScreenAccess { throw VisionGroundingError.screenNotAnalyzed }
                onReport?(ScreenHandOverReport(tier: "light", handOver: reason + " (no deep tasks left)"))
                return firstAnswer.withoutMarks
            }
            throw WorkerError.limitReached("deep_tasks")
        } catch let error as WorkerError {
            // Rate-limited on the second look: keep the light answer we already have.
            guard case .rateLimited = error, let firstAnswer, !firstAnswer.refusesScreenAccess else { throw error }
            onReport?(ScreenHandOverReport(tier: "light", handOver: reason + " (rate limited)"))
            return firstAnswer.withoutMarks
        }
        if second.refusesScreenAccess { throw VisionGroundingError.screenNotAnalyzed }
        onReport?(ScreenHandOverReport(tier: tier(of: second, request), handOver: reason))
        return second
    }
}
