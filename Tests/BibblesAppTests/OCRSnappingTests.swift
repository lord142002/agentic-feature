import XCTest
@testable import BibblesApp

final class OCRSnappingTests: XCTestCase {
    private let ocr = [
        OCRObservation(text: "Downloads", confidence: 1, normalizedRect: NormalizedRect(x: 0.15, y: 0.20, width: 0.08, height: 0.02)),
        OCRObservation(text: "bibbles-website", confidence: 1, normalizedRect: NormalizedRect(x: 0.10, y: 0.28, width: 0.12, height: 0.02)),
        OCRObservation(text: "bibbles-website.zip", confidence: 1, normalizedRect: NormalizedRect(x: 0.10, y: 0.32, width: 0.14, height: 0.02))
    ]

    private func envelope(_ json: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": json]]])
    }

    func testOCRIdSnapsTargetAndAnnotationToExactTextBox() throws {
        let json = #"{"answer":"It's the first item in Downloads.","confidence":0.9,"target":{"x":0.5,"y":0.5,"width":0.2,"height":0.2,"ocrId":2},"annotations":[{"kind":"arrow","target":{"ocrId":2},"confidence":0.6}]}"#
        let answer = try MessagesVisionProvider.parseResponse(try envelope(json), model: "test", ocr: ocr,
                                                         question: "where is bibble folder", kind: .findControl)
        let expected = MessagesVisionProvider.padded(ocr[1].normalizedRect)
        XCTAssertEqual(answer.target, expected)
        XCTAssertEqual(answer.annotations.first?.target, expected)
        XCTAssertEqual(answer.annotations.first?.confidence, 0.9)
    }

    func testMentionedNameSnapsToNearestMatchingText() throws {
        let json = #"{"answer":"Here.","confidence":0.9,"target":{"x":0.09,"y":0.27,"width":0.2,"height":0.05}}"#
        let answer = try MessagesVisionProvider.parseResponse(try envelope(json), model: "test", ocr: ocr,
                                                         question: "where is bibble folder", kind: .findControl)
        XCTAssertEqual(answer.target, MessagesVisionProvider.padded(ocr[1].normalizedRect))
    }

    func testEstimatedMarkTouchingNoTextIsDropped() throws {
        let json = #"{"answer":"Here.","confidence":0.9,"annotations":[{"kind":"circle","target":{"x":0.6,"y":0.6,"width":0.1,"height":0.1},"confidence":0.9}]}"#
        let answer = try MessagesVisionProvider.parseResponse(try envelope(json), model: "test", ocr: ocr,
                                                         question: "where is the export button", kind: .findControl)
        XCTAssertTrue(answer.annotations.isEmpty)
    }

    func testMarksOnlyWhenAsked() {
        XCTAssertTrue(MessagesVisionProvider.wantsMarks("can you see a folder named bibbles-website", kind: .general))
        XCTAssertEqual(ScreenQuestionKind.classify("can you see a folder named bibbles-website"), .findControl)
        XCTAssertTrue(MessagesVisionProvider.wantsMarks("what is on my screen", kind: .general))
        XCTAssertTrue(MessagesVisionProvider.wantsMarks("where is bibble folder", kind: .findControl))
        XCTAssertTrue(MessagesVisionProvider.wantsMarks("circle the zip file", kind: .general))
        XCTAssertEqual(MessagesVisionProvider.mentionedName(in: "where is bibble folder"), "bibble")
        XCTAssertEqual(MessagesVisionProvider.mentionedName(in: "Hey Bibbles, where is the Bibbles folder?"), "bibbles")
        XCTAssertEqual(MessagesVisionProvider.mentionedName(in: #"can you see a folder named "bibbles-website""#), "bibbles-website")
    }

    func testFindOnScreenDrawsInsteadOfSearchingTheMac() {
        let question = #"find a "xyz" named folder on my screen"#
        XCTAssertFalse(IntentRouter().isCommandRequest(question))
        XCTAssertEqual(IntentRouter().route(transcript: question, mode: .command), .screen(question: question))
        XCTAssertEqual(ScreenQuestionKind.classify(question.lowercased()), .findControl)
        XCTAssertEqual(MessagesVisionProvider.mentionedName(in: question), "xyz")
    }

    func testWhereIsGoesToTheScreenAndFindGoesToSpotlight() {
        let router = IntentRouter()
        XCTAssertEqual(router.route(transcript: "where is bibble folder", mode: .command), .screen(question: "where is bibble folder"))
        XCTAssertTrue(router.isCommandRequest("find my resume pdf"))
    }

    func testFindQuestionsAreNotStepByStepGuides() {
        XCTAssertEqual(ScreenQuestionKind.classify("how can i find microsoft folder on my screen"), .findControl)
        XCTAssertEqual(ScreenQuestionKind.classify("how do i find the microsoft folder"), .findControl)
        XCTAssertEqual(ScreenQuestionKind.classify("how do i export this as pdf"), .howTo)
        XCTAssertEqual(MessagesVisionProvider.mentionedName(in: "how can i find microsoft folder on my screen"), "microsoft")
    }

    func testWrongOCRChoiceIsCorrectedToTheNamedItem() {
        let desktop = [
            OCRObservation(text: "Microsoft", confidence: 1, normalizedRect: NormalizedRect(x: 0.80, y: 0.38, width: 0.05, height: 0.02)),
            OCRObservation(text: "Bibbles", confidence: 1, normalizedRect: NormalizedRect(x: 0.90, y: 0.38, width: 0.04, height: 0.02))
        ]
        // The model pointed at "Bibbles" (id 2) for a question about Microsoft.
        let box = MessagesVisionProvider.verifiedRect(ocrId: 2, mentioned: "microsoft", ocr: desktop)
        XCTAssertEqual(box, MessagesVisionProvider.padded(desktop[0].normalizedRect))
        // A matching choice is kept.
        XCTAssertEqual(MessagesVisionProvider.verifiedRect(ocrId: 1, mentioned: "microsoft", ocr: desktop),
                       MessagesVisionProvider.padded(desktop[0].normalizedRect))
        // Guide steps snap to the control their title names.
        let steps = MessagesVisionProvider.guideSteps(
            from: [["title": "Open the Microsoft folder", "explanation": "It's on the desktop.",
                    "target": ["x": 0.89, "y": 0.37, "width": 0.07, "height": 0.1]]],
            ocr: desktop, imageSize: nil, question: "where is microsoft folder")
        XCTAssertEqual(steps.first?.target, MessagesVisionProvider.padded(desktop[0].normalizedRect))
    }

    func testEveryWayOfAskingWhereSomethingIsGetsTheSameAnswer() {
        let router = IntentRouter()
        for question in ["where is microsoft folder on my screen", "where is microsoft folder", "find microsoft folder",
                         "Find the Microsoft folder", "can you see the microsoft folder", "microsoft folder kahan hai",
                         "how do I find the Microsoft folder", "show me the microsoft folder", "locate microsoft folder",
                         "search for the microsoft folder", "Hey Bibbles, where's the Microsoft folder?"] {
            XCTAssertEqual(router.route(transcript: question, mode: .command), .screen(question: question), question)
            XCTAssertEqual(ScreenQuestionKind.classify(question), .findControl, question)
            XCTAssertEqual(MessagesVisionProvider.mentionedName(in: question), "microsoft", question)
        }
        // Not about a place on screen.
        XCTAssertNotEqual(ScreenQuestionKind.classify("find the derivative of x squared"), .findControl)
        XCTAssertEqual(router.route(transcript: "online dhundo latest Swift release", mode: .command),
                       .search(query: "latest Swift release"))
        // Whole-Mac searches still use Spotlight.
        XCTAssertTrue(IntentRouter.isMacWideSearch("find the pdfs I downloaded yesterday"))
        XCTAssertEqual(router.route(transcript: "find the pdfs I downloaded yesterday", mode: .command),
                       .chat(message: "find the pdfs I downloaded yesterday"))
        XCTAssertTrue(IntentRouter.mentionsFileItem("where is microsoft folder"))
    }

    func testWhereIsMarksTheNamedLabelEvenWhenTheModelPointsElsewhere() throws {
        let desktop = [
            OCRObservation(text: "Claude", confidence: 1, normalizedRect: NormalizedRect(x: 0.68, y: 0.20, width: 0.03, height: 0.015)),
            OCRObservation(text: "Microsott", confidence: 0.6, normalizedRect: NormalizedRect(x: 0.78, y: 0.20, width: 0.04, height: 0.015)),
            OCRObservation(text: "Bibbles", confidence: 1, normalizedRect: NormalizedRect(x: 0.88, y: 0.20, width: 0.03, height: 0.015)),
            OCRObservation(text: "Amazon", confidence: 1, normalizedRect: NormalizedRect(x: 0.78, y: 0.36, width: 0.03, height: 0.015))
        ]
        // The model's box sits on Bibbles, and OCR misread the name slightly.
        let json = #"{"answer":"Microsoft is in the second row.","confidence":0.6,"target":{"x":0.83,"y":0.18,"width":0.1,"height":0.12},"annotations":[{"kind":"arrow","target":{"x":0.83,"y":0.18,"width":0.1,"height":0.12},"confidence":0.8,"label":"Microsoft"}]}"#
        for question in ["where is microsoft folder", "find microsoft folder", "microsoft folder on my screen"] {
            let answer = try MessagesVisionProvider.parseResponse(try envelope(json), model: "test", ocr: desktop,
                                                             question: question, kind: .findControl)
            let expected = MessagesVisionProvider.padded(desktop[1].normalizedRect)
            XCTAssertEqual(answer.target, expected, question)
            XCTAssertEqual(answer.annotations.count, 1, question)
            XCTAssertEqual(answer.annotations.first?.target, expected, question)
            XCTAssertGreaterThanOrEqual(answer.confidence, 0.9, question)
        }
    }

    func testFuzzyNameMatching() {
        XCTAssertEqual(MessagesVisionProvider.matchScore("microsoft", "Microsoft"), 0)
        XCTAssertNotNil(MessagesVisionProvider.matchScore("microsoft", "Microsott"))
        XCTAssertNil(MessagesVisionProvider.matchScore("microsoft", "Amazon"))
        XCTAssertNil(MessagesVisionProvider.matchScore("microsoft", "Bibbles"))
    }

    func testGeneralAnswersMarkTheNamedControl() throws {
        let mail = [
            OCRObservation(text: "Compose", confidence: 1, normalizedRect: NormalizedRect(x: 0.02, y: 0.12, width: 0.05, height: 0.02)),
            OCRObservation(text: "Inbox", confidence: 1, normalizedRect: NormalizedRect(x: 0.02, y: 0.18, width: 0.04, height: 0.02))
        ]
        let json = #"{"answer":"Compose starts a new email.","confidence":0.7}"#
        let answer = try MessagesVisionProvider.parseResponse(try envelope(json), model: "test", ocr: mail,
                                                         question: "what does the compose button do", kind: .general)
        XCTAssertEqual(answer.target, MessagesVisionProvider.padded(mail[0].normalizedRect))
        XCTAssertEqual(answer.annotations.count, 1)
    }

    func testPointerFallbackPicksNearbyTextOnly() {
        let lines = [
            OCRObservation(text: "Total due", confidence: 1, normalizedRect: NormalizedRect(x: 0.40, y: 0.50, width: 0.10, height: 0.02)),
            OCRObservation(text: "Far away", confidence: 1, normalizedRect: NormalizedRect(x: 0.90, y: 0.90, width: 0.05, height: 0.02))
        ]
        XCTAssertEqual(BibblesApplicationDelegate.textNearest(CGPoint(x: 0.45, y: 0.53), in: lines)?.text, "Total due")
        XCTAssertNil(BibblesApplicationDelegate.textNearest(CGPoint(x: 0.1, y: 0.1), in: lines))
    }
}
