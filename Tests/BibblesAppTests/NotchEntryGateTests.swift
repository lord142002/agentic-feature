import XCTest
@testable import BibblesApp

final class NotchEntryGateTests: XCTestCase {
    func testEscapeNearNotchRequiresExitAndReentry() {
        var gate = NotchEntryGate()
        gate.suppressUntilExit(currentlyNear: true)
        XCTAssertFalse(gate.moved(isNear: true))
        XCTAssertFalse(gate.moved(isNear: false))
        XCTAssertTrue(gate.moved(isNear: true))
        XCTAssertFalse(gate.moved(isNear: true))
    }
}
