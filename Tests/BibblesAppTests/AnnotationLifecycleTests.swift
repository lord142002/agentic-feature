import AppKit
import XCTest
@testable import BibblesApp

final class AnnotationLifecycleTests: XCTestCase {
    @MainActor
    func testEndingWalkthroughPreservesTheLocalCanvasAndUndoHistory() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("A window-server session is required") }
        let controller = TargetHighlightController()
        defer { controller.hide() }
        let point = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        XCTAssertTrue(controller.draw(.circle, at: point))
        controller.endWalkthrough()
        XCTAssertTrue(controller.hasDrawing)
        XCTAssertTrue(controller.canUndoDrawing)
        XCTAssertTrue(controller.undoDrawing())
        XCTAssertFalse(controller.hasDrawing)
    }

    @MainActor
    func testDisplayChangesInvalidatePendingWalkthroughAsWellAsVisibleMarks() async {
        let controller = TargetHighlightController()
        var invalidations = 0
        controller.onDisplayChange = { invalidations += 1 }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Notification handling is dispatched back onto the UI actor.
        for _ in 0..<20 where invalidations == 0 { await Task.yield() }
        XCTAssertEqual(invalidations, 1)
        XCTAssertFalse(controller.hasDrawing)
        XCTAssertFalse(controller.isShowingWalkthrough)
    }
}
