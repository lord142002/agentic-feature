import XCTest
@testable import BibblesApp

final class VoiceActivityMeterTests: XCTestCase {
    func testRMSDistinguishesSilenceSpeechAndClips() {
        let silence = Data(repeating: 0, count: PCMFrame.byteCount)
        XCTAssertEqual(VoiceLevel.normalizedRMS(silence), 0)

        var voiced = Data()
        for _ in 0..<(PCMFrame.byteCount / 2) {
            let sample = Int16(5_000).littleEndian
            withUnsafeBytes(of: sample) { voiced.append(contentsOf: $0) }
        }
        let level = VoiceLevel.normalizedRMS(voiced)
        XCTAssertGreaterThan(level, 0.3)
        XCTAssertLessThan(level, 1)

        let clipped = Data(repeating: 0x7f, count: PCMFrame.byteCount)
        XCTAssertGreaterThanOrEqual(VoiceLevel.normalizedRMS(clipped), level)
        XCTAssertLessThanOrEqual(VoiceLevel.normalizedRMS(clipped), 1)
    }

    @MainActor
    func testMeterStopsUpdatingAfterRelease() {
        let meter = VoiceActivityMeter()
        let frame = PCMFrame(sequence: 0, capturedAt: .now,
                             linearPCM16: Data(repeating: 0x7f, count: PCMFrame.byteCount))
        meter.begin()
        meter.receive(frame)
        XCTAssertTrue(meter.bars.contains(where: { $0 > 0 }))
        meter.end()
        meter.receive(frame)
        XCTAssertEqual(meter.bars, [0, 0, 0, 0])
        XCTAssertFalse(meter.isActive)
    }
}
