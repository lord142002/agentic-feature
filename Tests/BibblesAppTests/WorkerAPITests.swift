import XCTest
@testable import BibblesApp

final class WorkerAPITests: XCTestCase {
    func testWorkerRequestHasOnlyBearerSessionAuthentication() {
        let request = WorkerAPI.request(path: "v1/chat", method: "POST", contentType: "application/json",
                                        body: Data("{}".utf8), token: "supabase-test-token")
        XCTAssertEqual(request.url?.absoluteString, "https://bibbles-api.bibbles.workers.dev/v1/chat")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer supabase-test-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testChatResponseShapes() throws {
        let normal = Data(#"{"choices":[{"message":{"content":"Hello"}}]}"#.utf8)
        let deep = Data(#"{"content":[{"type":"text","text":"Deep "},{"type":"text","text":"answer"}]}"#.utf8)
        XCTAssertEqual(try WorkerAPI.parseChat(deep, mode: .ask), "Deep answer")
        XCTAssertEqual(try WorkerAPI.parseChat(deep, mode: .nemotron), "Deep answer")
        XCTAssertEqual(try WorkerAPI.parseChat(deep, mode: .search), "Deep answer")
        XCTAssertEqual(try WorkerAPI.parseChat(deep, mode: .deep), "Deep answer")
        XCTAssertEqual(try WorkerAPI.parseChat(normal, mode: .ask), "Hello") // older deployment fallback
    }

    func testSystemPromptUsesDeployedWorkerField() {
        let body = WorkerAPI.chatBody(mode: .ask, messages: [
            ["role": "system", "content": "Be brief"], ["role": "user", "content": "Hello"]
        ], maxTokens: 100, stream: true)
        XCTAssertEqual(body["system"] as? String, "Be brief")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.count, 1)
    }

    func testTaskModesAreChosenDeterministically() {
        XCTAssertEqual(WorkerAPI.mode(forPrompt: "Hi"), .ask)
        XCTAssertEqual(WorkerAPI.mode(forPrompt: "Review this code for bugs"), .deep)
        XCTAssertEqual(WorkerAPI.mode(forPrompt: "Find today's news", search: true), .search)
        XCTAssertEqual(WorkerAPI.mode(forPrompt: "Review this code for bugs", forceFast: true), .ask)
    }

    func testFriendlyWorkerErrors() {
        XCTAssertEqual(WorkerError.from(status: 401, data: Data(#"{"error":"unauthorized"}"#.utf8)), .signInRequired)
        XCTAssertEqual(WorkerError.from(status: 429, data: Data(#"{"error":"limit_reached","counter":"transcriptions"}"#.utf8)), .limitReached("transcriptions"))
        XCTAssertEqual(WorkerError.from(status: 413, data: Data(#"{"error":"payload_too_large"}"#.utf8)), .payloadTooLarge)
        XCTAssertEqual(WorkerError.from(status: 503, data: Data(#"{"error":"mode_disabled"}"#.utf8)), .temporarilyUnavailable)
        XCTAssertEqual(WorkerError.from(status: 500, data: Data(#"{"error":"server_error"}"#.utf8)), .server)
    }

    func testUsageComputesRemainingFromServerValues() throws {
        let snapshot = try XCTUnwrap(WorkerUsageSnapshot([
            "plan": "sigma", "month": "2026-10", "usage": ["asks": 12, "deep": 2],
            "limits": ["asks": 100, "deep": 10], "min_app_version": "1.0.0"
        ]))
        XCTAssertEqual(snapshot.counters.first(where: { $0.id == "asks" })?.remaining, 88)
        XCTAssertEqual(snapshot.minimumAppVersion, "1.0.0")
        XCTAssertNil(snapshot.currentPlan)
        XCTAssertNil(snapshot.planHistory)
    }

    func testPlanDatesAndHistoryComeOnlyFromAuthoritativeFields() throws {
        let snapshot = try XCTUnwrap(WorkerUsageSnapshot([
            "plan": "plus", "month": "2026-10", "usage": ["asks": 4], "limits": ["asks": 500],
            "subscription": [
                "plan": "plus", "status": "active", "started_at": "2026-10-08T05:00:00Z",
                "access_ends_at": NSNull(), "renews_at": "2026-11-08T05:00:00Z"
            ],
            "plan_history": [
                ["plan": "alpha", "started_at": "2026-09-01T05:00:00Z",
                 "ended_at": "2026-10-08T05:00:00Z", "end_reason": "upgrade"]
            ]
        ]))
        XCTAssertEqual(snapshot.currentPlan?.plan, "plus")
        XCTAssertNil(snapshot.currentPlan?.accessEndsAt)
        XCTAssertNotNil(snapshot.currentPlan?.renewsAt)
        XCTAssertEqual(snapshot.planHistory?.first?.endReason, "upgrade")
        XCTAssertEqual(snapshot.planHistory?.count, 1)
    }

    func testInvalidPlanTimelineCannotBeShownAsCorrectDates() {
        let base: [String: Any] = ["plan": "alpha", "month": "2026-10",
                                   "usage": ["asks": 0], "limits": ["asks": 30]]
        var mismatched = base
        mismatched["subscription"] = ["plan": "plus", "status": "active",
                                       "started_at": "2026-10-08T05:00:00Z",
                                       "access_ends_at": NSNull(), "renews_at": NSNull()]
        // Usage still shows; the mismatched block is not trusted as the current plan.
        XCTAssertNil(WorkerUsageSnapshot(mismatched)?.currentPlan)
        XCTAssertNotNil(WorkerUsageSnapshot(mismatched))
        var reversed = base
        reversed["plan_history"] = [["plan": "alpha", "started_at": "2026-10-08T05:00:00Z",
                                     "ended_at": "2026-09-08T05:00:00Z", "end_reason": "downgrade"]]
        XCTAssertEqual(WorkerUsageSnapshot(reversed)?.planHistory?.count, 0)
    }

    func testPlanExpiryIsReadFromCommonFieldNames() throws {
        let snapshot = try XCTUnwrap(WorkerUsageSnapshot([
            "plan": "sigma", "month": "2026-10", "usage": ["asks": 0], "limits": ["asks": 450],
            "subscription": ["plan": "sigma", "expires_at": "2026-11-08 10:30:00+00"]
        ]))
        XCTAssertNotNil(snapshot.entitlement?.expiresAt)
        XCTAssertTrue(PlanEntitlement.isPremium(plan: snapshot.plan))
        XCTAssertFalse(PlanEntitlement.isPremium(plan: "alpha"))
        XCTAssertTrue(PlanEntitlement.isPremium(plan: "omega"))
        XCTAssertNotNil(PlanEntitlement(row: ["plan_expiry": "2026-12-01"]))
    }

    func testWorkerActionPlanRejectsUnregisteredTools() throws {
        let plan = try CommandAgent.parseWorkerPlan(#"{"calls":[{"name":"open_app","input":{"name":"Safari"}},{"name":"run_shell","input":{"command":"rm"}}],"text":""}"#)
        XCTAssertEqual(plan.calls.map(\.name), ["open_app"])
        XCTAssertEqual(plan.calls.first?.string("name"), "Safari")
    }

    func testVisionPayloadUsesTierAndStripsProviderModel() throws {
        let payload = try WorkerAPI.visionPayload(body: ["model": "old-provider-id", "messages": [
            ["role": "user", "content": [["type": "text", "text": "What is this?"]]]
        ]], tier: .light)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["tier"] as? String, "light")
        XCTAssertNil(object["model"])
    }

    // MARK: Charged once

    func testServerErrorIsNotRetriedSoOneQuestionIsChargedOnce() async throws {
        let session = CountingURLProtocol.session(status: 502)
        let request = WorkerAPI.request(path: "v1/vision", method: "POST", contentType: "application/json",
                                        body: Data("{}".utf8), token: "t")
        do {
            _ = try await WorkerAPI.perform(request, session: session)
            XCTFail("a 502 must surface to the user")
        } catch let error as WorkerError {
            XCTAssertEqual(error, .server)
        }
        XCTAssertEqual(CountingURLProtocol.requests.count, 1, "a failed paid request must be sent exactly once")
    }

    func testEveryPaidRequestCarriesAFreshIdempotencyKey() {
        let a = WorkerAPI.request(path: "v1/vision", method: "POST", body: Data(), token: "t")
        let b = WorkerAPI.request(path: "v1/vision", method: "POST", body: Data(), token: "t")
        let keyA = a.value(forHTTPHeaderField: "Idempotency-Key")
        XCTAssertNotNil(keyA)
        XCTAssertNotEqual(keyA, b.value(forHTTPHeaderField: "Idempotency-Key"), "each user action gets its own key")
        XCTAssertNil(WorkerAPI.request(path: "v1/me", method: "GET", token: "t").value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testRateLimitIsNotShownAsMonthlyLimit() {
        // A plain 429 is a short rate limit, not a used-up plan.
        XCTAssertEqual(WorkerError.from(status: 429, data: Data()), .rateLimited(retryAfter: nil))
        XCTAssertEqual(WorkerError.from(status: 429, data: Data(), retryAfter: "7"), .rateLimited(retryAfter: 7))
        XCTAssertEqual(WorkerError.from(status: 429, data: Data(#"{"error":"rate_limited","retry_after":3}"#.utf8)),
                       .rateLimited(retryAfter: 3))
        // Only an explicit quota answer is the monthly limit.
        XCTAssertEqual(WorkerError.from(status: 429, data: Data(#"{"error":"limit_reached","counter":"asks"}"#.utf8)),
                       .limitReached("asks"))
        XCTAssertEqual(WorkerError.from(status: 429, data: Data(#"{"counter":"deep_tasks"}"#.utf8)), .limitReached("deep_tasks"))
        XCTAssertEqual(WorkerError.from(status: 403, data: Data(#"{"error":"quota_exceeded","counter":"asks"}"#.utf8)),
                       .limitReached("asks"))

        let wait = WorkerError.rateLimited(retryAfter: 5).errorDescription ?? ""
        XCTAssertTrue(wait.contains("5 seconds"))
        XCTAssertFalse(wait.lowercased().contains("monthly"))
        XCTAssertTrue((WorkerError.limitReached("asks").errorDescription ?? "").contains("monthly"))
    }

    func testOnlyARejectedRequestCountsAsBadRequest() {
        XCTAssertEqual(WorkerError.from(status: 400, data: Data()), .badRequest)
        XCTAssertEqual(WorkerError.from(status: 422, data: Data(#"{"error":"unsupported_language"}"#.utf8)), .badRequest)
        XCTAssertEqual(WorkerError.from(status: 502, data: Data()), .server, "server failures are not re-sent")
    }
}

/// Answers every request with one status code and records what was sent.
final class CountingURLProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var status = 200

    static func session(status: Int) -> URLSession {
        requests = []
        self.status = status
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"upstream"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
