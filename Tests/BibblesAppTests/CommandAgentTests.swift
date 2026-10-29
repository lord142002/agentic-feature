import XCTest
@testable import BibblesApp

final class CommandAgentTests: XCTestCase {
    func testOutOfRangeToolNumbersCannotCrashTheApp() {
        for number in [Double.nan, .infinity, -.infinity, 1e100, -1e100, Double(Int.max)] {
            let call = AgentToolCall(name: "set_volume", input: ["level": .number(number)])
            XCTAssertNil(call.int("level"))
        }
        XCTAssertEqual(AgentToolCall(name: "set_volume", input: ["level": .number(30.9)]).int("level"), 30)
        XCTAssertEqual(AgentToolCall(name: "set_volume", input: ["level": .string("30")]).int("level"), 30)
    }

    func testCommandsAreDetected() {
        let router = IntentRouter()
        // "Find my resume PDF" is still a Mac command, but Bibbles looks on
        // the screen first and searches the Mac only if it isn't visible.
        XCTAssertTrue(router.isCommandRequest("Find my resume PDF"))
        XCTAssertEqual(router.route(transcript: "Find my resume PDF", mode: .command), .screen(question: "Find my resume PDF"))
        for command in ["Hey Bibbles, open Spotify", "Go to YouTube",
                        "Remind me at 5pm to call HR", "Add a meeting tomorrow at 10", "Set volume to 30",
                        "Mute", "Turn on dark mode", "Make the screen brighter", "Spotify kholo"] {
            XCTAssertTrue(router.isCommandRequest(command), command)
            XCTAssertEqual(router.route(transcript: command, mode: .command), .chat(message: command), command)
        }
        for other in ["Open this", "What is on my screen", "Explain this", "What's the volume of a sphere",
                      "Where is the export button"] {
            XCTAssertFalse(router.isCommandRequest(other), other)
        }
    }

    func testParsesToolCalls() throws {
        let response: [String: Any] = ["content": [
            ["type": "text", "text": "Opening it."],
            ["type": "tool_use", "id": "1", "name": "open_app", "input": ["name": "Spotify"]],
            ["type": "tool_use", "id": "2", "name": "set_volume", "input": ["action": "set", "level": 30]]
        ]]
        let plan = try CommandAgent.parse(try JSONSerialization.data(withJSONObject: response))
        XCTAssertEqual(plan.calls.map(\.name), ["open_app", "set_volume"])
        XCTAssertEqual(plan.calls[0].string("name"), "Spotify")
        XCTAssertEqual(plan.calls[1].int("level"), 30)
        XCTAssertEqual(plan.text, "Opening it.")
    }

    func testAppMatchingAndWebsiteURLs() {
        let apps = ["/Applications/Spotify.app", "/System/Applications/System Settings.app", "/Applications/Safari.app"]
            .map { URL(fileURLWithPath: $0) }
        XCTAssertEqual(AppLauncher.bestMatch(for: "spotify", in: apps)?.lastPathComponent, "Spotify.app")
        XCTAssertEqual(AppLauncher.bestMatch(for: "settings", in: apps)?.lastPathComponent, "System Settings.app")
        XCTAssertEqual(AppLauncher.websiteURL(from: "youtube.com")?.absoluteString, "https://youtube.com")
        XCTAssertNil(AppLauncher.websiteURL(from: "file:///etc/passwd"))
    }

    func testSpotlightQueryStripsSpecialCharacters() {
        let query = FileFinder.query(name: "resume\" || x", kind: .pdf, modifiedWithinDays: 7)
        XCTAssertEqual(query, #"kMDItemFSName == "*resume*"cd && kMDItemFSName == "*||*"cd && kMDItemFSName == "*x*"cd && kMDItemContentTypeTree == "com.adobe.pdf" && kMDItemFSContentChangeDate >= $time.today(-7)"#)
        XCTAssertNil(FileFinder.query(name: nil, kind: .anyKind, modifiedWithinDays: nil))
    }

    func testParsesISODates() {
        XCTAssertNotNil(CalendarActions.parseDate("2026-10-03T17:00:00+05:30"))
        XCTAssertNotNil(CalendarActions.parseDate("2026-10-03T17:00"))
        XCTAssertNil(CalendarActions.parseDate("tomorrow"))
    }

    func testModelChosenActionsAreConfirmedUnlessClearlyAskedFor() {
        func call(_ name: String, _ input: [String: Any]) -> AgentToolCall {
            AgentToolCall(name: name, input: input.mapValues(AgentValue.init))
        }
        // Harmless or clearly requested: runs straight away.
        XCTAssertFalse(CommandAgent.needsConfirmation(call("set_volume", ["action": "set", "level": 30]), command: "set volume to 30"))
        XCTAssertFalse(CommandAgent.needsConfirmation(call("open_app", ["name": "Spotify"]), command: "open spotify"))
        XCTAssertFalse(CommandAgent.needsConfirmation(call("open_website", ["url": "https://www.youtube.com"]), command: "go to youtube"))
        XCTAssertFalse(CommandAgent.needsConfirmation(call("create_folder", ["name": "Mohit"]), command: "create a folder named Mohit"))
        // Not what the user said, or lasting: asks first.
        XCTAssertTrue(CommandAgent.needsConfirmation(call("open_app", ["name": "Terminal"]), command: "open spotify"))
        XCTAssertTrue(CommandAgent.needsConfirmation(call("open_website", ["url": "https://evil.example"]), command: "go to youtube"))
        // Look-alike addresses must ask first.
        XCTAssertTrue(CommandAgent.needsConfirmation(call("open_website", ["url": "https://google.com.evil.example"]), command: "open google"))
        XCTAssertTrue(CommandAgent.needsConfirmation(call("open_website", ["url": "https://www.google.com.login-check.co.in"]), command: "open google"))
        XCTAssertTrue(CommandAgent.needsConfirmation(call("open_website", ["url": "https://youtube.com@evil.example"]), command: "go to youtube"))
        XCTAssertTrue(CommandAgent.needsConfirmation(call("open_website", ["url": "https://tube.com"]), command: "go to youtube"))
        // The real sites still open straight away.
        XCTAssertFalse(CommandAgent.needsConfirmation(call("open_website", ["url": "https://news.bbc.co.uk"]), command: "open bbc news"))
        XCTAssertFalse(CommandAgent.needsConfirmation(call("open_website", ["url": "https://www.amazon.in"]), command: "open amazon"))
        XCTAssertFalse(CommandAgent.needsConfirmation(call("open_website", ["url": "https://www.youtube.com"]), command: "open you tube"))
        XCTAssertTrue(CommandAgent.needsConfirmation(call("open_website", ["url": "file:///etc/passwd"]), command: "open passwd"))
        XCTAssertTrue(CommandAgent.needsConfirmation(call("create_reminder", ["title": "Call HR"]), command: "remind me to call HR"))
        XCTAssertTrue(CommandAgent.needsConfirmation(call("create_calendar_event", ["title": "Sync", "start": "2026-10-03T10:00"]), command: "add a meeting"))
        XCTAssertTrue(CommandAgent.needsConfirmation(call("delete_everything", [:]), command: "anything"))
        XCTAssertEqual(CommandAgent.describe(call("create_folder", ["name": "Mohit"])), "Create a folder “Mohit” in Desktop")
    }
}
