import Foundation

/// Small, deterministic answers for facts the app already knows. Avoids a
/// network round trip and prevents the model inventing Bibbles' identity.
enum LocalQuickAnswer {
    /// `multilingual`: also answer time/date questions in other languages
    /// (on while the Tool Gate is on).
    static func answer(for input: String, now: Date = Date(), timeZone: TimeZone = .current,
                       multilingual: Bool? = nil) -> String? {
        let text = input.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let question = text.replacingOccurrences(of: #"^(hey|hi|hello) bibbles "#, with: "", options: .regularExpression)

        if isLocalClockQuestion(question) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            formatter.timeZone = timeZone
            formatter.locale = Locale(identifier: "en_US")
            let zone = timeZone.abbreviation(for: now) ?? timeZone.identifier
            return "It's \(formatter.string(from: now)) \(zone)."
        }
        if let place = Self.placeInTimeQuestion(question), let zone = Self.timeZone(forPlace: place) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            formatter.timeZone = zone
            formatter.locale = Locale(identifier: "en_US")
            let day = DateFormatter()
            day.dateFormat = "EEEE"
            day.timeZone = zone
            day.locale = Locale(identifier: "en_US")
            let name = place.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            let zoneName = zone.abbreviation(for: now) ?? zone.identifier
            return "It's \(formatter.string(from: now)) on \(day.string(from: now)) in \(name) (\(zoneName))."
        }
        if Self.isDateQuestion(question) {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, d MMMM yyyy"
            formatter.timeZone = timeZone
            formatter.locale = Locale(identifier: "en_US")
            return "It's \(formatter.string(from: now))."
        }
        if Self.nameQuestions.contains(question) {
            return "I'm Bibbles — your quick-thinking Mac companion. Point, ask, and I'll make the screen make sense."
        }
        if Self.isDeveloperQuestion(question) {
            return BibblesIdentity.spokenAttribution
        }
        if multilingual ?? ToolGate.isEnabled {
            return MultilingualClock.answer(for: input, now: now, timeZone: timeZone)
        }
        return nil
    }

    private static func isLocalClockQuestion(_ question: String) -> Bool {
        let words = question.split(separator: " ").map(String.init)
        let tokens = Set(words)
        guard tokens.contains("time") || tokens.contains("baje") || tokens.contains("samay") else { return false }
        // Only clock requests use this path. A task-duration question or a
        // request for another city's time must not silently get local time.
        guard !question.contains("screen time") else { return false }
        let allowed: Set<String> = [
            "a", "about", "abhi", "actual", "at", "baje", "bar", "bibbles", "can", "check", "clock",
            "computer", "could", "current", "currently", "do", "exact", "from", "give", "hai", "hain",
            "hello", "hey", "hi", "hua", "is", "it", "kitna", "kitne", "kya", "local", "mac",
            "me", "menu", "moment", "my", "now", "on", "please", "read", "real", "right", "s",
            "samay", "screen", "show", "tell", "the", "this", "time", "top", "what", "you",
            "ho", "raha", "rahe", "baj", "batao", "bata"
        ]
        return tokens.isSubset(of: allowed)
    }

    /// "What's today's date", "what is the date today", "aaj kya tarikh hai".
    private static func isDateQuestion(_ question: String) -> Bool {
        if dateQuestions.contains(question) { return true }
        let tokens = Set(question.split(separator: " ").map(String.init))
        guard !tokens.isDisjoint(with: ["date", "day", "din", "tarikh", "tareekh", "taarikh"]) else { return false }
        let allowed: Set<String> = [
            "a", "aaj", "aj", "bata", "batao", "bibbles", "current", "currently", "date", "day", "de", "do", "din",
            "exact", "give", "hai", "hello", "hey", "hi", "is", "it", "ka", "kaun", "kaunsa", "ki", "kya", "me",
            "now", "of", "please", "right", "s", "sa", "tarikh", "tareekh", "taarikh", "tell", "the", "today",
            "todays", "what", "whats", "which", "week"
        ]
        return tokens.isSubset(of: allowed)
    }

    /// The place in "what time is it in London" or "Dubai mein kitne baje hain".
    private static func placeInTimeQuestion(_ question: String) -> String? {
        let clockWords: Set<String> = [
            "a", "abhi", "baj", "baje", "bata", "batao", "can", "current", "currently", "do", "exact", "hai", "hain",
            "ho", "hua", "is", "it", "kitna", "kitne", "kya", "local", "me", "now", "please", "raha", "rahe", "right",
            "s", "samay", "tell", "the", "time", "what", "whats", "you"
        ]
        func cleanPlace(_ raw: Substring) -> String? {
            var words = raw.split(separator: " ").map(String.init)
            while let last = words.last, ["now", "right", "currently", "abhi"].contains(last) { words.removeLast() }
            return (1...3).contains(words.count) ? words.joined(separator: " ") : nil
        }
        if let range = question.range(of: " in ", options: .backwards) {
            let prefix = Set(question[..<range.lowerBound].split(separator: " ").map(String.init))
            if prefix.contains("time"), prefix.isSubset(of: clockWords) {
                return cleanPlace(question[range.upperBound...])
            }
        }
        for separator in [" mein ", " me ", " mai "] {
            if let range = question.range(of: separator) {
                let suffix = Set(question[range.upperBound...].split(separator: " ").map(String.init))
                if !suffix.isDisjoint(with: ["time", "baje", "baj", "samay"]), suffix.isSubset(of: clockWords) {
                    return cleanPlace(question[..<range.lowerBound])
                }
            }
        }
        return nil
    }

    static func timeZone(forPlace place: String) -> TimeZone? {
        if let identifier = placeZones[place] { return TimeZone(identifier: identifier) }
        let match = TimeZone.knownTimeZoneIdentifiers.first { identifier in
            identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ").lowercased() } == place
        }
        return match.flatMap(TimeZone.init(identifier:))
    }

    private static let placeZones: [String: String] = {
        var zones: [String: String] = [:]
        let groups: [String: [String]] = [
            "Asia/Kolkata": ["india", "delhi", "new delhi", "mumbai", "bombay", "bangalore", "bengaluru", "chennai",
                             "hyderabad", "pune", "ahmedabad", "jaipur", "lucknow", "chandigarh", "goa", "noida", "gurgaon", "gurugram"],
            "Asia/Dubai": ["dubai", "uae", "abu dhabi"],
            "Europe/London": ["london", "uk", "england", "britain", "united kingdom"],
            "America/New_York": ["new york", "nyc", "new york city", "washington", "boston", "miami"],
            "America/Los_Angeles": ["california", "san francisco", "sf", "los angeles", "la", "seattle", "silicon valley"],
            "America/Chicago": ["chicago", "texas", "dallas", "houston"],
            "America/Toronto": ["toronto", "canada"],
            "Australia/Sydney": ["sydney", "australia", "melbourne"],
            "Asia/Singapore": ["singapore"],
            "Asia/Tokyo": ["tokyo", "japan"],
            "Asia/Shanghai": ["china", "beijing", "shanghai"],
            "Asia/Hong_Kong": ["hong kong"],
            "Europe/Paris": ["paris", "france"],
            "Europe/Berlin": ["berlin", "germany"],
            "Europe/Moscow": ["moscow", "russia"],
            "Asia/Karachi": ["pakistan", "karachi", "lahore", "islamabad"],
            "Asia/Dhaka": ["bangladesh", "dhaka"],
            "Asia/Kathmandu": ["nepal", "kathmandu"],
            "Asia/Colombo": ["sri lanka", "colombo"],
            "Asia/Riyadh": ["saudi", "saudi arabia", "riyadh"],
            "Asia/Qatar": ["qatar", "doha"]
        ]
        for (identifier, places) in groups { for place in places { zones[place] = identifier } }
        return zones
    }()
    private static let dateQuestions: Set<String> = [
        "what s the date", "what is the date", "what date is it", "what day is it", "today s date",
        "aaj kya date hai", "aaj kaun sa din hai"
    ]
    private static let nameQuestions: Set<String> = [
        "what s your name", "what is your name", "who are you", "tell me your name",
        "tumhara naam kya hai", "aapka naam kya hai", "who is bibbles"
    ]
    private static func isDeveloperQuestion(_ question: String) -> Bool {
        var request = question
        for prefix in ["can you tell me ", "could you tell me ", "please tell me ", "tell me "] {
            if request.hasPrefix(prefix) { request.removeFirst(prefix.count); break }
        }
        return developerQuestions.contains(request)
    }

    private static let developerQuestions: Set<String> = [
        "who made you", "who built you", "who developed you", "who is your developer",
        "who s your developer", "who is your creator", "who created you", "who designed you",
        "who created bibbles", "who made bibbles", "who built bibbles", "who developed bibbles",
        "who is bibbles developer", "who is the developer of bibbles", "who is the creator of bibbles",
        "tumhe kisne banaya", "kisne tumhe banaya", "bibbles kisne banaya",
        "bibbles ka developer kaun hai"
    ]
}

/// Time, date and world-time questions in every language the Tool Gate
/// knows ("wie spät ist es in Tokio", "qué hora es", "टोक्यो में कितने बजे हैं"),
/// answered on the Mac in the user's language and date format. Returns nil
/// whenever it isn't sure, so the question goes to the AI instead.
enum MultilingualClock {
    static func answer(for input: String, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        let language = ToolGate.detectLanguage(input)
        // English and Hinglish keep their original rules above.
        if ["en", "hinglish"].contains(language.code), language.confidence >= 0.6 { return nil }
        let padded = ToolGateText.padded(input)
        let words = padded.split(separator: " ")
        guard !words.isEmpty, words.count <= 10 else { return nil }
        let code = language.answerLanguage
        let locale = Locale(identifier: code == "und" ? Locale.current.identifier : code)

        if ToolGate.matches(ToolGateLexicon.dateQuestion, in: padded, language: language) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateStyle = .full
            formatter.timeStyle = .none
            return ToolGateStrings.today(formatter.string(from: now), language: code)
        }

        guard let phrase = matchedPhrase(ToolGateLexicon.timeQuestion, in: padded, language: language) else { return nil }
        let rest = remainder(of: input, without: phrase)
        let time = DateFormatter()
        time.locale = locale
        time.timeStyle = .short
        time.dateStyle = .none
        guard !rest.folded.isEmpty else {
            time.timeZone = timeZone
            return ToolGateStrings.localTime(time.string(from: now), zone: timeZone.abbreviation(for: now) ?? timeZone.identifier,
                                             language: code)
        }
        guard (1...3).contains(rest.folded.count),
              let zone = zone(for: rest.folded.joined(separator: " ")) else { return nil }
        time.timeZone = zone
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = zone
        day.dateFormat = "EEEE"
        let place = rest.display.joined(separator: " ")
        return ToolGateStrings.placeTime(time.string(from: now), day: day.string(from: now), place: place,
                                         zone: zone.abbreviation(for: now) ?? zone.identifier, language: code)
    }

    /// The table phrase that matched, folded.
    static func matchedPhrase(_ table: [String: [String]], in padded: String, language: ToolGate.DetectedLanguage) -> String? {
        ToolGate.matchedPhrase(table, in: padded, language: language)
    }

    /// Words left once the question phrase and filler words are removed:
    /// the place, folded (for lookup) and as typed (for display).
    static func remainder(of input: String, without phrase: String) -> (folded: [String], display: [String]) {
        var text = ToolGateText.padded(input)
        var display = " " + input.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\p{M}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces) + " "
        // Remove the phrase from both copies (same word positions).
        let phraseWords = phrase.split(separator: " ").count
        if ToolGateText.isUnspaced(phrase) {
            text = text.replacingOccurrences(of: phrase, with: " ")
            display = text
        } else if let range = text.range(of: " " + phrase + " ") {
            let before = text[..<range.lowerBound].split(separator: " ").count
            var foldedWords = text.split(separator: " ").map(String.init)
            var shownWords = display.split(separator: " ").map(String.init)
            if foldedWords.count == shownWords.count {
                foldedWords.removeSubrange(before..<min(before + phraseWords, foldedWords.count))
                shownWords.removeSubrange(before..<min(before + phraseWords, shownWords.count))
                text = " " + foldedWords.joined(separator: " ") + " "
                display = " " + shownWords.joined(separator: " ") + " "
            } else {
                text = text.replacingCharacters(in: range, with: " ")
                display = text
            }
        }
        for particle in unspacedFiller { text = text.replacingOccurrences(of: particle, with: " ") }
        if display != text { for particle in unspacedFiller { display = display.replacingOccurrences(of: particle, with: " ") } }
        let foldedWords = text.split(separator: " ").map(String.init)
        let shownWords = display.split(separator: " ").map(String.init)
        var keptFolded: [String] = []
        var keptShown: [String] = []
        for (index, word) in foldedWords.enumerated() where !filler.contains(word) {
            keptFolded.append(word)
            let shown = index < shownWords.count && shownWords.count == foldedWords.count ? shownWords[index] : word
            keptShown.append(shown.prefix(1).uppercased() + shown.dropFirst())
        }
        return (keptFolded, keptShown)
    }

    static func zone(for place: String) -> TimeZone? {
        if let identifier = ToolGateLexicon.placeZones[place] { return TimeZone(identifier: identifier) }
        return LocalQuickAnswer.timeZone(forPlace: place)
    }

    /// Words around a time question that are never the place.
    static let filler: Set<String> = ToolGateLexicon.placePrepositions.union(ToolGateText.foldSet([
        "now", "right", "currently", "current", "the", "time", "is", "it", "please",
        "jetzt", "gerade", "bitte", "es", "ist", "uhr",
        "maintenant", "actuellement", "il", "est", "heure", "l",
        "ahora", "mismo", "son", "hora", "horas", "por", "favor",
        "adesso", "sono", "ora", "ore", "e",
        "agora", "sao", "são",
        "nu", "het", "is",
        "abhi", "hai", "hain", "baje", "kitne",
        "अभी", "में", "हैं", "है", "समय", "का", "की", "के",
        "şu", "an", "сейчас", "в", "الآن", "في", "teraz", "nyt", "acum", "nú", "nå", "nu"
    ]))

    /// Particles in Chinese, Japanese and Korean questions.
    static let unspacedFiller = ["ですか", "です", "今", "いま", "は", "の", "现在", "現在", "在", "是", "吗", "嗎", "了",
                                 "지금", "에서", "는", "은", "인가요", "예요", "이에요", "입니까", "요"]
}
