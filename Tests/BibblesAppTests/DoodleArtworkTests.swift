import XCTest
@testable import BibblesApp

final class DoodleArtworkTests: XCTestCase {
    func testRigidGeometryAndArrowEndpoints() throws {
        let circle = DoodleArtwork.path(for: .circle, in: CGRect(x: 20, y: 30, width: 150, height: 80)).boundingBoxOfPath
        XCTAssertEqual(circle.width, 80, accuracy: 0.001)
        XCTAssertEqual(circle.height, 80, accuracy: 0.001)
        let target = CGRect(x: -800, y: 200, width: 100, height: 40)
        let bounds = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let (start, end) = try XCTUnwrap(AnnotationGeometry.arrow(to: target, from: CGPoint(x: -750, y: 220), within: bounds))
        XCTAssertFalse(target.contains(start))
        XCTAssertFalse(target.contains(end))
        var curves = 0
        DoodleArtwork.arrow(from: start, to: end).applyWithBlock { element in
            if element.pointee.type == .addCurveToPoint || element.pointee.type == .addQuadCurveToPoint { curves += 1 }
        }
        XCTAssertEqual(curves, 0)
        XCTAssertNil(AnnotationGeometry.arrow(to: CGRect(x: 0, y: 0, width: -10, height: 20), from: nil, within: bounds))
    }

    func testRelativePlacementUsesRequestedDisplay() {
        let bounds = CGRect(x: -1600, y: -200, width: 1600, height: 1000)
        XCTAssertEqual(AnnotationGeometry.relativePoint(in: bounds, request: "draw a face center-screen", pointer: .zero), CGPoint(x: -800, y: 300))
        XCTAssertEqual(SimpleDrawingCommand.parse("draw a surprised face center-screen"), .surprisedFace)
        XCTAssertEqual(SimpleDrawingCommand.parse("draw a sun top-right-quadrant"), .sun)
    }
    func testShapesStayInsideVisibleAreaOnNegativeOriginDisplay() {
        let display = CGRect(x: -1440, y: -300, width: 1440, height: 900)
        for pointer in [CGPoint(x: -1440, y: -300), CGPoint(x: -1, y: 599), CGPoint(x: -700, y: 10)] {
            let rect = DoodleArtwork.localRect(around: pointer, within: display)
            XCTAssertTrue(display.contains(rect.insetBy(dx: -8, dy: -8)))
            for shape in DoodleShape.allCases {
                let path = DoodleArtwork.path(for: shape, in: rect)
                XCTAssertFalse(path.isEmpty)
                XCTAssertTrue(display.contains(path.boundingBoxOfPath))
            }
        }
    }

    func testLocalCommandsDoNotStealContextualOrExplanatoryRequests() {
        for shape in DoodleShape.allCases {
            XCTAssertEqual(SimpleDrawingCommand.parse("Could you draw a coral \(shape.rawValue) here?" )?.shape, shape)
        }
        XCTAssertEqual(SimpleDrawingCommand.parse("draw an arrow on my screen in purple"), .arrow)
        XCTAssertEqual(SimpleDrawingCommand.parse("clear drawings"), .clear)
        XCTAssertEqual(SimpleDrawingCommand.parse("undo drawing"), .undo)
        for text in ["Don't draw a circle", "How do I draw a star?", "Draw an arrow to Export", "Circle this button", "draw a triangle around this chart", "draw two circles", "draw a circle and an arrow"] {
            XCTAssertNil(SimpleDrawingCommand.parse(text), text)
        }
        XCTAssertEqual(IntentRouter().route(transcript: "circle this button", mode: .command), .screen(question: "circle this button"))
        XCTAssertEqual(IntentRouter().route(transcript: "draw a triangle around this pattern", mode: .command), .screen(question: "draw a triangle around this pattern"))
        XCTAssertEqual(IntentRouter().route(transcript: "draw a circle", mode: .dictation), .dictate)
    }

    func testCircleIsRoundAndLineStaysNearPointer() {
        let frame = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let point = CGPoint(x: 700, y: 450)
        let circle = DoodleArtwork.localRect(around: point, within: frame, shape: .circle)
        XCTAssertEqual(circle.width, circle.height)
        let line = DoodleArtwork.localRect(around: point, within: frame, shape: .line)
        XCTAssertLessThan(abs(DoodleArtwork.path(for: .line, in: line).boundingBoxOfPath.midY - point.y), 10)
    }
}
