import XCTest
@testable import BibblesApp

final class FileActionTests: XCTestCase {
    func testFileRequestsAreDetectedAndStayOffTheScreenPath() {
        let router = IntentRouter()
        let request = #"Hey Bibbles, can u create a empty folder on desktop screen named "Mohit""#
        XCTAssertTrue(router.isFileRequest(request))
        XCTAssertEqual(router.route(transcript: request, mode: .command), .chat(message: request))
        XCTAssertTrue(router.isFileRequest("Rename Mohit to Mohit Singh"))
        XCTAssertTrue(router.isFileRequest("Desktop pe Mohit naam ka folder banao"))
        XCTAssertFalse(router.isFileRequest("how do I rename a file"))
    }

    func testNamesAreCleanedAndUnsafeNamesRejected() {
        XCTAssertEqual(FileActionExecutor.cleanName(" “Mohit” "), "Mohit")
        XCTAssertNil(FileActionExecutor.cleanName("../etc"))
        XCTAssertNil(FileActionExecutor.cleanName("a/b"))
        XCTAssertNil(FileActionExecutor.cleanName(".hidden"))
    }

    func testParsesPlan() throws {
        let text = #"{"action":"create_folder","location":"desktop","name":"Mohit","from":null,"to":null,"note":""}"#
        let data = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]]])
        let plan = try ClaudeFileActionPlanner.parse(data)
        XCTAssertEqual(plan.action, .createFolder)
        XCTAssertEqual(plan.location, .desktop)
        XCTAssertEqual(plan.name, "Mohit")
    }
}
