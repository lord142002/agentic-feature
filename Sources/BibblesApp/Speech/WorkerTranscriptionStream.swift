import Foundation

enum SpeechToText {
    static let deepgramName = "Deepgram (Bibbles Worker)"
    private(set) static var active = deepgramName
    static var lastUsed: String?
    static var label: String { lastUsed ?? active }

    static func makeStream(configuration: BibblesConfiguration) -> TranscriptionStreaming {
        WorkerTranscriptionStream()
    }
}

/// Buffers PCM while the hotkey is held and sends one WAV upload on release.
/// No provider credential or provider URL exists in this path.
final class WorkerTranscriptionStream: TranscriptionStreaming {
    var onUpdate: ((TranscriptionUpdate) -> Void)?
    var onError: ((Error) -> Void)?
    var finalizationTimeoutSeconds: Double { 30 }

    private let session: URLSession
    private var audio = Data()
    private var isOpen = false
    private var request: Task<Void, Never>?

    init(session: URLSession = .shared) { self.session = session }

    func configure(for mode: SpeechMode) { SpeechToText.lastUsed = nil }

    func connect() async throws {
        await disconnect()
        try await Backends.current.ensureReady()
        audio = Data()
        isOpen = true
    }

    func send(_ frame: PCMFrame) async throws {
        guard isOpen else { throw TranscriptionStreamError.disconnected }
        audio.append(frame.linearPCM16)
    }

    func finalizeUtterance() async throws {
        guard isOpen else { throw TranscriptionStreamError.disconnected }
        guard !audio.isEmpty else { throw TranscriptionStreamError.noAudio }
        let wav = OpenRouterSpeech.wav(fromPCM: audio, sampleRate: PCMFrame.sampleRate)
        audio = Data()
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await WorkerAPI.transcribe(wav: wav, language: SpeechLanguage.current.requestCode,
                                                          session: self.session)
                guard !Task.isCancelled else { return }
                SpeechToText.lastUsed = SpeechToText.deepgramName
                self.onUpdate?(TranscriptionUpdate(text: text, isFinal: true, completesUtterance: true))
            } catch {
                guard !Task.isCancelled else { return }
                self.onError?(error)
            }
        }
    }

    func disconnect() async {
        request?.cancel()
        request = nil
        audio = Data()
        isOpen = false
    }
}
