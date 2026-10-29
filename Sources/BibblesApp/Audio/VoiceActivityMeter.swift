import Foundation
import SwiftUI

/// Reads the PCM already sent to transcription. No second microphone session is opened.
enum VoiceLevel {
    static func normalizedRMS(_ pcm: Data) -> CGFloat {
        guard pcm.count >= 2 else { return 0 }
        var energy = 0.0
        var count = 0
        pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: bytes.count - 1, by: 2) {
                let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                let sample = Double(Int16(bitPattern: bits)) / 32768.0
                energy += sample * sample
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let rms = sqrt(energy / Double(count))
        let decibels = 20 * log10(max(rms, 0.000_001))
        // Keep room for ordinary speech while suppressing typical room noise.
        return CGFloat(min(1, max(0, (decibels + 52) / 42)))
    }
}

@MainActor
final class VoiceActivityMeter: ObservableObject {
    @Published private(set) var bars: [CGFloat] = [0, 0, 0, 0]
    @Published private(set) var isActive = false
    private var smoothed: CGFloat = 0
    private var tick = 0

    func reset() {
        smoothed = 0
        tick = 0
        bars = [0, 0, 0, 0]
    }

    func begin() {
        reset()
        isActive = true
    }

    func end() {
        isActive = false
        reset()
    }

    func receive(_ frame: PCMFrame) {
        // 25 visual updates/second; microphone and transcription still run at 50.
        guard isActive, frame.sequence.isMultiple(of: 2) else { return }
        let level = VoiceLevel.normalizedRMS(frame.linearPCM16)
        smoothed += (level - smoothed) * (level > smoothed ? 0.62 : 0.25)
        tick += 1
        let weights: [CGFloat] = [0.58, 1, 0.78, 0.46]
        let phases: [CGFloat] = [0, 1.8, 3.4, 5.1]
        bars = (0..<4).map { index in
            let movement = 0.82 + 0.18 * sin(CGFloat(tick) * 0.72 + phases[index])
            return min(1, max(0, smoothed * weights[index] * movement))
        }
    }
}
