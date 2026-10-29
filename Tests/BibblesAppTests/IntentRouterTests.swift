import XCTest
@testable import BibblesApp

final class IntentRouterTests: XCTestCase {
    func testSimpleTriangleDrawingRoutesLocallyWithoutHijackingChartPatternRequests() {
        let router = IntentRouter()
        let local = "Draw a triangle on my screen"
        XCTAssertEqual(router.route(transcript: local, mode: .command), .screen(question: local))
        XCTAssertEqual(SimpleDrawingCommand.parse(local), .triangle)
        XCTAssertEqual(SimpleDrawingCommand.parse("Sketch a triangle"), .triangle)
        XCTAssertNil(SimpleDrawingCommand.parse("Draw a triangle around this candle pattern"))
    }

    func testPointedCandleUsesDetailedCropAndExportUsesOverview() {
        let router = IntentRouter()
        let candle = "Explain this candle on my trading chart"
        XCTAssertEqual(router.route(transcript: candle, mode: .command), .screen(question: candle))
        XCTAssertFalse(router.shouldUseScreenOverview(for: candle))
        XCTAssertEqual(ScreenQuestionKind.classify(candle), .chartCandle)
        XCTAssertFalse(ScreenQuestionKind.classify(candle).needsOCR)

        let export = "How do I export the file?"
        XCTAssertEqual(router.route(transcript: export, mode: .command), .screen(question: export))
        XCTAssertTrue(router.shouldUseScreenOverview(for: export))
        XCTAssertEqual(ScreenQuestionKind.classify(export), .howTo)
        XCTAssertEqual(ScreenQuestionKind.classify("Export this candle chart"), .findControl)
    }

    func testDictationModeAlwaysRoutesToDictation() {
        XCTAssertEqual(IntentRouter().route(transcript: "search this", mode: .dictation), .dictate)
    }

    func testHinglishScreenQuestionRoutesToScreen() {
        XCTAssertEqual(
            IntentRouter().route(transcript: "ye button disabled kyun hai", mode: .command),
            .screen(question: "ye button disabled kyun hai")
        )
    }

    func testSearchPrefixRoutesToSearch() {
        XCTAssertEqual(
            IntentRouter().route(transcript: "search Swift concurrency changes", mode: .command),
            .search(query: "Swift concurrency changes")
        )
    }

    func testHinglishSearchPrefixIsRemovedBeforeDispatch() {
        XCTAssertEqual(
            IntentRouter().route(transcript: "online dhundo latest Swift release", mode: .command),
            .search(query: "latest Swift release")
        )
    }

    func testSelectedTextRequestUsesFocusedContext() {
        XCTAssertTrue(IntentRouter().shouldUseFocusedText(for: "rewrite this more clearly"))
        XCTAssertTrue(IntentRouter().shouldUseFocusedText(for: "isko summarize karo"))
        XCTAssertTrue(IntentRouter().shouldUseFocusedText(for: "isko simple explain karo"))
        XCTAssertFalse(IntentRouter().shouldUseFocusedText(for: "tell me a joke"))
    }

    func testHinglishSimpleExplanationRoutesToSelectedText() {
        XCTAssertEqual(
            IntentRouter().route(transcript: "isko simple explain karo", mode: .command),
            .chat(message: "isko simple explain karo")
        )
    }

    func testGenericDeicticQuestionRoutesToScreen() {
        XCTAssertEqual(
            IntentRouter().route(transcript: "explain this", mode: .command),
            .screen(question: "explain this")
        )
        XCTAssertEqual(
            IntentRouter().route(transcript: "ye kya hai", mode: .command),
            .screen(question: "ye kya hai")
        )
    }

    func testFocusedTextRequestWinsOverGenericScreenSignal() {
        XCTAssertEqual(
            IntentRouter().route(transcript: "isko rewrite karo", mode: .command),
            .chat(message: "isko rewrite karo")
        )
    }

    func testConversationalScreenRequestRoutesToFullScreenOverview() {
        let text = "hey can you tell me what is up on my screen"
        let router = IntentRouter()
        XCTAssertEqual(router.route(transcript: text, mode: .command), .screen(question: text))
        XCTAssertTrue(router.shouldUseScreenOverview(for: text))
        XCTAssertFalse(router.shouldUseScreenOverview(for: "why is this button greyed out"))
    }

    func testTruncatedScreenQuestionDoesNotFallThroughToGenericChat() {
        let text = "Hey, we will. What is up on my"
        let router = IntentRouter()
        XCTAssertEqual(router.route(transcript: text, mode: .command), .screen(question: text))
        XCTAssertTrue(router.shouldUseScreenOverview(for: text))
        XCTAssertEqual(
            router.route(transcript: "What's on my calendar tomorrow?", mode: .command),
            .chat(message: "What's on my calendar tomorrow?")
        )
    }
}

final class MacSearchRoutingTests: XCTestCase {
    func testSearchingTheMacIsNotAWebSearch() {
        let router = IntentRouter()
        XCTAssertEqual(router.route(transcript: "Search my Mac for my resume", mode: .command),
                       .chat(message: "Search my Mac for my resume"))
        XCTAssertEqual(router.route(transcript: "search for the PDF I downloaded yesterday", mode: .command),
                       .chat(message: "search for the PDF I downloaded yesterday"))
        // Web searches still go to the web, without the word "for".
        XCTAssertEqual(router.route(transcript: "search for the latest iPhone price", mode: .command),
                       .search(query: "the latest iPhone price"))
        XCTAssertEqual(router.route(transcript: "search online for my resume tips", mode: .command),
                       .search(query: "my resume tips"))
    }
}
