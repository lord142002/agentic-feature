import XCTest
@testable import BibblesApp

final class TaskHistoryTests: XCTestCase {
    private func conversation(_ pairs: [(String, String, Date)]) -> ChatConversation {
        var conversation = ChatConversation(title: pairs.first?.0 ?? "Chat")
        for (question, answer, date) in pairs {
            conversation.messages.append(ChatMessage(role: .user, text: question, createdAt: date))
            conversation.messages.append(ChatMessage(role: .assistant, text: answer, createdAt: date))
        }
        return conversation
    }

    func testItemsListEveryFinishedTaskNewestFirst() {
        let now = Date()
        let first = conversation([("who is akbar", "A Mughal emperor.", now.addingTimeInterval(-3_600)),
                                  ("open safari", "Opened Safari.", now.addingTimeInterval(-60))])
        let second = conversation([("fix this code", "Fixed 2 errors.", now.addingTimeInterval(-600))])
        let items = TaskHistory.items(from: [first, second])
        XCTAssertEqual(items.map(\.question), ["open safari", "fix this code", "who is akbar"])
        XCTAssertEqual(items.first?.conversationID, first.id)
    }

    func testUnansweredQuestionsAreLeftOut() {
        var chat = ChatConversation()
        chat.messages.append(ChatMessage(role: .user, text: "still thinking"))
        chat.messages.append(ChatMessage(role: .assistant, text: "  "))
        chat.messages.append(ChatMessage(role: .user, text: "no reply yet"))
        XCTAssertTrue(TaskHistory.items(from: [chat]).isEmpty)
    }

    func testKindsMatchWhatBibblesDid() {
        XCTAssertEqual(TaskHistory.kind(question: "fix this code", hasSources: false), .fix)
        XCTAssertEqual(TaskHistory.kind(question: "write a leave mail to my manager", hasSources: false), .write)
        XCTAssertEqual(TaskHistory.kind(question: "open safari", hasSources: false), .action)
        XCTAssertEqual(TaskHistory.kind(question: "where is the compose button on my screen", hasSources: false), .screen)
        XCTAssertEqual(TaskHistory.kind(question: "who won the match", hasSources: true), .search)
        XCTAssertEqual(TaskHistory.kind(question: "what is photosynthesis", hasSources: false), .ask)
    }

    func testTimeLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 14))!
        XCTAssertEqual(TaskHistory.timeLabel(for: now.addingTimeInterval(-86_400), now: now, calendar: calendar), "Yesterday")
        let old = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 9))!
        XCTAssertTrue(TaskHistory.timeLabel(for: old, now: now, calendar: calendar).contains("2026"))
        XCTAssertFalse(TaskHistory.timeLabel(for: now.addingTimeInterval(-600), now: now, calendar: calendar).isEmpty)
    }

    func testPreviewIsOneCleanLine() {
        XCTAssertEqual(TaskHistory.preview("**Done.**\n\nOpened `Safari`"), "Done. Opened Safari")
    }
}

final class TaskFollowUpTests: XCTestCase {
    func testNewTasksAreNotFollowUps() {
        XCTAssertFalse(TaskHistory.isFollowUp("Seeing on my screen"))
        XCTAssertFalse(TaskHistory.isFollowUp("Find the immediate resistance and support of this chart"))
        XCTAssertFalse(TaskHistory.isFollowUp("where is the compose button"))
    }

    func testFollowUpsContinueTheTask() {
        XCTAssertTrue(TaskHistory.isFollowUp("and the other one?"))
        XCTAssertTrue(TaskHistory.isFollowUp("explain more"))
        XCTAssertTrue(TaskHistory.isFollowUp("Make it shorter"))
        XCTAssertTrue(TaskHistory.isFollowUp("aur batao"))
    }
}

final class UsageMeterTests: XCTestCase {
    func testCountsPerMonthAndResets() {
        let defaults = UserDefaults(suiteName: "UsageMeterTests-\(UUID().uuidString)")!
        let meter = UsageMeter(defaults: defaults)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let october = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        let november = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        meter.recordAsk(at: october)
        meter.recordAsk(at: october)
        meter.recordDeepTask(at: october)
        XCTAssertEqual(meter.asks(in: october), 2)
        XCTAssertEqual(meter.deepTasks(in: october), 1)
        XCTAssertEqual(meter.asks(in: november), 0)
        XCTAssertEqual(UsageMeter.resetDate(after: october, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
    }
}
