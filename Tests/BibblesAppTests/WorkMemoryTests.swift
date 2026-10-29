import AppKit
import XCTest
@testable import BibblesApp

final class WorkMemoryTests: XCTestCase {
    func testEditRequestsAreRecognised() {
        for request in ["I don't like this story, change it", "change it", "Replace the story", "make the mail shorter",
                        "Make it more formal", "rewrite this", "give me a different story", "write another one",
                        "try again", "isko badal do", "dusri story likho", "story pasand nahi aaya", "It's boring",
                        "Replace this story with a romantic one"] {
            XCTAssertTrue(EditRequest.isEdit(request), request)
        }
        for request in ["what is this", "open safari", "write a leave mail to my manager", "what is the temp in delhi",
                        "change the brightness", "update my mac", "I don't like mondays"] {
            XCTAssertFalse(EditRequest.isEdit(request), request)
        }
    }

    @MainActor
    func testMemoryKeepsRecentWritingAndPrefersTheSameApp() throws {
        let memory = WorkMemory()
        let app = NSRunningApplication.current
        memory.remember("A short thriller story.", request: "write a story", app: app)
        XCTAssertEqual(memory.latest(preferring: app)?.text, "A short thriller story.")
        XCTAssertNil(memory.latest(preferring: app, now: Date().addingTimeInterval(WorkMemory.lifetime + 1)))
    }

    func testFindsEarlierTextEvenWhenTheAppChangedIt() throws {
        let story = "The last train slid out of the station at 11:42, and Meera realized she was alone. That was her first mistake."
        let note = "Notes title\n\n" + story.replacingOccurrences(of: ", and", with: ",  and") + "\n\nOther notes"
        let range = try XCTUnwrap(FocusedTextInserter.range(of: story, in: note))
        let found = (note as NSString).substring(with: NSRange(location: range.location, length: range.length))
        XCTAssertTrue(found.hasPrefix("The last train"))
        XCTAssertTrue(found.hasSuffix("first mistake."))
        XCTAssertNil(FocusedTextInserter.range(of: "Something never written here at all, nothing like it.", in: note))
    }

    func testSharedOpeningAndClosingWordsNeverSelectDifferentContent() {
        let opening = "Dear colleagues, here is the full status update for this week. "
        let closing = " Please let me know if you have any questions. Best regards, Bibbles."
        let original = opening + "Launch is approved." + closing
        let editedByUser = opening + "Do not launch. We have unresolved safety issues." + closing
        XCTAssertNil(FocusedTextInserter.range(of: original, in: editedByUser))
    }

    func testNormalizedSelectionUsesCorrectUTF16Range() throws {
        let original = "👩🏽‍💻 The \"release\"\n is ready."
        let rendered = "👩🏽‍💻 The “release”\u{00a0}is ready."
        let editor = "Title\n" + rendered + "\nSignature"
        let range = try XCTUnwrap(FocusedTextInserter.range(of: original, in: editor))
        XCTAssertEqual((editor as NSString).substring(with: NSRange(location: range.location, length: range.length)), rendered)
    }
}
