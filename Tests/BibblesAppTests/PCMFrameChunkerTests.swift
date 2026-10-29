import XCTest
@testable import BibblesApp

final class PCMFrameChunkerTests: XCTestCase {
    func testEmitsExactTwentyMillisecondFramesAndKeepsRemainder() {
        var chunker = PCMFrameChunker()
        let bytes = Data(repeating: 7, count: PCMFrame.byteCount * 2 + 17)
        let frames = chunker.append(bytes)

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.map(\.sequence), [0, 1])
        XCTAssertEqual(frames.map { $0.linearPCM16.count }, [PCMFrame.byteCount, PCMFrame.byteCount])
        XCTAssertEqual(chunker.pending.count, 17)
    }
}
