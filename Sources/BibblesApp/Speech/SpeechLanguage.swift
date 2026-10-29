import Foundation

/// Settings → Dictation → "I speak". The languages of the speech model
/// (Nemotron 3.5 ASR Streaming Multilingual), transcription-ready and
/// broad-coverage tiers from its model card; the "adaptation-ready" tier is
/// left out because it isn't trained for full transcription yet.
/// Sent to the Worker as `/v1/transcribe?language=<ISO-639-1>`; "Auto" sends
/// no language, exactly as before.
struct SpeechLanguage: Hashable, Identifiable {
    /// ISO-639-1 code, or "auto".
    let code: String
    var id: String { code }

    static let auto = SpeechLanguage(code: "auto")
    /// English with no Hinglish: transcribed as English and always answered in English.
    static let englishOnly = SpeechLanguage(code: "en-only")
    static let storageKey = "bibbles.speechLanguage"

    /// (code, English name, native name)
    static let supported: [(code: String, english: String, native: String)] = [
        ("en", "English", "English & Hinglish"),
        ("es", "Spanish", "Español"),
        ("fr", "French", "Français"),
        ("de", "German", "Deutsch"),
        ("it", "Italian", "Italiano"),
        ("pt", "Portuguese", "Português"),
        ("nl", "Dutch", "Nederlands"),
        ("hi", "Hindi", "हिन्दी"),
        ("tr", "Turkish", "Türkçe"),
        ("ru", "Russian", "Русский"),
        ("uk", "Ukrainian", "Українська"),
        ("ar", "Arabic", "العربية"),
        ("ja", "Japanese", "日本語"),
        ("ko", "Korean", "한국어"),
        ("zh", "Chinese (Mandarin)", "中文"),
        ("vi", "Vietnamese", "Tiếng Việt"),
        ("pl", "Polish", "Polski"),
        ("cs", "Czech", "Čeština"),
        ("sk", "Slovak", "Slovenčina"),
        ("hu", "Hungarian", "Magyar"),
        ("ro", "Romanian", "Română"),
        ("bg", "Bulgarian", "Български"),
        ("hr", "Croatian", "Hrvatski"),
        ("sv", "Swedish", "Svenska"),
        ("nb", "Norwegian (Bokmål)", "Norsk bokmål"),
        ("da", "Danish", "Dansk"),
        ("fi", "Finnish", "Suomi"),
        ("et", "Estonian", "Eesti")
    ]

    /// The menu. "English & Hinglish" is no longer offered: "English" covers it.
    static var all: [SpeechLanguage] {
        [.auto, .englishOnly] + supported.filter { $0.code != "en" }.map { SpeechLanguage(code: $0.code) }
    }

    /// True when the user picked "English only": replies stay in English even
    /// if a message mixes in Hindi or other languages.
    static var isEnglishOnly: Bool { current == .englishOnly }

    var title: String {
        if self == .englishOnly { return "English" }
        guard let entry = Self.supported.first(where: { $0.code == code }) else { return ToolGateStrings.speechLanguageAuto }
        return entry.english == entry.native || code == "en" ? entry.native : "\(entry.english) — \(entry.native)"
    }

    /// The code to send, or nil to let the service detect the language.
    var requestCode: String? {
        switch code {
        case "auto": return nil
        case Self.englishOnly.code: return "en"
        default: return code
        }
    }

    /// The saved choice. Old saved values ("english", "hindi", "auto") still
    /// load. With nothing saved: the Mac's preferred language if the speech
    /// model supports it, otherwise Auto.
    static var current: SpeechLanguage {
        get { resolve(saved: UserDefaults.standard.string(forKey: storageKey)) }
        set { UserDefaults.standard.set(newValue.code, forKey: storageKey) }
    }

    static func resolve(saved: String?, preferred: [String] = Locale.preferredLanguages) -> SpeechLanguage {
        switch saved?.lowercased() {
        // "English & Hinglish" (and the old "english") now load as English.
        case "english"?, "en"?: return .englishOnly
        case "hindi"?: return SpeechLanguage(code: "hi")
        case "auto"?: return .auto
        case "en-only"?: return .englishOnly
        case let value? where supported.contains(where: { $0.code == value }): return SpeechLanguage(code: value)
        default: return defaultLanguage(preferred: preferred)
        }
    }

    static func defaultLanguage(preferred: [String] = Locale.preferredLanguages) -> SpeechLanguage {
        guard let first = preferred.first else { return .auto }
        let code = ToolGate.isoCode(first.replacingOccurrences(of: "_", with: "-"))
        if code == "en" { return .englishOnly }
        return supported.contains(where: { $0.code == code }) ? SpeechLanguage(code: code) : .auto
    }
}
