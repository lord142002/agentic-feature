import Foundation

enum VoiceReplyText {
    static func spoken(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"\[([^\]]+)\]\(https?://[^)]+\)"#,
                                               with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[`*_#]"#, with: "", options: .regularExpression)
        value = String(value.filter { character in
            !character.unicodeScalars.contains { scalar in
                let point = scalar.value
                if (0x30...0x39).contains(point) || point == 0x23 || point == 0x2A { return false }
                return scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && point > 0x7F)
                    || point == 0xFE0F || point == 0x20E3
            }
        })
        return value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pieces for speaking a whole answer: a short first piece (so speech
    /// starts quickly), then whole sentences grouped up to about
    /// `groupLimit` characters, so there are few joins between pieces.
    static func speechChunks(_ text: String, groupLimit: Int = 320) -> [String] {
        let (sentences, tail) = readyChunks(in: text, final: true, limit: 600, quickStart: true)
        let pieces = sentences + (tail.isEmpty ? [] : [tail])
        guard let first = pieces.first else { return [] }
        var result = [first]
        var current = ""
        for piece in pieces.dropFirst() {
            // The second piece stays smaller, so it is ready before the short
            // first piece finishes playing (no pause after the first sentence).
            let limit = result.count == 1 ? min(groupLimit, 160) : groupLimit
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= limit {
                current += " " + piece
            } else {
                result.append(current)
                current = piece
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Returns stable sentence prefixes for incremental model output. The
    /// unfinished tail stays in the card until the next update arrives.
    /// `quickStart`: the first chunk of an answer may end at a comma or
    /// similar pause (after at least 25 characters), so speech starts sooner.
    static func readyChunks(in text: String, final: Bool, limit: Int = 150,
                            quickStart: Bool = false) -> ([String], String) {
        var remaining = text
        var chunks: [String] = []
        var firstChunk = quickStart
        while !remaining.isEmpty {
            let window = firstChunk ? 90 : limit
            let search = String(remaining.prefix(window))
            var boundary = sentenceEnd(in: remaining, within: window, final: final)
            if firstChunk, boundary.map({ $0 > 60 }) ?? true {
                // A pause mark followed by a space (so "1,000" is never split).
                let pauses = search.indices.filter { index in
                    let next = search.index(after: index)
                    return ",;:—".contains(search[index]) && next < search.endIndex && search[next] == " "
                        && search.distance(from: search.startIndex, to: index) >= 25
                }
                if let pause = pauses.first { boundary = search.distance(from: search.startIndex, to: pause) }
            }
            firstChunk = false
            if let boundary {
                let offset = boundary + 1
                let end = remaining.index(remaining.startIndex, offsetBy: offset)
                let candidate = spoken(String(remaining[..<end]))
                if !candidate.isEmpty { chunks.append(candidate) }
                remaining = String(remaining[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if remaining.count > limit {
                let prefix = String(remaining.prefix(limit))
                let split = prefix.lastIndex(of: " ") ?? prefix.endIndex
                let raw = String(prefix[..<split])
                let candidate = spoken(raw)
                if !candidate.isEmpty { chunks.append(candidate) }
                remaining = String(remaining.dropFirst(raw.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                break
            }
        }
        if final, !remaining.isEmpty {
            let candidate = spoken(remaining)
            if !candidate.isEmpty { chunks.append(candidate) }
            remaining = ""
        }
        return (chunks, remaining)
    }

    /// Character offset of the first sentence end within `limit` characters.
    /// A full stop only ends a sentence when a space follows it, so "3.5",
    /// "v2.1" and "bibbles.in" are read whole. A full stop at the very end
    /// counts only on the final update (more digits may still be coming).
    static func sentenceEnd(in text: String, within limit: Int, final: Bool) -> Int? {
        var index = text.startIndex
        var offset = 0
        let otherScriptEnds = ToolGate.isEnabled
        while index < text.endIndex, offset < limit {
            let character = text[index]
            if "!?।\n".contains(character) { return offset }
            // Chinese/Japanese, Arabic and Devanagari sentence ends.
            if otherScriptEnds, "。！？؟॥".contains(character) { return offset }
            if character == "." {
                let next = text.index(after: index)
                if next == text.endIndex {
                    if final { return offset }
                } else if text[next].isWhitespace {
                    return offset
                }
            }
            index = text.index(after: index)
            offset += 1
        }
        return nil
    }
}

/// One piece of speech sent to the voice server. `marks` say where inside
/// the piece each walkthrough step starts (0 = start, 1 = end).
struct SpeechPiece: Equatable {
    struct Mark: Equatable { let step: Int; let at: Double }
    var text: String
    var marks: [Mark] = []
}

extension VoiceReplyText {
    /// Walkthrough speech in few, larger pieces: the first step alone (so the
    /// voice starts quickly), then whole steps grouped up to `groupLimit`
    /// characters. Fewer requests means far fewer failures and no gaps, and
    /// each step's drawing is timed by its position inside its piece.
    static func stepPieces(_ steps: [String], groupLimit: Int = 600) -> [SpeechPiece] {
        var pieces: [SpeechPiece] = []
        var current = SpeechPiece(text: "")
        var starts: [(step: Int, offset: Int)] = []
        func flush() {
            guard !starts.isEmpty else { return }
            let total = max(current.text.count, 1)
            current.marks = starts.map { .init(step: $0.step, at: current.text.isEmpty ? 0 : Double($0.offset) / Double(total)) }
            pieces.append(current)
            current = SpeechPiece(text: "")
            starts = []
        }
        for (index, raw) in steps.enumerated() {
            let step = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !starts.isEmpty, index == 1 || current.text.count + 1 + step.count > groupLimit { flush() }
            let offset = current.text.isEmpty ? 0 : current.text.count + 1
            starts.append((index, offset))
            if !step.isEmpty { current.text = current.text.isEmpty ? step : current.text + " " + step }
        }
        flush()
        return pieces
    }
}

extension VoiceReplyText {
    /// Sentences that just became ready while an answer is being written.
    /// The very first piece of an answer stays short so the voice starts at
    /// once; sentences that arrive together are joined (up to `limit`
    /// characters) so there are fewer requests and joins.
    static func groupLive(_ ready: [String], firstPiece: Bool, limit: Int = 320) -> [String] {
        var pieces: [String] = []
        var current = ""
        for (index, sentence) in ready.enumerated() {
            if firstPiece && index == 0 { pieces.append(sentence); continue }
            if current.isEmpty { current = sentence }
            else if current.count + 1 + sentence.count <= limit { current += " " + sentence }
            else { pieces.append(current); current = sentence }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
