#if BIBBLES_DEVELOPER
import AppKit
import Foundation

/// The developer test controls shared by the Option-click Developer menu and
/// Settings → Developer, so both always show the same state. Nothing here
/// changes the available tool set. The Tool Gate and AI router are on by
/// default; experimental keyword improvements are off. Developer builds only
/// (`-Xswiftc -DBIBBLES_DEVELOPER`): none of this exists in customer builds.
@MainActor
final class DeveloperControls: ObservableObject {
    static let shared = DeveloperControls()

    @Published private(set) var toolGate = ToolGate.isEnabled
    @Published private(set) var keywordImprovements = HybridRouter.keywordImprovementsEnabled
    @Published private(set) var aiRouter = HybridRouter.isEnabled
    /// "Not set" / "Set ✓ ····abcd" for each provider key.
    @Published private(set) var keyStatus: [DeveloperKeySlot: String] = [:]
    /// The latest Test result for each key ("OK", "invalid key"…).
    @Published private(set) var keyTest: [DeveloperKeySlot: DeveloperKeyTestResult] = [:]
    @Published private(set) var keyTesting: Set<DeveloperKeySlot> = []
    @Published private(set) var recordingLog = false
    @Published private(set) var logCount = 0
    @Published private(set) var testRunning = false
    @Published private(set) var testProgress: (done: Int, total: Int)?
    /// The latest result line, e.g. "Report copied · old 25/150 → …".
    @Published var message: String?
    @Published private(set) var messageIsError = false
    /// Extra progress output for the run in progress (the menu's notes).
    private var progressNote: ((String) -> Void)?

    private init() {}

    /// Re-reads everything (toggles can also change from the menu).
    func refresh() {
        toolGate = ToolGate.isEnabled
        keywordImprovements = HybridRouter.keywordImprovementsEnabled
        aiRouter = HybridRouter.isEnabled
        keyStatus = Dictionary(uniqueKeysWithValues: DeveloperKeySlot.allCases.map { ($0, DeveloperKeychain.status($0)) })
        recordingLog = ToolGateLog.shared.isRecording
        logCount = ToolGateLog.shared.entries.count
    }

    // MARK: Toggles

    func setToolGate(_ on: Bool) {
        ToolGate.isEnabled = on
        refresh()
    }

    func setKeywordImprovements(_ on: Bool) {
        HybridRouter.keywordImprovementsEnabled = on
        refresh()
    }

    func setAIRouter(_ on: Bool) {
        HybridRouter.isEnabled = on
        if on { RouterWarmUp.ifNeeded() }
        refresh()
    }

    func setRecordingLog(_ on: Bool) {
        ToolGateLog.shared.isRecording = on
        refresh()
    }

    /// A one-line warning when a toggle can't take effect yet (nil = fine).
    var warning: String? {
        if (aiRouter || keywordImprovements) && !toolGate { return "Turn the Tool Gate on: keyword improvements and the AI router only run with it." }

        return nil
    }

    var hasRouterKey: Bool { DeveloperKeychain.has(.anthropic) }

    func hasKey(_ slot: DeveloperKeySlot) -> Bool { DeveloperKeychain.has(slot) }

    // MARK: API keys (Keychain only)

    /// Reads the clipboard, trims, saves to the Keychain, then clears the clipboard.
    @discardableResult
    func pasteAndSave(_ slot: DeveloperKeySlot) -> Bool {
        let ok = DeveloperKeychain.pasteAndSave(slot)
        keyTest[slot] = nil
        show(ok ? "\(slot.title) key saved in Keychain (clipboard cleared)" : "Copy the \(slot.title) key first, then press Paste & Save",
             error: !ok)
        refresh()
        if ok, slot == .anthropic { RouterWarmUp.ifNeeded() }
        return ok
    }

    func removeKey(_ slot: DeveloperKeySlot) {
        DeveloperKeychain.remove(slot)
        keyTest[slot] = nil
        show("\(slot.title) key removed")
        refresh()
    }

    /// One tiny request with the saved key.
    func testKey(_ slot: DeveloperKeySlot) {
        guard !keyTesting.contains(slot) else { return }
        keyTesting.insert(slot)
        Task { @MainActor in
            let result = await DeveloperKeyTester.test(slot)
            self.keyTesting.remove(slot)
            self.keyTest[slot] = result
        }
    }

    // MARK: Tool Gate log

    @discardableResult
    func copyLog() -> Bool {
        refresh()
        guard !ToolGateLog.shared.entries.isEmpty else {
            show(ToolGateStrings.logEmpty, error: true)
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ToolGateLog.shared.table(), forType: .string)
        show("\(ToolGateStrings.logCopied) (\(ToolGateLog.shared.entries.count))")
        return true
    }

    func clearLog() {
        ToolGateLog.shared.clear()
        show(ToolGateStrings.menuClearLog)
        refresh()
    }

    // MARK: Router test set

    /// Runs the test set (router only: no answers, no Worker requests) and
    /// copies the report. `onProgress` lets the menu show notes too.
    func runTestSet(onProgress: ((String) -> Void)? = nil) {
        guard !testRunning else { return }
        guard let client = RouterClient.developer() else {
            show("Add your Anthropic key in Settings → Developer first.", error: true)
            onProgress?("Add your Anthropic key in Settings → Developer first")
            return
        }
        testRunning = true
        progressNote = onProgress
        testProgress = (0, RouterTestSet.cases.count)
        show("Running \(RouterTestSet.cases.count) phrases…")
        onProgress?("Router test: starting \(RouterTestSet.cases.count) phrases…")
        Task { @MainActor in
            let rows = await RouterTestRunner.run(client: client) { done, total in
                await MainActor.run {
                    let controls = DeveloperControls.shared
                    controls.testProgress = (done, total)
                    if done % 10 == 0 || done == total { controls.progressNote?("Router test: \(done)/\(total)…") }
                }
            }
            self.testRunning = false
            self.testProgress = nil
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(RouterTestRunner.report(rows), forType: .string)
            let total = rows.count
            let old = rows.filter { $0.today == $0.expected }.count
            let new = rows.filter { $0.newKeywords == $0.expected }.count
            let hybrid = rows.filter { $0.hybrid == $0.expected }.count
            let summary = "Report copied · old \(old)/\(total) → new keywords \(new)/\(total) → + router \(hybrid)/\(total)"
            self.show(summary)
            self.progressNote?(summary)
            self.progressNote = nil
        }
    }

    private func show(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }
}
#endif
