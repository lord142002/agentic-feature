import AVFoundation
import Foundation

enum MicrophoneCaptureError: LocalizedError {
    case unavailable
    case formatConversion

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The microphone input is unavailable."
        case .formatConversion: return "Bibbles could not convert microphone audio to 16 kHz mono PCM."
        }
    }
}

final class MicrophoneCapture {
    var onFrame: ((PCMFrame) -> Void)?
    var onError: ((Error) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var chunker = PCMFrameChunker()
    private var running = false

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(PCMFrame.sampleRate),
                channels: AVAudioChannelCount(PCMFrame.channelCount),
                interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MicrophoneCaptureError.unavailable
        }

        self.converter = converter
        self.outputFormat = outputFormat
        chunker.reset()

        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            self.outputFormat = nil
            throw error
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        converter = nil
        outputFormat = nil
        lock.lock()
        chunker.reset()
        lock.unlock()
    }

    private func consume(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter, let outputFormat else { return }
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            onError?(MicrophoneCaptureError.formatConversion)
            return
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil,
              let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
            onError?(conversionError ?? MicrophoneCaptureError.formatConversion)
            return
        }

        let bytes = Data(bytes: audioBuffer, count: Int(outputBuffer.audioBufferList.pointee.mBuffers.mDataByteSize))
        lock.lock()
        let frames = chunker.append(bytes)
        lock.unlock()
        frames.forEach { onFrame?($0) }
    }
}
