import Foundation

/// Text helpers used ONLY to decide where a request goes. Nothing here is
/// ever applied to the text sent to the answer model: callers always pass
/// the user's original words on unchanged.
enum RoutingText {

    // MARK: Filler words

    /// Spoken fillers per language. Whole-word (or whole-token) matches only.
    /// "like" and "so" are only fillers in certain positions, see `stripFillers`.
    static let fillers: [String] = [
        // English
        "uh", "uhh", "uhm", "um", "umm", "erm", "hmm", "hm", "mm", "ah", "eh", "you know", "i mean",
        // Spanish
        "o sea", "eh", "ehm", "bueno", "pues",
        // German
        "äh", "ähm", "öhm", "naja", "halt",
        // French
        "euh", "ben", "bah", "du coup", "genre",
        // Portuguese
        "tipo", "né", "hum", "tá",
        // Italian
        "ehm", "cioè", "beh", "mah",
        // Dutch
        "eh", "uhm", "nou", "zeg maar",
        // Hindi / Hinglish
        "matlab", "yaar", "accha", "achha", "haan", "मतलब", "यार", "अच्छा",
        // Japanese (unspaced; removed as substrings)
        "えっと", "えーと", "えー", "あのー", "あの", "まあ", "なんか", "うーん", "ええと"
    ]

    /// Words that are fillers only at the very start of a clause.
    static let leadingFillers: [String] = [
        "so", "well", "okay", "ok", "like", "and", "then", "anyway",
        "also", "dann", "na", "alors", "donc", "bon", "então", "entao", "aí", "allora", "quindi", "dus",
        "entonces", "toh", "तो"
    ]

    /// The request with spoken fillers removed, for routing decisions only.
    static func stripFillers(_ text: String) -> String {
        var value = " " + text + " "
        // Japanese and other unspaced fillers: plain substring removal.
        for filler in fillers where ToolGateText.isUnspaced(filler) {
            value = value.replacingOccurrences(of: filler, with: " ")
        }
        // "like" between commas (", like,") is a filler; "I like it" is not.
        value = value.replacingOccurrences(of: #"(?i),\s*like\s*,"#, with: ",", options: .regularExpression)
        for filler in fillers where !ToolGateText.isUnspaced(filler) {
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            // Whole words, optionally followed by a comma or dots ("uh," "um…").
            let pattern = #"(?i)(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])[,.…]*"#
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"^[\s,.;:…、。]+"#, with: "", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Clauses

    /// Words that start a new clause in running speech ("…so write a mail",
    /// "…and then fix it", "…pues escribe", "…also schreib", "…toh likho").
    static let clauseConnectors: [String] = [
        // English
        "so", "and then", "then", "and", "but", "now", "okay", "ok", "please", "anyway", "just",
        // Spanish
        "así que", "asi que", "entonces", "y luego", "luego", "pero", "por favor", "pues",
        // German
        "also", "und dann", "dann", "aber", "bitte", "deshalb",
        // French
        "alors", "donc", "et puis", "puis", "mais", "s il te plaît", "s il vous plaît",
        // Portuguese
        "então", "entao", "e aí", "aí", "daí", "mas", "por favor",
        // Italian
        "quindi", "allora", "e poi", "poi", "ma", "per favore",
        // Dutch
        "dus", "en dan", "dan", "maar", "alsjeblieft",
        // Hindi / Hinglish
        "toh", "aur", "phir", "fir", "तो", "और", "फिर"
    ]

    /// Splits a request into clauses at punctuation and spoken connectors.
    /// The connector itself is dropped, so each clause starts with what the
    /// speaker actually asked for ("write a mail of resignation to my HR").
    static func clauses(_ text: String) -> [String] {
        let cleaned = stripFillers(text)
        // Sentence punctuation in every script.
        let pieces = cleaned.components(separatedBy: CharacterSet(charactersIn: ".!?;:,…。、！？；\n"))
        var result: [String] = []
        let connectors = clauseConnectors.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let splitter = try? NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{N}])(?:"# + connectors + #")(?![\p{L}\p{N}])"#)
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let splitter else { result.append(trimmed); continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            var last = trimmed.startIndex
            for match in splitter.matches(in: trimmed, range: range) {
                guard let matchRange = Range(match.range, in: trimmed) else { continue }
                let before = trimmed[last..<matchRange.lowerBound].trimmingCharacters(in: .whitespaces)
                if !before.isEmpty { result.append(before) }
                last = matchRange.upperBound
            }
            let tail = trimmed[last...].trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { result.append(tail) }
        }
        return result.map(stripLeadingFillers).filter { !$0.isEmpty }
    }

    static func stripLeadingFillers(_ clause: String) -> String {
        var words = clause.split(separator: " ").map(String.init)
        while let first = words.first,
              leadingFillers.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }

    // MARK: Negation

    /// "I can't write today", "don't write anything", "no quiero escribir",
    /// "ich will nicht schreiben": the clause talks about NOT doing the task.
    static func isNegated(_ clause: String) -> Bool {
        let text = " " + ToolGateText.fold(clause) + " "
        let markers = [" can t ", " cant ", " cannot ", " don t ", " dont ", " do not ", " won t ", " wont ", " never ",
                       " didn t ", " didnt ", " not ", " no ", " nicht ", " kein ", " keine ", " pas ", " non ",
                       " nao ", " niet ", " geen ", " nahi ", " nahin ", " mat ", " नहीं ", " मत ", "ない ", "ません"]
        return markers.contains(where: text.contains)
    }

    /// Word count after removing fillers (for "long, rambling" decisions).
    static func wordCount(_ text: String) -> Int {
        let stripped = stripFillers(text)
        if ToolGateText.isUnspaced(stripped) { return max(1, stripped.count / 3) }
        return stripped.split(whereSeparator: { $0.isWhitespace }).count
    }
}
