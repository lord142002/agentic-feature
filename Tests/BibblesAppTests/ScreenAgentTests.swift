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
        XCTAssertEqual(preview.lines.map(\.text), ["Choose File ▸ Export as PDF...", "Press “Save”"],
                       "“…” and “...” match; Save in the sheet the menu opens is allowed")
        XCTAssertEqual(preview.dropped.count, 1)
        XCTAssertTrue(preview.dropped[0].reason.contains("never presses"))
        XCTAssertFalse(preview.lines[0].undoable)
    }

    @MainActor
    func testFinalButtonsAreNeverPressed() {
        let controls = ["Sign up", "Submit", "Send", "Pay now", "Buy", "Delete account", "Place order", "Registrieren",
                        "Enviar", "S'inscrire", "送信"].map { ScreenControl(role: "AXButton", title: $0, isOn: nil, options: []) }
        let plan = ScreenPlan(summary: "", steps: controls.map { .press($0.title) })
        let preview = ScreenPlanValidator.preview(plan, snapshot: snapshot(controls: controls), request: "sign me up", details: me)
        XCTAssertTrue(preview.isEmpty)
        XCTAssertEqual(preview.dropped.count, controls.count)
        XCTAssertNil(ScreenSafety.blockedWord(in: "Save"))
        XCTAssertNil(ScreenSafety.blockedWord(in: "Export"))
        XCTAssertNil(ScreenSafety.blockedWord(in: "Next"))
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
}
#endif
