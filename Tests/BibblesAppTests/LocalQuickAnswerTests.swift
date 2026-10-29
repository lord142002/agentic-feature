import XCTest
@testable import BibblesApp

final class LocalQuickAnswerTests: XCTestCase {
    func testTimeUsesSuppliedLocalClock() {
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        let date = Date(timeIntervalSince1970: 0)
        let answer = LocalQuickAnswer.answer(for: "Hey Bibbles, what time is it?", now: date, timeZone: zone)
        XCTAssertTrue(answer?.contains("5:30") == true)
        XCTAssertTrue(answer?.contains("IST") == true)
    }

    func testNameAndDeveloperNeverNeedModel() {
        XCTAssertTrue(LocalQuickAnswer.answer(for: "Who are you?")?.contains("Bibbles") == true)
        for question in ["Who made you?", "Who is your developer?", "Who developed Bibbles?",
                         "Can you tell me who built you?", "Bibbles ka developer kaun hai?"] {
            XCTAssertEqual(LocalQuickAnswer.answer(for: question), BibblesIdentity.spokenAttribution, question)
        }
        XCTAssertNil(LocalQuickAnswer.answer(for: "Who built this Mac?"))
    }

    func testTimeWordInUnrelatedQuestionDoesNotIntercept() {
        XCTAssertNil(LocalQuickAnswer.answer(for: "How much time does a Mac export take?"))
        XCTAssertNil(LocalQuickAnswer.answer(for: "What is my screen time?"))
    }

    func testOtherCitiesGetTheirOwnTime() {
        let date = Date(timeIntervalSince1970: 0) // 00:00 UTC, 1 Jan 1970
        let london = LocalQuickAnswer.answer(for: "What time is it in London?", now: date)
        XCTAssertTrue(london?.contains("London") == true)
        XCTAssertTrue(london?.contains("1:00") == true) // London was on GMT+1 in 1970
        XCTAssertTrue(LocalQuickAnswer.answer(for: "Dubai mein kitne baje hain", now: date)?.contains("4:00") == true)
        XCTAssertNil(LocalQuickAnswer.answer(for: "What is the time difference in Mars missions?"))
    }

    func testDateQuestionsInAnyWording() {
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        let date = Date(timeIntervalSince1970: 1_790_000_000) // 21 Sep 2026
        for question in ["What is the date today?", "What's today's date?", "Tell me the date",
                         "Aaj kya date hai?", "Aaj ki tarikh kya hai", "What day is it today?"] {
            let answer = LocalQuickAnswer.answer(for: question, now: date, timeZone: zone)
            XCTAssertTrue(answer?.contains("2026") == true, question)
        }
        XCTAssertNil(LocalQuickAnswer.answer(for: "What is the date of Diwali?"))
    }

    func testNaturalClockRequestsUseMacTimeEvenWhenTheyMentionScreen() {
        let questions = [
            "What time is it right now?",
            "Hey Bibbles, can you tell me what time it is?",
            "Check the time on my screen",
            "What is the current time on my Mac?",
            "Abhi kitne baje hain?"
        ]
        for question in questions {
            let answer = LocalQuickAnswer.answer(for: question)
            XCTAssertNotNil(answer, question)
            XCTAssertFalse(answer?.localizedCaseInsensitiveContains("Siri") ?? true)
        }
    }
}
