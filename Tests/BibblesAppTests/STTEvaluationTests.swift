import XCTest
@testable import BibblesApp

final class STTEvaluationTests: XCTestCase {
    func testCorpusContainsBalancedFiveHundredUtterances() {
        let entries = STTEvaluationCorpus.entries
        XCTAssertEqual(entries.count, 500)
        XCTAssertEqual(entries.filter { $0.language == .english }.count, 167)
        XCTAssertEqual(entries.filter { $0.language == .hindi }.count, 167)
        XCTAssertEqual(entries.filter { $0.language == .hinglish }.count, 166)
        XCTAssertEqual(Set(entries.map(\.id)).count, 500)
        XCTAssertTrue(entries.allSatisfy { !$0.reference.isEmpty })
    }

    func testProviderMatrixUsesRequiredIndependentEndpoints() {
        XCTAssertEqual(STTBenchmarkProvider.deepgramNova3.endpoint, "wss://api.deepgram.com/v1/listen")
        XCTAssertEqual(STTBenchmarkProvider.deepgramFlux.endpoint, "wss://api.deepgram.com/v2/listen")
        XCTAssertTrue(STTBenchmarkProvider.assemblyAIWhisperStreaming.endpoint.contains("assemblyai.com"))
    }

    func testBenchmarkSummaryCalculatesWERAndTailLatency() {
        let samples = [
            STTBenchmarkSample(entryID: "1", reference: "open the file", hypothesis: "open file", finalLatencyMilliseconds: 100),
            STTBenchmarkSample(entryID: "2", reference: "test this", hypothesis: "test this", finalLatencyMilliseconds: 300)
        ]
        let summary = STTBenchmarkSummary.calculate(samples)
        XCTAssertEqual(summary.wordErrorRate, 0.2, accuracy: 0.0001)
        XCTAssertEqual(summary.p50FinalLatencyMilliseconds, 300)
        XCTAssertEqual(summary.p95FinalLatencyMilliseconds, 300)
    }
}
