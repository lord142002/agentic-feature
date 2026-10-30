import XCTest
@testable import BibblesApp

final class WriteIntentTests: XCTestCase {
    func testWriteRequestsAreDetected() {
        let router = IntentRouter()
        XCTAssertTrue(router.isWriteRequest("Write a resignation mail to my HR on my Mac Notes"))
        XCTAssertTrue(router.isWriteRequest("Can you draft a reply here?"))
        XCTAssertTrue(router.isWriteRequest("HR ko resignation mail likho"))
        XCTAssertFalse(router.isWriteRequest("rewrite this"))
        XCTAssertFalse(router.isWriteRequest("what type of file is this"))
        XCTAssertFalse(router.isWriteRequest("how do I write a for loop"))
    }

    func testWriteRequestWithHereStaysOffTheScreenPath() {
        XCTAssertEqual(
            IntentRouter().route(transcript: "write a thank you mail here", mode: .command),
            .chat(message: "write a thank you mail here")
        )
    }
}

final class FormFillTests: XCTestCase {
    func testFillRequestsAreDetected() {
        let router = IntentRouter()
        XCTAssertTrue(router.isFillRequest("Mail is hr@themicrosoft.com"))
        XCTAssertTrue(router.isFillRequest("Subject is resignation"))
        XCTAssertTrue(router.isFillRequest("send it to my manager"))
        XCTAssertFalse(router.isFillRequest("mail me tomorrow"))
        XCTAssertFalse(router.isFillRequest("to be honest"))
        XCTAssertEqual(router.route(transcript: "mail is hr@x.com", mode: .command), .chat(message: "mail is hr@x.com"))
    }

    func testParsesFillPlanAndDropsUnknownFields() throws {
        let text = #"{"actions":[{"field":1,"text":"hr@x.com","mode":"append"},{"field":9,"text":"nope"},{"field":2,"text":"Resignation"}],"note":"Filled To and Subject"}"#
        let envelope: [String: Any] = ["content": [["type": "text", "text": text]]]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let plan = try ClaudeFormPlanner.parse(data, validIDs: [1, 2, 3])
        XCTAssertEqual(plan.actions, [
            FormFillAction(field: 1, text: "hr@x.com", replace: false),
            FormFillAction(field: 2, text: "Resignation", replace: true)
        ])
        XCTAssertEqual(plan.note, "Filled To and Subject")
    }
}

final class FormPlanRepairTests: XCTestCase {
    func testParsesPlanWithRawLineBreaksInText() throws {
        let text = "{\"actions\":[{\"field\":2,\"text\":\"Dear HR,\nI resign.\",\"mode\":\"replace\"}]}"
        let envelope: [String: Any] = ["content": [["type": "text", "text": text]]]
        let plan = try ClaudeFormPlanner.parse(try JSONSerialization.data(withJSONObject: envelope), validIDs: [2])
        XCTAssertEqual(plan.actions.first?.text, "Dear HR,\nI resign.")
    }
}

final class SelectionIntentTests: XCTestCase {
    func testHighlightedTextQuestionsUseTheSelection() {
        let router = IntentRouter()
        let question = "I have highlighted the text which you're seeing on my screen, can you explain it briefly"
        XCTAssertTrue(router.shouldUseFocusedText(for: question))
        XCTAssertEqual(router.route(transcript: question, mode: .command), .chat(message: question))
        XCTAssertTrue(router.isWriteRequest("write a reply to this email"))
    }
}

final class ScreenWriteTests: XCTestCase {
    func testWriteAnswerToOnScreenQuestionUsesTheScreen() {
        let request = "write answer to this question on my terminal which you are seeing on my screen"
        XCTAssertTrue(IntentRouter().isWriteRequest(request))
        XCTAssertTrue(IntentRouter.refersToScreenContent(request))
        XCTAssertFalse(IntentRouter.refersToScreenContent("write a resignation mail to my HR"))
        XCTAssertEqual(ScreenWriter.stripFences("```java\nint x = 1;\n```"), "int x = 1;")
    }
}

final class FixTests: XCTestCase {
    func testFixRequestsAreDetected() {
        let router = IntentRouter()
        XCTAssertTrue(router.isFixRequest("Fix the errors in my code"))
        XCTAssertTrue(router.isFixRequest("Correct the grammar of this email"))
        XCTAssertTrue(router.isFixRequest("isko theek karo"))
        XCTAssertTrue(router.isFixRequest("solve this error"))
        XCTAssertFalse(router.isFixRequest("How do I fix this error?"))
        XCTAssertFalse(router.isFixRequest("solve this math problem"))
        XCTAssertEqual(router.route(transcript: "fix this code", mode: .command), .chat(message: "fix this code"))
    }

    func testScreenshotIsSentOnlyWhenTheRequestIsAboutTheScreen() {
        XCTAssertTrue(ClaudeFixer.wantsScreenshot(for: "fix the errors shown on my screen"))
        XCTAssertTrue(ClaudeFixer.wantsScreenshot(for: "fix the compiler errors"))
        XCTAssertFalse(ClaudeFixer.wantsScreenshot(for: "correct the grammar of this paragraph"))
        XCTAssertFalse(ClaudeFixer.wantsScreenshot(for: "fix my spelling"))
    }

    func testParsesFixToolCallAndExplains() throws {
        let response: [String: Any] = ["content": [["type": "tool_use", "id": "t", "name": "apply_fix", "input": [
            "fixed_text": "1| int age = 20;\n2| int n = 1;",
            "summary": "Two type names were misspelled.",
            "changes": [["line": 7, "before": "it age", "after": "int age", "why": "`it` is not a Java type."]]
        ]]]]
        let result = try ClaudeFixer.parse(try JSONSerialization.data(withJSONObject: response))
        XCTAssertEqual(result.fixedText, "int age = 20;\nint n = 1;")
        XCTAssertTrue(result.explanation.contains("Line 7"))
        XCTAssertTrue(ClaudeFixer.looksLikeCode("public class A { int x = 1; }"))
        XCTAssertFalse(ClaudeFixer.looksLikeCode("Dear HR, I am writing to resign."))
    }
}

final class MailComposeTests: XCTestCase {
    func testEmailRequestsAreDetected() {
        XCTAssertTrue(MailCompose.isEmailRequest("write a mail to my friend email: soham@gmail.com and ask about his health"))
        XCTAssertTrue(MailCompose.isEmailRequest("Write an email to my boss about Friday"))
        XCTAssertTrue(MailCompose.isEmailRequest("reply to Soham.K@work.co.in saying yes"))
        XCTAssertFalse(MailCompose.isEmailRequest("write a short story about a dragon"))
        XCTAssertFalse(MailCompose.isEmailRequest("write a poem about mailboxes"))
    }

    func testComposeWindowsAreDetected() {
        XCTAssertTrue(MailCompose.isComposeWindow(labels: ["To:", "Cc:", "Subject:", "Message body"]))
        XCTAssertTrue(MailCompose.isComposeWindow(labels: ["To recipients", "Subject", "Message Body"]))
        XCTAssertTrue(MailCompose.isComposeWindow(labels: ["To", "Add a subject", "Main text area"]))
        XCTAssertFalse(MailCompose.isComposeWindow(labels: ["Message body"]))
        XCTAssertFalse(MailCompose.isComposeWindow(labels: ["Title", "Tomorrow's notes", "Main text area"]))
        XCTAssertFalse(MailCompose.isComposeWindow(labels: ["Name", "Email", "Subject"]))
    }
}
