import AppKit
import XCTest
@testable import BibblesApp

final class MusicActionTests: XCTestCase {
    func testRouting() {
        let router = IntentRouter()
        for text in ["Put on some classic rock on Apple Music", "Play Marvins Room by drake on spotify", "Skip this track", "pause the music", "Could you play jazz on Spotify"] {
            XCTAssertTrue(router.isCommandRequest(text), text)
            XCTAssertEqual(router.route(transcript: text, mode: .command), .chat(message: text))
            XCTAssertEqual(router.route(transcript: text, mode: .dictation), .dictate)
        }
        for text in ["Don't play music", "How do I play music?", "\"play music\"", "Explain Spotify"] {
            XCTAssertFalse(MusicRequest.isRequest(text), text)
            XCTAssertNil(MusicRequest.localPlan(text))
        }
    }

    func testLocalControlsAndModelConfirmation() {
        let plan = MusicRequest.localPlan("Skip this track!")!
        XCTAssertEqual(plan.calls[0].string("action"), "next")
        XCTAssertFalse(CommandAgent.needsConfirmation(plan.calls[0], command: "Skip this track"))
        XCTAssertTrue(CommandAgent.needsConfirmation(plan.calls[0], command: "Don't skip this track"))
        XCTAssertNil(MusicRequest.localPlan("skip this track in five minutes"))
        XCTAssertEqual(MusicRequest.localPlan("Please pause music on Spotify")?.calls.first?.string("app"), "spotify")
    }

    func testAppleMusicScriptsCompileWithoutExecution() throws {
        for action in [MusicAction.Operation.play, .pause, .resume, .next, .previous] {
            for search in [false, true] where !search || action == .play {
                let script = try XCTUnwrap(NSAppleScript(source: MusicAction.script(player: .appleMusic, operation: action, search: search)))
                var error: NSDictionary?
                XCTAssertTrue(script.compileAndReturnError(&error), String(describing: error))
            }
        }
    }

    func testTargetDoesNotGuessWhenTwoPlayersAreRunning() throws {
        XCTAssertEqual(try MusicAction.resolve(explicit: nil, running: [.spotify]), .appleMusic)
        XCTAssertEqual(try MusicAction.resolve(explicit: nil, running: []), .appleMusic)
        XCTAssertEqual(try MusicAction.resolve(explicit: nil, running: [.spotify, .appleMusic]), .appleMusic)
        XCTAssertEqual(try MusicAction.resolve(explicit: .appleMusic, running: [.spotify]), .appleMusic)
        XCTAssertEqual(try MusicAction.resolve(explicit: .spotify, running: [.appleMusic]), .spotify)
    }

    func testValidatesModelParameters() throws {
        func call(_ values: [String: AgentValue]) -> AgentToolCall { AgentToolCall(name: "music", input: values) }
        XCTAssertNoThrow(try MusicAction(call(["action": .string("play"), "app": .string("spotify"), "query": .string("Marvins Room Drake")])))
        XCTAssertThrowsError(try MusicAction(call(["action": .string("delete")])))
        XCTAssertThrowsError(try MusicAction(call(["action": .string("play"), "app": .string("Terminal")])))
        XCTAssertThrowsError(try MusicAction(call(["action": .string("pause"), "query": .string("a song")])))
        XCTAssertThrowsError(try MusicAction(call(["action": .string("play"), "script": .string("anything")])))
    }

    func testSearchEncodingAndScriptSafety() {
        let query = "AC/DC & rock #1? \"quoted\""
        let apple = MusicAction.searchURL(player: .appleMusic, query: query)
        XCTAssertEqual(URLComponents(url: apple, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, query)
        let spotify = MusicAction.searchURL(player: .spotify, query: query)
        XCTAssertEqual(spotify.host, "open.spotify.com")
        XCTAssertNil(spotify.fragment)
        let script = MusicAction.script(player: .appleMusic, operation: .play, search: true)
        XCTAssertTrue(script.contains("item 1 of argv"))
        XCTAssertTrue(script.contains("AMBIGUOUS"))
        XCTAssertFalse(script.contains(query))
        XCTAssertTrue(MusicAction.script(player: .spotify, operation: .next, search: false).contains("next track"))
    }

    func testCatalogSelectionRespectsTitleAndNamedArtist() {
        if #available(macOS 14.0, *) {
            let songs = [(title: "Happy Birthday", artist: "Kids Now"),
                         (title: "Happy Birthday", artist: "Diljit Dosanjh"),
                         (title: "Another Song", artist: "Happy Birthday")]
            XCTAssertEqual(AppleMusicCatalog.bestIndex(for: "Happy Birthday", in: songs), 0)
            XCTAssertEqual(AppleMusicCatalog.bestIndex(for: "Happy Birthday by Diljit Dosanjh", in: songs), 1)
            XCTAssertNil(AppleMusicCatalog.bestIndex(for: "Marvins Room by Drake", in: songs))
        }
    }
}
