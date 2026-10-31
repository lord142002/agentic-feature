#if BIBBLES_DEVELOPER
import Foundation
import XCTest
@testable import BibblesApp

/// Answers every request locally and remembers what was sent. Nothing leaves the Mac.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var body = Data()
    }

    private static let lock = NSLock()
    private static var storedRequests: [URLRequest] = []
    /// Picks the reply for a request (by host, path…).
    static var reply: (URLRequest) -> Reply = { _ in Reply() }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    static func reset() {
        lock.lock()
        storedRequests = []
        lock.unlock()
        reply = { _ in Reply() }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// The body, also when URLSession moved it into a stream.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static func json(of request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body(of: request))) as? [String: Any] ?? [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        recorded.httpBody = Self.body(of: request)
        Self.lock.lock()
        Self.storedRequests.append(recorded)
        Self.lock.unlock()
        let reply = Self.reply(recorded)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LocalBackendTests: XCTestCase {
    private let anthropicReply = Data(#"{"content":[{"type":"text","text":"hello"}],"usage":{"input_tokens":10,"output_tokens":5}}"#.utf8)
    private let openRouterReply = Data(#"{"choices":[{"message":{"content":"hello"}}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#.utf8)
    private let messages = [["role": "system", "content": "Be brief."], ["role": "user", "content": "hi"]]

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        DeveloperKeychain.testOverride = [:]
        LocalMode.testOverride = false
        WorkerAPI.testAccessToken = "test-token"
    }

    override func tearDown() {
        StubURLProtocol.reset()
        DeveloperKeychain.testOverride = nil
        LocalMode.testOverride = nil
        WorkerAPI.testAccessToken = nil
        super.tearDown()
    }

    private func useKeys(_ slots: [DeveloperKeySlot]) {
        DeveloperKeychain.testOverride = Dictionary(uniqueKeysWithValues: slots.map { ($0, "test-\($0.rawValue)-key") })
    }

    private var bibblesRequests: [URLRequest] {
        StubURLProtocol.requests.filter { $0.url?.host?.contains("bibbles") == true }
    }

    // MARK: Local mode OFF = today's Worker requests

    /// The request today's code built before Local mode existed: same URL,
    /// method, headers and JSON body. (The Idempotency-Key is a fresh UUID per
    /// action by design, so only its presence is compared.)
    private func assertSameAsBefore(_ request: URLRequest, path: String, method: String, contentType: String?,
                                    body expected: [String: Any]?, query: String? = nil,
                                    file: StaticString = #filePath, line: UInt = #line) {
        var url = WorkerAPI.baseURL.appendingPathComponent(path)
        if let query { url = URL(string: url.absoluteString + "?" + query)! }
        XCTAssertEqual(request.url, url, file: file, line: line)
        XCTAssertEqual(request.httpMethod, method, file: file, line: line)
        XCTAssertEqual(request.timeoutInterval, 120, file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token", file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), contentType, file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key") != nil, method != "GET", file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: DeviceIdentity.headerName), DeviceIdentity.hashedID, file: file, line: line)
        let headers = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        XCTAssertTrue(headers.isSubset(of: ["authorization", "content-type", "idempotency-key", DeviceIdentity.headerName.lowercased()]),
                      "no new headers: \(headers)", file: file, line: line)
        if let expected {
            XCTAssertEqual(StubURLProtocol.json(of: request) as NSDictionary, expected as NSDictionary, file: file, line: line)
        }
    }

    func testLocalModeOffChatRequestIsUnchanged() async throws {
        StubURLProtocol.reply = { _ in .init(body: self.anthropicReply) }
        let text = try await WorkerAPI.chat(mode: .ask, messages: messages, maxTokens: 700, session: StubURLProtocol.session())
        XCTAssertEqual(text, "hello")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        assertSameAsBefore(request, path: "v1/chat", method: "POST", contentType: "application/json",
                           body: ["mode": "ask", "messages": [["role": "user", "content": "hi"]], "stream": false,
                                  "system": "Be brief.", "max_tokens": 700])
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testLocalModeOffStreamRequestIsUnchanged() async throws {
        StubURLProtocol.reply = { _ in
            .init(body: Data("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n".utf8))
        }
        let result = try await WorkerAPI.chatStream(mode: .deep, messages: messages, maxTokens: 4_096,
                                                    session: StubURLProtocol.session(), onUpdate: { _ in })
        XCTAssertEqual(result.text, "hi")
        assertSameAsBefore(try XCTUnwrap(StubURLProtocol.requests.first), path: "v1/chat", method: "POST",
                           contentType: "application/json",
                           body: ["mode": "deep", "messages": [["role": "user", "content": "hi"]], "stream": true,
                                  "system": "Be brief.", "max_tokens": 4_096])
    }

    func testLocalModeOffSpeechVisionTranscribeAndUsageAreUnchanged() async throws {
        let session = StubURLProtocol.session()
        StubURLProtocol.reply = { request in
            switch request.url?.path {
            case "/v1/tts": return .init(body: Data(repeating: 1, count: 200))
            case "/v1/transcribe": return .init(body: Data(#"{"text":"hello there"}"#.utf8))
            case "/v1/me": return .init(body: Data(#"{"plan":"alpha","month":"2026-10","usage":{},"limits":{}}"#.utf8))
            default: return .init(body: self.anthropicReply)
            }
        }
        _ = try await WorkerAPI.speechPCM(text: "Hi", voice: "Kore", session: session)
        _ = try await WorkerAPI.vision(body: ["model": "m", "max_tokens": 10, "messages": [["role": "user", "content": "x"]]],
                                       tier: .light, session: session)
        let wav = Data("RIFF".utf8) + Data(repeating: 0, count: 100)
        let text = try await WorkerAPI.transcribe(wav: wav, language: "de", session: session)
        XCTAssertEqual(text, "hello there")
        _ = try await WorkerAPI.me(session: session)
        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.count, 4)
        assertSameAsBefore(requests[0], path: "v1/tts", method: "POST", contentType: "application/json",
                           body: ["text": "Hi", "voice": "Kore"])
        assertSameAsBefore(requests[1], path: "v1/vision", method: "POST", contentType: "application/json",
                           body: ["tier": "light", "max_tokens": 10, "messages": [["role": "user", "content": "x"]]])
        assertSameAsBefore(requests[2], path: "v1/transcribe", method: "POST", contentType: "audio/wav", body: nil,
                           query: "language=de")
        XCTAssertEqual(StubURLProtocol.body(of: requests[2]), wav)
        assertSameAsBefore(requests[3], path: "v1/me", method: "GET", contentType: nil, body: nil)
    }

    func testLocalModeOffRouterUsesTheServer() async throws {
        XCTAssertTrue(Backends.current is WorkerBackend)
        let routerClient = await Backends.current.routerClient()
        let client = try XCTUnwrap(routerClient)
        XCTAssertTrue(client.viaServer)
        XCTAssertEqual(try client.urlRequest(text: "hi", flags: RouterFlags()).url?.path, "/v1/route")
    }

    func testLocalModeIsOffByDefault() {
        LocalMode.testOverride = nil
        let saved = UserDefaults.standard.object(forKey: LocalMode.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: LocalMode.defaultsKey) }
        UserDefaults.standard.removeObject(forKey: LocalMode.defaultsKey)
        XCTAssertFalse(LocalMode.isOn)
        XCTAssertFalse(Backends.isLocal)
    }

    // MARK: Local mode ON = zero contact with the Bibbles server

    func testLocalModeOnNeverContactsTheBibblesServer() async throws {
        LocalMode.testOverride = true
        useKeys([.openrouter, .anthropic, .deepgram])
        let session = StubURLProtocol.session()
        StubURLProtocol.reply = { request in
            switch request.url?.path {
            case "/api/v1/audio/speech": return .init(body: Data(repeating: 1, count: 200))
            case "/api/v1/audio/transcriptions": return .init(body: Data(#"{"text":"hola"}"#.utf8))
            case "/v1/messages": return .init(body: self.anthropicReply)
            default: return .init(body: self.openRouterReply)
            }
        }
        XCTAssertTrue(Backends.current is LocalBackend)
        _ = try await WorkerAPI.chat(mode: .ask, messages: messages, session: session)
        _ = try await WorkerAPI.chat(mode: .search, messages: messages, session: session)
        _ = try await WorkerAPI.chat(mode: .deep, messages: messages, session: session)
        _ = try await WorkerAPI.speechPCM(text: "Hi", voice: "Kore", session: session)
        _ = try await WorkerAPI.transcribe(wav: Data(repeating: 0, count: 1_000), language: "es", session: session)
        _ = try await WorkerAPI.vision(body: ["max_tokens": 10, "messages": [["role": "user", "content": "x"]]],
                                       tier: .light, session: session)
        _ = try await WorkerAPI.vision(body: ["max_tokens": 10, "messages": [["role": "user", "content": "x"]]],
                                       tier: .deep, session: session)
        let liveRouter = await RouterClient.live()
        let router = try XCTUnwrap(liveRouter)
        XCTAssertFalse(router.viaServer)
        XCTAssertEqual(try router.urlRequest(text: "hi", flags: RouterFlags()).url?.host, "api.anthropic.com")
        do {
            _ = try await WorkerAPI.me(session: session)
        } catch {}
        do {
            try await WorkerAPI.deleteAccount(session: session)
            XCTFail("account deletion needs the server")
        } catch {
            XCTAssertEqual(error as? LocalBackendError, .serverOff)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 7)
        XCTAssertTrue(bibblesRequests.isEmpty, "Local mode sent \(bibblesRequests.map { $0.url!.absoluteString })")
        // Every OpenRouter request asks providers not to keep the data.
        for request in StubURLProtocol.requests where request.url?.host == "openrouter.ai" {
            XCTAssertEqual((StubURLProtocol.json(of: request)["provider"] as? [String: Any])?["data_collection"] as? String,
                           "deny", request.url!.path)
        }
        // No sign-in token goes to a provider.
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
    }

    func testLocalModeUsesTheLiveWorkerModelsAndLimits() async throws {
        LocalMode.testOverride = true
        useKeys([.openrouter, .anthropic])
        let session = StubURLProtocol.session()
        StubURLProtocol.reply = { request in
            .init(body: request.url?.host == "api.anthropic.com" ? self.anthropicReply : self.openRouterReply)
        }
        _ = try await WorkerAPI.chat(mode: .ask, messages: messages, maxTokens: 100_000, session: session)
        _ = try await WorkerAPI.chat(mode: .search, messages: messages, session: session)
        _ = try await WorkerAPI.chat(mode: .deep, messages: messages, maxTokens: 100_000, session: session)
        let light = StubURLProtocol.json(of: StubURLProtocol.requests[0])
        XCTAssertEqual(StubURLProtocol.requests[0].url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(light["model"] as? String, "deepseek/deepseek-v4.1-flash")
        XCTAssertEqual(light["max_tokens"] as? Int, 4_096)
        XCTAssertNil(light["plugins"])
        let search = StubURLProtocol.json(of: StubURLProtocol.requests[1])
        XCTAssertEqual((search["plugins"] as? [[String: Any]])?.first?["id"] as? String, "web")
        XCTAssertEqual((search["plugins"] as? [[String: Any]])?.first?["max_results"] as? Int, 5)
        let deep = StubURLProtocol.json(of: StubURLProtocol.requests[2])
        XCTAssertEqual(StubURLProtocol.requests[2].url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(deep["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(deep["max_tokens"] as? Int, 8_192)
        XCTAssertEqual(deep["system"] as? String, "Be brief.")
        XCTAssertEqual(StubURLProtocol.requests[2].value(forHTTPHeaderField: "x-api-key"), "test-anthropic-key")
        XCTAssertEqual(StubURLProtocol.requests[0].timeoutInterval, 90)
    }

    func testLightTasksFallBackToHaikuWhenOpenRouterFails() async throws {
        LocalMode.testOverride = true
        useKeys([.openrouter, .anthropic])
        StubURLProtocol.reply = { request in
            request.url?.host == "openrouter.ai" ? .init(status: 503, body: Data("{}".utf8)) : .init(body: self.anthropicReply)
        }
        let text = try await WorkerAPI.chat(mode: .ask, messages: messages, session: StubURLProtocol.session())
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertEqual(StubURLProtocol.json(of: StubURLProtocol.requests[1])["model"] as? String, "claude-haiku-4-5-20251001")
    }

    func testMissingKeyNamesTheKeyToAdd() async {
        LocalMode.testOverride = true
        useKeys([])
        do {
            _ = try await WorkerAPI.chat(mode: .ask, messages: messages, session: StubURLProtocol.session())
            XCTFail("needs a key")
        } catch {
            XCTAssertEqual(error as? LocalBackendError, .missingKey(.openrouter))
            XCTAssertEqual(error.localizedDescription, "Add your OpenRouter key in Settings → Developer.")
        }
        do {
            _ = try await WorkerAPI.chat(mode: .deep, messages: messages, session: StubURLProtocol.session())
            XCTFail("needs a key")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Add your Anthropic key in Settings → Developer.")
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "nothing is sent without a key")
    }

    func testProviderErrorsNameTheProblem() async {
        LocalMode.testOverride = true
        useKeys([.anthropic])
        StubURLProtocol.reply = { _ in .init(status: 401, body: Data("{}".utf8)) }
        do {
            _ = try await WorkerAPI.chat(mode: .deep, messages: messages, session: StubURLProtocol.session())
            XCTFail("401")
        } catch {
            XCTAssertEqual(error as? LocalBackendError, .provider(name: "Anthropic", status: 401, problem: "invalid key"))
        }
    }

    // MARK: Speech, vision limits

    func testSpeechMatchesTheWorkerContract() throws {
        let request = try LocalBackend.speechRequest(text: String(repeating: "a", count: 3_000), voice: "", key: "k")
        let body = StubURLProtocol.json(of: request)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/audio/speech")
        XCTAssertEqual(body["model"] as? String, "google/gemini-3.8-flash-lite-tts")
        XCTAssertEqual(body["voice"] as? String, "Kore")
        XCTAssertEqual(body["response_format"] as? String, "pcm")
        XCTAssertEqual((body["input"] as? String)?.count, 2_000)
    }

    func testTranscriptionMatchesTheWorkerContract() throws {
        let wav = Data(repeating: 7, count: 64)
        let request = try LocalBackend.transcriptionRequest(wav: wav, language: "hi", seconds: 4, key: "k")
        let body = StubURLProtocol.json(of: request)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/audio/transcriptions")
        XCTAssertEqual(body["model"] as? String, "nvidia/nemotron-3.5-asr-streaming-multilingual-0.6b")
        XCTAssertEqual((body["input_audio"] as? [String: Any])?["data"] as? String, wav.base64EncodedString())
        XCTAssertEqual((body["input_audio"] as? [String: Any])?["format"] as? String, "wav")
        XCTAssertEqual(body["language"] as? String, "hi")
        XCTAssertEqual(request.timeoutInterval, 7, accuracy: 0.001)
        XCTAssertEqual(LocalBackend.transcriptionTimeout(seconds: 60), 12)
        let deepgram = LocalBackend.deepgramRequest(wav: wav, language: nil, key: "dg")
        XCTAssertEqual(deepgram.url?.absoluteString, "https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true")
        XCTAssertEqual(deepgram.value(forHTTPHeaderField: "Authorization"), "Token dg")
    }

    func testTranscriptionFallsBackToDeepgram() async throws {
        LocalMode.testOverride = true
        useKeys([.openrouter, .deepgram])
        StubURLProtocol.reply = { request in
            request.url?.host == "openrouter.ai" ? .init(status: 500, body: Data())
                : .init(body: Data(#"{"results":{"channels":[{"alternatives":[{"transcript":"from deepgram"}]}]}}"#.utf8))
        }
        let text = try await WorkerAPI.transcribe(wav: Data(repeating: 0, count: 500), session: StubURLProtocol.session())
        XCTAssertEqual(text, "from deepgram")
    }

    func testVisionLimits() throws {
        let image: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "AAAA"]]
        let five: [String: Any] = ["messages": [["role": "user", "content": Array(repeating: image, count: 5)]]]
        XCTAssertThrowsError(try LocalBackend.checkVisionLimits(five)) { XCTAssertEqual($0 as? LocalBackendError, .tooManyImages) }
        let big: [String: Any] = ["messages": [["role": "user", "content": String(repeating: "x", count: 10_000_100)]]]
        XCTAssertThrowsError(try LocalBackend.checkVisionLimits(big)) { XCTAssertEqual($0 as? LocalBackendError, .payloadTooLarge) }
        let converted = LocalBackend.openRouterVisionBody(["system": "S", "max_tokens": 9_999,
                                                           "messages": [["role": "user", "content": [image, ["type": "text", "text": "what?"]]]]],
                                                          model: "deepseek/deepseek-v4.1-flash")
        let parts = ((converted["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]]) ?? []
        XCTAssertEqual((parts.first?["image_url"] as? [String: Any])?["url"] as? String, "data:image/jpeg;base64,AAAA")
        XCTAssertEqual(converted["max_tokens"] as? Int, 4_096)
        XCTAssertEqual((converted["messages"] as? [[String: Any]])?.first?["role"] as? String, "system")
    }

    func testDeepTasksThinkAtMediumEffort() throws {
        XCTAssertEqual(LocalBackend.deepEffort, "medium")
        let body = LocalBackend.withDeepEffort(LocalBackend.anthropicBody(
            model: "claude-sonnet-5-5", messages: [["role": "user", "content": "hi"]], maxTokens: 100, stream: false, search: false))
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertNil(body["thinking"], "adaptive thinking stays on (the model default)")
        let request = try LocalBackend.openRouterChatRequest(model: "openai/gpt-6.1-sol", messages: [["role": "user", "content": "hi"]],
                                                             maxTokens: 100, stream: false, search: false, key: "k", effort: "medium")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual((sent["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
        // Light requests carry no effort setting.
        let light = try LocalBackend.openRouterChatRequest(model: "deepseek/deepseek-v4.1-flash", messages: [["role": "user", "content": "hi"]],
                                                           maxTokens: 100, stream: false, search: false, key: "k")
        let lightSent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(light.httpBody)) as? [String: Any])
        XCTAssertNil(lightSent["reasoning"])
    }

    // MARK: Usage cache and badge

    func testUsageCacheKeepsOnlyUsageNumbers() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "bibbles.tests.usage.\(UUID().uuidString)"))
        LocalUsageCache.save(["plan": "sigma", "month": "2026-10", "usage": ["asks": 4], "limits": ["asks": 500],
                              "email": "someone@example.com", "token": "secret"], defaults: defaults)
        let cached = try XCTUnwrap(LocalUsageCache.load(defaults: defaults))
        XCTAssertEqual(Set(cached.payload.keys), ["plan", "month", "usage", "limits"])
        XCTAssertEqual(cached.snapshot?.counters.first?.remaining, 496)
        XCTAssertTrue(cached.label.hasPrefix("Last synced "))
        XCTAssertTrue(cached.label.hasSuffix("(Local mode — not counting)"))
    }

    func testPlanLimitsAreNotEnforcedInLocalMode() async {
        LocalMode.testOverride = true
        let left = await MainActor.run { ToolGate.deepTasksLeft }
        XCTAssertEqual(left, Int.max)
    }

    func testAnswerCardShowsTheLocalModeBadgeNeverAModelName() {
        LocalMode.testOverride = true
        XCTAssertEqual(ClaudeAPI.taskLabel(for: ClaudeAPI.smartModel), "Deep Task · LOCAL MODE")
        LocalMode.testOverride = false
        XCTAssertEqual(ClaudeAPI.taskLabel(for: ClaudeAPI.fastModel), "Light Task")
    }

    func testCostEstimatesUseThePriceTable() {
        XCTAssertEqual(ModelCatalog.estimatedCost(model: "claude-sonnet-5-5", inputTokens: 1_000_000, outputTokens: 1_000_000) ?? 0,
                       12, accuracy: 0.0001)
        XCTAssertNil(ModelCatalog.estimatedCost(model: "unknown", inputTokens: 1, outputTokens: 1))
        let usage = LocalCostLog.usage(in: openRouterReply)
        XCTAssertEqual(usage.input, 10)
        XCTAssertEqual(usage.output, 5)
    }
}
#endif
