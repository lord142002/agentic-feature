import XCTest
@testable import BibblesApp

final class HotkeyInterpreterTests: XCTestCase {
    func testControlOptionHoldEmitsPTTBoundaries() {
        var sut = HotkeyInterpreter()
        XCTAssertEqual(sut.consume([.control], at: 1.0), [])
        XCTAssertEqual(sut.consume([.control, .option], at: 1.1), [.pushToTalkBegan])
        XCTAssertEqual(sut.consume([.control, .option], at: 1.2), [])
        XCTAssertEqual(sut.consume([.control], at: 1.3), [.pushToTalkEnded])
        XCTAssertEqual(sut.consume([], at: 1.4), [])
    }

    func testReleasingControlWhileOptionRemainsEndsPTT() {
        var sut = HotkeyInterpreter()
        XCTAssertEqual(sut.consume([.control, .option], at: 1.0), [.pushToTalkBegan])
        XCTAssertEqual(sut.consume([.option], at: 1.3), [.pushToTalkEnded])
        XCTAssertEqual(sut.consume([], at: 1.4), [])
    }

    func testReleasingOptionWhileControlRemainsEndsPTT() {
        var sut = HotkeyInterpreter()
        XCTAssertEqual(sut.consume([.control, .option], at: 1.0), [.pushToTalkBegan])
        XCTAssertEqual(sut.consume([.control], at: 1.3), [.pushToTalkEnded])
        XCTAssertEqual(sut.consume([], at: 1.4), [])
    }

    func testFunctionControlHoldEmitsDictationBoundaries() {
        var sut = HotkeyInterpreter()
        XCTAssertEqual(sut.consume([.control, .function], at: 1.0), [.dictationBegan])
        XCTAssertEqual(sut.consume([], at: 1.5), [.dictationEnded])
    }

    func testDoubleControlTapRequestsTypedInput() {
        var sut = HotkeyInterpreter()
        XCTAssertEqual(sut.consume([.control], at: 1.00), [])
        XCTAssertEqual(sut.consume([], at: 1.10), [])
        XCTAssertEqual(sut.consume([.control], at: 1.28), [])
        XCTAssertEqual(sut.consume([], at: 1.38), [.typedInputRequested])
    }

    func testModifiedControlDoesNotCountAsTap() {
        var sut = HotkeyInterpreter()
        _ = sut.consume([.control], at: 1.00)
        _ = sut.consume([.control, .option], at: 1.05)
        _ = sut.consume([], at: 1.20)
        _ = sut.consume([.control], at: 1.30)
        XCTAssertEqual(sut.consume([], at: 1.40), [])
    }
}
