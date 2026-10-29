import Foundation

/// Decides, on this Mac and before any AI call, whether an "explain" screen
/// question is about a diagram or formula (needs the deep model) or about
/// words, text or the interface (the fast model is enough). Unclear cases
/// stay on the fast model, so most questions stay cheap.
enum ScreenComplexity {
    /// Words that mean a picture with parts, spatial reasoning or maths.
    static let diagramWords = [
        "formula", "equation", "diagram", "figure", "graph", "geometry", "triangle", "rectangle",
        "proof", "prove", "theorem", "derivation", "derive", "identity", "flowchart", "flow chart",
        "circuit", "integral", "derivative", "matrix", "vector", "parabola", "hypotenuse", "angle",
        "fraction", "expression", "solve this", "visual proof", "sutra", "सूत्र", "आकृति", "समीकरण"
    ]

    /// Words that mean text meaning, language or simple interface help.
    static let textWords = [
        "word", "meaning", "mean by", "sentence", "paragraph", "phrase", "highlighted", "highlight",
        "selected", "translate", "translation", "define", "definition", "spelling", "pronounce",
        "synonym", "grammar", "matlab", "मतलब", "अर्थ", "shabd", "शब्द",
        "button", "icon", "menu", "setting", "app", "website", "error message"
    ]

    /// Asking to be taught (not "where is" or "what app is this").
    static let teachWords = ["explain", "understand", "teach", "how does", "how do", "why", "solve",
                             "samjha", "samjh", "kaise", "समझा", "breakdown", "break down", "walk me through"]

    /// Characters that only appear in maths.
    static let mathCharacters = Set("²³√∑∫π=±×÷≤≥≠∞θ^")

    /// true: send this screen question to the deep model.
    static func needsDeep(question: String, ocr: [OCRObservation]) -> Bool {
        let text = question.lowercased()
        // 1. The question names a diagram or formula.
        if diagramWords.contains(where: text.contains) { return true }
        // 2. It's about words, text or the interface.
        if textWords.contains(where: { containsWord($0, in: text) }) { return false }
        // 3. Otherwise only a teaching question can go deep, and only when
        //    the screen looks like a diagram or formula.
        guard teachWords.contains(where: text.contains) else { return false }
        return looksLikeDiagram(ocr)
    }

    /// Maths symbols, or a few scattered single letters (a, b, c, x, y) over
    /// a drawing, and not mostly ordinary sentences.
    static func looksLikeDiagram(_ ocr: [OCRObservation]) -> Bool {
        guard !ocr.isEmpty else { return false }
        let texts = ocr.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let mathItems = texts.filter { item in
            item.contains(where: { mathCharacters.contains($0) })
                || (item.count <= 2 && item.allSatisfy(\.isLetter))
                || item.range(of: #"^[a-zA-Z0-9]\s*[\+\-]\s*[a-zA-Z0-9]"#, options: .regularExpression) != nil
        }.count
        let sentences = texts.filter { $0.split(separator: " ").count >= 6 }.count
        return mathItems >= 3 && sentences * 2 < texts.count
    }

    /// Whole-word match for short words ("app" must not match "happy").
    private static func containsWord(_ word: String, in text: String) -> Bool {
        guard word.count <= 6, word.allSatisfy({ $0.isASCII && $0.isLetter }) else { return text.contains(word) }
        return text.range(of: #"\b"# + word + #"s?\b"#, options: .regularExpression) != nil
    }
}
