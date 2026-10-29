import Foundation

enum BibblesIntent: Equatable {
    case dictate
    case screen(question: String)
    case search(query: String)
    case chat(message: String)
}

struct IntentRouter {
    /// How sure the keyword rules were. Only the hybrid router (developer
    /// toggle) reads this; `route` returns exactly the same intent as before.
    enum Strength: String, Equatable {
        /// An anchored rule matched ("write …" at the start, "open Safari",
        /// a live-info word): trust it.
        case strong
        /// An incidental word matched ("here", "this app", "export"): right
        /// for short requests, unreliable in long rambling speech.
        case weak
        /// Nothing matched; today this falls through to plain chat.
        case none
    }

    func route(transcript: String, mode: SpeechMode) -> BibblesIntent {
        decide(transcript: transcript, mode: mode).intent
    }

    /// The same decision as `route`, plus how it was reached.
    func decide(transcript: String, mode: SpeechMode) -> (intent: BibblesIntent, strength: Strength) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        func strong(_ intent: BibblesIntent) -> (intent: BibblesIntent, strength: Strength) { (intent, .strong) }
        func weak(_ intent: BibblesIntent) -> (intent: BibblesIntent, strength: Strength) { (intent, .weak) }
        if mode == .dictation { return strong(.dictate) }
        if LockScreenCommand.isRequest(text) { return strong(.chat(message: text)) }
        if MusicRequest.isRequest(text) { return strong(.chat(message: text)) }

        let normalized = text.lowercased()
        // "Search for the Microsoft folder" means on screen / on the Mac, not the web.
        if Self.isLocateRequest(text), !Self.isMacWideSearch(text),
           Self.mentionsFileItem(text) || Self.refersToVisibleScreen(text),
           !normalized.hasPrefix("search online"), !normalized.hasPrefix("web search"), !normalized.hasPrefix("online") {
            return strong(.screen(question: text))
        }
        // "Search my Mac for my resume", "search for the PDF I downloaded
        // yesterday": a file search on the Mac, not the web.
        if normalized.hasPrefix("search"), !Self.asksForTheWeb(normalized), isCommandRequest(text),
           Self.isMacWideSearch(text) || normalized.range(of: #"\b(?:my|mine|i)\b"#, options: .regularExpression) != nil {
            return strong(.chat(message: text))
        }
        if Self.searchSignals.contains(where: normalized.hasPrefix) {
            let query = Self.searchSignals
                .first(where: normalized.hasPrefix)
                .map { String(text.dropFirst($0.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? text
            return strong(.search(query: query.isEmpty ? text : query))
        }
        if shouldUseFocusedText(for: text) {
            return strong(.chat(message: text))
        }
        // "Where is X", "find X", "X kahan hai", "can you see X": look at the
        // screen first (Bibbles searches the Mac if X isn't visible).
        if Self.isLocateRequest(text), !Self.isMacWideSearch(text), !isFileRequest(text) {
            return strong(.screen(question: text))
        }
        if isFixRequest(text) || isCommandRequest(text) || isActionRequest(text) {
            return strong(.chat(message: text))
        }
        // Weather, prices, scores, news: answers that change, so search the
        // web even without the word "search".
        if Self.needsLiveInfo(text) {
            return strong(.search(query: text))
        }
        if SimpleDrawingCommand.parse(text) != nil || SimpleDrawingCommand.requiresGrounding(text) {
            return strong(.screen(question: text))
        }
        if Self.screenSignals.contains(where: normalized.contains) {
            return Self.isStrongScreenSignal(normalized) ? strong(.screen(question: text)) : weak(.screen(question: text))
        }
        if isTruncatedScreenQuestion(text) {
            return strong(.screen(question: text))
        }
        // "How do I … in this app / on my Mac": a step-by-step guide on screen.
        if ScreenQuestionKind.isHowTo(normalized),
           Self.guideContextSignals.contains(where: {
               normalized.range(of: "\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b", options: .regularExpression) != nil
           }) {
            return RoutingText.wordCount(text) <= 14 ? strong(.screen(question: text)) : weak(.screen(question: text))
        }
        // Tool Gate (multilingual): the same screen / live-info / weather
        // routes for requests in other languages. Off → nil, today's route.
        // Multilingual keyword hints are only hints ("infos" also appears in
        // "mes infos"); the hybrid router double-checks them.
        switch ToolGate.routeHint(for: text) {
        case .screen?: return weak(.screen(question: text))
        case .search?, .weather?: return weak(.search(query: text))
        default: return (.chat(message: text), .none)
        }
    }

    func shouldUseFocusedText(for transcript: String) -> Bool {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.focusedTextSignals.contains(where: normalized.contains)
    }

    /// Requests such as "write a resignation mail", "draft a reply here" or
    /// "email likho": the answer should be typed into the user's app.
    func isWriteRequest(_ transcript: String) -> Bool {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !shouldUseFocusedText(for: normalized) else { return false }
        let english = #"^(?:(?:hey )?bibbles[, ]+)?(?:(?:can|could|would|will) you )?(?:please )?(?:write|draft|compose|type|reply|respond)\b(?! of\b)"#
        if normalized.range(of: english, options: .regularExpression) != nil { return true }
        if Self.hinglishWriteSignals.contains(where: normalized.contains) { return true }
        // Tool Gate: "schreib eine E-Mail", "écris un mail", "ईमेल लिखो".
        return ToolGate.isEnabled && ToolGate.isWriteRequest(transcript)
    }

    /// Requests that fill a box in the user's app, such as "mail is hr@x.com",
    /// "subject is leave request" or "send it to my manager".
    func isFillRequest(_ transcript: String) -> Bool {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let pattern = #"^(?:(?:hey )?bibbles[, ]+)?(?:please )?(?:fill\b|(?:the )?recipients? (?:is|are|should be)\b|send (?:it |this |the mail |the email )?to\b|address it to\b|(?:the |my )?(?:e-?mail|mail)(?: id| address)? (?:is|should be)\b|to (?:is|should be)\b|(?:the )?subject (?:is|should be|line is)\b|(?:make|change|set|update) the (?:subject|recipient|to|body|message)\b|(?:add )?b?cc\b)"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    /// Requests to create a folder or rename a file/folder, e.g. "create a
    /// folder named Mohit on my desktop" or "Mohit naam ka folder banao".
    func isFileRequest(_ transcript: String) -> Bool {
        let normalized = transcript.lowercased()
            .replacingOccurrences(of: #"[,.!?;]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let english = #"^(?:hey )?(?:bibbles )?(?:(?:can|could|would|will) (?:you|u) )?(?:please )?(?:(?:create|make|add|build)\b.*\b(?:folder|directory)\b|(?:rename|change the name of)\b)"#
        if normalized.range(of: english, options: .regularExpression) != nil { return true }
        return ["folder bana", "folder banao", "folder bana do", "naam badal", "naam change", "rename kar", "rename karo"]
            .contains(where: normalized.contains)
    }

    /// Mac commands Bibbles can carry out: open apps/websites/folders, find
    /// files, reminders and calendar events, volume, brightness, dark mode,
    /// and folder create/rename.
    func isCommandRequest(_ transcript: String) -> Bool {
        if MusicRequest.isRequest(transcript) { return true }
        if LockScreenCommand.isRequest(transcript) { return true }
        if isFileRequest(transcript) { return true }
        // "Find X on my screen" means look at the screen, not search the Mac.
        if Self.refersToVisibleScreen(transcript) { return false }
        let normalized = transcript.lowercased()
            .replacingOccurrences(of: #"[,.!?;]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let prefix = #"^(?:hey )?(?:bibbles )?(?:(?:can|could|would|will) (?:you|u) )?(?:please )?(?:just )?"#
        let patterns = [
            // open / launch (not "open this" or "open that", which are about the screen)
            #"(?:open|launch|start up|fire up)\b(?! (?:this|that|it)\b)"#,
            #"(?:go to|visit|take me to)\b"#,
            // find files
            #"(?:find|search for|look for|search my mac for)\b.*\b(?:files?|pdfs?|documents?|docs?|resume|cv|photos?|images?|pictures?|screenshots?|videos?|songs?|folders?|presentations?|spreadsheets?|downloads?|downloaded)\b"#,
            // reminders and calendar
            #"(?:remind me|set (?:a |an )?reminder|add (?:a |an )?reminder|create (?:a |an )?reminder|new reminder)\b"#,
            #"(?:schedule|book|add|create|put|set up)\b.*\b(?:meeting|event|appointment|call|calendar)\b"#,
            // volume, brightness, dark mode
            #"(?:set|turn|increase|decrease|raise|lower|reduce|change|make|put|switch|enable|disable)\b.*\b(?:volume|sound|brightness|dark mode|light mode)\b"#,
            #"(?:mute|unmute|volume|brightness|dark mode|light mode)\b"#,
            #"(?:make|turn) (?:the )?(?:screen|display) (?:brighter|dimmer|darker)\b"#
        ]
        if patterns.contains(where: { normalized.range(of: prefix + $0, options: .regularExpression) != nil }) {
            return true
        }
        let hinglish = ["kholo", "khol do", "khol de", "yaad dila", "reminder laga", "reminder set kar",
                        "volume badha", "volume kam", "awaaz badha", "awaaz kam", "brightness badha", "brightness kam",
                        "dark mode on", "dark mode off", "dhundo", "dhoondo", "dhund do", "meeting laga", "meeting set kar"]
        return hinglish.contains(where: normalized.contains)
    }

    /// Write requests whose content is on screen: "answer this question",
    /// "reply to this email", "fix this code which you can see".
    static func refersToScreenContent(_ transcript: String) -> Bool {
        let text = transcript.lowercased()
        if refersToVisibleScreen(text) { return true }
        return ["this question", "these questions", "the question", "this problem", "this code", "this error",
                "this email", "this mail", "this message", "this task", "this assignment", "this exercise",
                "you're seeing", "you are seeing", "is question", "iska answer", "iska jawab", "is sawal"]
            .contains(where: text.contains)
    }

    /// Asking where something is, in any wording: "where is the Microsoft
    /// folder", "find Microsoft folder", "Microsoft folder on my screen",
    /// "can you see it", "Microsoft folder kahan hai", "how do I find …".
    static func isLocateRequest(_ transcript: String) -> Bool {
        let text = transcript.lowercased()
            .replacingOccurrences(of: #"[,.!?;:]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let prefix = #"^(?:hey |hi |ok )?(?:bibbles )?(?:(?:can|could|would|will) (?:you|u) )?(?:please )?(?:just )?(?:help me )?"#
        // Always about a place: "where is …", "can you see …", "kahan hai".
        let wherePattern = prefix + #"(?:where(?: is| are|'s|s)|tell me where|show me where|(?:do|can|could) (?:you|u) see)\b"#
        if text.range(of: wherePattern, options: .regularExpression) != nil { return true }
        if ["kahan hai", "kaha hai", "kidhar hai", "kahan pe", "kaha pe", "kahan par", "dikh raha", "dikh rahi",
            "dikhta hai", "dhundo", "dhoondo", "dhund do", "dhoond do"].contains(where: text.contains) { return true }
        // "Find / locate / show me X": only when X is a thing you can see
        // (not "find the derivative of x²").
        let findPattern = prefix + #"(?:find|locate|spot|show me|point (?:to|at|me to)|search for|look for|how (?:do|can|would|should) i (?:find|locate))\b"#
        guard text.range(of: findPattern, options: .regularExpression) != nil else { return false }
        return refersToVisibleScreen(text) || text.contains("\"") || text.contains("“")
            || text.range(of: #"\b(?:folders?|files?|documents?|docs?|pdfs?|photos?|pictures?|images?|videos?|songs?|resume|cv|screenshots?|presentations?|spreadsheets?|apps?|icons?|buttons?|tabs?|windows?|menus?|options?|settings?|links?|emails?|mails?|messages?|logo|toggle|switch|checkbox|field|box|cursor|pointer)\b"#,
                          options: .regularExpression) != nil
    }

    /// The thing asked about is a file or folder, so it can be searched for
    /// on the Mac when it isn't on screen.
    static func mentionsFileItem(_ transcript: String) -> Bool {
        transcript.lowercased().range(of: #"\b(?:folders?|files?|documents?|docs?|pdfs?|photos?|pictures?|images?|videos?|songs?|resume|cv|screenshots?|presentations?|spreadsheets?|zip)\b"#,
                                      options: .regularExpression) != nil
    }

    /// Searches meant for the whole Mac, not the screen: "find PDFs I
    /// downloaded yesterday", "find all my screenshots from last week".
    static func isMacWideSearch(_ transcript: String) -> Bool {
        let text = transcript.lowercased()
        if refersToVisibleScreen(text) { return false }
        return text.range(of: #"\b(?:yesterday|today|tonight|last (?:week|month|year|night)|this (?:week|month)|recent(?:ly)?|latest|newest|days? ago|weeks? ago|all my|all the|every|on my mac|in my mac|my mac for|on my computer|on my laptop|downloaded|modified|created|saved last)\b"#,
                          options: .regularExpression) != nil
    }

    static func refersToVisibleScreen(_ transcript: String) -> Bool {
        let text = transcript.lowercased()
        return ["on my screen", "on the screen", "on screen", "on this screen", "my screen", "visible", "you can see",
                "in this window", "in the finder window", "on my display", "screen pe", "screen par", "screen mein"]
            .contains(where: text.contains)
    }

    /// "Fix this code", "correct my grammar", "solve these errors", "theek karo":
    /// Bibbles fixes the text in place and explains each change.
    func isFixRequest(_ transcript: String) -> Bool {
        let normalized = transcript.lowercased()
            .replacingOccurrences(of: #"[,.!?;]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if normalized.range(of: #"^(?:how|what|why|where|when|which|can you explain)\b"#, options: .regularExpression) != nil { return false }
        let english = #"^(?:hey )?(?:bibbles )?(?:(?:can|could|would|will) (?:you|u) )?(?:please )?(?:just )?(?:fix|correct|debug|proofread|repair)\b"#
        if normalized.range(of: english, options: .regularExpression) != nil { return true }
        return ["fix the error", "fix these error", "fix this error", "fix my code", "fix the code", "fix this code",
                "resolve the error", "resolve this error", "solve the error", "solve this error", "solve these error",
                "correct the grammar", "correct my grammar", "spelling mistake", "grammar mistake",
                "theek karo", "theek kar do", "thik karo", "thik kar do", "sahi karo", "sahi kar do", "galti theek", "error hatao"]
            .contains(where: normalized.contains)
    }

    /// Write or fill requests: Bibbles performs them in the user's app
    /// instead of typing the spoken words.
    func isActionRequest(_ transcript: String) -> Bool {
        isFixRequest(transcript) || isWriteRequest(transcript) || isFillRequest(transcript)
    }

    func shouldUseScreenOverview(for question: String) -> Bool {
        let kind = ScreenQuestionKind.classify(question)
        if kind == .chartCandle { return false }
        if kind.prefersDisplayOverview { return true }
        let normalized = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.screenOverviewSignals.contains(where: normalized.contains)
            || isTruncatedScreenQuestion(question)
    }

    private func isTruncatedScreenQuestion(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return Self.truncatedScreenQuestionEndings.contains(where: normalized.hasSuffix)
    }

    /// Screen words that mean only "in the app I'm using" ("write a mail to my
    /// HR here"). Note `screenSignals` match substrings, so "there" also
    /// contains "here".
    static let hereWords: Set<String> = ["here", "yahan"]

    /// Always on (not behind a toggle): "here" alone must not start screen
    /// help when a text box is focused or the request clearly asks to write.
    /// Returns the intent to use instead, or nil to keep `decided`.
    static func hereScreenCorrection(for text: String, decided: (intent: BibblesIntent, strength: Strength),
                                     textFieldFocused: Bool) -> BibblesIntent? {
        guard case .screen = decided.intent, decided.strength == .weak else { return nil }
        let normalized = text.lowercased()
        let matched = screenSignals.filter { normalized.contains($0) }
        guard !matched.isEmpty, matched.allSatisfy({ hereWords.contains($0) }) else { return nil }
        guard textFieldFocused || clearlyAsksToWrite(text) else { return nil }
        return .chat(message: text)
    }

    /// "…so write a mail of resignation to my HR here", "can you draft a reply
    /// to him": a write verb followed closely by something to write, anywhere
    /// in the request. Not questions ("how do I write…") and not negations
    /// ("I can't write the mail today").
    static func clearlyAsksToWrite(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[,.!?;:…]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if normalized.range(of: #"^(?:how|what|why|when|where|should|can i|could i|do i)\b"#, options: .regularExpression) != nil { return false }
        let verb = #"(?:write|draft|compose|type up|type out|put together|prepare)"#
        let negated = #"\b(?:can't|cant|cannot|can not|don't|dont|do not|won't|wont|never|not|didn't|didnt)\s+(?:\S+\s+){0,2}"# + verb + #"\b"#
        if normalized.range(of: negated, options: .regularExpression) != nil { return false }
        let things = #"(?:mail|email|e-mail|message|letter|reply|note|post|text|response|application|resignation|cover letter|caption|comment|tweet|story|essay|bio)s?"#
        let english = #"\b"# + verb + #"\b(?:\s+\S+){0,4}?\s+"# + things + #"\b"#
        if normalized.range(of: english, options: .regularExpression) != nil { return true }
        let hinglish = #"\b(?:mail|email|message|letter|application|reply)\b(?:\s+\S+){0,2}\s+(?:likh|likho|likh do|likh de|bana do|draft karo|type karo)\b"#
        return normalized.range(of: hinglish, options: .regularExpression) != nil
    }

    /// Screen words that are only weak hints: they also appear in ordinary
    /// requests ("write a mail to my HR here", "export the file").
    private static let weakScreenSignals: Set<String> = [
        "here", "yahan", "isko", "export", "save as", "this app", "this page", "the display", "my display",
        "suits my", "download button"
    ]

    /// A screen word matched: strong when the request is short or the word is
    /// unmistakably about the screen ("what is this", "my screen").
    static func isStrongScreenSignal(_ normalized: String) -> Bool {
        let matched = screenSignals.filter { normalized.contains($0) }
        let onlyWeak = !matched.isEmpty && matched.allSatisfy { weakScreenSignals.contains($0) }
        if onlyWeak { return false }
        return RoutingText.wordCount(normalized) <= 14
    }

    private static let screenSignals = [
        "this screen", "my screen", "the screen", "on screen", "here", "this button", "this error",
        "where is", "where's", "where are", "kahan hai", "kaha hai", "kidhar hai", "kahan pe",
        "i have opened", "i've opened", "i opened", "i have open", "currently open", "is open on", "opened on my",
        "suits my", "on my mac screen", "maine khola", "khula hai",
        "you're seeing", "you are seeing", "you can see", "can you see", "do you see", "what you see",
        "this page", "this window", "this app", "this website", "this image", "this picture", "this chart",
        "my display", "the display",
        "what is this", "what's this", "explain this", "what am i looking at",
        "what is on my screen", "something on screen",
        "ye screen", "iss screen", "screen pe", "ye button", "yahan", "isko",
        "iss error", "ye kya hai", "ye kya", "isko dekho",
        "candle", "candlestick", "wick", "ohlc", "trading chart", "price bar",
        "export", "download button", "save as", "where is the", "where's the",
        "circle this", "circle that", "underline this", "underline that", "point to", "arrow to", "highlight this"
    ]
    private static let guideContextSignals = [
        "this", "here", "screen", "app", "apps", "window", "page", "tab", "button", "menu", "settings", "setting", "mac", "macbook",
        "finder", "file", "files", "folder", "document", "browser", "chrome", "safari", "brave", "website", "site",
        "gmail", "mail", "outlook", "notes", "excel", "word", "sheet", "slide", "zoom", "whatsapp", "slack",
        "tradingview", "chart", "photo", "ye", "isme", "is app", "yahan"
    ]
    private static let screenOverviewSignals = [
        "this screen", "my screen", "the screen", "on screen",
        "ye screen", "iss screen", "screen pe", "whole screen", "entire screen"
    ]
    private static let truncatedScreenQuestionEndings = [
        "what is up on my", "what's up on my", "what’s up on my",
        "what is on my", "what's on my", "what’s on my"
    ]
    /// Questions whose answer changes over time: weather, prices and rates,
    /// scores and results, news. Not questions about the screen or the Mac.
    static func needsLiveInfo(_ transcript: String) -> Bool {
        let text = transcript.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if refersToVisibleScreen(text) { return false }
        let local = #"\b(?:this|these|here|isko|iska|iske|ye|yeh|my mac|my files?|cpu|gpu|battery|macbook|laptop|candle|temp folder|temp files?)\b"#
        if text.range(of: local, options: .regularExpression) != nil { return false }
        let live = #"\b(?:weather|temperature|temp|forecast|mausam|humidity|aqi|air quality|raining|barish|baarish|news|headlines?|khabar|samachar|who won|kaun jeeta|kisne jeeta|live score|score of|match score|match result|results? of|election results?|stock price|share price|stock market|sensex|nifty|bitcoin|btc|ethereum|crypto price|exchange rate|dollar rate|usd to inr|inr to usd|euro to inr|gold rate|gold price|silver rate|silver price|petrol price|diesel price|price of|price in india|price today|rate today|trending|box office)\b"#
        return text.range(of: live, options: .regularExpression) != nil
    }

    /// "search online …", "search the web for …", "google …".
    static func asksForTheWeb(_ normalized: String) -> Bool {
        ["search online", "search the web", "search the internet", "search on google", "search google",
         "web search", "online", "google "].contains(where: normalized.hasPrefix)
            || normalized.contains(" online") || normalized.contains(" on the web") || normalized.contains(" on google")
    }

    private static let searchSignals = [
        "search the web for ", "search online for ", "search for ",
        "search ", "look up ", "find online ", "web search ",
        "search karo ", "online dhundo "
    ]
    private static let hinglishWriteSignals = [
        "likho", "likh do", "likh de", "likh ke do", "type karo", "type kar do", "draft karo", "draft kar do"
    ]
    private static let focusedTextSignals = [
        "selected text", "this selection", "rewrite this", "edit this",
        "highlighted", "i highlighted", "i have highlighted", "i've highlighted", "the highlight",
        "what i selected", "i have selected", "i've selected", "the selection", "my selection",
        "this text", "this paragraph", "this passage", "this sentence", "this line", "these lines",
        "this story", "this article", "this code", "this poem",
        "translate this", "ye para", "ye paragraph", "ye line", "jo select", "jo highlight",
        "summarize this", "explain this text", "explain the selection",
        "explain selected", "fix this writing", "simplify this text",
        "ye text", "isko rewrite", "isko summarize", "isko explain",
        "isko simple explain", "selection ko"
    ]
}

enum SpeechMode: Equatable {
    case command
    case dictation
}

enum SimpleDrawingCommand: String, Equatable {
    case triangle, circle, rectangle, arrow, line, underline, star, clear, undo
    case spotlight, house, sun, cube
    case happyFace = "happy face", sadFace = "sad face", surprisedFace = "surprised face"

    var shape: DoodleShape? { DoodleShape(rawValue: rawValue) }

    static func requiresGrounding(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = #"^(?:(?:can|could|would) you )?(?:please )?(?:draw|sketch|circle|underline|highlight|point)\b"#
        return value.range(of: prefix, options: .regularExpression) != nil
            && ["around", "this", "that", " to ", "chart", "pattern"].contains(where: value.contains)
    }

    static func parse(_ text: String) -> SimpleDrawingCommand? {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if ["clear drawings", "clear the drawings", "clear doodles", "clear annotations", "erase drawings", "erase all drawings"].contains(normalized) { return .clear }
        if ["undo drawing", "undo the drawing", "undo last drawing", "undo last doodle"].contains(normalized) { return .undo }
        // A complete command grammar keeps requests like 'draw an arrow to
        // Export' on the vision path and 'how do I draw' in conversation.
        let pattern = #"^(?:(?:hey bibbles|bibbles)[, ]+)?(?:(?:can|could|would) you )?(?:please )?(?:draw|sketch|make) (?:me )?(?:a |an )?(?:(teal|green|cyan|blue|coral|red|pink|violet|purple|amber|yellow|orange) )?(triangle|circle|rectangle|box|arrow|line|underline|star|spotlight|house|sun|cube|happy face|sad face|surprised face|face|smiley face)(?: (?:here|center-screen|top-right-quadrant|at the center of the screen|on (?:my |the )?screen|by (?:my |the )?(?:pointer|cursor)|near (?:my |the )?(?:pointer|cursor)))?(?: in (?:teal|green|cyan|blue|coral|red|pink|violet|purple|amber|yellow|orange))?(?: please)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let range = Range(match.range(at: 2), in: normalized) else { return nil }
        let shape = String(normalized[range])
        if shape == "face" || shape == "smiley face" { return .happyFace }
        return SimpleDrawingCommand(rawValue: shape == "box" ? "rectangle" : shape)
    }
}
