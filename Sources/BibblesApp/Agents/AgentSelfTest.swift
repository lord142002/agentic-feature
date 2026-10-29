#if BIBBLES_DEVELOPER
import Foundation

/// Files agent checks for `--router-self-test` (Macs without XCTest). Uses a
/// temporary folder only; never Downloads, Desktop or Documents, and never the Trash.
enum AgentSelfTest {
    static func checks() -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func check(_ name: String, _ condition: Bool) { results.append(("agent: " + name, condition)) }

        // Plan parsing
        let clean = #"{"summary":"Sort","steps":[{"action":"createFolder","path":"PDFs"},{"action":"move","match":{"ext":["pdf"]},"to":"PDFs"}]}"#
        check("parse clean plan", AgentPlanParser.parse(clean).plan?.steps.count == 2)
        check("parse fenced plan", AgentPlanParser.parse("```json\n" + clean + "\n```").isValid)
        check("parse prose-wrapped plan", AgentPlanParser.parse("Here you go: " + clean + " Done.").isValid)
        check("parse prefill continuation", AgentPlanParser.parse(String(clean.dropFirst())).isValid)
        check("reject broken plan", !AgentPlanParser.parse(#"{"summary":"x","steps":[{"#).isValid)
        let unknown = AgentPlanParser.parse(#"{"summary":"x","steps":[{"action":"delete","match":{"ext":["dmg"]}},{"action":"trash","match":{"ext":["dmg"]}}]}"#)
        check("drop unknown action", unknown.plan?.steps.map(\.action) == [.trash] && unknown.dropped.first?.index == 0)
        check("drop unknown match field",
              AgentPlanParser.parse(#"{"summary":"x","steps":[{"action":"trash","match":{"name_ends":"x"}}]}"#).plan?.steps.isEmpty == true)

        // Paths
        check("refuse ..", FilesPathSafety.problem(with: "../x") != nil)
        check("refuse hidden", FilesPathSafety.problem(with: ".x") != nil)
        check("refuse app bundle", FilesPathSafety.problem(with: "A.app") != nil)
        check("system folder", FilesPathSafety.isSystemPath(URL(fileURLWithPath: "/System/Library")))

        // Detection and strings
        check("detect English", FilesAgentDetector.isRequest("Clean up my Downloads folder"))
        check("detect Spanish", FilesAgentDetector.isRequest("Limpia mi carpeta de descargas"))
        check("detect German", FilesAgentDetector.isRequest("Räum meinen Download-Ordner auf"))
        check("detect Hinglish", FilesAgentDetector.isRequest("Downloads folder saaf kar do"))
        check("question is not a request", !FilesAgentDetector.isRequest("How do I organise my desktop?"))
        var result = AgentResult()
        result.moved = 362
        result.trashed = 40
        result.destinationFolders = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b"), URL(fileURLWithPath: "/c")]
        check("English summary", FilesAgentStrings.english.summary(result) == "Moved 362 files into 3 folders. 40 files are in the Trash.")

        // Screen agent (no app is touched)
        check("screen: never press Sign up", ScreenSafety.blockedWord(in: "Sign up") != nil && ScreenSafety.blockedWord(in: "Save") == nil)
        check("screen: email label", MyDetailsMatcher.key(forLabel: "E-Mail") == .email)
        check("screen: never fill passwords", MyDetailsMatcher.key(forLabel: "Password") == nil)
        check("screen: PIN code is a postal code", MyDetailsMatcher.key(forLabel: "PIN code") == .postalCode)
        check("screen: details fill detected", ScreenAgentDetector.isDetailsFill("Fill in this sign-up form with my details"))
        check("screen: parse export plan",
              ScreenPlanParser.parse(#"{"summary":"","steps":[{"action":"menu","path":["File","Export as PDF…"]},{"action":"press","target":"Save"}]}"#).plan?.steps.count == 2)
        var saved = MyDetails()
        saved.email = "a@b.c"
        check("screen: AI never sees values", (try? ScreenPlanValidator.resolve("{{email}}", details: saved, request: "").get()) == "a@b.c"
              && (try? ScreenPlanValidator.resolve("made up", details: saved, request: "").get()) == nil)

        // Move, name collision, Stop and Undo in a temporary folder.
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("BibblesAgentSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        do {
            try manager.createDirectory(at: root.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
            for name in ["a.pdf", "b.pdf", "c.pdf", "PDFs/a.pdf"] { try Data("x".utf8).write(to: root.appendingPathComponent(name)) }
            let scan = try FolderScanner.scan(root)
            let plan = AgentRulePlan(summary: "", steps: [AgentStep(action: .move, match: AgentMatch(ext: ["pdf"]), to: "PDFs")])
            let preview = FilesPlanApplier.apply(plan, to: scan, allowed: [root])
            check("preview before anything changes", preview.moves == 3 && manager.fileExists(atPath: root.appendingPathComponent("a.pdf").path))
            let executor = AgentExecutor()
            let run = executor.run(preview.operations) { done, _, _ in if done == 2 { executor.stop() } }
            check("stop halts cleanly", run.stopped && run.moved == 2)
            check("never overwrite", manager.fileExists(atPath: root.appendingPathComponent("PDFs/a 2.pdf").path))
            let undone = AgentExecutor.undo(run.undo)
            check("undo restores", undone.failed == 0 && ["a.pdf", "b.pdf", "c.pdf"].allSatisfy {
                manager.fileExists(atPath: root.appendingPathComponent($0).path)
            })
        } catch {
            check("temporary folder", false)
        }
        return results
    }
}
#endif
