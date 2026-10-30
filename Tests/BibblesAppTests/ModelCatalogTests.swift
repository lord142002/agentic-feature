#if BIBBLES_DEVELOPER
import XCTest
@testable import BibblesApp

final class ModelCatalogTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "bibbles.tests.models.\(UUID().uuidString)")
    }

    func testDefaultsMatchTheTask() {
        XCTAssertEqual(ModelCatalog.selected(.light, defaults: defaults).id, "deepseek/deepseek-v4.1-flash")
        XCTAssertEqual(ModelCatalog.selected(.deep, defaults: defaults).id, "claude-sonnet-5-5")
        XCTAssertEqual(ModelCatalog.selected(.router, defaults: defaults).id, "claude-haiku-4-5-20251001")
        XCTAssertEqual(ModelCatalog.selected(.agentPlanner, defaults: defaults).id, "openai/gpt-5-mini")
        XCTAssertEqual(ModelCatalog.selected(.agentBackup, defaults: defaults).id, "claude-haiku-4-5-20251001")
        XCTAssertEqual(ModelCatalog.selected(.screenAgent, defaults: defaults).id, "openai/gpt-5-mini")
        XCTAssertEqual(ModelCatalog.choices(for: .agentPlanner).map(\.name),
                       ["GPT-5 mini", "Haiku 5.5", "Gemini 3.8 Flash", "Haiku 4.5", "Sonnet 5.5"])
        XCTAssertEqual(ModelCatalog.choices(for: .agentBackup).map(\.name), ["Haiku 4.5", "Haiku 5.5"])
    }

    func testPickedModelIsSavedAndUnknownIDsFallBack() {
        ModelCatalog.select(ModelCatalog.haiku55, for: .agentPlanner, defaults: defaults)
        XCTAssertEqual(ModelCatalog.selected(.agentPlanner, defaults: defaults), ModelCatalog.haiku55)
        // A model that isn't offered for this feature is ignored.
        ModelCatalog.select(ModelCatalog.gpt5Mini, for: .deep, defaults: defaults)
        XCTAssertEqual(ModelCatalog.selected(.deep, defaults: defaults), ModelCatalog.sonnet55)
        defaults.set("some/old-model", forKey: ModelCatalog.defaultsKey(for: .light))
        XCTAssertEqual(ModelCatalog.selected(.light, defaults: defaults), ModelCatalog.deepSeekFlash)
    }

    func testJevRouterIsARouterOptionThroughOpenRouter() {
        XCTAssertEqual(ModelCatalog.choices(for: .router).map(\.id),
                       ["claude-haiku-4-5-20251001", "typesafe/jev-1.14", "typesafe/jev-router"])
        XCTAssertEqual(ModelCatalog.jevRouter.provider, .openrouter)
        XCTAssertNil(ModelCatalog.estimatedCost(model: "typesafe/jev-router", inputTokens: 100, outputTokens: 10),
                     "its price varies: the cost log uses OpenRouter's own figure")
        let body = HybridRouter.openRouterBody(model: "typesafe/jev-router", text: "export this to pdf", flags: RouterFlags())
        XCTAssertEqual(body["model"] as? String, "typesafe/jev-router")
        XCTAssertNil(body["temperature"])
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.map { $0["role"] as? String }, ["system", "user"],
                       "no pre-filled assistant answer on OpenRouter")
    }

    func testJevDecidesTheRouteItself() {
        var client = RouterClient(key: "sk-or-test")
        client.openRouterModel = ModelCatalog.jev.id
        XCTAssertTrue(client.usesDecisionsAPI)
        let request = try? client.urlRequest(text: "export this to pdf", flags: RouterFlags())
        XCTAssertEqual(request?.url, HybridRouter.decisionsURL)
        client.openRouterModel = ModelCatalog.jevRouter.id
        XCTAssertFalse(client.usesDecisionsAPI, "Jev Router uses the chat endpoint")

        // One Choice question; the options are the router prompt's routes.
        let body = HybridRouter.decisionsBody(model: "typesafe/jev-1.14", text: "export this to pdf", flags: RouterFlags())
        let question = (body["questions"] as? [String: Any])?["route"] as? [String: Any]
        XCTAssertEqual(question?["type"] as? String, "choice")
        let options = Set((question?["criteria"] as? [String: String])?.keys.map { $0 } ?? [])
        XCTAssertTrue(options.isSuperset(of: ["simple", "write", "screen", "command", "unclear"]), "\(options)")
        XCTAssertEqual((body["state"] as? [String: Any])?["request"] as? String, "export this to pdf")

        // The answer: the chosen route with its own probability.
        let reply = #"{"model":"typesafe/jev-1.14-20261014","answers":{"route":{"type":"choice","choice":"command","confidence":0.67,"probabilities":{"command":0.91,"screen":0.09}}},"usage":{"input_tokens":900,"output_tokens":5,"cost":0.0000378}}"#
        let result = HybridRouter.parseDecision(Data(reply.utf8))
        XCTAssertEqual(result?.route, .command)
        XCTAssertEqual(result?.confidence ?? 0, 0.91, accuracy: 0.001)
        XCTAssertNil(HybridRouter.parseDecision(Data(#"{"answers":{"route":{"choice":"fly"}}}"#.utf8)))
    }

    func testGPT61SolIsADeepOptionThroughOpenRouter() {
        XCTAssertEqual(ModelCatalog.choices(for: .deep).map(\.id), ["claude-sonnet-5-5", "openai/gpt-6.1-sol"])
        XCTAssertEqual(ModelCatalog.selected(.deep, defaults: defaults).id, "claude-sonnet-5-5", "Sonnet 5.5 stays the default")
        XCTAssertEqual(ModelCatalog.gpt61Sol.provider, .openrouter)
        XCTAssertFalse(ModelCatalog.gpt61Sol.acceptsTemperature)
        let vision = LocalBackend.openRouterVisionBody(["temperature": 0.2, "max_tokens": 50_000,
                                                        "messages": [["role": "user", "content": "hi"]]],
                                                       model: "openai/gpt-6.1-sol", cap: LocalBackend.deepMaxTokens)
        XCTAssertNil(vision["temperature"], "GPT-6.1 Sol takes no temperature")
        XCTAssertEqual(vision["max_tokens"] as? Int, LocalBackend.deepMaxTokens)
    }

    func testOnlyPinnedIDs() {
        for model in ModelCatalog.all {
            XCTAssertFalse(model.id.contains("latest"), model.id)
            XCTAssertFalse(model.id.hasPrefix("~"), model.id)
        }
        XCTAssertFalse(ModelCatalog.speechToText.contains("latest"))
        XCTAssertFalse(ModelCatalog.textToSpeech.contains("latest"))
    }
}
#endif
