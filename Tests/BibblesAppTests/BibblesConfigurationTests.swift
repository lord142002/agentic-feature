import XCTest
@testable import BibblesApp

final class BibblesConfigurationTests: XCTestCase {
    @MainActor func testAnswerModelsDefaultToClaude() {
        let config = BibblesConfiguration.load(environment: [:])
        XCTAssertEqual(ChatConversationStore.model, ClaudeAPI.model)
        XCTAssertEqual(config.visionPrimaryModel, ClaudeAPI.model)
        XCTAssertEqual(config.visionFallbackModel, ClaudeAPI.screenFallbackModel)
        XCTAssertEqual(config.visionBaseURL, "https://bibbles-api.bibbles.workers.dev")
    }

    func testNonClaudeEnvironmentOverrideIsIgnored() {
        let config = BibblesConfiguration.load(environment: [
            "BIBBLES_VISION_PRIMARY_MODEL": "openai/gpt-test",
            "BIBBLES_VISION_FALLBACK_MODEL": "other/unsupported-test"
        ])
        XCTAssertEqual(config.visionPrimaryModel, ClaudeAPI.model)
        XCTAssertTrue(config.visionFallbackModel.hasPrefix("claude-"))
    }
}
