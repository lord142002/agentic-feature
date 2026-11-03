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

    func testRobotLooks() {
        typealias Robot = AgentRobotController
        // Working: the robot plays, no badge; clicks pass through only while steps run on screen.
        XCTAssertEqual(Robot.look(screen: .planning, asking: false, errorSeen: false),
                       .init(visible: true, badge: false, clickThrough: false))
        XCTAssertEqual(Robot.look(screen: .running(done: 1, total: 3), asking: false, errorSeen: false),
                       .init(visible: true, badge: false, clickThrough: true))
        // Needs you: a plan to start, a "Send?" to answer, an error not yet seen: the red 1, clickable.
        XCTAssertEqual(Robot.look(screen: .preview, asking: false, errorSeen: false),
                       .init(visible: true, badge: true, clickThrough: false))
        XCTAssertEqual(Robot.look(screen: .running(done: 2, total: 3), asking: true, errorSeen: false),
                       .init(visible: true, badge: true, clickThrough: false))
        XCTAssertEqual(Robot.look(screen: .failed("x"), asking: false, errorSeen: false).badge, true)
        XCTAssertEqual(Robot.look(screen: .failed("x"), asking: false, errorSeen: true), .hidden)
        // Done: the robot disappears.
        XCTAssertEqual(Robot.look(screen: .done, asking: false, errorSeen: false), .hidden)
        XCTAssertEqual(Robot.look(files: .done, errorSeen: false), .hidden)
        XCTAssertEqual(Robot.look(files: .preview, errorSeen: false).badge, true)
        XCTAssertEqual(Robot.look(files: .scanning, errorSeen: false), .init(visible: true, badge: false, clickThrough: false))
    }
}
#endif
