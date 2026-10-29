import XCTest
@testable import BibblesApp

final class ToolGateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ToolGate.isEnabled = true
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ToolGate.enabledKey)
        super.tearDown()
    }

    private func route(_ text: String, recentWriting: Bool = false, file: StaticString = #filePath,
                       line: UInt = #line) -> ToolGate.Route {
        ToolGate.classify(text, context: ToolGate.Context(hasRecentWriting: recentWriting)).route
    }

    private func assertRoute(_ expected: ToolGate.Route, _ texts: [String], recentWriting: Bool = false,
                             file: StaticString = #filePath, line: UInt = #line) {
        for text in texts {
            XCTAssertEqual(route(text, recentWriting: recentWriting), expected, text, file: file, line: line)
        }
    }

    // MARK: Language detection

    func testDetectsLanguages() {
        let samples: [(String, String)] = [
            ("What's the weather like in Berlin today?", "en"),
            ("Wie spät ist es heute in Tokio?", "de"),
            ("Quelle heure est-il à Tokyo maintenant ?", "fr"),
            ("¿Qué hora es ahora mismo en Tokio?", "es"),
            ("Che ore sono adesso a Tokyo?", "it"),
            ("Que horas são agora em Tóquio?", "pt"),
            ("टोक्यो में अभी कितने बजे हैं?", "hi"),
            ("isko chhota karo yaar", "hinglish"),
            ("mujhe ek mail likh do", "hinglish")
        ]
        for (text, code) in samples {
            XCTAssertEqual(ToolGate.detectLanguage(text).code, code, text)
        }
    }

    // MARK: Routes

    func testTimeQuestionsAreAnsweredLocallyInEveryLanguage() {
        assertRoute(.localAnswer, ["what's the time in Tokyo", "wie spät ist es in Tokio", "quelle heure est-il à Tokyo",
                                   "qué hora es en Tokio", "che ore sono a Tokyo", "que horas são em Tóquio",
                                   "टोक्यो में कितने बजे हैं"])
    }

    func testWorldTimeAnswersUseTheUsersLanguage() throws {
        let date = Date(timeIntervalSince1970: 0) // 09:00 in Tokyo
        let german = try XCTUnwrap(LocalQuickAnswer.answer(for: "wie spät ist es in Tokio", now: date))
        XCTAssertTrue(german.contains("Tokio"), german)
        XCTAssertTrue(german.contains("09:00") || german.contains("9:00"), german)
        let spanish = try XCTUnwrap(LocalQuickAnswer.answer(for: "qué hora es en Tokio", now: date))
        XCTAssertTrue(spanish.hasPrefix("En Tokio"), spanish)
        // Unknown places are left to the AI rather than guessed.
        XCTAssertNil(LocalQuickAnswer.answer(for: "wie spät ist es in Blubberhausen", now: date))
    }

    func testWeatherQuestionsInEveryLanguage() {
        assertRoute(.weather, ["weather in Berlin", "Wetter in Berlin", "météo à Paris", "tiempo en Madrid",
                               "che tempo fa a Roma", "previsão do tempo em Lisboa", "दिल्ली का मौसम"])
        XCTAssertEqual(WeatherQuery.parse("Wetter in Berlin")?.city, "Berlin")
        XCTAssertEqual(WeatherQuery.parse("météo à Paris demain")?.city, "Paris")
        XCTAssertEqual(WeatherQuery.parse("météo à Paris demain")?.tomorrow, true)
        XCTAssertEqual(WeatherQuery.parse("tiempo en Madrid")?.language, "es")
        XCTAssertEqual(WeatherQuery.parse("dime el tiempo en Madrid")?.city, "Madrid")
        XCTAssertEqual(WeatherQuery.parse("दिल्ली का मौसम")?.city, "दिल्ली")
        XCTAssertNil(WeatherQuery.parse("llevo mucho tiempo en esta empresa"))
        XCTAssertNil(WeatherQuery.parse("pasé tiempo en Madrid"))
    }

    func testWriteRequestsInEveryLanguage() {
        assertRoute(.write, ["write an email to my boss", "schreib eine E-Mail an meinen Chef", "écris un mail à mon patron",
                             "escribe un correo a mi jefe", "scrivi una email al mio capo",
                             "escreva um email para o meu chefe", "मेरे बॉस को एक ईमेल लिखो"])
        XCTAssertTrue(IntentRouter().isWriteRequest("schreib eine E-Mail an meinen Chef"))
        XCTAssertFalse(IntentRouter().isWriteRequest("wie schreibe ich eine Bewerbung"))
    }

    func testEditRequestsAfterWriting() {
        assertRoute(.edit, ["make it shorter", "mach es kürzer", "rends-le plus court", "hazlo más corto",
                            "isko chhota karo", "rendilo più corto", "deixa mais curto", "इसे छोटा करो"],
                    recentWriting: true)
        XCTAssertTrue(EditRequest.isEdit("mach es kürzer"))
        // An ordinary question with a comparative is not an edit.
        XCTAssertFalse(EditRequest.isEdit("¿cuál es el camino más corto a Madrid?"))
    }

    func testScreenQuestionsInEveryLanguage() {
        assertRoute(.screen, ["what is this error on my screen", "was ist dieser Fehler auf meinem Bildschirm",
                              "quelle est cette erreur sur mon écran", "qué es este error en mi pantalla",
                              "cos'è questo errore sul mio schermo", "o que é este erro na minha tela",
                              "मेरी स्क्रीन पर यह एरर क्या है"])
    }

    func testLiveInformationSearchesInEveryLanguage() {
        assertRoute(.search, ["bitcoin price today", "Bitcoin Preis heute", "prix du bitcoin aujourd'hui",
                              "precio del bitcoin hoy", "prezzo del bitcoin oggi", "preço do bitcoin hoje",
                              "आज बिटकॉइन की कीमत"])
    }

    func testRouterUsesTheGateForOtherLanguages() {
        let router = IntentRouter()
        XCTAssertEqual(router.route(transcript: "Wetter in Berlin", mode: .command), .search(query: "Wetter in Berlin"))
        XCTAssertEqual(router.route(transcript: "was ist auf meinem Bildschirm", mode: .command),
                       .screen(question: "was ist auf meinem Bildschirm"))
        XCTAssertEqual(router.route(transcript: "What is photosynthesis?", mode: .command), .chat(message: "What is photosynthesis?"))
    }

    func testHardWorkGoesDeepOnlyWhenDeepTasksAreLeft() {
        let code = """
        Warum stürzt das ab?
        ```swift
        func load() {
            let items = try! decode()
            for item in items { print(item.name!) }
        }
        ```
        """
        XCTAssertEqual(route(code), .deep)
        XCTAssertEqual(route("Beweise, dass √2 irrational ist: √2 = a/b ⇒ 2b² = a²"), .deep)
        XCTAssertEqual(route(String(repeating: "Ceci est un long texte collé. ", count: 90)), .deep)
        XCTAssertEqual(ToolGate.mode(for: .deep, preference: .auto, deepTasksLeft: 3), .deep)
        XCTAssertEqual(ToolGate.mode(for: .deep, preference: .auto, deepTasksLeft: 0), .ask)
        XCTAssertEqual(ToolGate.mode(for: .deep, preference: .auto, deepTasksLeft: nil), .ask)
        XCTAssertEqual(ToolGate.mode(for: .deep, preference: .haiku, deepTasksLeft: 3), .ask)
        XCTAssertEqual(ToolGate.mode(for: .simple, preference: .sonnet, deepTasksLeft: 3), .deep)
        XCTAssertEqual(ToolGate.mode(for: .simple, preference: .sonnet, deepTasksLeft: 0), .ask)
        XCTAssertEqual(ToolGate.mode(for: .unclear, preference: .auto, deepTasksLeft: 9), .ask)
        XCTAssertEqual(ToolGate.mode(for: .search, preference: .sonnet, deepTasksLeft: 9), .search)
    }

    func testUnknownOrAmbiguousRequestsStayUnclear() {
        assertRoute(.unclear, ["xqzv blorp wuggle", "can you help me with this", "kannst du das hier machen",
                               "explique-moi ça"])
        assertRoute(.simple, ["hello", "Hallo", "What is photosynthesis?", "¿Quién escribió Don Quijote?"])
    }

    func testHistoryPerRoute() {
        XCTAssertEqual(ToolGate.historyLimit(for: .simple), 4)
        XCTAssertEqual(ToolGate.historyLimit(for: .write), 2)
        XCTAssertEqual(ToolGate.historyLimit(for: .edit), 0)
        XCTAssertEqual(ToolGate.historyLimit(for: .search), 0)
        XCTAssertEqual(ToolGate.historyLimit(for: .unclear), 12)
    }

    // MARK: Prompts

    func testReplyLanguageRuleIsInEverySystemPrompt() {
        let rule = ToolGate.replyLanguageRule
        let prompts = [
            ToolGate.corePrompt(),
            ChatConversationStore.fullPrompt(languageRule: rule, useWebSearch: false, writeMode: false, editing: false),
            ChatConversationStore.fullPrompt(languageRule: rule, useWebSearch: true, writeMode: true, editing: true),
            MessagesVisionProvider.screenSystemPrompt(),
            ScreenWriter.systemPrompt,
            ClaudeFixer.systemPrompt,
            ClaudeFileActionPlanner.systemPrompt,
            ClaudeFormPlanner.systemPrompt,
            CommandAgent.systemPrompt()
        ]
        for prompt in prompts {
            XCTAssertTrue(prompt.contains(rule), String(prompt.prefix(80)))
            XCTAssertFalse(prompt.contains("including Hinglish."), String(prompt.prefix(80)))
        }
    }

    // MARK: Local answers

    func testFahrenheitOnlyWhereItIsUsed() {
        XCTAssertTrue(LiveWeather.usesFahrenheit(locale: Locale(identifier: "en_US")))
        for identifier in ["de_DE", "fr_FR", "es_ES", "en_GB", "en_IN"] {
            XCTAssertFalse(LiveWeather.usesFahrenheit(locale: Locale(identifier: identifier)), identifier)
        }
    }

    func testLocalizedWeatherSentence() {
        let forecast = LiveWeather.Forecast(unit: "°C", current: 21.4, feelsLike: 21, humidity: 40, code: 0,
                                            todayMax: 24, todayMin: 13, todayRain: 10)
        let place = LiveWeather.Place(name: "Berlin", latitude: 52.5, longitude: 13.4)
        let german = LiveWeather.describe(forecast, place: place, tomorrow: false, language: "de")
        XCTAssertTrue(german.hasPrefix("Aktuell in Berlin: 21°C, klar."), german)
        XCTAssertTrue(german.contains("13°C bis 24°C"), german)
    }

    // MARK: Speech language

    func testSpeechLanguageKeepsOldSavedChoices() {
        XCTAssertEqual(SpeechLanguage.resolve(saved: "english"), .englishOnly)
        XCTAssertEqual(SpeechLanguage.resolve(saved: "en"), .englishOnly)
        XCTAssertEqual(SpeechLanguage.resolve(saved: "hindi").code, "hi")
        XCTAssertEqual(SpeechLanguage.resolve(saved: "auto"), .auto)
        XCTAssertEqual(SpeechLanguage.resolve(saved: "en-only"), .englishOnly)
        XCTAssertEqual(SpeechLanguage.englishOnly.requestCode, "en")
        XCTAssertEqual(SpeechLanguage.englishOnly.title, "English")
        XCTAssertEqual(SpeechLanguage(code: "en").title, "English & Hinglish")
        XCTAssertEqual(Array(SpeechLanguage.all.prefix(3)).map(\.code), ["auto", "en-only", "es"])
        XCTAssertEqual(SpeechLanguage.resolve(saved: "fr").code, "fr")
        XCTAssertEqual(SpeechLanguage.resolve(saved: nil, preferred: ["de-DE"]).code, "de")
        XCTAssertEqual(SpeechLanguage.resolve(saved: nil, preferred: ["zh-Hans-CN"]).code, "zh")
        XCTAssertEqual(SpeechLanguage.resolve(saved: nil, preferred: ["no-NO"]).code, "nb")
        XCTAssertEqual(SpeechLanguage.resolve(saved: nil, preferred: ["el-GR"]), .auto)
        XCTAssertNil(SpeechLanguage.auto.requestCode)
        // Auto and English-only are distinct choices in addition to the language list.
        XCTAssertEqual(SpeechLanguage.all.count, SpeechLanguage.supported.count + 2)
    }

    func testTranscribeSendsTheLanguageOnlyWhenChosen() {
        let chosen = WorkerAPI.request(path: "v1/transcribe", method: "POST", token: "t",
                                       query: [URLQueryItem(name: "language", value: "de")])
        XCTAssertEqual(chosen.url?.absoluteString, "https://bibbles-api.bibbles.workers.dev/v1/transcribe?language=de")
        let auto = WorkerAPI.request(path: "v1/transcribe", method: "POST", token: "t")
        XCTAssertEqual(auto.url?.absoluteString, "https://bibbles-api.bibbles.workers.dev/v1/transcribe")
    }

    // MARK: Speed and logging

    func testDecisionIsFast() {
        _ = ToolGate.classify("warm up")
        let samples = ["Wetter in Berlin", "what's the time in Tokyo", "schreib eine E-Mail an meinen Chef",
                       "precio del bitcoin hoy", "explique-moi la photosynthèse", "isko chhota karo"]
        let start = Date()
        for _ in 0..<20 { for text in samples { _ = ToolGate.classify(text) } }
        let average = Date().timeIntervalSince(start) / Double(20 * samples.count)
        XCTAssertLessThan(average, 0.005, "average \(average * 1000) ms")
    }

    func testStreamUsageIsRead() {
        let start = #"{"type":"message_start","message":{"usage":{"input_tokens":812,"output_tokens":1}}}"#
        XCTAssertEqual(ChatStreamParser.usage(from: start)?.input, 812)
        let delta = #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":94}}"#
        XCTAssertEqual(ChatStreamParser.usage(from: delta)?.output, 94)
        let openAI = #"{"choices":[],"usage":{"prompt_tokens":300,"completion_tokens":20}}"#
        XCTAssertEqual(ChatStreamParser.usage(from: openAI)?.input, 300)
        XCTAssertNil(ChatStreamParser.usage(from: #"{"type":"content_block_delta"}"#))
    }

    @MainActor func testLogNeverStoresTextAndIsOffByDefault() {
        let log = ToolGateLog.shared
        let wasRecording = log.isRecording
        defer { log.isRecording = wasRecording; log.clear() }
        log.isRecording = false
        log.clear()
        log.recordLocal(route: .localAnswer, text: "secret question", started: Date())
        XCTAssertTrue(log.entries.isEmpty)
        log.isRecording = true
        log.recordLocal(route: .localAnswer, text: "secret question", started: Date())
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertFalse(log.table().contains("secret"))
    }
}

final class TranscriptParsingTests: XCTestCase {
    func testReadsEveryTranscriptShape() {
        func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        let deepgram = data(["results": ["channels": [["alternatives": [["transcript": " hallo welt "]]]]]])
        XCTAssertEqual(WorkerAPI.transcript(from: deepgram), "hallo welt")
        XCTAssertEqual(WorkerAPI.transcript(from: data(["text": "bonjour"])), "bonjour")
        XCTAssertEqual(WorkerAPI.transcript(from: data(["transcript": "hola"])), "hola")
        XCTAssertNil(WorkerAPI.transcript(from: data(["text": "  "])))
        XCTAssertNil(WorkerAPI.transcript(from: Data("not json".utf8)))
    }
}
