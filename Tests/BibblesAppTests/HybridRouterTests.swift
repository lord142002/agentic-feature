import Foundation
import XCTest
@testable import BibblesApp

/// A transport that never touches the network.
private struct FakeTransport: RouterTransport {
    var body: String = #"{"content":[{"type":"text","text":"write\",\"confidence\":0.92}"}]}"#
    var status = 200
    var delay: TimeInterval = 0
    var error: Error?

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let error { throw error }
        return (Data(body.utf8), status)
    }
}

/// Records what would have been sent.
private final class CapturingTransport: RouterTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        return (Data(#"{"content":[{"type":"text","text":"simple\",\"confidence\":0.9}"}]}"#.utf8), 200)
    }
}

final class HybridRouterTests: XCTestCase {
    private let resignation = "I'm not liking a job where I'm working right now. So uh, I want to resign. Uh, so write a mail of resignation to my HR here."

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: HybridRouter.enabledKey)
        UserDefaults.standard.removeObject(forKey: ToolGate.enabledKey)
        UserDefaults.standard.removeObject(forKey: HybridRouter.keywordImprovementsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: HybridRouter.enabledKey)
        UserDefaults.standard.removeObject(forKey: ToolGate.enabledKey)
        UserDefaults.standard.removeObject(forKey: HybridRouter.keywordImprovementsKey)
        super.tearDown()
    }

    // MARK: JSON parsing

    func testParsesCleanJSON() {
        XCTAssertEqual(HybridRouter.parse(#"{"route":"fix_code","confidence":0.88}"#),
                       RouterResult(route: .fixCode, confidence: 0.88))
    }

    func testParsesPrefillContinuation() {
        XCTAssertEqual(HybridRouter.parse(#"write","confidence":0.95}"#), RouterResult(route: .write, confidence: 0.95))
    }

    func testParsesFencedJSON() {
        XCTAssertEqual(HybridRouter.parse("```json\n{\"route\": \"search\", \"confidence\": 0.9}\n```"),
                       RouterResult(route: .search, confidence: 0.9))
    }

    func testParsesMessyText() {
        XCTAssertEqual(HybridRouter.parse(#"Sure! Here you go: {"route":"edit","confidence":"0.8"} hope that helps"#),
                       RouterResult(route: .edit, confidence: 0.8))
    }

    func testParsesBrokenJSONWithPatterns() {
        XCTAssertEqual(HybridRouter.parse(#"{"route":"screen","confidence":0.77"#), RouterResult(route: .screen, confidence: 0.77))
    }

    func testRejectsUnknownRouteAndGarbage() {
        XCTAssertNil(HybridRouter.parse(#"{"route":"dance","confidence":0.9}"#))
        XCTAssertNil(HybridRouter.parse("{}"))
        XCTAssertNil(HybridRouter.parse("```\n```"))
    }

    func testClampsConfidence() {
        XCTAssertEqual(HybridRouter.parse(#"{"route":"simple","confidence":7}"#)?.confidence, 1)
    }

    // MARK: Threshold

    func testConfidenceThreshold() {
        XCTAssertEqual(HybridRouter.accept(RouterResult(route: .write, confidence: 0.75)), .write)
        XCTAssertNil(HybridRouter.accept(RouterResult(route: .write, confidence: 0.74)))
        XCTAssertNil(HybridRouter.accept(RouterResult(route: .unclear, confidence: 0.99)))
        XCTAssertNil(HybridRouter.accept(nil))
    }

    // MARK: Timeout, offline, no key

    func testTimeoutFallsBack() async {
        let client = RouterClient(serverToken: "test", transport: FakeTransport(delay: 2))
        let outcome = await client.classify(text: "hello", flags: RouterFlags(), timeout: 0.2)
        XCTAssertNil(outcome.result)
        XCTAssertEqual(outcome.failure, "timeout")
        XCTAssertLessThan(outcome.milliseconds, 1_500)
    }

    func testOfflineFallsBack() async {
        let client = RouterClient(serverToken: "test", transport: FakeTransport(error: URLError(.notConnectedToInternet)))
        let outcome = await client.classify(text: "hello", flags: RouterFlags(), timeout: 1)
        XCTAssertNil(outcome.result)
        XCTAssertEqual(outcome.failure, "offline")
    }

    func testHTTPErrorFallsBack() async {
        let client = RouterClient(serverToken: "test", transport: FakeTransport(body: "{}", status: 401))
        let outcome = await client.classify(text: "hello", flags: RouterFlags(), timeout: 1)
        XCTAssertNil(outcome.result)
        XCTAssertEqual(outcome.failure, "http 401")
    }

    func testUnclearRequestUsesRouterAnswer() async {
        let client = RouterClient(serverToken: "test", transport: FakeTransport())
        let decision = await HybridRouter.decide(text: "the thing with the stuff from before, yeah", flags: RouterFlags(),
                                                 client: client, timeout: 1)
        XCTAssertEqual(decision.source, .router)
        XCTAssertEqual(decision.override, .write)
        XCTAssertEqual(decision.jsonParsed, true)
    }

    func testUnsureRouterKeepsTodaysBehaviour() async {
        let client = RouterClient(serverToken: "test",
                                  transport: FakeTransport(body: #"{"content":[{"type":"text","text":"deep\",\"confidence\":0.5}"}]}"#))
        let decision = await HybridRouter.decide(text: "the thing with the stuff from before, yeah", flags: RouterFlags(),
                                                 client: client, timeout: 1)
        XCTAssertEqual(decision.source, .fallback)
        XCTAssertNil(decision.override)
        XCTAssertEqual(decision.routerRoute, .deep)
    }

    func testTimedOutRouterKeepsTodaysBehaviour() async {
        let client = RouterClient(serverToken: "test", transport: FakeTransport(delay: 2))
        let decision = await HybridRouter.decide(text: "the thing with the stuff from before, yeah", flags: RouterFlags(),
                                                 client: client, timeout: 0.2)
        XCTAssertEqual(decision.source, .fallback)
        XCTAssertNil(decision.override)
        XCTAssertEqual(decision.reason, "timeout")
    }

    // MARK: Toggle

    func testRouterIsOnByDefault() {
        UserDefaults.standard.removeObject(forKey: HybridRouter.enabledKey)
        XCTAssertTrue(HybridRouter.isEnabled)
    }

    func testRouterAndToolGateAlwaysOn() {
        HybridRouter.isEnabled = false
        ToolGate.isEnabled = false
        XCTAssertTrue(HybridRouter.isEnabled)
        XCTAssertTrue(ToolGate.isEnabled)
        XCTAssertTrue(HybridRouter.isActive)
    }

    func testTodaysIntentIsUnchangedByRefactor() {
        // `route` must return exactly what it did before `decide` existed.
        let router = IntentRouter()
        XCTAssertEqual(router.route(transcript: resignation, mode: .command), .screen(question: resignation))
        XCTAssertEqual(router.route(transcript: "write a resignation mail to my HR", mode: .command),
                       .chat(message: "write a resignation mail to my HR"))
        XCTAssertEqual(router.route(transcript: "hello", mode: .dictation), .dictate)
        XCTAssertEqual(router.route(transcript: "what is on my screen", mode: .command),
                       .screen(question: "what is on my screen"))
    }

    // MARK: Keyword pass

    func testResignationExampleIsWrittenByClauseRule() {
        var flags = RouterFlags()
        flags.textFieldFocused = true
        XCTAssertEqual(HybridRouter.keywordVerdict(for: resignation, flags: flags, improvements: true), .clause(.write))
        if case .unclear = HybridRouter.keywordVerdict(for: resignation, flags: flags, improvements: false) {} else {
            XCTFail("without keyword improvements the router decides")
        }
    }

    func testFixItAtTheEndOfARamble() {
        var flags = RouterFlags()
        flags.hasSelectedText = true
        flags.selectionLooksLikeCode = true
        let text = "So this thing keeps crashing when I click save, uh, can you look at what's wrong and fix it?"
        XCTAssertEqual(HybridRouter.keywordVerdict(for: text, flags: flags, improvements: true), .clause(.fixCode))
    }

    func testKeywordFalsePositivesAreNotWrites() {
        for text in ["I can't write today, I'm so tired", "I don't want to write anything", "No quiero escribir nada hoy"] {
            XCTAssertFalse(HybridRouter.clauseRoutes(for: text, flags: RouterFlags()).contains(.write), text)
        }
    }

    func testShortStrongRequestsKeepTodaysRoute() {
        XCTAssertEqual(HybridRouter.keywordVerdict(for: "open Safari", flags: RouterFlags()), .keep(.strong))
        XCTAssertEqual(HybridRouter.keywordVerdict(for: "write a mail to my boss", flags: RouterFlags()), .keep(.strong))
        XCTAssertEqual(HybridRouter.keywordVerdict(for: "what is on my screen", flags: RouterFlags()), .keep(.strong))
    }

    func testConflictingClausesAreUnclear() {
        let text = "I need to finish the report, and then open Slack, and then write a reply to Sam"
        if case .unclear = HybridRouter.keywordVerdict(for: text, flags: RouterFlags(), improvements: true) {} else {
            XCTFail("two different tasks should go to the router")
        }
    }

    func testKeywordImprovementsToggleIsSeparate() {
        HybridRouter.isEnabled = false
        XCTAssertFalse(HybridRouter.keywordImprovementsEnabled)
        HybridRouter.keywordImprovementsEnabled = true
        XCTAssertTrue(HybridRouter.pathActive)
        XCTAssertFalse(HybridRouter.isActive)
    }

    func testFlagsEncodeUnusualAppNamesAsValidJSON() throws {
        var flags = RouterFlags()
        flags.frontmostApp = "Editor \"Pro\"\\Test\nWindow\tName"
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(flags.json.utf8)) as? [String: Any])
        XCTAssertEqual(object["frontmostApp"] as? String, flags.frontmostApp)
        XCTAssertEqual(object["hasSelectedText"] as? Bool, false)
        XCTAssertEqual(flags.json, flags.json, "Encoding must be stable")
    }

    func testNonFiniteAndBooleanConfidenceCannotDispatchAnAction() {
        for raw in [#"{"route":"command","confidence":"NaN"}"#,
                    #"{"route":"command","confidence":"inf"}"#,
                    #"{"route":"command","confidence":true}"#] {
            XCTAssertNil(HybridRouter.parse(raw), raw)
        }
        XCTAssertNil(HybridRouter.accept(RouterResult(route: .command, confidence: .nan)))
        XCTAssertNil(HybridRouter.accept(RouterResult(route: .command, confidence: .infinity)))
    }

    // MARK: "here" fix (always on)

    func testHereWithAWriteRequestIsNotScreen() {
        let router = IntentRouter()
        let decided = router.decide(transcript: resignation, mode: .command)
        XCTAssertNotNil(IntentRouter.hereScreenCorrection(for: resignation, decided: decided, textFieldFocused: false))
        XCTAssertEqual(HybridRouter.baselineRoute(for: resignation, flags: RouterFlags(), intentRouter: router), .write)
    }

    func testHereWithTextFieldFocusedIsNotScreen() {
        let text = "so I'm filling in my profile and I don't know what goes in this bit here"
        let decided = IntentRouter().decide(transcript: text, mode: .command)
        XCTAssertNotNil(IntentRouter.hereScreenCorrection(for: text, decided: decided, textFieldFocused: true))
        XCTAssertNil(IntentRouter.hereScreenCorrection(for: text, decided: decided, textFieldFocused: false))
    }

    func testRealScreenWordsStillMeanScreen() {
        let text = "what is on my screen here"
        let decided = IntentRouter().decide(transcript: text, mode: .command)
        XCTAssertNil(IntentRouter.hereScreenCorrection(for: text, decided: decided, textFieldFocused: true))
    }

    func testClearlyAsksToWrite() {
        XCTAssertTrue(IntentRouter.clearlyAsksToWrite("okay so can you draft a quick reply to him here"))
        XCTAssertTrue(IntentRouter.clearlyAsksToWrite("HR ko mail likh do"))
        XCTAssertFalse(IntentRouter.clearlyAsksToWrite("I can't write the mail here today"))
        XCTAssertFalse(IntentRouter.clearlyAsksToWrite("how do I write a cover letter here"))
    }

    // MARK: Filler words

    func testFillersAreIgnoredForRouting() {
        XCTAssertEqual(RoutingText.stripFillers("uh, um, write a mail, you know, to HR"), "write a mail, to HR")
        XCTAssertEqual(RoutingText.stripFillers("äh, schreib eine Mail"), "schreib eine Mail")
        XCTAssertEqual(RoutingText.stripFillers("えっと、メールを書いて"), "メールを書いて")
        XCTAssertEqual(RoutingText.stripFillers("I like pizza"), "I like pizza")
    }

    func testFillersAreKeptInTheTextSentToTheModel() async {
        let capturing = CapturingTransport()
        let client = RouterClient(serverToken: "test", transport: capturing)
        let spoken = "uh, so, um, the thing from before"
        _ = await client.classify(text: spoken, flags: RouterFlags(), timeout: 1)
        let body = String(data: capturing.requests.first?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("uh, so, um, the thing from before"))
    }

    func testClausesSplitOnConnectors() {
        XCTAssertEqual(RoutingText.clauses("I want to resign. Uh, so write a mail to HR here"),
                       ["I want to resign", "write a mail to HR here"])
        XCTAssertTrue(RoutingText.clauses("No me gusta, así que escribe un correo").contains("escribe un correo"))
    }

    // MARK: Privacy

    func testRouterNeverReceivesImagesFilesOrSelectedText() throws {
        var flags = RouterFlags()
        flags.hasSelectedText = true
        flags.selectionLooksLikeCode = true
        flags.filesAttached = true
        flags.frontmostApp = "Xcode"
        let body = HybridRouter.requestBody(text: "fix it", flags: flags)
        let data = try JSONSerialization.data(withJSONObject: body)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"image\""))
        XCTAssertFalse(json.contains("base64"))
        XCTAssertFalse(json.contains("\"document\""))
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        // Every message is plain text: the user's words + flags, and the JSON prefill.
        XCTAssertTrue(messages.allSatisfy { $0["content"] is String })
        XCTAssertEqual(messages.count, 2)
        // RouterFlags has no field that could carry text other than the app name.
        let labels = Mirror(reflecting: flags).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), ["hasSelectedText", "selectionLooksLikeCode", "recentBibblesWriting",
                                     "textFieldFocused", "frontmostApp", "filesAttached", "screenHotkeyUsed"])
    }

    func testRequestSettings() {
        let body = HybridRouter.requestBody(text: "hi", flags: RouterFlags())
        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5-20251001")
        XCTAssertEqual(body["max_tokens"] as? Int, 40)
        XCTAssertEqual(body["temperature"] as? Int, 0)
        XCTAssertNil(body["thinking"])
    }

    // MARK: Deep tasks

    func testDeepWithNoDeepTasksLeftIsLight() {
        XCTAssertEqual(ToolGate.mode(for: .deep, preference: .auto, deepTasksLeft: 0), .ask)
        XCTAssertEqual(ToolGate.mode(for: .deep, preference: .auto, deepTasksLeft: 3), .deep)
        XCTAssertEqual(ToolGate.mode(for: .simple, preference: .auto, deepTasksLeft: 3), .ask)
    }

    // MARK: Customer path: the router goes only to the Bibbles server

    func testServerRouterRequestHasNoProviderKey() throws {
        let request = try RouterClient(serverToken: "user-token").urlRequest(text: "hi", flags: RouterFlags())
        XCTAssertTrue(request.url?.absoluteString.hasPrefix(WorkerAPI.baseURL.absoluteString) == true)
        XCTAssertTrue(request.url?.path.hasSuffix("/v1/route") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-token")
        XCTAssertFalse((request.allHTTPHeaderFields ?? [:]).keys.contains { $0.lowercased().hasSuffix("api-key") })
    }

    #if BIBBLES_DEVELOPER
    // MARK: Developer builds only

    func testDeveloperKeyRequestGoesStraightToAnthropic() throws {
        let request = try RouterClient(key: "dev-key").urlRequest(text: "hi", flags: RouterFlags())
        XCTAssertEqual(request.url, HybridRouter.messagesURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "dev-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: Test set

    func testTestSetCoversEveryRouteAndLanguage() {
        let cases = RouterTestSet.cases
        XCTAssertGreaterThanOrEqual(cases.count, 140)
        XCTAssertEqual(Set(cases.map(\.expected)), Set(HybridRoute.allCases))
        XCTAssertTrue(Set(["English", "Spanish", "German", "Portuguese", "French", "Japanese", "Italian", "Dutch", "Hindi", "Mixed"])
            .isSubset(of: Set(cases.map(\.language))))
    }

    func testPromptExamplesDoNotLeakIntoTheTestSet() {
        for item in RouterTestSet.cases {
            XCTAssertFalse(RouterPrompt.system.contains(item.text), item.text)
        }
    }
    #endif
}
