import XCTest
@testable import BibblesApp

/// Customer builds (no BIBBLES_DEVELOPER flag) contain no developer code:
/// no Developer page, no agent route, no Local mode, no direct provider path.
final class CustomerBuildTests: XCTestCase {
    func testEveryBuildUsesTheWorkerUnlessLocalModeIsOn() {
        if !Backends.isLocal { XCTAssertTrue(Backends.current is WorkerBackend) }
    }

    #if !BIBBLES_DEVELOPER
    func testNoDeveloperSettingsPage() {
        XCTAssertFalse(SettingsSection.allCases.map(\.rawValue).contains("developer"))
        XCTAssertFalse(SettingsSection.allCases.map(\.title).contains("Developer"))
    }

    func testNoAgentRoute() {
        XCTAssertNil(HybridRoute(rawValue: "agent_files"))
        XCTAssertNil(HybridRoute(rawValue: "agent_screen"))
        XCTAssertFalse(RouterPrompt.system.contains("agent_files"))
        XCTAssertEqual(RouterPrompt.system, RouterPrompt.base)
    }

    func testNoLocalModeAndOnlyTheWorker() {
        XCTAssertFalse(Backends.isLocal)
        XCTAssertTrue(Backends.current is WorkerBackend)
    }

    func testRouterNeverHasAProviderKey() async {
        RouterClient.serverAllowed = false
        defer { RouterClient.serverAllowed = true }
        // Without the server there is no router at all: no developer key path exists.
        let client = await RouterClient.live()
        XCTAssertNil(client)
    }

    func testAnswerLabelsNeverNameAModel() {
        XCTAssertEqual(ClaudeAPI.taskLabel(for: ClaudeAPI.fastModel), "Light Task")
        XCTAssertEqual(ClaudeAPI.taskLabel(for: ClaudeAPI.smartModel), "Deep Task")
    }
    #endif
}
