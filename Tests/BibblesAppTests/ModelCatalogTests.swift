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
