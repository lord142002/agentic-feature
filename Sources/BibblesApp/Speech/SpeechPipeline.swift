import AVFoundation
import Foundation

@MainActor
final class SpeechPipeline {
    var onUpdate: ((TranscriptionUpdate) -> Void)?
    var onComplete: ((String, BibblesIntent) -> Void)?
    var onError: ((Error) -> Void)?
    var onAudioFrame: ((PCMFrame) -> Void)?

    private let capture: MicrophoneCapture
    private let stream: TranscriptionStreaming
    private let router: IntentRouter
    private var mode: SpeechMode = .command
    private var latestTranscript = ""
    private var committedSegments: [String] = []
    private var active = false
    private var connected = false
    private var pendingFrames: [PCMFrame] = []
    private var finishRequested = false
    private var finalizeSent = false
    private var isSendingFrames = false
    private var resetStreamBeforeNextBegin = false
    private var replayFrames: [PCMFrame] = []
    private var replayBufferOverflowed = false
    private var reconnectAttempts = 0
    private var isRecovering = false
    private var isReplayingAfterReconnect = false
    private var finalizationTimeoutTask: Task<Void, Never>?

    private static let maximumReplayFrames = 3_000 // 60 seconds at 20 ms per frame.
    /// Audio waiting to be sent (while connecting, or while a slow network
    /// catches up). Same 60 seconds as the replay buffer: nothing is dropped
    /// before that, and past it the turn stops with a clear message.
    static let maximumPendingFrames = maximumReplayFrames

    init(capture: MicrophoneCapture, stream: TranscriptionStreaming, router: IntentRouter = IntentRouter()) {
        self.capture = capture
        self.stream = stream
        self.router = router

        capture.onFrame = { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onAudioFrame?(frame)
                await self.send(frame)
            }
        }
        capture.onError = { [weak self] error in
            Task { @MainActor [weak self] in self?.fail(error) }
        }
        stream.onUpdate = { [weak self] update in
            Task { @MainActor [weak self] in self?.receive(update) }
        }
        stream.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                await self.recoverOrFail(error)
            }
        }
    }

    @discardableResult
    func begin(mode: SpeechMode) async -> Bool {
        guard !active else { return false }
        do {
            try await ensureMicrophonePermission()
            try Task.checkCancellation()
            if resetStreamBeforeNextBegin {
                await stream.disconnect()
                resetStreamBeforeNextBegin = false
            }
            self.mode = mode
            stream.configure(for: mode)
            latestTranscript = ""
            committedSegments.removeAll(keepingCapacity: true)
            active = true
            connected = false
            finishRequested = false
            finalizeSent = false
            pendingFrames.removeAll(keepingCapacity: true)
            replayFrames.removeAll(keepingCapacity: true)
            replayBufferOverflowed = false
            reconnectAttempts = 0
            isRecovering = false
            isReplayingAfterReconnect = false
            finalizationTimeoutTask?.cancel()
            finalizationTimeoutTask = nil
            try capture.start()
            try await NetworkRecovery.onceAfterAbruptTLS { try await stream.connect() }
            try Task.checkCancellation()
            guard active else {
                await stream.disconnect()
                return false
            }
            connected = true
            Diagnostics.log("stt", ["event": "connected", "mode": "\(mode)"])
            await drainPendingFrames()
            return true
        } catch {
            Diagnostics.log("stt", ["event": "begin_failed", "error": String(describing: type(of: error)), "detail": String("\(error)".prefix(80))])
            fail(error)
            return false
        }
    }

    func finish() async {
        Diagnostics.log("stt", ["event": "finish", "active": active, "connected": connected, "frames": replayFrames.count])
        guard active else { return }
        capture.stop()
        finishRequested = true
        finalizationTimeoutTask?.cancel()
        let timeout = UInt64(stream.finalizationTimeoutSeconds * 1_000_000_000)
        finalizationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled, let self, self.active, self.finishRequested else { return }
            self.fail(TranscriptionStreamError.finalizationTimedOut)
        }
        guard connected else { return }
        await drainPendingFrames()
    }

    func shutdown() async {
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        capture.stop()
        active = false
        connected = false
        pendingFrames.removeAll(keepingCapacity: false)
        replayFrames.removeAll(keepingCapacity: false)
        await stream.disconnect()
    }

    private func send(_ frame: PCMFrame) async {
        guard active, !finishRequested else { return }
        if replayFrames.count < Self.maximumReplayFrames {
            replayFrames.append(frame)
        } else {
            replayBufferOverflowed = true
        }
        guard Self.canQueue(pendingCount: pendingFrames.count) else {
            // Never drop words silently: stop and say why.
            fail(TranscriptionStreamError.audioBacklog)
            return
        }
        pendingFrames.append(frame)
        // While connecting, frames wait here and are sent once connected.
        guard connected else { return }
        await drainPendingFrames()
    }

    /// Whether one more 20 ms frame fits in the waiting queue.
    static func canQueue(pendingCount: Int) -> Bool {
        pendingCount < maximumPendingFrames
    }

    private func drainPendingFrames() async {
        guard active, connected, !isSendingFrames, !isRecovering else { return }
        isSendingFrames = true
        var transportFailure: Error?
        while active, connected, !pendingFrames.isEmpty {
            let frame = pendingFrames.removeFirst()
            do {
                try await stream.send(frame)
                if isReplayingAfterReconnect {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            } catch {
                transportFailure = error
                break
            }
        }
        isSendingFrames = false
        if pendingFrames.isEmpty { isReplayingAfterReconnect = false }

        if let transportFailure {
            await recoverOrFail(transportFailure)
            return
        }

        guard active, connected, finishRequested, pendingFrames.isEmpty, !finalizeSent else { return }
        guard !replayFrames.isEmpty else {
            fail(TranscriptionStreamError.noAudio)
            return
        }
        finalizeSent = true
        do {
            try await stream.finalizeUtterance()
        } catch {
            await recoverOrFail(error)
        }
    }

    private func recoverOrFail(_ error: Error) async {
        guard active else { return }
        guard isTransientConnectionError(error),
              reconnectAttempts == 0,
              !replayFrames.isEmpty,
              !replayBufferOverflowed,
              !isRecovering else {
            if !isRecovering { fail(error) }
            return
        }

        reconnectAttempts += 1
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        isRecovering = true
        connected = false
        finalizeSent = false
        pendingFrames.removeAll(keepingCapacity: true)
        committedSegments.removeAll(keepingCapacity: true)
        latestTranscript = ""

        await stream.disconnect()
        do {
            try await stream.connect()
            guard active else {
                isRecovering = false
                await stream.disconnect()
                return
            }
            connected = true
            pendingFrames = replayFrames
            isRecovering = false
            isReplayingAfterReconnect = true
            await drainPendingFrames()
        } catch {
            isRecovering = false
            fail(error)
        }
    }

    private func isTransientConnectionError(_ error: Error) -> Bool {
        guard let streamError = error as? TranscriptionStreamError else {
            let text = error.localizedDescription.lowercased()
            return text.contains("socket") || text.contains("connection") || text.contains("timed out")
        }
        switch streamError {
        case .connectionLost, .disconnected, .secureConnectionInterrupted:
            return true
        default:
            return false
        }
    }

    private func receive(_ update: TranscriptionUpdate) {
        guard active else { return }
        if update.isFinal, !update.text.isEmpty, committedSegments.last != update.text {
            committedSegments.append(update.text)
        }
        let displayText: String
        if update.isFinal {
            displayText = committedSegments.joined(separator: " ")
        } else {
            displayText = (committedSegments + [update.text])
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        if !displayText.isEmpty { latestTranscript = displayText }
        onUpdate?(TranscriptionUpdate(
            text: latestTranscript,
            isFinal: update.isFinal,
            completesUtterance: update.completesUtterance
        ))
        if update.completesUtterance {
            finalizationTimeoutTask?.cancel()
            finalizationTimeoutTask = nil
            active = false
            connected = false
            let transcript = latestTranscript
            Diagnostics.log("stt", ["event": "complete", "chars": transcript.count])
            replayFrames.removeAll(keepingCapacity: true)
            onComplete?(transcript, router.route(transcript: transcript, mode: mode))
            Task { await stream.disconnect() }
        }
    }

    private func fail(_ error: Error) {
        Diagnostics.log("stt", ["event": "failed", "error": String(describing: type(of: error)), "detail": String("\(error)".prefix(80))])
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        capture.stop()
        active = false
        connected = false
        resetStreamBeforeNextBegin = true
        pendingFrames.removeAll(keepingCapacity: true)
        replayFrames.removeAll(keepingCapacity: true)
        isRecovering = false
        isReplayingAfterReconnect = false
        onError?(error)
    }

    private func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw MicrophoneCaptureError.unavailable }
        case .denied, .restricted: throw MicrophoneCaptureError.unavailable
        @unknown default: throw MicrophoneCaptureError.unavailable
        }
    }
}
