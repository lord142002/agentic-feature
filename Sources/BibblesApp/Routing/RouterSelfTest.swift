import Foundation

/// Developer-only checks for the hybrid router that run without XCTest
/// (Macs with only the Command Line Tools). Launch the built binary with
/// `--router-self-test [--out <file>]`. No network: every router call uses
/// a fake transport. Mirrors Tests/BibblesAppTests/HybridRouterTests.swift.
enum RouterSelfTest {
    private struct Fake: RouterTransport {
        var body = #"{"content":[{"type":"text","text":"write\",\"confidence\":0.92}"}]}"#
        var status = 200
        var delay: TimeInterval = 0
        var offline = false
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if offline { throw URLError(.notConnectedToInternet) }
            return (Data(body.utf8), status)
        }
    }

    private final class Capture: RouterTransport, @unchecked Sendable {
        var bodies: [String] = []
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            bodies.append(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
            return (Data(#"{"content":[{"type":"text","text":"simple\",\"confidence\":0.9}"}]}"#.utf8), 200)
        }
    }

    static let resignation = "I'm not liking a job where I'm working right now. So uh, I want to resign. Uh, so write a mail of resignation to my HR here."

    /// Runs every check; returns a report and whether all passed.
    static func run() async -> (report: String, passed: Bool) {
        var results: [(String, Bool)] = []
        func check(_ name: String, _ condition: Bool) { results.append((name, condition)) }

        // Keep the developer's real toggles.
        let defaults = UserDefaults.standard
        let savedRouter = defaults.object(forKey: HybridRouter.enabledKey)
        let savedGate = defaults.object(forKey: ToolGate.enabledKey)
        let savedKeywords = defaults.object(forKey: HybridRouter.keywordImprovementsKey)
        defer {
            defaults.set(savedRouter, forKey: HybridRouter.enabledKey)
            defaults.set(savedGate, forKey: ToolGate.enabledKey)
            defaults.set(savedKeywords, forKey: HybridRouter.keywordImprovementsKey)
        }
        defaults.removeObject(forKey: HybridRouter.enabledKey)
        // The self-test never touches the real Keychain or the server (both
        // could wait forever: a Keychain prompt, or no sign-in).
        RouterKeychain.testOverride = .some(nil)
        RouterClient.serverAllowed = false
        defer {
            RouterKeychain.testOverride = nil
            RouterClient.serverAllowed = true
        }
        defaults.removeObject(forKey: ToolGate.enabledKey)
        defaults.removeObject(forKey: HybridRouter.keywordImprovementsKey)

        // JSON parsing
        check("parse clean JSON", HybridRouter.parse(#"{"route":"fix_code","confidence":0.88}"#) == RouterResult(route: .fixCode, confidence: 0.88))
        check("parse prefill continuation", HybridRouter.parse(#"write","confidence":0.95}"#) == RouterResult(route: .write, confidence: 0.95))
        check("parse fenced JSON", HybridRouter.parse("```json\n{\"route\": \"search\", \"confidence\": 0.9}\n```") == RouterResult(route: .search, confidence: 0.9))
        check("parse messy text", HybridRouter.parse(#"Sure! {"route":"edit","confidence":"0.8"} ok"#) == RouterResult(route: .edit, confidence: 0.8))
        check("parse broken JSON", HybridRouter.parse(#"{"route":"screen","confidence":0.77"#) == RouterResult(route: .screen, confidence: 0.77))
        check("reject unknown route", HybridRouter.parse(#"{"route":"dance","confidence":0.9}"#) == nil)
        check("reject empty object", HybridRouter.parse("{}") == nil)
        check("clamp confidence", HybridRouter.parse(#"{"route":"simple","confidence":7}"#)?.confidence == 1)

        // Threshold
        check("accept at 0.75", HybridRouter.accept(RouterResult(route: .write, confidence: 0.75)) == .write)
        check("reject below 0.75", HybridRouter.accept(RouterResult(route: .write, confidence: 0.74)) == nil)
        check("reject unclear label", HybridRouter.accept(RouterResult(route: .unclear, confidence: 0.99)) == nil)

        // Timeout, offline, HTTP error, no key
        let timedOut = await RouterClient(key: "t", transport: Fake(delay: 2)).classify(text: "hi", flags: RouterFlags(), timeout: 0.2)
        check("timeout falls back", timedOut.result == nil && timedOut.failure == "timeout" && timedOut.milliseconds < 1_500)
        let offline = await RouterClient(key: "t", transport: Fake(offline: true)).classify(text: "hi", flags: RouterFlags(), timeout: 1)
        check("offline falls back", offline.result == nil && offline.failure == "offline")
        let unauthorized = await RouterClient(key: "t", transport: Fake(body: "{}", status: 401)).classify(text: "hi", flags: RouterFlags(), timeout: 1)
        check("http error falls back", unauthorized.result == nil && unauthorized.failure == "http 401")
        let vague = "the thing with the stuff from before, yeah"
        let used = await HybridRouter.decide(text: vague, flags: RouterFlags(), client: RouterClient(key: "t", transport: Fake()), timeout: 1)
        check("unclear request uses router", used.source == .router && used.override == .write && used.jsonParsed == true)
        let unsure = await HybridRouter.decide(text: vague, flags: RouterFlags(),
                                               client: RouterClient(key: "t", transport: Fake(body: #"{"content":[{"type":"text","text":"deep\",\"confidence\":0.5}"}]}"#)),
                                               timeout: 1)
        check("unsure router keeps today", unsure.source == .fallback && unsure.override == nil && unsure.routerRoute == .deep)
        let slow = await HybridRouter.decide(text: vague, flags: RouterFlags(), client: RouterClient(key: "t", transport: Fake(delay: 2)), timeout: 0.2)
        check("slow router keeps today", slow.source == .fallback && slow.override == nil && slow.reason == "timeout")
        // Never touch the real Keychain here (a test binary would trigger a
        // macOS permission prompt): pretend no key is saved.
        let noKey = await HybridRouter.decide(text: vague, flags: RouterFlags())
        check("no key keeps today", noKey.source == .fallback && noKey.override == nil && noKey.reason == "no router key")

        // Toggle
        check("router always on", HybridRouter.isEnabled && HybridRouter.isActive && HybridRouter.pathActive)
        HybridRouter.isEnabled = false
        ToolGate.isEnabled = false
        check("router and Tool Gate can't be turned off", HybridRouter.isEnabled && ToolGate.isEnabled && HybridRouter.isActive)
        check("keyword improvements off by default", !HybridRouter.keywordImprovementsEnabled)
        let router = IntentRouter()
        check("today's route unchanged (resignation → screen)", router.route(transcript: resignation, mode: .command) == .screen(question: resignation))
        check("today's route unchanged (write)", router.route(transcript: "write a resignation mail to my HR", mode: .command)
              == .chat(message: "write a resignation mail to my HR"))
        check("today's route unchanged (dictation)", router.route(transcript: "hello", mode: .dictation) == .dictate)

        // Keyword pass
        var typing = RouterFlags(); typing.textFieldFocused = true
        check("resignation → clause write", HybridRouter.keywordVerdict(for: resignation, flags: typing, improvements: true) == .clause(.write))
        if case .unclear = HybridRouter.keywordVerdict(for: resignation, flags: typing, improvements: false) {
            check("improvements off: resignation goes to router", true)
        } else { check("improvements off: resignation goes to router", false) }
        var code = RouterFlags(); code.hasSelectedText = true; code.selectionLooksLikeCode = true
        check("ramble ending in fix it → fix_code",
              HybridRouter.keywordVerdict(for: "So this thing keeps crashing when I click save, uh, can you look at what's wrong and fix it?", flags: code, improvements: true) == .clause(.fixCode))
        for text in ["I can't write today, I'm so tired", "I don't want to write anything", "No quiero escribir nada hoy"] {
            check("not a write: \(text)", !HybridRouter.clauseRoutes(for: text, flags: RouterFlags()).contains(.write))
        }
        check("short strong keeps today (open Safari)", HybridRouter.keywordVerdict(for: "open Safari", flags: RouterFlags()) == .keep(.strong))
        check("short strong keeps today (write a mail)", HybridRouter.keywordVerdict(for: "write a mail to my boss", flags: RouterFlags()) == .keep(.strong))
        check("short strong keeps today (my screen)", HybridRouter.keywordVerdict(for: "what is on my screen", flags: RouterFlags()) == .keep(.strong))
        if case .unclear = HybridRouter.keywordVerdict(for: "I need to finish the report, and then open Slack, and then write a reply to Sam", flags: RouterFlags(), improvements: true) {
            check("two tasks → router", true)
        } else { check("two tasks → router", false) }

        // "here" fix (always on)
        let hereDecided = router.decide(transcript: resignation, mode: .command)
        check("here fix: resignation is not screen (writes)", IntentRouter.hereScreenCorrection(for: resignation, decided: hereDecided, textFieldFocused: false) != nil
              && IntentRouter.clearlyAsksToWrite(resignation)
              && HybridRouter.baselineRoute(for: resignation, flags: RouterFlags(), intentRouter: router) == .write)
        let hereQuestion = "so I'm filling in my profile and I don't know what goes in this bit here"
        let hereQuestionDecided = router.decide(transcript: hereQuestion, mode: .command)
        check("here fix: text field focused stops screen", IntentRouter.hereScreenCorrection(for: hereQuestion, decided: hereQuestionDecided, textFieldFocused: true) != nil)
        check("here fix: no text field, no write → screen stays", IntentRouter.hereScreenCorrection(for: hereQuestion, decided: hereQuestionDecided, textFieldFocused: false) == nil)
        let strongScreen = "what is on my screen here"
        check("here fix: real screen words keep screen", IntentRouter.hereScreenCorrection(for: strongScreen, decided: router.decide(transcript: strongScreen, mode: .command), textFieldFocused: true) == nil)
        check("clearly asks to write (English)", IntentRouter.clearlyAsksToWrite("okay so can you draft a quick reply to him here"))
        check("clearly asks to write (Hinglish)", IntentRouter.clearlyAsksToWrite("HR ko mail likh do"))
        check("not a write: negation", !IntentRouter.clearlyAsksToWrite("I can't write the mail here today"))
        check("not a write: question", !IntentRouter.clearlyAsksToWrite("how do I write a cover letter here"))

        // Fillers
        check("strip English fillers", RoutingText.stripFillers("uh, um, write a mail, you know, to HR") == "write a mail, to HR")
        check("strip German fillers", RoutingText.stripFillers("äh, schreib eine Mail") == "schreib eine Mail")
        check("strip Japanese fillers", RoutingText.stripFillers("えっと、メールを書いて") == "メールを書いて")
        check("keep 'like' when meaningful", RoutingText.stripFillers("I like pizza") == "I like pizza")
        let capture = Capture()
        _ = await RouterClient(key: "t", transport: capture).classify(text: "uh, so, um, the thing from before", flags: RouterFlags(), timeout: 1)
        check("fillers kept in text sent to model", capture.bodies.first?.contains("uh, so, um, the thing from before") == true)
        check("clauses split on connectors",
              RoutingText.clauses("I want to resign. Uh, so write a mail to HR here") == ["I want to resign", "write a mail to HR here"])

        // Privacy
        var full = RouterFlags(); full.hasSelectedText = true; full.selectionLooksLikeCode = true; full.filesAttached = true; full.frontmostApp = "Xcode"
        let body = HybridRouter.requestBody(text: "fix it", flags: full)
        let json = (try? JSONSerialization.data(withJSONObject: body)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("no image/file blocks sent", !json.contains("\"image\"") && !json.contains("base64") && !json.contains("\"document\""))
        check("only text messages sent", (body["messages"] as? [[String: Any]])?.allSatisfy { $0["content"] is String } == true)
        check("flags carry no text fields", Set(Mirror(reflecting: full).children.compactMap(\.label)) == [
            "hasSelectedText", "selectionLooksLikeCode", "recentBibblesWriting", "textFieldFocused", "frontmostApp",
            "filesAttached", "screenHotkeyUsed"])
        check("request settings", body["model"] as? String == "claude-haiku-4-5-20251001" && body["max_tokens"] as? Int == 40
              && body["temperature"] as? Int == 0 && body["thinking"] == nil)

        // Replacing earlier writing ("rewrite it"): find the old text even
        // when the editor changed line breaks, spaces or quotes.
        let written = "Subject: Still thinking of you\n\nHi [Friend's Name],\n\nI hope you're well.\n\nWarm regards,\n[Your Name]"
        let inGmail = "Subject: Still thinking of you\nHi [Friend\u{2019}s Name],\n\u{00A0}\nI hope you\u{2019}re well.\n\nWarm regards,\n[Your Name]"
        if let found = FocusedTextInserter.range(of: written, in: "Draft\n" + inGmail + "\n-- \nsig") {
            let picked = (("Draft\n" + inGmail + "\n-- \nsig") as NSString).substring(with: NSRange(location: found.location, length: found.length))
            check("replace: finds old mail despite editor changes", picked == inGmail)
        } else { check("replace: finds old mail despite editor changes", false) }
        check("replace: exact text still found", FocusedTextInserter.range(of: "hello world", in: "say hello world now")?.location == 4)
        check("replace: unrelated text not matched", FocusedTextInserter.range(of: "Dear team, the launch is moved", in: "Hi Sam, lunch at noon?") == nil)

        // Spoken answers: a short first piece, then sentences grouped, with
        // nothing lost or reordered.
        let answer = "This is a YouTube Short playing a math visualization. The triangle shown is a right triangle with the right angle at the bottom-left, the vertical leg labeled a on the left, the horizontal leg labeled b at the bottom, and the hypotenuse labeled c. The formula states that if you build a square on side a and a square on side b, their combined area equals the area of a square built on the hypotenuse c. So the two smaller squares' areas add up to exactly the largest square's area. Next step: let the video play to see the squares being rearranged."
        let spokenAnswer = VoiceReplyText.spoken(answer)
        let pieces = VoiceReplyText.speechChunks(spokenAnswer)
        check("speech: first piece is short", (pieces.first?.count ?? 999) <= 100)
        check("speech: few pieces (sentences grouped)", pieces.count >= 2 && pieces.count <= 4)
        check("speech: nothing lost or reordered", pieces.joined(separator: " ") == spokenAnswer)
        check("speech: pieces stay small enough to generate quickly", pieces.dropFirst().allSatisfy { $0.count <= 600 })

        // Screen walkthrough: parts first, then the whole, each with its mark.
        let tourJSON = #"{"answer":"x","confidence":0.9,"walkthrough":[{"say":"Side a is the vertical leg.","mark":{"kind":"line","points":[{"x":0.2,"y":0.8},{"x":0.2,"y":0.3}],"label":"a"}},{"say":"Side b is the bottom.","mark":{"kind":"line","points":[{"x":0.2,"y":0.8},{"x":0.7,"y":0.8}],"label":"b"}},{"say":"The formula sits here.","mark":{"kind":"rectangle","target":{"ocrId":1}}},{"say":"Together they form the triangle.","mark":{"kind":"line","points":[{"x":0.2,"y":0.8},{"x":0.2,"y":0.3},{"x":0.7,"y":0.8},{"x":0.2,"y":0.8}]}}]}"#
        let tourResponse = try? JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": tourJSON]]])
        let tourOCR = [OCRObservation(text: "a² + b² = c²", confidence: 0.9, normalizedRect: NormalizedRect(x: 0.6, y: 0.1, width: 0.2, height: 0.05))]
        if let tourResponse, let tour = try? MessagesVisionProvider.parseResponse(tourResponse, model: "m", imageSize: CGSize(width: 1000, height: 800), ocr: tourOCR, question: "explain this formula", kind: .general) {
            check("walkthrough: four steps in order", tour.walkthrough.map(\.say).first == "Side a is the vertical leg." && tour.walkthrough.count == 4)
            check("walkthrough: line traced through its points", tour.walkthrough[0].mark?.points.count == 2 && tour.walkthrough[0].mark?.label == "a")
            check("walkthrough: text mark snaps to OCR box", tour.walkthrough[2].mark?.target.map { $0.x <= 0.6 && $0.x + $0.width >= 0.8 } == true)
            check("walkthrough: whole outline kept (closed shape)", tour.walkthrough[3].mark?.points.count == 4)
            check("walkthrough: card text is the spoken steps", tour.answer.hasPrefix("Side a is the vertical leg.\n\nSide b"))
        } else { check("walkthrough: parses", false) }
        let pixelTour = MessagesVisionProvider.walkthrough(from: [
            ["say": "One", "mark": ["kind": "line", "points": [["x": 200, "y": 640], ["x": 200, "y": 240]]]],
            ["say": "Two", "mark": ["kind": "line", "points": [["x": 0.5, "y": 0.5], ["x": 0.5, "y": 0.5]]]]
        ], ocr: [], imageSize: CGSize(width: 1000, height: 800))
        check("walkthrough: pixel points scaled to the image", pixelTour.first?.mark?.points.first == CGPoint(x: 0.2, y: 0.8))
        check("walkthrough: a dot is not a line", pixelTour.count == 2 && pixelTour[1].mark == nil)
        check("walkthrough: one step is no walkthrough", MessagesVisionProvider.walkthrough(from: [["say": "Only"]], ocr: [], imageSize: nil).isEmpty)

        // Walkthrough voice: first step alone, the rest in few larger pieces,
        // every step timed inside its piece, nothing lost.
        let stepTexts = ["Side a is the vertical leg.", "Side b is the bottom.", "Side c is the slanted one.", "Together they make the triangle."]
        let stepVoice = VoiceReplyText.stepPieces(stepTexts)
        check("step voice: few pieces", stepVoice.count == 2)
        check("step voice: every step has a start", stepVoice.flatMap(\.marks).map(\.step) == [0, 1, 2, 3])
        check("step voice: later steps start later", stepVoice[1].marks.map(\.at) == stepVoice[1].marks.map(\.at).sorted() && stepVoice[1].marks.first?.at == 0)
        check("step voice: nothing lost", stepVoice.map(\.text).joined(separator: " ") == stepTexts.joined(separator: " "))
        check("step voice: long steps split into more pieces", VoiceReplyText.stepPieces(Array(repeating: String(repeating: "word ", count: 80), count: 4)).count == 4)

        // Live voice: sentences are spoken as soon as they are written.
        let partial = "Bibbles is a Mac helper, and it answers fast. It can also see your scr"
        let (liveReady, liveTail) = VoiceReplyText.readyChunks(in: partial, final: false, limit: 320, quickStart: true)
        check("live voice: first words ready before the answer ends", !liveReady.isEmpty && liveTail.hasSuffix("see your scr"))
        check("live voice: unfinished sentence waits", !liveReady.joined().contains("scr"))
        let livePieces = VoiceReplyText.groupLive(["One.", "Two.", "Three."], firstPiece: true)
        check("live voice: short first piece, rest joined", livePieces == ["One.", "Two. Three."])

        // Screen model choice: diagrams and formulas deep, words and UI fast.
        func ocrItems(_ texts: [String]) -> [OCRObservation] {
            texts.map { OCRObservation(text: $0, confidence: 0.9, normalizedRect: NormalizedRect(x: 0.1, y: 0.1, width: 0.05, height: 0.05)) }
        }
        let figure = ocrItems(["(a + b)²", "a", "b", "a", "b", "= a² + 2ab + b²"])
        let article = ocrItems(["The committee decided to postpone the vote until next week.",
                                "Members said they needed more time to read the report.", "Home", "News"])
        check("screen deep: formula question", ScreenComplexity.needsDeep(question: "explain this formula", ocr: []))
        check("screen deep: explain a diagram on screen", ScreenComplexity.needsDeep(question: "explain this", ocr: figure))
        check("screen fast: meaning of highlighted word", !ScreenComplexity.needsDeep(question: "explain the meaning of the highlighted word", ocr: figure))
        check("screen fast: explain text on a normal page", !ScreenComplexity.needsDeep(question: "explain this", ocr: article))
        check("screen fast: what is this app", !ScreenComplexity.needsDeep(question: "what is this app", ocr: figure))
        check("screen fast: 'app' isn't matched inside 'happy'", ScreenComplexity.needsDeep(question: "explain why this graph is happy", ocr: []))

        // Router through the Bibbles server (no key in the app)
        let serverClient = RouterClient(key: "", serverToken: "user-token")
        if let serverRequest = try? serverClient.urlRequest(text: "hi", flags: RouterFlags()) {
            check("server router: Bibbles server, /v1/route", serverRequest.url?.path.hasSuffix("/v1/route") == true)
            check("server router: sign-in token, no Anthropic key", serverRequest.value(forHTTPHeaderField: "Authorization") == "Bearer user-token"
                  && serverRequest.value(forHTTPHeaderField: "x-api-key") == nil)
            let sent = serverRequest.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            check("server router: Haiku, text only", sent?["model"] as? String == HybridRouter.model
                  && !(String(data: serverRequest.httpBody ?? Data(), encoding: .utf8) ?? "").contains("image"))
        } else { check("server router: request builds", false) }

        // Deep tasks
        check("deep with none left → light", ToolGate.mode(for: .deep, preference: .auto, deepTasksLeft: 0) == .ask)
        check("deep with some left → deep", ToolGate.mode(for: .deep, preference: .auto, deepTasksLeft: 3) == .deep)

        // Test set
        check("test set size", RouterTestSet.cases.count >= 140)
        check("test set covers every route", Set(RouterTestSet.cases.map(\.expected)) == Set(HybridRoute.allCases))
        check("prompt examples don't leak", RouterTestSet.cases.allSatisfy { !RouterPrompt.system.contains($0.text) })

        let failed = results.filter { !$0.1 }
        var lines = ["Router self-test: \(results.count - failed.count)/\(results.count) passed"]
        lines += results.map { "\($0.1 ? "PASS" : "FAIL")  \($0.0)" }

        // Local keyword-pass preview over the test set (no network).
        var todayCorrect = 0, keywordDecided = 0, keywordCorrect = 0, newCorrect = 0
        for item in RouterTestSet.cases {
            let local = RouterTestRunner.localRoutes(for: item)
            if local.today == item.expected { todayCorrect += 1 }
            switch local.verdict {
            case .clause(let route), .gate(let route): if route == item.expected { newCorrect += 1 }
            case .keep, .unclear: if local.today == item.expected { newCorrect += 1 }
            }
            switch local.verdict {
            case .clause(let route), .gate(let route):
                keywordDecided += 1
                if route == item.expected { keywordCorrect += 1 }
            case .keep:
                keywordDecided += 1
                if local.today == item.expected { keywordCorrect += 1 }
            case .unclear: break
            }
        }
        lines += ["", "Test set, keywords only (no network): old keywords correct \(todayCorrect)/\(RouterTestSet.cases.count); new keywords correct \(newCorrect)/\(RouterTestSet.cases.count); "
                  + "keyword pass decided \(keywordDecided) (correct \(keywordCorrect)), sent to router \(RouterTestSet.cases.count - keywordDecided)"]
        for (index, item) in RouterTestSet.cases.enumerated() {
            let local = RouterTestRunner.localRoutes(for: item)
            lines.append("#\(index + 1) [\(item.language)] expected \(item.expected.rawValue) · today \(local.today.rawValue) · \(RouterTestRunner.describe(local.verdict))")
        }
        return (lines.joined(separator: "\n"), failed.isEmpty)
    }

    /// Entry point for `--router-self-test`. Never returns.
    private final class Box: @unchecked Sendable { var report = ""; var passed = false }

    static func runAndExit() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = Box()
        Task.detached {
            let result = await run()
            outcome.report = result.report
            outcome.passed = result.passed
            semaphore.signal()
        }
        semaphore.wait()
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count {
            try? outcome.report.write(toFile: arguments[index + 1], atomically: true, encoding: .utf8)
        }
        print(outcome.report)
        exit(outcome.passed ? 0 : 1)
    }
}
