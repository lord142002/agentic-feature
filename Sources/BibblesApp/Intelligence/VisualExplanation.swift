import Foundation

/// A bounded scene format for visual guides. Canvas coordinates are relative
/// to the guide itself, never the user's desktop.
struct VisualExplanation: Codable, Equatable {
    let title: String
    let steps: [VisualExplanationStep]

    var isValid: Bool {
        !title.isEmpty && title.count <= 100 && (1...6).contains(steps.count)
            && steps.allSatisfy(\.isValid)
    }

    var transcript: String {
        ([title] + steps.map { "\($0.title): \($0.explanation)" }).joined(separator: "\n\n")
    }

    /// Mathematical and geometry requests stay in ordinary answers rather
    /// than opening the retired lesson canvas.
    static func isMathLessonQuestion(_ question: String) -> Bool {
        let terms = #"\b(?:math|maths|mathematics|equations?|quadratic|pythagoras|pythagorean|geometry|geometric|triangles?|polygons?|algebra|calculus|fractions?|theorem|derivative|integral)\b"#
        return question.range(of: terms, options: [.regularExpression, .caseInsensitive]) != nil
            || question.contains(where: { "=√∫∑".contains($0) })
    }
}

struct VisualExplanationStep: Codable, Equatable {
    let title: String
    let explanation: String
    let strokes: [ExplanationStroke]
    let labels: [ExplanationLabel]

    var isValid: Bool {
        !title.isEmpty && title.count <= 100 && explanation.count <= 800
            && strokes.count <= 16 && labels.count <= 12
            && strokes.allSatisfy(\.isValid) && labels.allSatisfy(\.isValid)
    }
}

struct ExplanationPoint: Codable, Equatable {
    let x: Double
    let y: Double
    var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

struct ExplanationStroke: Codable, Equatable {
    let points: [ExplanationPoint]
    let tone: String
    var isValid: Bool { (2...160).contains(points.count) && points.allSatisfy(\.isValid) && Self.tones.contains(tone) }
    static let tones = ["teal", "violet", "coral", "amber"]
}

struct ExplanationLabel: Codable, Equatable {
    let text: String
    let position: ExplanationPoint
    var isValid: Bool { !text.isEmpty && text.count <= 60 && position.isValid }
}
