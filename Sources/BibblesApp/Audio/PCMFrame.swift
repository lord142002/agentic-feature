import Foundation

struct PCMFrame: Equatable {
    static let sampleRate = 16_000
    static let channelCount = 1
    static let bytesPerSample = 2
    static let frameDurationMilliseconds = 20
    static let byteCount = sampleRate * channelCount * bytesPerSample * frameDurationMilliseconds / 1_000

    let sequence: UInt64
    let capturedAt: ContinuousClock.Instant
    let linearPCM16: Data
}

struct PCMFrameChunker {
    private(set) var pending = Data()
    private(set) var nextSequence: UInt64 = 0

    mutating func append(_ data: Data, capturedAt: ContinuousClock.Instant = .now) -> [PCMFrame] {
        pending.append(data)
        var frames: [PCMFrame] = []

        while pending.count >= PCMFrame.byteCount {
            let payload = pending.prefix(PCMFrame.byteCount)
            pending.removeFirst(PCMFrame.byteCount)
            frames.append(PCMFrame(sequence: nextSequence, capturedAt: capturedAt, linearPCM16: Data(payload)))
            nextSequence += 1
        }
        return frames
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        nextSequence = 0
    }
}
