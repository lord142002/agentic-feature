import AppKit
import XCTest
@testable import BibblesApp

final class NotchVisibilityTests: XCTestCase {
    func testDesktopAndFullScreenVisibility() {
        XCTAssertTrue(NotchVisibilityPolicy.shouldShow(enabled: true, checkingSpace: false,
                                                       fullScreen: false, appHasKeyWindow: false, interactionActive: false))
        XCTAssertFalse(NotchVisibilityPolicy.shouldShow(enabled: true, checkingSpace: false,
                                                        fullScreen: true, appHasKeyWindow: false, interactionActive: false))
        XCTAssertTrue(NotchVisibilityPolicy.shouldShow(enabled: true, checkingSpace: false,
                                                       fullScreen: true, appHasKeyWindow: true, interactionActive: false))
        XCTAssertTrue(NotchVisibilityPolicy.shouldShow(enabled: true, checkingSpace: false,
                                                       fullScreen: true, appHasKeyWindow: false, interactionActive: true))
    }

    func testSpaceTransitionAndDisabledNotchRemainHidden() {
        XCTAssertFalse(NotchVisibilityPolicy.shouldShow(enabled: true, checkingSpace: true,
                                                        fullScreen: false, appHasKeyWindow: true, interactionActive: false))
        XCTAssertTrue(NotchVisibilityPolicy.shouldShow(enabled: true, checkingSpace: true,
                                                       fullScreen: true, appHasKeyWindow: false, interactionActive: true))
        XCTAssertFalse(NotchVisibilityPolicy.shouldShow(enabled: false, checkingSpace: false,
                                                        fullScreen: false, appHasKeyWindow: true, interactionActive: true))
        XCTAssertFalse(NotchGeometry.everySpace.contains(.fullScreenAuxiliary))
    }
}
