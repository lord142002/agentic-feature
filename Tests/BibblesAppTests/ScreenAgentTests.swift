#if BIBBLES_DEVELOPER
import ApplicationServices
import XCTest
@testable import BibblesApp

/// No real app is touched: snapshots and fields are made up here.
final class ScreenAgentTests: XCTestCase {
    private let me: MyDetails = {
        var details = MyDetails()
        details.firstName = "Mohit"
        details.lastName = "Singh"
        details.email = "mohit@example.com"
        details.phone = "+91 98765 43210"
        details.city = "Delhi"
        details.country = "India"
        return details
    }()

    override func tearDown() {
        AgentSettings.screenTestOverride = nil
        AgentSettings.testOverride = nil
        MyDetailsStore.testOverride = nil
        super.tearDown()
    }

    private func field(_ id: Int, _ label: String, value: String = "") -> FormField {
        FormField(id: id, element: AXUIElementCreateApplication(getpid()), role: "AXTextField", label: label, value: value, hasCursor: false)
    }

    private func snapshot(fields: [FormField] = [], controls: [ScreenControl] = [],
                          menus: [(path: [String], enabled: Bool)] = []) -> ScreenSnapshot {
        ScreenSnapshot(appName: "Test", menus: menus, controls: controls, fields: fields)
    }

    // MARK: My details

    func testLabelsMatchDetailsInManyLanguages() {
        let cases: [(String, MyDetails.Key?)] = [
            ("Email address", .email), ("E-Mail", .email), ("Correo electrónico", .email), ("メールアドレス", .email),
            ("First name", .firstName), ("Vorname", .firstName), ("Prénom", .firstName),
            ("Last name", .lastName), ("Nachname", .lastName), ("Apellidos", .lastName),
            ("Full name", .fullName), ("Name", .fullName), ("お名前", .fullName), ("氏名", .fullName),
            ("Phone number", .phone), ("Mobile", .phone), ("Teléfono", .phone),
            ("ZIP code", .postalCode), ("PIN code", .postalCode), ("Postleitzahl", .postalCode),
            ("City", .city), ("Country", .country), ("Company name", .company), ("Street address", .street),
            ("Username", nil), ("Password", nil), ("Confirm password", nil), ("Card number", nil), ("CVV", nil),
            ("Name on card", nil), ("One-time code", nil), ("PIN", nil), ("Date of birth", nil), ("Passport number", nil)
        ]
        for (label, expected) in cases {
            XCTAssertEqual(MyDetailsMatcher.key(forLabel: label), expected, label)
        }
    }

    @MainActor
    func testDetailsFillIsPlannedOnTheMacWithoutAI() {
        let fields = [field(1, "First name"), field(2, "Last name"), field(3, "Email"), field(4, "Password"),
                      field(5, "Phone", value: "already typed"), field(6, "Username"), field(7, "Email confirmation")]
        let plan = ScreenPlanValidator.detailsPlan(fields: fields, details: me)
        XCTAssertEqual(plan.steps, [.fill(field: "First name", value: "{{firstName}}"), .fill(field: "Last name", value: "{{lastName}}"),
                                    .fill(field: "Email", value: "{{email}}")],
                       "no password, no username, fields that already have text are kept, each detail once")
        let preview = ScreenPlanValidator.preview(plan, snapshot: snapshot(fields: fields), request: "fill this with my details", details: me)
        XCTAssertEqual(preview.fills, 3)
        XCTAssertEqual(preview.lines.map(\.text), ["Type “Mohit” into “First name”", "Type “Singh” into “Last name”",
                                                  "Type “mohit@example.com” into “Email”"])
    }

    func testTheAIOnlySeesPlaceholdersNeverValues() {
        let described = snapshot(fields: [field(1, "Email", value: "secret@old.com")]).describe(details: me)
        XCTAssertFalse(described.contains("mohit@example.com"))
        XCTAssertFalse(described.contains("secret@old.com"), "field contents are never sent")
        XCTAssertFalse(described.contains("Mohit"))
        XCTAssertTrue(described.contains("{{email}}"))
        XCTAssertTrue(described.contains("[has text]"))
        XCTAssertFalse(ScreenAgentPrompt.system(replyLanguage: "").contains("mohit"))
    }

    func testOnlySavedDetailsOrSpokenWordsAreTyped() {
        let request = ToolGateText.fold("fill the form, my nickname is Mo")
        XCTAssertEqual(try ScreenPlanValidator.resolve("{{fullName}}", details: me, request: request).get(), "Mohit Singh")
        XCTAssertEqual(try ScreenPlanValidator.resolve("Mo", details: me, request: request).get(), "Mo")
        XCTAssertThrowsError(try ScreenPlanValidator.resolve("Invented Street 5", details: me, request: request).get())
        XCTAssertThrowsError(try ScreenPlanValidator.resolve("{{website}}", details: me, request: request).get(), "no website saved")
        XCTAssertThrowsError(try ScreenPlanValidator.resolve("{{password}}", details: me, request: request).get())
    }

    func testDetailsAreStoredOnlyInTheKeychainStoreAndTrimmedOnSave() {
        MyDetailsStore.testOverride = .some(nil)
        var typed = MyDetails()
        typed.set(.street, "12 Park Street ")
        typed.set(.fullName, "Mohit Singh")
        XCTAssertTrue(MyDetailsStore.save(typed))
        let loaded = MyDetailsStore.load()
        XCTAssertEqual(loaded.street, "12 Park Street")
        XCTAssertEqual(loaded.firstName, "Mohit")
        XCTAssertEqual(loaded.lastName, "Singh")
        var card = MyDetails()
        card.firstName = "Other"
        card.email = "card@example.com"
        let merged = loaded.merged(with: card)
        XCTAssertEqual(merged.firstName, "Mohit", "what you typed wins")
        XCTAssertEqual(merged.email, "card@example.com", "empty fields come from the Contacts card")
        let everything = UserDefaults.standard.dictionaryRepresentation().map { "\($0.value)" }.joined()
        XCTAssertFalse(everything.contains("12 Park Street"))
    }

    // MARK: Plans

    func testParsesScreenPlans() throws {
        let text = #"{"summary":"Export","steps":[{"action":"menu","path":["File","Export as PDF…"]},{"action":"press","target":"Save"},{"action":"fill","field":"Email","value":"{{email}}"},{"action":"toggle","target":"Remember me","on":false},{"action":"choose","target":"Country","option":"India"},{"action":"mac","tool":"set_dark_mode","input":{"mode":"on"}},{"action":"run","target":"rm"},{"action":"mac","tool":"lock_screen"}]}"#
        let parsed = ScreenPlanParser.parse(text)
        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.plan?.steps.count, 6)
        XCTAssertEqual(parsed.dropped.map(\.index), [6, 7], "unknown actions and Mac tools outside the list are dropped")
        XCTAssertEqual(parsed.plan?.steps.last, .mac(AgentToolCall(name: "set_dark_mode", input: ["mode": .string("on")])))
        XCTAssertEqual(ScreenPlanParser.parse("```json\n" + text + "\n```").plan, parsed.plan)
        XCTAssertFalse(ScreenPlanParser.parse("sorry").isValid)
    }

    @MainActor
    func testExportAsPDFPlan() {
        let menus: [(path: [String], enabled: Bool)] = [(["File", "Export as PDF..."], true), (["File", "Print…"], true), (["Edit", "Delete"], true)]
        let plan = ScreenPlan(summary: "", steps: [.menu(["File", "Export as PDF…"]), .press("Save"), .menu(["Edit", "Delete"])])
        let preview = ScreenPlanValidator.preview(plan, snapshot: snapshot(menus: menus), request: "click export and save it as a pdf", details: me)
        XCTAssertEqual(preview.lines.map(\.text), ["Choose File ▸ Export as PDF...", "Press “Save”", "Choose Edit ▸ Delete (asks you first)"],
                       "“…” and “...” match; Save in the sheet the menu opens is allowed; Delete asks first")
        XCTAssertTrue(preview.dropped.isEmpty)
        XCTAssertFalse(preview.lines[0].undoable)
        XCTAssertTrue(preview.lines[2].asksFirst)
        XCTAssertTrue(preview.needsApproval)
    }

    @MainActor
    func testFinalButtonsAskFirstAndSomeAreNeverPressed() {
        let finals = ["Sign up", "Submit", "Send", "Pay now", "Buy", "Place order", "Registrieren", "Enviar", "S'inscrire", "送信"]
        let nevers = ["Empty Trash", "Delete Account", "Log Out", "Shut Down"]
        let controls = (finals + nevers).map { ScreenControl(role: "AXButton", title: $0, isOn: nil, options: []) }
        let plan = ScreenPlan(summary: "", steps: controls.map { .press($0.title) })
        let preview = ScreenPlanValidator.preview(plan, snapshot: snapshot(controls: controls), request: "sign me up", details: me)
        XCTAssertEqual(preview.actions.count, finals.count)
        XCTAssertTrue(preview.lines.allSatisfy(\.asksFirst), "every final action asks first")
        XCTAssertEqual(preview.dropped.count, nevers.count, "these are never pressed, even when asked")
        XCTAssertNil(ScreenSafety.blockedWord(in: "Save"))
        XCTAssertNil(ScreenSafety.blockedWord(in: "Export"))
        XCTAssertNil(ScreenSafety.blockedWord(in: "Next"))
        XCTAssertNotNil(ScreenSafety.neverWord(in: "Empty Trash"))
        XCTAssertNil(ScreenSafety.neverWord(in: "Send"))
    }

    // MARK: Clicks, typing, keys, music

    func testParsesActSteps() {
        let text = #"{"summary":"play","done":false,"steps":[{"action":"click","x":500,"y":250,"label":"Search"},{"action":"type","text":"hello"},{"action":"key","keys":"cmd+l"},{"action":"key","keys":"cmd+q"},{"action":"play","notes":[{"x":100,"y":900,"ms":300},{"key":"a","ms":50},{"x":2000,"y":1,"ms":300}]},{"action":"wait","ms":99999},{"action":"click","x":-5,"y":10}]}"#
        let parsed = ScreenPlanParser.parse(text)
        XCTAssertEqual(parsed.plan?.done, false)
        XCTAssertEqual(parsed.plan?.steps, [
            .click(x: 0.5, y: 0.25, label: "Search", final: false),
            .type("hello"),
            .key("cmd+l", final: false),
            .play([ScreenNote(x: 0.1, y: 0.9, ms: 300), ScreenNote(key: "a", ms: 50)]),
            .wait(5_000)
        ], "cmd+q is never pressed; points outside 0…1000 are dropped; times are clamped")
        XCTAssertEqual(parsed.dropped.map(\.index), [3, 6])
    }

    // MARK: Plan format (Gmail "not a step")

    func testSafeSlipsAreAcceptedAndSentencesExplained() {
        let text = #"{"summary":"reply","done":false,"steps":["Click Reply",{"type":"click","x":640,"y":980,"label":"Reply"},{"action":"tap","coordinate":[100,200]},{"action":"hotkey","key":"cmd+l"},{"action":"type_text","value":"Please block my account."},{"action":"open_url","url":"https://example.com"},{"x":1,"y":2},{"action":"fly"}]}"#
        let parsed = ScreenPlanParser.parse(text)
        XCTAssertEqual(parsed.plan?.steps, [
            .click(x: 0.64, y: 0.98, label: "Reply", final: false),
            .click(x: 0.1, y: 0.2, label: "", final: false),
            .key("cmd+l", final: false),
            .type("Please block my account."),
            .mac(AgentToolCall(name: "open_website", input: ["url": .string("https://example.com")]))
        ])
        XCTAssertEqual(parsed.dropped.map(\.index), [0, 6, 7])
        XCTAssertTrue(parsed.dropped[0].reason.hasPrefix("the planner wrote a sentence, not a step"))
        XCTAssertTrue(parsed.dropped[1].reason.hasPrefix("a step without an action (it had: x, y)"))
        XCTAssertEqual(parsed.dropped[2].reason, "“fly” isn't something Bibbles can do")
    }

    func testStrictModeNullsAreIgnored() {
        let text = #"{"summary":"","done":true,"steps":[{"action":"click","x":500,"y":500,"label":null,"final":null,"path":null,"target":null,"field":null,"value":null,"on":null,"option":null,"tool":null,"input":null,"folder":null,"name":null,"to_x":null,"to_y":null,"text":null,"keys":null,"ms":null,"notes":null}]}"#
        XCTAssertEqual(ScreenPlanParser.parse(text).plan?.steps, [.click(x: 0.5, y: 0.5, label: "", final: false)])
    }

    func testStrictFormatListsEveryField() {
        func check(_ object: [String: Any], path: String) {
            if let properties = object["properties"] as? [String: Any] {
                XCTAssertEqual(object["additionalProperties"] as? Bool, false, path)
                XCTAssertEqual(Set(object["required"] as? [String] ?? []), Set(properties.keys), "\(path): every field required (null when unused)")
                for (key, value) in properties { if let child = value as? [String: Any] { check(child, path: path + "." + key) } }
            }
            if let items = object["items"] as? [String: Any] { check(items, path: path + "[]") }
            for option in object["anyOf"] as? [[String: Any]] ?? [] { check(option, path: path + "?") }
        }
        check(ScreenPlanParser.strictSchema, path: "plan")
    }

    func testPlannerAsksOpenAIStrictlyAndGeminiWithoutAFormat() throws {
        DeveloperKeychain.testOverride = [.openrouter: "or"]
        defer { DeveloperKeychain.testOverride = nil }
        let gpt = StubURLProtocol.json(of: try AgentPlanner.request(model: ModelCatalog.gpt5Mini, system: "S", user: "U",
                                                                    strictSchema: ScreenPlanParser.strictSchema))
        let format = gpt["response_format"] as? [String: Any]
        XCTAssertEqual((format?["json_schema"] as? [String: Any])?["strict"] as? Bool, true)
        let gemini = StubURLProtocol.json(of: try AgentPlanner.request(model: ModelCatalog.gemini38Flash, system: "S", user: "U",
                                                                       strictSchema: ScreenPlanParser.strictSchema))
        XCTAssertNil(gemini["response_format"], "Gemini rejected the loose format, so it gets none")
    }

    func testEmptyRepliesSayWhy() {
        let thinking = Data(#"{"content":[{"type":"thinking","thinking":"…"}],"stop_reason":"max_tokens"}"#.utf8)
        XCTAssertEqual(AgentPlanner.emptyReplyProblem(thinking, provider: "Anthropic"),
                       .provider(name: "Anthropic", status: 200, problem: "ran out of room before answering (it spent it thinking)"))
        XCTAssertEqual(AgentPlanner.emptyReplyProblem(Data("{}".utf8), provider: "OpenRouter"), .invalidResponse("OpenRouter"))
    }

    // MARK: Gmail reply fixes

    func testAMissingDetailLeavesOutOnlyThatPart() {
        var noName = me
        noName.firstName = ""
        noName.lastName = ""
        let (text, missing) = ScreenPlanValidator.typing("Please block my account.\n\nThanks,\n{{fullName}}", details: noName)
        XCTAssertEqual(text, "Please block my account.\n\nThanks,")
        XCTAssertEqual(missing, ["Full name"])
        XCTAssertEqual(ScreenPlanValidator.typing("Hi, I'm {{firstName}}, email {{email}}", details: me).text,
                       "Hi, I'm Mohit, email mohit@example.com")
        XCTAssertEqual(ScreenPlanValidator.typing("My password is {{password}}", details: me).text, "My password is",
                       "unknown placeholders are never filled")
    }

    @MainActor
    func testSendIsDroppedWhenAnEarlierStepWasSkipped() {
        var screen = snapshot()
        screen.screenFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let plan = ScreenPlan(summary: "", steps: [.fill(field: "Nickname", value: "Mo"),          // no such field: skipped
                                                   .click(x: 0.4, y: 0.9, label: "Send", final: true)])
        let preview = ScreenPlanValidator.preview(plan, snapshot: screen, request: "reply and send", details: me)
        XCTAssertTrue(preview.lines.isEmpty)
        XCTAssertEqual(preview.dropped.map(\.index), [0, 1])
        XCTAssertTrue(preview.dropped[1].reason.contains("an earlier step was skipped"))

        // After a click that may open a box, a box that isn't there yet means "look again", not "skip".
        let later = ScreenPlan(summary: "", steps: [.click(x: 0.3, y: 0.9, label: "Reply", final: false),
                                                    .fill(field: "Nickname", value: "Mo"),
                                                    .click(x: 0.4, y: 0.9, label: "Send", final: true)])
        let looked = ScreenPlanValidator.preview(later, snapshot: screen, request: "reply and send", details: me)
        XCTAssertEqual(looked.lines.map(\.text), ["Click “Reply”"])
        XCTAssertTrue(looked.dropped.isEmpty)
        XCTAssertTrue(looked.looksAgain, "Send is planned again once the reply box is open")

        let typed = ScreenPlan(summary: "", steps: [.click(x: 0.3, y: 0.9, label: "Reply", final: false),
                                                    .type("Please block my account. {{fullName}}"),
                                                    .click(x: 0.4, y: 0.9, label: "Send", final: true)])
        var noName = me
        noName.firstName = ""
        noName.lastName = ""
        let kept = ScreenPlanValidator.preview(typed, snapshot: screen, request: "reply and send", details: noName)
        XCTAssertEqual(kept.lines.map(\.text), ["Click “Reply”", "Type “Please block my account.”", "Click “Send” (asks you first)"],
                       "a left-out name is a note, not a skipped step, so Send stays (and still asks first)")
        XCTAssertEqual(kept.notes.count, 1)
        XCTAssertTrue(kept.dropped.isEmpty)
    }

    func testKeysAndShortcuts() {
        XCTAssertEqual(ScreenKeys.parse("return")?.code, 36)
        XCTAssertEqual(ScreenKeys.parse("cmd+L")?.flags, .maskCommand)
        XCTAssertEqual(ScreenKeys.parse("cmd+shift+d")?.flags, [.maskCommand, .maskShift])
        XCTAssertNil(ScreenKeys.parse("cmd+q"))
        XCTAssertNil(ScreenKeys.parse("hyper+a"))
        XCTAssertNil(ScreenKeys.parse("f13"))
    }

    func testScreenshotPointsBecomeScreenPoints() {
        // A 1000×800 display at the origin, main display 800 tall.
        let point = ScreenGeometry.globalPoint(x: 0.25, y: 0.5, displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                                               primaryHeight: 800)
        XCTAssertEqual(point, CGPoint(x: 250, y: 400))
        let top = ScreenGeometry.globalPoint(x: 0, y: 0, displayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800), primaryHeight: 800)
        XCTAssertEqual(top, CGPoint(x: 0, y: 0), "top-left of the screenshot is top-left of the screen")
    }

    func testParsesChordsHoldsStrumsAndDrags() {
        let text = #"{"summary":"","steps":[{"action":"play","notes":[{"keys":["a","j"],"ms":250},{"key":"d","ms":0},{"key":"f","ms":500,"hold":900},{"x":400,"y":300,"to":{"x":400,"y":620},"ms":500,"hold":180},{"points":[{"x":100,"y":100},{"x":200,"y":100}],"ms":300},{"keys":["cmd+q"],"ms":100}]},{"action":"drag","x":200,"y":500,"to_x":600,"to_y":500,"label":"Volume"}]}"#
        let steps = ScreenPlanParser.parse(text).plan?.steps
        guard case .play(let notes)? = steps?.first else { return XCTFail("play") }
        XCTAssertEqual(notes.count, 5, "a note with only a forbidden key is dropped")
        XCTAssertEqual(notes[0].allKeys, ["a", "j"])
        XCTAssertEqual(notes[1].ms, 0, "0 ms = together with the next note")
        XCTAssertEqual(notes[2].hold, 900)
        XCTAssertEqual(notes[3].to, ScreenPoint(x: 0.4, y: 0.62))
        XCTAssertEqual(notes[4].allPoints.count, 2)
        XCTAssertEqual(steps?.last, .drag(x: 0.2, y: 0.5, toX: 0.6, toY: 0.5, label: "Volume", final: false))
    }

    func testTimelineKeepsChordsTogetherHoldsLongAndStrums() {
        let a = CGPoint(x: 10, y: 10), b = CGPoint(x: 50, y: 10), top = CGPoint(x: 0, y: 0), bottom = CGPoint(x: 0, y: 100)
        let timeline = ScreenPlayback.timeline([
            ScreenPlayNote(keys: ["a", "j"], ms: 250),            // chord at 0
            ScreenPlayNote(keys: ["d"], ms: 500, hold: 900),       // held over the next notes
            ScreenPlayNote(keys: ["d"], ms: 200),                  // pressed again while held: released first
            ScreenPlayNote(points: [a, b], ms: 300),               // two clicks "together"
            ScreenPlayNote(points: [top], ms: 400, hold: 150, to: bottom)  // strum
        ])
        func times(_ event: ScreenPlayback.Event) -> [Int] { timeline.filter { $0.event == event }.map(\.time) }
        XCTAssertEqual(times(.keyDown("a")), [0])
        XCTAssertEqual(times(.keyDown("j")), [0], "chords are pressed together")
        XCTAssertEqual(times(.keyDown("d")), [250, 750])
        XCTAssertEqual(times(.keyUp("d")).first, 750, "a held key is released before it's pressed again")
        XCTAssertEqual(times(.mouseDown(a)), [950])
        XCTAssertEqual(times(.mouseDown(b)), [978], "one pointer: clicks together land a few ms apart")
        XCTAssertEqual(times(.mouseDown(top)), [1250])
        XCTAssertEqual(times(.mouseUp(bottom)), [1400])
        XCTAssertGreaterThan(timeline.filter { if case .mouseDrag = $0.event { return true } else { return false } }.count, 3)
        XCTAssertEqual(timeline.map(\.time), timeline.map(\.time).sorted(), "one timeline, in order")
        let downs = timeline.filter { if case .keyDown = $0.event { return true } else { return false } }.count
        let ups = timeline.filter { if case .keyUp = $0.event { return true } else { return false } }.count
        XCTAssertEqual(downs, ups, "every key is released")
    }

    @MainActor
    func testDragAndChordPreview() {
        var withScreenshot = snapshot()
        withScreenshot.screenFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let plan = ScreenPlan(summary: "", steps: [
            .play([ScreenNote(ms: 250, keys: ["a", "j"]), ScreenNote(x: 0.4, y: 0.3, ms: 400, hold: 150, to: ScreenPoint(x: 0.4, y: 0.6))]),
            .drag(x: 0.2, y: 0.5, toX: 0.6, toY: 0.5, label: "Volume", final: false),
            .drag(x: 0.2, y: 0.5, toX: 0.6, toY: 0.5, label: "Empty Trash", final: false)
        ])
        let preview = ScreenPlanValidator.preview(plan, snapshot: withScreenshot, request: "play and turn it up", details: me)
        XCTAssertEqual(preview.lines.map(\.text), ["Play 2 notes with chords and strums (about 1 s)", "Drag “Volume”"])
        XCTAssertEqual(preview.dropped.count, 1, "never-pressed things can't be dragged either")
        let noScreen = ScreenPlanValidator.preview(ScreenPlan(summary: "", steps: [.drag(x: 0, y: 0, toX: 1, toY: 1, label: "", final: false)]),
                                                   snapshot: snapshot(), request: "", details: me)
        XCTAssertTrue(noScreen.isEmpty)
    }

    @MainActor
    func testPianoMailAndMessagesPlans() {
        var withScreenshot = snapshot()
        withScreenshot.screenFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let piano = ScreenPlan(summary: "", steps: [.play([ScreenNote(x: 0.1, y: 0.9, ms: 500), ScreenNote(x: 0.2, y: 0.9, ms: 500)])])
        let played = ScreenPlanValidator.preview(piano, snapshot: withScreenshot, request: "play a happy tune", details: me)
        XCTAssertEqual(played.lines.map(\.text), ["Play 2 notes (about 1 s)"])
        XCTAssertFalse(played.needsApproval, "clicks alone run straight on")
        let noScreenshot = ScreenPlanValidator.preview(piano, snapshot: snapshot(), request: "play", details: me)
        XCTAssertTrue(noScreenshot.isEmpty, "no clicking without Screen Recording")

        let mail = ScreenPlan(summary: "", steps: [.click(x: 0.5, y: 0.5, label: "Message body", final: false),
                                                   .type("Hi Sam, I'll join at 5."),
                                                   .key("cmd+shift+d", final: true)])
        let written = ScreenPlanValidator.preview(mail, snapshot: withScreenshot, request: "reply I'll join at 5 and send", details: me)
        XCTAssertEqual(written.lines.map(\.text), ["Click “Message body”", "Type “Hi Sam, I'll join at 5.”", "Press cmd+shift+d (asks you first)"])
        XCTAssertTrue(written.needsApproval)

        let messages = ScreenSnapshot(appName: "Messages", menus: [], controls: [], fields: [], screenFrame: CGRect(x: 0, y: 0, width: 10, height: 10))
        let sent = ScreenPlanValidator.preview(ScreenPlan(summary: "", steps: [.type("On my way"), .key("return", final: false)]),
                                               snapshot: messages, request: "tell Sam on my way", details: me)
        XCTAssertTrue(sent.lines[1].asksFirst, "Return sends in Messages, so it asks first")
    }

    @MainActor
    func testUnknownTargetsAndNeverFillFieldsAreDropped() {
        let fields = [field(1, "Email"), field(2, "Card number")]
        let controls = [ScreenControl(role: "AXCheckBox", title: "Remember me", isOn: true, options: []),
                        ScreenControl(role: "AXPopUpButton", title: "Country", isOn: nil, options: ["India", "Germany"])]
        let plan = ScreenPlan(summary: "", steps: [
            .press("Save"),                                   // no menu before it, not on screen
            .fill(field: "Card number", value: "4111"),       // never filled
            .fill(field: "Nickname", value: "Mo"),            // no such field
            .toggle("Remember me", on: false),
            .choose("Country", option: "India"),              // a saved detail
            .choose("Country", option: "France")              // not said, not saved
        ])
        let preview = ScreenPlanValidator.preview(plan, snapshot: snapshot(fields: fields, controls: controls),
                                                  request: "untick remember me and pick my country", details: me)
        XCTAssertEqual(preview.lines.map(\.text), ["Turn off “Remember me”", "Choose “India” in “Country”"])
        XCTAssertEqual(preview.dropped.map(\.index), [0, 1, 2, 5])
    }

    @MainActor
    func testDarkModeIsAMacActionAndCanBeUndone() {
        let plan = ScreenPlan(summary: "", steps: [.mac(AgentToolCall(name: "set_dark_mode", input: ["mode": .string("on")]))])
        let preview = ScreenPlanValidator.preview(plan, snapshot: snapshot(), request: "go to settings and turn on dark mode", details: me)
        XCTAssertEqual(preview.actions.count, 1)
        XCTAssertTrue(preview.lines[0].undoable)
    }

    // MARK: Save where the user says

    func testParsesSaveSteps() {
        let parsed = ScreenPlanParser.parse(#"{"summary":"","steps":[{"action":"menu","path":["File","Export as PDF…"]},{"action":"save","folder":"Desktop","name":"holi final"},{"action":"save"}]}"#)
        XCTAssertEqual(parsed.plan?.steps, [.menu(["File", "Export as PDF…"]), .save(folder: "Desktop", name: "holi final"),
                                            .save(folder: nil, name: nil)])
    }

    func testSaveFoldersStayInsideTheHomeFolder() throws {
        let desktop = try XCTUnwrap(FileLocation.desktop.url)
        XCTAssertEqual(try ScreenSaveLocation.resolve("Desktop", request: "").get().url.path, desktop.standardizedFileURL.path)
        XCTAssertEqual(try ScreenSaveLocation.resolve("Schreibtisch", request: "").get().url.path, desktop.standardizedFileURL.path)
        XCTAssertEqual(ScreenSaveLocation.display(desktop), "Desktop")
        let missing = "Bibbles Test \(UUID().uuidString.prefix(6))"
        XCTAssertThrowsError(try ScreenSaveLocation.resolve("Desktop/\(missing)", request: "save it on the desktop").get(),
                             "a missing folder is only created when the user asks for a new folder")
        let created = try ScreenSaveLocation.resolve("Desktop/\(missing)", request: ToolGateText.fold("save it in a new folder on the desktop")).get()
        XCTAssertTrue(created.create)
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.url.path), "nothing is created before Start")
        for unsafe in ["/etc", "/System/Library", "~/Library/Preferences", "Desktop/../../etc", "Desktop/.secret"] {
            XCTAssertThrowsError(try ScreenSaveLocation.resolve(unsafe, request: "new folder").get(), unsafe)
        }
    }

    @MainActor
    func testSaveNeedsASheetAndOnlyNamesTheUserSaid() {
        let menus: [(path: [String], enabled: Bool)] = [(["File", "Export as PDF…"], true)]
        let plan = ScreenPlan(summary: "", steps: [.save(folder: "Desktop", name: nil),
                                                   .menu(["File", "Export as PDF…"]),
                                                   .save(folder: "Desktop", name: "holi final"),
                                                   .save(folder: nil, name: "invented name")])
        let preview = ScreenPlanValidator.preview(plan, snapshot: snapshot(menus: menus),
                                                  request: "export this to pdf, save it on the desktop as holi final", details: me)
        XCTAssertEqual(preview.lines.map(\.text), ["Choose File ▸ Export as PDF…", "Save as “holi final” in Desktop"])
        XCTAssertEqual(preview.dropped.map(\.index), [0, 3])
        XCTAssertFalse(preview.lines[1].undoable)
    }

    func testFindsTheFileASheetJustSaved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BibblesSaved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = Date()
        let old = folder.appendingPathComponent("holi6.pdf")
        try Data("x".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: started.addingTimeInterval(-3_600)], ofItemAtPath: old.path)
        try Data("x".utf8).write(to: folder.appendingPathComponent("holi7.pdf"))
        XCTAssertEqual(ScreenSavedFile.locate(name: "holi7", folders: [folder], since: started)?.lastPathComponent, "holi7.pdf")
        XCTAssertNil(ScreenSavedFile.locate(name: "holi6", folders: [folder], since: started), "an old file is not the one just saved")
    }

    // MARK: Detection and routing

    func testDetection() {
        XCTAssertTrue(ScreenAgentDetector.isDetailsFill("Fill in this sign-up form with my details"))
        XCTAssertTrue(ScreenAgentDetector.isDetailsFill("Rellena este formulario con mis datos"))
        XCTAssertTrue(ScreenAgentDetector.isDetailsFill("Füll das Formular mit meinen Daten aus"))
        XCTAssertTrue(ScreenAgentDetector.isDetailsFill("ye form meri details se bhar do"))
        XCTAssertFalse(ScreenAgentDetector.isDetailsFill("what are my details on this page"))
        XCTAssertTrue(ScreenAgentDetector.mightBeAction("Click Export and save it as a PDF"))
        XCTAssertTrue(ScreenAgentDetector.mightBeAction("Go to Settings and turn on dark mode"))
        XCTAssertFalse(ScreenAgentDetector.mightBeAction("what is this chart"))
        for command in ["export this holi7 image file to pdf", "Please export it as a PDF", "Click Save", "can you turn off dark mode",
                        "Exportiere das als PDF", "Exporta esto a PDF", "isko pdf mein export kar do"] {
            XCTAssertTrue(ScreenAgentDetector.isDirectCommand(command), command)
        }
        for question in ["how do I export this as a PDF?", "how do I export this", "where is the Export button",
                         "what does export do", "Clean up my Downloads folder"] {
            XCTAssertFalse(ScreenAgentDetector.isDirectCommand(question), question)
        }
    }

    func testRoutingOnlyWhileTheToggleIsOn() {
        AgentSettings.screenTestOverride = false
        AgentSettings.testOverride = false
        XCTAssertNil(HybridRouter.accept(RouterResult(route: .agentScreen, confidence: 0.95)))
        XCTAssertFalse(RouterPrompt.system.contains("agent_screen"))
        AgentSettings.screenTestOverride = true
        XCTAssertEqual(HybridRouter.accept(RouterResult(route: .agentScreen, confidence: 0.95)), .agentScreen)
        XCTAssertTrue(RouterPrompt.system.contains("agent_screen"))
        XCTAssertEqual(HybridRouter.keywordVerdict(for: "Click Export and save it as a PDF", flags: RouterFlags()),
                       .unclear("agents on: router decides"))
        // However it's phrased, the router decides; only trivial requests skip it.
        XCTAssertEqual(HybridRouter.keywordVerdict(for: "hey bibbles if you don't mind can you please export this holi7 image to pdf",
                                                   flags: RouterFlags()), .unclear("agents on: router decides"))
        if case .unclear = HybridRouter.keywordVerdict(for: "thanks", flags: RouterFlags()) { XCTFail("greetings skip the router") }
        if case .unclear = HybridRouter.keywordVerdict(for: "what time is it", flags: RouterFlags()) { XCTFail("the time is local") }
        AgentSettings.testOverride = true
        XCTAssertTrue(RouterPrompt.system.contains("agent_files") && RouterPrompt.system.contains("agent_screen"))
    }

    // MARK: Scroll, other apps, files, quick plans, voice

    @MainActor
    func testNewMessageWindowIsLookedAtBeforeFillingIt() {
        // Mail's main window: no To box yet. The plan opens New Message, then fills it.
        let menus: [(path: [String], enabled: Bool)] = [(["File", "New Message"], true)]
        let plan = ScreenPlan(summary: "", steps: [.menu(["File", "New Message"]), .wait(1_500),
                                                   .fill(field: "Email", value: "soham@gmail.com"),
                                                   .type("Total: £600.00"), .key("cmd+return", final: true)], done: true)
        let preview = ScreenPlanValidator.preview(plan, snapshot: snapshot(menus: menus),
                                                  request: "email the total to soham@gmail.com", details: me)
        XCTAssertEqual(preview.lines.map(\.text), ["Choose File ▸ New Message", "Wait 1.5 s"])
        XCTAssertTrue(preview.dropped.isEmpty, "nothing is skipped: the rest waits for the new window")
        XCTAssertTrue(preview.looksAgain)

        // In the new window, "Email" finds the To box.
        let compose = snapshot(fields: [field(1, "To:"), field(2, "Subject:")])
        let filled = ScreenPlanValidator.preview(ScreenPlan(summary: "", steps: [.fill(field: "Email", value: "soham@gmail.com")]),
                                                 snapshot: compose, request: "email the total to soham@gmail.com", details: me)
        XCTAssertEqual(filled.lines.map(\.text), ["Type “soham@gmail.com” into “To:”"])
    }

    @MainActor
    func testComposeEmailPutsEachPartInItsBox() {
        let text = #"{"summary":"","done":true,"steps":[{"action":"compose_email","recipients":"mohit55599@gmail.com, boss@x.com","subject":"Invoice total","body":"Hi Mohit,\n\nHow are you?\n\nTotal: £600.00"}]}"#
        guard case .composeEmail(let recipients, let subject, let body)? = ScreenPlanParser.parse(text).plan?.steps.first else {
            return XCTFail("compose_email")
        }
        XCTAssertEqual(recipients, "mohit55599@gmail.com, boss@x.com")
        XCTAssertEqual(subject, "Invoice total")
        XCTAssertEqual(body, "Hi Mohit,\n\nHow are you?\n\nTotal: £600.00")

        let messageBox = FormField(id: 4, element: AXUIElementCreateApplication(getpid()), role: "AXWebArea", label: "Message body",
                                   value: "", hasCursor: false)
        let compose = snapshot(fields: [field(1, "To:"), field(2, "Cc:"), field(3, "Subject:"), messageBox])
        let request = "take the total from this image and open apple mail to email it to \"mohit55599@gmail.com\" and greet Mohit"
        let preview = ScreenPlanValidator.preview(ScreenPlanParser.parse(text).plan!, snapshot: compose, request: request, details: me)
        guard case .composeEmail(let parts)? = preview.actions.first else { return XCTFail("one email step") }
        XCTAssertEqual(parts.map(\.field.id), [1, 3, 4], "To, Subject and the message, never Cc")
        XCTAssertEqual(parts.map(\.text).first, "mohit55599@gmail.com", "only the address the user said")
        XCTAssertTrue(preview.notes.contains { $0.contains("boss@x.com") })
        XCTAssertTrue(preview.needsApproval, "the user sees the email before it is written")

        // The plan left the address out, and Mail's To box has no label: the address
        // written in the request goes into the first box above Subject.
        let unlabeled = snapshot(fields: [field(1, ""), field(2, "Cc:"), field(3, "Subject:"), messageBox])
        let curly = "take the total from this image and open apple mail to email it to \"mohit55599@gmail.com” and greet Mohit"
        let noTo = ScreenPlan(summary: "", steps: [.composeEmail(recipients: nil, subject: "Invoice", body: "Hi Mohit")])
        let filled = ScreenPlanValidator.preview(noTo, snapshot: unlabeled, request: curly, details: me)
        guard case .composeEmail(let boxes)? = filled.actions.first else { return XCTFail("one email step") }
        XCTAssertEqual(boxes.map(\.field.id), [1, 3, 4])
        XCTAssertEqual(boxes.first?.text, "mohit55599@gmail.com")

        // Spoken addresses count as said.
        XCTAssertTrue(MailCompose.userSaid("sam.k@work.com", in: "email sam dot k at work dot com"))
        XCTAssertFalse(MailCompose.userSaid("sam@evil.com", in: "email sam at work dot com"))

        // No compose window yet, right after File ▸ New Message: look again instead of skipping.
        let menus: [(path: [String], enabled: Bool)] = [(["File", "New Message"], true)]
        let opening = ScreenPlan(summary: "", steps: [.menu(["File", "New Message"]),
                                                      .composeEmail(recipients: "mohit55599@gmail.com", subject: "Hi", body: "Hello")])
        let first = ScreenPlanValidator.preview(opening, snapshot: snapshot(menus: menus), request: request, details: me)
        XCTAssertEqual(first.lines.map(\.text), ["Choose File ▸ New Message"])
        XCTAssertTrue(first.looksAgain)
        XCTAssertTrue(first.dropped.isEmpty)
    }

    @MainActor
    func testEmailFromAnyAppOpensAFilledNewMessage() {
        // In Preview, with no email window: one step opens a new message with every part filled in.
        let request = "take the total from this image and open apple mail to email it to \"mohit55599@gmail.com” and greet Mohit"
        let plan = ScreenPlan(summary: "", steps: [.remember("Total: £600.00"),
                                                   .composeEmail(recipients: nil, subject: "Invoice — £600.00", body: "Hi Mohit,\nHow are you?")])
        let preview = ScreenPlanValidator.preview(plan, snapshot: snapshot(), request: request, details: me)
        guard case .mailto(let url)? = preview.actions.last else { return XCTFail("a filled new message") }
        let link = url.absoluteString
        XCTAssertTrue(link.hasPrefix("mailto:mohit55599@gmail.com?subject=Invoice%20"), link)
        XCTAssertTrue(link.contains("body=Hi%20Mohit%2C%0D%0AHow%20are%20you%3F"), link)
        XCTAssertFalse(link.contains("+"))
        XCTAssertTrue(preview.lines.last?.text.hasPrefix("New email in your mail app — To: mohit55599@gmail.com") == true)
        XCTAssertTrue(preview.needsApproval)
        XCTAssertTrue(ScreenAction.mailto(url).changesApp)

        // switch_app with no name: the app named in the request.
        XCTAssertEqual(ScreenPlanParser.parse(#"{"summary":"","steps":[{"action":"switch_app"}]}"#).plan?.steps, [.switchApp("")])
        XCTAssertEqual(ScreenApps.mentioned(in: request, among: ["Preview", "Mail", "Messages", "Terminal"]), "Mail")
        XCTAssertNil(ScreenApps.mentioned(in: "send this by email", among: ["Mail", "Notes"]), "\"email\" is not the Mail app")
        XCTAssertNil(ScreenApps.mentioned(in: "open terminal", among: ["Terminal"]))
    }

    @MainActor
    func testMailBoxesAreFilledByName() {
        // Slips seen in Mail: "type" into a named box, and switch_app with the name in another field.
        let text = #"{"summary":"","done":false,"steps":[{"action":"type","field":"Subject:","text":"Invoice total"},{"action":"switch_app","label":"Mail"},{"action":"type","label":"To:"}]}"#
        let parsed = ScreenPlanParser.parse(text)
        XCTAssertEqual(parsed.plan?.steps, [.fill(field: "Subject:", value: "Invoice total"), .switchApp("Mail")])
        XCTAssertTrue(parsed.dropped.first?.reason.contains("(it had: label)") == true, "the reason says what the step had")

        let compose = snapshot(fields: [field(1, "To:"), field(2, "Cc:"), field(3, "Subject:")])
        let request = "take the total from this invoice and email it to soham@gmail.com"
        let plan = ScreenPlan(summary: "", steps: [.fill(field: "To:", value: "soham@gmail.com"),
                                                   .fill(field: "Subject:", value: "Invoice total: £600.00"),
                                                   .fill(field: "Cc:", value: "boss@company.com")])
        let preview = ScreenPlanValidator.preview(plan, snapshot: compose, request: request, details: me)
        XCTAssertEqual(preview.lines.map(\.text), ["Type “soham@gmail.com” into “To:”", "Type “Invoice total: £600.00” into “Subject:”"],
                       "a subject may be new text in an email")
        XCTAssertEqual(preview.dropped.map(\.index), [2], "recipients are only addresses the user said")

        // Outside an email window, fields still take only the user's words.
        let form = snapshot(fields: [field(1, "Name"), field(2, "Company")])
        let strict = ScreenPlanValidator.preview(ScreenPlan(summary: "", steps: [.fill(field: "Company", value: "Acme Ltd")]),
                                                 snapshot: form, request: "fill this form", details: me)
        XCTAssertTrue(strict.actions.isEmpty)
    }

    @MainActor
    func testParsesNewSteps() {
        let text = #"{"summary":"x","done":false,"steps":[{"action":"scroll","direction":"down","amount":4},{"action":"scroll_up"},{"action":"remember","text":"Total: ₹4,250"},{"action":"attach","name":"resume","folder":"Downloads"},{"action":"open_file","file":"holi7"},{"action":"switch_app","app":"Mail"},{"action":"scroll","direction":"sideways"}]}"#
        let parsed = ScreenPlanParser.parse(text)
        XCTAssertEqual(parsed.plan?.steps, [
            .scroll(direction: "down", amount: 4, x: nil, y: nil),
            .scroll(direction: "up", amount: 3, x: nil, y: nil),
            .remember("Total: ₹4,250"),
            .attach(name: "resume", folder: "Downloads"),
            .openFile(name: "holi7", folder: nil),
            .switchApp("Mail")
        ])
        XCTAssertEqual(parsed.dropped.map(\.index), [6], "an unknown scroll direction is dropped")
        XCTAssertEqual(parsed.plan?.done, false)
    }

    @MainActor
    func testRememberAndScrollPreview() {
        let plan = ScreenPlan(summary: "", steps: [.remember("Total: 42"), .scroll(direction: "down", amount: 2, x: nil, y: nil)])
        let preview = ScreenPlanValidator.preview(plan, snapshot: snapshot(), request: "email the total", details: MyDetails())
        XCTAssertEqual(preview.lines.map(\.text), ["Remember: Total: 42", "Scroll down"])
        guard case .scroll(let at, let dx, let dy)? = preview.actions.last else { return XCTFail("scroll") }
        XCTAssertNil(at)
        XCTAssertEqual(dx, 0)
        XCTAssertLessThan(dy, 0, "down scrolls with a negative wheel value")
        XCTAssertFalse(preview.needsApproval, "remembering and scrolling run without asking")
    }

    @MainActor
    func testSwitchingAppsEndsTheRoundAndNeverOpensTerminal() {
        let blocked = ScreenPlanValidator.preview(ScreenPlan(summary: "", steps: [.switchApp("Terminal")]), snapshot: snapshot(),
                                                  request: "open terminal", details: MyDetails())
        XCTAssertTrue(blocked.actions.isEmpty)
        XCTAssertTrue(ScreenApps.isNeverSwitch("Terminal.app"))
        XCTAssertTrue(ScreenApps.isNeverSwitch("the iTerm2 app"))
        XCTAssertFalse(ScreenApps.isNeverSwitch("Mail"))
        XCTAssertEqual(ScreenApps.cleaned("Google Chrome app"), "google chrome")
        XCTAssertTrue(ScreenAction.switchApp(ScreenAppTarget(name: "Mail", bundleURL: nil, processID: nil)).changesApp)
        XCTAssertTrue(ScreenAction.openFile(URL(fileURLWithPath: "/tmp/a.pdf")).changesApp)
        XCTAssertFalse(ScreenAction.wait(100).changesApp)
    }

    @MainActor
    func testFileWordsMustBeWordsTheUserSaid() {
        XCTAssertEqual(ScreenFileFinder.words("my latest Resume_2026.pdf"), ["resume", "2026", "pdf"])
        let invented = ScreenFileFinder.find(name: "passwords", folder: "Downloads", request: ToolGateText.fold("attach my resume"),
                                             opening: false)
        guard case .failure(let problem) = invented else { return XCTFail("a name the user didn't say is refused") }
        XCTAssertTrue(problem.reason.contains("passwords"))
        let nothing = ScreenFileFinder.find(name: "latest file", folder: nil, request: "attach the latest file", opening: false)
        guard case .failure = nothing else { return XCTFail("no words and no folder: ask which file") }
    }

    @MainActor
    func testQuickPlansNeedNoAI() {
        XCTAssertEqual(ScreenQuickPlan.target(of: "Please open YouTube.com"), "youtube.com")
        XCTAssertEqual(ScreenQuickPlan.webAddress("youtube.com"), "https://youtube.com")
        XCTAssertEqual(ScreenQuickPlan.webAddress("apple.com/in website"), "https://apple.com/in")
        XCTAssertNil(ScreenQuickPlan.webAddress("google chrome"))
        XCTAssertEqual(ScreenQuickPlan.target(of: "hey bibbles can you launch Safari"), "safari")
        XCTAssertNil(ScreenQuickPlan.target(of: "open Mail and write to Sam"), "more than opening goes to the planner")
        XCTAssertNil(ScreenQuickPlan.target(of: "open this file"))
        XCTAssertNil(ScreenQuickPlan.target(of: "export this to pdf"))
        let web = ScreenQuickPlan.plan(for: "open youtube.com")
        XCTAssertEqual(web?.steps, [.mac(AgentToolCall(name: "open_website", input: ["url": .string("https://youtube.com")]))])

        XCTAssertTrue(ScreenQuickPlan.isOpenRequest("open the holi7 file in Downloads and export it to PDF"))
        XCTAssertTrue(ScreenQuickPlan.isOpenRequest("please open Mail and write to Soham"))
        XCTAssertFalse(ScreenQuickPlan.isOpenRequest("open this link"), "\"this\" needs the screen")
        XCTAssertFalse(ScreenQuickPlan.isOpenRequest("start a happy song on the piano"))
        XCTAssertFalse(ScreenQuickPlan.isOpenRequest("export this to pdf"))
    }

    @MainActor
    func testVoiceCommands() {
        for text in ["Stop", "stop!", "Bibbles, stop", "cancel", "ruko", "Stopp"] {
            XCTAssertEqual(AgentVoiceCommand.parse(text), .stop, text)
        }
        for text in ["continue", "Go ahead.", "yes, do it", "carry on please", "weiter", "chalo"] {
            XCTAssertEqual(AgentVoiceCommand.parse(text), .proceed, text)
        }
        for text in ["stop the music", "continue writing the mail to Sam", "start a timer for 5 minutes", "what time is it"] {
            XCTAssertNil(AgentVoiceCommand.parse(text), text)
        }
    }

    @MainActor
    func testSpokenResultIsShort() {
        let long = "Saved holi7.pdf in Desktop. Filled 3 fields. Did 4 steps in 2 parts. Stopped: the Send button wasn't there anymore after the page changed."
        let spoken = AgentSpeech.short(long, limit: 60)
        XCTAssertTrue(long.hasPrefix(spoken))
        XCTAssertLessThanOrEqual(spoken.count, 60)
        XCTAssertEqual(AgentSpeech.short("Done."), "Done.")
    }

    @MainActor
    func testScreenshotPositionsRoundTrip() {
        let frame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let point = ScreenGeometry.globalPoint(x: 0.25, y: 0.75, displayFrame: frame, primaryHeight: 900)
        let back = ScreenGeometry.screenshotPoint(of: point, displayFrame: frame, primaryHeight: 900)
        XCTAssertEqual(back?.x, 250)
        XCTAssertEqual(back?.y, 750)
        XCTAssertNil(ScreenGeometry.screenshotPoint(of: CGPoint(x: 5_000, y: 10), displayFrame: frame, primaryHeight: 900))

        var described = ScreenSnapshot(appName: "Chrome", menus: [], controls: [
            ScreenControl(role: "AXButton", title: "Reply", isOn: nil, options: [], center: point),
            ScreenControl(role: "AXButton", title: "Load more", isOn: nil, options: [], center: CGPoint(x: 700, y: 2_000))
        ], fields: [], screenFrame: frame)
        described.primaryHeight = 900
        let text = described.describe(details: MyDetails())
        XCTAssertTrue(text.contains("button: Reply @ 250,750"))
        XCTAssertTrue(text.contains("button: Load more\n") || text.hasSuffix("button: Load more"), "off screen: no position")
    }
}
#endif
