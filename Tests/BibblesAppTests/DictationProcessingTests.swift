import XCTest
@testable import BibblesApp

final class DictationProcessingTests: XCTestCase {
    func testNewInstallationDefaultsToCleanButHonorsVerbatimPreference() {
        let suite = "bibbles.dictation.test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DictationPreferences(defaults: defaults)
        XCTAssertEqual(preferences.mode, .clean)
        preferences.mode = .verbatim
        XCTAssertEqual(preferences.mode, .verbatim)
    }

    func testVerbatimOnlyAppliesApprovedCorrections() {
        let result = DictationProcessor.process(
            "ye react jay ess component",
            mode: .verbatim,
            corrections: [SpeechCorrection(heard: "react jay ess", replacement: "React.js")]
        )
        XCTAssertEqual(result, "ye React.js component")
    }

    func testCleanModeIsDeterministicAndDoesNotUseAnLLM() {
        let result = DictationProcessor.process(
            "um please update the websocket handler",
            mode: .clean,
            corrections: []
        )
        XCTAssertEqual(result, "Please update the websocket handler.")
    }

    func testCleanModePreservesHindiTerminalPunctuation() {
        XCTAssertEqual(
            DictationProcessor.process("यह ठीक है।", mode: .clean, corrections: []),
            "यह ठीक है।"
        )
    }

    func testCleanModePreservesMixedScripts() {
        XCTAssertEqual(
            DictationProcessor.process("Please send यह file आज", mode: .clean, corrections: []),
            "Please send यह file आज."
        )
        XCTAssertEqual(
            DictationProcessor.process("please send the file आज", mode: .clean, corrections: []),
            "Please send the file आज."
        )
        XCTAssertEqual(
            DictationProcessor.process("please send the file", mode: .clean, corrections: []),
            "Please send the file."
        )
    }
}
