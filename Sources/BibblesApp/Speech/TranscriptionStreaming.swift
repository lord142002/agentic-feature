import Foundation

struct TranscriptionUpdate: Equatable {
    let text: String
    let isFinal: Bool
    let completesUtterance: Bool
}

protocol TranscriptionStreaming: AnyObject {
    var onUpdate: ((TranscriptionUpdate) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func connect() async throws
    func send(_ frame: PCMFrame) async throws
    func finalizeUtterance() async throws
    func disconnect() async
    func configure(for mode: SpeechMode)
    /// How long to wait for the final transcript after the key is released.
    var finalizationTimeoutSeconds: Double { get }
}

extension TranscriptionStreaming {
    var finalizationTimeoutSeconds: Double { 4 }
    func configure(for mode: SpeechMode) {}
}

enum TranscriptionStreamError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case disconnected
    case connectionLost
    case secureConnectionInterrupted
    case noAudio
    case finalizationTimedOut
    /// The network was too slow to keep up with the recording (over a minute behind).
    case audioBacklog
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Please sign in to Bibbles to use transcription."
        case .invalidEndpoint: return "The transcription endpoint is invalid."
        case .disconnected: return "The transcription connection is not ready."
        case .connectionLost: return "The transcription connection dropped. Hold Control + Option and try again."
        case .secureConnectionInterrupted: return "The secure transcription connection was interrupted before it opened. Check your network or VPN, then try again."
        case .noAudio: return "No speech was detected. Hold the shortcut while speaking and try again."
        case .finalizationTimedOut: return "Transcription took too long to finish. If a partial transcript is shown, you can use it anyway."
        case .audioBacklog: return "Your connection is too slow to send the recording, so nothing was cut. Check your network and try again."
        case let .server(message): return "Transcription failed: \(message)"
        }
    }
}
