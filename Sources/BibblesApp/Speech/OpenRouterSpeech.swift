import Foundation

/// Legacy voice preferences and PCM/WAV helpers. Production speech is sent
/// through Bibbles' authenticated Worker, never directly to a provider.
enum OpenRouterSpeech {
    static let model = "google/gemini-3.8-flash-lite-tts"
    /// Gemini detects the language itself, including Hindi.
    static let defaultEnglishVoice = "Kore"
    /// A selection of Gemini's prebuilt studio voices.
    static let englishVoices: [(id: String, name: String)] = [
        ("Kore", "Kore (firm)"),
        ("Puck", "Puck (upbeat)"),
        ("Zephyr", "Zephyr (bright)"),
        ("Charon", "Charon (informative)"),
        ("Aoede", "Aoede (breezy)"),
        ("Sulafat", "Sulafat (warm)"),
        ("Achird", "Achird (friendly)")
    ]
    private static let voiceKey = "bibbles.geminiVoice"

    static var englishVoice: String {
        get {
            let value = UserDefaults.standard.string(forKey: voiceKey) ?? ""
            return englishVoices.contains { $0.id == value } ? value : defaultEnglishVoice
        }
        set { UserDefaults.standard.set(newValue, forKey: voiceKey) }
    }

    static func requestBody(text: String) -> [String: Any] {
        ["model": model,
         "input": String(text.prefix(2_000)),
         "voice": englishVoice,
         // Gemini speaks raw 24 kHz PCM natively; Bibbles wraps it as WAV.
         "response_format": "pcm"]
    }

    /// Wraps raw 16-bit mono PCM (24 kHz, what the speech model returns) in a WAV
    /// header so the Mac can play it.
    static func wav(fromPCM pcm: Data, sampleRate: Int = 24_000) -> Data {
        var header = Data()
        func append(_ value: UInt32) { var v = value.littleEndian; header.append(Data(bytes: &v, count: 4)) }
        func append16(_ value: UInt16) { var v = value.littleEndian; header.append(Data(bytes: &v, count: 2)) }
        header.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8)); append(16); append16(1); append16(1)
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append16(2); append16(16)
        header.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        return header + pcm
    }

    /// Turns the service's reply into playable audio, or a clear error.
    static func playableAudio(from data: Data, contentType: String?) throws -> Data {
        let type = (contentType ?? "").lowercased()
        if type.contains("json") || data.first == UInt8(ascii: "{") {
            throw VoiceReplyError.service("OpenRouter", 200, errorMessage(in: data) ?? "no audio came back")
        }
        guard data.count > 64 else { throw VoiceReplyError.invalidAudio("OpenRouter") }
        let isMP3 = type.contains("mpeg") || type.contains("mp3")
            || data.starts(with: Array("ID3".utf8)) || (data.first == 0xFF && ((data.dropFirst().first ?? 0) & 0xE0) == 0xE0)
        let isWAV = data.starts(with: Array("RIFF".utf8))
        return isMP3 || isWAV ? data : wav(fromPCM: data)
    }

    static func errorMessage(in data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return String(data: data.prefix(200), encoding: .utf8)
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String
            let raw = (error["metadata"] as? [String: Any])?["raw"] as? String
            return [message, raw].compactMap { $0 }.joined(separator: " — ")
        }
        return object["message"] as? String
    }
}
