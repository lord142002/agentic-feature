#if BIBBLES_DEVELOPER
import Foundation

enum STTCorpusLanguage: String, Codable, CaseIterable { case english, hindi, hinglish }

struct STTCorpusEntry: Codable, Equatable, Identifiable {
    let id: String
    let language: STTCorpusLanguage
    let reference: String
}

enum STTEvaluationCorpus {
    /// A deterministic, balanced 500-utterance text manifest. Physical or human-recorded
    /// WAV files use each entry's id as the filename; generated voices are intentionally
    /// excluded from accuracy claims.
    static let entries: [STTCorpusEntry] = {
        make(language: .english, count: 167,
             starts: ["Please", "Can you", "Now", "Carefully", "Quickly", "Today", "First", "Next", "Kindly", "Immediately"],
             middles: ["update", "inspect", "restart", "explain", "compare", "open", "validate", "rename", "profile", "test"],
             ends: ["the WebSocket handler", "this React component", "the cursor coordinates", "our API route", "the selected paragraph", "the build pipeline", "the microphone stream", "the retry policy", "the Swift actor", "the latency report"])
        + make(language: .hindi, count: 167,
               starts: ["कृपया", "अब", "पहले", "ध्यान से", "आज", "जल्दी", "इसके बाद", "फिर", "तुरंत", "एक बार"],
               middles: ["जाँचें", "समझाएँ", "खोलें", "बदलें", "मापें", "सुधारें", "दोबारा चलाएँ", "तुलना करें", "लिखें", "पढ़ें"],
               ends: ["यह त्रुटि", "स्क्रीन का पाठ", "माइक्रोफोन की आवाज़", "कर्सर की जगह", "नेटवर्क कनेक्शन", "चुना हुआ वाक्य", "ऐप की सेटिंग", "प्रतिक्रिया का समय", "कोड का यह भाग", "नई रिपोर्ट"])
        + make(language: .hinglish, count: 166,
               starts: ["Please", "Ab", "Pehle", "Ek baar", "Jaldi", "Dhyan se", "Next", "Aaj", "Phir", "Kindly"],
               middles: ["check karo", "explain karo", "update karo", "compare karo", "open karo", "fix karo", "measure karo", "restart karo", "validate karo", "read karo"],
               ends: ["ye WebSocket handler", "is React component ko", "cursor coordinates ko", "API route ko", "selected text ko", "build pipeline ko", "microphone stream ko", "retry logic ko", "Swift actor ko", "latency report ko"])
    }()

    private static func make(
        language: STTCorpusLanguage,
        count: Int,
        starts: [String],
        middles: [String],
        ends: [String]
    ) -> [STTCorpusEntry] {
        (0..<count).map { index in
            let start = starts[index % starts.count]
            let middle = middles[(index / starts.count) % middles.count]
            let end = ends[(index / (starts.count * middles.count)) % ends.count]
            return STTCorpusEntry(
                id: String(format: "%@-%03d", language.rawValue, index + 1),
                language: language,
                reference: "\(start) \(middle) \(end)."
            )
        }
    }
}

enum STTBenchmarkProvider: String, CaseIterable {
    case deepgramNova3
    case deepgramFlux
    case assemblyAIWhisperStreaming

    var model: String {
        switch self {
        case .deepgramNova3: return "nova-3"
        case .deepgramFlux: return "flux-general-multi"
        case .assemblyAIWhisperStreaming: return "whisper-rt"
        }
    }

    var endpoint: String {
        switch self {
        case .deepgramNova3: return "wss://api.deepgram.com/v1/listen"
        case .deepgramFlux: return "wss://api.deepgram.com/v2/listen"
        case .assemblyAIWhisperStreaming: return "wss://streaming.assemblyai.com/v3/ws"
        }
    }
}

struct STTBenchmarkSample: Equatable {
    let entryID: String
    let reference: String
    let hypothesis: String
    let finalLatencyMilliseconds: Double
}

struct STTBenchmarkSummary: Equatable {
    let sampleCount: Int
    let wordErrorRate: Double
    let p50FinalLatencyMilliseconds: Double
    let p95FinalLatencyMilliseconds: Double

    static func calculate(_ samples: [STTBenchmarkSample]) -> STTBenchmarkSummary {
        let totals = samples.reduce(into: (edits: 0, words: 0)) { result, sample in
            let reference = tokens(sample.reference)
            let hypothesis = tokens(sample.hypothesis)
            result.edits += editDistance(reference, hypothesis)
            result.words += reference.count
        }
        let latencies = samples.map(\.finalLatencyMilliseconds).sorted()
        return STTBenchmarkSummary(
            sampleCount: samples.count,
            wordErrorRate: totals.words == 0 ? 0 : Double(totals.edits) / Double(totals.words),
            p50FinalLatencyMilliseconds: percentile(latencies, 0.50),
            p95FinalLatencyMilliseconds: percentile(latencies, 0.95)
        )
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
    }

    private static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1]
            for (j, right) in rhs.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous.last ?? lhs.count
    }

    private static func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[Int((Double(sorted.count - 1) * percentile).rounded(.up))]
    }
}
#endif
