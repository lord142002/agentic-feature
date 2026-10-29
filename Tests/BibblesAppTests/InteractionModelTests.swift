import XCTest
@testable import BibblesApp

@MainActor
final class InteractionModelTests: XCTestCase {
    func testShowAgainRestoresLastAnswerAfterDismissal() {
        let model = InteractionModel()
        XCTAssertFalse(model.showAgain())
        model.transition(to: .answer("The highlighted button opens Settings."))
        model.cancel()
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.showAgain())
        XCTAssertEqual(model.state, .answer("The highlighted button opens Settings."))
    }
}
