#if BIBBLES_DEVELOPER
import CoreGraphics
import XCTest
@testable import BibblesApp

@MainActor
final class AgentRobotTests: XCTestCase {
    func testSpriteSheetIsCutIntoSeventyTwoFrames() throws {
        let side = AgentRobotController.frameSide
        let columns = AgentRobotController.columns
        let rows = AgentRobotController.frameCount / columns
        let context = try XCTUnwrap(CGContext(data: nil, width: side * columns, height: side * rows, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let sheet = try XCTUnwrap(context.makeImage())
        let frames = AgentRobotController.frames(from: sheet)
        XCTAssertEqual(frames.count, 72)
        XCTAssertTrue(frames.allSatisfy { $0.width == side && $0.height == side })
    }

    func testNoImageMeansNoRobot() {
        // The test bundle has no AgentRobot.png: the robot simply doesn't show.
        XCTAssertTrue(AgentRobotController.loadFrames(bundle: Bundle(for: AgentRobotTests.self)).isEmpty)
    }

    func testTheScreenAgentCardLeavesTheCornerToTheRobot() {
        XCTAssertEqual(AgentRobotController.reservedHeight, AgentRobotController.size.height + AgentRobotController.margin)
    }
}
#endif
